# The Clapp Protocol

The complete, frozen contract between **Clatch** (the launcher) and a **clapp** (a
Clatch app): the **manifest** (static declaration, §1) and the **control pipe**
(runtime, §2–§12). It is *not* the app's own GUI↔CLI channel — that is the app's, and
Clatch never sees it.

Design goals, in order: **safe · ordered · minimal**. Every field is one Clatch
cannot already know: no echoed id, no sequence number, no reserved-but-empty method.

## 1. The manifest — `clatch.json`

The app's static declaration, read at **install**. It is the single source for
everything Clatch knows about the app before it runs: identity, how to launch, and
the agent-facing surface.

```jsonc
{
  "manifestVersion": 1,                     // schema major
  "id": "com.example.clapp",                // reverse-DNS, path-segment safe
  "name": "Clapp",
  "description": "…",                       // library entry + context-inserted on grant
  "version": "0.1.0",
  "protocol": 1,                            // control-pipe major this app targets (§6)
  "icon": "assets/icon.png",                // optional; banner/about/tags also optional
  "launch": { "macos": "bin/clapp", "args": ["app"] },   // ≥1 per-OS command
  "connector": {                            // agent-facing surface; every field optional
    "cli": "clapp",                         // the CLI shorthand; `<cli> -h` is the manual
    "cliBin": "bin/clapp",                  // optional; default bin/<cli>
    "commands": [ { "name": "set", "about": "…" } ],    // permission grain: Bash(<cli> <name>:*)
    "signals":  [ { "id": "poke", "type": "run" } ]     // declared vocabulary, typed (§8)
  }
}
```

| field | required | rule |
|---|---|---|
| `manifestVersion` | yes | integer, `1` |
| `id` | yes | reverse-DNS, path-segment safe (no `/`, `..`) |
| `name` · `description` · `version` | yes | non-empty strings |
| `protocol` | yes | integer; the control-pipe major this app targets (§6) |
| `launch` | yes | ≥1 per-OS command (`macos`/`linux`/`windows`), optional `args` |
| `icon` · `banner` · `about` · `tags` | no | presentation (library page) |
| `connector` | no | the agent-facing surface; omit it entirely for a bare app |
| `connector.cli` | no | the CLI shorthand — declare it iff the agent should drive the app; `<cli> -h` is the whole manual |
| `connector.cliBin` | no | CLI binary path; default `bin/<cli>` |
| `connector.commands` | no | `[{name, about}]` — the permission grain + library display; NOT the manual |
| `connector.signals` | no | `[{id, type}]`, `type ∈ run \| context \| buffered` — declared and typed (§8) |

The **advertised platforms are the `launch` OS keys** (a per-OS command is the claim
"runs on that OS"). The `connector` surface is optional and independent: a
signal-only observer has no `cli`; a driveable app has one. **Additive-only within a
`manifestVersion`** — new optional fields only; a launcher ignores fields it does not
know. A breaking change bumps `manifestVersion`.

### Presentation assets — `icon` & `banner`

Optional, but when shipped they carry a fixed standard (as the agent avatar does),
checked at install for format and minimum resolution. Aspect is a design target, not
a hard check — the GUI scales every asset with `cover`, so a mismatch crops, never
letterboxes.

| | `icon` | `banner` |
|---|---|---|
| role | app mark — library tiles + the detail hero (rendered 76px) + shortcuts | the library detail **hero** strip, behind the identity text |
| format | PNG (the desktop app icon) | PNG / JPEG / WebP |
| aspect | **1:1** (square) | **215:32** (≈ 6.72:1) — design canvas `860×128` |
| min resolution | **512×512** | **3440×512** |
| max resolution | 1024×1024 | — |
| max file | 1 MiB | 2 MiB |

The banner renders as a **128px-tall, ≤860px-wide** hero, `cover`-cropped and centered,
under a **left-dark horizontal scrim** (white identity text sits over the left ~40%).
So: keep focal imagery **center/right**; match the **6.72:1** ratio (the height is
fixed — an off-ratio image loses its top/bottom); and expect the sides to crop on a
narrow window. The `icon` is just the desktop app icon — no separate asset.

## 2. Dependency & launch

A clapp **runs only under Clatch** (the Steam↔game dependency). Clatch is the
parent: it spawns the app and injects identity into the environment *before* the
app's code runs; the app connects back.

First thing in `main`, the app calls **`clatch_init(appId)`**:

- **wired** — `CLATCH_INSTANCE_TOKEN` present → continue (if `CLATCH_APP_ID != appId`,
  hard error).
- **standalone** — `CLATCH_STANDALONE=1` → continue, no launcher (dev hatch).
- **neither** → `exec clatch run <appId>` and exit.

Injected env: `CLATCH_APP_ID`, `CLATCH_INSTANCE_ID`, `CLATCH_CONTROL_ADDR`,
`CLATCH_INSTANCE_TOKEN`. No protocol version is injected — the major the app targets
is the manifest's `protocol` (§1), validated at install (§6).

## 3. Transport

Clatch is the **server**; the app connects back to `CLATCH_CONTROL_ADDR`. One
endpoint **per instance**:

- **Linux/macOS** — Unix domain socket, `~/.clatch/run/<instanceId>.sock` (dir `0700`).
- **Windows** — named pipe, `\\.\pipe\clatch-<instanceId>`.

No TCP, no port. The connection's lifetime **is** the instance's lifetime: socket
closed = instance gone (no polling, no heartbeat). Dev hatch: with no launcher, pass
the address by hand (`--control-addr <addr>` / `CLATCH_CONTROL_ADDR`) — the only
place identity is self-asserted.

## 4. Framing

Each message is a **4-byte big-endian length `N`**, then **`N` bytes of UTF-8 JSON**.

**Fail-fast.** Both ends are Clatch (its daemon writes, the binding reads), so a
malformed, zero-length, or over-`N` frame is a framing **bug**, and the stream is
already desynced (the next length can't be trusted). The reader **closes the
connection** — it never drains or skips. `N` has one sanity bound (**1 MiB**; control
messages are tiny); past it, close. There is no resync machinery. A clean
end-of-stream means the peer closed.

## 5. Envelope — JSON-RPC 2.0

Every message carries `"jsonrpc": "2.0"` and is one of:

- **request** — `id` (number) + `method` + `params`; expects a response.
- **notification** — `method` + `params`, no `id` (fire-and-forget).
- **response** — `id` + `result` | `error {code, message}`.

Ids are **per-direction**, starting at 1. Field names are **camelCase**. The stream
is ordered, so there is **no sequence number** anywhere.

## 6. Handshake

The app's first, and only, request:

```
app  → clatch:  app.register { instanceToken }
clatch → app:   { hostContext }                    // ok
            |   error { code, message }             // IDENTITY_MISMATCH
```

Register carries **only the token** — the one thing Clatch cannot already know:

- **which** instance connected — the per-instance socket says it (§3);
- **who** the app is, and **what signals** it may emit — the manifest says it (§1);
- the **protocol major** the app targets — the manifest's `protocol` says it, read at
  install (Clatch refuses to install an app whose major it does not support, so a
  running instance is compatible by construction — no runtime negotiation).

The token proves the connecting process is the one Clatch spawned (it was injected
into that child's environment, nowhere else). An app that never registers is killed
at the spawn timeout and reported as an exit.

## 7. Vocabulary

The whole surface. Adding a method is a deliberate act.

| method | direction | kind | params |
|---|---|---|---|
| `app.register` | app→clatch | request | `{instanceToken}` |
| `app.toAgent` | app→clatch | notification | `{id, type, target, payload}` |
| `app.notify` | app→clatch | notification | `{text}` |
| `app.ping` | clatch→app | request | — → `{ok:true}` |
| `app.shutdown` | clatch→app | request | — → reply, then exit |
| `app.agents` | clatch→app | notification | `{agents:[{name, backend, model?, avatar?}]}` |
| `app.toAgentRefused` | clatch→app | notification | `{id, agent, reason}` |

The app→clatch surface is **notifications only** apart from `app.register`; any other
request from the app gets an error and Clatch keeps draining, so a misbehaving app
can never wedge its own pipe. There are **no reserved methods** — an app knows its
own focus (a native window event) and its own liveness *is* the socket.

## 8. Signals — `app.toAgent`

A signal is a fire-and-forget message to the agent(s), carrying no durable state; the
agent reads real state through the app's CLI.

**The declaration is the authority.** Each signal is declared once in the manifest
`connector.signals` as `{id, type}`, `type ∈ run | context | buffered`. `id` is the
signal's stable **identifier** (e.g. `"poke"`), *not* a per-emission id — the stream
is ordered, there is no per-message counter. `app.toAgent` **stamps the declared type
onto the wire** (intent is explicit), and Clatch **re-validates** it against the
manifest: a wire `type` that disagrees, or an undeclared `id`, is **dropped
launcher-side**. So an app cannot escalate a signal at runtime, yet the wire states
its intent checkably.

| type | effect |
|---|---|
| `run` | triggers an agent turn now |
| `context` | queued, injected at the next turn boundary — in order, lossless |
| `buffered` | replaces the agent's one chat-buffer slot; rides the user's next prompt |

`target` is a list of agent **names**. Empty/omitted = fan-out to every
bound-and-uncut agent; non-empty = only those, **still intersected with the cut
matrix** (an app can never reach an agent that did not grant it). Names come from
`CLATCH_AGENT` (the caller of the app's CLI) or the `app.agents` roster (§9).

**All-or-nothing fan-out.** A `run`/`context` signal reaches **every** resolved agent
or **none**: if any receiver cannot accept it (full inbox for `run`, full context
queue for `context`), the whole emission is refused and Clatch sends
**`app.toAgentRefused {id, agent, reason}`** (`reason`: `inbox_full` | `queue_full`).
`buffered` is exempt (one replace-in-place slot, so it never refuses). Partial
fan-out is forbidden: two agents driven by one app diverge the instant one silently
misses a signal the other got.

`app.notify {text}` is a short line for the **user's Clatch chat** (distinct from the
app's own GUI) — e.g. surfacing a refusal.

## 9. Connected agents — `app.agents`

Clatch pushes the roster of agents **bound to this app** — a full snapshot, once
after register and again on every change (a bind/unbind, rename, model switch, new
avatar). The app just **replaces its view** (the ordered stream delivers snapshots in
order; there is no seq).

Each entry is `{name, backend, model?, avatar?}`, `avatar = {mime, path, width,
height}` (an absolute, same-machine path). The roster is **only this app's own bound
agents** — never other apps' agents, and never an agent's permissions, cuts, or the
other apps it is bound to (the local trust boundary). It exists so the app can pick a
`target` (§8) by name.

## 10. Lifecycle

- `app.ping` → reply `{ok:true}`.
- `app.shutdown` → reply, then exit cleanly.
- **Pipe drop = instance gone.** If the pipe closes without `app.shutdown` (EOF, or
  fail-fast on a bad frame), a **wired** app exits rather than linger as a zombie;
  standalone dev stays up (no launcher to be orphaned from).

## 11. Errors

Errors exist only for **requests** (`app.register`). Signals are fire-and-forget: a
violation (an undeclared id, a type mismatch) is **dropped**, never answered.

| code | when |
|---|---|
| `IDENTITY_MISMATCH` | register's token ≠ the injected one |
| `MALFORMED` | unparseable / schema-invalid message |

Protocol-major support is checked at **install** (from the manifest's `protocol`), not
here — a running instance is already compatible.

## 12. Security & versioning

- **Local trust boundary.** Same OS user; Clatch owns the socket directory (`0700`).
  Identity is assigned by injection; the token only proves it.
- **Signals are advisory.** The agent host decides whether to act; a buggy or hostile
  app cannot force agent turns.
- **Versioning.** The protocol major is the manifest's `protocol`, validated at
  install. Within a major, only additive change (new optional fields, new optional
  notifications); a breaking change is a new major, served alongside the old for a
  documented window so installed apps do not break on a launcher update.
