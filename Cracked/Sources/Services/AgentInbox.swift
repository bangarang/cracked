import Foundation
import AppKit
import Darwin

/// One coding agent: a Claude Code session reported by hooks, a Paseo agent read
/// from the Paseo daemon's state (see `PaseoAgents`), or a Claude Code / OpenCode
/// process found running in a terminal (see `TerminalAgents`).
struct AgentSession: Codable, Identifiable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        /// Reported by Cracked's Claude Code hooks.
        case claudeCode
        case paseo
        /// Found by scanning running processes.
        case terminal
    }

    enum Status: String, Codable, Sendable {
        /// Session open, nothing asked yet.
        case ready
        /// Working on a prompt.
        case working
        /// Blocked mid-task, e.g. waiting for a permission decision.
        case needsInput
        /// Finished its turn; your move.
        case done
        /// The agent hit an error (Paseo only).
        case error
        /// Running, but it doesn't report what it's doing (OpenCode in a terminal).
        case running
    }

    let sessionID: String
    var cwd: String
    var status: Status
    var message: String?
    var startedAt: Date
    var updatedAt: Date
    /// The `claude` process, used to drop sessions whose process has exited.
    var claudePID: Int32?
    /// The GUI app hosting the session (Ghostty, Warp, Cursor…), used to bring it to the front.
    var terminalPID: Int32?
    var terminalBundlePath: String?
    var transcriptPath: String?
    // Paseo agents only. All optional so hook files written before Paseo support still decode.
    var paseoAgentID: String?
    var paseoServerID: String?
    /// The agent's title in Paseo (usually the start of its first prompt).
    var title: String?
    /// The provider running the agent, e.g. "claude" or "opencode".
    var provider: String?
    /// Set for agents found by scanning processes.
    var scanned: Bool?
    /// The agent's terminal, e.g. "/dev/ttys003", used to focus the exact tab.
    var tty: String?

    var id: String { sessionID }

    var source: Source {
        if paseoAgentID != nil { return .paseo }
        return scanned == true ? .terminal : .claudeCode
    }

    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? (source == .paseo ? "Paseo" : "Claude Code") : name
    }

    /// "Claude", "OpenCode"… for notifications ("Claude is done").
    var agentName: String {
        switch provider {
        case nil, "claude": "Claude"
        case "opencode": "OpenCode"
        case "codex": "Codex"
        case let other?: other.prefix(1).uppercased() + other.dropFirst()
        }
    }

    /// Opens this agent in the Paseo app.
    var paseoURL: URL? {
        guard let agent = paseoAgentID, let server = paseoServerID else { return nil }
        return PaseoAgents.deepLink(serverID: server, agentID: agent)
    }

    var terminalName: String? {
        terminalBundlePath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
    }

    /// Whether this session is waiting on the user.
    var isWaiting: Bool { status == .needsInput || status == .done || status == .error }

    /// Permission prompts produce a Notification hook but nothing when they are answered.
    /// If the transcript has been written since, the session is evidently working again.
    func effectiveStatus(transcriptModifiedAt: Date?) -> Status {
        if status == .needsInput, let modified = transcriptModifiedAt,
           modified > updatedAt.addingTimeInterval(3) {
            return .working
        }
        return status
    }
}

/// The JSON Claude Code sends a hook on stdin (only the fields Cracked uses).
struct HookInput: Decodable, Sendable {
    let sessionID: String
    let hookEventName: String
    let cwd: String?
    let message: String?
    let transcriptPath: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case hookEventName = "hook_event_name"
        case cwd, message
        case transcriptPath = "transcript_path"
    }
}

/// Where a hook process sits in the process tree.
struct ProcessContext: Sendable, Equatable {
    var claudePID: Int32?
    var terminalPID: Int32?
    var terminalBundlePath: String?
}

enum AgentInbox {
    /// Posted (distributed) by `Cracked hook` so the running app refreshes immediately.
    static let changedNotification = Notification.Name("com.bangarang.cracked.agentsChanged")

    // MARK: - State machine

    /// Applies one hook event to a session. Returns nil when the session has ended.
    static func apply(_ input: HookInput, to existing: AgentSession?,
                      context: ProcessContext, now: Date) -> AgentSession? {
        if input.hookEventName == "SessionEnd" { return nil }

        var session = existing ?? AgentSession(
            sessionID: input.sessionID, cwd: input.cwd ?? "", status: .ready,
            message: nil, startedAt: now, updatedAt: now
        )
        if let cwd = input.cwd, !cwd.isEmpty { session.cwd = cwd }
        if let transcript = input.transcriptPath { session.transcriptPath = transcript }
        session.claudePID = context.claudePID ?? session.claudePID
        session.terminalPID = context.terminalPID ?? session.terminalPID
        session.terminalBundlePath = context.terminalBundlePath ?? session.terminalBundlePath

        switch input.hookEventName {
        case "SessionStart":
            // Also fires on resume and after compaction; only a brand-new session resets state.
            if existing != nil { return session }
            session.status = .ready
        case "UserPromptSubmit":
            session.status = .working
            session.message = nil
        case "Notification":
            // An idle reminder after the turn ended isn't news.
            if session.status == .done || session.status == .ready { return session }
            session.status = .needsInput
            session.message = input.message
        case "Stop":
            session.status = .done
            session.message = nil
        default:
            return session
        }
        session.updatedAt = now
        return session
    }

    // MARK: - Storage (one JSON file per session)

    static var directory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Cracked/agents", isDirectory: true)
    }

    static func fileURL(for sessionID: String) -> URL {
        let safe = sessionID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent("\(safe.isEmpty ? "unknown" : safe).json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func read(sessionID: String) -> AgentSession? {
        guard let data = try? Data(contentsOf: fileURL(for: sessionID)) else { return nil }
        return try? decoder.decode(AgentSession.self, from: data)
    }

    static func write(_ session: AgentSession) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: fileURL(for: session.sessionID), options: .atomic)
    }

    static func delete(sessionID: String) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionID))
    }

    /// All live sessions, most recently updated first. Sessions whose `claude`
    /// process has exited (or that are very old) are removed.
    static func loadAll(now: Date = Date()) -> [AgentSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var sessions: [AgentSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(AgentSession.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let processGone = session.claudePID.map { !ProcessTree.isAlive($0) } ?? false
            let stale = now.timeIntervalSince(session.updatedAt) > 3 * 86400
            if processGone || stale {
                try? FileManager.default.removeItem(at: file)
            } else {
                sessions.append(session)
            }
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func transcriptModifiedAt(_ session: AgentSession) -> Date? {
        guard let path = session.transcriptPath else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: - Hook entry point

    /// Handles one Claude Code hook invocation (`Cracked hook`). Never fails loudly:
    /// a broken hook should never get in the way of Claude Code.
    static func handleHook(stdin: Data, now: Date = Date()) -> HookInput? {
        guard let input = try? JSONDecoder().decode(HookInput.self, from: stdin) else { return nil }
        let existing = read(sessionID: input.sessionID)
        // Walking the process tree is only needed once per session.
        let context = (existing?.claudePID == nil || existing?.terminalPID == nil)
            ? ProcessTree.context() : ProcessContext()
        if let updated = apply(input, to: existing, context: context, now: now) {
            write(updated)
        } else {
            delete(sessionID: input.sessionID)
        }
        DistributedNotificationCenter.default().postNotificationName(
            changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
        return input
    }
}

/// Small libproc/sysctl helpers for walking up the process tree.
enum ProcessTree {
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func name(of pid: pid_t) -> String {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return "" }
        return withUnsafePointer(to: &info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func isClaude(_ pid: pid_t) -> Bool {
        if name(of: pid) == "claude" { return true }
        guard let path = path(of: pid) else { return false }
        return path.hasSuffix("/claude") || path.contains("/claude/versions/")
    }

    /// Walks up from `pid` to find the Claude Code process and the GUI app hosting it.
    static func context(startingAt pid: pid_t = getpid()) -> ProcessContext {
        var context = ProcessContext()
        var current = parent(of: pid)
        var hops = 0
        while let candidate = current, candidate > 1, hops < 32 {
            if context.claudePID == nil, isClaude(candidate) {
                context.claudePID = candidate
            }
            if let app = NSRunningApplication(processIdentifier: candidate),
               app.activationPolicy == .regular {
                context.terminalPID = candidate
                context.terminalBundlePath = app.bundleURL?.path
                break
            }
            // Rex's terminals run in Rex Server, a background process; the Rex app shows them.
            if Rex.isServer(path: path(of: candidate)) {
                if let app = Rex.app {
                    context.terminalPID = app.processIdentifier
                    context.terminalBundlePath = app.bundleURL?.path
                }
                break
            }
            current = parent(of: candidate)
            hops += 1
        }
        return context
    }
}
