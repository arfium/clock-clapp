// Formatting, ported 1:1 from the Swift app (`ClockStore+View.swift` → `Days`/`Fmt`,
// `TimeParse.swift` → relative/compact, `AlarmsView.swift` → splitTime). Every string
// the UI shows comes from here, so the window and the CLI read the same.

// Locale-aware 12h/24h, the web equivalent of `dateFormat(fromTemplate: "j")`.
export const use12h = (() => {
  try {
    return new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" })
      .formatToParts(new Date())
      .some((p) => p.type === "dayPeriod");
  } catch {
    return true;
  }
})();

// Swift's `setLocalizedDateFormatFromTemplate("j:mm")` resolves to a 2-DIGIT hour on a
// 24-hour locale ("09:05", never "9:05") and a 1-digit one on a 12-hour locale
// ("7:30 AM"). `hour: "numeric"` alone drops that leading zero, so ask for "2-digit" off
// the clock — and pad the hour part by hand for the engines that ignore the request.
const hmFmt = new Intl.DateTimeFormat(undefined, {
  hour: use12h ? "numeric" : "2-digit",
  minute: "2-digit",
});
const dateFmt = new Intl.DateTimeFormat(undefined, { weekday: "long", day: "numeric", month: "long" });

/// ICU emits U+202F/U+00A0 before the day period; splitTime wants a plain space.
const plain = (s: string) => s.replace(/[\u202f\u00a0]/g, " ");

/// One instant → the locale's wall time. EVERY wall clock in the UI comes through here,
/// so the zero-padding rule is stated once.
function wall(d: Date): string {
  if (use12h) return plain(hmFmt.format(d));
  return plain(
    hmFmt
      .formatToParts(d)
      .map((p) => (p.type === "hour" && p.value.length < 2 ? `0${p.value}` : p.value))
      .join("")
  );
}

/// Locale-aware wall time, e.g. "7:30 AM" or "07:30" (`Fmt.hm`).
export function hm(hour: number, minute: number): string {
  const d = new Date();
  d.setHours(hour, minute, 0, 0);
  return wall(d);
}

/// The same, from an instant — the timer ring's "ends at" and the clock tab's readout.
export function timeText(d: Date): string {
  return wall(d);
}

/// "Wednesday 29 July" (en_GB) / "Wednesday, July 29" (en_US) — `EEEE d MMMM`.
export function dateLine(d: Date): string {
  return dateFmt.format(d);
}

/// "7:30 AM" → ["7:30", "AM"]; "07:30" → ["07:30", null].
export function splitTime(s: string): [string, string | null] {
  const i = s.indexOf(" ");
  return i < 0 ? [s, null] : [s.slice(0, i), s.slice(i + 1)];
}

/// Countdown display: "9:58", "1:09:58" — hours dropped under 1h (`Fmt.duration`).
export function duration(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const p2 = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${p2(m)}:${p2(sec)}` : `${m}:${p2(sec)}`;
}

/// Seconds → at most two units: "1h 5m", "58s", "2d 3h" (`TimeParse.compact`).
export function compact(seconds: number): string {
  if (seconds <= 0) return "0s";
  const units: [string, number][] = [["d", 86400], ["h", 3600], ["m", 60], ["s", 1]];
  const parts: string[] = [];
  let rem = seconds;
  for (const [name, size] of units) {
    if (parts.length >= 2) break;
    const q = Math.floor(rem / size);
    if (q > 0 || (parts.length > 0 && name === "s" && rem > 0)) {
      parts.push(`${q}${name}`);
      rem -= q * size;
    }
  }
  return parts.length === 0 ? "0s" : parts.join(" ");
}

/// "in 9h 42m" / "2m ago" / "now" (`TimeParse.relative`).
export function relative(target: Date, from: Date): string {
  const delta = Math.round((target.getTime() - from.getTime()) / 1000);
  if (delta === 0) return "now";
  const text = compact(Math.abs(delta));
  return delta > 0 ? `in ${text}` : `${text} ago`;
}

// MARK: - Repeat days (Calendar weekdays: 1 = Sun … 7 = Sat)

/// The day-pill letters. The summary text ("Weekdays", "Mon Wed Fri") is computed once
/// in Rust — `Days.summary` there — and arrives on the snapshot as `repeat`/`detail`.
export const DAY_LETTER = ["", "S", "M", "T", "W", "T", "F", "S"];
