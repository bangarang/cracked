import Foundation
import Testing
@testable import Cracked

/// A Paseo agent record as the daemon writes it to `~/.paseo/agents/<project>/<id>.json`.
private func paseoJSON(id: String = "c7ff450f-2db1-4815-a7c5-8fd201f936d5", status: String = "idle",
                       attention: String? = nil, lastActivity: String = "2026-11-10T21:25:17.235Z",
                       archived: Bool = false, lastError: String? = nil, sessionID: String = "f509068b") -> Data {
    var json: [String: Any] = [
        "id": id, "provider": "claude", "cwd": "/Users/me/Developer/clearing",
        "createdAt": "2026-11-07T00:29:59.172Z", "updatedAt": lastActivity, "lastActivityAt": lastActivity,
        "title": "Take a look at the handoff spec", "labels": [:] as [String: String],
        "lastStatus": status, "requiresAttention": attention != nil,
        "attentionReason": attention ?? NSNull(), "attentionTimestamp": attention != nil ? "2026-11-10T21:26:00.000Z" : NSNull(),
        "internal": false, "archivedAt": archived ? "2026-11-10T22:00:00.000Z" : NSNull(),
        "runtimeInfo": ["provider": "claude", "sessionId": sessionID, "model": "claude-opus-5-5"],
        "persistence": ["provider": "claude", "sessionId": sessionID, "nativeHandle": sessionID],
        "features": [] as [Any],
    ]
    if let lastError { json["lastError"] = lastError }
    return try! JSONSerialization.data(withJSONObject: json)
}

private func record(_ data: Data) throws -> PaseoAgentRecord {
    try PaseoAgents.decoder.decode(PaseoAgentRecord.self, from: data)
}

@Suite("Paseo agents")
struct PaseoAgentsTests {
    /// Shortly after the fixture's last activity.
    let now = try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-11-10T21:30:00.000Z")

    @Test("Decodes a real Paseo record, fractional-second dates included")
    func decodes() throws {
        let r = try record(paseoJSON())
        #expect(r.lastStatus == "idle")
        #expect(r.providerSessionID == "f509068b")
        #expect(r.lastActivityAt != nil)
        #expect(r.archivedAt == nil)
    }

    @Test("Paseo states map onto Cracked's agent states")
    func mapping() throws {
        func status(_ s: String, _ attention: String? = nil) throws -> AgentSession.Status? {
            PaseoAgents.session(from: try record(paseoJSON(status: s, attention: attention)), serverID: "srv_X", now: now)?.status
        }
        #expect(try status("running") == .working)
        #expect(try status("initializing") == .working)
        #expect(try status("running", "permission") == .needsInput)
        #expect(try status("idle", "finished") == .done)
        #expect(try status("idle", "error") == .error)
        #expect(try status("error") == .error)
        #expect(try status("idle") == .ready, "Recently used idle agents are listed")
        #expect(try status("closed") == nil)
        #expect(try status("closed", "finished") == nil)
    }

    @Test("Archived agents and long-idle agents are hidden; unseen ones are kept")
    func filtering() throws {
        #expect(PaseoAgents.session(from: try record(paseoJSON(status: "running", archived: true)), serverID: nil, now: now) == nil)
        let later = now.addingTimeInterval(PaseoAgents.idleWindow + 60)
        #expect(PaseoAgents.session(from: try record(paseoJSON()), serverID: nil, now: later) == nil)
        #expect(PaseoAgents.session(from: try record(paseoJSON(attention: "finished")), serverID: nil, now: later)?.status == .done,
                "A finished agent you haven't looked at stays however old it is")
    }

    @Test("A Paseo session carries its title, provider, message and a deep link")
    func sessionFields() throws {
        let session = try #require(PaseoAgents.session(
            from: try record(paseoJSON(status: "error", lastError: "Rate limited")), serverID: "srv_KFWc", now: now))
        #expect(session.source == .paseo)
        #expect(session.sessionID == "paseo-c7ff450f-2db1-4815-a7c5-8fd201f936d5")
        #expect(session.projectName == "clearing")
        #expect(session.title == "Take a look at the handoff spec")
        #expect(session.agentName == "Claude")
        #expect(session.message == "Rate limited")
        #expect(session.isWaiting)
        #expect(session.paseoURL?.absoluteString == "paseo://h/srv_KFWc/agent/c7ff450f-2db1-4815-a7c5-8fd201f936d5")

        let permission = try #require(PaseoAgents.session(
            from: try record(paseoJSON(status: "running", attention: "permission")), serverID: nil, now: now))
        #expect(permission.message == "Waiting for permission")
        #expect(permission.paseoURL == nil, "No deep link without a server ID")
        #expect(permission.updatedAt > permission.startedAt)
    }

    @Test("A Claude Code session Paseo is running is listed once, as the Paseo agent")
    func dedupe() throws {
        let hookOnly = AgentSession(sessionID: "standalone", cwd: "/a", status: .working, message: nil,
                                    startedAt: now, updatedAt: now)
        let hookDuplicate = AgentSession(sessionID: "f509068b", cwd: "/Users/me/Developer/clearing", status: .done,
                                         message: nil, startedAt: now, updatedAt: now)
        let paseo = try #require(PaseoAgents.session(from: try record(paseoJSON(status: "running")), serverID: nil, now: now))
        let merged = AgentFeed.merge(hookSessions: [hookOnly, hookDuplicate], paseoSessions: [paseo],
                                     paseoProviderSessionIDs: ["f509068b"])
        #expect(Set(merged.map(\.sessionID)) == ["standalone", paseo.sessionID])
    }

    @Test("Hook session files written before Paseo support still decode")
    func backwardCompatible() throws {
        let old = #"{"cwd":"/x","sessionID":"s1","startedAt":"2026-11-10T21:00:00Z","status":"done","updatedAt":"2026-11-10T21:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AgentSession.self, from: Data(old.utf8))
        #expect(session.source == .claudeCode)
        #expect(session.paseoURL == nil)
    }

    @Test("The reader picks up new and changed files, and forgets deleted ones")
    func reader() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("paseo-test-\(UUID().uuidString)")
        let project = home.appendingPathComponent("agents/Users-me-Developer-clearing")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "srv_TEST\n".write(to: home.appendingPathComponent("server-id"), atomically: true, encoding: .utf8)

        let reader = PaseoAgentReader(home: home)
        #expect(reader.records().isEmpty)

        let file = project.appendingPathComponent("a1.json")
        try paseoJSON(id: "a1", status: "running").write(to: file)
        var (sessions, ids) = reader.sessions(now: now)
        #expect(sessions.map(\.status) == [.working])
        #expect(sessions.first?.paseoServerID == "srv_TEST")
        #expect(ids == ["f509068b"])

        try paseoJSON(id: "a1", status: "idle", attention: "finished").write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        (sessions, _) = reader.sessions(now: now)
        #expect(sessions.map(\.status) == [.done])

        try FileManager.default.removeItem(at: file)
        #expect(reader.records().isEmpty)
    }

    @Test("Tracked apps count Paseo's agents separately from Claude Code sessions in terminals")
    func trackedApps() {
        func proc(_ pid: Int32, _ ppid: Int32, _ name: String) -> ProcessSnapshot {
            ProcessSnapshot(id: pid, pid: pid, ppid: ppid, uid: 501, name: name, cpuPercent: 0, memoryMB: 100, uptimeSeconds: 60)
        }
        let processes = [
            proc(10, 1, "/Applications/Paseo.app/Contents/MacOS/Paseo"),
            proc(11, 10, "Paseo Supervisor"),
            proc(12, 11, "Paseo Daemon"),
            proc(20, 12, "/Users/me/.local/bin/claude"),
            proc(21, 12, "/Users/me/.local/bin/claude"),
            proc(22, 12, "/opt/homebrew/bin/opencode"),
            proc(23, 12, "<defunct>"),
            proc(24, 12, "/bin/zsh"),
            proc(30, 5, "claude"),
        ]
        let tracked = Dictionary(uniqueKeysWithValues: MenuBarViewModel.computeTrackedApps(from: processes).map { ($0.name, $0) })
        #expect(tracked["Paseo"]?.count == 3)
        #expect(tracked["Paseo"]?.label == "agents")
        #expect(tracked["Claude Code"]?.count == 1, "Paseo's claude processes aren't terminal sessions")
    }

    @Test("PASEO_HOME overrides ~/.paseo")
    func home() {
        #expect(PaseoAgents.home(environment: ["PASEO_HOME": "/tmp/p"]).path == "/tmp/p")
        #expect(PaseoAgents.home(environment: [:]).lastPathComponent == ".paseo")
    }
}
