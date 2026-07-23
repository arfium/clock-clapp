import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// `clatch_init(appId)` — the Steam `SteamAPI_RestartAppIfNecessary` equivalent
// (reference/launch.md). Call it FIRST THING in `app` mode, before any app work.
// It makes the dependency "this app runs only under Clatch" real, and lets a bare
// double-click route back through the launcher.
//
//   true  → we asked Clatch to relaunch the installed copy; EXIT NOW.
//   false → we are wired (or in the standalone dev hatch); continue.

@discardableResult
func clatchInit(appId: String) -> Bool {
    let env = ProcessInfo.processInfo.environment

    // 1) Wired: Clatch spawned us and injected identity.
    if env["CLATCH_INSTANCE_TOKEN"] != nil {
        if env["CLATCH_APP_ID"] != appId {
            FileHandle.standardError.write(Data(
                "\(AppInfo.cli): identity mismatch — CLATCH_APP_ID=\(env["CLATCH_APP_ID"] ?? "nil") != \(appId)\n".utf8))
            exit(1)  // binary/manifest id mismatch is a hard error
        }
        return false  // continue: connect + app.register next
    }

    // 2) Standalone dev hatch: run without a launcher.
    if env["CLATCH_STANDALONE"] == "1" {
        return false
    }

    // 3) Not wired: relaunch the INSTALLED copy through Clatch and exit.
    let clatch = env["CLATCH_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "clatch"
    let args = [clatch, "run", appId]
    let cArgs = args.map { strdup($0) } + [nil]
    execvp(clatch, cArgs)
    // execvp only returns on failure (clatch not on PATH / not installed).
    FileHandle.standardError.write(Data(
        "\(AppInfo.cli): could not reach Clatch (`\(clatch)` not found). Install this app through Clatch and launch it with: clatch run \(appId)\n".utf8))
    exit(1)
}
