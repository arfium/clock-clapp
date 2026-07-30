// The window (`ClockRoot.swift`). Apple's Clock puts its tabs in a segmented control
// as the window's *principal* toolbar item — the segments ARE the title, so there is no
// title text at all. We host our own chrome, so we draw the same relationship: a
// segmented control centred at the top, nothing beside it.
//
// The selected segment is deliberately NOT orange: macOS renders segmented selection
// with `unemphasizedSelectedContentBackgroundColor`, a neutral chip.

import { useEffect, useMemo, useState, type ReactNode } from "react";
import { onFired, normalize, useSnapshot, EMPTY, type ClockState, type Req } from "./bridge";
import { AlarmsView } from "./AlarmsView";
import { armChime, playChime } from "./chime";
import { ClockTab } from "./ClockTab";
import { TimerView } from "./TimerView";
import { IconAlarm, IconClock, IconTimer } from "./icons";

type Tab = "clock" | "alarms" | "timers";

const TABS: { id: Tab; icon: ReactNode; title: string }[] = [
  { id: "clock", icon: <IconClock size={13} />, title: "Clock" },
  { id: "alarms", icon: <IconAlarm size={13} />, title: "Alarms" },
  { id: "timers", icon: <IconTimer size={13} />, title: "Timers" },
];

export default function App() {
  const [tab, setTab] = useState<Tab>("clock");

  /// Subscribe to `state`, ask for the first snapshot on mount, and discard any snapshot
  /// older than the one already held — the invoke reply and the scheduler's pushed event
  /// race every second, and the loser must not win. `run` is the one way a mutation
  /// reaches the Rust command handler; the fresh snapshot comes straight back.
  const { state, run } = useSnapshot<ClockState, Req>(EMPTY, { normalize });

  useEffect(() => {
    // Every fire rings the chime, exactly as the Swift app's `onFire()` did — the signal
    // wakes the agent, the chime is the human's cue.
    let dead = false;
    let unFired: (() => void) | undefined;
    onFired(playChime)
      .then((f) => (dead ? f() : (unFired = f)))
      .catch(() => {});
    const disarm = armChime();
    return () => {
      dead = true;
      unFired?.();
      disarm();
    };
  }, []);

  // Ascending by (hour, minute, id) — id compares as a string, like `sortAlarms()`.
  const alarms = useMemo(
    () =>
      [...state.alarms].sort(
        (a, b) => a.hour - b.hour || a.minute - b.minute || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
      ),
    [state.alarms]
  );

  return (
    <div className="root">
      <div className="tabbar">
        <div className="seg" role="tablist">
          {TABS.map((t) => (
            <button
              type="button"
              key={t.id}
              role="tab"
              aria-selected={tab === t.id}
              title={t.title}
              className={"seg-btn" + (tab === t.id ? " on" : "")}
              onClick={() => setTab(t.id)}
            >
              {t.icon}
            </button>
          ))}
        </div>
      </div>

      {tab === "clock" && <ClockTab alarms={alarms} />}
      {tab === "alarms" && <AlarmsView alarms={alarms} agents={state.agents} run={run} />}
      {tab === "timers" && <TimerView timers={state.timers} run={run} />}
    </div>
  );
}
