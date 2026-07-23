import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// clock — a Clatch alarm/timer app. The agent sets its own timed wake-ups via the
// CLI; the human sets alarms in the GUI; when an alarm is due the app fires a
// signal that wakes (or notifies) the granted agent. Built on clapp-template.
//
// Identity lives here in ONE place; keep clatch.json in sync (id, connector.cli,
// connector.signals).
// ─────────────────────────────────────────────────────────────────────────────

enum AppInfo {
    /// Reverse-DNS app id. MUST equal `id` in clatch.json and CLATCH_APP_ID.
    static let id = "com.arfium.clock"

    /// The agent's CLI shorthand. MUST equal `connector.cli` in clatch.json.
    static let cli = "clock"

    /// Every signal this app may emit, as ID → TYPE. MUST equal `connector.signals`
    /// in clatch.json (same ids, same types). The type is stamped onto every
    /// `app.toAgent` from here and RE-VALIDATED by Clatch against the manifest; the
    /// wake-vs-notify distinction is two IDS (a type is fixed at declaration, never a
    /// per-emit mode):
    ///   alarm.fired — a wake alarm came due          (declared `run`)
    ///   alarm.quiet — a --quiet alarm came due        (declared `context`)
    ///   alarm.set   — the human added an alarm in GUI (declared `context`)
    ///   timer.done  — a countdown reached zero        (declared `run`)
    /// (The control-pipe major lives ONLY in clatch.json `protocol`, read at install.)
    static let signals: [String: String] = [
        "alarm.fired": "run",
        "alarm.quiet": "context",
        "alarm.set": "context",
        "timer.done": "run",
    ]

    /// User-private runtime dir: the GUI↔CLI socket AND the durable alarm store.
    static var runtimeDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".clock")
    }
}
