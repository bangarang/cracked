import AppKit

/// A minimal Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
/// Run with `Cracked mcp`; register with `claude mcp add cracked -- <path>/Cracked mcp`.
final class MCPServer {
    /// Everything the tools touch, injectable for tests.
    struct Environment {
        var report: () -> SystemReport
        var records: () -> [[String: Any]]
        var restart: (_ pid: Int32, _ bundlePath: String) -> Bool
        var snooze: (_ bundlePath: String, _ until: Date) -> Void
        var runningApps: () -> [(name: String, bundlePath: String)]
        var now: () -> Date = { Date() }
    }

    static let latestProtocolVersion = "2025-06-18"
    static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]

    let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    // MARK: - Transport

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = handle(line: line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    /// Handles one JSON-RPC message; returns the response line, or nil for notifications.
    func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(),
                           "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let response = handle(message: message) else { return nil }
        return encode(response)
    }

    func handle(message: [String: Any]) -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        // Notifications (no id) never get a response.
        guard let id = message["id"] else { return nil }

        func result(_ value: [String: Any]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "result": value]
        }
        func error(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? Self.latestProtocolVersion
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.latestProtocolVersion
            return result([
                "protocolVersion": version,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "cracked", "title": "Cracked",
                               "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
                "instructions": """
                    Cracked monitors this Mac: system load, CPU hogs, bloated long-running apps \
                    ("worth a restart"), tracked app counts (browser tabs, Claude Code sessions) and \
                    the state of every coding agent on the machine (Claude Code sessions and Paseo agents). Check system_status before \
                    starting heavy work like large builds or test suites.
                    """,
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return result(callTool(name, arguments: arguments))
        default:
            return error(-32601, "Method not found: \(method)")
        }
    }

    // MARK: - Tools

    nonisolated(unsafe) static let tools: [[String: Any]] = [
        tool("system_status",
             "Live snapshot of this Mac: pressure level (CPU, load and macOS memory pressure), load average, RAM, models loaded in Ollama with their memory, CPU hogs, apps worth restarting, tracked app counts and every coding agent (Claude Code sessions and Paseo agents).",
             readOnly: true),
        tool("list_agent_sessions",
             "Every coding agent on this Mac, from the Paseo app (source paseo), Claude Code / OpenCode running in terminals (source terminal) and Claude Code hooks (source claudeCode), with its project, title, provider, status (ready, working, needsInput, done, error, running), pending message and hosting terminal.",
             readOnly: true),
        tool("get_records",
             "All-time records Cracked has logged: peak CPU, most processes, and personal bests for browser tabs, windows and Claude Code sessions.",
             readOnly: true),
        tool("restart_app",
             "Gracefully quit and relaunch an app. Only apps currently listed under worth_a_restart in system_status can be restarted.",
             properties: ["app": ["type": "string", "description": "App name, e.g. \"Comet\""]],
             required: ["app"], readOnly: false, destructive: true),
        tool("snooze_app",
             "Stop suggesting a restart for a running app, for a number of days or forever.",
             properties: [
                "app": ["type": "string", "description": "App name, e.g. \"Slack\""],
                "days": ["type": "integer", "description": "Days to snooze (default 7)", "minimum": 1],
                "forever": ["type": "boolean", "description": "Never suggest this app again"],
             ],
             required: ["app"], readOnly: false, destructive: false),
    ]

    private static func tool(_ name: String, _ description: String,
                             properties: [String: Any] = [:], required: [String] = [],
                             readOnly: Bool, destructive: Bool = false) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return [
            "name": name,
            "description": description,
            "inputSchema": schema,
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive,
                            "idempotentHint": readOnly, "openWorldHint": false],
        ]
    }

    func callTool(_ name: String, arguments: [String: Any]) -> [String: Any] {
        switch name {
        case "system_status":
            let report = environment.report()
            return text(report.summary + "\n\n" + report.json)
        case "list_agent_sessions":
            let report = environment.report()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            let json = (try? encoder.encode(report.agents)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return text(report.agents.isEmpty ? "No Claude Code sessions or Paseo agents are reporting to Cracked." : json)
        case "get_records":
            let records = environment.records()
            return text(records.isEmpty ? "No records yet." : encode(records))
        case "restart_app":
            guard let app = arguments["app"] as? String else { return failure("Missing 'app'.") }
            let candidates = environment.report().worthARestart
            guard let candidate = candidates.first(where: { $0.name.caseInsensitiveCompare(app) == .orderedSame }) else {
                let names = candidates.map(\.name).joined(separator: ", ")
                let hint = names.isEmpty ? "Nothing is worth restarting right now." : "Candidates: \(names)."
                return failure("\(app) isn't on the Worth a Restart list, so Cracked won't restart it. \(hint)")
            }
            let ok = environment.restart(candidate.pid, candidate.bundlePath)
            return ok
                ? text("Restarted \(candidate.name), which was using \(candidate.memory) after \(candidate.uptime).")
                : failure("Couldn't relaunch \(candidate.name).")
        case "snooze_app":
            guard let app = arguments["app"] as? String else { return failure("Missing 'app'.") }
            let match = environment.runningApps().first { $0.name.caseInsensitiveCompare(app) == .orderedSame }
            guard let bundlePath = match?.bundlePath else { return failure("\(app) isn't running.") }
            let forever = arguments["forever"] as? Bool ?? false
            let days = arguments["days"] as? Int ?? 7
            let until = forever ? Date.distantFuture : environment.now().addingTimeInterval(Double(max(days, 1)) * 86400)
            environment.snooze(bundlePath, until)
            return text(forever ? "Cracked will never suggest restarting \(match!.name)."
                                : "Snoozed \(match!.name) for \(max(days, 1)) day\(days == 1 ? "" : "s").")
        default:
            return failure("Unknown tool: \(name)")
        }
    }

    private func text(_ string: String) -> [String: Any] {
        ["content": [["type": "text", "text": string]], "isError": false]
    }

    private func failure(_ string: String) -> [String: Any] {
        ["content": [["type": "text", "text": string]], "isError": true]
    }

    private func encode(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

extension MCPServer.Environment {
    /// The real environment: live readings, the records database, real app actions.
    static var live: MCPServer.Environment {
        MCPServer.Environment(
            report: { SystemReport.current() },
            records: {
                guard let db = try? DatabaseManager() else { return [] }
                var rows: [[String: Any]] = []
                for record in (try? db.allRecords()) ?? [] {
                    var row: [String: Any] = ["type": record.recordType, "value": record.value,
                                              "achieved_at": ISO8601DateFormatter().string(
                                                from: Date(timeIntervalSince1970: record.achievedAt))]
                    if let app = record.appName { row["app"] = app }
                    if let details = record.details { row["details"] = details }
                    rows.append(row)
                }
                return rows
            },
            restart: { pid, bundlePath in AppActions.restart(pid: pid, bundlePath: bundlePath) },
            snooze: { bundlePath, until in
                var ignored = IgnoredApps.load()
                ignored.prune()
                ignored.until[bundlePath] = until
                ignored.save()
                UserDefaults.standard.synchronize()
            },
            runningApps: {
                NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular }
                    .compactMap { app in
                        guard let path = app.bundleURL?.path else { return nil }
                        let name = app.localizedName ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                        return (name, path)
                    }
            }
        )
    }
}
