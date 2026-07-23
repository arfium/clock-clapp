import SwiftUI

// The drum picker — the physical way to set a time, never a text field.
//
// Apple's details (from MTACountDownPicker and the shipped loctable):
//   • Values are NOT zero-padded in the duration drum: 0, 1, 2 … 59.
//   • Unit labels are lowercase `hour`/`hours` (pluralized at 1), `min`, `sec` —
//     min and sec never pluralize. They are STATIC beside their column, pinned to
//     the selection band; they do not scroll with the rows.
//   • ONE selection band spans every column *and* its unit labels — not a band per
//     column — and the selected row keeps `labelColor`. Never tint it orange.
//   • Foreshortening is a continuous function of scroll offset with real 3D
//     X-rotation. Discrete per-row opacity steps are the classic knockoff tell.

private let ROW: CGFloat = 36
private let VISIBLE = 5                    // odd — one centred, two above/below
private let COL_H = ROW * CGFloat(VISIBLE)

struct WheelColumn: View {
    let values: [String]
    @Binding var selection: Int
    var width: CGFloat = 56

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(values.indices, id: \.self) { i in
                    Text(values[i])
                        .font(.sf(23))
                        .monospacedDigit()
                        .foregroundStyle(Palette.fg)
                        .frame(width: width, height: ROW, alignment: .center)
                        .scrollTransition(.interactive, axis: .vertical) { content, phase in
                            let v = abs(phase.value)          // 0 centred → 1 at the edge
                            return content
                                .opacity(1 - 0.7 * v)
                                .scaleEffect(1 - 0.2 * v)
                                .rotation3DEffect(.degrees(phase.value * 47),
                                                  axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                        }
                        .id(i)
                }
            }
            .scrollTargetLayout()
        }
        .frame(width: width, height: COL_H)
        .scrollIndicators(.hidden)
        .contentMargins(.vertical, (COL_H - ROW) / 2, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: Binding(get: { selection }, set: { if let v = $0 { selection = v } }))
    }
}

/// A unit label pinned beside its column, level with the selection band.
private struct Unit: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.sf(15))
            .foregroundStyle(Palette.fgDim)
            .frame(width: 44, alignment: .leading)
    }
}

/// The single band every column scrolls under.
private struct SelectionBand: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.band, style: .continuous)
            .fill(Palette.fill)
            .frame(height: ROW)
            .allowsHitTesting(false)
    }
}

/// Set a wall-clock time (locale-aware 12h/24h). Binds hour 0..23 + minute 0..59.
struct TimeWheel: View {
    @Binding var hour: Int
    @Binding var minute: Int

    private var use12h: Bool {
        (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }
    @State private var hourIdx = 0
    @State private var minIdx = 0
    @State private var pmIdx = 0

    var body: some View {
        ZStack {
            SelectionBand()
            HStack(spacing: 0) {
                if use12h {
                    WheelColumn(values: (1...12).map { "\($0)" }, selection: $hourIdx, width: 52)
                    WheelColumn(values: (0...59).map { String(format: "%02d", $0) },
                                selection: $minIdx, width: 58)
                    WheelColumn(values: ["AM", "PM"], selection: $pmIdx, width: 56)
                } else {
                    WheelColumn(values: (0...23).map { String(format: "%02d", $0) },
                                selection: $hourIdx, width: 58)
                    WheelColumn(values: (0...59).map { String(format: "%02d", $0) },
                                selection: $minIdx, width: 58)
                }
            }
        }
        .frame(height: COL_H)
        .onAppear { syncFromBinding() }
        .onChange(of: hourIdx) { recompute() }
        .onChange(of: minIdx) { recompute() }
        .onChange(of: pmIdx) { recompute() }
    }

    private func syncFromBinding() {
        minIdx = minute
        if use12h {
            hourIdx = (hour % 12 == 0 ? 12 : hour % 12) - 1
            pmIdx = hour >= 12 ? 1 : 0
        } else {
            hourIdx = hour
        }
    }
    private func recompute() {
        minute = minIdx
        if use12h {
            let base = (hourIdx + 1) % 12          // 12 → 0
            hour = pmIdx == 1 ? base + 12 : base
        } else {
            hour = hourIdx
        }
    }
}

/// Set a countdown duration. Binds total seconds. Hours / min / sec columns.
struct DurationWheel: View {
    @Binding var seconds: Int
    @State private var h = 0
    @State private var m = 0
    @State private var s = 0

    var body: some View {
        ZStack {
            SelectionBand()
            HStack(spacing: 0) {
                WheelColumn(values: (0...23).map { "\($0)" }, selection: $h, width: 44)
                Unit(text: h == 1 ? "hour" : "hours")
                WheelColumn(values: (0...59).map { "\($0)" }, selection: $m, width: 44)
                Unit(text: "min")
                WheelColumn(values: (0...59).map { "\($0)" }, selection: $s, width: 44)
                Unit(text: "sec")
            }
        }
        .frame(height: COL_H)
        .onAppear { h = seconds / 3600; m = (seconds % 3600) / 60; s = seconds % 60 }
        .onChange(of: h) { seconds = h * 3600 + m * 60 + s }
        .onChange(of: m) { seconds = h * 3600 + m * 60 + s }
        .onChange(of: s) { seconds = h * 3600 + m * 60 + s }
    }
}
