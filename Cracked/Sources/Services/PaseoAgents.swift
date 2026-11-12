import Foundation

/// The parts of a Paseo agent record (`~/.paseo/agents/<project>/<agent-id>.json`) Cracked uses.
/// The Paseo daemon rewrites this file whenever the agent's state changes.
struct PaseoAgentRecord: Decodable, Sendable, Equatable {
    struct Session: Decodable, Sendable, Equatable {
        let sessionId: String?
    }

    let id: String
    let provider: String?
    let cwd: String?
    let title: String?
    /// "initializing", "idle", "running", "error" or "closed".
    let lastStatus: String?
    let lastError: String?
    let requiresAttention: Bool?
    /// "finished", "error" or "permission". Paseo clears it once the agent is viewed.
    let attentionReason: String?
    let attentionTimestamp: Date?
    let archivedAt: Date?
    let createdAt: Date?
    let updatedAt: Date?
    let lastActivityAt: Date?
    let `internal`: Bool?
    let runtimeInfo: Session?
    let persistence: Session?

    /// The provider's own session ID. For Claude agents this is the Claude Code
    /// session ID that hooks report, so the same agent isn't listed twice.
    var providerSessionID: String? { persistence?.sessionId ?? runtimeInfo?.sessionId }
}

enum PaseoAgents {
    /// Idle agents nobody has to look at are only listed this long after their last activity.
    static let idleWindow: TimeInterval = 3 * 3600

    /// Paseo's home directory: `$PASEO_HOME`, or `~/.paseo`.
    static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["PASEO_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".paseo", isDirectory: true)
    }

    static func serverID(home: URL) -> String? {
        guard let raw = try? String(contentsOf: home.appendingPathComponent("server-id"), encoding: .utf8) else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// `paseo://h/<server>/agent/<agent>` opens the agent in the Paseo app.
    static func deepLink(serverID: String, agentID: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let server = serverID.addingPercentEncoding(withAllowedCharacters: allowed),
              let agent = agentID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "paseo://h/\(server)/agent/\(agent)")
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
        }
        return decoder
    }()

    // MARK: - Mapping

    /// Maps a Paseo record onto Cracked's agent model. Returns nil for agents that
    /// shouldn't be listed: archived, internal, closed, or idle and long untouched.
    static func session(from record: PaseoAgentRecord, serverID: String?, now: Date) -> AgentSession? {
        if record.archivedAt != nil || record.internal == true { return nil }

        let attention = record.requiresAttention == true ? record.attentionReason : nil
        let lastActivity = record.lastActivityAt ?? record.updatedAt ?? record.createdAt ?? now
        let status: AgentSession.Status
        var message: String?

        switch (record.lastStatus, attention) {
        case ("closed", _), (nil, _):
            return nil
        case (_, "permission"):
            status = .needsInput
            message = "Waiting for permission"
        case ("error", _), (_, "error"):
            status = .error
            message = record.lastError
        case ("running", _), ("initializing", _):
            status = .working
        case (_, "finished"):
            status = .done
        default:
            // Idle and already seen in Paseo: only worth listing if it was used recently.
            guard now.timeIntervalSince(lastActivity) < idleWindow else { return nil }
            status = .ready
        }

        // When it started needing you, so "finished since you last opened the menu" works.
        let changedAt = attention != nil ? (record.attentionTimestamp ?? lastActivity) : lastActivity
        return AgentSession(
            sessionID: "paseo-\(record.id)",
            cwd: record.cwd ?? "",
            status: status,
            message: message,
            startedAt: record.createdAt ?? lastActivity,
            updatedAt: changedAt,
            paseoAgentID: record.id,
            paseoServerID: serverID,
            title: record.title,
            provider: record.provider
        )
    }
}

/// Reads Paseo's agent records, re-decoding only files that changed since the last read.
/// The menu bar refreshes agents every second, so this keeps that cheap.
final class PaseoAgentReader {
    let home: URL
    private var cache: [String: (modified: Date, record: PaseoAgentRecord?)] = [:]

    init(home: URL = PaseoAgents.home()) {
        self.home = home
    }

    func records() -> [PaseoAgentRecord] {
        let agentsDir = home.appendingPathComponent("agents", isDirectory: true)
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil) else {
            cache.removeAll()
            return []
        }
        var seen = Set<String>()
        var records: [PaseoAgentRecord] = []
        for project in projects {
            guard let files = try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "json" {
                let path = file.path
                seen.insert(path)
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let record: PaseoAgentRecord?
                if let cached = cache[path], cached.modified == modified {
                    record = cached.record
                } else {
                    record = (try? Data(contentsOf: file)).flatMap { try? PaseoAgents.decoder.decode(PaseoAgentRecord.self, from: $0) }
                    cache[path] = (modified, record)
                }
                if let record { records.append(record) }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return records
    }

    func sessions(now: Date = Date()) -> (sessions: [AgentSession], providerSessionIDs: Set<String>) {
        let records = records()
        let serverID = PaseoAgents.serverID(home: home)
        let ids = Set(records.compactMap(\.providerSessionID))
        return (records.compactMap { PaseoAgents.session(from: $0, serverID: serverID, now: now) }, ids)
    }
}

/// Every agent Cracked knows about: Paseo agents, Claude Code sessions running in
/// terminals, OpenCode sessions (from its database), and sessions reporting through
/// Cracked's Claude Code hooks. Each agent
/// is listed once: a session Paseo runs as the Paseo agent (that's where you answer
/// it), and a terminal session with Claude Code's own live status, keeping the
/// hook's more specific "needs input" message when there is one.
enum AgentFeed {
    static func merge(hookSessions: [AgentSession], paseoSessions: [AgentSession],
                      paseoProviderSessionIDs: Set<String>,
                      terminalSessions: [AgentSession] = []) -> [AgentSession] {
        let hooks = hookSessions.filter { !paseoProviderSessionIDs.contains($0.sessionID) }
        let terminals = terminalSessions
            .filter { !paseoProviderSessionIDs.contains($0.sessionID) }
            .map { terminal -> AgentSession in
                var terminal = terminal
                if terminal.status == .needsInput,
                   let hook = hooks.first(where: { matches($0, terminal) }), hook.status == .needsInput,
                   let message = hook.message {
                    terminal.message = message
                }
                return terminal
            }
        let unmatchedHooks = hooks.filter { hook in !terminals.contains { matches(hook, $0) } }
        // The same session can be open twice (e.g. resumed in a second terminal); list it once.
        var seen = Set<String>()
        return (paseoSessions + terminals + unmatchedHooks)
            .filter { seen.insert($0.sessionID).inserted }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func matches(_ hook: AgentSession, _ terminal: AgentSession) -> Bool {
        hook.sessionID == terminal.sessionID || (hook.claudePID != nil && hook.claudePID == terminal.claudePID)
    }

    /// Loads every agent, with the transcript heuristic applied to hook sessions.
    static func load(paseo: PaseoAgentReader, openCode: OpenCodeAgentReader, now: Date = Date()) -> [AgentSession] {
        let hooks = AgentInbox.loadAll(now: now).map { session -> AgentSession in
            var session = session
            session.status = session.effectiveStatus(transcriptModifiedAt: AgentInbox.transcriptModifiedAt(session))
            return session
        }
        let (paseoSessions, ids) = paseo.sessions(now: now)
        let processes = TerminalAgents.processes()
        let terminals = TerminalAgents.scan(processes: processes, now: now)
            + openCode.sessions(processes: processes.filter { $0.kind == .opencode }, now: now)
        return merge(hookSessions: hooks, paseoSessions: paseoSessions, paseoProviderSessionIDs: ids,
                     terminalSessions: terminals)
    }
}
