import Foundation
import GRDB
import Testing
@testable import Cracked

@Suite("OpenCode agents")
struct OpenCodeAgentsTests {
    let now = Date(timeIntervalSince1970: 1_794_500_000)

    func record(_ id: String = "ses_a", directory: String = "/Users/me/app", title: String? = "Fix the login bug",
                created: TimeInterval = -3600, updated: TimeInterval = -60,
                busy: TimeInterval? = nil, idle: TimeInterval? = nil, outcome: String? = nil,
                viewed: TimeInterval? = nil) -> OpenCodeSessionRecord {
        func at(_ offset: TimeInterval?) -> Date? { offset.map { now.addingTimeInterval($0) } }
        return OpenCodeSessionRecord(
            id: id, directory: directory, title: title, createdAt: at(created)!, updatedAt: at(updated)!,
            busyAt: at(busy), idleAt: at(idle), outcome: outcome, viewedAt: at(viewed))
    }

    func tui(pid: Int32 = 4242, cwd: String = "/Users/me/app", started: TimeInterval = -7200) -> AgentProcess {
        AgentProcess(pid: pid, kind: .opencode, cwd: cwd, tty: "/dev/ttys004",
                     startedAt: now.addingTimeInterval(started),
                     terminalPID: 93437, terminalBundlePath: "/Applications/Ghostty.app")
    }

    func status(_ record: OpenCodeSessionRecord, permission: OpenCodePendingPermission? = nil,
                process: AgentProcess? = nil) -> AgentSession.Status? {
        OpenCodeAgents.session(from: record, permission: permission, process: process, now: now)?.status
    }

    @Test("Busy, finished, failed and seen sessions map onto Cracked's states")
    func states() {
        #expect(status(record(busy: -30, idle: -600)) == .working, "Busy since its last idle")
        #expect(status(record(busy: -30)) == .working, "Busy and never idle yet")
        #expect(status(record(busy: -600, idle: -30, outcome: "succeeded")) == .done)
        #expect(status(record(busy: -600, idle: -30, outcome: "failed")) == .error)
        #expect(status(record(busy: -600, idle: -30, outcome: "succeeded", viewed: -10)) == nil,
                "Seen since it finished, and not open in a terminal")
        #expect(status(record(busy: -600, idle: -30, outcome: "succeeded", viewed: -10), process: tui()) == .ready)
        #expect(status(record(busy: -9000, idle: -2 * OpenCodeAgents.recentlyFinishedWindow)) == nil,
                "Long finished isn't news")
        #expect(status(record(updated: -2 * OpenCodeAgents.busyStaleAfter, busy: -2 * OpenCodeAgents.busyStaleAfter)) == nil,
                "Busy forever without an update means its server died")
    }

    @Test("A pending permission from the plugin makes a busy session need input")
    func permission() throws {
        let pending = OpenCodePendingPermission(sessionID: "ses_a", message: "Waiting for permission: bash git push",
                                                askedAt: (now.timeIntervalSince1970 - 5) * 1000, pid: nil)
        let session = try #require(OpenCodeAgents.session(
            from: record(busy: -30), permission: pending, process: nil, now: now))
        #expect(session.status == .needsInput)
        #expect(session.message == "Waiting for permission: bash git push")
        #expect(session.isWaiting)

        #expect(status(record(busy: -30, idle: -10, outcome: "succeeded"), permission: pending) == .done,
                "Answered and finished")
        let older = OpenCodePendingPermission(sessionID: "ses_a", message: nil,
                                              askedAt: (now.timeIntervalSince1970 - 100) * 1000, pid: nil)
        #expect(status(record(busy: -30), permission: older) == .working, "Asked during an earlier turn")
    }

    @Test("A session carries its title, directory and the terminal it's open in")
    func fields() throws {
        let session = try #require(OpenCodeAgents.session(
            from: record(busy: -30), permission: nil, process: tui(), now: now))
        #expect(session.sessionID == "ses_a")
        #expect(session.title == "Fix the login bug")
        #expect(session.projectName == "app")
        #expect(session.agentName == "OpenCode")
        #expect(session.source == .terminal)
        #expect(session.tty == "/dev/ttys004")
        #expect(session.terminalName == "Ghostty")
    }

    @Test("Terminal UIs pair with the newest session in their directory; the rest show as open")
    func matching() {
        let records = [
            record("ses_old", updated: -5000, idle: -5000, outcome: "succeeded", viewed: -4000),
            record("ses_new", updated: -60, busy: -60),
            record("ses_elsewhere", directory: "/Users/me/other", updated: -30, busy: -30),
        ]
        let sessions = OpenCodeAgents.sessions(
            records: records, permissions: [:],
            processes: [tui(pid: 1), tui(pid: 2, cwd: "/Users/me/empty")], now: now)
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
        #expect(byID["ses_new"]?.tty == "/dev/ttys004")
        #expect(byID["ses_new"]?.claudePID == 1)
        #expect(byID["ses_old"] == nil, "Seen, finished long ago and not open")
        #expect(byID["ses_elsewhere"]?.status == .working, "Running in the desktop app or another server")
        #expect(byID["ses_elsewhere"]?.tty == nil)
        #expect(byID["opencode-2"]?.status == .ready, "Open with nothing asked yet")
    }

    @Test("OpenCode servers and tool commands aren't sessions")
    func processes() {
        #expect(OpenCodeAgents.isSessionProcess(arguments: ["opencode"]))
        #expect(OpenCodeAgents.isSessionProcess(arguments: ["opencode", "--continue"]))
        #expect(OpenCodeAgents.isSessionProcess(arguments: ["opencode", "/Users/me/app"]))
        #expect(OpenCodeAgents.isSessionProcess(arguments: ["opencode", "run", "fix it"]))
        #expect(!OpenCodeAgents.isSessionProcess(arguments: ["opencode", "serve", "--port=50494"]))
        #expect(!OpenCodeAgents.isSessionProcess(arguments: ["opencode", "acp"]))
        #expect(!OpenCodeAgents.isSessionProcess(arguments: ["opencode", "mcp", "list"]))
    }

    @Test("Our own argv reads back through KERN_PROCARGS2")
    func ownArguments() throws {
        let arguments = try #require(ProcessTree.arguments(of: getpid()))
        #expect(arguments == CommandLine.arguments)
    }

    @Test("Reads recent top-level sessions from OpenCode's database")
    func database() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("opencode.db")
        let ms = Int64(now.timeIntervalSince1970 * 1000)

        let writer = try DatabaseQueue(path: url.path)
        try writer.write { db in
            try db.execute(sql: """
                CREATE TABLE session_v2 (id text PRIMARY KEY, project_id text NOT NULL, parent_id text,
                  slug text NOT NULL, directory text NOT NULL, title text, version text NOT NULL,
                  time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer,
                  time_idle integer, time_viewed integer, idle_outcome text, time_busy integer)
                """)
            func insert(_ id: String, parent: String? = nil, updated: Int64, archived: Int64? = nil,
                        busy: Int64? = nil, idle: Int64? = nil, outcome: String? = nil) throws {
                try db.execute(sql: """
                    INSERT INTO session_v2 (id, project_id, parent_id, slug, directory, title, version,
                      time_created, time_updated, time_archived, time_busy, time_idle, idle_outcome)
                    VALUES (?, 'p', ?, 's', '/Users/me/app', 'Title', '2', ?, ?, ?, ?, ?, ?)
                    """, arguments: [id, parent, updated - 1000, updated, archived, busy, idle, outcome])
            }
            try insert("ses_busy", updated: ms - 1000, busy: ms - 1000, idle: ms - 9000, outcome: "succeeded")
            try insert("ses_child", parent: "ses_busy", updated: ms - 1000)
            try insert("ses_archived", updated: ms - 1000, archived: ms)
            try insert("ses_ancient", updated: ms - 3 * 86_400_000)
        }
        try writer.close()

        let reader = OpenCodeAgentReader(databaseURL: url)
        let records = reader.records(now: now)
        #expect(records.map(\.id) == ["ses_busy"])
        let busy = try #require(records.first)
        #expect(busy.isBusy)
        #expect(busy.outcome == "succeeded")
        #expect(busy.title == "Title")

        let missing = OpenCodeAgentReader(databaseURL: dir.appendingPathComponent("nope.db"))
        #expect(missing.records(now: now).isEmpty)
    }

    @Test("A session run by an app's own OpenCode server is shown with that app")
    func serverHost() throws {
        let host = ProcessContext(claudePID: nil, terminalPID: 96995,
                                  terminalBundlePath: "/Applications/T3 Code (Nightly).app")
        let sessions = OpenCodeAgents.sessions(
            records: [record("ses_t3", busy: -30)], permissions: [:], processes: [],
            hosts: ["ses_t3": host], now: now)
        let session = try #require(sessions.first)
        #expect(session.terminalPID == 96995)
        #expect(session.terminalName == "T3 Code (Nightly)")
        #expect(session.tty == nil)

        let inTerminal = try #require(OpenCodeAgents.sessions(
            records: [record("ses_t3", busy: -30)], permissions: [:], processes: [tui()],
            hosts: ["ses_t3": host], now: now).first)
        #expect(inTerminal.terminalName == "Ghostty", "The terminal showing it wins over the server's host")
    }

    @Test("Server records from a server that quit are dropped")
    func serverFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"sessionID":"ses_a","pid":1}"#.utf8).write(to: dir.appendingPathComponent("ses_a.json"))
        try Data(#"{"sessionID":"ses_b","pid":2}"#.utf8).write(to: dir.appendingPathComponent("ses_b.json"))
        #expect(OpenCodeAgents.sessionServers(directory: dir, isAlive: { $0 == 1 }) == ["ses_a": 1])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("ses_b.json").path))
    }

    @Test("Pending permissions from a server that quit are dropped")
    func pendingFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ id: String, pid: Int32) throws {
            let json = #"{"sessionID":"\#(id)","requestID":"per_1","message":"m","askedAt":1,"pid":\#(pid)}"#
            try Data(json.utf8).write(to: dir.appendingPathComponent("\(id).json"))
        }
        try write("ses_live", pid: 1)
        try write("ses_dead", pid: 2)
        let pending = OpenCodeAgents.pendingPermissions(directory: dir, isAlive: { $0 == 1 })
        #expect(Set(pending.keys) == ["ses_live"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("ses_dead.json").path))
    }
}

@Suite("OpenCode setup")
struct OpenCodeSetupTests {
    let exe = "/Applications/Cracked.app/Contents/MacOS/Cracked"

    @Test("The MCP server goes under mcp.servers, leaving other servers and settings alone")
    func mcp() throws {
        let original: [String: Any] = [
            "theme": "system",
            "mcp": ["servers": ["linear": ["type": "remote", "url": "https://mcp.linear.app/mcp"]],
                    "vercel": ["type": "remote"]],
        ]
        let installed = OpenCodeSetup.installingMCP(into: original, executable: exe)
        #expect(OpenCodeSetup.hasMCP(in: installed))
        let servers = try #require((installed["mcp"] as? [String: Any])?["servers"] as? [String: Any])
        #expect(servers["linear"] != nil)
        let cracked = try #require(servers["cracked"] as? [String: Any])
        #expect(cracked["type"] as? String == "local")
        #expect(cracked["command"] as? [String] == [exe, "mcp"])
        #expect(installed["theme"] as? String == "system")

        let removed = OpenCodeSetup.removingMCP(from: installed)
        #expect(!OpenCodeSetup.hasMCP(in: removed))
        #expect((removed["mcp"] as? [String: Any])?["vercel"] != nil)
        #expect(((removed["mcp"] as? [String: Any])?["servers"] as? [String: Any])?["linear"] != nil)

        let empty = OpenCodeSetup.removingMCP(from: OpenCodeSetup.installingMCP(into: [:], executable: exe))
        #expect(empty["mcp"] == nil, "Leaves no empty mcp object behind")
    }

    @Test("The plugin embeds Cracked's path safely and is marked as Cracked's")
    func plugin() {
        let source = OpenCodeSetup.pluginSource(executable: #"/Apps/My "Cracked".app/Cracked"#,
                                                pendingDirectory: URL(fileURLWithPath: "/tmp/pending"))
        #expect(source.hasPrefix(OpenCodeSetup.pluginMarker))
        #expect(source.contains(#"const CRACKED = "/Apps/My \"Cracked\".app/Cracked";"#))
        #expect(source.contains(#"const PENDING_DIR = "/tmp/pending";"#))
        #expect(source.contains(#"id: "cracked""#))
    }

    @Test("XDG_CONFIG_HOME overrides ~/.config")
    func configDirectory() {
        #expect(OpenCodeSetup.configDirectory(environment: ["XDG_CONFIG_HOME": "/tmp/c"]).path == "/tmp/c/opencode")
        #expect(OpenCodeSetup.configDirectory(environment: [:]).path.hasSuffix("/.config/opencode"))
        #expect(OpenCodeAgents.dataDirectory(environment: ["XDG_DATA_HOME": "/tmp/d"]).path == "/tmp/d/opencode")
    }
}
