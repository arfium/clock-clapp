// The chime (`Chime.swift` + `scripts/render-chime.swift`): one soft ASCENDING marimba
// arrival — G5 → C6 → E6, a calm major triad up. The signal wakes the agent; the chime
// is the human's cue.
//
// The Swift app plays a WAV rendered once by `render-chime.swift`. That renderer is pure
// arithmetic, so this ports the SYNTHESIS rather than the file: identical partial ratios,
// gains, decays, fade-in and normalisation, evaluated straight into a WebAudio buffer. No
// asset to bundle, no dependency, and the two apps sound the same.

const DUR = 1.5; // seconds

/// One struck marimba bar: fundamental + inharmonic overtones (real marimba tuning
/// ratios 1 : 3.98 : 9.2), highs decaying fastest, ~13 ms amplitude fade-in so it never
/// clicks and never startles.
const PARTIALS: [number, number, number][] = [
  [1.0, 1.0, 0.62],
  [3.98, 0.34, 0.24],
  [9.2, 0.12, 0.12],
];

/// G5 → C6 → E6, each blooming ~0.17 s after the last (gentle overlap).
const STRIKES: [number, number, number][] = [
  [783.99, 0.0, 0.44],
  [1046.5, 0.17, 0.42],
  [1318.51, 0.34, 0.4],
];

function render(ac: AudioContext): AudioBuffer {
  const sr = ac.sampleRate;
  const n = Math.floor(sr * DUR);
  const buffer = ac.createBuffer(1, n, sr);
  const out = buffer.getChannelData(0);

  for (const [f0, start, gain] of STRIKES) {
    const s0 = Math.floor(start * sr);
    for (let i = s0; i < n; i++) {
      const t = (i - s0) / sr;
      const fadeIn = Math.min(1, t / 0.013);
      let v = 0;
      for (const [ratio, amp, decay] of PARTIALS) {
        v += Math.sin(2 * Math.PI * f0 * ratio * t) * amp * Math.exp(-t / decay);
      }
      out[i] += v * fadeIn * gain;
    }
  }

  // Normalise to ~-1 dBFS, exactly as the renderer does before writing the WAV.
  let peak = 0;
  for (let i = 0; i < n; i++) peak = Math.max(peak, Math.abs(out[i]));
  if (peak > 0) for (let i = 0; i < n; i++) out[i] = (out[i] / peak) * 0.89;

  return buffer;
}

let ctx: AudioContext | null = null;
let buffer: AudioBuffer | null = null;

function context(): AudioContext | null {
  try {
    ctx ??= new AudioContext();
    // A webview may hand back a suspended context until the window has been touched.
    if (ctx.state === "suspended") void ctx.resume();
    return ctx;
  } catch {
    return null; // no audio device — the signal still woke the agent
  }
}

/// Warm the context AT STARTUP, so an alarm that comes due before anyone has touched the
/// window is still audible — a clock that only rings after you click it is no use to the
/// human it is ringing for. The gesture listeners stay as the fallback for a webview that
/// really does hold the context suspended until it is touched.
export function armChime(): () => void {
  const unlock = () => {
    const ac = context();
    if (ac) buffer ??= render(ac);
  };
  unlock();
  window.addEventListener("pointerdown", unlock, { once: true });
  window.addEventListener("keydown", unlock, { once: true });
  return () => {
    window.removeEventListener("pointerdown", unlock);
    window.removeEventListener("keydown", unlock);
  };
}

/// `Chime.play()` — fired for every alarm and every timer that comes due.
export function playChime(): void {
  const ac = context();
  if (!ac) return;
  try {
    buffer ??= render(ac);
    const src = ac.createBufferSource();
    src.buffer = buffer;
    src.connect(ac.destination);
    src.start();
  } catch {
    /* ignore — a missing chime must never break the scheduler */
  }
}
