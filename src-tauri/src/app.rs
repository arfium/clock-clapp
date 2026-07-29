//! The GUI process: a Tauri window over the same `Store` the CLI drives. The React
//! webview calls `run_cmd` (invoke) and listens for `state` events; the scheduler and
//! the agent's IPC both go through the SAME `Store::handle`, so nothing drifts.
//!
//! The window is OPTIONAL and disposable; the scheduler is not. Closing it hides it and
//! drops the app to the background (macOS `.accessory`), `clock app --background` starts
//! with no window at all, and `clock close` is the ONE thing that ends the process —
//! a clock that stops keeping time when you close its window is not a clock.

use crate::store::{AgentRow, Store};
use clappkit::{ipc, Control};
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, RunEvent, State, WindowEvent};
use tokio::sync::Mutex;

pub type SharedStore = Arc<Mutex<Store>>;
const CLI: &str = "clock";
const WINDOW: &str = "main";

/// The app's own mark, embedded so the bare executable can set its Dock/taskbar icon at
/// runtime — there is no `.app` bundle to carry it (docs/ICONS.md, docs/PLAYBOOK.md).
const ICON_PNG: &[u8] = include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../assets/icon.png"));

/// Give this bare executable its own icon: the Dock on macOS, the window (hence taskbar)
/// on Windows/Linux. Called on the main thread from `setup`, before the window shows.
fn apply_icon(app: &AppHandle) {
    clappkit::set_dock_icon(ICON_PNG);
    #[cfg(not(target_os = "macos"))]
    if let Some(w) = main_window(app) {
        if let Ok(img) = tauri::image::Image::from_bytes(ICON_PNG) {
            let _ = w.set_icon(img);
        }
    }
    #[cfg(target_os = "macos")]
    let _ = app;
}

pub fn run() {
    // `clock app --background`: start with no window and no Dock tile — just the
    // scheduler and the socket. An agent setting an alarm shouldn't have to take over
    // the screen. (`role()` routes on argv[1], so the flag is still in `args()`.)
    let background = std::env::args().any(|a| a == "--background");
    let store: SharedStore = Arc::new(Mutex::new(Store::load()));

    // Connect the control pipe on Tauri's own async runtime, so the reactive loop
    // (emit + serve + roster) outlives this call and shares the runtime with the tasks.
    let control = tauri::async_runtime::block_on(clappkit::connect(clappkit::declared_signals()))
        .unwrap_or_else(|e| {
            eprintln!("clock: {e}");
            std::process::exit(1);
        });

    let app = tauri::Builder::default()
        .manage(store.clone())
        .manage(control.clone())
        .setup(move |app| {
            let handle = app.handle().clone();
            // Set the app's own icon before anything shows, so the Dock/taskbar never
            // flashes the generic tile.
            apply_icon(&handle);
            // The window is created hidden (tauri.conf.json `"visible": false`) and the
            // policy demoted first, so a background start never flashes a Dock icon;
            // `show_window` promotes us back to .regular the moment there IS a window.
            enter_background(&handle);
            if !background {
                show_window(&handle);
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
                let _ = window.hide();
                enter_background(window.app_handle());
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

// MARK: - Window lifetime (the window is optional and disposable; the scheduler is not)

/// `clock show` / `clock focus` / launch: put the window back on screen — and the app
/// back in the Dock (macOS `.regular`).
fn show_window(app: &AppHandle) {
    #[cfg(target_os = "macos")]
    let _ = app.set_activation_policy(tauri::ActivationPolicy::Regular);
    if let Some(w) = main_window(app) {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

/// `clock hide` / the red button: no window, no Dock tile, still alive and still ticking.
fn hide_window(app: &AppHandle) {
    if let Some(w) = main_window(app) {
        let _ = w.hide();
    }
    enter_background(app);
}

/// The one window from the manifest — falling back to whatever window exists, so a
/// relabelled config can never leave the app running with nothing on screen.
fn main_window(app: &AppHandle) -> Option<tauri::WebviewWindow> {
    app.get_webview_window(WINDOW)
        .or_else(|| app.webview_windows().into_values().next())
}

/// No Dock tile, no menu bar — the scheduler runs on (Swift's `enterBackground`).
fn enter_background(app: &AppHandle) {
    #[cfg(target_os = "macos")]
    let _ = app.set_activation_policy(tauri::ActivationPolicy::Accessory);
    #[cfg(not(target_os = "macos"))]
    let _ = app;
}

/// The app-level verbs the CLI drives. They never touch the store — the window is
/// disposable, the alarms are not. `None` means "not a window verb, pass it to the store".
fn window_cmd(app: &AppHandle, cmd: &str) -> Option<Value> {
    match cmd {
        "ping" => Some(json!({ "ok": true })),
        "show" | "focus" => {
            show_window(app);
            Some(json!({ "ok": true, "message": "window shown" }))
        }
        "hide" => {
            hide_window(app);
            Some(json!({ "ok": true, "message": "running in the background" }))
        }
        // The one command that really stops the alarms. Deferred a beat so the CLI's
        // response frame is written before the process goes away (Swift defers the
        // `NSApp.terminate` to the next main-loop turn for the same reason).
        "quit" | "close" => {
            let handle = app.clone();
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(Duration::from_millis(150)).await;
                handle.exit(0);
            });
            Some(json!({ "ok": true, "message": "bye" }))
        }
        _ => None,
    }
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
    let resp = apply(&store, &control, &req, None).await;
    let _ = app.emit("state", store.lock().await.snapshot());
    Ok(resp)
}

/// Apply a command through the ONE `Store::handle` and emit any signals it produced.
async fn apply(store: &SharedStore, control: &Control, req: &Value, caller: Option<String>) -> Value {
    let (resp, emits) = {
        let mut s = store.lock().await;
        s.set_agents(roster(control));
        let r = s.handle(req, caller);
        s.save();
        r
    };
    for e in emits {
        control.emit(&e.id, e.target, e.payload);
    }
    resp
}

/// Serve the agent's CLI over clappkit IPC (a separate process), then refresh the window.
fn spawn_ipc(store: SharedStore, control: Control, app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let handler = move |req: Value| {
            let store = store.clone();
            let control = control.clone();
            let app = app.clone();
            async move {
                // `show` / `hide` / `focus` / `close` drive the WINDOW, not the store.
                let verb = req.get("cmd").and_then(Value::as_str).unwrap_or("");
                if let Some(resp) = window_cmd(&app, verb) {
                    return resp;
                }
                let caller = req.get("agent").and_then(|v| v.as_str()).map(String::from);
                let resp = apply(&store, &control, &req, caller).await;
                let _ = app.emit("state", store.lock().await.snapshot());
                resp
            }
        };
        if let Err(e) = ipc::serve(&ipc::address(CLI), handler).await {
            eprintln!("clock: ipc: {e}");
        }
    });
}

/// The 1-second scheduler: fire due alarms/timers as signals, and keep the window live.
/// Clatch has no cron — this app IS the scheduler while it runs.
fn spawn_scheduler(store: SharedStore, control: Control, app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(1));
        loop {
            ticker.tick().await;
            let (emits, snap) = {
                let mut s = store.lock().await;
                // Keep the roster fresh so `wakes` / `owner` names and the GUI's
                // wake-target picker track Clatch's `app.agents` pushes.
                s.set_agents(roster(&control));
                let e = s.tick(chrono::Local::now());
                if !e.is_empty() {
                    s.save();
                }
                (e, s.snapshot())
            };
            for e in emits {
                // The signal wakes the agent; the `fired` event is the human's cue (the
                // webview plays the chime, as the Swift app's `onFire` did).
                let _ = app.emit("fired", serde_json::json!({ "signal": e.id, "payload": e.payload }));
                control.emit(&e.id, e.target, e.payload);
            }
            let _ = app.emit("state", snap);
        }
    });
}

fn roster(control: &Control) -> Vec<AgentRow> {
    control
        .agents()
        .into_iter()
        .map(|a| AgentRow { id: a.id, name: a.name, backend: a.backend, model: a.model })
        .collect()
}
