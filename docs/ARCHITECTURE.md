# Architecture

How a clapp-style app is put together, and why. This is the mental model; the
normative details live in the [Clatch repo](https://github.com/arfium/clatch)'s `reference/` specs.

## The boundary (what Clatch does and does not do)

Clatch owns four things: the **launcher**, the **registry**, the **Clatch↔App
control pipe**, and the **agent host**. It is **blind to your app's insides** —
your GUI, your CLI, your state, and how they stay in sync are entirely yours. The
agent operates your app by running *your own CLI* in a shell; **Clatch is never in
that path**.

So the whole contract is three surfaces (Clapp v1):

1. **Manifest** (`clatch.json`) — how Clatch installs, launches, and describes you.
2. **Control pipe** — how you register and (optionally) signal the agent.
3. **CLI** — the agent's hands. **Mandatory**: the CLI is the clapp's constant
   surface, and `<cli> -h` is the floor even for an app the agent only observes.

Everything else in this repo is a *convenience implementation* of a good app shape,
not something Clatch requires.

## Share state, not screens

The recommended shape (and what this template implements) is **one backend, two
frontends**:

```
                    ┌─────────────────────┐
   human ──clicks──▶│      GUI            │
                    │  (ContentView.swift)│
                    └──────────┬──────────┘
                               │ same methods
                    ┌──────────▼──────────┐
                    │     AppState         │  ← single source of truth
                    │  (@MainActor model)  │     (@Published, observable)
                    └──────────▲──────────┘
                               │ same methods
                    ┌──────────┴──────────┐
   agent ──`clapp`─▶│   socket handler    │
                    │   (main.swift)      │
                    └─────────────────────┘
```

Both surfaces call the **same mutation methods** on the same `AppState`. SwiftUI
observes it, so a value the agent sets over the socket appears in the GUI
instantly, and a value the human types reaches the agent (as a signal + on its
next `clapp state`). The two can never drift because there is only one copy of the
truth.

`AppState` is `@MainActor`-isolated: every mutation happens on the UI thread. The
socket server hops to the main actor (`DispatchQueue.main.sync`) before calling in,
so agent writes and GUI writes are serialized against each other with no locks.

## Two channels — don't confuse them

A clapp speaks over **two independent sockets**. Keeping them straight is the whole
trick.

| | GUI↔CLI channel | Clatch↔App control pipe |
|---|---|---|
| file | `IPC.swift` | `ControlPipe.swift` |
| who is server | **your app** | **Clatch** |
| address | `~/.clapp/clapp.sock` (you choose) | `CLATCH_CONTROL_ADDR` (injected) |
| wire | newline-delimited JSON (yours) | JSON-RPC 2.0, 4-byte length prefix |
| carries | your commands + state | the control-pipe vocabulary — register · toAgent · notify · ping · shutdown · agents · toAgentRefused (table below) |
| Clatch sees it? | **no** (private to your app) | **yes** (Clatch owns it) |

The agent's CLI (`clapp set …`) travels the **left** channel — Clatch never sees
it. Your app's **notices to the agent** (`app.toAgent`) travel the **right**
channel — Clatch routes them.

### The GUI↔CLI channel (yours)

A Unix-domain socket: a filesystem object under a `0700` dir, `0600` socket,
reachable only by the owning user, never on the network. `clapp app` binds it;
`clapp <verb>` connects. The message shape is whatever you put in `Protocol.swift`.

Because the agent's shell is often **sandboxed**, the CLI distinguishes connect
failures (see `IPCError`): `ENOENT`/`ECONNREFUSED` → *"app is not running; start it
with `clatch run <id>`"*; `EPERM`/`EACCES` → *"blocked by the sandbox; retry with
escalated permissions."* Misdiagnosing the second as the first sends the agent to
relaunch a perfectly healthy app.

### The control pipe (Clatch's)

At launch Clatch injects identity into your environment and listens on a pipe. Your
app connects back and identifies itself:

```
CLATCH_APP_ID           com.example.clapp        (must match AppInfo.id)
CLATCH_CONTROL_ADDR     /…/run/<instanceId>.sock (where to connect back)
CLATCH_INSTANCE_ID      this launch's id
CLATCH_INSTANCE_TOKEN   proves this is really us
CLATCH_PROTOCOL_VERSION 1
```

Then: send `app.register` — just `{instanceToken}`. The per-instance socket already
tells Clatch *which* instance you are, and the token proves you are the process it
spawned; your id, your signal list, and the protocol major you target are all in the
manifest (Clatch read it at install), so register carries none of them. Clatch
**requires** a successful register — the control socket's lifetime *is* the instance's
liveness (socket closed = app gone, no polling). After that you just answer `app.ping`
and exit on `app.shutdown`.

Clatch also **pushes** `app.agents` — a full snapshot of the agents bound to your
app (**id**, name, backend, model, avatar), once after register and again on every
change. `ControlPipe.swift` replaces its view each time (the ordered stream delivers
them in order) and hands it to an optional `onAgents` callback; it is the roster for
targeting a *chosen* agent and mapping its **id → display name**. The `id` is the
immutable wire key; the `name` is a re-pointable label (same id + new name = the same
agent) — key on the id, show the name; targeting by name is a bug. The demo leaves
`onAgents` unset — it targets the caller via `CLATCH_AGENT_ID`, below.

The reader is **fail-fast** (protocol.md § Framing): both ends of this pipe are
Clatch (its daemon writes, this binding reads), so a malformed or absurdly-sized
frame is a framing *bug*, and the stream is already desynced (the next length can't
be trusted). `ControlPipe.readMessage()` surfaces it by closing the connection, not
by skipping the frame — hiding a bug is worse than ending on it. There is no
resync/drain machinery, because on this pipe there is no lossy or hostile wire to
recover from. When the pipe ends (that bug, or Clatch itself gone), a **wired** app
exits — socket-close *is* "instance gone" (protocol.md), so lingering would only
leave a zombie GUI; standalone dev stays up (no launcher to be orphaned from).

#### The vocabulary (the whole surface)

This is the entire control pipe — `ControlPipe.swift` implements all of it. Every
field is one Clatch cannot already know: no echoed id, no sequence number, no
reserved-but-empty method.

| method | direction | kind | params | meaning |
|---|---|---|---|---|
| `app.register` | app→clatch | request | `{instanceToken}` | handshake — the first frame; success gates "running" |
| `app.toAgent` | app→clatch | notify | `{id, type, target, payload}` | send a **declared** signal to the agent(s); `type` is stamped from the declaration |
| `app.notify` | app→clatch | notify | `{text}` | a short line for the **user's** Clatch chat (not your GUI) |
| `app.ping` | clatch→app | request | — | health probe; reply `{ok:true}` |
| `app.shutdown` | clatch→app | request | — | graceful stop; reply, then exit |
| `app.agents` | clatch→app | notify | `{agents:[{id, name, backend, model?, avatar?}]}` | roster of **this app's** bound agents (id = wire key, name = label); replace-in-place |
| `app.toAgentRefused` | clatch→app | notify | `{id, agent, reason}` | an all-or-nothing fan-out was refused whole; `agent` = the refusing **agent id** (`reason`: `inbox_full`\|`queue_full`) |

The app→clatch surface is **notifications only** apart from the one `app.register`
request, so a misbehaving app can never wedge its own pipe with an unread request
queue. There are no reserved methods: an app knows its own focus (a native window
event) and its own liveness *is* the socket, so `focusChanged`/`heartbeat` never
existed here.

## The bootstrap: run only under Clatch

`main.swift` calls `clatchInit(appId:)` first thing in `app` mode — the Steam
`RestartAppIfNecessary` equivalent (`Bootstrap.swift`):

- **wired** (`CLATCH_INSTANCE_TOKEN` present) → continue; register next. A mismatched
  `CLATCH_APP_ID` is a hard error.
- **standalone** (`CLATCH_STANDALONE=1`) → continue with no launcher (the dev hatch).
- **neither** → `exec clatch run <appId>` and exit; Clatch relaunches the *installed*
  copy properly.

That is what makes a bare double-click route back through Clatch, exactly like a
Steam game. The launch command must never scrub `CLATCH_*` from the environment, or
the loop guard breaks.

## Signals: your app's notices to the agent

A signal is a **fire-and-forget** notice that carries no durable state — the agent
reads the real state through the CLI. You **declare** every signal in `clatch.json`
(`connector.signals`) as `{ "id", "type" }`. The wire (`app.toAgent`) is `{id, type,
target, payload}`: `emitSignal(id, …)` **stamps the declared type on** (from
`AppInfo.signals`), so intent is explicit — but the **declaration stays the
authority**. Clatch re-validates the wire `type` against the manifest and **drops**
a signal whose type disagrees, or whose `id` was never declared. So intent is
readable on the wire, yet an app still can't escalate a signal at runtime: a
mismatch is dropped, not honored. (`id` is the signal's stable identifier, not a
per-emission number — the stream is ordered.)

| declared type | effect | use it for |
|---|---|---|
| **`run`** | **triggers an agent turn now** (wakes it) | the user did something the agent must act on |
| **`context`** | queued **in order, lossless**, injected at the agent's next turn | a state-changing action the agent should know about |
| **`buffered`** | updates the agent's visible **chat buffer** (one slot, latest wins); rides the **user's next prompt** | a *position* (selection, open file) the user may want to talk about |

The chat buffer is worth knowing even though this template doesn't emit one: a
`buffered` signal never enters the timeline on its own. It appears as a
source-labeled strip above the user's composer and is cleared three ways — the
user's ✕, a newer `buffered` signal replacing it, or the user sending a prompt
(Clatch prepends the buffer to the prompt as one recorded input). It also clears
when your app exits; queued `context` survives your exit (an action that
happened, happened).

This template fires both built types: editing the message or count emits
`changed` (declared `context`) — the agent learns *what the human did* on its
next turn — and the **"Wake agent"** button emits `poke` (declared `run`) — an
immediate turn. Only **user** actions signal; the agent already knows about its
own writes.

Whether a `run` signal actually wakes an agent depends on the **cut matrix**: the
target agent must be **granted** the app (hold a bind) and that bind must be
**run-open**. Note: when an app already has one run-open bind, a *new* bind to
another agent is born **run-cut** — the user opens run deliberately. If a signal
seems to vanish, that is almost always why.

**Fan-out is all-or-nothing** (signals.md, 2026-07-19). Once the cut matrix and any
`target` resolve the receiving set, a `run`/`context` signal reaches **every** agent
in it or **none**: before delivering, the daemon checks each receiver has room (an
inbox slot for `run`, context-queue room for `context`), and if any one can't, the
whole emission is refused and nothing is delivered. This is deliberate — two agents
driven by one app diverge the instant one silently misses a signal the other got,
and that divergence is unrecoverable. (`buffered` is exempt: one replace-in-place
slot per agent, so it can never refuse.)

A refusal is **reported back.** If the fan-out is refused, Clatch sends
`app.toAgentRefused { id, agent, reason }` — the refused signal's id, the first
blocking agent's **id**, and `reason` (`inbox_full` for a `run` target, `queue_full`
for a `context` one). `ControlPipe` hands it to `onSignalRefused`; this template's handler
tells the human over `app.notify` (a line in their Clatch chat), so a full-inbox
agent doesn't read as a dead button. Either way a fan-out lands **whole**, or you
learn **which signal didn't** — never a silent partial delivery.

## Targeting: which agent(s) a signal reaches

By default a signal **broadcasts** — it fans out to every agent granted the app
(that the cut matrix passes). A signal may instead **target** specific agents by
**id**: `emitSignal(…, target: ["1753460000"], …)`. Empty `target` (the default) is
the broadcast; a non-empty target is *still* intersected with the cut matrix, so you
can never reach an agent that didn't grant you — targeting narrows the fan-out, it
never widens it. Target **ids, never names**: an agent's `name` is a re-pointable
label, its `id` is the stable wire key (protocol.md §9).

The app can target precisely because **it knows who invoked its CLI**: Clatch injects
`CLATCH_AGENT_ID=<id>` (the caller agent's immutable id) into every agent's CLI shell,
so the CLI client forwards that id to the app (`Request.agent` → `AppState.lastAgent`).
From there an app can wake the caller, a chosen other agent, a set, or everyone — and
because it's an id, it stays valid even if that agent is later renamed.

clapp's own signals are **user-origin** (a GUI edit, the Wake-agent button) — a
human has no `CLATCH_AGENT_ID`, so they broadcast; that is correct. The pattern shows
its value when a signal is *deferred* and *owned*: the **clock** example records the
`CLATCH_AGENT_ID` of whoever set an alarm and, when it fires, wakes **exactly that
agent** — the same code, one filled-in `target`.

## Always-on apps (schedulers, observers, the clock app)

Clatch has **no cron and no scheduler** — deliberately. From the daemon spec:

> a scheduler is any always-on app firing signals; the platform ships no
> always-on hook today.

And as of Clapp v1 there is **no `autostart` either** — it was removed. So a
timer/alarm/observer app is just a normal clapp that, **while it is running**:

1. keeps its **own internal timer loop** going between user actions;
2. **emits a signal declared `run` when its timer fires**, waking the granted agent.

The platform will *not* keep it alive for you: nothing launches it at boot, so it
fires only while open (design your app to be a small always-on-top window if that
matters). Missed-schedule catch-up, persistence, and reliability are the app's own
policy. The **clock** example app is exactly this pattern, and the smallest thing you
can add on top of this template to get there is: a store of alarms, a `Timer` that
checks them, and `emitSignal("alarm.fired", …)` with `alarm.fired` declared `run` in
`connector.signals`.

## Where each concern lives (file map)

| Concern | File | Reusable as-is? |
|---|---|---|
| App identity (id, cli, signals) | `AppInfo.swift` | **edit when forking** |
| Run-only-under-Clatch bootstrap | `Bootstrap.swift` | yes |
| Control pipe (register/signal/ping/shutdown) | `ControlPipe.swift` | yes |
| GUI↔CLI socket transport | `IPC.swift` | yes |
| Clatch design system (tokens + atoms + fonts) | `Theme.swift`, `Resources/fonts/` | yes |
| Your wire shape (Request/Response/State) | `Protocol.swift` | **replace** |
| Your shared state (the backend) | `AppState.swift` | **replace** |
| Your GUI (the human's face) | `ContentView.swift` | **replace** (using `Theme.swift`) |
| Dispatch + app delegate + CLI parsing | `main.swift` | **adapt verbs** |

## The look: the Clatch design system

`Theme.swift` ports the launcher's own `design.css` (Clatch's Tauri GUI) into
SwiftUI so a forked app is on-brand for free. It gives you the tokens — `Palette`
(the dark "space" ground + the volt `#e1ff00` Phosphor accent), `Radius`, `Space` — the
Plus Jakarta Sans typeface (bundled, registered at launch by `Fonts.register()`),
and reusable atoms: `Panel`, `Eyebrow`, `Badge`, `VoltButtonStyle`,
`GhostButtonStyle`, `ClatchFieldStyle`. Build your `ContentView` from these rather
than raw SwiftUI defaults, and set the window to the dark appearance
(`main.swift` does this: `.darkAqua` + `Palette.nsBg`). It carries verbatim; edit
the palette only if your app deliberately diverges from Clatch.
