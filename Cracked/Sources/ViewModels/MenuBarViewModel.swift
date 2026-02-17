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
    private var started = false

    // Thresholds (will be configurable later via Settings)
    var cpuThreshold: Double = 30.0
    var stalenessThresholdSeconds: Int = 7 * 86400  // 7 days

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

        cpuHogs = snapshot.processes
            .filter { $0.cpuPercent >= cpuThreshold }
            .sorted { $0.cpuPercent > $1.cpuPercent }

        staleApps = snapshot.processes
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
