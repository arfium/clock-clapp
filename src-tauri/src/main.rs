//! clock — one binary, two roles (clappkit `role`): `clock app` is the Tauri process
//! Clatch launches (window + scheduler + control pipe + IPC server); `clock <verb>` is
//! the agent's CLI client. All plumbing is clappkit's, all state is `Store` — no
//! platform code, so the one binary builds for macOS, Windows, and Linux.

// On Windows a release GUI build must not pop a console window.
#![cfg_attr(all(not(debug_assertions), windows), windows_subsystem = "windows")]

mod app;
mod cli;
mod store;

use clappkit::role::{role, Role};

const APP_ID: &str = "com.arfium.clock";

fn main() {
    match role() {
        Role::Cli(args) => {
            tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .expect("tokio runtime")
                .block_on(cli::run(args)); // exits inside
        }
        Role::App => {
            // Run only under Clatch: relaunch-and-exit if started any other way.
            match clappkit::bootstrap(APP_ID) {
                Ok(true) => {}
                Ok(false) => app::run(),
                Err(e) => {
                    eprintln!("clock: {e}");
                    std::process::exit(1);
                }
            }
        }
    }
}
