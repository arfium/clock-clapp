import Foundation

// Repeat-day parsing/summary, time formatting, and DTO projection — the bits both
// the CLI and the GUI render from. Calendar weekday: 1=Sun … 7=Sat.

enum Days {
    static let short = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]  // index by weekday
    static let letter = ["", "S", "M", "T", "W", "T", "F", "S"]

    /// Parse "weekdays" / "weekends" / "daily" / "mon,wed,fri" into a weekday set.
    static func parse(_ s: String?) -> Set<Int> {
        guard let raw = s?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return [] }
        switch raw {
        case "daily", "everyday", "every day", "all": return [1, 2, 3, 4, 5, 6, 7]
        case "weekdays", "weekday": return [2, 3, 4, 5, 6]
        case "weekends", "weekend": return [1, 7]
        default: break
        }
        let map = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
        var out = Set<Int>()
        for tok in raw.split(whereSeparator: { $0 == "," || $0 == " " }) {
            if let d = map[String(tok.prefix(3))] { out.insert(d) }
        }
        return out
    }

    /// "Once" | "Every day" | "Weekdays" | "Weekends" | "Mon Wed Fri".
    static func summary(_ days: Set<Int>) -> String {
        if days.isEmpty { return "Once" }
        if days.count == 7 { return "Every day" }
        if days == [2, 3, 4, 5, 6] { return "Weekdays" }
        if days == [1, 7] { return "Weekends" }
        return days.sorted().map { short[$0] }.joined(separator: " ")
    }
}

enum Fmt {
    /// Locale-aware wall time from hour/minute, e.g. "7:30 AM" or "07:30".
    static func hm(_ hour: Int, _ minute: Int) -> String {
        var c = DateComponents(); c.hour = hour; c.minute = minute
        guard let d = Calendar.current.date(from: c) else { return String(format: "%02d:%02d", hour, minute) }
        let f = DateFormatter(); f.locale = .current
        f.setLocalizedDateFormatFromTemplate("j:mm")
        return f.string(from: d)
    }
    /// Countdown display: "9:58", "1:09:58" (drops hours < 1h, drops leading zeros).
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    static func endText(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("j:mm")
        return "ends " + f.string(from: date)
    }
}

extension ClockStore {
    func alarmDTO(_ a: Alarm) -> AlarmDTO {
        let nextText: String
        if a.enabled, let d = nextFire(a, from: now) { nextText = TimeParse.relative(d, from: now) }
        else { nextText = "off" }
        return AlarmDTO(id: a.id, hour: a.hour, minute: a.minute, timeText: Fmt.hm(a.hour, a.minute),
                        label: a.label, note: a.note, repeatText: Days.summary(a.repeatDays),
                        enabled: a.enabled, wakeAgent: a.wakeAgent, forAgent: a.agentName,
                        nextText: nextText)
    }

    func timerDTO(_ t: Countdown) -> TimerDTO {
        // Measure against the true instant, not the published `now` (which lags up to
        // one scheduler tick behind the Date() that set endAt) — else a fresh 25:00
        // timer reads 25:01. The GUI ring is already live via its own TimelineView.
        let r = t.remaining(Date())
        return TimerDTO(id: t.id, label: t.label, remaining: r,
                        remainingText: Fmt.duration(r),
                        endText: t.done ? "done" : (t.isRunning ? Fmt.endText(t.endAt) : "paused"),
                        running: t.isRunning, done: t.done, forAgent: t.agentName)
    }

    func snapshotAlarms() -> [AlarmDTO] { alarms.map(alarmDTO) }
    func snapshotTimers() -> [TimerDTO] { timers.map(timerDTO) }
}
