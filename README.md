# clock

A shared **clock** for you and your agent — a live analog face, **alarms**, and
**timers** — and a worked example of a principle: **Clatch has no scheduler, because
a scheduler is just an app that fires signals.**

- The **agent** schedules its own timed work over the CLI: *"wake me in 10 minutes
  to re-check the build."* When it comes due, clock fires a **`run` signal** that
  starts an agent turn — the agent schedules its own future.
- The **human** sets alarms and timers in the GUI. Both edit **one shared state**
  (`ClockStore`), so an alarm the agent sets shows up in your window instantly, and
  one you set reaches the agent as an `alarm.set` signal.

clock is a **clapp** on the frozen [Clapp Protocol](docs/protocol.md) — same
two-channel wiring (GUI↔CLI socket + Clatch control pipe), with a domain of alarms
and timers and a 1-second scheduler loop.

## Why this exists (the doctrine)

From the Clatch daemon spec:

> a scheduler is any always-on app firing signals; the platform ships no
> always-on hook today.

So there is **no cron in Clatch**, and (as of Clapp v1) **no `autostart` either** —
the platform provides no always-on hook at all. A scheduler is just an app that,
*while it runs*, keeps its own timer and emits a signal when something is due. clock
is the smallest honest demonstration of that: an internal 1-second `Timer`, a
durable store, and one line — `emitSignal("alarm.fired", …)` — that turns a due
alarm into an agent turn (the signal's `run` type is fixed in the manifest).

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

## Quickstart (macOS)

```sh
npm run build

# Try it without Clatch (dev hatch): a window with a live face, alarms, and timers
CLATCH_STANDALONE=1 bin/clock app &
bin/clock timer 30s "say hello"        # a countdown (wakes the agent when it ends)
bin/clock alarm 14:30 "lunch"          # a wall-clock alarm
bin/clock alarm 7:30 "standup" --repeat weekdays \
  --note "post yesterday's diff summary to #eng"   # ← the agent's prompt when it fires
bin/clock edit a1 9:15 --note "…"      # change one; omitted flags keep their value
bin/clock list                         # see everything, with notes and who set it
bin/clock cancel t1                    # cancel by id (aN alarm · tN timer)
bin/clock --help                       # the agent's manual
```

### Install it for real (end users)

No source checkout — install from a published GitHub release:

```sh
clatch install github:arfium/clock-clapp          # latest release
clatch install github:arfium/clock-clapp@v0.1.0   # a specific version
```

(Or download `com.arfium.clock-macos-arm64.clapp` from the repo's **Releases** and
`clatch install <that file>`.) Then hand it to an agent:

```sh
clatch run com.arfium.clock
clatch agent grant <agent-name> app:com.arfium.clock
clatch agent send <agent-name> "set a timer 2 minutes from now to check on me"
```

(Dev-from-source path: `clatch install dist` after `npm run package`.)

## Keeping it running (there is no autostart)

An alarm is only useful if the app is running when it comes due — and Clapp v1
**dropped `autostart`**: the platform ships **no always-on hook**. So clock fires
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

clock persists its state to `~/.clock/clock.json` and, on the next startup, **fires
anything already overdue** (its catch-up policy) — because the platform guarantees
nothing about missed schedules; that's the app's job.

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

## Signals (typed at declaration — Clapp v1)

A signal's type is fixed in the manifest, not chosen per emission, so wake vs notify
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

## Files worth reading

- [`native/Sources/clock/ClockStore.swift`](native/Sources/clock/ClockStore.swift) —
  the shared state + scheduler + the `fire()` that emits the signal. **This is the
  whole idea.**
- [`native/Sources/clock/main.swift`](native/Sources/clock/main.swift) — the CLI
  verbs and the socket handler.
- [`native/Sources/clock/ClockRoot.swift`](native/Sources/clock/ClockRoot.swift) —
  the human's GUI: the tabbed Clock / Alarms / Timer window.
- [`native/Sources/clock/ClockFace.swift`](native/Sources/clock/ClockFace.swift) —
  the live analog face (a sweeping second hand with zero drift).
- [`AGENT.md`](AGENT.md) — how an agent operates clock.
- The transport (`ControlPipe.swift`, `IPC.swift`, `Bootstrap.swift`) is the generic
  clapp implementation, speaking the frozen [Clapp Protocol](docs/protocol.md)
  (`app.toAgent`, `app.register {instanceToken}`, fail-fast framing).
