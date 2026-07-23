import SwiftUI

// The window. Apple's Clock puts its tabs in an NSToolbarItemGroup segmented
// control as the window's *principal* item — the segments ARE the title, so there
// is no title text at all. We host our own chrome, so we draw the same
// relationship: a real segmented Picker centred at the top, nothing beside it.
//
// The selected segment is deliberately NOT orange. macOS renders segmented
// selection with `unemphasizedSelectedContentBackgroundColor` (a neutral chip) and
// NSSegmentedControl ignores accent tint outright — so using the stock control is
// both the authentic Mac look and less code than faking it.

struct ClockRoot: View {
    @ObservedObject var store: ClockStore
    @State private var tab: Tab = .clock
    enum Tab: String, CaseIterable { case clock, alarms, timers }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Image(systemName: "clock").tag(Tab.clock)
                Image(systemName: "alarm").tag(Tab.alarms)
                Image(systemName: "timer").tag(Tab.timers)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .padding(.vertical, Space.s2)
            .frame(maxWidth: .infinity)
            .background(Palette.bg)

            switch tab {
            case .clock: ClockTab(store: store)
            case .alarms: AlarmsView(store: store)
            case .timers: TimerView(store: store)
            }
        }
        .frame(minWidth: 480, minHeight: 560)
        .background(Palette.bg)
    }
}

struct ClockTab: View {
    @ObservedObject var store: ClockStore

    var body: some View {
        VStack(spacing: Space.s5) {
            Spacer(minLength: 0)

            ClockFace().frame(width: 240, height: 240)

            TimelineView(.periodic(from: .now, by: 1)) { tl in
                let d = digital(tl.date)
                VStack(spacing: Space.s1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(d.time).font(.sf(46, .thin)).monospacedDigit()
                            .foregroundStyle(Palette.fg)
                        if let a = d.ampm {
                            Text(a).font(.sf(20, .light)).foregroundStyle(Palette.fgDim)
                        }
                    }
                    // Sentence case, no letter-spacing: Mac Clock uses Title Case
                    // headers and never tracks system text.
                    Text(d.date).font(.sf(13)).foregroundStyle(Palette.fgDim)
                }
            }

            nextLine
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg)
    }

    @ViewBuilder private var nextLine: some View {
        if let (a, when) = store.nextAlarm(from: store.now) {
            HStack(spacing: 5) {
                Image(systemName: "alarm").font(.sf(11))
                Text(Fmt.hm(a.hour, a.minute)).monospacedDigit()
                Text("·").foregroundStyle(Palette.fgMute)
                Text(TimeParse.relative(when, from: store.now))
            }
            .font(.sf(13)).foregroundStyle(Palette.fgDim)
        } else {
            Text("No Alarms").font(.sf(13)).foregroundStyle(Palette.fgMute)
        }
    }

    private func digital(_ date: Date) -> (time: String, ampm: String?, date: String) {
        let f = DateFormatter(); f.locale = .current
        f.setLocalizedDateFormatFromTemplate("j:mm")
        let (t, ampm) = splitTime(f.string(from: date))
        let df = DateFormatter(); df.locale = .current
        df.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return (t, ampm, df.string(from: date))
    }
}
