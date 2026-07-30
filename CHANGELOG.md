# Changelog

All notable changes to **clock**. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: pre-1.0, minor
bumps may break (SemVer 0.x rules).

## [Unreleased]

### Changed

- **Ported from macOS SwiftUI to Rust + Tauri v2 on the shared `clappkit` crate.** One
  binary, two roles, unchanged: `clock app` is the GUI Clatch launches, `clock <verb>`
  is the agent's CLI, and both go through the same `Store::handle`. The new layout is
  `src-tauri/` (Rust) + `src/` (React). `clatch.json`'s `launch` gained `windows` and
  `linux` alongside `macos`. The SwiftUI original stays checked in under `native/` as
  the **behavioural reference**, not as the build — `src-tauri/src/store.rs` is a 1:1
  port of `ClockStore.swift` down to the on-disk format, so an existing
  `clock.json` written by the Swift app still loads.
- **Adopted clappkit's shared plumbing**, deleting clock's local copies: the data-dir
  resolver, the atomic store writer, the window verbs (`ping`/`show`/`hide`/`quit`),
  the icon wiring, the GUI↔CLI relay, the roster projection (`Control::roster`), the
  `Emit`/`AgentRow` types, and `main()`'s role dispatch.
- **State now lives under `CLATCH_DATA_DIR` properly.** An exported-but-empty
  `CLATCH_DATA_DIR` used to send `clock.json` into the process working directory —
  which under Clatch is the *install* directory, where an update destroys it. It is now
  treated as unset, and there is no `"."` fallback at all. On Windows the fallback moved
  from a `~/.clock` dotdir in the profile root to `%LOCALAPPDATA%\clock`; macOS and
  Linux keep `~/.clock` exactly.
- **`clock.json` is written durably and privately**: temp file → `fsync` → rename →
  directory `fsync`, at mode `0600` on unix. The old write was atomic against a
  concurrent reader but not against a power loss, and the lenient load path would have
  read the resulting truncated file as "fresh install" and started with no alarms.
- Signals are delivered with a bounded wait rather than a lossy try-send, and a dropped
  one is now counted and logged — "the alarm just did not fire" used to be
  indistinguishable from a scheduler bug.
- The `quit` grace is 150 ms, and `focus`/`show` answer `window shown`.
- Docs rewritten for the real implementation; `AGENT.md` renamed to **`AGENTS.md`** to
  match every other clapp (`CLAUDE.md` follows it).

### Added

- **`state`** declared in `connector.commands` as an alias for `list`. It was
  implemented in the CLI but undeclared, and `connector.commands` is the permission
  grain — an undeclared verb is one no agent can be granted. `--help` now carries a
  usage line for every declared verb, including `set` and `focus`, which were only
  mentioned in passing.
- A **shutdown hook**: Clatch's `app.shutdown` (and a closed control pipe) ends the
  process from inside clappkit, skipping every destructor. clock now flushes its alarms
  and timers on the way out. The `app.shutdown` ack itself is flushed to the wire before
  the exit, so Clatch no longer has to fall back to its kill timeout.
- A monotonic **`rev`** on every snapshot. The invoke reply and the scheduler's pushed
  `state` event race every second, and a reply that resolved late could drag the window
  back to a stale alarm list; the front end now drops the loser.
- **`scripts/verify.sh`** — build → package → `clatch validate` → socket round-trip
  through the *packaged* binary. clock never had this gate. Plus `scripts/render-icon.sh`
  (regenerates `assets/icon.png` **and** the stale-prone `src-tauri/icons/icon.ico` from
  one source) and the shared `scripts/lib.sh` every clapp script now reads identity from.
- `docs/ICONS.md` and `docs/PLAYBOOK.md` — the house standards this app is held to were
  only readable in the template.
- `.claude/` with the Tauri-era command allowlist, and a `CHANGELOG.md` (this file).

### Fixed

- **A crash loop from one bad field on disk.** A `clock.json` carrying a `repeatDays`
  value outside 1–7 (hand-edited, or written by a forked build) indexed an 8-element
  table out of bounds — inside `snapshot()`, so it panicked on *every* command and on
  *every* 1-second tick, and only editing the file by hand could stop it. Out-of-range
  days are now dropped at decode, and the lookup is total.
- **`clock timer <huge>` no longer overflows.** `9223372036854775807s` parsed cleanly
  and then overflowed `now + seconds`: a panic in a debug build, and in release a
  wrapped negative deadline that "completed" instantly with a bogus `timer.done`.
  Durations are capped at `365d` with an actionable message.
- **`clock now` no longer rewrites the store.** Every command — including the three
  pure reads — serialised and rewrote the whole of `clock.json`, with the blocking write
  held under the state lock while the scheduler waited on it.
- **The scheduler no longer stampedes after a laptop sleep.** The 1-second interval used
  tokio's default `Burst` behaviour, which replays every missed tick back to back; an
  hour asleep queued ~3600 immediate snapshots and webview pushes at the moment the
  machine was waking up. It is `Delay` now — alarms are wall-clock driven, so skipping
  the backlog changes nothing about when they fire.
- **The response and the pushed snapshot are taken in one critical section.** The store
  lock was released between them, so a scheduler tick could interleave and the window
  could be shown a different moment than the caller was told about.
- An empty `model` from Clatch's roster rendered as an empty value instead of nothing.
- `dist/` was two incompatible things: Vite's bundle and the Clatch depot. `npm run
  build` and `scripts/package.sh` deleted each other's output and `clatch validate dist`
  could not pass. The depot is **`pkg/`** now; `dist/` is Vite's alone.
- Packaging built the retired Swift target. It now builds through the Tauri CLI (a bare
  `cargo build --release` produces a binary with **no embedded frontend**, which opens a
  white window — `package.sh` asserts against that), handles `.exe`, and rewrites the
  depot manifest's `connector.cliBin` to `bin/clock.exe` on Windows, without which a
  Windows package fails `clatch validate` and cannot install.
- CI built Swift on macOS only, while the manifest claimed three platforms; it is now a
  macOS/Windows/Linux matrix that compiles the Rust and runs the tests, which had never
  run in CI at all.
- Stale protocol-1 references: `CLATCH_AGENT` → `CLATCH_AGENT_ID`, and the "Clapp v1"
  labels, which the manifest has declared `"protocol": 2` for some time.

### Removed

- `windows_subsystem = "windows"` was never applied here in a form that survived the
  port, and must not be re-added: it marks the whole image GUI-subsystem, and this image
  is two roles — the agent's CLI would return instantly and empty through the `.cmd`
  shim Clatch links onto its PATH. Clatch already spawns the launch command with
  `CREATE_NO_WINDOW`.

## [0.2.0]

### Added

- Choose **which agent(s)** an alarm wakes: the GUI's *Wake which* picker and `--to
  alice,bob` / `--to everyone`. Targets are stored as agent **ids**, so a renamed agent
  keeps its alarms.
- `--note` on alarms: the instruction a woken agent acts on, and in effect the prompt
  for the turn the alarm starts.

### Changed

- Alarms and timers record the setter's `CLATCH_AGENT_ID` and, by default, wake exactly
  that agent rather than broadcasting.

## [0.1.0]

- First release: a live analog face, drum-wheel alarms with weekday repeats, countdown
  timers, and the four signals (`alarm.fired`, `alarm.quiet`, `alarm.set`,
  `timer.done`).
