import Foundation
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// The single source of truth: alarms (wall-clock, optionally repeating) + timers
// (countdowns), plus the scheduler that fires them. Both surfaces mutate it — the
// human via the GUI, the agent via the CLI — so they never drift.
//
// A due WAKE alarm fires `alarm.fired` (run → wakes the agent); a --quiet alarm
// fires `alarm.quiet` (context). A due timer fires `timer.done` (run). Each is
// TARGETED at exactly the agent who set it (via its CLATCH_AGENT). The GUI plays a
// chime. Clatch has no cron — this app IS the scheduler while it runs.
// ─────────────────────────────────────────────────────────────────────────────

enum Actor { case user, agent }

@MainActor
final class ClockStore: ObservableObject {

    struct Alarm: Codable, Identifiable {
        var id: String
        var hour: Int                 // 0..23
        var minute: Int               // 0..59
        var label: String             // the short name shown on the row ("Wake up")
        /// Free text left on the alarm. When `wakeAgent` is on, this note IS the
        /// prompt the woken agent receives — the only context that survives the gap
        /// between setting the alarm and it going off. Write the whole instruction.
        var note: String = ""
        var repeatDays: Set<Int>      // Calendar weekday 1=Sun … 7=Sat; empty = one-shot
        var enabled: Bool
        var wakeAgent: Bool           // fire wakes the agent (run) vs notify only (context)
        var agentName: String?        // the CLATCH_AGENT that set it via CLI (nil = human/GUI)
        var lastFired: String?        // "yyyyMMddHHmm" guard so it fires once per matching minute
    }

    struct Countdown: Codable, Identifiable {
        var id: String
        var label: String
        var total: Int                // seconds
        var endAt: Date               // wall-clock fire time (valid while running)
        var pausedRemaining: Int?     // set when paused (frozen); nil while running
        var done: Bool
        var agentName: String?
        var isRunning: Bool { pausedRemaining == nil && !done }
        func remaining(_ now: Date) -> Int {
            if done { return 0 }
            if let r = pausedRemaining { return r }
            return max(0, Int(endAt.timeIntervalSince(now).rounded(.up)))
        }
    }

    @Published private(set) var alarms: [Alarm] = []
    @Published private(set) var timers: [Countdown] = []
    @Published private(set) var now: Date = Date()

    /// (name, target, payload) → control pipe. Set by the app delegate.
    var onSignal: ((String, [String], [String: String]) -> Void)?
    /// GUI hook: play the chime when something fires.
    var onFire: (() -> Void)?

    private var ticker: Timer?
    private var nextA = 1
    private var nextT = 1
    private let storeURL: URL

    init() {
        let dir = AppInfo.runtimeDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        storeURL = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("clock.json"))
        load()
    }

    // MARK: Scheduler

    func startScheduler() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        tick()
    }

    private func tick() {
        now = Date()
        var changed = false
        // Timers: fire any running timer whose end has arrived.
        for i in timers.indices where timers[i].isRunning && timers[i].endAt <= now {
            fireTimer(i); changed = true
        }
        // Alarms: minute-granular, once per matching minute.
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .weekday, .year, .month, .day], from: now)
        let key = String(format: "%04d%02d%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        for i in alarms.indices where alarms[i].enabled && alarms[i].lastFired != key {
            let a = alarms[i]
            let dayOK = a.repeatDays.isEmpty || a.repeatDays.contains(c.weekday ?? 0)
            if a.hour == c.hour && a.minute == c.minute && dayOK {
                fireAlarm(i, at: now); alarms[i].lastFired = key
                if a.repeatDays.isEmpty { alarms[i].enabled = false }  // one-shot
                changed = true
            }
        }
        if changed { save() }
    }

    private func fireAlarm(_ i: Int, at when: Date) {
        let a = alarms[i]
        let name = a.wakeAgent ? "alarm.fired" : "alarm.quiet"
        let target = a.agentName.map { [$0] } ?? []
        var payload = ["id": a.id, "label": a.label, "at": ISO8601DateFormatter().string(from: when),
                       "time": String(format: "%02d:%02d", a.hour, a.minute)]
        // The note rides along as the agent's instruction. On `alarm.fired` (run) it
        // is effectively the prompt for the turn this signal starts; on `alarm.quiet`
        // (context) it is just what got recorded. The signal NAME decides which.
        if !a.note.isEmpty { payload["note"] = a.note }
        if let owner = a.agentName { payload["for"] = owner }
        onSignal?(name, target, payload)
        onFire?()
    }

    private func fireTimer(_ i: Int) {
        timers[i].done = true
        let t = timers[i]
        let target = t.agentName.map { [$0] } ?? []
        var payload = ["id": t.id, "label": t.label, "seconds": String(t.total),
                       "at": ISO8601DateFormatter().string(from: now)]
        if let owner = t.agentName { payload["for"] = owner }
        onSignal?("timer.done", target, payload)
        onFire?()
    }

    // MARK: Alarm commands (GUI + CLI call the SAME methods)

    @discardableResult
    func addAlarm(hour: Int, minute: Int, label: String, note: String = "", repeatDays: Set<Int>,
                  wakeAgent: Bool, by actor: Actor, agent: String? = nil) -> Alarm {
        let a = Alarm(id: "a\(nextA)", hour: hour, minute: minute, label: label, note: note,
                      repeatDays: repeatDays, enabled: true, wakeAgent: wakeAgent,
                      agentName: actor == .agent ? agent : nil, lastFired: nil)
        nextA += 1
        alarms.append(a)
        sortAlarms()
        save()
        if actor == .user {   // tell the agent the human scheduled one (broadcast, context)
            var p = ["id": a.id, "label": a.label, "time": String(format: "%02d:%02d", hour, minute)]
            if !note.isEmpty { p["note"] = note }
            onSignal?("alarm.set", [], p)
        }
        return a
    }

    /// Edit an existing alarm in place. Clearing `lastFired` re-arms it, so moving an
    /// alarm onto the current minute still rings instead of being swallowed by the
    /// once-per-minute guard. Ownership (`agentName`) is deliberately NOT editable —
    /// whoever set it stays the one it wakes.
    @discardableResult
    func updateAlarm(id: String, hour: Int, minute: Int, label: String, note: String,
                     repeatDays: Set<Int>, wakeAgent: Bool) -> Alarm? {
        guard let i = idxA(id) else { return nil }
        alarms[i].hour = hour
        alarms[i].minute = minute
        alarms[i].label = label
        alarms[i].note = note
        alarms[i].repeatDays = repeatDays
        alarms[i].wakeAgent = wakeAgent
        alarms[i].lastFired = nil
        sortAlarms()
        save()
        return alarms.first { $0.id == id }
    }

    func toggleAlarm(id: String) { if let i = idxA(id) { alarms[i].enabled.toggle(); alarms[i].lastFired = nil; save() } }
    func setEnabled(id: String, _ on: Bool) { if let i = idxA(id) { alarms[i].enabled = on; alarms[i].lastFired = nil; save() } }

    @discardableResult
    func cancel(id: String) -> Bool {
        if let i = idxA(id) { alarms.remove(at: i); save(); return true }
        if let i = idxT(id) { timers.remove(at: i); save(); return true }
        return false
    }

    // MARK: Timer commands

    @discardableResult
    func addTimer(seconds: Int, label: String, by actor: Actor, agent: String? = nil) -> Countdown {
        let t = Countdown(id: "t\(nextT)", label: label, total: seconds,
                          endAt: Date().addingTimeInterval(TimeInterval(seconds)),
                          pausedRemaining: nil, done: false, agentName: actor == .agent ? agent : nil)
        nextT += 1
        timers.append(t)
        save()
        return t
    }

    func pauseTimer(id: String) {
        guard let i = idxT(id), timers[i].isRunning else { return }
        timers[i].pausedRemaining = timers[i].remaining(now); save()
    }
    func resumeTimer(id: String) {
        guard let i = idxT(id), let r = timers[i].pausedRemaining else { return }
        timers[i].endAt = Date().addingTimeInterval(TimeInterval(r)); timers[i].pausedRemaining = nil; save()
    }

    // MARK: Queries

    func alarm(id: String) -> Alarm? { alarms.first { $0.id == id } }
    private func idxA(_ id: String) -> Int? { alarms.firstIndex { $0.id == id } }
    private func idxT(_ id: String) -> Int? { timers.firstIndex { $0.id == id } }

    /// The next enabled alarm to ring, and its Date — for the clock face subtitle.
    func nextAlarm(from ref: Date = Date()) -> (Alarm, Date)? {
        alarms.filter { $0.enabled }
            .compactMap { a -> (Alarm, Date)? in nextFire(a, from: ref).map { (a, $0) } }
            .min { $0.1 < $1.1 }
    }

    /// The next wall-clock occurrence of an alarm (today if still ahead, else the
    /// next matching weekday; for one-shots, today or tomorrow).
    func nextFire(_ a: Alarm, from ref: Date) -> Date? {
        let cal = Calendar.current
        for add in 0...7 {
            guard let day = cal.date(byAdding: .day, value: add, to: ref),
                  let cand = cal.date(bySettingHour: a.hour, minute: a.minute, second: 0, of: day)
            else { continue }
            if cand <= ref { continue }
            let wd = cal.component(.weekday, from: cand)
            if a.repeatDays.isEmpty || a.repeatDays.contains(wd) { return cand }
        }
        return nil
    }

    private func sortAlarms() {
        alarms.sort { ($0.hour, $0.minute, $0.id) < ($1.hour, $1.minute, $1.id) }
    }

    // MARK: Persistence

    private struct Disk: Codable { var alarms: [Alarm]; var timers: [Countdown]; var nextA: Int; var nextT: Int }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let d = try? JSONDecoder.iso().decode(Disk.self, from: data) else { return }
        alarms = d.alarms
        // Drop finished/expired timers on load; a still-running one that expired while
        // we were closed fires on the first tick (its endAt is already past).
        timers = d.timers.filter { !$0.done }
        nextA = max(d.nextA, (alarms.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1)
        nextT = max(d.nextT, (timers.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1)
        sortAlarms()
    }

    private func save() {
        let d = Disk(alarms: alarms, timers: timers, nextA: nextA, nextT: nextT)
        if let data = try? JSONEncoder.iso().encode(d) { try? data.write(to: storeURL, options: .atomic) }
    }
}

// Decoded by hand, in an extension so the memberwise init survives. `note` was added
// after the first stores were written, and Swift's synthesized decoder THROWS on a
// missing key rather than falling back to the property's default — without this, one
// pre-existing ~/.clock/clock.json would fail to decode and silently wipe every alarm.
// Any field added from here on should be decodeIfPresent for the same reason.
extension ClockStore.Alarm {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        hour = try c.decode(Int.self, forKey: .hour)
        minute = try c.decode(Int.self, forKey: .minute)
        label = try c.decode(String.self, forKey: .label)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        repeatDays = try c.decode(Set<Int>.self, forKey: .repeatDays)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        wakeAgent = try c.decode(Bool.self, forKey: .wakeAgent)
        agentName = try c.decodeIfPresent(String.self, forKey: .agentName)
        lastFired = try c.decodeIfPresent(String.self, forKey: .lastFired)
    }
}

extension JSONEncoder { fileprivate static func iso() -> JSONEncoder {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e } }
extension JSONDecoder { fileprivate static func iso() -> JSONDecoder {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
