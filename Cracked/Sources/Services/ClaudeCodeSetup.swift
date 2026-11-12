import Foundation

/// Connects Cracked to Claude Code: hooks in ~/.claude/settings.json feed the
/// agent inbox, and an MCP server registration lets agents query Cracked.
enum ClaudeCodeSetup {
    static let hookEvents = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"]
    static let mcpServerName = "cracked"

    static var executablePath: String {
        Bundle.main.executablePath ?? "/Applications/Cracked.app/Contents/MacOS/Cracked"
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static func hookCommand(executable: String = executablePath) -> String {
        "'\(executable)' hook"
    }

    static func isCrackedHook(_ command: String) -> Bool {
        command.contains("Cracked") && command.hasSuffix(" hook")
    }

    // MARK: - Pure settings transforms

    /// Returns `settings` with Cracked's hooks removed (other hooks untouched).
    static func removingHooks(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = groups.compactMap { group in
                var group = group
                let entries = (group["hooks"] as? [[String: Any]]) ?? []
                let kept = entries.filter { !isCrackedHook(($0["command"] as? String) ?? "") }
                if kept.isEmpty && !entries.isEmpty { return nil }
                group["hooks"] = kept
                return group
            }
            if cleaned.isEmpty { hooks[event] = nil } else { hooks[event] = cleaned }
        }
        if hooks.isEmpty { settings["hooks"] = nil } else { settings["hooks"] = hooks }
        return settings
    }

    /// Returns `settings` with Cracked's hooks installed for every event,
    /// replacing any earlier Cracked hooks (e.g. from a different install path).
    static func installingHooks(into settings: [String: Any], executable: String = executablePath) -> [String: Any] {
        var settings = removingHooks(from: settings)
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        for event in hookEvents {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups.append(["hooks": [["type": "command", "command": hookCommand(executable: executable), "timeout": 10]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    static func hooksInstalled(in settings: [String: Any], executable: String = executablePath) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hookEvents.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String) == hookCommand(executable: executable)
                }
            }
        }
    }

    // MARK: - Hooks on disk

    static func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SetupError.unreadableSettings
        }
        return object
    }

    static func writeSettings(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("cracked-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    static var areHooksInstalled: Bool {
        (try? hooksInstalled(in: readSettings())) ?? false
    }

    static func installHooks() throws {
        try writeSettings(installingHooks(into: readSettings()))
    }

    static func uninstallHooks() throws {
        try writeSettings(removingHooks(from: readSettings()))
    }

    // MARK: - MCP server (via the claude CLI, which owns ~/.claude.json)

    static var isMCPInstalled: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return false }
        return servers[mcpServerName] != nil
    }

    static var mcpAddCommand: String {
        "claude mcp add --scope user \(mcpServerName) -- '\(executablePath)' mcp"
    }

    static func installMCP() throws {
        _ = try? runClaude("claude mcp remove --scope user \(mcpServerName)")
        let output = try runClaude(mcpAddCommand)
        guard isMCPInstalled else { throw SetupError.claudeCLIFailed(output) }
    }

    static func uninstallMCP() throws {
        _ = try runClaude("claude mcp remove --scope user \(mcpServerName)")
    }

    /// Runs a `claude` command through a login shell so the user's PATH applies.
    private static func runClaude(_ command: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    enum SetupError: LocalizedError {
        case unreadableSettings
        case claudeCLIFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadableSettings:
                "~/.claude/settings.json isn't valid JSON, so Cracked left it alone."
            case .claudeCLIFailed(let output):
                "The claude CLI couldn't add the MCP server: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }
}
