# Third-Party Notices

clock's structure and transport layer are derived from
[clapp-template](../template-clapp), and its shared plumbing — the control pipe, the
GUI↔CLI IPC, the data-dir resolver, the store writer — comes from the in-tree
[clappkit](../clappkit) crate.

## Runtime dependencies

clock is a Rust binary with a [Tauri v2](https://tauri.app) webview front end. It ships
no bundled runtime and no vendored browser: the window is the operating system's own
WebView (WKWebView on macOS, WebView2 on Windows, WebKitGTK on Linux).

| Component | License |
|---|---|
| [tauri](https://github.com/tauri-apps/tauri) 2 (+ `@tauri-apps/api`) | Apache-2.0 OR MIT |
| [tokio](https://github.com/tokio-rs/tokio) 1 | MIT |
| [serde](https://github.com/serde-rs/serde) / serde_json 1 | Apache-2.0 OR MIT |
| [chrono](https://github.com/chronotope/chrono) 0.4 | Apache-2.0 OR MIT |
| [anyhow](https://github.com/dtolnay/anyhow) 1 | Apache-2.0 OR MIT |
| [React](https://react.dev) 18 / react-dom | MIT |
| [Vite](https://vite.dev) 5, [TypeScript](https://www.typescriptlang.org) 5 (build only) | MIT / Apache-2.0 |

Full transitive license text is reproducible from the lockfiles
(`src-tauri/Cargo.lock`, `package-lock.json`).

## Fonts

**None bundled.** clock uses the system typeface (SF Pro on macOS) throughout, so
nothing is redistributed. Earlier revisions bundled Plus Jakarta Sans as part of the
Clatch design system; that dependency was removed when the app was restyled after
Apple's Clock (see below).

## Visual design

clock's interface deliberately follows the design of Apple's **Clock** app — its
palette (systemOrange chrome, systemGreen switches), SF Pro type scale, grouped row
layout, analog dial proportions, and app-icon geometry. This is a homage in an
unaffiliated third-party utility: clock is not produced, endorsed, or approved by
Apple, ships no Apple code or artwork, and reproduces no Apple asset — every element
is drawn from scratch in this repository (`src/ClockFace.tsx`, and the icon by
`scripts/render-clock-icon.swift`). "Apple" and "Clock" are trademarks of Apple Inc.

Note that this makes clock the one clapp-template fork that does **not** carry the
Clatch design system; see the header of `src/styles.css`.

## The Swift original

`native/` holds the original macOS SwiftUI implementation, retained as the behavioural
reference for the Rust port rather than as a build target. It builds against Apple's
system frameworks only (Foundation, AppKit, SwiftUI) and ships in nothing.
