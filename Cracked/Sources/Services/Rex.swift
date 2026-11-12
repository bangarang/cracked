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

    /// The block whose terminal runs `lineage` (the agent's PID and its parents):
    /// its program (e.g. `login`) or foreground process is one of them.
    static func block(containing lineage: Set<Int32>, in blocks: [(id: String, processes: BlockProcesses)]) -> String? {
        blocks.first { block in
            [block.processes.child?.pid, block.processes.foreground?.pid]
                .contains { $0.map(lineage.contains) ?? false }
        }?.id
    }

    /// Focuses the block running `pid` and brings Rex to the front. Blocking: it runs
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
        let found = blocks(cli: cli).flatMap { block(containing: lineage, in: $0) }
        if let found {
            _ = run(cli, ["focus", found, "--autostart=false"])
        }
        activate()
        return found != nil
    }

    /// `…/Rex Server.app/Contents/MacOS/rex`, next to the server's own executable.
    static func cliPath(serverPath: String?) -> String? {
        guard let serverPath else { return nil }
        let cli = ((serverPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("rex")
        return FileManager.default.isExecutableFile(atPath: cli) ? cli : nil
    }

    private static func blocks(cli: String) -> [(id: String, processes: BlockProcesses)]? {
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
              let sessions = try? JSONDecoder().decode(Sessions.self, from: data) else { return nil }
        let all = sessions.sessions.flatMap { session -> [List.Block] in
            guard let data = run(cli, ["block", "ls", "-s", session.session_id, "--json", "--autostart=false"]),
                  let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
            return list.blocks
        }
        return all
            .filter { $0.flavor?.contains("terminal") ?? true }
            .compactMap { block in
                guard let data = run(cli, ["block", "call", "process", "--block", block.block_id, "--autostart=false"]),
                      let processes = try? JSONDecoder().decode(BlockProcesses.self, from: data) else { return nil }
                return (block.block_id, processes)
            }
    }

    private static func activate() {
        _ = app?.activate()
    }

    /// Runs the CLI and returns its output, or nil if it failed.
    private static func run(_ executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
