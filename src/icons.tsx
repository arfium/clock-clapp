// SF Symbols, redrawn. The Swift app names them (`clock`, `alarm`, `timer`, `plus`,
// `ellipsis`, `bell.fill`, `text.alignleft`, `chevron.up.chevron.down`, `checkmark`);
// a webview has no symbol library, so each is a hand-cut SVG at the same optical
// weight. They inherit `currentColor` and scale with the font size, like a glyph.

type P = { size?: number };

const box = (size: number) => ({
  width: size,
  height: size,
  viewBox: "0 0 16 16",
  fill: "none" as const,
  stroke: "currentColor",
  strokeWidth: 1.25,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
  "aria-hidden": true,
});

/// A thin circle with the hands at ~10:10.
export const IconClock = ({ size = 13 }: P) => (
  <svg {...box(size)}>
    <circle cx="8" cy="8" r="6.4" />
    <path d="M8 8 L5.4 6.4" />
    <path d="M8 8 L11.2 5.9" />
  </svg>
);

/// A circle with two bell "ears" at 10 and 2 o'clock, and two feet.
export const IconAlarm = ({ size = 13 }: P) => (
  <svg {...box(size)}>
    <circle cx="8" cy="8.7" r="5.6" />
    <path d="M8 5.6 V8.7 H10.2" />
    <path d="M3.9 4.4 L2.3 2.8" />
    <path d="M12.1 4.4 L13.7 2.8" />
    <path d="M4.9 13.1 L3.6 14.7" />
    <path d="M11.1 13.1 L12.4 14.7" />
  </svg>
);

/// A circle with a short stem on top and one hand pointing up-right.
export const IconTimer = ({ size = 13 }: P) => (
  <svg {...box(size)}>
    <circle cx="8" cy="9.2" r="5.6" />
    <path d="M8 3.6 V1.6" />
    <path d="M6.3 1.6 H9.7" />
    <path d="M8 9.2 L11 6.5" />
  </svg>
);

export const IconPlus = ({ size = 15 }: P) => (
  <svg {...box(size)} strokeWidth={1.5}>
    <path d="M8 3.2 V12.8" />
    <path d="M3.2 8 H12.8" />
  </svg>
);

export const IconEllipsis = ({ size = 13 }: P) => (
  <svg {...box(size)} stroke="none" fill="currentColor">
    <circle cx="3.3" cy="8" r="1.05" />
    <circle cx="8" cy="8" r="1.05" />
    <circle cx="12.7" cy="8" r="1.05" />
  </svg>
);

/// `bell.fill` — the timer ring's end line.
export const IconBell = ({ size = 11 }: P) => (
  <svg {...box(size)} stroke="none" fill="currentColor">
    <path d="M8 1.4c-2.7 0-4.3 1.9-4.3 4.6 0 2.3-.5 3.5-1.2 4.3-.45.5-.1 1.25.55 1.25h9.9c.65 0 1-.75.55-1.25-.7-.8-1.2-2-1.2-4.3 0-2.7-1.6-4.6-4.3-4.6z" />
    <path d="M6.3 12.6h3.4a1.7 1.7 0 0 1-3.4 0z" />
  </svg>
);

/// `text.alignleft` — "this alarm carries a note".
export const IconNote = ({ size = 10 }: P) => (
  <svg {...box(size)} strokeWidth={1.4}>
    <path d="M2.2 3.6 H13.8" />
    <path d="M2.2 6.5 H9.6" />
    <path d="M2.2 9.5 H13.8" />
    <path d="M2.2 12.4 H9.6" />
  </svg>
);

export const IconUpDown = ({ size = 9 }: P) => (
  <svg {...box(size)} strokeWidth={1.8}>
    <path d="M4 6.4 L8 2.4 L12 6.4" />
    <path d="M4 9.6 L8 13.6 L12 9.6" />
  </svg>
);

export const IconCheck = ({ size = 11 }: P) => (
  <svg {...box(size)} strokeWidth={1.8}>
    <path d="M2.6 8.4 L6.2 12 L13.4 4.2" />
  </svg>
);
