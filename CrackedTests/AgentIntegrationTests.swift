import Foundation
import Testing
@testable import Cracked

private func hook(_ event: String, message: String? = nil, session: String = "abc-123",
                  cwd: String = "/Users/me/Developer/cracked") -> HookInput {
    var json: [String: Any] = ["session_id": session, "hook_event_name": event, "cwd": cwd,
                               "transcript_path": "/tmp/\(session).jsonl"]
    if let message { json["message"] = message }
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder().decode(HookInput.self, from: data)
}

@Suite("AgentInbox")
struct AgentInboxTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let context = ProcessContext(claudePID: 42, terminalPID: 7, terminalBundlePath: "/Applications/Ghostty.app")

    @Test("A session moves through ready → working → needs input → working → done")
    func lifecycle() throws {
        var session = try #require(AgentInbox.apply(hook("SessionStart"), to: nil, context: context, now: t0))
        #expect(session.status == .ready)
        #expect(session.projectName == "cracked")
        #expect(session.terminalName == "Ghostty")
        #expect(session.claudePID == 42)

        session = try #require(AgentInbox.apply(hook("UserPromptSubmit"), to: session, context: .init(), now: t0 + 10))
        #expect(session.status == .working)
        #expect(session.terminalPID == 7, "Process context is kept when later hooks skip the lookup")

        session = try #require(AgentInbox.apply(hook("Notification", message: "Claude needs your permission to use Bash"),
                                                to: session, context: .init(), now: t0 + 20))
        #expect(session.status == .needsInput)
        #expect(session.message == "Claude needs your permission to use Bash")
        #expect(session.isWaiting)

        session = try #require(AgentInbox.apply(hook("UserPromptSubmit"), to: session, context: .init(), now: t0 + 30))
        #expect(session.status == .working)
        #expect(session.message == nil)

        session = try #require(AgentInbox.apply(hook("Stop"), to: session, context: .init(), now: t0 + 40))
        #expect(session.status == .done)
        #expect(session.updatedAt == t0 + 40)
    }

    @Test("Idle reminders after a finished turn don't change anything")
    func idleReminderIgnored() throws {
        let done = try #require(AgentInbox.apply(hook("Stop"), to: nil, context: context, now: t0))
        let after = try #require(AgentInbox.apply(hook("Notification", message: "Claude is waiting for your input"),
                                                  to: done, context: .init(), now: t0 + 60))
        #expect(after.status == .done)
        #expect(after.updatedAt == t0, "No new timestamp, so no repeat notification")
    }

    @Test("Resume or compaction doesn't reset a working session; SessionEnd removes it")
    func sessionStartAndEnd() throws {
        let working = try #require(AgentInbox.apply(hook("UserPromptSubmit"), to: nil, context: context, now: t0))
        let resumed = try #require(AgentInbox.apply(hook("SessionStart"), to: working, context: .init(), now: t0 + 5))
        #expect(resumed.status == .working)
        #expect(AgentInbox.apply(hook("SessionEnd"), to: resumed, context: .init(), now: t0 + 9) == nil)
    }

    @Test("An answered permission prompt counts as working once the transcript moves on")
    func transcriptHeuristic() throws {
        let blocked = try #require(AgentInbox.apply(hook("UserPromptSubmit"), to: nil, context: context, now: t0)
            .flatMap { AgentInbox.apply(hook("Notification", message: "Permission"), to: $0, context: .init(), now: t0 + 10) })
        #expect(blocked.effectiveStatus(transcriptModifiedAt: t0 + 11) == .needsInput)
        #expect(blocked.effectiveStatus(transcriptModifiedAt: t0 + 30) == .working)
        #expect(blocked.effectiveStatus(transcriptModifiedAt: nil) == .needsInput)
    }

    @Test("Session files use a sanitised name")
    func sanitisedFileName() {
        #expect(AgentInbox.fileURL(for: "../../etc/passwd").lastPathComponent == "etcpasswd.json")
    }

    @Test("Menu ages are compact")
    func ages() {
        #expect(AgentRowView.age(of: t0, now: t0 + 30) == "now")
        #expect(AgentRowView.age(of: t0, now: t0 + 300) == "5m")
        #expect(AgentRowView.age(of: t0, now: t0 + 7200) == "2h")
        #expect(AgentRowView.age(of: t0, now: t0 + 200_000) == "2d")
    }
}

@Suite("ClaudeCodeSetup")
struct ClaudeCodeSetupTests {
    let exe = "/Applications/Cracked.app/Contents/MacOS/Cracked"

    @Test("Installs a hook for every event and is idempotent")
    func install() {
        let once = ClaudeCodeSetup.installingHooks(into: [:], executable: exe)
        #expect(ClaudeCodeSetup.hooksInstalled(in: once, executable: exe))
        let twice = ClaudeCodeSetup.installingHooks(into: once, executable: exe)
        let hooks = twice["hooks"] as! [String: Any]
        for event in ClaudeCodeSetup.hookEvents {
            #expect((hooks[event] as! [[String: Any]]).count == 1, "\(event) has exactly one Cracked hook")
        }
    }

    @Test("Keeps the user's own hooks and settings, and removes only Cracked's")
    func preservesOtherHooks() {
        let userHook: [String: Any] = ["matcher": "", "hooks": [["type": "command", "command": "say done"]]]
        let settings: [String: Any] = ["model": "opus", "hooks": ["Stop": [userHook]]]

        let installed = ClaudeCodeSetup.installingHooks(into: settings, executable: exe)
        #expect(installed["model"] as? String == "opus")
        let stop = (installed["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        #expect(stop.count == 2)

        let removed = ClaudeCodeSetup.removingHooks(from: installed)
        let hooks = removed["hooks"] as! [String: Any]
        #expect(hooks.keys.sorted() == ["Stop"])
        let remaining = (hooks["Stop"] as! [[String: Any]]).first!["hooks"] as! [[String: Any]]
        #expect(remaining.first?["command"] as? String == "say done")
    }

    @Test("Reinstalling from a new location replaces the old hook")
    func movedApp() {
        let old = ClaudeCodeSetup.installingHooks(into: [:], executable: "/Users/me/Downloads/Cracked.app/Contents/MacOS/Cracked")
        let new = ClaudeCodeSetup.installingHooks(into: old, executable: exe)
        let stop = (new["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        #expect(stop.count == 1)
        #expect(ClaudeCodeSetup.hooksInstalled(in: new, executable: exe))
    }
}

@Suite("MCPServer")
struct MCPServerTests {
    final class Spy: @unchecked Sendable {
        var restarted: [(Int32, String)] = []
        var snoozed: [(String, Date)] = []
    }

    func makeServer(spy: Spy) -> MCPServer {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let comet = ProcessSnapshot(id: 10, pid: 10, ppid: 1, uid: 501, name: "/Applications/Comet.app/Contents/MacOS/Comet",
                                    cpuPercent: 1, memoryMB: 8 * 1024, uptimeSeconds: 10 * 86400)
        let snapshot = SystemSnapshot(timestamp: now, loadAverage: 2, totalProcesses: 1,
                                      memoryUsedMB: 64 * 1024, memoryTotalMB: 128 * 1024, processes: [comet])
        let report = SystemReport.build(snapshot: snapshot, settings: CrackedSettings(), launchedAppPIDs: [10],
                                        ignoredBundlePaths: [], agents: [], cpuCores: 16)
        return MCPServer(environment: .init(
            report: { report },
            records: { [["type": "peak_tabs", "value": 166]] },
            restart: { pid, path in spy.restarted.append((pid, path)); return true },
            snooze: { path, until in spy.snoozed.append((path, until)) },
            runningApps: { [("Slack", "/Applications/Slack.app"), ("Comet", "/Applications/Comet.app")] },
            now: { now }
        ))
    }

    func call(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:], id: Int = 1) -> [String: Any] {
        server.handle(message: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])!
    }

    func toolText(_ response: [String: Any]) -> (text: String, isError: Bool) {
        let result = response["result"] as! [String: Any]
        let content = (result["content"] as! [[String: Any]]).first!
        return (content["text"] as! String, result["isError"] as! Bool)
    }

    @Test("Initialize negotiates the protocol version and advertises tools")
    func initialize() {
        let server = makeServer(spy: Spy())
        let result = call(server, "initialize", ["protocolVersion": "2025-03-26"])["result"] as! [String: Any]
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)

        let unknown = call(server, "initialize", ["protocolVersion": "1999-01-01"])["result"] as! [String: Any]
        #expect(unknown["protocolVersion"] as? String == MCPServer.latestProtocolVersion)
    }

    @Test("Notifications get no response; unknown methods get an error; bad JSON is a parse error")
    func protocolEdges() {
        let server = makeServer(spy: Spy())
        #expect(server.handle(message: ["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let error = call(server, "resources/list")["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32601)
        #expect(server.handle(line: "{not json")?.contains("-32700") == true)
    }

    @Test("Lists five tools, with restart marked destructive")
    func toolsList() {
        let tools = (call(makeServer(spy: Spy()), "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]
        #expect(tools.map { $0["name"] as! String } == ["system_status", "list_agent_sessions", "get_records", "restart_app", "snooze_app"])
        let restart = tools.first { $0["name"] as? String == "restart_app" }!
        #expect((restart["annotations"] as! [String: Any])["destructiveHint"] as? Bool == true)
    }

    @Test("system_status reports the live picture")
    func systemStatus() {
        let (text, isError) = toolText(call(makeServer(spy: Spy()), "tools/call", ["name": "system_status"]))
        #expect(!isError)
        #expect(text.contains("Worth a restart: Comet (8.0 GB · 10d)"))
        #expect(text.contains("\"worth_a_restart\""))
    }

    @Test("restart_app only restarts apps on the Worth a Restart list")
    func restartGuard() {
        let spy = Spy()
        let server = makeServer(spy: spy)
        let refused = toolText(call(server, "tools/call", ["name": "restart_app", "arguments": ["app": "Slack"]]))
        #expect(refused.isError)
        #expect(spy.restarted.isEmpty)

        let ok = toolText(call(server, "tools/call", ["name": "restart_app", "arguments": ["app": "comet"]]))
        #expect(!ok.isError)
        #expect(spy.restarted.map(\.1) == ["/Applications/Comet.app"])
    }

    @Test("snooze_app snoozes for N days or forever")
    func snooze() {
        let spy = Spy()
        let server = makeServer(spy: spy)
        _ = call(server, "tools/call", ["name": "snooze_app", "arguments": ["app": "Slack", "days": 3]])
        _ = call(server, "tools/call", ["name": "snooze_app", "arguments": ["app": "Comet", "forever": true]])
        let missing = toolText(call(server, "tools/call", ["name": "snooze_app", "arguments": ["app": "Nope"]]))
        #expect(spy.snoozed.count == 2)
        #expect(spy.snoozed[0].1 == Date(timeIntervalSince1970: 2_000_000 + 3 * 86400))
        #expect(spy.snoozed[1].1 == .distantFuture)
        #expect(missing.isError)
    }
}

@Suite("SystemReport")
struct SystemReportTests {
    func report(load: Double, hogCPU: Double? = nil, memoryUsedGB: Int = 32,
                agents: [AgentSession] = []) -> SystemReport {
        var processes: [ProcessSnapshot] = []
        if let hogCPU {
            processes.append(ProcessSnapshot(id: 5, pid: 5, ppid: 1, uid: 501,
                                             name: "/Applications/Xcode.app/Contents/MacOS/Xcode",
                                             cpuPercent: hogCPU, memoryMB: 2048, uptimeSeconds: 600))
        }
        let snapshot = SystemSnapshot(timestamp: Date(), loadAverage: load, totalProcesses: 500,
                                      memoryUsedMB: memoryUsedGB * 1024, memoryTotalMB: 128 * 1024, processes: processes)
        return SystemReport.build(snapshot: snapshot, settings: CrackedSettings(), launchedAppPIDs: [],
                                  ignoredBundlePaths: [], agents: agents, cpuCores: 16)
    }

    @Test("Pressure follows CPU hogs and load")
    func pressure() {
        #expect(report(load: 2).pressure == .normal)
        #expect(report(load: 9).pressure == .warning)
        #expect(report(load: 2, hogCPU: 85).pressure == .warning)
        #expect(report(load: 2, hogCPU: 140).pressure == .critical)
        #expect(report(load: 25).pressure == .critical)
    }

    @Test("New sessions only get a brief when the Mac is struggling")
    func agentBrief() {
        #expect(report(load: 2).agentBrief == nil)
        let busy = report(load: 30, hogCPU: 140)
        let brief = try! #require(busy.agentBrief)
        #expect(brief.contains("load 30.0 on 16 cores"))
        #expect(brief.contains("Xcode 140%"))
        #expect(report(load: 2, memoryUsedGB: 120).agentBrief != nil, "Memory pressure alone also counts")
    }

    @Test("Settings default to the values shown in Settings")
    func settingsDefaults() {
        let defaults = UserDefaults(suiteName: "cracked-tests-\(UUID().uuidString)")!
        let settings = CrackedSettings.load(from: defaults)
        #expect(settings.cpuThreshold == 80)
        #expect(settings.stalenessDays == 7)
        #expect(settings.restartMemoryGB == 2)
        defaults.set(50.0, forKey: "cpuThreshold")
        #expect(CrackedSettings.load(from: defaults).cpuThreshold == 50)
    }
}
