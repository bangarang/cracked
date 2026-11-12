import Foundation
import Testing
@testable import Cracked

@Suite("Terminal agents")
struct TerminalAgentsTests {
    let now = Date(timeIntervalSince1970: 1_794_350_000)
    var started: Date { now.addingTimeInterval(-4 * 86400) }

    func process(_ kind: AgentProcess.Kind = .claude, pid: Int32 = 19654, tty: String? = "/dev/ttys001") -> AgentProcess {
        AgentProcess(pid: pid, kind: kind, cwd: "/Users/me/Developer", tty: tty, startedAt: started,
                     terminalPID: 93437, terminalBundlePath: "/Applications/Ghostty.app")
    }

    func claude(status: String, waitingFor: String? = nil, changedAgo: TimeInterval = 60,
                kind: String = "interactive", name: String = "developer-15", nameSource: String = "derived") -> ClaudeSessionFile {
        let json: [String: Any?] = [
            "pid": 19654, "sessionId": "a902efde", "cwd": "/Users/me/Developer", "kind": kind,
            "name": name, "nameSource": nameSource, "status": status, "waitingFor": waitingFor,
            "startedAt": started.timeIntervalSince1970 * 1000,
            "statusUpdatedAt": (now.timeIntervalSince1970 - changedAgo) * 1000,
            "messagingSocketPath": "/tmp/cc-socks/19654.sock", "version": "2.1.318",
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
        return try! JSONDecoder().decode(ClaudeSessionFile.self, from: data)
    }

    @Test("Claude Code's own session status maps onto Cracked's states")
    func claudeStatus() throws {
        func status(_ file: ClaudeSessionFile) -> AgentSession.Status? {
            TerminalAgents.session(for: process(), claude: file, now: now)?.status
        }
        #expect(status(claude(status: "busy")) == .working)
        #expect(status(claude(status: "waiting", waitingFor: "permission")) == .needsInput)
        #expect(status(claude(status: "idle")) == .done, "Just finished a turn: your move")
        #expect(status(claude(status: "idle", changedAgo: TerminalAgents.recentlyFinishedWindow + 60)) == .ready,
                "Idle for a long time is just idle")
        #expect(status(claude(status: "idle", changedAgo: now.timeIntervalSince(started))) == .ready,
                "Opened and never used isn't done")
        #expect(status(claude(status: "busy", kind: "bg")) == nil, "Background jobs aren't terminal sessions")
    }

    @Test("A terminal session carries its session ID, tty, host app and message")
    func fields() throws {
        let session = try #require(TerminalAgents.session(
            for: process(), claude: claude(status: "waiting", waitingFor: "permission"), now: now))
        #expect(session.source == .terminal)
        #expect(session.sessionID == "a902efde")
        #expect(session.tty == "/dev/ttys001")
        #expect(session.terminalName == "Ghostty")
        #expect(session.projectName == "Developer")
        #expect(session.message == "Waiting for permission")
        #expect(session.title == nil, "Derived names like developer-15 aren't titles")
        #expect(session.paseoURL == nil)

        let named = try #require(TerminalAgents.session(
            for: process(), claude: claude(status: "busy", name: "Fix the login bug", nameSource: "user"), now: now))
        #expect(named.title == "Fix the login bug")
    }

    @Test("An OpenCode process alone has no state; OpenCodeAgents adds it from the database")
    func opencode() throws {
        let session = try #require(TerminalAgents.session(for: process(.opencode, pid: 14453), claude: nil, now: now))
        #expect(session.status == .running)
        #expect(session.sessionID == "opencode-14453")
        #expect(session.agentName == "OpenCode")
        #expect(!session.isWaiting)
    }

    @Test("Claude without a session file is listed only if it's in a terminal")
    func noSessionFile() {
        #expect(TerminalAgents.session(for: process(), claude: nil, now: now)?.status == .running)
        #expect(TerminalAgents.session(for: process(tty: nil), claude: nil, now: now) == nil)
    }

    @Test("Recognises Claude Code and OpenCode by name or path, including versioned Claude binaries")
    func recognises() {
        #expect(TerminalAgents.kind(name: "claude", path: nil) == .claude)
        #expect(TerminalAgents.kind(name: "2.1.322", path: "/Users/me/.local/share/claude/versions/2.1.322") == .claude)
        #expect(TerminalAgents.kind(name: "opencode", path: "/opt/homebrew/bin/opencode") == .opencode)
        #expect(TerminalAgents.kind(name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude") == nil)
        #expect(TerminalAgents.kind(name: "zsh", path: "/bin/zsh") == nil)
    }

    @Test("A terminal session also reported by hooks is listed once, keeping the hook's message")
    func mergeWithHooks() throws {
        var terminal = try #require(TerminalAgents.session(
            for: process(), claude: claude(status: "waiting", waitingFor: "permission"), now: now))
        terminal.claudePID = 19654
        let hook = AgentSession(sessionID: "a902efde", cwd: "/Users/me/Developer", status: .needsInput,
                                message: "Claude needs your permission to use Bash", startedAt: started, updatedAt: now,
                                claudePID: 19654)
        let other = AgentSession(sessionID: "other", cwd: "/x", status: .working, message: nil,
                                 startedAt: started, updatedAt: now)
        let merged = AgentFeed.merge(hookSessions: [hook, other], paseoSessions: [], paseoProviderSessionIDs: [],
                                     terminalSessions: [terminal, terminal])
        #expect(merged.map(\.sessionID).sorted() == ["a902efde", "other"], "Listed once, duplicates dropped")
        let combined = try #require(merged.first { $0.sessionID == "a902efde" })
        #expect(combined.source == .terminal)
        #expect(combined.message == "Claude needs your permission to use Bash")
    }

    @Test("Focus scripts target the tab by tty, and only for terminals that support it")
    func focusScripts() {
        let ghostty = AgentNavigator.focusScript(bundleID: "com.mitchellh.ghostty", tty: "/dev/ttys003")
        #expect(ghostty?.contains(#"first terminal whose tty is "/dev/ttys003""#) == true)
        #expect(AgentNavigator.focusScript(bundleID: "com.googlecode.iterm2", tty: "/dev/ttys003")?.contains("select s") == true)
        #expect(AgentNavigator.focusScript(bundleID: "com.apple.Terminal", tty: "/dev/ttys003") != nil)
        #expect(AgentNavigator.focusScript(bundleID: "dev.warp.Warp-Stable", tty: "/dev/ttys003") == nil)
        let injected = AgentNavigator.focusScript(bundleID: "com.mitchellh.ghostty", tty: #"x" & do shell script "y"#)
        #expect(injected?.contains(#"do shell script "y""#) == false, "Quotes can't break out of the string")
    }

    @Test("Reads the latest ai-title from a transcript, ignoring a partial first line")
    func titles() throws {
        #expect(ClaudeTitles.projectFolderName(cwd: "/Users/me/.paseo/my_app") == "-Users-me--paseo-my-app")
        let jsonl = """
            itle","aiTitle":"cut off mid-line"}
            {"type":"ai-title","aiTitle":"Old title","sessionId":"s"}
            {"type":"user","message":{"content":"mentions \\"ai-title\\" in text"}}
            {"type":"ai-title","aiTitle":"Ollama qwen performance limits","sessionId":"s"}
            {"type":"assistant","message":{}}
            """
        #expect(ClaudeTitles.latestTitle(inJSONL: Data(jsonl.utf8)) == "Ollama qwen performance limits")
        #expect(ClaudeTitles.latestTitle(inJSONL: Data(#"{"type":"user"}"#.utf8)) == nil)

        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("claude-projects-\(UUID().uuidString)")
        let folder = projects.appendingPathComponent("-Users-me-Developer")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projects) }
        try Data(jsonl.utf8).write(to: folder.appendingPathComponent("abc.jsonl"))
        #expect(ClaudeTitles.title(sessionID: "abc", cwd: "/Users/me/Developer", projects: projects)
                == "Ollama qwen performance limits")
        #expect(ClaudeTitles.title(sessionID: "missing", cwd: "/Users/me/Developer", projects: projects) == nil)
    }

    @Test("The live scan finds real processes without crashing")
    func liveScan() {
        // Smoke test: results depend on the machine, but every entry must be well-formed.
        for session in TerminalAgents.scan(now: Date()) {
            #expect(session.source == .terminal)
            #expect(session.claudePID != nil)
        }
    }
}
