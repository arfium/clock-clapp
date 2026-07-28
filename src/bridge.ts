// The webview's only door to the Rust core: `run_cmd` invokes a command against the
// shared Store; `state` events push the fresh snapshot whenever anything changes
// (a GUI action, the agent's CLI, or the scheduler firing).
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export type Alarm = {
  id: string;
  time: string;
  label: string;
  note: string;
  repeat: string;
  enabled: boolean;
  wake: boolean;
  owner: string | null;
  wakes: string;
};

export type Timer = {
  id: string;
  label: string;
  remaining: number;
  remainingText: string;
  total: number;
  running: boolean;
  done: boolean;
  owner: string | null;
};

export type ClockState = { alarms: Alarm[]; timers: Timer[] };

export async function cmd(req: unknown): Promise<ClockState> {
  return (await invoke("run_cmd", { req })) as ClockState;
}

export function onState(cb: (s: ClockState) => void): Promise<UnlistenFn> {
  return listen<ClockState>("state", (e) => cb(e.payload));
}
