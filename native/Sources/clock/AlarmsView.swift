import SwiftUI

// The Alarms tab, to Apple's anatomy. `MTAAlarmTableViewCell` has exactly three
// visible parts — `_digitalClockLabel`, `_detailLabel`, `_enabledSwitch` — laid out
// as [time + detail] · spacer · [switch], inside an inset-grouped rounded card.
//
// Two details are where knockoffs give themselves away:
//   • A switched-OFF alarm changes TEXT COLOR (Apple has a dedicated
//     `mtui_disabledTextColor`). It is never `.opacity()` on the row — that fades
//     the switch too and reads as "loading/broken" rather than "off".
//   • The switch is GREEN, never the app accent. Apple keeps `mtui_switchTintColor`
//     separate from its orange tint for exactly this reason.

struct AlarmsView: View {
    @ObservedObject var store: ClockStore
    @State private var adding = false
    @State private var editing: ClockStore.Alarm?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            if store.alarms.isEmpty {
                emptyState
            } else {
                ScrollView {
                    GroupedCard {
                        ForEach(Array(store.alarms.enumerated()), id: \.element.id) { i, alarm in
                            AlarmRow(store: store, alarm: alarm) { editing = alarm }
                            if i < store.alarms.count - 1 { Hairline() }
                        }
                    }
                    .padding(.horizontal, Space.cardInset)
                    .padding(.vertical, Space.s3)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.bg)
        .safeAreaInset(edge: .top, spacing: 0) { AddBar(title: "Alarms") { adding = true } }
        .sheet(isPresented: $adding) { AlarmSheet(store: store, editing: nil) }
        .sheet(item: $editing) { AlarmSheet(store: store, editing: $0) }
    }

    /// Apple's empty state is one line of gray text. No icon, no description, no
    /// button — the loctable has `NO_ALARMS` and no sibling strings at all.
    private var emptyState: some View {
        Text("No Alarms")
            .font(.sf(20))
            .foregroundStyle(Palette.fgDim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The title + "＋" band. Apple puts these in the window toolbar; we draw the same
/// relationship in-content since this window hosts its own chrome.
struct AddBar: View {
    let title: String
    var add: (() -> Void)?
    var body: some View {
        HStack {
            Text(title).font(.sf(22, .bold)).foregroundStyle(Palette.fg)
            Spacer()
            if let add {
                Button(action: add) { Image(systemName: "plus").font(.sf(15, .medium)) }
                    .buttonStyle(PlainTintStyle())
                    .help("New \(title.lowercased())")
            }
        }
        .padding(.horizontal, Space.cardInset)
        .padding(.top, Space.s3)
        .padding(.bottom, Space.s2)
        .background(Palette.bg)
    }
}

struct AlarmRow: View {
    @ObservedObject var store: ClockStore
    let alarm: ClockStore.Alarm
    var onEdit: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let on = alarm.enabled
        let (big, ampm) = splitTime(Fmt.hm(alarm.hour, alarm.minute))

        HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(big)
                        .font(.sf(38, .light))
                        .monospacedDigit()
                    if let ampm { Text(ampm).font(.sf(20, .light)) }
                }
                // The color swap IS the on/off signal.
                .foregroundStyle(on ? Palette.fg : Palette.fgDim)

                HStack(spacing: 4) {
                    Text(detail)
                    // A note means this alarm carries an instruction. Flag it with a
                    // glyph rather than the text — the row stays two lines like
                    // Apple's, and the sheet shows the note in full.
                    if !alarm.note.isEmpty {
                        Image(systemName: "text.alignleft").font(.sf(10))
                            .foregroundStyle(on ? Palette.fgDim : Palette.fgMute)
                            .help(alarm.note)
                    }
                    // Who it wakes — shown when the alarm targets specific agents
                    // (a default "everyone" alarm stays clean, Apple-style).
                    if !alarm.targets.isEmpty {
                        Text("·").foregroundStyle(Palette.fgMute)
                        AgentTag(wakesShort, dimmed: !on)
                    }
                }
                .font(.sf(13))
                .foregroundStyle(Palette.fgDim)
            }

            Spacer(minLength: Space.s3)

            AppleSwitch(isOn: Binding(get: { alarm.enabled },
                                      set: { store.setEnabled(id: alarm.id, $0) }))

            rowMenu
        }
        .padding(.horizontal, Space.rowInset)
        .padding(.vertical, Space.s3)
        .frame(minHeight: 72)
        .background(hovering ? Palette.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Three ways in, because each suits a different hand: the ⋯ menu is the
        // visible one, double-click is the Mac list idiom, right-click is the habit.
        .onTapGesture(count: 2) { onEdit?() }
        .contextMenu { menuItems }
    }

    /// The ⋯ button. Always present so it is discoverable, but muted until the
    /// pointer arrives — a row at rest should read as a time, not as a toolbar.
    private var rowMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis")
                .font(.sf(13))
                .foregroundStyle(hovering ? Palette.fgDim : Palette.fgMute)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Alarm actions")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Edit Alarm…") { onEdit?() }
        Button(alarm.enabled ? "Turn Off" : "Turn On") { store.toggleAlarm(id: alarm.id) }
        Divider()
        Button("Delete Alarm", role: .destructive) { store.cancel(id: alarm.id) }
    }

    /// Compact "who it wakes" — one or two names, then "+k".
    private var wakesShort: String {
        let t = alarm.targets
        if t.count <= 2 { return t.joined(separator: ", ") }
        return "\(t[0]) +\(t.count - 1)"
    }

    /// Apple's `ALARM_DETAIL_FORMAT = "%1$@, %2$@"` → "{label}, {repeat}", with the
    /// label defaulting to "Alarm" and the repeat dropped when it's Never.
    private var detail: String {
        let label = alarm.label.isEmpty ? "Alarm" : alarm.label
        let rep = Days.summary(alarm.repeatDays)
        var s = rep == "Once" ? label : "\(label), \(rep)"
        if !alarm.wakeAgent { s += ", quiet" }
        return s
    }
}

/// "7:30 AM" → ("7:30", "AM"); "07:30" → ("07:30", nil).
func splitTime(_ s: String) -> (String, String?) {
    let parts = s.split(separator: " ", maxSplits: 1)
    if parts.count == 2 { return (String(parts[0]), String(parts[1])) }
    return (s, nil)
}

/// Add or edit an alarm. Apple's `MTAAlarmEditViewController` is one grouped table
/// titled "Add Alarm" / "Edit Alarm", with Delete Alarm present only when editing.
struct AlarmSheet: View {
    @ObservedObject var store: ClockStore
    let editing: ClockStore.Alarm?

    @Environment(\.dismiss) private var dismiss
    @State private var hour = 7
    @State private var minute = 0
    @State private var label = ""
    @State private var note = ""
    @State private var repeatDays: Set<Int> = []
    @State private var wake = true
    @State private var targets: Set<String> = []   // agents to wake; empty = everyone

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(editing == nil ? "Add Alarm" : "Edit Alarm")
                .font(.sf(15, .semibold)).foregroundStyle(Palette.fg)
                .frame(maxWidth: .infinity)

            TimeWheel(hour: $hour, minute: $minute)

            GroupedCard {
                row("Repeat") {
                    HStack(spacing: 5) { ForEach(1...7, id: \.self) { dayPill($0) } }
                }
                Hairline()
                row("Label:") {
                    TextField("Alarm", text: $label)
                        .textFieldStyle(AppleFieldStyle())
                        .frame(maxWidth: 170)
                }
                Hairline()
                row("Wake the agent") { AppleSwitch(isOn: $wake) }
                Hairline()
                row("Wake which") { agentPicker }
            }

            // The note is the alarm's whole payload when it wakes an agent, so it
            // gets room to breathe rather than a one-line field.
            VStack(alignment: .leading, spacing: Space.s2) {
                SectionHeader("Note")
                TextEditor(text: $note)
                    .font(.sf(13))
                    .foregroundStyle(Palette.fg)
                    .scrollContentBackground(.hidden)
                    .padding(Space.s2)
                    .frame(height: 72)
                    .background(Palette.fill)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                Text(wake
                     ? "Sent as the prompt for the turn this alarm wakes."
                     : "Recorded with the alarm. No turn is started.")
                    .font(.sf(11))
                    .foregroundStyle(Palette.fgMute)
            }

            if let a = editing {
                Button("Delete Alarm", role: .destructive) {
                    store.cancel(id: a.id)
                    dismiss()
                }
                .buttonStyle(PlainTintStyle(tint: Palette.destructive))
                .frame(maxWidth: .infinity)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.s5)
        .frame(width: 420)
        .background(Palette.bg)
        .onAppear {
            guard let a = editing else { return }
            hour = a.hour; minute = a.minute
            label = a.label; note = a.note
            repeatDays = a.repeatDays; wake = a.wakeAgent
            targets = Set(a.targets)
        }
    }

    private func row<T: View>(_ title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Text(title).font(.sf(13)).foregroundStyle(Palette.fg)
            Spacer()
            trailing()
        }
        .padding(.horizontal, Space.rowInset)
        .padding(.vertical, Space.s2)
    }

    private func dayPill(_ d: Int) -> some View {
        let on = repeatDays.contains(d)
        return Text(Days.letter[d])
            .font(.sf(12, .medium))
            .foregroundStyle(on ? .white : Palette.fgDim)
            .frame(width: 26, height: 26)
            .background(on ? Palette.accent : Palette.fill)
            .clipShape(Circle())
            .contentShape(Circle())
            .onTapGesture { if on { repeatDays.remove(d) } else { repeatDays.insert(d) } }
    }

    /// A menu multi-select over the connected agents. "Everyone" (no selection) is the
    /// broadcast default; picking names narrows the wake to exactly those agents.
    private var agentPicker: some View {
        Menu {
            Button { targets = [] } label: {
                if targets.isEmpty { Label("Everyone", systemImage: "checkmark") } else { Text("Everyone") }
            }
            if !agentNames.isEmpty { Divider() }
            ForEach(agentNames, id: \.self) { name in
                Button { toggle(name) } label: {
                    if targets.contains(name) { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(wakesLabel).font(.sf(13)).foregroundStyle(Palette.accent).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.sf(9)).foregroundStyle(Palette.fgDim)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which agent(s) this alarm wakes — everyone, or a chosen few")
    }

    /// The roster ∪ any already-chosen names, so a target set from the CLI (or an agent
    /// that has since disconnected) still shows and can be toggled off.
    private var agentNames: [String] {
        Array(Set(store.agents.map(\.name)).union(targets)).sorted()
    }
    private var wakesLabel: String {
        targets.isEmpty ? "Everyone" : targets.sorted().joined(separator: ", ")
    }
    private func toggle(_ name: String) {
        if targets.contains(name) { targets.remove(name) } else { targets.insert(name) }
    }

    private func save() {
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = editing {
            store.updateAlarm(id: a.id, hour: hour, minute: minute, label: l, note: n,
                              repeatDays: repeatDays, wakeAgent: wake, targets: Array(targets))
        } else {
            store.addAlarm(hour: hour, minute: minute, label: l, note: n,
                           repeatDays: repeatDays, wakeAgent: wake, targets: Array(targets), by: .user)
        }
        dismiss()
    }
}
