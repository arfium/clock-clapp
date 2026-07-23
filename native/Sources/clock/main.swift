import AppKit
import Foundation
import SwiftUI

// One binary, two roles:
//   clock app            -> the app process (clock GUI + socket server + scheduler)
//   clock <cmd> [...]    -> a CLI client the agent uses to set alarms & timers

let argv = Array(CommandLine.arguments.dropFirst())
let first = argv.first ?? "help"

// `clock --help` is the agent's ONLY manual — document every verb.
let helpText = """
clock — a shared alarm clock for you and your agent.
You (the agent) schedule your own alarms and timers; the human sets them in the GUI.
An alarm/timer targets exactly the agent who set it: when it fires you get a signal
(`alarm.fired` / `timer.done`, type run) that wakes you for that turn.

usage:
  clock now                          print the current time
  clock list                         list all alarms and timers
  clock alarm <time> "<label>"       set an alarm at a wall-clock time
      --note "<text>"                what to do when it fires — this becomes YOUR
                                     PROMPT for the turn the alarm wakes
      --repeat <days>                daily | weekdays | weekends | mon,wed,fri
      --quiet                        fire as context (do NOT wake you → alarm.quiet)
  clock edit <id> [<time>]           change an alarm; omitted flags keep their value
      --time · --label · --note · --repeat · --quiet · --wake
  clock timer <dur> "<label>"        start a countdown (fires timer.done when it ends)
  clock cancel <id>                  remove an alarm (aN) or timer (tN)
  clock toggle <id>                  enable / disable an alarm
  clock pause <id> / resume <id>     pause / resume a timer
  clock show                         open the window (same as `focus`)
  clock hide                         send it back to the background
  clock close                        quit the app — this is what stops the alarms

clock keeps time with or without a window. `clock app --background` starts it with no
window and no Dock icon; closing the window just backgrounds it again. Set an alarm
without taking over the screen, and `clock show` only when you want to be seen.

<time>  7:30 · 07:30 · 7:30am · 19:30        <dur>  10m · 1h30m · 90s · 45s
`clock set <when> …` is a shorthand: a clock time makes an alarm, a duration a timer.

The note is the whole point of a wake alarm: when it fires you get a fresh turn with
no memory of setting it, and the note is the only context that survives. Write the
full instruction, not a reminder to yourself to remember something.
  clock alarm 9:00 "standup" --note "post yesterday's diff summary to #eng"
"""

func fmtAlarm(_ a: AlarmDTO) -> String {
    var tags = [a.repeatText]
    if !a.enabled { tags.append("off") }
    if !a.wakeAgent { tags.append("quiet") }
    if let f = a.forAgent { tags.append("→\(f)") }
    let label = a.label.isEmpty ? "" : "  \(a.label)"
    var line = "\(a.id.padding(toLength: 4, withPad: " ", startingAt: 0)) "
        + "\(a.timeText.padding(toLength: 8, withPad: " ", startingAt: 0))\(label)  [\(tags.joined(separator: ", "))]"
    // The note is the payload of a wake alarm, so `list` must show it in full —
    // truncating would hide the very instruction the agent is meant to act on.
    if !a.note.isEmpty { line += "\n       ↳ \(a.note)" }
    return line
}
func fmtTimer(_ t: TimerDTO) -> String {
    var tags = [t.done ? "done" : (t.running ? t.endText : "paused")]
    if let f = t.forAgent { tags.append("→\(f)") }
    let label = t.label.isEmpty ? "" : "  \(t.label)"
    return "\(t.id.padding(toLength: 4, withPad: " ", startingAt: 0)) "
        + "\(t.remainingText.padding(toLength: 9, withPad: " ", startingAt: 0))\(label)  [\(tags.joined(separator: ", "))]"
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = ClockStore()
    var server: SocketServer?
    var control: ControlPipe?
    var window: NSWindow?
    let dock = DockClock()
    /// Start without a window: no Dock icon, no front app — just the scheduler and
    /// the socket. An agent setting an alarm shouldn't have to take over the screen.
    var background = false

    func applicationDidFinishLaunching(_ note: Notification) {
        let wiredByClatch = ProcessInfo.processInfo.environment["CLATCH_INSTANCE_TOKEN"] != nil

        let socketServer = SocketServer(path: SocketPath.path) { [weak self] req in
            MainActor.assumeIsolated { self?.handle(req) ?? Response(ok: false, error: "no app") }
        }
        do { try socketServer.start(); server = socketServer }
        catch {
            FileHandle.standardError.write(Data("\(AppInfo.cli): \(error)\n".utf8))
            NSApp.terminate(nil); return
        }

        if let pipe = ControlPipe(signals: AppInfo.signals) {
            pipe.onShutdown = { DispatchQueue.main.async { NSApp.terminate(nil) } }
            // The control pipe closed unexpectedly (Clatch gone, or fail-fast on a bad
            // frame): socket-close IS "instance gone", so a wired app exits rather than
            // linger as a zombie. Standalone dev stays up.
            pipe.onClose = {
                if wiredByClatch { DispatchQueue.main.async { NSApp.terminate(nil) } }
            }
            // An alarm/timer fan-out was REFUSED whole (the target agent's inbox/queue
            // was full), so nothing was delivered. Tell the human why over `notify`.
            pipe.onSignalRefused = { [weak pipe] id, agent, reason in
                let why = reason == "inbox_full" ? "its inbox is full"
                        : reason == "queue_full" ? "its context queue is full" : reason
                pipe?.notify("\(AppInfo.cli): couldn't deliver '\(id)' to \(agent) — \(why); nothing was delivered")
            }
            if pipe.start() {
                control = pipe
                store.onSignal = { [weak self] name, target, payload in
                    self?.control?.emitSignal(name, target: target, payload)
                }
            } else if wiredByClatch { NSApp.terminate(nil); return }
        } else if wiredByClatch {
            FileHandle.standardError.write(Data("\(AppInfo.cli): Clatch launch missing control pipe\n".utf8))
            NSApp.terminate(nil); return
        }

        store.onFire = { Chime.play() }     // the human's cue when something rings
        store.startScheduler()

        if background { enterBackground() } else { showWindow() }
    }

    // MARK: Window lifetime
    //
    // The window is OPTIONAL and disposable; the scheduler is not. A clock that
    // stops keeping time when you close its window is not a clock — so closing
    // drops us to the background instead of quitting, and `clock close` is the
    // only thing that actually ends the process.

    /// 600×640 is Apple Clock's own default frame. The title is hidden and the
    /// titlebar transparent because in Clock the centred segmented control IS the
    /// title — and we follow the system appearance rather than forcing dark, since
    /// every color in Theme.swift is semantic.
    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = "Clock"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.contentMinSize = NSSize(width: 480, height: 560)
        win.backgroundColor = Palette.nsBg
        win.contentView = NSHostingView(rootView: ClockRoot(store: store))
        win.isReleasedWhenClosed = false     // we re-show this instance later
        win.delegate = self
        win.center()
        return win
    }

    func showWindow() {
        let win = window ?? makeWindow()
        window = win
        NSApp.setActivationPolicy(.regular)
        dock.start()                        // the live ticking Dock icon
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideWindow() {
        window?.orderOut(nil)
        enterBackground()
    }

    private func enterBackground() {
        dock.stop()
        NSApp.setActivationPolicy(.accessory)   // no Dock tile, no menu bar, still alive
    }

    /// Closing the window backgrounds the app — it does NOT stop the alarms.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ note: Notification) { server?.stop() }

    func handle(_ req: Request) -> Response {
        func snap() -> Response { Response(ok: true, nowText: TimeParse.clock(Date()),
                                           alarms: store.snapshotAlarms(), timers: store.snapshotTimers()) }
        switch req.cmd {
        case "ping": return Response(ok: true)
        case "focus", "show":
            showWindow(); return Response(ok: true, message: "window shown")
        case "hide":
            hideWindow(); return Response(ok: true, message: "running in the background")
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }; return Response(ok: true, message: "bye")
        case "now": return Response(ok: true, nowText: TimeParse.clock(Date()))
        case "list": return snap()
        case "alarm":
            guard let raw = req.when, let (h, m) = TimeParse.hourMinute(raw) else {
                return Response(ok: false, error: "bad time: \(req.when ?? "") — try 7:30, 07:30, or 7:30am")
            }
            let a = store.addAlarm(hour: h, minute: m, label: req.label ?? "", note: req.note ?? "",
                                   repeatDays: Days.parse(req.days), wakeAgent: !(req.quiet ?? false),
                                   by: .agent, agent: req.agent)
            var r = snap(); r.alarm = store.alarmDTO(a); return r
        case "timer":
            guard let raw = req.when, let secs = TimeParse.duration(raw), secs > 0 else {
                return Response(ok: false, error: "bad duration: \(req.when ?? "") — try 10m, 1h30m, 90s")
            }
            let t = store.addTimer(seconds: secs, label: req.label ?? "", by: .agent, agent: req.agent)
            var r = snap(); r.timer = store.timerDTO(t); return r
        case "set":
            // Smart alias: a clock time → alarm, a duration → timer.
            if let raw = req.when, TimeParse.duration(raw) != nil, TimeParse.hourMinute(raw) == nil {
                return handle(Request(cmd: "timer", when: req.when, label: req.label, agent: req.agent))
            }
            return handle(Request(cmd: "alarm", when: req.when, label: req.label, note: req.note,
                                  days: req.days, quiet: req.quiet, agent: req.agent))
        case "edit":
            // Partial update: every field you omit keeps its current value.
            guard let id = req.id, let cur = store.alarm(id: id) else {
                return Response(ok: false, error: "no such alarm: \(req.id ?? "")")
            }
            var h = cur.hour, m = cur.minute
            if let raw = req.when {
                guard let hm = TimeParse.hourMinute(raw) else {
                    return Response(ok: false, error: "bad time: \(raw) — try 7:30, 07:30, or 7:30am")
                }
                h = hm.0; m = hm.1
            }
            guard let a = store.updateAlarm(
                id: id, hour: h, minute: m,
                label: req.label ?? cur.label,
                note: req.note ?? cur.note,
                repeatDays: req.days.map { Days.parse($0) } ?? cur.repeatDays,
                wakeAgent: req.quiet.map { !$0 } ?? cur.wakeAgent)
            else { return Response(ok: false, error: "no such alarm: \(id)") }
            var r = snap(); r.alarm = store.alarmDTO(a); return r
        case "cancel":
            guard let id = req.id, store.cancel(id: id) else { return Response(ok: false, error: "no such id: \(req.id ?? "")") }
            var r = snap(); r.message = "cancelled \(id)"; return r
        case "toggle":
            guard let id = req.id, store.alarm(id: id) != nil else { return Response(ok: false, error: "no such alarm: \(req.id ?? "")") }
            store.toggleAlarm(id: id); var r = snap(); r.message = "toggled \(id)"; return r
        case "pause":
            guard let id = req.id else { return Response(ok: false, error: "pause needs a timer id") }
            store.pauseTimer(id: id); var r = snap(); r.message = "paused \(id)"; return r
        case "resume":
            guard let id = req.id else { return Response(ok: false, error: "resume needs a timer id") }
            store.resumeTimer(id: id); var r = snap(); r.message = "resumed \(id)"; return r
        case "help", "catalog": return Response(ok: true, message: helpText)
        default: return Response(ok: false, error: "unknown command: \(req.cmd)")
        }
    }
}

func runApp(background: Bool) -> Never {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        // Start as an accessory either way: the delegate promotes us to .regular the
        // moment a window is shown. Launching straight into .regular would flash a
        // Dock icon even for a background start.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        delegate.background = background
        app.delegate = delegate
        app.run()
    }
    exit(0)
}

// MARK: - CLI client

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("\(AppInfo.cli): \(msg)\n".utf8)); exit(1)
}

func runClient(_ argv: [String]) -> Never {
    let cmd = argv[0]
    var req = Request(cmd: cmd)
    let rest = Array(argv.dropFirst())

    // Shared flag parser. `edit` reuses it but takes an <id> first and treats every
    // flag as optional — anything you don't pass keeps its current value.
    func parseFlags(leadingID: Bool) {
        var positionals: [String] = []
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--quiet": req.quiet = true
            case "--wake": req.quiet = false
            case "--repeat", "--days":
                i += 1; guard i < rest.count else { fail("--repeat needs a value") }; req.days = rest[i]
            case "--label":
                i += 1; guard i < rest.count else { fail("--label needs a value") }; req.label = rest[i]
            case "--note":
                i += 1; guard i < rest.count else { fail("--note needs a value") }; req.note = rest[i]
            case "--time":
                i += 1; guard i < rest.count else { fail("--time needs a value") }; req.when = rest[i]
            default: positionals.append(rest[i])
            }
            i += 1
        }
        if leadingID {
            guard let id = positionals.first else { fail("usage: \(AppInfo.cli) edit <id> [--time 8:00] […]") }
            req.id = id
            // `edit a1 9:00` — a bare second positional is the new time.
            if positionals.count > 1 { req.when = positionals[1] }
            return
        }
        guard let when = positionals.first else { fail("usage: \(AppInfo.cli) \(cmd) <when> [\"<label>\"] …") }
        req.when = when
        if req.label == nil, positionals.count > 1 { req.label = positionals.dropFirst().joined(separator: " ") }
    }

    switch cmd {
    case "now", "list", "focus", "show", "hide":
        guard rest.isEmpty else { fail("usage: \(AppInfo.cli) \(cmd)") }
    case "close": guard rest.isEmpty else { fail("usage: \(AppInfo.cli) close") }; req.cmd = "quit"
    case "alarm", "timer", "set": parseFlags(leadingID: false)
    case "edit": parseFlags(leadingID: true)
    case "cancel", "toggle", "pause", "resume":
        guard rest.count == 1 else { fail("usage: \(AppInfo.cli) \(cmd) <id>") }; req.id = rest[0]
    default: fail("unknown command: \(cmd) (try: \(AppInfo.cli) help)")
    }

    // Forward CLATCH_AGENT so the app targets us when our alarm/timer fires.
    req.agent = ProcessInfo.processInfo.environment["CLATCH_AGENT"].flatMap { $0.isEmpty ? nil : $0 }

    let resp: Response
    do { resp = try sendRequest(req) } catch { fail("\(error)") }
    guard resp.ok else { fail(resp.error ?? "rejected") }

    switch cmd {
    case "now": print(resp.nowText ?? "?")
    case "list":
        print("now: \(resp.nowText ?? "?")")
        let alarms = resp.alarms ?? [], timers = resp.timers ?? []
        if alarms.isEmpty && timers.isEmpty { print("no alarms or timers"); break }
        for a in alarms { print(fmtAlarm(a)) }
        for t in timers { print(fmtTimer(t)) }
    case "alarm", "timer", "set", "edit":   // set is a smart alias → returns whichever it created
        if let a = resp.alarm { print(fmtAlarm(a)) }
        else if let t = resp.timer { print(fmtTimer(t)) }
        else if let m = resp.message { print(m) }
        else { print("ok") }
    default:
        if let m = resp.message { print(m) } else { print("ok") }
    }
    exit(0)
}

// MARK: - Dispatch

switch first {
case "app":
    if clatchInit(appId: AppInfo.id) { exit(0) }
    if let i = argv.firstIndex(of: "--control-addr") {
        guard i + 1 < argv.count else { fail("usage: \(AppInfo.cli) app --control-addr <addr>") }
        setenv("CLATCH_CONTROL_ADDR", argv[i + 1], 1)
    }
    runApp(background: argv.contains("--background"))
case "help", "-h", "--help":
    print(helpText); exit(0)
default:
    runClient(argv)
}
