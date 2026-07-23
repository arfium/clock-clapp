# Contributing to clapp-template

This is a **template** — a starting point people fork into their own Clatch apps.
So the bar is: keep it minimal, keep it correct, keep it easy to fork. Small is a
feature.

## Ground rules

- **KISS.** This repo should stay a clean foundation, not grow into a framework.
  If a change makes forking harder, it probably doesn't belong here.
- **The contract is the Clatch spec.** The normative truth lives in the
  [Clatch repo](https://github.com/arfium/clatch)'s `reference/`
  (`app-developer.md`, `protocol.md`, `launch.md`, `signals.md`,
  `data-structures.md`). On conflict, the spec wins.
- **The three must agree.** `clatch.json`, `AppInfo.swift`, and the code must share
  the same app **id**, CLI **name**, and **signal** vocabulary. `clatch validate`
  checks the manifest; nothing checks that the Swift matches it — keep them in
  lockstep (see [`docs/TEMPLATE.md`](../docs/TEMPLATE.md)).
- **It must build and validate.** `swift build -c release --package-path native`
  is green, and `clatch validate dist` passes (CI runs the build).
- **No silent failures.** Every dropped signal, denied command, or fallback is
  visible in an error or the timeline. Fail-safe beats fail-open.
- **Small, coherent PRs.** One concern per PR.

## Branches (KISS variant of Clatch's model)

`main` holds release code. Do daily work on short branches (`feat/…`, `fix/…`,
`chore/…`) and open a PR into `main`; CI (a macOS `swift build`) is the gate.
Releases are `v*` tags. (Clatch itself uses a `dev → stage → main` split; a small
template doesn't need the extra rings.)

## Getting started

```sh
git clone https://github.com/arfium/clapp-template && cd clapp-template
swift build -c release --package-path native
CLATCH_STANDALONE=1 bin/clapp app &   # the GUI, without a launcher (dev hatch)
bin/clapp state                        # drive it like the agent would
npm run package                        # → dist/, ready for `clatch install`
```

Prerequisites: macOS 14+ and a Swift 5.9+ toolchain (Xcode or the Command Line
Tools). `clatch validate dist` needs the `clatch` binary from the Clatch repo.

Commit messages: imperative subject, body explains *why*.

## License

Apache-2.0. By contributing you agree your contribution is licensed under the same
terms (inbound = outbound). No CLA.
