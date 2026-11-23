import Foundation

/// `Cracked <command>`: the same binary as the menu bar app, used by
/// Claude Code hooks, the MCP server and humans in a terminal.
enum CrackedCLI {
    #if DEBUG
    static let commands: Set<String> = ["hook", "status", "mcp", "setup", "uninstall", "fleet", "help", "--help", "snapshot"]
    #else
    static let commands: Set<String> = ["hook", "status", "mcp", "setup", "uninstall", "fleet", "help", "--help"]
    #endif

    static func run(_ command: String, arguments: [String]) -> Int32 {
        switch command {
        case "hook":
            // Called by Claude Code for every session event. Must stay quiet and never fail:
            // on SessionStart, anything printed is added to the session's context.
            let input = AgentInbox.handleHook(stdin: FileHandle.standardInput.readDataToEndOfFile())
            if input?.hookEventName == "SessionStart" {
                let report = SystemReport.current()
                let hint = FleetRanking.idlePeerHint(FleetMember.current(thisMac: report))
                if let brief = report.agentBrief(idlePeerHint: hint) { print(brief) }
            }
            return 0

        case "status":
            let report = SystemReport.current()
            if arguments.contains("--fleet") {
                let members = FleetMember.current(thisMac: report)
                if arguments.contains("--json") {
                    let reports = members.map(\.report)
                    print(String(data: (try? JSONEncoder.fleet.encode(reports)) ?? Data(), encoding: .utf8) ?? "[]")
                } else {
                    print(FleetRanking.recommendation(members))
                }
                return 0
            }
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
        case "snapshot":
            return MainActor.assumeIsolated {
                DebugSnapshots.run(outputDirectory: arguments.first ?? FileManager.default.currentDirectoryPath)
            }
        #endif

        case "fleet":
            return fleet(arguments)

        case "uninstall":
            try? ClaudeCodeSetup.uninstallHooks()
            try? ClaudeCodeSetup.uninstallMCP()
            print("Removed Cracked's Claude Code hooks and MCP server.")
            return 0

        default:
            print("""
                Usage: Cracked [command]

                  (no command)      Run the menu bar app
                  status            Summary of this Mac right now (--json, --brief, --fleet)
                  setup             Connect Claude Code: install hooks and register the MCP server
                  uninstall         Disconnect Claude Code
                  fleet             Paired Macs (fleet on|off, fleet pair <address> <code>, fleet remove <name>)
                  mcp               Run the MCP server on stdio
                  hook              Handle a Claude Code hook event (reads JSON on stdin)
                """)
            return 0
        }
    }

    // MARK: - Fleet

    /// For Macs you can't click on (lid closed, icon hidden behind the notch).
    static func fleet(_ arguments: [String]) -> Int32 {
        let store = FleetStore.shared
        func fail(_ message: String) -> Int32 {
            FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
            return 1
        }
        switch arguments.first {
        case "on", "off":
            store.defaults.set(arguments.first == "on", forKey: FleetStore.enabledKey)
            store.defaults.synchronize()
            DistributedNotificationCenter.default().postNotificationName(fleetChangedNotification, object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
            print("Fleet \(arguments.first == "on" ? "on" : "off").")
            return 0
        case "pair":
            guard arguments.count == 3 else { return fail("Usage: Cracked fleet pair <address> <code>") }
            guard store.isEnabled else { return fail("Fleet is off. Run `Cracked fleet on` first.") }
            let client = FleetClient(store: store, me: .current(), timeout: 5)
            let result = blockingAwait(timeout: 15) {
                await Result(catching: { try await client.pair(address: arguments[1], port: FleetStore.defaultPort,
                                                               code: arguments[2], myPort: store.port) })
            }
            switch result {
            case .success(let peer)?:
                DistributedNotificationCenter.default().postNotificationName(fleetChangedNotification, object: nil,
                                                                             userInfo: nil, deliverImmediately: true)
                print("✓ Paired with \(peer.name) (\(peer.machine.hardwareSummary))")
                return 0
            case .failure(let error)?: return fail(error.localizedDescription)
            case nil: return fail("Timed out.")
            }
        case "remove":
            guard arguments.count >= 2 else { return fail("Usage: Cracked fleet remove <name>") }
            let name = arguments.dropFirst().joined(separator: " ")
            guard let peer = store.peers().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                return fail("No paired Mac called \(name).")
            }
            let client = FleetClient(store: store, me: .current())
            _ = blockingAwait(timeout: 5) { await client.unpair(peer) }
            store.remove(peer.id)
            print("Removed \(peer.name).")
            return 0
        default:
            let me = MachineIdentity.current()
            print("Fleet: \(store.isEnabled ? "on" : "off") · this Mac: \(me.name) (\(me.hardwareSummary)) · port \(store.port)")
            let peers = store.peers()
            if peers.isEmpty { print("No paired Macs.") }
            let cache = FleetCache.load()
            for peer in peers {
                let seen = cache?.entries.first { $0.peer.id == peer.id }?.lastSeen
                let status = seen.map { "seen \(AgentRowView.age(of: $0)) ago" } ?? "not seen yet"
                print("  • \(peer.name) (\(peer.machine.hardwareSummary)) at \(peer.address):\(peer.port), \(status)")
            }
            return 0
        }
    }

    /// Posted by `Cracked fleet on|off|pair` so the running app picks up the change.
    static let fleetChangedNotification = Notification.Name("com.bangarang.cracked.fleetChanged")
}
