import Foundation

/// `Cracked <command>`: the same binary as the menu bar app, used by
/// Claude Code hooks, the OpenCode plugin, the MCP server and humans in a terminal.
enum CrackedCLI {
    /// An agent `setup` and `uninstall` can connect Cracked to.
    enum Agent: String, CaseIterable {
        case claude, opencode

        var isInstalled: Bool {
            switch self {
            case .claude: FileManager.default.fileExists(atPath: ClaudeCodeSetup.settingsURL.deletingLastPathComponent().path)
            case .opencode: OpenCodeSetup.isDetected
            }
        }
    }

    /// The agents named in `arguments`, or `whenNoneNamed` when there are none. Nil when
    /// an argument isn't an agent, so a typo never acts on everything.
    static func agents(_ arguments: [String], whenNoneNamed: () -> [Agent]) -> [Agent]? {
        guard !arguments.isEmpty else { return whenNoneNamed() }
        let named = arguments.map { Agent(rawValue: $0.lowercased()) }
        return named.contains(nil) ? nil : named.compactMap { $0 }
    }

    private static func unknownAgent() -> Int32 {
        let names = Agent.allCases.map(\.rawValue).joined(separator: ", ")
        FileHandle.standardError.write(Data("✗ Unknown agent. Use one of: \(names)\n".utf8))
        return 1
    }

    #if DEBUG
    static let commands: Set<String> = ["hook", "status", "mcp", "setup", "uninstall", "help", "--help", "snapshot", "rex-focus"]
    #else
    static let commands: Set<String> = ["hook", "status", "mcp", "setup", "uninstall", "help", "--help"]
    #endif

    static func run(_ command: String, arguments: [String]) -> Int32 {
        switch command {
        case "hook":
            // Called by Claude Code for every session event. Must stay quiet and never fail:
            // on SessionStart, anything printed is added to the session's context.
            let input = AgentInbox.handleHook(stdin: FileHandle.standardInput.readDataToEndOfFile())
            if input?.hookEventName == "SessionStart", let brief = SystemReport.current().agentBrief {
                print(brief)
            }
            return 0

        case "status":
            let report = SystemReport.current()
            if arguments.contains("--json") {
                print(report.json)
            } else if arguments.contains("--brief") {
                if let brief = report.agentBrief { print(brief) }
            } else {
                print(report.summary)
            }
            return 0

        case "mcp":
            MCPServer(environment: .live).run()
            return 0

        case "setup":
            // `setup` connects every agent found on this Mac; `setup claude` / `setup opencode` just one.
            guard let targets = agents(arguments, whenNoneNamed: { Agent.allCases.filter(\.isInstalled) }) else {
                return unknownAgent()
            }
            guard !targets.isEmpty else {
                FileHandle.standardError.write(Data("✗ Found neither Claude Code nor OpenCode. Name one: setup claude | setup opencode\n".utf8))
                return 1
            }
            var failed = false
            var succeeded = false
            func step(_ done: String, _ action: () throws -> Void) {
                do {
                    try action()
                    print("✓ \(done)")
                    succeeded = true
                } catch {
                    failed = true
                    FileHandle.standardError.write(Data("✗ \(error.localizedDescription)\n".utf8))
                }
            }
            if targets.contains(.claude) {
                step("Claude Code hooks installed in \(ClaudeCodeSetup.settingsURL.path)") { try ClaudeCodeSetup.installHooks() }
                step("MCP server '\(ClaudeCodeSetup.mcpServerName)' registered with Claude Code") { try ClaudeCodeSetup.installMCP() }
            }
            if targets.contains(.opencode) {
                step("OpenCode plugin installed at \(OpenCodeSetup.pluginURL.path)") { try OpenCodeSetup.installPlugin() }
                step("MCP server '\(OpenCodeSetup.mcpServerName)' added to \(OpenCodeSetup.configURL.path)") { try OpenCodeSetup.installMCP() }
            }
            if succeeded {
                print("Start a new session to pick them up."
                      + (targets.contains(.opencode) ? " OpenCode loads plugins at startup: opencode service restart" : ""))
            }
            return failed ? 1 : 0

        #if DEBUG
        case "rex-focus":
            // Focuses the Rex block running a PID, as clicking its agent does.
            guard let pid = arguments.first.flatMap(Int32.init) else { return 1 }
            let found = Rex.focus(pid: pid)
            print(found ? "focused" : "block not found")
            Thread.sleep(forTimeInterval: 0.3)
            return found ? 0 : 1

        case "snapshot":
            return MainActor.assumeIsolated {
                DebugSnapshots.run(outputDirectory: arguments.first ?? FileManager.default.currentDirectoryPath)
            }
        #endif

        case "uninstall":
            guard let targets = agents(arguments, whenNoneNamed: { Agent.allCases }) else { return unknownAgent() }
            if targets.contains(.claude) {
                try? ClaudeCodeSetup.uninstallHooks()
                try? ClaudeCodeSetup.uninstallMCP()
                print("Removed Cracked's Claude Code hooks and MCP server.")
            }
            if targets.contains(.opencode) {
                try? OpenCodeSetup.uninstallPlugin()
                try? OpenCodeSetup.uninstallMCP()
                print("Removed Cracked's OpenCode plugin and MCP server.")
            }
            return 0

        default:
            print("""
                Usage: Cracked [command]

                  (no command)      Run the menu bar app
                  status            Summary of this Mac right now (--json, --brief)
                  setup [agent]     Connect Claude Code and/or OpenCode (claude, opencode; default:
                                    every one installed): agent inbox, load warnings, MCP server
                  uninstall [agent] Disconnect them
                  mcp               Run the MCP server on stdio
                  hook              Handle a Claude Code hook event (reads JSON on stdin)
                """)
            return 0
        }
    }
}
