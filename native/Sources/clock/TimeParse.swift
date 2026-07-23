import Foundation

// Parsing of the `<when>` argument the human and agent use to schedule an alarm,
// and of `--repeat` durations. Deliberately small and forgiving.

enum TimeParse {
    /// Parse a wall-clock time — "7:30", "07:30", "7:30am", "7am", "19:30" — into
    /// (hour 0..23, minute 0..59). Returns nil if it isn't a time.
    static func hourMinute(_ raw: String) -> (Int, Int)? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        var pm: Bool? = nil
        if s.hasSuffix("am") { pm = false; s = String(s.dropLast(2)) }
        else if s.hasSuffix("pm") { pm = true; s = String(s.dropLast(2)) }
        s = s.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: ":")
        guard let h = Int(parts.first ?? ""), (0...23).contains(h) else { return nil }
        let m = parts.count > 1 ? (Int(parts[1]) ?? -1) : 0
        guard (0...59).contains(m) else { return nil }
        var hour = h
        if let pm { hour = pm ? (h == 12 ? 12 : h + 12) : (h == 12 ? 0 : h) }
        guard (0...23).contains(hour) else { return nil }
        return (hour, m)
    }

    /// Parse a compound duration like "10m", "1h30m", "90s", "2d" into seconds.
    /// Returns nil if it isn't a pure duration.
    static func duration(_ s: String) -> Int? {
        let str = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !str.isEmpty else { return nil }
        var total = 0
        var num = ""
        var sawUnit = false
        for ch in str {
            if ch.isNumber {
                num.append(ch)
            } else {
                guard let n = Int(num) else { return nil }
                let unit: Int
                switch ch {
                case "s": unit = 1
                case "m": unit = 60
                case "h": unit = 3600
                case "d": unit = 86_400
                default: return nil
                }
                // Overflow-checked: an absurd duration returns nil, never traps.
                let (product, o1) = n.multipliedReportingOverflow(by: unit)
                if o1 { return nil }
                let (sum, o2) = total.addingReportingOverflow(product)
                if o2 { return nil }
                total = sum
                num = ""
                sawUnit = true
            }
        }
        // A trailing bare number (no unit) is invalid for a duration.
        guard num.isEmpty, sawUnit else { return nil }
        return total
    }

    /// Parse `<when>` into an absolute fire Date, relative to `now`.
    /// Accepts:
    ///   +<dur> or <dur>   → now + duration        ("+10m", "1h30m")
    ///   HH:MM             → today at HH:MM (tomorrow if already past)
    ///   ISO8601           → an absolute instant    ("2026-07-15T14:30:00")
    static func fireDate(_ raw: String, now: Date = Date(),
                         calendar: Calendar = .current) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // +<dur> / bare <dur>
        let durPart = s.hasPrefix("+") ? String(s.dropFirst()) : s
        if let secs = duration(durPart) {
            return now.addingTimeInterval(TimeInterval(secs))
        }

        // HH:MM (24h)
        if let colon = s.firstIndex(of: ":"), !s.contains("-"), !s.contains("T") {
            let hh = String(s[s.startIndex..<colon])
            let mm = String(s[s.index(after: colon)...])
            if let h = Int(hh), let m = Int(mm), (0..<24).contains(h), (0..<60).contains(m) {
                var comps = calendar.dateComponents([.year, .month, .day], from: now)
                comps.hour = h; comps.minute = m; comps.second = 0
                if let candidate = calendar.date(from: comps) {
                    return candidate > now ? candidate
                        : calendar.date(byAdding: .day, value: 1, to: candidate)
                }
            }
        }

        // ISO8601 (with or without seconds)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        // Bare "YYYY-MM-DDTHH:MM" without timezone → interpret in local time.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = calendar
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = fmt
            if let d = local.date(from: s) { return d }
        }
        return nil
    }

    /// "in 9m 58s" / "fired 2m ago" / "now".
    static func relative(_ target: Date, from now: Date = Date()) -> String {
        let delta = Int(target.timeIntervalSince(now).rounded())
        if delta == 0 { return "now" }
        let ahead = delta > 0
        let text = compact(abs(delta))
        return ahead ? "in \(text)" : "\(text) ago"
    }

    /// Seconds → compact "1h 5m", "58s", "2d 3h" (at most two units).
    static func compact(_ seconds: Int) -> String {
        if seconds <= 0 { return "0s" }
        let units: [(String, Int)] = [("d", 86_400), ("h", 3600), ("m", 60), ("s", 1)]
        var parts: [String] = []
        var rem = seconds
        for (name, size) in units where parts.count < 2 {
            let q = rem / size
            if q > 0 || (!parts.isEmpty && name == "s" && rem > 0) {
                parts.append("\(q)\(name)")
                rem -= q * size
            }
        }
        return parts.isEmpty ? "0s" : parts.joined(separator: " ")
    }

    static func clock(_ d: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.dateFormat = "MMM d HH:mm:ss"
        return f.string(from: d)
    }
}
