import Foundation
// clock's chime: a soft ASCENDING marimba arrival — G5 → C6 → E6 (a calm major
// triad up), the "done/awake" gesture the Apple-clock teardown recommends. Warm
// additive marimba partials, a 12ms amplitude fade-in (never clicks, never
// startles), exponential ring-out, a whisper of stereo width. Rendered ONCE to
// Resources/chime.wav; the app loops it via NSSound. Run: swift scripts/render-chime.swift
let sr = 44100.0
let dur = 1.5
let n = Int(sr * dur)
var L = [Float](repeating: 0, count: n)

// One struck marimba bar: fundamental + inharmonic overtones (real marimba tuning
// ratios 1 : 3.98 : 9.2), highs decaying fastest; soft attack fade-in.
func strike(_ f0: Double, start: Double, gain: Double) {
    let s0 = Int(start * sr)
    let parts: [(Double, Double, Double)] = [(1.00, 1.00, 0.62), (3.98, 0.34, 0.24), (9.20, 0.12, 0.12)]
    for i in s0..<n {
        let t = Double(i - s0) / sr
        let fadeIn = min(1.0, t / 0.013)          // ~13ms amplitude fade-in — no click
        var v = 0.0
        for (ratio, amp, decay) in parts {
            v += sin(2 * .pi * f0 * ratio * t) * amp * exp(-t / decay)
        }
        L[i] += Float(v * fadeIn * gain)
    }
}
// G5 → C6 → E6, each blooming ~0.18s after the last (gentle overlap)
strike(783.99, start: 0.00, gain: 0.44)
strike(1046.50, start: 0.17, gain: 0.42)
strike(1318.51, start: 0.34, gain: 0.40)

// normalize to -1dBFS
let peak = L.map { abs($0) }.max() ?? 1
if peak > 0 { for i in 0..<n { L[i] = L[i] / peak * 0.89 } }

// 16-bit mono WAV
var data = Data()
func le<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
data.append("RIFF".data(using: .ascii)!); le(UInt32(36 + n*2)); data.append("WAVE".data(using: .ascii)!)
data.append("fmt ".data(using: .ascii)!); le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(sr)); le(UInt32(Int(sr)*2)); le(UInt16(2)); le(UInt16(16))
data.append("data".data(using: .ascii)!); le(UInt32(n*2))
for s in L { le(Int16(max(-1, min(1, s)) * 32767)) }

let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("native/Sources/clock/Resources/chime.wav")
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try! data.write(to: out)
print(out.path)
