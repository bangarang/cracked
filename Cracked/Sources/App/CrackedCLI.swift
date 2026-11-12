import Foundation

/// `Cracked <command>`: the same binary as the menu bar app, used by
/// Claude Code hooks, the MCP server and humans in a terminal.
enum CrackedCLI {
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
            do {
                try ClaudeCodeSetup.installHooks()
                print("✓ Claude Code hooks installed in \(ClaudeCodeSetup.settingsURL.path)")
                try ClaudeCodeSetup.installMCP()
                print("✓ MCP server '\(ClaudeCodeSetup.mcpServerName)' registered")
                print("Start a new Claude Code session to pick them up.")
                return 0
            } catch {
                FileHandle.standardError.write(Data("✗ \(error.localizedDescription)\n".utf8))
                return 1
            }

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
            try? ClaudeCodeSetup.uninstallHooks()
            try? ClaudeCodeSetup.uninstallMCP()
            print("Removed Cracked's Claude Code hooks and MCP server.")
            return 0

        default:
            print("""
                Usage: Cracked [command]

                  (no command)      Run the menu bar app
                  status            Summary of this Mac right now (--json, --brief)
                  setup             Connect Claude Code: install hooks and register the MCP server
                  uninstall         Disconnect Claude Code
                  mcp               Run the MCP server on stdio
                  hook              Handle a Claude Code hook event (reads JSON on stdin)
                """)
            return 0
        }
    }
}
