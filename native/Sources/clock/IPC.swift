import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// The app's GUI↔CLI channel: a Unix domain socket. The app (GUI process) binds a
// user-private socket directory (0700 dir, 0600 socket); the CLI connects to it.
// There is NO TCP port — the channel is a filesystem object, usable only by the
// owning user, not reachable from the network. This whole file is reusable as-is;
// only the DTOs it carries (Protocol.swift) are app-specific.

func makeAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let cap = MemoryLayout.size(ofValue: addr.sun_path) - 1
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: cap + 1) { dst in
            let n = min(bytes.count, cap)
            for i in 0..<n { dst[i] = CChar(bitPattern: bytes[i]) }
            dst[n] = 0
        }
    }
    return addr
}

// MARK: - Server (runs inside the app)

final class SocketServer {
    private let path: String
    private let handler: (Request) -> Response
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "\(AppInfo.cli).accept")

    init(path: String, handler: @escaping (Request) -> Response) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)  // clear any stale socket file

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.failed("socket() failed") }
        var addr = makeAddr(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard r == 0 else { close(fd); throw IPCError.failed("bind() failed (already running?)") }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { close(fd); throw IPCError.failed("listen() failed") }
        listenFD = fd
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        loop: while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                switch errno {
                case EINTR, ECONNABORTED, EMFILE, ENFILE, EAGAIN:
                    continue loop   // transient — keep serving the CLI
                default:
                    break loop      // listener closed (stop()) or fatal
                }
            }
            DispatchQueue.global().async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0a) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                let resp: Response
                if let req = try? JSONDecoder().decode(Request.self, from: line) {
                    // Hop to the main actor: the state model is main-actor isolated,
                    // so all mutation happens on the UI thread and never races the GUI.
                    resp = DispatchQueue.main.sync { self.handler(req) }
                } else {
                    resp = Response(ok: false, error: "bad request json")
                }
                if var out = try? JSONEncoder().encode(resp) {
                    out.append(0x0a)
                    out.withUnsafeBytes { _ = write(fd, $0.baseAddress, out.count) }
                }
            }
        }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
    }
}

enum IPCError: Error, CustomStringConvertible {
    case failed(String)
    case notRunning
    case sandboxBlocked
    var description: String {
        switch self {
        case .failed(let m): return m
        // Sandbox-aware error strings (reference/app-developer.md § Step 3): the model
        // acts on these, so a "not running" must not be reported for a blocked connect.
        case .notRunning:
            return "\(AppInfo.cli) app is not running; start it with: clatch run \(AppInfo.id)"
        case .sandboxBlocked:
            return "connection to \(AppInfo.cli) was blocked by the sandbox; retry with escalated permissions"
        }
    }
}

// MARK: - Client (the CLI)

func sendRequest(_ req: Request, path: String = SocketPath.path) throws -> Response {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw IPCError.failed("socket() failed") }
    defer { close(fd) }
    var addr = makeAddr(path)
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard r == 0 else {
        let code = errno
        switch code {
        case EPERM, EACCES: throw IPCError.sandboxBlocked
        case ENOENT, ECONNREFUSED: throw IPCError.notRunning
        default: throw IPCError.failed("could not connect to \(AppInfo.cli): \(String(cString: strerror(code)))")
        }
    }

    var out = try JSONEncoder().encode(req)
    out.append(0x0a)
    out.withUnsafeBytes { _ = write(fd, $0.baseAddress, out.count) }

    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer.append(contentsOf: chunk[0..<n])
        if buffer.contains(0x0a) { break }
    }
    guard let nl = buffer.firstIndex(of: 0x0a) else {
        throw IPCError.failed("no response")
    }
    let line = buffer.subdata(in: buffer.startIndex..<nl)
    return try JSONDecoder().decode(Response.self, from: line)
}

// True if a live app is already listening on the socket.
func appIsRunning(path: String = SocketPath.path) -> Bool {
    (try? sendRequest(Request(cmd: "ping"), path: path)) != nil
}
