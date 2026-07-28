//! The GUI process: a Tauri window over the same `Store` the CLI drives. The React
//! webview calls `run_cmd` (invoke) and listens for `state` events; the scheduler and
//! the agent's IPC both go through the SAME `Store::handle`, so nothing drifts.

use crate::store::{AgentRow, Store};
use clappkit::{ipc, Control};
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;
use tauri::{AppHandle, Emitter, State};
use tokio::sync::Mutex;

pub type SharedStore = Arc<Mutex<Store>>;
const CLI: &str = "clock";

pub fn run() {
    let store: SharedStore = Arc::new(Mutex::new(Store::load()));

    // Connect the control pipe on Tauri's own async runtime, so the reactive loop
    // (emit + serve + roster) outlives this call and shares the runtime with the tasks.
    let control = tauri::async_runtime::block_on(clappkit::connect(clappkit::declared_signals()))
        .unwrap_or_else(|e| {
            eprintln!("clock: {e}");
            std::process::exit(1);
        });

    tauri::Builder::default()
        .manage(store.clone())
        .manage(control.clone())
        .setup(move |app| {
            let handle = app.handle().clone();
            spawn_ipc(store.clone(), control.clone(), handle.clone());
            spawn_scheduler(store.clone(), control.clone(), handle);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![run_cmd])
        .run(tauri::generate_context!())
        .expect("error while running clock");
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
fn spawn_scheduler(store: SharedStore, control: Control, app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(1));
        loop {
            ticker.tick().await;
            let (emits, snap) = {
                let mut s = store.lock().await;
                let e = s.tick(chrono::Local::now());
                if !e.is_empty() {
                    s.save();
                }
                (e, s.snapshot())
            };
            for e in emits {
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
        .map(|a| AgentRow { id: a.id, name: a.name })
        .collect()
}
