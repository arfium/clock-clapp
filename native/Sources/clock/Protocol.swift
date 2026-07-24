import Foundation

// The clock app's OWN GUI↔CLI wire protocol (newline-delimited JSON over a Unix
// socket). Clatch never sees this — it is the app's private channel. The app
// pre-formats the human-readable fields so the CLI and GUI read identically.

/// A CLI command travelling to the running app.
struct Request: Codable {
    var cmd: String
    var when: String?        // alarm: "HH:MM" / "7:30am"  ·  timer: "10m", "1h30m", "90s"
    var label: String?
    var note: String?        // alarm --note: the prompt delivered when it wakes the agent
    var id: String?          // cancel / toggle / pause / resume / edit
    var days: String?        // alarm --repeat: "weekdays", "weekends", "daily", "mon,wed,fri"
    var quiet: Bool?         // alarm --quiet: fire as context, don't wake (--wake sets false)
    var to: String?          // alarm --to: who to wake — "everyone" | "alice" | "alice,bob"
    var agent: String?       // the caller's CLATCH_AGENT (forwarded by the CLI)
}

/// An alarm, projected for CLI + GUI.
struct AlarmDTO: Codable {
    var id: String
    var hour: Int
    var minute: Int
    var timeText: String       // "07:30"
    var label: String
    var note: String           // the prompt sent when it wakes the agent ("" = none)
    var repeatText: String     // "Once" | "Every day" | "Weekdays" | "Mon Wed Fri"
    var enabled: Bool
    var wakeAgent: Bool
    var forAgent: String?       // the owner (the agent that set it via CLI; nil = human/GUI)
    var targets: [String]       // the agents it wakes ([] = everyone)
    var wakesText: String       // "everyone" | "alice" | "alice, bob"
    var nextText: String        // "in 3h 12m" | "off"
}

/// A countdown timer, projected for CLI + GUI.
struct TimerDTO: Codable {
    var id: String
    var label: String
    var remaining: Int          // seconds (machine)
    var remainingText: String   // "9:58"
    var endText: String         // "ends 3:47 PM"
    var running: Bool
    var done: Bool
    var forAgent: String?
}

/// A command's result.
struct Response: Codable {
    var ok: Bool
    var error: String?
    var message: String?        // help / plain acknowledgements
    var nowText: String?
    var alarms: [AlarmDTO]?
    var timers: [TimerDTO]?
    var alarm: AlarmDTO?
    var timer: TimerDTO?
}

/// `~/.clock/clock.sock` — user-private dir (0700), socket (0600).
enum SocketPath {
    static var dir: String { AppInfo.runtimeDir }
    static var path: String { (dir as NSString).appendingPathComponent("\(AppInfo.cli).sock") }
}
