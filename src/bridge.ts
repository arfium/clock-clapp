// The webview's only door to the Rust core: `run_cmd` invokes a command against the
// shared Store; `state` events push the fresh snapshot whenever anything changes
// (a GUI action, the agent's CLI, or the scheduler firing).
//
// Both channels are clappkit's (`@clappkit`, aliased in vite.config.ts) — every clapp
// speaks the same two, and they were written out once per app. What stays here is what
// is genuinely clock's: the DTO shapes, `normalize`, and the `fired` chime event.
//
// The shapes below mirror `Store::alarm_dto` / `timer_dto` exactly. Text the CLI also
// prints (`detail`, `wakes`, `wakesShort`, `repeat`) is computed ONCE in Rust and read
// here, so the window and the terminal can never word the same alarm differently.
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export { cmd, onState, useSnapshot, agentTint } from "@clappkit";

export type Alarm = {
  id: string;
  hour: number; // 0…23
  minute: number; // 0…59
  time: string; // "07:30"
  label: string;
  note: string; // when `wake` is on, this IS the prompt the woken agent receives
  repeat: string; // "Once" | "Every day" | "Weekdays" | "Weekends" | "Mon Wed Fri"
  days: number[]; // Calendar weekdays, 1 = Sun … 7 = Sat; empty = one-shot
  enabled: boolean;
  wake: boolean; // true → alarm.fired (run); false → alarm.quiet (context)
  owner: string | null; // display name of the agent that set it (null = human/GUI)
  ownerId: string | null;
  targets: string[]; // agent IDS this alarm wakes; empty = everyone
  wakes: string; // "everyone" | "alice, bob"
  wakesShort: string; // "alice" | "alice, bob" | "alice +2" ("" when broadcast)
  detail: string; // the row's second line: "standup, Weekdays, quiet"
  nextText: string;
  nextAt: number | null; // unix seconds of the next fire (null = never / off)
};

export type Timer = {
  id: string;
  label: string;
  remaining: number; // seconds, as of the snapshot
  remainingText: string;
  total: number;
  endAt: number; // unix seconds — the ring counts against this, not the snapshot
  running: boolean;
  done: boolean;
  owner: string | null;
  ownerId: string | null;
};

/// One bound agent, mirrored from Clatch's `app.agents` roster push. A blank backend or
/// model arrives as "" / null respectively — Rust normalises it (`clappkit::AgentRow`).
export type AgentRow = {
  id: string;
  name: string;
  backend?: string;
  model?: string | null;
  avatar?: string | null;
};

/// A command envelope: `{ cmd: "alarm", when: "7:30", … }` — the one shape both the
/// window and the agent's CLI send.
export type Req = Record<string, unknown>;

export type ClockState = {
  /// `false` on a refused command; `useSnapshot` drops those and keeps the last good state.
  ok?: boolean;
  /// Monotonic, stamped by `clappkit::snapshot` — how an invoke reply that resolves after
  /// a newer pushed event is recognised as stale and discarded.
  rev?: number;
  alarms: Alarm[];
  timers: Timer[];
  agents: AgentRow[];
};

export const EMPTY: ClockState = { alarms: [], timers: [], agents: [] };

/// Fill in anything a snapshot left out, so the views never index into `undefined`.
/// (`ok: false` is already filtered upstream by `useSnapshot`.)
export function normalize(v: ClockState): ClockState {
  return {
    ...v,
    alarms: v.alarms ?? [],
    timers: v.timers ?? [],
    agents: v.agents ?? [],
  };
}

/// One alarm or timer came due. The scheduler emits this beside the signal it sends
/// Clatch: the signal wakes the agent, this is the human's cue (`ClockStore.onFire`).
export type Fired = { signal: string; payload: Record<string, unknown> };

export function onFired(cb: (f: Fired) => void): Promise<UnlistenFn> {
  return listen<Fired>("fired", (e) => cb(e.payload));
}
