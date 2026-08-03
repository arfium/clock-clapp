# clock

A shared **clock** for you and your agent — a live analog face, **alarms**, and
**timers** — and a worked example of a principle: **Clatch has no scheduler, because
a scheduler is just an app that fires signals.**

- The **agent** schedules its own timed work over the CLI: *"wake me in 10 minutes
  to re-check the build."* When it comes due, clock fires a **`run` signal** that
  starts an agent turn — the agent schedules its own future.
- The **human** sets alarms and timers in the GUI. Both edit **one shared state**
  (`Store`), so an alarm the agent sets shows up in your window instantly, and
  one you set reaches the agent as an `alarm.set` signal.

clock is a **clapp** on the frozen [Clapp Protocol](clappkit/docs/protocol.md) — same
two-channel wiring (GUI↔CLI socket + Clatch control pipe), with a domain of alarms
and timers and a 1-second scheduler loop.

## Why this exists (the doctrine)

From the Clatch daemon spec:

> a scheduler is any always-on app firing signals; the platform ships no
> always-on hook today.

So there is **no cron in Clatch**, and **no `autostart` either** —
the platform provides no always-on hook at all. A scheduler is just an app that,
*while it runs*, keeps its own timer and emits a signal when something is due. clock
is the smallest honest demonstration of that: an internal 1-second tick, a durable
store, and one line — `Emit { id: "alarm.fired", … }` — that turns a due alarm into an
agent turn (the signal's `run` type is fixed in the manifest).

## The agent loop it enables

```
agent: clock alarm 9:00 "standup" --note "re-check the build; if green, tag the release"
        └─ the turn ends; hours pass (clock stays alive, the agent does not) ─┐
                                                                               ▼
clock:  ⏰ due → emit alarm.fired [run] {note: "re-check the build…"}
                                        ──▶  Clatch wakes the agent for a turn
agent:  (woken, with no memory of setting it) → the note IS the prompt → does the work
```

This is the same shape as a human setting a reminder — except the reminder wakes an
*agent*, and the agent set it for *itself*.

**The note is the mechanism.** A woken agent starts a fresh turn carrying nothing
from the turn that set the alarm, so whatever it needs to know has to travel *in the
alarm*. That's what `--note` is: not a memo, but the prompt for the turn the alarm
starts. The human writes notes too — in the GUI's Note field — which is how you hand
an agent work at a future time without being there when it happens.

## Quickstart

Prerequisites: Node 20+, a Rust toolchain, and the platform's Tauri v2 prerequisites
(Xcode CLT on macOS; WebKitGTK on Linux; nothing extra on Windows).

```sh
npm ci
npm run build          # → src-tauri/target/release/clock (the frontend EMBEDDED)
CLI=src-tauri/target/release/clock

# Try it without Clatch (dev hatch): a window with a live face, alarms, and timers
CLATCH_STANDALONE=1 $CLI app &
$CLI timer 30s "say hello"        # a countdown (wakes the agent when it ends)
$CLI alarm 14:30 "lunch"          # a wall-clock alarm
$CLI alarm 7:30 "standup" --repeat weekdays \
  --note "post yesterday's diff summary to #eng"   # ← the agent's prompt when it fires
$CLI edit a1 9:15 --note "…"      # change one; omitted flags keep their value
$CLI list                         # see everything, with notes and who set it
$CLI cancel t1                    # cancel by id (aN alarm · tN timer)
$CLI --help                       # the agent's manual
$CLI close                        # the one thing that stops the alarms
```

Build it with `npm run build`, not a bare `cargo build --release`: Tauri's
`custom-protocol` feature is turned on by the Tauri CLI, and without it the binary
points its webview at the dev server instead of the frontend embedded in the
executable — a shipped app that opens a white window. `scripts/package.sh` asserts the
bundle really is embedded, so that cannot ship by accident.

### Install it for real (end users)

No source checkout — install from a published GitHub release:

```sh
clatch install github:arfium/clock-clapp          # latest release
clatch install github:arfium/clock-clapp@v0.2.0   # a specific version
```

(Or download `com.arfium.clock-macos-arm64.clapp` from the repo's **Releases** and
`clatch install <that file>`.) Then hand it to an agent:

```sh
clatch run com.arfium.clock
clatch agent grant <agent-name> app:com.arfium.clock
clatch agent send <agent-name> "set a timer 2 minutes from now to check on me"
```

(Dev-from-source path: `clatch install pkg` after `npm run package`. The depot is
`pkg/` — `dist/` belongs to Vite.)

## Keeping it running (there is no autostart)

An alarm is only useful if the app is running when it comes due — and the Clapp
Protocol has **no `autostart`**: the platform ships **no always-on hook**. So clock fires
only *while the process is alive*. If a scheduler needs to survive reboots, that is
the app's own concern today, not a platform mechanic.

**Running is not the same as having a window.** A clock that stops keeping time when
you close its window isn't a clock, so the two lifetimes are separate:

```sh
clock app --background   # start with no window and no Dock icon — just the scheduler
clock show               # bring up the window when you want to look at it
clock hide               # put it back in the background; alarms keep running
clock close              # the ONLY thing that stops the alarms
```

Closing the window with its red button backgrounds the app rather than quitting it.
This is what lets an agent set an alarm without taking over the screen: it schedules
its work, the app keeps time invisibly, and the window only appears if someone asks
for it.

clock persists its state to `$CLATCH_DATA_DIR/clock.json` — the directory Clatch gives
the instance, so a backup captures it and `clatch purge` cleans it. Outside Clatch it
falls back to `~/.clock/clock.json` (`%LOCALAPPDATA%\clock\clock.json` on Windows). On
the next startup it **fires anything already overdue** (its catch-up policy) — because
the platform guarantees nothing about missed schedules; that's the app's job.

## Why isn't my alarm waking the agent?

A `run` signal only starts a turn if the target agent is **granted** the app *and*
that grant is **run-open**. Clatch is deliberate here: when an app already has one
run-open bind, a **new** grant to another agent is born **run-cut**, so the user
opens run on purpose. If a wake alarm never starts a turn, open run on that agent's
bind — or check it isn't cut. (A `--quiet` alarm is a *different signal*,
`alarm.quiet`, declared `context` by design: notify, don't wake.)

## Which agent(s) an alarm wakes

By default an alarm or timer wakes **exactly the agent who set it**: when an agent runs
`clock alarm …`, Clatch has injected `CLATCH_AGENT_ID=<id>` (the agent's immutable id)
into its CLI shell, and clock records that id. When it fires it **targets that agent by
id** — the other granted agents get nothing, so two agents keep their own alarms in one
clock without waking each other.

You can also **choose** who an alarm wakes — in the GUI's *Wake which* picker, or with
`--to alice,bob` / `--to everyone` on the CLI. A name you type is resolved to the agent's
**id** (the wire key) and stored as an id; `clock list` resolves it back to `→ <name>`
for display. An alarm set in the GUI with no choice broadcasts to every granted agent.
Because targets are stored by id, a **renamed agent keeps its alarms** — same id, new
label.

This is the launcher spec's own example of targeting made real: *"a scheduler records
the `CLATCH_AGENT_ID` of whoever set an alarm and, when it fires, targets exactly that
agent."*

## Signals (typed at declaration)

A signal's type is fixed in `clatch.json`, not chosen per emission, so wake vs notify
is two **names**, not a mode:

| signal | type | when | target |
|---|---|---|---|
| `alarm.fired` | **`run`** | a *wake* alarm comes due — starts an agent turn | the agent who set it; broadcast if GUI-set |
| `alarm.quiet` | **`context`** | a `--quiet` alarm comes due — notify, no turn | the agent who set it; broadcast if GUI-set |
| `timer.done`  | **`run`** | a countdown reaches zero — starts an agent turn | the agent who set it; broadcast if GUI-set |
| `alarm.set`   | **`context`** | the **human** adds an alarm in the GUI | broadcast (every granted agent learns of it) |

The emitted envelope carries only `name` + `seq` + `payload` + `target`. The agent
setting its own alarm emits no signal — it already knows.

The alarm payload carries `note` when one is set — the instruction the woken agent
acts on. Both `alarm.fired` and `alarm.quiet` include it; the **signal name** is what
decides whether to act on it now or merely absorb it.

## How it is built

clock is **Rust + [Tauri v2](https://tauri.app)** on the shared **`clappkit`** crate:
one binary with two roles. `clock app` is the GUI process Clatch launches — the window,
the 1-second scheduler, the control pipe, and the IPC server. `clock <verb>` is the
agent's CLI client, which talks to that process over the app's own private socket
(a Windows named pipe there). The same binary, dispatched on `argv[1]`.

It began as a macOS SwiftUI app, and **that original is still in the repo** under
[`native/`](native/Sources/clock/) — not as the build, but as the behavioural spec. When
a question comes up about *what clock should do*, `ClockStore.swift` is the answer;
`src-tauri/src/store.rs` is a deliberate 1:1 port of it, down to the on-disk format, so
an existing `~/.clock/clock.json` written by the Swift app still loads.

```
src-tauri/src/store.rs   the whole app: alarms, timers, the scheduler tick, and the ONE
                         `handle` both surfaces call. Pure and sync — it RETURNS the
                         signals to send rather than sending them. Start here.
src-tauri/src/app.rs     the Tauri process: window lifetime, the scheduler task, the
                         GUI↔CLI relay. Thin — the generic parts are clappkit::app.
src-tauri/src/cli.rs     the agent's CLI. `HELP` is the agent's only manual.
src/                     the React window: the analog face, the alarm sheet, the timer
                         ring. Its channels come from `@clappkit`.
clatch.json              the manifest: id, launch, the declared verbs and signals.
```

The plumbing is nobody's business but clappkit's — the control pipe (`app.toAgent`,
`app.register {instanceToken}`, fail-fast framing), the private IPC transport, the
data-dir resolver, the atomic store writer, the window verbs, and the roster
projection. All of it speaks the frozen [Clapp Protocol](clappkit/docs/protocol.md).

## Files worth reading

- [`src-tauri/src/store.rs`](src-tauri/src/store.rs) — the shared state + scheduler +
  the `tick()` that turns a due alarm into a signal. **This is the whole idea.**
- [`native/Sources/clock/ClockStore.swift`](native/Sources/clock/ClockStore.swift) —
  the Swift original the above is a port of; the behavioural reference.
- [`AGENTS.md`](AGENTS.md) — how an agent operates clock.
- [`clappkit/docs/ARCHITECTURE.md`](clappkit/docs/ARCHITECTURE.md) — the clapp model in general.
- [`clappkit/docs/ICONS.md`](clappkit/docs/ICONS.md) · [`clappkit/docs/PLAYBOOK.md`](clappkit/docs/PLAYBOOK.md) — the house
  standards this app is held to.
