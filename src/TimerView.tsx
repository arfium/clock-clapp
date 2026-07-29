// The Timers tab (`TimerView.swift`). No timer → a duration drum with Cancel/Start
// beneath. Running → a depleting ring with the countdown inside and two round buttons.
//
// Apple's measured constants, and where each contradicts the obvious guess:
//   • Ring stroke is 6pt at a 220pt diameter (~1:38). 9pt looks visibly heavy.
//   • The gap OPENS at 12 o'clock and sweeps clockwise — `trim(from: elapsed, to: 1)`,
//     the inverse of trimming 0→remaining.
//   • The two buttons align to the RING'S OUTER EDGES, not a cosy gap. At 220/72 that
//     leaves 76pt of air between them. The wide separation is characteristic.
//   • Cancel is NOT red and NOT tinted — neutral disc, `labelColor` label. Red is
//     reserved for real deletion.

import { useEffect, useLayoutEffect, useReducer, useRef, useState } from "react";
import type { Timer } from "./bridge";
import { duration, timeText } from "./format";
import { IconBell } from "./icons";
import { DurationWheel } from "./WheelPicker";
import { AgentTag, CircleButton, PushButton, Sheet } from "./ui";
import { AddBar, type Run } from "./AlarmsView";

const RING = 220;
const STROKE = 6;
const C = 2 * Math.PI * (RING / 2); // path circumference at r = 110 → 691.150

export function TimerView({ timers, run }: { timers: Timer[]; run: Run }) {
  const [adding, setAdding] = useState(false);

  return (
    <div className="tab">
      <AddBar title="Timers" add={timers.length === 0 ? undefined : () => setAdding(true)} />

      {timers.length === 0 ? (
        <TimerSetup run={run} />
      ) : (
        <div className="scroll">
          <div className="timer-stack">
            {timers.map((t) => (
              <TimerRing key={t.id} t={t} run={run} />
            ))}
          </div>
        </div>
      )}

      {adding && <AddTimerSheet run={run} onClose={() => setAdding(false)} />}
    </div>
  );
}

/// The setup state: the drum is the control, never a text field.
function TimerSetup({ run }: { run: Run }) {
  const [seconds, setSeconds] = useState(300);
  return (
    <div className="timer-setup">
      <DurationWheel seconds={seconds} onChange={setSeconds} />
      <div className="btn-row">
        {/* A placeholder that preserves Apple's two-button layout. Does nothing. */}
        <CircleButton label="Cancel" tone="neutral" disabled />
        <CircleButton
          label="Start"
          tone="go"
          disabled={seconds === 0}
          onClick={() => run({ cmd: "timer", seconds, label: "" })}
        />
      </div>
    </div>
  );
}

/// 20 fps, the rate `TimelineView(.animation(minimumInterval: 1/20))` redraws at.
function useTick(ms: number) {
  const [, bump] = useReducer((n: number) => n + 1, 0);
  useEffect(() => {
    const id = setInterval(bump, ms);
    return () => clearInterval(id);
  }, [ms]);
}

function TimerRing({ t, run }: { t: Timer; run: Run }) {
  useTick(50);

  // Counted against the real deadline, not the snapshot, so the ring never lags a tick.
  const remaining = t.done ? 0 : t.running ? Math.max(0, Math.ceil(t.endAt - Date.now() / 1000)) : t.remaining;
  const elapsed = t.total > 0 ? Math.max(0, Math.min(1, 1 - remaining / t.total)) : 1;
  const text = t.done ? "Timer Done" : duration(remaining);
  const owner = t.owner ?? t.ownerId;

  // 60pt is Apple's size, but "1:04:59" measures 206pt against a 208pt inner diameter —
  // so let the longest strings scale down rather than overflow the ring. Shrink the FONT
  // SIZE, not a transform: `minimumScaleFactor` re-lays-out the text, so the glyphs stay
  // crisp and hinted instead of being resampled.
  const textRef = useRef<HTMLSpanElement>(null);
  useLayoutEffect(() => {
    const el = textRef.current;
    if (!el) return;
    el.style.fontSize = ""; // back to the CSS size before measuring
    const base = parseFloat(getComputedStyle(el).fontSize) || 60;
    const w = el.scrollWidth;
    const max = RING - 48;
    if (w > max) el.style.fontSize = `${base * Math.max(0.55, max / w)}px`;
  }, [text, t.done]);

  return (
    <div className="timer">
      <div className="ring" style={{ width: RING, height: RING }}>
        <svg className="ring-svg" width={RING + STROKE} height={RING + STROKE}>
          <g transform={`translate(${(RING + STROKE) / 2} ${(RING + STROKE) / 2})`}>
            <circle
              r={RING / 2}
              fill="none"
              stroke="var(--ring-track)"
              strokeWidth={STROKE}
              strokeLinecap="round"
            />
            {/* Dropped entirely once nothing remains: `trim(from: 1, to: 1)` is an EMPTY
                path in SwiftUI, but a zero-length SVG dash with a round cap still paints
                a dot — an orange pip stuck at 12 o'clock on every finished timer. */}
            {elapsed < 1 && (
              <circle
                r={RING / 2}
                fill="none"
                stroke="var(--accent)"
                strokeWidth={STROKE}
                strokeLinecap="round"
                transform="rotate(-90)"
                strokeDasharray={`${(1 - elapsed) * C} ${C}`}
                strokeDashoffset={-elapsed * C}
              />
            )}
          </g>
        </svg>

        <div className="ring-inner">
          <div className={"countdown" + (t.done ? " done" : "")}>
            <span ref={textRef} className="tnum">
              {text}
            </span>
          </div>
          {t.label && <div className="timer-label">{t.label}</div>}
          {!t.done && (
            <div className="timer-end">
              <IconBell size={11} />
              <span className="tnum">{t.running ? timeText(new Date(t.endAt * 1000)) : "Paused"}</span>
            </div>
          )}
          {owner && <AgentTag name={owner} />}
        </div>
      </div>

      <div className="btn-row">
        <CircleButton label="Cancel" tone="neutral" onClick={() => run({ cmd: "cancel", id: t.id })} />
        {t.done ? (
          <CircleButton label="Done" tone="go" onClick={() => run({ cmd: "cancel", id: t.id })} />
        ) : t.running ? (
          <CircleButton label="Pause" tone="accent" onClick={() => run({ cmd: "pause", id: t.id })} />
        ) : (
          <CircleButton label="Resume" tone="go" onClick={() => run({ cmd: "resume", id: t.id })} />
        )}
      </div>
    </div>
  );
}

/// Note the tint difference from the alarm sheet: Save is orange, Start is green.
function AddTimerSheet({ run, onClose }: { run: Run; onClose: () => void }) {
  const [seconds, setSeconds] = useState(300);
  const start = () => {
    if (seconds === 0) return;
    run({ cmd: "timer", seconds, label: "" });
    onClose();
  };
  return (
    <Sheet open onClose={onClose} onDefault={start} className="timer-sheet">
      <div className="sheet-title">New Timer</div>
      <DurationWheel seconds={seconds} onChange={setSeconds} />
      <div className="sheet-buttons">
        <PushButton onClick={onClose}>Cancel</PushButton>
        <PushButton prominent tint="go" disabled={seconds === 0} onClick={start}>
          Start
        </PushButton>
      </div>
    </Sheet>
  );
}
