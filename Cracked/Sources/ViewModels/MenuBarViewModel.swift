import Foundation
import SwiftUI

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var cpuHogs: [ProcessSnapshot] = []
    @Published var staleApps: [ProcessSnapshot] = []
    @Published var loadAverage: Double = 0
    @Published var memoryUsedGB: Double = 0
    @Published var memoryTotalGB: Double = 0
    @Published var totalProcesses: Int = 0
    @Published var iconState: IconState = .normal

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
        notificationManager.requestPermission()
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

        staleApps = userApps
            .filter { $0.uptimeSeconds >= stalenessThresholdSeconds && $0.cpuPercent < cpuThreshold }
            .sorted { $0.uptimeSeconds > $1.uptimeSeconds }
        // Deduplicate stale apps by name, keeping the longest-running instance
        var seen = Set<String>()
        staleApps = staleApps.filter { seen.insert($0.name).inserted }

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

        // Check for alerts (only /Applications/ apps)
        let alerts = alertEngine.evaluate(
            processes: userApps,
            loadAverage: snapshot.loadAverage
        )
        for alert in alerts {
            notificationManager.sendAlert(alert)
        }

        // Persist snapshot to database (every 12th poll ~ once per minute at 5s interval)
        persistCounter += 1
        if persistCounter % 12 == 0 {
            try? db?.saveSnapshot(snapshot)
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
