import Foundation
import AppKit

/// User settings, with one set of defaults shared by the app, the Settings
/// window, the CLI and the MCP server.
struct CrackedSettings: Sendable {
    static let defaultCPUThreshold = 80.0
    static let defaultStalenessDays = 7
    static let defaultRestartMemoryGB = 2.0

    var cpuThreshold: Double = defaultCPUThreshold
    var stalenessDays: Int = defaultStalenessDays
    var restartMemoryGB: Double = defaultRestartMemoryGB

    static func load(from defaults: UserDefaults = .standard) -> CrackedSettings {
        var settings = CrackedSettings()
        if defaults.object(forKey: "cpuThreshold") != nil {
            settings.cpuThreshold = defaults.double(forKey: "cpuThreshold")
        }
        if defaults.object(forKey: "stalenessThresholdDays") != nil {
            settings.stalenessDays = defaults.integer(forKey: "stalenessThresholdDays")
        }
        if defaults.object(forKey: "restartMemoryThresholdGB") != nil {
            settings.restartMemoryGB = defaults.double(forKey: "restartMemoryThresholdGB")
        }
        return settings
    }
}

/// How stressed the machine is; drives the menu bar icon colour.
enum PressureLevel: String, Codable, Sendable {
    case normal, warning, critical

    static func from(cpuHogs: [ProcessSnapshot], loadAverage: Double,
                     memoryPressure: MemoryPressure = .normal) -> PressureLevel {
        if cpuHogs.contains(where: { $0.cpuPercent >= 100 }) || loadAverage > 20 || memoryPressure == .critical {
            return .critical
        }
        if !cpuHogs.isEmpty || loadAverage > 8 || memoryPressure == .warning { return .warning }
        return .normal
    }
}

/// A point-in-time picture of the machine, shared by `Cracked status`,
/// the MCP server and the SessionStart hook.
struct SystemReport: Encodable, Sendable {
    struct Hog: Encodable, Sendable {
        let name: String
        let pid: Int32
        let cpuPercent: Double
        let memoryMB: Int
    }

    struct RestartCandidate: Encodable, Sendable {
        let name: String
        let pid: Int32
        let bundlePath: String
        let memoryMB: Int
        let memory: String
        let processCount: Int
        let uptime: String
        let uptimeSeconds: Int
    }

    struct Tracked: Encodable, Sendable {
        let name: String
        let count: Int
        let label: String
    }

    struct Agent: Encodable, Sendable {
        let sessionID: String
        /// "paseo", "terminal" (found running in a terminal) or "claudeCode" (reported by hooks).
        let source: String
        let provider: String?
        let title: String?
        let project: String
        let cwd: String
        let status: String
        let message: String?
        let terminal: String?
        let updatedAt: Date
    }

    let timestamp: Date
    let pressure: PressureLevel
    let loadAverage: Double
    let cpuCores: Int
    let memoryUsedGB: Double
    let memoryTotalGB: Double
    let totalProcesses: Int
    let cpuHogs: [Hog]
    let worthARestart: [RestartCandidate]
    let trackedApps: [Tracked]
    let agents: [Agent]
    /// macOS's memory pressure: "normal", "warning" or "critical".
    let memoryPressure: MemoryPressure
    /// Models Ollama has loaded; empty when Ollama isn't running.
    let localModels: [LocalModel]

    // MARK: - Building

    static func build(snapshot: SystemSnapshot, settings: CrackedSettings,
                      launchedAppPIDs: Set<Int32>, ignoredBundlePaths: Set<String>,
                      agents: [AgentSession], cpuCores: Int,
                      memoryPressure: MemoryPressure = .normal, localModels: [LocalModel] = []) -> SystemReport {
        let userApps = snapshot.processes.filter { $0.isUserApp }
        let hogs = userApps
            .filter { $0.cpuPercent >= settings.cpuThreshold }
            .sorted { $0.cpuPercent > $1.cpuPercent }
        let stale = StaleAppDetector.detect(
            processes: userApps,
            launchedAppPIDs: launchedAppPIDs,
            stalenessThresholdSeconds: settings.stalenessDays * 86400,
            memoryThresholdMB: Int(settings.restartMemoryGB * 1024),
            cpuThreshold: settings.cpuThreshold,
            ignoredBundlePaths: ignoredBundlePaths
        )
        let tracked = MenuBarViewModel.computeTrackedApps(from: snapshot.processes)

        return SystemReport(
            timestamp: snapshot.timestamp,
            pressure: .from(cpuHogs: hogs, loadAverage: snapshot.loadAverage, memoryPressure: memoryPressure),
            loadAverage: (snapshot.loadAverage * 100).rounded() / 100,
            cpuCores: cpuCores,
            memoryUsedGB: (snapshot.memoryUsedGB * 10).rounded() / 10,
            memoryTotalGB: (snapshot.memoryTotalGB * 10).rounded() / 10,
            totalProcesses: snapshot.totalProcesses,
            cpuHogs: hogs.prefix(10).map {
                Hog(name: $0.displayName, pid: $0.pid, cpuPercent: $0.cpuPercent, memoryMB: $0.memoryMB)
            },
            worthARestart: stale.map {
                RestartCandidate(name: $0.displayName, pid: $0.main.pid, bundlePath: $0.bundlePath,
                                 memoryMB: $0.totalMemoryMB, memory: $0.memoryFormatted,
                                 processCount: $0.processCount, uptime: $0.main.uptimeFormatted,
                                 uptimeSeconds: $0.main.uptimeSeconds)
            },
            trackedApps: tracked.map { Tracked(name: $0.name, count: $0.count, label: $0.label) },
            agents: agents.map {
                Agent(sessionID: $0.sessionID, source: $0.source.rawValue, provider: $0.provider,
                      title: $0.title, project: $0.projectName, cwd: $0.cwd, status: $0.status.rawValue,
                      message: $0.message, terminal: $0.terminalName, updatedAt: $0.updatedAt)
            },
            memoryPressure: memoryPressure,
            localModels: localModels
        )
    }

    /// Takes a fresh reading of this Mac.
    static func current() -> SystemReport {
        let processes = ProcessMonitor.fetchProcesses()
        let (usedMB, totalMB) = ProcessMonitor.fetchMemory()
        let snapshot = SystemSnapshot(
            timestamp: Date(), loadAverage: ProcessMonitor.fetchLoadAverage(),
            totalProcesses: processes.count, memoryUsedMB: usedMB, memoryTotalMB: totalMB,
            processes: processes
        )
        return build(
            snapshot: snapshot,
            settings: .load(),
            launchedAppPIDs: launchedAppPIDs(),
            ignoredBundlePaths: IgnoredApps.load().activeBundlePaths(),
            agents: AgentFeed.load(paseo: PaseoAgentReader(), openCode: OpenCodeAgentReader()),
            cpuCores: ProcessInfo.processInfo.activeProcessorCount,
            memoryPressure: .current(),
            localModels: Ollama.isRunning(processes: processes) ? (Ollama.loadedModelsSync() ?? []) : []
        )
    }

    /// PIDs of regular (Dock-visible) apps, i.e. apps the user actually launched.
    static func launchedAppPIDs() -> Set<Int32> {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map(\.processIdentifier))
    }

    // MARK: - Rendering

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private var memoryPercent: Double {
        memoryTotalGB > 0 ? memoryUsedGB / memoryTotalGB : 0
    }

    var localModelsGB: Double { localModels.reduce(0) { $0 + $1.sizeGB } }

    /// "gemma4:26b 22.3 GB, qwen3-embedding:0.6b 4.4 GB (26.7 GB, 56% of RAM)"
    var localModelsSummary: String? {
        guard !localModels.isEmpty else { return nil }
        let models = localModels.map { String(format: "%@ %.1f GB", $0.name, $0.sizeGB) }.joined(separator: ", ")
        let share = memoryTotalGB > 0 ? String(format: ", %.0f%% of RAM", localModelsGB / memoryTotalGB * 100) : ""
        return models + String(format: " (%.1f GB", localModelsGB) + share + ")"
    }

    /// Human-readable summary for `Cracked status`.
    var summary: String {
        var lines: [String] = []
        let mood = ["normal": "chill", "warning": "warning", "critical": "cracked"][pressure.rawValue] ?? pressure.rawValue
        lines.append(String(format: "Cracked · %@ · load %.1f on %d cores · RAM %.0f/%.0f GB · %d processes",
                            mood, loadAverage, cpuCores, memoryUsedGB, memoryTotalGB, totalProcesses))
        if !cpuHogs.isEmpty {
            lines.append("CPU hogs: " + cpuHogs.prefix(5).map { "\($0.name) \(Int($0.cpuPercent))%" }.joined(separator: ", "))
        }
        if !worthARestart.isEmpty {
            lines.append("Worth a restart: " + worthARestart.map { "\($0.name) (\($0.memory) · \($0.uptime))" }.joined(separator: ", "))
        }
        if memoryPressure != .normal {
            lines.append("Memory pressure: \(memoryPressure.rawValue)")
        }
        if let models = localModelsSummary {
            lines.append("Local models: " + models)
        }
        if !trackedApps.isEmpty {
            lines.append("Tracked: " + trackedApps.map { "\($0.name) \($0.count) \($0.label)" }.joined(separator: ", "))
        }
        if !agents.isEmpty {
            lines.append("Agents:")
            for agent in agents {
                let status = ["ready": "idle", "working": "working", "needsInput": "needs input", "done": "done",
                              "error": "error", "running": "running"][agent.status] ?? agent.status
                let via = agent.source == "paseo" ? " (Paseo)" : agent.terminal.map { " (\($0))" } ?? ""
                lines.append("  • \(agent.project)\(via): \(status)\(agent.message.map { " · \($0)" } ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Context for a new Claude Code or OpenCode session, only when the machine is under
    /// pressure (so it's useful signal, not noise in every session).
    var agentBrief: String? {
        guard pressure != .normal || memoryPercent >= 0.9 else { return nil }
        var parts = [String(format: "load %.1f on %d cores", loadAverage, cpuCores),
                     String(format: "RAM %.0f/%.0f GB", memoryUsedGB, memoryTotalGB)]
        if !cpuHogs.isEmpty {
            parts.append("CPU hogs: " + cpuHogs.prefix(3).map { "\($0.name) \(Int($0.cpuPercent))%" }.joined(separator: ", "))
        }
        if memoryPressure != .normal {
            parts.append("memory pressure \(memoryPressure.rawValue)")
        }
        if let models = localModelsSummary {
            parts.append("Ollama models loaded: " + models)
        }
        let busyAgents = agents.filter { $0.status == "working" }.count
        if busyAgents > 0 {
            parts.append("\(busyAgents) other coding agent\(busyAgents == 1 ? "" : "s") working")
        }
        return "[Cracked system monitor] This Mac is under heavy load: " + parts.joined(separator: " · ")
            + ". Prefer running builds and test suites one at a time, and avoid starting extra heavy processes"
            + (localModels.isEmpty ? "." : " or loading more local models.")
    }
}

/// Actions shared by the menu bar app and the MCP server.
enum AppActions {
    /// Quits an app gracefully, waits for it to exit, and relaunches it. Blocking.
    @discardableResult
    static func restart(pid: pid_t, bundlePath: String, timeout: TimeInterval = 10) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
        } else {
            kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while ProcessTree.isAlive(pid), Date() < deadline {
            usleep(250_000)
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [bundlePath]
        do {
            try open.run()
            open.waitUntilExit()
            return open.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Brings an app (e.g. the terminal hosting a Claude Code session) to the front.
    @discardableResult
    static func activate(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activate() ?? false
    }
}
