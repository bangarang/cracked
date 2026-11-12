import Foundation

/// `Cracked <command>`: the same binary as the menu bar app, used by
/// Claude Code hooks, the MCP server and humans in a terminal.
enum CrackedCLI {
    #if DEBUG
    static let commands: Set<String> = ["hook", "status", "mcp", "setup", "uninstall", "help", "--help", "snapshot", "dot-usb", "firmware-verify"]
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
        case "firmware-verify":
            // Checks for releases, then downloads and verifies each model's latest package. Writes nothing.
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var code: Int32 = 0
            Task.detached {
                do {
                    let releases = try await SidePulseFirmware.latest()
                    for (model, release) in releases.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                        let (zip, _) = try await URLSession.shared.data(from: release.url)
                        let firmware = try SidePulseFirmware.firmware(fromPackage: zip, for: release)
                        print("\(model.rawValue): latest \(release.version), package verified, FIRMWARE.BIN \(firmware.count) bytes")
                    }
                    for device in SidePulse.discover() {
                        let installed = device.version.flatMap(SidePulseFirmware.Version.init)
                        var verdict = "no release"
                        if let latest = releases[device.model]?.version, let installed {
                            verdict = installed < latest ? "update to \(latest)" : "up to date"
                        }
                        print("\(device.model.rawValue) \(device.serial): installed \(device.version ?? "?"), \(verdict)")
                    }
                } catch {
                    print("error:", error.localizedDescription)
                    code = 1
                }
                done.signal()
            }
            done.wait()
            return code

        case "dot-usb":
            // dot-usb [status | storage on|off | write <program file>]: exercise the Dot's USB control.
            let dots = SidePulseUSB.devices()
            guard let dot = dots.first else { print("no Dot on USB"); return 1 }
            switch arguments.first ?? "status" {
            case "storage":
                let on = arguments.dropFirst().first == "on"
                print(SidePulseUSB.setStorage(on, device: dot) ? "storage \(on ? "on" : "off"), reconnecting" : "failed")
            case "write":
                let program = (try? String(contentsOfFile: arguments.dropFirst().first ?? "", encoding: .utf8)) ?? ""
                print(SidePulseUSB.write(program, to: dot))
            default:
                print("dots: \(dots.count)")
                print("status:", SidePulseUSB.status(dot).map { "id \($0.id) state \(String(describing: $0.state)) applied \($0.applied)" } ?? "none")
                print("storage:", SidePulseUSB.storageStatus(dot).map { "saved \($0.saved) active \($0.active) \(String(describing: $0.state))" } ?? "not reported")
                print("unmounted (USB-only) dots:", SidePulseUSB.unmountedDots(mounted: SidePulse.discover()).count)
            }
            return 0

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
