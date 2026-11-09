import Foundation
import SwiftUI
import AppKit

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

    @AppStorage("cpuThreshold") var cpuThreshold: Double = CrackedSettings.defaultCPUThreshold
    @AppStorage("agentNotifications") private var agentNotifications: Bool = false
    @AppStorage("stalenessThresholdDays") private var stalenessThresholdDays: Int = 7
    @AppStorage("restartMemoryThresholdGB") private var restartMemoryThresholdGB: Double = 2.0
    @AppStorage("pollIntervalSeconds") private var pollInterval: Double = 5.0
    @AppStorage("cooldownMinutes") private var cooldownMinutes: Int = 15

    var stalenessThresholdSeconds: Int { stalenessThresholdDays * 86400 }

    init() {
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

        switch PressureLevel.from(cpuHogs: cpuHogs, loadAverage: loadAverage) {
        case .critical: iconState = .critical
        case .warning: iconState = .warning
        case .normal: iconState = .normal
        }

        // Persist snapshot to database (every 12th poll ~ once per minute at 5s interval)
        persistCounter += 1
        if persistCounter % 12 == 0 {
            try? db?.saveSnapshot(snapshot)
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

        // Downsample every ~hour (720 polls at 5s interval)
        if persistCounter % 720 == 0 && persistCounter > 0 {
            try? db?.downsample()
        }

        // Check for new records (tracked silently, viewable in Records & Stats)
        _ = try? recordTracker?.checkForRecords(
            processes: snapshot.processes,
            totalProcessCount: snapshot.totalProcesses
        )
    }

    nonisolated static func computeTrackedApps(from processes: [ProcessSnapshot]) -> [TrackedAppCount] {
        var results: [TrackedAppCount] = []

        // Browser tabs: count "Helper (Renderer)" processes per browser
        let browsers: [(name: String, keyword: String, bundle: String)] = [
            ("Comet", "Comet", "/Applications/Comet.app"),
            ("Arc", "Arc", "/Applications/Arc.app"),
            ("Chrome", "Google Chrome", "/Applications/Google Chrome.app"),
        ]
        for browser in browsers {
            let count = processes.count { $0.name.contains(browser.keyword) && $0.name.contains("Helper (Renderer)") }
            if count > 0 {
                results.append(TrackedAppCount(name: browser.name, count: count, label: "tabs", appBundlePath: browser.bundle))
            }
        }

        // Cursor windows: count "Cursor Helper (Renderer)" processes
        let cursorWindows = processes.count { $0.name.contains("Cursor") && $0.name.contains("Helper (Renderer)") }
        if cursorWindows > 0 {
            results.append(TrackedAppCount(name: "Cursor", count: cursorWindows, label: "windows", appBundlePath: "/Applications/Cursor.app"))
        }

        // Claude Code instances: bare "claude" processes (not Claude.app)
        let claudeCount = processes.count { p in
            let n = p.name
            return (n == "claude" || n.hasSuffix("/claude")) && !n.contains("Claude.app")
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

    /// Re-reads the agent inbox, applies the transcript heuristic, and notifies
    /// (if enabled) when a session newly finishes or needs input.
    func refreshAgents() {
        let sessions = AgentInbox.loadAll().map { session -> AgentSession in
            var session = session
            session.status = session.effectiveStatus(transcriptModifiedAt: AgentInbox.transcriptModifiedAt(session))
            return session
        }

        if let known = knownAgentStatuses, agentNotifications {
            for session in sessions where session.isWaiting && known[session.sessionID] != session.status {
                notificationManager.sendAgentNotification(session)
            }
        }
        knownAgentStatuses = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0.status) })

        if sessions != agentSessions { agentSessions = sessions }
        let waiting = sessions.filter {
            $0.status == .needsInput || ($0.status == .done && $0.updatedAt > agentsLastSeenAt)
        }.count
        if waiting != agentsWaitingCount { agentsWaitingCount = waiting }
    }

    /// Called when the dropdown opens: finished sessions have now been seen.
    func markAgentsSeen() {
        agentsLastSeenAt = Date()
        refreshAgents()
    }

    func focusAgent(_ session: AgentSession) {
        if let pid = session.terminalPID {
            AppActions.activate(pid: pid)
        }
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
