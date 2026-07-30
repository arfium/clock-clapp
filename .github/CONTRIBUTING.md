# Contributing to clock

clock is a **clapp**: one binary with two roles (a Tauri window for the human, a CLI
for the agent) over one shared state, on the frozen
[Clapp Protocol](../docs/protocol.md). Keep it small, keep it correct.

## Ground rules

- **The protocol wins.** [`docs/protocol.md`](../docs/protocol.md) is the normative
  contract for every point between Clatch and this app — the manifest and the control
  pipe. Clatch implements it; on any conflict, the protocol is right and we are wrong.
- **Three surfaces must agree.** `clatch.json`'s `connector.commands`, the verbs
  `src-tauri/src/cli.rs` actually implements, and the `HELP` text must list the same
  set — `connector.commands` is the permission grain (`Bash(clock <verb>:*)`), so an
  undeclared verb is one no agent can be granted, and *"if a verb isn't in `--help`, the
  agent doesn't know it exists."* The same goes for `connector.signals` and every
  `Emit { id: … }` in `store.rs`.
- **Don't hand-roll plumbing.** Where state lives, how it is written, the window verbs,
  the roster projection and the IPC relay all belong to [`clappkit`](../../clappkit).
  Four apps copy-pasted that layer once and drifted three ways; a fix that belongs in
  the shared crate goes in the shared crate.
- **`native/` is the spec, not the build.** The SwiftUI original stays checked in as the
  behavioural reference. Read it to settle what clock *should* do. Never build it, and
  never let a change make the Rust and the Swift disagree silently — say so in the PR.
- **No silent failures.** Every dropped signal, denied command, or fallback is visible
  in an error or a log line. Fail-safe beats fail-open. A `panic!` reachable from a
  file on disk or an agent's argument is a bug, not a guard.
- **Small, coherent PRs.** One concern per PR.

## Branches

`main` holds release code. Do daily work on short branches (`feat/…`, `fix/…`,
`chore/…`) and open a PR into `main`; CI is the gate. Releases are `v*` tags, which
build one `.clapp` depot per platform the manifest claims.

## Getting started

```sh
git clone https://github.com/arfium/clock-clapp && cd clock-clapp
npm ci
npm run build                                   # the shippable binary
CLATCH_STANDALONE=1 src-tauri/target/release/clock app &   # the GUI, no launcher
src-tauri/target/release/clock list             # drive it like the agent would
npm run verify                                  # build → package → validate → round-trip
```

Prerequisites: Node 20+, a Rust toolchain, and Tauri v2's platform prerequisites
(Xcode Command Line Tools on macOS; WebKitGTK on Linux). `npm run validate` and
`npm run pack` additionally need the `clatch` binary — on `PATH`, in `$CLATCH_BIN`, or
built in a sibling `clatch` checkout.

**Run `npm run verify` before every commit.** It is the only check that the two
surfaces actually talk to each other: `clatch validate` reads the manifest and the
compiler reads the code, and neither can tell you that `clock list` reaches the
running window.

Commit messages: imperative subject, body explains *why*.

## License

Apache-2.0. By contributing you agree your contribution is licensed under the same
terms (inbound = outbound). No CLA.
