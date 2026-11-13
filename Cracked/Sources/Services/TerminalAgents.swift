import Foundation
import AppKit
import Darwin

/// `~/.claude/sessions/<pid>.json`, which every running Claude Code process keeps up
/// to date itself (only the fields Cracked uses). This gives live status without hooks.
struct ClaudeSessionFile: Decodable, Sendable, Equatable {
    let pid: Int32
    let sessionId: String?
    let cwd: String?
    /// "interactive" for a session in a terminal; background jobs use other kinds.
    let kind: String?
    let name: String?
    /// "derived" when Claude Code made the name up from the directory ("developer-15").
    let nameSource: String?
    /// "busy", "idle" or "waiting".
    let status: String?
    /// Why a "waiting" session is blocked, e.g. "permission".
    let waitingFor: String?
    /// Milliseconds since 1970.
    let startedAt: Double?
    let statusUpdatedAt: Double?
}

/// A coding agent process found running on this Mac.
struct AgentProcess: Sendable, Equatable {
    enum Kind: String, Sendable {
        case claude
        case opencode
    }

    let pid: Int32
    let kind: Kind
    var cwd: String?
    /// e.g. "/dev/ttys003"; nil when it isn't attached to a terminal.
    var tty: String?
    var startedAt: Date?
    var terminalPID: Int32?
    var terminalBundlePath: String?
}

/// Finds Claude Code and OpenCode processes running in terminals, outside Paseo.
enum TerminalAgents {
    /// An idle Claude Code session counts as "done" (your move) this long after its last turn.
    static let recentlyFinishedWindow: TimeInterval = 3600

    static var claudeSessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    // MARK: - Mapping

    static func session(for process: AgentProcess, claude: ClaudeSessionFile?, now: Date) -> AgentSession? {
        let started = process.startedAt ?? now
        var session = AgentSession(
            sessionID: claude?.sessionId ?? "\(process.kind.rawValue)-\(process.pid)",
            cwd: process.cwd ?? claude?.cwd ?? "",
            status: .running, message: nil, startedAt: started, updatedAt: started,
            claudePID: process.pid, terminalPID: process.terminalPID,
            terminalBundlePath: process.terminalBundlePath,
            provider: process.kind.rawValue, scanned: true, tty: process.tty
        )

        guard process.kind == .claude else { return session }
        guard let claude else {
            // An older Claude Code without session files: only list it if it's interactive.
            return process.tty == nil ? nil : session
        }
        if let kind = claude.kind, kind != "interactive" { return nil }
        if let name = claude.name, claude.nameSource != "derived" { session.title = name }
        if let ms = claude.startedAt { session.startedAt = Date(timeIntervalSince1970: ms / 1000) }
        let changedAt = claude.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? session.startedAt
        session.updatedAt = changedAt

        switch claude.status {
        case "busy":
            session.status = .working
        case "waiting":
            session.status = .needsInput
            session.message = waitingMessage(claude.waitingFor)
        case "idle":
            // Idle since it started means nothing has been asked yet.
            let neverUsed = changedAt.timeIntervalSince(session.startedAt) < 5
            let recent = now.timeIntervalSince(changedAt) < recentlyFinishedWindow
            session.status = (!neverUsed && recent) ? .done : .ready
        default:
            session.status = .running
        }
        return session
    }

    static func waitingMessage(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return "Waiting for you" }
        if reason.contains(" ") { return reason }
        return "Waiting for " + reason.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - Scanning

    /// Claude Code sessions in terminals. OpenCode processes are mapped onto their
    /// sessions by `OpenCodeAgentReader`, which knows their state.
    static func scan(processes: [AgentProcess] = processes(), now: Date = Date()) -> [AgentSession] {
        processes.filter { $0.kind == .claude }.compactMap { process in
            let file = claudeSessionFile(pid: process.pid)
            guard var session = session(for: process, claude: file, now: now) else { return nil }
            if session.title == nil, let id = file?.sessionId {
                session.title = ClaudeTitles.title(sessionID: id, cwd: session.cwd)
            }
            return session
        }
    }

    static func claudeSessionFile(pid: Int32, directory: URL = claudeSessionsDirectory) -> ClaudeSessionFile? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(pid).json")) else { return nil }
        return try? JSONDecoder().decode(ClaudeSessionFile.self, from: data)
    }

    static func kind(name: String, path: String?) -> AgentProcess.Kind? {
        if name == "claude" { return .claude }
        if name == "opencode" { return .opencode }
        guard let path else { return nil }
        if path.hasSuffix("/opencode") { return .opencode }
        if path.hasSuffix("/claude") || path.contains("/claude/versions/") { return .claude }
        return nil
    }

    /// Agent processes outside Paseo, skipping ones started by another agent
    /// (e.g. `claude -p` run from an agent's shell) and OpenCode servers, which
    /// aren't sessions themselves.
    static func processes() -> [AgentProcess] {
        var found: [AgentProcess] = []
        let pids = ProcessTree.allPIDs()
        for pid in pids where pid > 1 {
            guard let kind = cachedKind(of: pid) else { continue }
            if kind == .opencode, let arguments = ProcessTree.arguments(of: pid),
               !OpenCodeAgents.isSessionProcess(arguments: arguments) { continue }
            guard !ProcessTree.ancestors(of: pid).contains(where: { isPaseo($0) || isAgent($0) }) else { continue }

            let context = ProcessTree.context(startingAt: pid)
            found.append(AgentProcess(
                pid: pid, kind: kind, cwd: ProcessTree.cwd(of: pid), tty: ProcessTree.tty(of: pid),
                startedAt: ProcessTree.startTime(of: pid),
                terminalPID: context.terminalPID, terminalBundlePath: context.terminalBundlePath
            ))
        }
        return found
    }

    /// Classifying a process needs its executable path (Claude Code's executable is named
    /// after its version), which is the slow part of a scan. Cache it per PID, keyed by
    /// name so a reused PID is classified again.
    private nonisolated(unsafe) static var kindCache: [pid_t: (name: String, kind: AgentProcess.Kind?)] = [:]
    private static let kindCacheLock = NSLock()

    private static func cachedKind(of pid: pid_t) -> AgentProcess.Kind? {
        let name = ProcessTree.fastName(of: pid)
        kindCacheLock.lock()
        defer { kindCacheLock.unlock() }
        if let cached = kindCache[pid], cached.name == name { return cached.kind }
        let kind = kind(name: name, path: ProcessTree.path(of: pid))
        if kindCache.count > 20_000 { kindCache.removeAll() }
        kindCache[pid] = (name, kind)
        return kind
    }

    private static func isPaseo(_ pid: pid_t) -> Bool {
        ProcessTree.name(of: pid).hasPrefix("Paseo") || (ProcessTree.path(of: pid)?.contains("/Paseo.app/") ?? false)
    }

    private static func isAgent(_ pid: pid_t) -> Bool {
        kind(name: ProcessTree.name(of: pid), path: ProcessTree.path(of: pid)) != nil
    }
}

extension ProcessTree {
    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return Array(pids.prefix(Int(max(0, filled))))
    }

    /// The process name via libproc, much cheaper than a sysctl per process when scanning everything.
    static func fastName(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    /// Parents of `pid`, nearest first, up to (not including) launchd.
    static func ancestors(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var current = parent(of: pid)
        while let candidate = current, candidate > 1, result.count < 64 {
            result.append(candidate)
            current = parent(of: candidate)
        }
        return result
    }

    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func tty(of pid: pid_t) -> String? {
        guard let info = kinfo(pid) else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    static func startTime(of pid: pid_t) -> Date? {
        guard let info = kinfo(pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// The process's argv, via KERN_PROCARGS2. Nil when it can't be read.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        // argc, then the executable path, NUL padding, then argv as NUL-terminated strings.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(argc), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }
}

/// The title Claude Code gives a session ("Ollama qwen performance limits"), which it
/// also shows as the terminal tab title. Claude Code appends `ai-title` records to the
/// session transcript, so the latest one is read from the end of the file, and only
/// again when the file changes.
enum ClaudeTitles {
    private nonisolated(unsafe) static var cache: [String: (modified: Date, title: String?)] = [:]
    private static let lock = NSLock()
    static let tailBytes = 256 * 1024

    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Claude Code names a project's transcript folder after its path, with every
    /// character other than a letter or digit replaced by "-".
    static func projectFolderName(cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func title(sessionID: String, cwd: String, projects: URL = projectsDirectory) -> String? {
        let file = projects.appendingPathComponent(projectFolderName(cwd: cwd))
            .appendingPathComponent("\(sessionID).jsonl")
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[file.path], cached.modified == modified { return cached.title }
        let title = latestTitle(in: file)
        if cache.count > 500 { cache.removeAll() }
        cache[file.path] = (modified, title)
        return title
    }

    static func latestTitle(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return latestTitle(inJSONL: data)
    }

    static func latestTitle(inJSONL data: Data) -> String? {
        let marker = Data(#""ai-title""#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               object["type"] as? String == "ai-title",
               let title = (object["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                return title
            }
        }
        return nil
    }
}

/// Brings an agent to the front: the Paseo agent, the exact terminal tab, or at least its app.
@MainActor
enum AgentNavigator {
    static func focus(_ session: AgentSession) {
        if let url = session.paseoURL {
            NSWorkspace.shared.open(url)
            return
        }
        let bundleID = session.terminalBundlePath.flatMap { Bundle(path: $0)?.bundleIdentifier }
        if bundleID == Rex.bundleID, let pid = session.claudePID {
            // The `rex` CLI finds and focuses the session's block; it takes a moment.
            Task.detached { Rex.focus(pid: pid) }
            return
        }
        if let tty = session.tty, let bundleID, let script = focusScript(bundleID: bundleID, tty: tty) {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error == nil { return }
        }
        if let pid = session.terminalPID {
            _ = AppActions.activate(pid: pid)
        }
    }

    /// AppleScript that focuses the tab or split showing `tty`, for terminals that support it.
    nonisolated static func focusScript(bundleID: String, tty: String) -> String? {
        let tty = tty.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        switch bundleID {
        case "com.mitchellh.ghostty":
            return """
                tell application id "com.mitchellh.ghostty"
                    activate
                    focus (first terminal whose tty is "\(tty)")
                end tell
                """
        case "com.googlecode.iterm2":
            return """
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select w
                                    select t
                                    select s
                                    activate
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                    error "not found"
                end tell
                """
        case "com.apple.Terminal":
            return """
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected of t to true
                                set index of w to 1
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                    error "not found"
                end tell
                """
        default:
            return nil
        }
    }
}
