import Foundation
import SwiftUI

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var cpuHogs: [ProcessSnapshot] = []
    @Published var staleApps: [ProcessSnapshot] = []
    @Published var trackedApps: [TrackedAppCount] = []
    @Published var loadAverage: Double = 0
    @Published var memoryUsedGB: Double = 0
    @Published var memoryTotalGB: Double = 0
    @Published var totalProcesses: Int = 0
    @Published var iconState: IconState = .normal

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

    @AppStorage("cpuThreshold") var cpuThreshold: Double = 30.0
    @AppStorage("stalenessThresholdDays") private var stalenessThresholdDays: Int = 7
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

        // For stale apps, use only the main app executable (not helpers/renderers)
        staleApps = userApps
            .filter { $0.uptimeSeconds >= stalenessThresholdSeconds && $0.cpuPercent < cpuThreshold }
            .filter { !$0.name.contains("Helper") }
            .sorted { $0.uptimeSeconds > $1.uptimeSeconds }
        // Deduplicate by display name, keeping the longest-running instance
        var seen = Set<String>()
        staleApps = staleApps.filter { seen.insert($0.displayName).inserted }

        // Tracked app counts (computed from full process list)
        trackedApps = computeTrackedApps(from: snapshot.processes)

        // Determine icon state
        let hasCritical = cpuHogs.contains { $0.cpuPercent >= 100 }
        let hasWarning = !cpuHogs.isEmpty || loadAverage > 8
        if hasCritical || loadAverage > 20 {
            iconState = .critical
        } else if hasWarning {
            iconState = .warning
        } else {
            iconState = .normal
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

    private func computeTrackedApps(from processes: [ProcessSnapshot]) -> [TrackedAppCount] {
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

    func restartApp(_ process: ProcessSnapshot) {
        let appName = process.name
        kill(process.pid, SIGTERM)

        Task {
            try? await Task.sleep(for: .seconds(1))
            let appURL = URL(fileURLWithPath: "/Applications/\(appName).app")
            if FileManager.default.fileExists(atPath: appURL.path) {
                try? await NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
            }
        }
    }
}
