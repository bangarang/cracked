import Foundation
import GRDB

/// One row of OpenCode's `session_v2` table (only the columns Cracked uses).
///
/// OpenCode v2 runs sessions in a server (its background service, the desktop app's
/// service, or a private `--standalone` server), not in the terminal UI, and every one
/// of them writes to the same SQLite database. So the database, not the `opencode`
/// process, is where a session's title and state live.
struct OpenCodeSessionRecord: Sendable, Equatable {
    let id: String
    let directory: String
    let title: String?
    let createdAt: Date
    let updatedAt: Date
    /// When it last started working on a prompt.
    let busyAt: Date?
    /// When it last finished one.
    let idleAt: Date?
    /// How the last turn ended: "succeeded" or "failed".
    let outcome: String?
    /// When someone last looked at it (OpenCode's desktop and web apps record this).
    let viewedAt: Date?

    /// Busy more recently than idle: a turn is in progress.
    var isBusy: Bool {
        guard let busyAt else { return false }
        return idleAt.map { busyAt > $0 } ?? true
    }
}

/// A permission prompt an OpenCode session is waiting on, written by Cracked's OpenCode
/// plugin to `~/Library/Application Support/Cracked/opencode/<session>.json` and
/// removed once it's answered. OpenCode keeps pending prompts in memory only.
struct OpenCodePendingPermission: Codable, Sendable, Equatable {
    let sessionID: String
    let message: String?
    /// Milliseconds since 1970.
    let askedAt: Double
    /// The OpenCode server that asked, so a prompt left by a server that quit is ignored.
    let pid: Int32?

    var askedDate: Date { Date(timeIntervalSince1970: askedAt / 1000) }
}

enum OpenCodeAgents {
    /// A finished session counts as "done" (your move) this long, unless it has been viewed.
    static let recentlyFinishedWindow: TimeInterval = TerminalAgents.recentlyFinishedWindow
    /// A session busy for longer than this without any update is assumed abandoned
    /// (e.g. its server was killed mid-turn).
    static let busyStaleAfter: TimeInterval = 6 * 3600

    /// `$XDG_DATA_HOME/opencode`, or `~/.local/share/opencode`.
    static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["XDG_DATA_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    static var databaseURL: URL { dataDirectory().appendingPathComponent("opencode.db") }

    /// Where the OpenCode plugin leaves pending permission prompts.
    static var permissionsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Cracked/opencode", isDirectory: true)
    }

    // MARK: - Processes

    /// `opencode` subcommands that don't run a session of their own (servers and tools).
    /// The bare command (the terminal UI), `mini` and `run` do.
    static let nonSessionSubcommands: Set<String> = [
        "serve", "service", "web", "acp", "api", "mcp", "debug", "auth", "models", "stats",
        "session", "plugin", "upgrade", "update", "uninstall", "export", "import", "github", "pr",
    ]

    /// Whether an `opencode` process with these arguments (argv, including argv[0]) is a
    /// session someone is using, rather than a server or a one-off tool command.
    static func isSessionProcess(arguments: [String]) -> Bool {
        guard let first = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return true }
        return !nonSessionSubcommands.contains(first)
    }

    // MARK: - Mapping

    /// Maps a session onto Cracked's agent model. `process` is the terminal UI showing it,
    /// if one was found. Returns nil for sessions that aren't worth listing: idle, seen or
    /// long finished, and not open in a terminal.
    static func session(from record: OpenCodeSessionRecord, permission: OpenCodePendingPermission?,
                        process: AgentProcess?, now: Date) -> AgentSession? {
        var session = AgentSession(
            sessionID: record.id, cwd: record.directory, status: .ready, message: nil,
            startedAt: record.createdAt, updatedAt: record.updatedAt,
            claudePID: process?.pid, terminalPID: process?.terminalPID,
            terminalBundlePath: process?.terminalBundlePath,
            title: record.title.flatMap { $0.isEmpty ? nil : $0 },
            provider: AgentProcess.Kind.opencode.rawValue, scanned: true, tty: process?.tty
        )

        if record.isBusy, now.timeIntervalSince(record.updatedAt) < busyStaleAfter {
            if let permission, permission.askedDate >= (record.busyAt ?? .distantPast) {
                session.status = .needsInput
                session.message = permission.message ?? "Waiting for permission"
                session.updatedAt = permission.askedDate
            } else {
                session.status = .working
                session.updatedAt = record.busyAt ?? record.updatedAt
            }
            return session
        }

        if let idleAt = record.idleAt {
            let seen = record.viewedAt.map { $0 >= idleAt } ?? false
            let recent = now.timeIntervalSince(idleAt) < recentlyFinishedWindow
            session.updatedAt = idleAt
            if !seen && recent {
                session.status = record.outcome == "failed" ? .error : .done
                if session.status == .error { session.message = "The last turn failed" }
                return session
            }
        }
        // Idle: only listed while it's open in a terminal.
        return process == nil ? nil : session
    }

    /// Pairs each session with the terminal UI showing it: the most recently updated
    /// session in the same directory. Returns the processes left over (open, but with
    /// no session yet).
    static func match(records: [OpenCodeSessionRecord], processes: [AgentProcess])
        -> (byRecord: [String: AgentProcess], unmatched: [AgentProcess]) {
        var byRecord: [String: AgentProcess] = [:]
        var unmatched: [AgentProcess] = []
        // Newest processes first, so the newest terminal gets the newest session.
        for process in processes.sorted(by: { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }) {
            let candidate = records
                .filter { $0.directory == process.cwd && byRecord[$0.id] == nil }
                .max { $0.updatedAt < $1.updatedAt }
            if let candidate, candidate.updatedAt >= (process.startedAt ?? .distantPast).addingTimeInterval(-5) {
                byRecord[candidate.id] = process
            } else {
                unmatched.append(process)
            }
        }
        return (byRecord, unmatched)
    }

    static func sessions(records: [OpenCodeSessionRecord], permissions: [String: OpenCodePendingPermission],
                         processes: [AgentProcess], now: Date) -> [AgentSession] {
        let (byRecord, unmatched) = match(records: records, processes: processes)
        let fromRecords = records.compactMap {
            session(from: $0, permission: permissions[$0.id], process: byRecord[$0.id], now: now)
        }
        // A terminal UI with no session yet: open, nothing asked.
        let open = unmatched.compactMap { process -> AgentSession? in
            guard var session = TerminalAgents.session(for: process, claude: nil, now: now) else { return nil }
            session.status = .ready
            return session
        }
        return fromRecords + open
    }

    // MARK: - Pending permissions

    static func pendingPermissions(directory: URL = permissionsDirectory,
                                   isAlive: (Int32) -> Bool = ProcessTree.isAlive) -> [String: OpenCodePendingPermission] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [:] }
        var result: [String: OpenCodePendingPermission] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let pending = try? JSONDecoder().decode(OpenCodePendingPermission.self, from: data) else { continue }
            if let pid = pending.pid, !isAlive(pid) {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            result[pending.sessionID] = pending
        }
        return result
    }
}

/// Reads recent sessions from OpenCode's database. The menu bar refreshes agents every
/// second, so the connection is kept open and the query only runs when the database changed.
final class OpenCodeAgentReader: @unchecked Sendable {
    /// Sessions untouched for longer than this aren't read at all.
    static let lookback: TimeInterval = 24 * 3600

    let databaseURL: URL
    private var queue: DatabaseQueue?
    private var lastModified: Date?
    private var cached: [OpenCodeSessionRecord] = []
    private let lock = NSLock()

    init(databaseURL: URL = OpenCodeAgents.databaseURL) {
        self.databaseURL = databaseURL
    }

    /// The database and its write-ahead log change on every write.
    private func modificationDate() -> Date? {
        let fm = FileManager.default
        let dates = [databaseURL.path, databaseURL.path + "-wal"].compactMap {
            (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
        return dates.max()
    }

    func records(now: Date = Date()) -> [OpenCodeSessionRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let modified = modificationDate() else {
            queue = nil
            cached = []
            return []
        }
        if modified == lastModified { return cached }
        do {
            if queue == nil {
                var config = Configuration()
                config.readonly = true
                config.busyMode = .timeout(0.2)
                queue = try DatabaseQueue(path: databaseURL.path, configuration: config)
            }
            cached = try queue!.read { db in
                try Self.fetch(db, since: now.addingTimeInterval(-Self.lookback))
            }
            lastModified = modified
        } catch {
            // A schema we don't know, or the database is mid-migration: show nothing rather than guess.
            queue = nil
            cached = []
        }
        return cached
    }

    static func fetch(_ db: Database, since: Date) throws -> [OpenCodeSessionRecord] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, directory, title, time_created, time_updated, time_busy, time_idle, idle_outcome, time_viewed
            FROM session_v2
            WHERE parent_id IS NULL AND time_archived IS NULL AND time_updated >= ?
            ORDER BY time_updated DESC
            LIMIT 200
            """, arguments: [Int64(since.timeIntervalSince1970 * 1000)])
        func date(_ ms: Int64?) -> Date? { ms.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
        return rows.map { row in
            OpenCodeSessionRecord(
                id: row["id"], directory: row["directory"], title: row["title"],
                createdAt: date(row["time_created"]) ?? .distantPast,
                updatedAt: date(row["time_updated"]) ?? .distantPast,
                busyAt: date(row["time_busy"]), idleAt: date(row["time_idle"]),
                outcome: row["idle_outcome"], viewedAt: date(row["time_viewed"])
            )
        }
    }

    func sessions(processes: [AgentProcess], now: Date = Date()) -> [AgentSession] {
        OpenCodeAgents.sessions(records: records(now: now), permissions: OpenCodeAgents.pendingPermissions(),
                                processes: processes, now: now)
    }
}
