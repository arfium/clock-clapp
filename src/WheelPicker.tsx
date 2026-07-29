// The drum picker (`WheelPicker.swift`) — the physical way to set a time, never a
// text field.
//
// Apple's details, each the opposite of the obvious guess:
//   • Values are NOT zero-padded in the duration drum: 0, 1, 2 … 59.
//   • Unit labels are lowercase `hour`/`hours` (pluralized at 1), `min`, `sec` — min
//     and sec never pluralize. They are STATIC beside their column, pinned to the
//     selection band; they do not scroll with the rows.
//   • ONE selection band spans every column *and* its unit labels — not a band per
//     column — and the selected row keeps `labelColor`. Never tint it orange.
//   • Foreshortening is a CONTINUOUS function of scroll offset with real 3D
//     X-rotation. Discrete per-row opacity steps are the classic knockoff tell.

import { useCallback, useEffect, useRef } from "react";
import { use12h } from "./format";

const ROW = 36;
const VISIBLE = 5; // odd — one centred, two above/below
export const COL_H = ROW * VISIBLE; // 180
const PAD = (COL_H - ROW) / 2; // 72 — so row 0 can reach the centre

function WheelColumn({
  values,
  index,
  onIndex,
  width,
}: {
  values: string[];
  index: number;
  onIndex: (i: number) => void;
  width: number;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const rows = useRef<(HTMLDivElement | null)[]>([]);
  const settle = useRef(0);
  const raf = useRef(0);
  const idx = useRef(index);
  idx.current = index;

  /// phase runs +1 (fully off the top) → 0 (centred) → −1 (fully off the bottom), and
  /// is recomputed from the LIVE scroll offset, so the foreshortening is continuous.
  const paint = useCallback(() => {
    const el = ref.current;
    if (!el) return;
    const centre = el.scrollTop + COL_H / 2;
    for (let i = 0; i < rows.current.length; i++) {
      const r = rows.current[i];
      if (!r) continue;
      const rowCentre = PAD + i * ROW + ROW / 2;
      const phase = Math.max(-1, Math.min(1, (centre - rowCentre) / (COL_H / 2)));
      const v = Math.abs(phase);
      r.style.opacity = String(1 - 0.7 * v);
      r.style.transform = `rotateX(${phase * 47}deg) scale(${1 - 0.2 * v})`;
    }
  }, []);

  const onScroll = () => {
    if (!raf.current) {
      raf.current = requestAnimationFrame(() => {
        raf.current = 0;
        paint();
      });
    }
    clearTimeout(settle.current);
    settle.current = window.setTimeout(() => {
      const el = ref.current;
      if (!el) return;
      const i = Math.max(0, Math.min(values.length - 1, Math.round(el.scrollTop / ROW)));
      if (i !== idx.current) onIndex(i);
    }, 90);
  };

  // Mount and every external change: park the selected row on the band.
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const want = index * ROW;
    if (Math.abs(el.scrollTop - want) > 1) el.scrollTop = want;
    paint();
  }, [index, paint]);

  useEffect(() => () => clearTimeout(settle.current), []);

  return (
    <div className="wheel-col" ref={ref} onScroll={onScroll} style={{ width, height: COL_H }}>
      <div className="wheel-pad" style={{ height: PAD }} />
      {values.map((v, i) => (
        <div
          key={i}
          className="wheel-row"
          ref={(el) => {
            rows.current[i] = el;
          }}
          style={{ height: ROW }}
          onClick={() => ref.current?.scrollTo({ top: i * ROW, behavior: "smooth" })}
        >
          {v}
        </div>
      ))}
      <div className="wheel-pad" style={{ height: PAD }} />
    </div>
  );
}

/// A unit label pinned beside its column, level with the selection band.
const Unit = ({ text }: { text: string }) => <div className="wheel-unit">{text}</div>;

const pad2 = (n: number) => String(n).padStart(2, "0");
const range = (n: number, f: (i: number) => string) => Array.from({ length: n }, (_, i) => f(i));

/// Set a wall-clock time (locale-aware 12h/24h). Binds hour 0…23 + minute 0…59.
export function TimeWheel({
  hour,
  minute,
  onChange,
}: {
  hour: number;
  minute: number;
  onChange: (hour: number, minute: number) => void;
}) {
  const pmIdx = hour >= 12 ? 1 : 0;
  const hourIdx = use12h ? (hour % 12 === 0 ? 12 : hour % 12) - 1 : hour;

  return (
    <div className="wheel" style={{ height: COL_H }}>
      <div className="wheel-band" />
      <div className="wheel-cols">
        {use12h ? (
          <>
            <WheelColumn
              values={range(12, (i) => `${i + 1}`)}
              index={hourIdx}
              width={52}
              onIndex={(i) => {
                const base = (i + 1) % 12;
                onChange(pmIdx === 1 ? base + 12 : base, minute);
              }}
            />
            <WheelColumn
              values={range(60, (i) => pad2(i))}
              index={minute}
              width={58}
              onIndex={(i) => onChange(hour, i)}
            />
            <WheelColumn
              values={["AM", "PM"]}
              index={pmIdx}
              width={56}
              onIndex={(i) => onChange((hour % 12) + (i === 1 ? 12 : 0), minute)}
            />
          </>
        ) : (
          <>
            <WheelColumn
              values={range(24, (i) => pad2(i))}
              index={hour}
              width={58}
              onIndex={(i) => onChange(i, minute)}
            />
            <WheelColumn
              values={range(60, (i) => pad2(i))}
              index={minute}
              width={58}
              onIndex={(i) => onChange(hour, i)}
            />
          </>
        )}
      </div>
    </div>
  );
}

/// Set a countdown duration. Binds total seconds. Hours / min / sec columns.
export function DurationWheel({
  seconds,
  onChange,
}: {
  seconds: number;
  onChange: (seconds: number) => void;
}) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;

  return (
    <div className="wheel" style={{ height: COL_H }}>
      <div className="wheel-band" />
      <div className="wheel-cols">
        <WheelColumn
          values={range(24, (i) => `${i}`)}
          index={h}
          width={44}
          onIndex={(i) => onChange(i * 3600 + m * 60 + s)}
        />
        <Unit text={h === 1 ? "hour" : "hours"} />
        <WheelColumn
          values={range(60, (i) => `${i}`)}
          index={m}
          width={44}
          onIndex={(i) => onChange(h * 3600 + i * 60 + s)}
        />
        <Unit text="min" />
        <WheelColumn
          values={range(60, (i) => `${i}`)}
          index={s}
          width={44}
          onIndex={(i) => onChange(h * 3600 + m * 60 + i)}
        />
        <Unit text="sec" />
      </div>
    </div>
  );
}
