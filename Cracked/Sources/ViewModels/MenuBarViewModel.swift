import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var cpuHogs: [ProcessSnapshot] = []
    @Published var staleApps: [StaleApp] = []
    @Published var trackedApps: [TrackedAppCount] = []
    @Published var loadAverage: Double = 0
    @Published var memoryUsedGB: Double = 0
    @Published var memoryTotalGB: Double = 0
    @Published var totalProcesses: Int = 0
    @Published var iconState: IconState = .normal
    @Published var agentSessions: [AgentSession] = []
    /// Sessions that finished or got blocked since the menu was last opened.
    @Published var agentsWaitingCount: Int = 0
    /// Models Ollama has loaded, biggest first.
    @Published var localModels: [LocalModel] = []
    /// Models being unloaded, so their button can show progress.
    @Published var unloadingModels: Set<String> = []
    @Published var memoryPressure: MemoryPressure = .normal
    /// The full picture of this Mac, rebuilt with each new reading. Served to the fleet
    /// and used for the Right Now share card.
    @Published private(set) var latestReport: SystemReport?
    private(set) var machine = MachineIdentity.current()

    struct TrackedAppCount: Identifiable {
        let id = UUID()
        let name: String
        let count: Int
        let label: String
        let appBundlePath: String?
    }

    let monitor = ProcessMonitor()
    let alertEngine = AlertEngine()
    let notificationManager = NotificationManager.shared
    private(set) var db: DatabaseManager?
    private var recordTracker: RecordTracker?
    private var started = false
    private var persistCounter = 0
    private var agentsLastSeenAt = Date()
    private var knownAgentStatuses: [String: AgentSession.Status]?
    private var agentObserver: NSObjectProtocol?
    private let paseoReader = PaseoAgentReader()
    private var lastOllamaPoll = Date.distantPast
    private var ollamaPollInFlight = false
    private var lastSnapshotTime: Date?
    private var fleetForwarder: AnyCancellable?
    private var fleetCLIObserver: NSObjectProtocol?
    /// Paired Macs. Created in `start()` once the database is open.
    private(set) var fleet: FleetMonitor!

    @AppStorage("cpuThreshold") var cpuThreshold: Double = CrackedSettings.defaultCPUThreshold
    @AppStorage("agentNotifications") private var agentNotifications: Bool = false
    @AppStorage("stalenessThresholdDays") private var stalenessThresholdDays: Int = 7
    @AppStorage("restartMemoryThresholdGB") private var restartMemoryThresholdGB: Double = 2.0
    @AppStorage("pollIntervalSeconds") private var pollInterval: Double = 5.0
    @AppStorage("cooldownMinutes") private var cooldownMinutes: Int = 15

    var stalenessThresholdSeconds: Int { stalenessThresholdDays * 86400 }

    /// The app's instance, for code outside SwiftUI (reopening the app).
    private(set) static weak var shared: MenuBarViewModel?

    init() {
        Self.shared = self
        start()
    }

    enum IconState {
        case normal
        case warning
        case critical

        var systemImage: String {
            switch self {
            case .normal: "gauge.low"
            case .warning: "gauge.medium"
            case .critical: "gauge.high"
            }
        }

        var color: Color {
            switch self {
            case .normal: .primary
            case .warning: .yellow
            case .critical: .red
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        db = try? DatabaseManager()
        if let db { recordTracker = RecordTracker(db: db) }
        fleet = FleetMonitor(db: db)
        // Fleet changes (remote agents waiting) affect the menu bar badge.
        // Re-render the menu when paired Macs report in, and update the badge.
        fleetForwarder = fleet.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor in self?.updateWaitingCount() }
        }
        fleet.notifyAgent = { [weak self] agent in
            guard let self, self.agentNotifications else { return }
            self.notificationManager.sendRemoteAgentNotification(agent.agent, machineName: agent.peer.name)
        }
        fleet.startIfEnabled()
        // `Cracked fleet on|off|pair` from a terminal.
        fleetCLIObserver = DistributedNotificationCenter.default().addObserver(
            forName: CrackedCLI.fleetChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.fleet.syncWithSettings() }
        }
        monitor.start()
        refreshAgents()
        if agentNotifications { notificationManager.requestPermission() }
        // `Cracked hook` posts this whenever a Claude Code session changes state.
        agentObserver = DistributedNotificationCenter.default().addObserver(
            forName: AgentInbox.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAgents() }
        }
        // Observe changes from monitor
        Task {
            while true {
                try? await Task.sleep(for: .seconds(1))
                updateFromSnapshot()
            }
        }
    }

    private func updateFromSnapshot() {
        guard let snapshot = monitor.latestSnapshot else { return }

        loadAverage = snapshot.loadAverage
        memoryUsedGB = snapshot.memoryUsedGB
        memoryTotalGB = snapshot.memoryTotalGB
        totalProcesses = snapshot.totalProcesses

        let userApps = snapshot.processes.filter { $0.isUserApp }

        cpuHogs = userApps
            .filter { $0.cpuPercent >= cpuThreshold }
            .sorted { $0.cpuPercent > $1.cpuPercent }

        // "Worth a Restart": apps the user launched (regular, Dock-visible apps, which
        // excludes .appex extensions, helpers and agents macOS starts at login) that have
        // been up for days AND are using enough memory, across all of their helper
        // processes, that restarting them would actually free something.
        let launchedAppPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map(\.processIdentifier)
        )
        staleApps = StaleAppDetector.detect(
            processes: userApps,
            launchedAppPIDs: launchedAppPIDs,
            stalenessThresholdSeconds: stalenessThresholdSeconds,
            memoryThresholdMB: Int(restartMemoryThresholdGB * 1024),
            cpuThreshold: cpuThreshold,
            ignoredBundlePaths: IgnoredApps.load().activeBundlePaths()
        )

        // Tracked app counts (computed from full process list)
        trackedApps = Self.computeTrackedApps(from: snapshot.processes)
        refreshAgents()

        memoryPressure = .current()
        pollOllamaIfDue(running: Ollama.isRunning(processes: snapshot.processes))

        switch PressureLevel.from(cpuHogs: cpuHogs, loadAverage: loadAverage, memoryPressure: memoryPressure) {
        case .critical: iconState = .critical
        case .warning: iconState = .warning
        case .normal: iconState = .normal
        }

        // Everything below runs once per new reading, not on every 1-second UI tick.
        guard snapshot.timestamp != lastSnapshotTime else { return }
        lastSnapshotTime = snapshot.timestamp

        let report = SystemReport.build(
            snapshot: snapshot, settings: .load(), launchedAppPIDs: launchedAppPIDs,
            ignoredBundlePaths: IgnoredApps.load().activeBundlePaths(), agents: agentSessions,
            cpuCores: machine.cpuCores, memoryPressure: memoryPressure, localModels: localModels,
            machine: machine, idleSeconds: UserActivity.idleSeconds())
        latestReport = report
        fleet.latestReport.set(report)

        let extras = SnapshotExtras(
            cpuCores: machine.cpuCores, memoryPressure: memoryPressure,
            activeAgents: report.activeAgentCount, localModelMB: Int(localModelsGB * 1024),
            zombie: SnapshotExtras.worstZombie(staleApps))
        _ = try? recordTracker?.checkExtendedRecords(
            loadPerCore: report.loadPerCore, activeAgents: extras.activeAgents,
            localModelGB: localModelsGB, zombie: extras.zombie)

        // Persist snapshot to database (every 12th reading: once a minute at the default 5 s interval)
        persistCounter += 1
        if persistCounter % 12 == 0 {
            // Pick up a renamed Mac without a relaunch.
            machine = MachineIdentity.current()
            fleet.machine.set(machine)
            try? db?.saveSnapshot(snapshot, extras: extras)
            // Save tracked app counts and check for PRs
            if !trackedApps.isEmpty {
                try? db?.saveTrackedAppCounts(trackedApps.map { ($0.name, $0.count, $0.label) })
                for app in trackedApps {
                    let recordType = "peak_\(app.label)"
                    let existing = try? db?.currentRecord(type: recordType, appName: app.name)
                    if existing == nil || Double(app.count) > existing!.value {
                        try? db?.saveRecord(
                            type: recordType,
                            value: Double(app.count),
                            appName: app.name,
                            details: "PR!"
                        )
                    }
                }
            }
        }

        // Downsample every ~hour (720 readings at 5s interval)
        if persistCounter % 720 == 0 && persistCounter > 0 {
            try? db?.downsample()
        }

        // Check for new records (tracked silently, viewable in Records & Stats)
        _ = try? recordTracker?.checkForRecords(
            processes: snapshot.processes,
            totalProcessCount: snapshot.totalProcesses
        )
    }

    /// Chromium renderer helpers: "Comet Helper (Renderer)", and newer builds'
    /// "Comet Helper (Aperitif Renderer)". One per tab (or per Electron window).
    nonisolated static func isRenderer(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard let open = name.range(of: "Helper ("), name.hasSuffix(")") else { return false }
        return name[open.upperBound...].contains("Renderer")
    }

    nonisolated static func computeTrackedApps(from processes: [ProcessSnapshot]) -> [TrackedAppCount] {
        var results: [TrackedAppCount] = []

        // Browser tabs: count renderer helpers per browser (see isRenderer)
        let browsers: [(name: String, keyword: String, bundle: String)] = [
            ("Comet", "Comet", "/Applications/Comet.app"),
            ("Arc", "Arc", "/Applications/Arc.app"),
            ("Chrome", "Google Chrome", "/Applications/Google Chrome.app"),
        ]
        for browser in browsers {
            let count = processes.count { $0.name.contains(browser.keyword) && isRenderer($0.name) }
            if count > 0 {
                results.append(TrackedAppCount(name: browser.name, count: count, label: "tabs", appBundlePath: browser.bundle))
            }
        }

        // Cursor windows: count Cursor renderer helpers
        let cursorWindows = processes.count { $0.name.contains("Cursor") && isRenderer($0.name) }
        if cursorWindows > 0 {
            results.append(TrackedAppCount(name: "Cursor", count: cursorWindows, label: "windows", appBundlePath: "/Applications/Cursor.app"))
        }

        // Claude Code instances: bare "claude" processes (not Claude.app)
        // Paseo agents: agent runtimes (claude, opencode…) the Paseo daemon is running
        let paseoDaemonPIDs = Set(processes.filter { $0.name.hasSuffix("Paseo Daemon") }.map(\.pid))
        let paseoAgents = processes.count { p in
            paseoDaemonPIDs.contains(p.ppid) && p.name != "<defunct>"
                && TerminalAgents.kind(name: (p.name as NSString).lastPathComponent, path: p.name) != nil
        }
        if paseoAgents > 0 {
            results.append(TrackedAppCount(name: "Paseo", count: paseoAgents, label: "agents", appBundlePath: "/Applications/Paseo.app"))
        }

        // Claude Code sessions outside Paseo: bare "claude" processes (not Claude.app)
        let claudeCount = processes.count { p in
            let n = p.name
            return (n == "claude" || n.hasSuffix("/claude")) && !n.contains("Claude.app")
                && !paseoDaemonPIDs.contains(p.ppid)
        }
        if claudeCount > 0 {
            results.append(TrackedAppCount(name: "Claude Code", count: claudeCount, label: "sessions", appBundlePath: "/Applications/Claude.app"))
        }

        // Warp tabs: count login shell processes whose parent is a Warp process
        let warpPIDs = Set(processes.filter { $0.name.contains("Warp.app") }.map { $0.pid })
        if !warpPIDs.isEmpty {
            let warpTabs = processes.count { p in
                warpPIDs.contains(p.ppid) && p.name.hasPrefix("-")
            }
            if warpTabs > 0 {
                results.append(TrackedAppCount(name: "Warp", count: warpTabs, label: "tabs", appBundlePath: "/Applications/Warp.app"))
            }
        }

        return results
    }

    func refreshNow() {
        monitor.pollNow()
        lastOllamaPoll = .distantPast
    }

    // MARK: - Local models

    var localModelsGB: Double { localModels.reduce(0) { $0 + $1.sizeGB } }

    /// Asks Ollama what's loaded every 5 seconds, and only while it's running.
    private func pollOllamaIfDue(running: Bool) {
        guard running else {
            if !localModels.isEmpty { localModels = [] }
            return
        }
        guard !ollamaPollInFlight, Date().timeIntervalSince(lastOllamaPoll) >= 5 else { return }
        ollamaPollInFlight = true
        lastOllamaPoll = Date()
        Task {
            let models = await Ollama.loadedModels()
            ollamaPollInFlight = false
            let loaded = models ?? []
            if loaded != localModels { localModels = loaded }
        }
    }

    func unloadModel(_ model: LocalModel) {
        unloadingModels.insert(model.name)
        Task {
            await Ollama.unload(model: model.name)
            unloadingModels.remove(model.name)
            lastOllamaPoll = .distantPast
            if let models = await Ollama.loadedModels() { localModels = models }
        }
    }

    func killProcess(_ process: ProcessSnapshot) {
        kill(process.pid, SIGTERM)
    }

    func restartApp(_ app: StaleApp) {
        let pid = app.main.pid
        let bundlePath = app.bundlePath
        // Quits gracefully, waits for big apps to exit, then relaunches (off the main thread).
        Task.detached {
            AppActions.restart(pid: pid, bundlePath: bundlePath)
            await MainActor.run { self.refreshNow() }
        }
    }

    // MARK: - Agents

    /// Re-reads Paseo agents, terminal sessions and hook sessions, and notifies
    /// (if enabled) when one newly finishes, errors or needs input.
    func refreshAgents() {
        let sessions = AgentFeed.load(paseo: paseoReader)

        // With other Macs awake, only the one you used last notifies.
        let notifyHere = fleet == nil || !fleet.isEnabled || fleet.shouldNotifyHere()
        if let known = knownAgentStatuses, agentNotifications, notifyHere {
            for session in sessions where session.isWaiting && known[session.sessionID] != session.status {
                notificationManager.sendAgentNotification(session)
            }
        }
        knownAgentStatuses = Dictionary(sessions.map { ($0.sessionID, $0.status) }, uniquingKeysWith: { first, _ in first })

        if sessions != agentSessions { agentSessions = sessions }
        updateWaitingCount()
    }

    /// Agents blocked, or finished since the menu was last opened, on this Mac and paired Macs.
    private func updateWaitingCount() {
        let local = agentSessions.filter {
            $0.status == .needsInput || ($0.isWaiting && $0.updatedAt > agentsLastSeenAt)
        }.count
        let remote = (fleet?.remoteAgents ?? []).filter {
            $0.agent.status == "needsInput" || ($0.isWaiting && $0.agent.updatedAt > agentsLastSeenAt)
        }.count
        if local + remote != agentsWaitingCount { agentsWaitingCount = local + remote }
    }

    /// Called when the dropdown opens: finished sessions have now been seen.
    func markAgentsSeen() {
        agentsLastSeenAt = Date()
        refreshAgents()
    }

    func focusAgent(_ session: AgentSession) {
        AgentNavigator.focus(session)
    }

    func ignoreApp(_ app: StaleApp) {
        updateIgnoredApps { $0.ignoreForever(app.bundlePath) }
    }

    func snoozeApp(_ app: StaleApp) {
        updateIgnoredApps { $0.snooze(app.bundlePath) }
    }

    private func updateIgnoredApps(_ change: (inout IgnoredApps) -> Void) {
        var ignored = IgnoredApps.load()
        ignored.prune()
        change(&ignored)
        ignored.save()
        staleApps.removeAll { ignored.activeBundlePaths().contains($0.bundlePath) }
    }
}
