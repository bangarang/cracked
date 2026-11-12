import Foundation
import AppKit

/// Rex, a terminal multiplexer (`com.superlogical.rex`). Its terminals ("blocks") run inside a
/// background Rex Server process that macOS starts, not inside the Rex app, so a
/// shell in Rex sits under `Rex Server → launchd` and the app never appears among
/// its parents. Cracked credits the Rex app as the host instead, and focuses a
/// session's exact block with the `rex` CLI bundled in Rex Server.
enum Rex {
    static let bundleID = "com.superlogical.rex"

    /// Whether this executable is Rex Server, which hosts Rex's terminals.
    static func isServer(path: String?) -> Bool {
        path?.contains("/Rex Server.app/") ?? false
    }

    /// The running Rex app, which shows Rex Server's terminals.
    static var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    // MARK: - Focus

    /// One Rex terminal block and the processes in it, from `rex block call process`.
    struct BlockProcesses: Decodable, Equatable {
        struct Process: Decodable, Equatable {
            let pid: Int32
        }
        let child: Process?
        let foreground: Process?
    }

    /// A terminal block, the Rex session it's in, and the processes in it.
    struct Block: Equatable {
        let id: String
        let session: String
        let processes: BlockProcesses
    }

    /// The block whose terminal runs `lineage` (the agent's PID and its parents):
    /// its program (e.g. `login`) or foreground process is one of them.
    static func block(containing lineage: Set<Int32>, in blocks: [Block]) -> Block? {
        blocks.first { block in
            [block.processes.child?.pid, block.processes.foreground?.pid]
                .contains { $0.map(lineage.contains) ?? false }
        }
    }

    /// Focuses the block running `pid`, shows its session and brings Rex to the front. Blocking: it runs
    /// the `rex` CLI a few times, so call it off the main thread. Returns false when the
    /// block couldn't be found, after still bringing Rex to the front.
    @discardableResult
    static func focus(pid: Int32) -> Bool {
        let ancestors = ProcessTree.ancestors(of: pid)
        let lineage = Set([pid] + ancestors)
        // The CLI that ships with the server running this terminal, so versions match.
        guard let server = ancestors.first(where: { isServer(path: ProcessTree.path(of: $0)) }),
              let cli = cliPath(serverPath: ProcessTree.path(of: server)) else {
            activate()
            return false
        }
        let found = block(containing: lineage, in: blocks(cli: cli))
        if let found {
            // Focus the block within its session, then show that session (it may not be the
            // one on screen). Rex applies `show` asynchronously at the session's focused
            // block, so showing first could land after, and undo, the focus.
            _ = run(cli, ["focus", found.id, "--autostart=false"])
            // `show` also brings Rex to the front. Activating the app as well would raise
            // whichever window macOS last had in front, undoing the focus.
            if show(session: found.session) { return true }
        }
        activate()
        return found != nil
    }

    /// AppleScript that shows a Rex session. Rex's AppleScript IDs are
    /// `<host>/<session id>`; the CLI reports the session ID alone.
    static func showScript(session: String) -> String? {
        guard !session.isEmpty, session.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" || $0 == "_" })
        else { return nil }
        return """
            tell application id "\(bundleID)" to show (first session whose id ends with "/\(session)")
            """
    }

    private static func show(session: String) -> Bool {
        guard let script = showScript(session: session) else { return false }
        // osascript rather than NSAppleScript, which isn't safe off the main thread.
        return run("/usr/bin/osascript", ["-e", script]) != nil
    }

    /// `…/Rex Server.app/Contents/MacOS/rex`, next to the server's own executable.
    static func cliPath(serverPath: String?) -> String? {
        guard let serverPath else { return nil }
        let cli = ((serverPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("rex")
        return FileManager.default.isExecutableFile(atPath: cli) ? cli : nil
    }

    private static func blocks(cli: String) -> [Block] {
        struct Sessions: Decodable {
            struct Session: Decodable { let session_id: String }
            let sessions: [Session]
        }
        struct List: Decodable {
            struct Block: Decodable {
                let block_id: String
                let flavor: String?
            }
            let blocks: [Block]
        }
        // `block ls --json` lists one session at a time.
        guard let data = run(cli, ["ls", "--json", "--autostart=false"]),
              let sessions = try? JSONDecoder().decode(Sessions.self, from: data) else { return [] }
        let all = sessions.sessions.flatMap { session -> [(List.Block, String)] in
            guard let data = run(cli, ["block", "ls", "-s", session.session_id, "--json", "--autostart=false"]),
                  let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
            return list.blocks.map { ($0, session.session_id) }
        }
        return all
            .filter { $0.0.flavor?.contains("terminal") ?? true }
            .compactMap { block, session in
                guard let data = run(cli, ["block", "call", "process", "--block", block.block_id, "--autostart=false"]),
                      let processes = try? JSONDecoder().decode(BlockProcesses.self, from: data) else { return nil }
                return Block(id: block.block_id, session: session, processes: processes)
            }
    }

    private static func activate() {
        _ = app?.activate()
    }

    /// Each CLI call answers in well under a second; a stuck one is given up on.
    static let commandTimeout: TimeInterval = 3

    /// Runs a command and returns its output, or nil if it failed or took too long.
    private static func run(_ executable: String, _ arguments: [String]) -> Data? {
        final class Output: @unchecked Sendable { var data = Data() }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Read on another thread (so a full pipe can't stall the command) and wait for
        // end of output, which comes when the command exits.
        let output = Output()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + commandTimeout) == .success else {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? output.data : nil
    }
}
