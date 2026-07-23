import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// The Clatch↔App CONTROL PIPE (reference/protocol.md) — distinct from the app's own
// GUI↔CLI Unix socket (IPC.swift). Clatch is the SERVER; the app connects back to the
// injected CLATCH_CONTROL_ADDR and identifies itself in `app.register`. Framing is
// JSON-RPC 2.0, length-prefixed: a 4-byte big-endian length + a UTF-8 body.
//
// Clatch owns this channel. The app only: registers, emits `app.toAgent` when the
// user acts (or on a scheduled event), answers `app.ping`, and exits on `app.shutdown`.
// This file is reusable as-is — the app-specific part is only WHICH signals you emit.
// The envelope is {id, type, target, payload}: `id` is the signal's declared identifier
// and TYPE (run / context / buffered) is your clatch.json declaration's, stamped here
// from AppInfo.signals and RE-VALIDATED by Clatch against the manifest — a wire type
// that disagrees, or an undeclared id, is dropped. Intent is explicit on the wire;
// authority stays the declaration. The stream is ordered, so there is no sequence number.

final class ControlPipe {
    private let addr: String
    private let instanceToken: String
    private let signals: [String: String]   // declared signal id → type (run|context|buffered)
    var onShutdown: (() -> Void)?

    /// The control pipe ended without an `app.shutdown` — EOF, or fail-fast on a bad
    /// frame. socket-close IS "instance gone" (reference/protocol.md), so a wired app
    /// is now orphaned. Fires on the read thread.
    var onClose: (() -> Void)?

    // The roster Clatch PUSHES on `app.agents` (reference/protocol.md § Connected
    // agents): a full snapshot once right after register, then again on every change
    // (a bind, a rename, a model switch, a new avatar). The app just replaces its view.
    struct Avatar {
        let mime: String
        let path: String       // absolute path; same-machine (reference/data-structures.md § Agent avatar)
        let width: Int
        let height: Int
    }
    struct ConnectedAgent {
        let name: String       // the target key (app.toAgent `target: [name]`)
        let backend: String    // the brand/harness, e.g. "cline-acp"
        let model: String?     // current model, or nil
        let avatar: Avatar?    // profile image, or nil
    }
    /// The pushed roster (above), for *targeting a named, non-calling agent*. The
    /// demo leaves this unset — it targets the caller via `CLATCH_AGENT`, or
    /// broadcasts. Fires on the read thread; hop to your actor before touching UI.
    var onAgents: (([ConnectedAgent]) -> Void)?

    /// An `app.toAgent` was REFUSED whole (all-or-nothing): a receiver could not
    /// accept, so NOTHING was delivered. `id` is the refused signal's declared id;
    /// `agent` is the first receiver (name order) that could not accept; `reason` is
    /// "inbox_full" (a `run` target) or "queue_full" (a `context` target); `buffered`
    /// never refuses. Fires on the read thread. No handler = the app just doesn't react.
    var onSignalRefused: ((_ id: String, _ agent: String, _ reason: String) -> Void)?

    private var fd: Int32 = -1
    private let writeQueue = DispatchQueue(label: "\(AppInfo.cli).controlpipe.write")

    // Sanity bound. Control-pipe messages are tiny, so a frame larger than this is a
    // framing bug: we read it as desync and fail fast (§ readMessage), never skip it.
    private static let maxFrame = 1 << 20   // 1 MiB

    init?(signals: [String: String]) {
        let env = ProcessInfo.processInfo.environment
        guard let addr = env["CLATCH_CONTROL_ADDR"], !addr.isEmpty else { return nil }
        self.addr = addr
        // The per-instance socket already identifies us to Clatch; the injected token
        // is the only thing register must prove ("I am the process you spawned").
        // Bootstrap.clatchInit already verified CLATCH_APP_ID. Standalone dev (a
        // hand-wired --control-addr with no token) sends an empty token.
        self.instanceToken = env["CLATCH_INSTANCE_TOKEN"] ?? ""
        self.signals = signals
    }

    /// Connect + register. Returns false if no launcher is listening (standalone) or
    /// if the launcher rejects the handshake.
    @discardableResult
    func start() -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var sa = makeAddr(addr)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) }
        }
        guard r == 0 else { close(s); return false }
        fd = s

        // The per-instance socket names us; the token proves us; the manifest already
        // holds our id, our signals, and the protocol major we target — so register
        // carries only the token, the one thing Clatch cannot already know.
        let registered = sendSync([
            "jsonrpc": "2.0", "id": 1, "method": "app.register",
            "params": ["instanceToken": instanceToken],
        ]) && readRegisterResponse()

        guard registered else {
            close(fd)
            fd = -1
            return false
        }

        DispatchQueue.global().async { [weak self] in self?.readLoop() }
        return true
    }

    /// Send a declared signal to the agent(s): the `app.toAgent` method, app→clatch,
    /// fire-and-forget. The wire is `{id, type, target, payload}` — `id` is the
    /// signal's declared identifier (NOT a per-emission id; the stream is ordered),
    /// and `type` is looked up from that declaration and stamped on, so intent is
    /// explicit and Clatch re-validates it (a mismatch or an undeclared id is dropped).
    ///
    /// `target` is a list of agent names. Empty (the default) = broadcast to every
    /// bound-and-uncut agent; non-empty = only those, still intersected with the cut
    /// matrix (you can never reach an agent that did not grant you). You know who to
    /// target because Clatch injects `CLATCH_AGENT` into every agent's CLI shell, so
    /// you can wake the caller, a named other agent, a set, or everyone.
    func emitSignal(_ id: String, target: [String] = [], _ payload: [String: String] = [:]) {
        guard fd >= 0 else { return }
        guard let type = signals[id] else {
            FileHandle.standardError.write(Data("\(AppInfo.cli): refusing to emit undeclared signal '\(id)'\n".utf8))
            return
        }
        send([
            "jsonrpc": "2.0", "method": "app.toAgent",
            "params": ["id": id, "type": type, "target": target, "payload": payload],
        ])
    }

    /// `app.notify` (app→clatch, optional): a short line for the USER's Clatch chat
    /// surface — distinct from your app's own GUI. Fire-and-forget. Use it to tell
    /// the human something Clatch should show (e.g. why a refused signal didn't land).
    func notify(_ text: String) {
        guard fd >= 0 else { return }
        send(["jsonrpc": "2.0", "method": "app.notify", "params": ["text": text]])
    }

    // MARK: - Framing

    private func makeFrame(_ obj: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        var frame = Data(count: 4)
        let n = UInt32(body.count).bigEndian
        withUnsafeBytes(of: n) { frame.replaceSubrange(0..<4, with: $0) }
        frame.append(body)
        return frame
    }

    private func sendSync(_ obj: [String: Any]) -> Bool {
        guard let frame = makeFrame(obj) else { return false }
        return writeQueue.sync { writeAll(frame) }
    }

    private func send(_ obj: [String: Any]) {
        guard let frame = makeFrame(obj) else { return }
        writeQueue.async { [fd] in
            var remaining = frame.count
            frame.withUnsafeBytes { raw in
                var ptr = raw.baseAddress
                while remaining > 0, let current = ptr {
                    let wrote = write(fd, current, remaining)
                    if wrote <= 0 { break }
                    remaining -= wrote
                    ptr = current.advanced(by: wrote)
                }
            }
        }
    }

    private func writeAll(_ data: Data) -> Bool {
        var remaining = data.count
        return data.withUnsafeBytes { raw in
            var ptr = raw.baseAddress
            while remaining > 0, let current = ptr {
                let wrote = write(fd, current, remaining)
                if wrote <= 0 { return false }
                remaining -= wrote
                ptr = current.advanced(by: wrote)
            }
            return true
        }
    }

    private func readExact(_ n: Int) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: n)
        while out.count < n {
            let got = read(fd, &buf, n - out.count)
            if got <= 0 { return nil }
            out.append(contentsOf: buf[0..<got])
        }
        return out
    }

    private func readLoop() {
        while let msg = readMessage() { handle(msg) }
        close(fd); fd = -1
        onClose?()   // the pipe ended (EOF, or fail-fast on a bad frame): we're detached
    }

    /// Read one frame, FAIL-FAST. Both ends of this pipe are Clatch (its daemon writes,
    /// this binding reads), so a malformed or absurdly-sized frame is a framing BUG and
    /// the stream is already desynced (the next length can't be trusted). We surface it
    /// by returning nil → the loop closes the connection, instead of hiding it by
    /// skipping. A clean end-of-stream returns nil too (the peer closed); both end the loop.
    private func readMessage() -> [String: Any]? {
        guard let lenData = readExact(4) else { return nil }       // peer closed
        let len = lenData.reduce(0) { ($0 << 8) | Int($1) }
        guard len > 0, len <= Self.maxFrame,                       // a bad length is a bug: fail fast
              let body = readExact(len),
              let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }                                        // desync / garbage: close, don't hide
        return msg
    }

    private func readRegisterResponse() -> Bool {
        guard let msg = readMessage(), numericId(msg["id"]) == 1 else {
            FileHandle.standardError.write(Data("\(AppInfo.cli): Clatch register failed: no response\n".utf8))
            return false
        }
        if msg["result"] != nil { return true }
        let error = msg["error"] as? [String: Any]
        let message = error?["message"] as? String ?? "rejected"
        FileHandle.standardError.write(Data("\(AppInfo.cli): Clatch register failed: \(message)\n".utf8))
        return false
    }

    private func numericId(_ id: Any?) -> Int? {
        if let id = id as? Int { return id }
        if let id = id as? NSNumber { return id.intValue }
        return nil
    }

    private func handle(_ msg: [String: Any]) {
        guard let method = msg["method"] as? String else { return }  // ignore responses
        let id = msg["id"]
        switch method {
        case "app.ping":
            if let id = id { _ = reply(id: id, result: ["ok": true]) }
        case "app.shutdown":
            if let id = id { _ = reply(id: id, result: ["ok": true]) }
            onShutdown?()
        case "app.agents":
            updateAgents(msg)   // pushed roster of this app's bound agents (for targeting)
        case "app.toAgentRefused":
            handleRefusal(msg)  // an all-or-nothing fan-out was refused whole
        default:
            break               // unknown method: ignore, keep the stream healthy
        }
    }

    /// Apply an `app.toAgentRefused` notice: a `run`/`context` emission was refused
    /// whole because a receiver could not accept it (all-or-nothing).
    private func handleRefusal(_ msg: [String: Any]) {
        guard let params = msg["params"] as? [String: Any] else { return }
        let id = params["id"] as? String ?? "?"
        let agent = params["agent"] as? String ?? "?"
        let reason = params["reason"] as? String ?? "refused"
        onSignalRefused?(id, agent, reason)
    }

    /// Apply an `app.agents` push: a full snapshot of the agents bound to this app
    /// (reference/protocol.md § Connected agents). Full-snapshot-on-change means we
    /// just replace our view; the ordered stream already delivers snapshots in order.
    private func updateAgents(_ msg: [String: Any]) {
        guard let params = msg["params"] as? [String: Any] else { return }
        let rows = (params["agents"] as? [[String: Any]]) ?? []
        let agents = rows.compactMap { row -> ConnectedAgent? in
            guard let name = row["name"] as? String,
                  let backend = row["backend"] as? String else { return nil }
            var avatar: Avatar?
            if let a = row["avatar"] as? [String: Any],
               let mime = a["mime"] as? String, let path = a["path"] as? String {
                avatar = Avatar(mime: mime, path: path,
                                width: numericId(a["width"]) ?? 0,
                                height: numericId(a["height"]) ?? 0)
            }
            return ConnectedAgent(name: name, backend: backend,
                                  model: row["model"] as? String, avatar: avatar)
        }
        onAgents?(agents)
    }

    private func reply(id: Any, result: [String: Any]) -> Bool {
        sendSync(["jsonrpc": "2.0", "id": id, "result": result])
    }
}
