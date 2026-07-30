# CLAUDE.md

Mirrors [`AGENTS.md`](AGENTS.md) for Claude. If you change one, change the other.

- **Operating clock** (as an agent): [`AGENTS.md`](AGENTS.md).
- **How it works / the "scheduler is an app" doctrine**: [`README.md`](README.md).
- **The frozen contract — every point between Clatch and this clapp — is
  [`docs/protocol.md`](docs/protocol.md)** (The Clapp Protocol: manifest + control
  pipe). It is the single normative source; Clatch implements it. **Protocol wins.**
- **House standards**: [`docs/ICONS.md`](docs/ICONS.md) (the icon contract) and
  [`docs/PLAYBOOK.md`](docs/PLAYBOOK.md) (shipping lessons).

## Working on the code

clock is **Rust + Tauri v2** on the shared [`clappkit`](../clappkit) crate, ported from
the SwiftUI original that is still checked in under `native/` as the behavioural
reference — read it to settle a question about behaviour, never to build.

- `src-tauri/src/store.rs` — the whole app: alarms, timers, the scheduler tick, and the
  ONE `handle` both surfaces call. Pure and sync; it returns signals rather than sending
  them. **This is the file worth reading.**
- `src-tauri/src/app.rs` — the Tauri process: window lifetime, the scheduler task, the
  IPC relay. Almost everything generic here is a call into `clappkit::app`.
- `src-tauri/src/cli.rs` — the agent's CLI. `HELP` is the agent's only manual, so it must
  list exactly the verbs `clatch.json`'s `connector.commands` declares.
- `src/` — the React window. Its two channels (`cmd`, `onState`) and the snapshot
  wiring (`useSnapshot`) come from `@clappkit`, aliased in `vite.config.ts`.

Do not hand-roll plumbing. Where state lives (`clappkit::paths`), how it is written
(`clappkit::store`), the window verbs (`clappkit::window`), the roster projection
(`Control::roster`) and the signal type (`clappkit::Emit`) are all shared — four apps
copy-pasted them once and drifted.

```sh
npm run build      # the shippable binary (through the Tauri CLI — never bare cargo)
npm test           # the store, the scheduler, the parsers
npm run verify     # build → package → validate → socket round-trip. Before every commit.
```
