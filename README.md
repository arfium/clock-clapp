# clock-clapp

**A clock your agent can set.** A live face, alarms and timers, shared between a window
you look at and a CLI your agent drives. An alarm the agent sets appears in your window;
one you set can wake the agent.

## The note is the mechanism

An agent woken by an alarm starts a **fresh turn** and carries nothing from the turn that
set it. So whatever it needs to know has to travel *in the alarm*:

```sh
clock alarm 9:00 "standup" --note "re-check the build; if green, tag the release"
```

`--note` is not a memo. It is the prompt for the turn the alarm starts. The window has
the same field, which is how you hand an agent work at a time you will not be there for.

## The agent side

```sh
clock alarm 9:00 "standup" --note "…"    # --quiet to notify without waking
clock timer 10m "tea"
clock list                               # also: cancel · snooze · show · hide · close
```

`--to alice,bob` or `--to everyone` chooses who it wakes. By default an alarm wakes
**exactly whoever set it**: Clatch injects `CLATCH_AGENT_ID` into the agent's shell, clock
records that id, and targets it. Two agents keep their own alarms in one clock without
waking each other. Targets are stored by **id**, so a renamed agent keeps its alarms.

## Wake versus notify is two names

A signal's type is fixed in the manifest, never chosen per emission — so this is a
vocabulary, not a flag:

| signal | type | when |
|---|---|---|
| `alarm.fired` | `run` | a wake alarm comes due — starts an agent turn |
| `alarm.quiet` | `context` | a `--quiet` alarm — told at its next turn, not woken |
| `timer.done` | `run` | a countdown reaches zero |
| `alarm.set` | `context` | you added an alarm in the window |

## Running is not the same as having a window

A clock that stops keeping time when you close its window is not a clock, so the two
lifetimes are separate:

```sh
clock app --background   # keep time with no window and no Dock icon
clock show               # look at it
clock hide               # put it back; alarms keep running
clock close              # the only thing that stops them
```

The window's red button backgrounds the app rather than quitting it.

**Nothing starts clock for you.** Clatch has no cron, no scheduler and no app autostart —
which is the point: a scheduler is just an app that, while it runs, keeps its own timer.
An alarm only fires if the process is alive when it comes due. On startup clock fires
anything already overdue, because nothing else will.

State lives in `$CLATCH_DATA_DIR/clock.json`, so a backup captures it and `clatch purge`
cleans it. Outside Clatch: `~/.clock/clock.json`.

## My alarm did not wake the agent

A `run` signal reaches an agent that was granted the app and whose bind is run-open.
Binds are born **all-open**, `run` included — narrowing happens in the cut matrix, and
only because someone did it. Check there first. And a `--quiet` alarm is a different
signal by design: `alarm.quiet` is `context`, so it informs without waking.

## Build

```sh
npm run pack
```

`npm run verify` builds, packages, validates, and proves the window and the CLI are
talking over the socket.
