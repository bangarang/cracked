import Foundation
import AppKit
import GRDB

/// One row of OpenCode's `session_v2` table (only the columns Cracked uses).
///
/// OpenCode v2 runs sessions in a server (its background service, the desktop app's
/// service, or a private `--standalone` server), not in the terminal UI, and every one
/// of them writes to the same SQLite database. So the database, not the `opencode`
/// process, is where a session's title and state live.
struct OpenCodeSessionRecord: Sendable, Equatable {
    enum Outcome: String, Sendable {
        case succeeded, failed
    }

    let id: String
    let directory: String
    let title: String?
    let createdAt: Date
    let updatedAt: Date
    /// When it last started working on a prompt.
    let busyAt: Date?
    /// When it last finished one.
    let idleAt: Date?
    /// How the last turn ended.
    let outcome: Outcome?
    /// When someone last looked at it (OpenCode's desktop and web apps record this).
    let viewedAt: Date?

    /// Busy more recently than idle: a turn is in progress.
    var isBusy: Bool {
        guard let busyAt else { return false }
        return idleAt.map { busyAt > $0 } ?? true
    }
}

/// Something an OpenCode session is waiting on you for (a permission decision, or a
/// question the agent asked), written by Cracked's OpenCode plugin to
/// `~/Library/Application Support/Cracked/opencode/` and removed once it's answered.
/// OpenCode keeps pending prompts in memory only.
struct OpenCodePendingPermission: Codable, Sendable, Equatable {
    let sessionID: String
    let message: String?
    /// Milliseconds since 1970.
    let askedAt: Double
    /// The OpenCode server that asked, so a prompt left by a server that quit is ignored.
    let pid: Int32?

    var askedDate: Date { Date(timeIntervalSince1970: askedAt / 1000) }
}

/// Where a session can be looked at, decided from the server running it (as the
/// plugin reports it).
enum OpenCodePlacement: Equatable {
    /// Its server runs under this terminal UI (`opencode --standalone`).
    case terminal(AgentProcess)
    /// Its server runs inside an app, e.g. T3 Code.
    case app(ProcessContext)
    /// A one-shot `opencode run`: not open anywhere.
    case oneShot
    /// The shared background service, or a server Cracked knows nothing about: any
    /// terminal UI in its directory may be showing it, else `fallback` (the desktop app).
    case shared(fallback: ProcessContext?)
}

enum OpenCodeAgents {
    /// A finished session counts as "done" (your move) this long, unless it has been viewed.
    static let recentlyFinishedWindow: TimeInterval = TerminalAgents.recentlyFinishedWindow
    /// A session busy for longer than this without any update is assumed abandoned
    /// (e.g. its server was killed mid-turn).
    static let busyStaleAfter: TimeInterval = 6 * 3600

    /// `$<key>/opencode`, or `~/<fallback>/opencode`: OpenCode follows the XDG base
    /// directories on macOS too.
    static func xdgDirectory(_ key: String, fallback: String,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base: URL
        if let custom = environment[key], !custom.isEmpty {
            base = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback, isDirectory: true)
        }
        return base.appendingPathComponent("opencode", isDirectory: true)
    }

    static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        xdgDirectory("XDG_DATA_HOME", fallback: ".local/share", environment: environment)
    }

    static func stateDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        xdgDirectory("XDG_STATE_HOME", fallback: ".local/state", environment: environment)
    }

    static var databaseURL: URL { dataDirectory().appendingPathComponent("opencode.db") }

    /// Where the OpenCode plugin leaves pending prompts.
    static var permissionsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Cracked/opencode", isDirectory: true)
    }

    /// Where the plugin records which OpenCode server (by PID) runs each session.
    static var serversDirectory: URL { permissionsDirectory.appendingPathComponent("servers", isDirectory: true) }

    // MARK: - Processes

    /// `opencode` subcommands that aren't a session someone has open: servers, tools,
    /// and `run`, a one-shot prompt (like `claude -p`). The bare command (the terminal
    /// UI) and `mini` are.
    static let nonSessionSubcommands: Set<String> = [
        "run", "serve", "service", "web", "acp", "api", "mcp", "debug", "auth", "models", "stats",
        "session", "plugin", "upgrade", "update", "uninstall", "export", "import", "github", "pr",
    ]

    /// Whether an `opencode` process with these arguments (argv, including argv[0]) is a
    /// session someone is using, rather than a server or a one-off tool command.
    static func isSessionProcess(arguments: [String]) -> Bool {
        guard let first = subcommand(arguments) else { return true }
        return !nonSessionSubcommands.contains(first)
    }

    static func subcommand(_ arguments: [String]) -> String? {
        arguments.dropFirst().first(where: { !$0.hasPrefix("-") })
    }

    /// Whether this is an `opencode run` process, whose session isn't open anywhere.
    static func isOneShot(arguments: [String]) -> Bool {
        guard let program = arguments.first.map({ ($0 as NSString).lastPathComponent }),
              program.hasPrefix("opencode") else { return false }
        return subcommand(arguments) == "run"
    }

    /// The OpenCode desktop app, which shows sessions run by the background service.
    static let desktopBundleID = "ai.opencode.desktop"

    /// The background service's PID, from `service.json`.
    static func servicePID(stateDirectory: URL = stateDirectory()) -> Int32? {
        guard let data = try? Data(contentsOf: stateDirectory.appendingPathComponent("service.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["pid"] as? NSNumber)?.int32Value
    }

    // MARK: - Mapping

    /// Maps a session onto Cracked's agent model. `process` is the terminal UI showing it,
    /// if any; otherwise `host` is the app it can be looked at in (e.g. T3 Code), if any.
    /// Working sessions are always listed. A finished one is only news (done or error)
    /// where you can go and look at it: open in a terminal or an app. Idle ones are
    /// listed only while open in a terminal.
    static func session(from record: OpenCodeSessionRecord, permission: OpenCodePendingPermission?,
                        process: AgentProcess?, host: ProcessContext? = nil, now: Date) -> AgentSession? {
        var session = AgentSession(
            sessionID: record.id, cwd: record.directory, status: .ready, message: nil,
            startedAt: record.createdAt, updatedAt: record.updatedAt,
            claudePID: process?.pid, terminalPID: process?.terminalPID ?? host?.terminalPID,
            terminalBundlePath: process?.terminalBundlePath ?? host?.terminalBundlePath,
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
            let open = process != nil || host?.terminalPID != nil
            if !seen && recent && open {
                session.status = record.outcome == .failed ? .error : .done
                if session.status == .error { session.message = "The last turn failed" }
                return session
            }
        }
        // Idle: only listed while it's open in a terminal.
        return process == nil ? nil : session
    }

    /// Pairs sessions in `shared` servers with the terminal UIs that may be showing them:
    /// the most recently updated session in the terminal's directory. Terminals in
    /// `claimed` already show a session of their own. Returns the terminals left over
    /// (open, but with no session yet).
    static func match(records: [OpenCodeSessionRecord], processes: [AgentProcess], claimed: Set<Int32> = [])
        -> (byRecord: [String: AgentProcess], unmatched: [AgentProcess]) {
        var byRecord: [String: AgentProcess] = [:]
        var unmatched: [AgentProcess] = []
        // Newest processes first, so the newest terminal gets the newest session.
        let free = processes.filter { !claimed.contains($0.pid) }
        for process in free.sorted(by: { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }) {
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

    /// Every session worth listing, plus terminal UIs that have no session yet.
    /// Sessions missing from `placements` count as `.shared(fallback: nil)`.
    static func sessions(records: [OpenCodeSessionRecord], permissions: [String: OpenCodePendingPermission],
                         processes: [AgentProcess], placements: [String: OpenCodePlacement] = [:],
                         now: Date) -> [AgentSession] {
        func placement(_ record: OpenCodeSessionRecord) -> OpenCodePlacement {
            placements[record.id] ?? .shared(fallback: nil)
        }
        var claimed: [String: AgentProcess] = [:]
        for record in records {
            if case .terminal(let process) = placement(record) { claimed[record.id] = process }
        }
        let shared = records.filter { if case .shared = placement($0) { true } else { false } }
        let (matched, unmatched) = match(records: shared, processes: processes,
                                         claimed: Set(claimed.values.map(\.pid)))

        let fromRecords = records.compactMap { record -> AgentSession? in
            var process: AgentProcess?
            var host: ProcessContext?
            switch placement(record) {
            case .terminal(let terminal): process = terminal
            case .app(let app): host = app
            case .oneShot: break
            case .shared(let fallback):
                process = matched[record.id]
                host = process == nil ? fallback : nil
            }
            return session(from: record, permission: permissions[record.id], process: process, host: host, now: now)
        }
        // A terminal UI with no session yet: open, nothing asked.
        let open = unmatched.compactMap { process -> AgentSession? in
            guard var session = TerminalAgents.session(for: process, claude: nil, now: now) else { return nil }
            session.status = .ready
            return session
        }
        return fromRecords + open
    }

    // MARK: - Files the plugin writes

    /// Decodes each JSON file in `directory`, removing those whose OpenCode server
    /// (`pid`) has quit.
    static func liveEntries<Entry: Decodable>(_ type: Entry.Type, in directory: URL, pid: (Entry) -> Int32?,
                                              isAlive: (Int32) -> Bool) -> [Entry] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
            if let pid = pid(entry), !isAlive(pid) {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            return entry
        }
    }

    /// The OpenCode server (PID) running each session.
    static func sessionServers(directory: URL = serversDirectory,
                               isAlive: (Int32) -> Bool = ProcessTree.isAlive) -> [String: Int32] {
        struct Entry: Decodable { let sessionID: String; let pid: Int32 }
        let entries = liveEntries(Entry.self, in: directory, pid: { $0.pid }, isAlive: isAlive)
        return Dictionary(entries.map { ($0.sessionID, $0.pid) }, uniquingKeysWith: { _, last in last })
    }

    /// The newest pending prompt of each session (a session can have several at once).
    static func pendingPermissions(directory: URL = permissionsDirectory,
                                   isAlive: (Int32) -> Bool = ProcessTree.isAlive) -> [String: OpenCodePendingPermission] {
        let entries = liveEntries(OpenCodePendingPermission.self, in: directory, pid: { $0.pid }, isAlive: isAlive)
        return Dictionary(entries.map { ($0.sessionID, $0) }, uniquingKeysWith: { $0.askedAt >= $1.askedAt ? $0 : $1 })
    }

    /// Re-keys entries for subagent (child) sessions onto their top-level session, which
    /// is the one listed. `root` maps a session to its top-level session.
    static func onRoots<Value>(_ entries: [String: Value], root: (String) -> String,
                               newer: (Value, Value) -> Bool) -> [String: Value] {
        var result: [String: Value] = [:]
        for (id, value) in entries {
            let key = root(id)
            if let existing = result[key], !newer(value, existing) { continue }
            result[key] = value
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
    /// Subagent session → its parent. Never changes once a session exists.
    private var parents: [String: String?] = [:]
    /// The app hosting each server, by server PID. A server's parents never change.
    private var hostCache: [Int32: ProcessContext] = [:]
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

    private func openQueue() throws -> DatabaseQueue {
        if let queue { return queue }
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(0.2)
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        self.queue = queue
        return queue
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
            cached = try openQueue().read { db in
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
                outcome: (row["idle_outcome"] as String?).flatMap(OpenCodeSessionRecord.Outcome.init(rawValue:)),
                viewedAt: date(row["time_viewed"])
            )
        }
    }

    /// The top-level session of each of `ids`, following `parent_id` (subagents can
    /// nest). Only sessions the plugin wrote about are looked up, and each only once.
    /// Call with the lock held.
    private func roots(of ids: Set<String>) -> [String: String] {
        let unknown = ids.filter { parents[$0] == nil }
        if !unknown.isEmpty, let queue = try? openQueue() {
            var pending = Array(unknown)
            for _ in 0..<8 where !pending.isEmpty {
                let found = (try? queue.read { db in
                    try Row.fetchAll(db, sql: "SELECT id, parent_id FROM session_v2 WHERE id IN (\(pending.map { _ in "?" }.joined(separator: ",")))",
                                     arguments: StatementArguments(pending))
                }) ?? []
                for row in found {
                    let parent: String? = row["parent_id"]
                    parents[row["id"] as String] = .some(parent)
                }
                pending = found.compactMap { $0["parent_id"] as String? }.filter { parents[$0] == nil }
            }
        }
        if parents.count > 5000 { parents.removeAll() }
        var result: [String: String] = [:]
        for id in ids {
            var current = id
            for _ in 0..<8 {
                guard let parent = parents[current] ?? nil else { break }
                current = parent
            }
            result[id] = current
        }
        return result
    }

    func sessions(processes: [AgentProcess], now: Date = Date()) -> [AgentSession] {
        let records = records(now: now)
        let rawServers = OpenCodeAgents.sessionServers()
        let rawPermissions = OpenCodeAgents.pendingPermissions()
        let servicePID = OpenCodeAgents.servicePID()
        let desktop = NSRunningApplication.runningApplications(withBundleIdentifier: OpenCodeAgents.desktopBundleID).first
        let desktopHost = desktop.map {
            ProcessContext(claudePID: nil, terminalPID: $0.processIdentifier, terminalBundlePath: $0.bundleURL?.path)
        }
        let viewed = Set(records.filter { $0.viewedAt != nil }.map(\.id))
        let terminals = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        lock.lock()
        let rootOf = roots(of: Set(rawServers.keys).union(rawPermissions.keys))
        // Prompts and servers of subagents belong to the session that's listed.
        let permissions = OpenCodeAgents.onRoots(rawPermissions, root: { rootOf[$0] ?? $0 },
                                                 newer: { $0.askedAt > $1.askedAt })
        // A subagent normally runs in its parent's server; the parent's own record wins.
        var servers: [String: Int32] = [:]
        for (id, pid) in rawServers {
            let root = rootOf[id] ?? id
            if root == id || servers[root] == nil { servers[root] = pid }
        }
        let live = Set(servers.values)
        hostCache = hostCache.filter { live.contains($0.key) }
        var placements: [String: OpenCodePlacement] = [:]
        for (sessionID, pid) in servers {
            if pid == servicePID {
                // The background service has no app of its own. Its sessions belong to the
                // desktop app if they've been opened there (the desktop app records views;
                // `opencode run` and other clients don't).
                placements[sessionID] = .shared(fallback: viewed.contains(sessionID) ? desktopHost : nil)
                continue
            }
            placements[sessionID] = Self.placement(ofServer: pid, terminals: terminals, hostCache: &hostCache)
        }
        lock.unlock()
        return OpenCodeAgents.sessions(records: records, permissions: permissions, processes: processes,
                                       placements: placements, now: now)
    }

    /// Where a (non-service) server's sessions can be looked at: the terminal UI it runs
    /// under (`--standalone`), nowhere for a one-shot `opencode run`, else the app it runs
    /// in (e.g. T3 Code).
    static func placement(ofServer pid: Int32, terminals: [Int32: AgentProcess],
                          hostCache: inout [Int32: ProcessContext]) -> OpenCodePlacement {
        let lineage = [pid] + ProcessTree.ancestors(of: pid)
        if let terminal = lineage.lazy.compactMap({ terminals[$0] }).first { return .terminal(terminal) }
        for candidate in lineage.prefix(2) {
            if let arguments = ProcessTree.arguments(of: candidate), OpenCodeAgents.isOneShot(arguments: arguments) {
                return .oneShot
            }
        }
        let host = hostCache[pid] ?? ProcessTree.context(startingAt: pid)
        hostCache[pid] = host
        return host.terminalPID != nil ? .app(host) : .shared(fallback: nil)
    }
}
