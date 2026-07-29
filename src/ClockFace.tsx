// Apple's analog face, at Apple's own constants (`ClockFace.swift`). Every number is a
// fraction of the dial radius R; at the 240×240 frame this app uses, R = 120.
//
// Four details do most of the work, and each is the opposite of the obvious guess:
//   • NO TICK MARKS. Twelve numerals on a plain disc, nothing else.
//   • Hour and minute hands are the SAME width (Apple's constant is literally named
//     `hourMinuteHandWidth`). Plain untapered capsules.
//   • The second hand TICKS, with an overshoot-and-settle flutter. A smooth sweep
//     reads as a third-party clock immediately.
//   • Day/night flips on the DISPLAYED TIME, not the system appearance. The second
//     hand is the one element that never inverts — it is always the accent.
//
// Time comes from `new Date()` on every animation frame, never from a counter, so the
// face cannot drift: the hands are a pure function of the local clock.

import { useEffect, useRef, useState } from "react";

const isNight = (d: Date) => d.getHours() < 6 || d.getHours() >= 18;

// `.interpolatingSpring(stiffness: 190, damping: 13)`, mass 1 — ζ = 0.47, so the hand
// overshoots each 6° step by ~18.6 % at t ≈ 0.26 s and settles by ~0.65 s.
const STIFFNESS = 190;
const DAMPING = 13;

export function ClockFace({ size = 240 }: { size?: number }) {
  const R = size / 2;
  const hourRef = useRef<SVGGElement>(null);
  const minRef = useRef<SVGGElement>(null);
  const secRef = useRef<SVGGElement>(null);
  const [night, setNight] = useState(() => isNight(new Date()));

  useEffect(() => {
    let raf = 0;
    const start = new Date();
    const base = Math.floor(start.getTime() / 1000);
    const baseDeg = start.getSeconds() * 6;
    let deg = baseDeg; // the second hand's live angle
    let vel = 0;
    let last = performance.now();
    let wasNight = isNight(start);

    const frame = (t: number) => {
      const now = new Date();
      const minF = now.getMinutes() + now.getSeconds() / 60 + now.getMilliseconds() / 60000;
      const hrF = (now.getHours() % 12) + minF / 60;

      // Monotonic, so 59 → 00 steps FORWARD instead of unwinding a full turn.
      const target = baseDeg + (Math.floor(now.getTime() / 1000) - base) * 6;
      const dt = Math.min((t - last) / 1000, 0.1);
      last = t;
      const steps = Math.max(1, Math.ceil(dt * 240)); // sub-step so the spring stays stable
      const h = dt / steps;
      for (let i = 0; i < steps; i++) {
        vel += (-STIFFNESS * (deg - target) - DAMPING * vel) * h;
        deg += vel * h;
      }

      hourRef.current?.setAttribute("transform", `rotate(${(hrF / 12) * 360})`);
      minRef.current?.setAttribute("transform", `rotate(${(minF / 60) * 360})`);
      secRef.current?.setAttribute("transform", `rotate(${deg})`);

      const n = isNight(now);
      if (n !== wasNight) {
        wasNight = n;
        setNight(n);
      }
      raf = requestAnimationFrame(frame);
    };
    raf = requestAnimationFrame(frame);
    return () => cancelAnimationFrame(raf);
  }, []);

  // A hand pivoted at the dial centre: `len` toward 12 o'clock, `tail` the other way,
  // fully rounded ends (a SwiftUI Capsule).
  const hand = (len: number, w: number, tail: number, fill: string) => (
    <rect x={-w / 2} y={-len} width={w} height={len + tail} rx={w / 2} ry={w / 2} fill={fill} />
  );

  const numeralR = R * 0.79;

  return (
    <svg
      className={"face " + (night ? "night" : "day")}
      width={size}
      height={size}
      viewBox={`0 0 ${size} ${size}`}
    >
      <g transform={`translate(${R} ${R})`}>
        <circle r={R} fill="var(--disc)" />
        {/* strokeBorder draws INSIDE the circle, so inset by half the line width. */}
        <circle r={R - 0.5} fill="none" stroke="var(--line)" strokeWidth={1} />

        {Array.from({ length: 12 }, (_, i) => {
          const n = i + 1;
          const a = (n / 12) * 2 * Math.PI;
          return (
            <text
              key={n}
              x={Math.sin(a) * numeralR}
              y={-Math.cos(a) * numeralR}
              fill="var(--ink)"
              fontSize={R * 0.258}
              fontWeight={500}
              textAnchor="middle"
              dominantBaseline="central"
            >
              {n}
            </text>
          );
        })}

        <g ref={hourRef}>{hand(R * 0.528, R * 0.0417, 0, "var(--ink)")}</g>
        <g ref={minRef}>{hand(R * 0.912, R * 0.0417, 0, "var(--ink)")}</g>

        {/* The hub sits UNDER the second hand but OVER the hour/minute hands — that
            ordering is what makes the pivot read correctly. */}
        <circle r={R * 0.05} fill="var(--ink)" />

        <g ref={secRef}>{hand(R * 0.896, R * 0.0167, R * 0.1167, "var(--accent)")}</g>
        <circle r={R * 0.025} fill="var(--accent)" />
      </g>
    </svg>
  );
}
