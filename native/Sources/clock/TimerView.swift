import SwiftUI

// The Timers tab. No timer → a duration drum with Cancel/Start beneath. Running →
// a depleting ring with the countdown inside and two round buttons under it.
//
// Apple's measured constants, and where each contradicts the obvious guess:
//   • Ring stroke is 6pt at a 220pt diameter (~1:38). 9pt looks visibly heavy.
//   • The gap OPENS at 12 o'clock and sweeps clockwise — `trim(from: elapsed, to: 1)`,
//     the inverse of trimming 0→remaining.
//   • The two buttons align to the RING'S OUTER EDGES, not a cosy gap. At 220/72
//     that leaves 76pt of air between them. The wide separation is characteristic.
//   • Cancel is NOT red and NOT tinted — neutral disc, `labelColor` label. Red is
//     reserved for real deletion. Every other button matches its label to its disc.

private let RING: CGFloat = 220
private let STROKE: CGFloat = 6
private let BTN: CGFloat = 72

struct TimerView: View {
    @ObservedObject var store: ClockStore
    @State private var adding = false

    var body: some View {
        Group {
            if store.timers.isEmpty {
                TimerSetup(store: store)
            } else {
                ScrollView {
                    VStack(spacing: Space.s6) {
                        ForEach(store.timers) { t in TimerRing(store: store, id: t.id) }
                    }
                    .padding(.vertical, Space.s5)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg)
        .safeAreaInset(edge: .top, spacing: 0) {
            AddBar(title: "Timers", add: store.timers.isEmpty ? nil : { adding = true })
        }
        .sheet(isPresented: $adding) { AddTimerSheet(store: store) }
    }
}

/// The setup state: the drum is the control, never a text field.
struct TimerSetup: View {
    @ObservedObject var store: ClockStore
    @State private var seconds = 300
    var onStart: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.s6) {
            Spacer(minLength: 0)
            DurationWheel(seconds: $seconds)
            HStack {
                Button("Cancel") {}
                    .buttonStyle(CircleButtonStyle(tint: Palette.fill, label: Palette.fg, diameter: BTN))
                    .disabled(true)
                Spacer()
                Button("Start") { start() }
                    .buttonStyle(CircleButtonStyle(tint: Palette.go, diameter: BTN))
                    .disabled(seconds == 0)
            }
            .frame(width: RING)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func start() {
        store.addTimer(seconds: seconds, label: "", by: .user)
        onStart?()
    }
}

struct TimerRing: View {
    @ObservedObject var store: ClockStore
    let id: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
            content(store.timers.first { $0.id == id }, now: tl.date)
        }
    }

    @ViewBuilder
    private func content(_ t: ClockStore.Countdown?, now: Date) -> some View {
        if let t {
            let remaining = t.remaining(now)
            let elapsed = t.total > 0 ? max(0, min(1, 1 - Double(remaining) / Double(t.total))) : 1
            VStack(spacing: Space.s5) {
                ZStack {
                    Circle().stroke(Palette.ringTrack,
                                    style: StrokeStyle(lineWidth: STROKE, lineCap: .round))
                    Circle().trim(from: elapsed, to: 1)
                        .stroke(Palette.accent,
                                style: StrokeStyle(lineWidth: STROKE, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: Space.s1) {
                        // 60pt is Apple's size, but "1:04:59" measures 206pt against a
                        // 208pt inner diameter — so let the longest strings scale down
                        // rather than overflow the ring.
                        Text(t.done ? "Timer Done" : Fmt.duration(remaining))
                            .font(.sf(t.done ? 26 : 60, .light))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .foregroundStyle(Palette.fg)
                            .padding(.horizontal, Space.s5)

                        if !t.label.isEmpty {
                            Text(t.label).font(.sf(13)).foregroundStyle(Palette.fgDim)
                        }
                        if !t.done {
                            HStack(spacing: 4) {
                                Image(systemName: "bell.fill").font(.sf(11))
                                Text(t.isRunning ? endText(t) : "Paused").monospacedDigit()
                            }
                            .font(.sf(13)).foregroundStyle(Palette.fgDim)
                        }
                        if let owner = t.agentName { AgentTag(owner) }
                    }
                }
                .frame(width: RING, height: RING)

                HStack {
                    Button("Cancel") { store.cancel(id: t.id) }
                        .buttonStyle(CircleButtonStyle(tint: Palette.fill,
                                                       label: Palette.fg, diameter: BTN))
                    Spacer()
                    if t.done {
                        Button("Done") { store.cancel(id: t.id) }
                            .buttonStyle(CircleButtonStyle(tint: Palette.go, diameter: BTN))
                    } else if t.isRunning {
                        Button("Pause") { store.pauseTimer(id: t.id) }
                            .buttonStyle(CircleButtonStyle(tint: Palette.accent, diameter: BTN))
                    } else {
                        Button("Resume") { store.resumeTimer(id: t.id) }
                            .buttonStyle(CircleButtonStyle(tint: Palette.go, diameter: BTN))
                    }
                }
                .frame(width: RING)
            }
        }
    }

    private func endText(_ t: ClockStore.Countdown) -> String {
        let f = DateFormatter(); f.locale = .current
        f.setLocalizedDateFormatFromTemplate("j:mm")
        return f.string(from: t.endAt)
    }
}

struct AddTimerSheet: View {
    @ObservedObject var store: ClockStore
    @Environment(\.dismiss) private var dismiss
    @State private var seconds = 300

    var body: some View {
        VStack(spacing: Space.s5) {
            Text("New Timer").font(.sf(15, .semibold)).foregroundStyle(Palette.fg)
            DurationWheel(seconds: $seconds)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start") {
                    store.addTimer(seconds: seconds, label: "", by: .user)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.go)
                .keyboardShortcut(.defaultAction)
                .disabled(seconds == 0)
            }
        }
        .padding(Space.s5)
        .frame(width: 420)
        .background(Palette.bg)
    }
}
