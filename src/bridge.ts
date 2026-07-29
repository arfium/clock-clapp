// The webview's only door to the Rust core: `run_cmd` invokes a command against the
// shared Store; `state` events push the fresh snapshot whenever anything changes
// (a GUI action, the agent's CLI, or the scheduler firing).
//
// The shapes below mirror `Store::alarm_dto` / `timer_dto` exactly. Text the CLI also
// prints (`detail`, `wakes`, `wakesShort`, `repeat`) is computed ONCE in Rust and read
// here, so the window and the terminal can never word the same alarm differently.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

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

/// One bound agent, mirrored from Clatch's `app.agents` roster push.
export type AgentRow = { id: string; name: string; backend?: string; model?: string | null };

export type ClockState = { alarms: Alarm[]; timers: Timer[]; agents: AgentRow[] };

export const EMPTY: ClockState = { alarms: [], timers: [], agents: [] };

/// A refused command answers `{ ok: false, error }` — keep the last good state.
export function normalize(v: unknown): ClockState | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  if (o.ok === false) return null;
  return {
    alarms: (o.alarms as Alarm[]) ?? [],
    timers: (o.timers as Timer[]) ?? [],
    agents: (o.agents as AgentRow[]) ?? [],
  };
}

export async function cmd(req: unknown): Promise<ClockState | null> {
  return normalize(await invoke("run_cmd", { req }));
}

export function onState(cb: (s: ClockState) => void): Promise<UnlistenFn> {
  return listen<unknown>("state", (e) => {
    const s = normalize(e.payload);
    if (s) cb(s);
  });
}

/// One alarm or timer came due. The scheduler emits this beside the signal it sends
/// Clatch: the signal wakes the agent, this is the human's cue (`ClockStore.onFire`).
export type Fired = { signal: string; payload: Record<string, unknown> };

export function onFired(cb: (f: Fired) => void): Promise<UnlistenFn> {
  return listen<Fired>("fired", (e) => cb(e.payload));
}
