import SwiftUI

// Apple's analog face, to its own constants. These were recovered by dlopening
// MobileTimerUI.framework and calling MTUIAnalogClockView's class methods, so the
// proportions below are literal Apple values expressed as fractions of the dial
// radius R (reference face: R = 60pt → 120×120).
//
// Four details do most of the work, and each is the opposite of the obvious guess:
//
//   • NO TICK MARKS. The face is twelve numerals on a plain disc, nothing else.
//     (Tick constants exist in the framework only for the analog STOPWATCH.)
//   • Hour and minute hands are the SAME width — Apple's constant is literally
//     named `hourMinuteHandWidth`. Plain untapered rects, no lozenge, no point.
//   • The second hand TICKS with a small overshoot-and-settle flutter. A smooth
//     sweep reads as a third-party clock immediately.
//   • Day/night flips on the DISPLAYED TIME, not the system appearance. A white
//     dial at 2pm while macOS is in dark mode is correct behavior. The second hand
//     is the one element that never inverts — it is always the accent.

struct ClockFace: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            dial(at: tl.date)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func dial(at now: Date) -> some View {
        GeometryReader { geo in
            let R = min(geo.size.width, geo.size.height) / 2
            let c = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
            let hour = c.hour ?? 0
            let minF = Double(c.minute ?? 0) + Double(c.second ?? 0) / 60
            let hrF = Double(hour % 12) + minF / 60
            let night = !(6..<18).contains(hour)
            let ink = night ? Color.white : Color.black

            // Monotonic so 59→00 steps forward instead of unwinding a full turn.
            let secDeg = now.timeIntervalSinceReferenceDate.rounded(.down) * 6

            ZStack {
                Circle().fill(night ? Palette.faceNight : Palette.faceDay)
                // Apple's dial carries no stroke because it sits on the icon's dark
                // body. Ours sits straight on the page, where a white day dial on a
                // light window (and a black night dial on a dark one) would otherwise
                // have a ~1.05:1 edge and simply vanish. The hairline disappears on
                // its own whenever the dial already contrasts.
                Circle().strokeBorder(Palette.line, lineWidth: 1)

                ForEach(1...12, id: \.self) { n in
                    let a = Double(n) / 12 * 2 * .pi
                    Text("\(n)")
                        .font(.sf(R * 0.258, .medium))
                        .foregroundStyle(ink)
                        .offset(x: sin(a) * R * 0.79, y: -cos(a) * R * 0.79)
                }

                hand(len: R * 0.528, w: R * 0.0417, tail: 0, ink, deg: hrF / 12 * 360)
                hand(len: R * 0.912, w: R * 0.0417, tail: 0, ink, deg: minF / 60 * 360)

                // The hub sits UNDER the second hand but OVER the hour/minute hands —
                // that ordering is what makes the pivot read correctly.
                Circle().fill(ink).frame(width: R * 0.10, height: R * 0.10)

                hand(len: R * 0.896, w: R * 0.0167, tail: R * 0.1167,
                     Palette.accent, deg: secDeg)
                    .animation(.interpolatingSpring(stiffness: 190, damping: 13), value: secDeg)

                Circle().fill(Palette.accent).frame(width: R * 0.05, height: R * 0.05)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// A hand pivoted at the dial centre: `len` forward (12 o'clock at 0°), `tail`
    /// back the other way. Rotation is clockwise-positive, as a clock reads.
    private func hand(len: CGFloat, w: CGFloat, tail: CGFloat,
                      _ color: Color, deg: Double) -> some View {
        Capsule()
            .fill(color)
            .frame(width: w, height: len + tail)
            .offset(y: (tail - len) / 2)
            .rotationEffect(.degrees(deg))
    }
}
