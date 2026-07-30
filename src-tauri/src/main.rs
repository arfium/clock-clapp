//! clock — one binary, two roles (clappkit `role`): `clock app` is the Tauri process
//! Clatch launches (window + scheduler + control pipe + IPC server); `clock <verb>` is
//! the agent's CLI client. All plumbing is clappkit's, all state is `Store` — no
//! platform code, so the one binary builds for macOS, Windows, and Linux.
//!
//! There is deliberately NO `windows_subsystem = "windows"` here. That attribute applies
//! to the whole image, and this image is two roles: a GUI-subsystem process gets no
//! console and is not waited on by the `.cmd` shim Clatch links onto the agent's PATH, so
//! every `clock <verb>` would return instantly, empty, with exit code 0. Clatch already
//! spawns the launch command with `CREATE_NO_WINDOW`, so a console-subsystem clapp shows
//! no console window anyway. (clappkit `role::main_dispatch` documents the same.)

mod app;
mod cli;
mod store;

const APP_ID: &str = "com.arfium.clock";

fn main() {
    clappkit::role::main_dispatch(APP_ID, "clock", cli::run, app::run)
}
