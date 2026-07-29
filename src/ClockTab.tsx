// The Clock tab (`ClockRoot.swift` → `ClockTab`): the analog face, the digital block,
// and the next-alarm line — one vertically centred column, no header bar.

import { useEffect, useState } from "react";
import { ClockFace } from "./ClockFace";
import { IconAlarm } from "./icons";
import { dateLine, hm, relative, splitTime, timeText } from "./format";
import type { Alarm } from "./bridge";

/// The earliest next fire among the ENABLED alarms — what the subtitle counts down to.
/// `nextAt` is the store's own `nextFire`, so the window and `clock list` agree.
function nextAlarm(alarms: Alarm[]): Alarm | null {
  let best: Alarm | null = null;
  for (const a of alarms) {
    if (!a.enabled || a.nextAt == null) continue;
    if (!best || a.nextAt < best.nextAt!) best = a;
  }
  return best;
}

export function ClockTab({ alarms }: { alarms: Alarm[] }) {
  const [now, setNow] = useState(() => new Date());

  // 1 Hz, re-aligned to the second boundary each tick (`TimelineView(.periodic by: 1)`).
  useEffect(() => {
    let id = 0;
    const tick = () => {
      setNow(new Date());
      id = window.setTimeout(tick, 1000 - (Date.now() % 1000));
    };
    id = window.setTimeout(tick, 1000 - (Date.now() % 1000));
    return () => clearTimeout(id);
  }, []);

  const [time, ampm] = splitTime(timeText(now));
  const next = nextAlarm(alarms);

  return (
    <div className="clock-tab">
      <ClockFace size={240} />

      <div className="digital">
        <div className="digital-time">
          <span className="big">{time}</span>
          {ampm && <span className="ampm">{ampm}</span>}
        </div>
        <div className="digital-date">{dateLine(now)}</div>
      </div>

      {next ? (
        <div className="next-alarm">
          <IconAlarm size={11} />
          <span className="tnum">{hm(next.hour, next.minute)}</span>
          <span className="dot-sep">·</span>
          <span>{relative(new Date(next.nextAt! * 1000), now)}</span>
        </div>
      ) : (
        <div className="no-alarms-line">No Alarms</div>
      )}
    </div>
  );
}
