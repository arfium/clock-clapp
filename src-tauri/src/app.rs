//! The GUI process: a Tauri window over the same `Store` the CLI drives. The React
//! webview calls `run_cmd` (invoke) and listens for `state` events; the scheduler and
//! the agent's IPC both go through the SAME `Store::handle`, so nothing drifts.
//!
//! The window is OPTIONAL and disposable; the scheduler is not. Closing it hides it and
//! drops the app to the background (macOS `.accessory`), `clock app --background` starts
//! with no window at all, and `clock close` is the ONE thing that ends the process —
//! a clock that stops keeping time when you close its window is not a clock.
//!
//! Everything generic here is clappkit's: the icon dance, the window verbs, the IPC
//! relay, the roster projection. What is left is the parts that are actually clock's —
//! the background-start flag, the `ExitRequested` guard, and the 1-second scheduler.

use crate::store::Store;
use clappkit::app::Reply;
use clappkit::{Control, WindowPolicy};
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, RunEvent, State, WindowEvent};
use tokio::sync::Mutex;

pub type SharedStore = Arc<Mutex<Store>>;
const CLI: &str = "clock";

/// The app's own mark, embedded so the bare executable can set its Dock/taskbar icon at
/// runtime — there is no `.app` bundle to carry it (docs/ICONS.md, docs/PLAYBOOK.md).
const ICON_PNG: &[u8] = include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../assets/icon.png"));

/// clock is the backgroundable clapp: `hide` and the close box demote it instead of
/// quitting, and the icon is re-asserted when a `.regular` promotion rebuilds the Dock
/// tile. `quit`/`close` still answers first and exits a beat later, so the CLI's response
/// frame is on the wire before the process goes away.
fn policy() -> WindowPolicy {
    WindowPolicy::backgroundable(ICON_PNG)
}

pub fn run() {
    // `clock app --background`: start with no window and no Dock tile — just the
    // scheduler and the socket. An agent setting an alarm shouldn't have to take over
    // the screen. (`role()` routes on argv[1], so the flag is still in `args()`.)
    let background = std::env::args().any(|a| a == "--background");
    let store: SharedStore = Arc::new(Mutex::new(Store::load()));

    // Connect the control pipe on Tauri's own async runtime, so the reactive loop
    // (emit + serve + roster) outlives this call and shares the runtime with the tasks.
    //
    // The shutdown hook is not optional for this app: clappkit's control loop ends the
    // process on Clatch's `app.shutdown` (and on a closed pipe), which skips every
    // destructor. clock's whole premise is that only `clock close` stops it, so a
    // shutdown that arrives from underneath must at least not lose the last mutation.
    // The hook runs on its own thread, off the runtime, so `blocking_lock` is correct
    // here; clappkit caps the wait so a held lock cannot wedge the quit.
    let flush = store.clone();
    let control = tauri::async_runtime::block_on(clappkit::connect_or_die_with(
        CLI,
        Arc::new(move |cause| {
            eprintln!("clock: {cause} — flushing alarms and timers");
            flush.blocking_lock().save();
        }),
    ));

    let app = tauri::Builder::default()
        .manage(store.clone())
        .manage(control.clone())
        .setup(move |app| {
            let handle = app.handle().clone();
            // Set the app's own icon before anything shows, so the Dock/taskbar never
            // flashes the generic tile.
            clappkit::app::apply_icon(&handle, ICON_PNG);
            // The window is created hidden (tauri.conf.json `"visible": false`), so the
            // policy is set ONCE, to whichever state we are actually starting in.
            //
            // It used to demote to .accessory unconditionally and then promote straight
            // back for a normal launch. That round trip is what left clock — alone among
            // the clapps — showing the generic terminal tile: promoting to .regular builds
            // a BRAND NEW Dock tile, and a bare executable's new tile is the generic one.
            // Re-asserting the icon afterwards only races that construction. Not demoting
            // in the first place is the fix, and it makes a normal clock launch behave
            // exactly like chess, whose icon was never wrong.
            if background {
                clappkit::app::enter_background(&handle);
            } else {
                clappkit::app::show_window(&handle, Some(ICON_PNG));
            }
            spawn_ipc(store.clone(), control.clone(), handle.clone());
            spawn_scheduler(store.clone(), control.clone(), handle);
            Ok(())
        })
        // Closing the window BACKGROUNDS the app — it does not stop the alarms. A clock
        // that stops keeping time when you close its window is not a clock.
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                clappkit::app::hide_window(window.app_handle());
            }
        })
        .invoke_handler(tauri::generate_handler![run_cmd])
        .build(tauri::generate_context!())
        .expect("error while building clock");

    app.run(|_app, event| {
        // `code: None` is "the last window went away" — survive it. `clock close` calls
        // `AppHandle::exit`, which arrives with `Some(code)` and is allowed through, so
        // the quit verb stays the ONE thing that ends the process.
        if let RunEvent::ExitRequested { code: None, api, .. } = event {
            api.prevent_exit();
        }
    });
}

/// The one command the webview calls: a command envelope `{ "cmd": … }` (human caller),
/// applied through the shared store; the fresh state rides back as a `state` event too.
#[tauri::command]
async fn run_cmd(
    req: Value,
    store: State<'_, SharedStore>,
    control: State<'_, Control>,
    app: AppHandle,
) -> Result<Value, String> {
    let reply = apply(&store, &control, &req, None).await;
    clappkit::app::push_state(&app, reply.snapshot);
    Ok(reply.resp)
}

/// Apply a command through the ONE `Store::handle` and emit any signals it produced.
/// The response and the snapshot are taken in the SAME critical section, so the state
/// pushed to the window can never describe a different moment than the answer the caller
/// got — a scheduler tick used to be able to interleave between the two.
async fn apply(store: &SharedStore, control: &Control, req: &Value, caller: Option<String>) -> Reply {
    let (resp, emits, snap) = {
        let mut s = store.lock().await;
        s.set_agents(control.roster());
        let (resp, emits) = s.handle(req, caller);
        // Only a mutation writes. The write stays inside the lock deliberately: it is
        // what orders two concurrent saves, and a read no longer pays for it at all.
        if s.take_dirty() {
            s.save();
        }
        let snap = s.snapshot();
        (resp, emits, snap)
    };
    control.emit_all(emits);
    Reply::new(resp, snap)
}

/// Serve the agent's CLI over clappkit IPC (a separate process). clappkit answers the
/// window verbs itself, extracts the caller's agent id, and pushes the snapshot we return.
fn spawn_ipc(store: SharedStore, control: Control, app: AppHandle) {
    clappkit::app::spawn_ipc(app, CLI, policy(), move |req, caller| {
        let store = store.clone();
        let control = control.clone();
        async move { apply(&store, &control, &req, caller).await }
    });
}

/// The 1-second scheduler: fire due alarms/timers as signals, and keep the window live.
/// Clatch has no cron — this app IS the scheduler while it runs.
fn spawn_scheduler(store: SharedStore, control: Control, app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(1));
        // `Delay`, not the default `Burst`: after a laptop suspend the runtime clock is
        // starved, and Burst replays every missed tick back to back — an hour asleep
        // queued ~3600 immediate iterations, each one a full snapshot and a webview push,
        // at the moment the machine is trying to wake up. `tick()` reads the wall clock
        // each time, so skipping the backlog changes nothing about when alarms fire.
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            ticker.tick().await;
            let (emits, snap) = {
                let mut s = store.lock().await;
                // Keep the roster fresh so `wakes` / `owner` names and the GUI's
                // wake-target picker track Clatch's `app.agents` pushes.
                s.set_agents(control.roster());
                let e = s.tick(chrono::Local::now());
                if s.take_dirty() {
                    s.save();
                }
                (e, s.snapshot())
            };
            for e in &emits {
                // The signal wakes the agent; the `fired` event is the human's cue (the
                // webview plays the chime, as the Swift app's `onFire` did).
                let _ = app.emit("fired", json!({ "signal": e.id, "payload": e.payload }));
            }
            control.emit_all(emits);
            clappkit::app::push_state(&app, snap);
        }
    });
}
