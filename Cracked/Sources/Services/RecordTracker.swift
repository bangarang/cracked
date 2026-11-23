import Foundation

final class RecordTracker {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    /// Check current state for new records. Returns list of human-readable record messages.
    func checkForRecords(processes: [ProcessSnapshot], totalProcessCount: Int) throws -> [String] {
        let userApps = processes.filter { $0.isUserApp }
        var messages: [String] = []

        // 1. Peak CPU for any single process (user apps only)
        if let topCPU = userApps.max(by: { $0.cpuPercent < $1.cpuPercent }), topCPU.cpuPercent > 50 {
            let existing = try db.currentRecord(type: "peak_cpu")
            if existing == nil || topCPU.cpuPercent > existing!.value {
                try db.saveRecord(
                    type: "peak_cpu",
                    value: topCPU.cpuPercent,
                    appName: topCPU.name,
                    details: "PID \(topCPU.pid)"
                )
                messages.append("\(topCPU.name) hit \(String(format: "%.0f", topCPU.cpuPercent))% CPU!")
            }
        }

        // 2. Most processes from a single app (user apps only)
        let grouped = Dictionary(grouping: userApps, by: \.name)
        for (appName, appProcesses) in grouped where appProcesses.count >= 10 {
            let count = Double(appProcesses.count)
            let existing = try db.currentRecord(type: "process_count", appName: appName)
            if existing == nil || count > existing!.value {
                try db.saveRecord(
                    type: "process_count",
                    value: count,
                    appName: appName,
                    details: "That's cracked."
                )
                messages.append("\(Int(count)) \(appName) processes at once!")
            }
        }

        // 3. Total system process count
        let totalCount = Double(totalProcessCount)
        if totalProcessCount >= 500 {
            let existing = try db.currentRecord(type: "total_processes")
            if existing == nil || totalCount > existing!.value {
                try db.saveRecord(
                    type: "total_processes",
                    value: totalCount,
                    details: "System-wide"
                )
                messages.append("\(totalProcessCount) total processes running!")
            }
        }

        return messages
    }

    /// Records that need more than `ps`: load per core, agents, local models, zombies.
    /// Returns the record types that were beaten, for share prompts.
    @discardableResult
    func checkExtendedRecords(loadPerCore: Double, activeAgents: Int, localModelGB: Double,
                              zombie: SnapshotExtras.Zombie?) throws -> [String] {
        var beaten: [String] = []
        func check(_ type: String, _ value: Double, minimum: Double, app: String? = nil, details: String? = nil) throws {
            guard value >= minimum else { return }
            let existing = try db.currentRecord(type: type)
            if existing == nil || value > existing!.value {
                try db.saveRecord(type: type, value: value, appName: app, details: details)
                beaten.append(type)
            }
        }
        try check("peak_load_per_core", loadPerCore, minimum: 1)
        try check("peak_concurrent_agents", Double(activeAgents), minimum: 2)
        try check("peak_local_model_gb", localModelGB, minimum: 1)
        if let zombie {
            // One zombie record, whichever app holds it (saveRecord keys records by app).
            try check("zombie_score", zombie.score, minimum: 10,
                      details: String(format: "%@ · %.0f GB · %.0fd", zombie.app, zombie.gb, zombie.days))
        }
        return beaten
    }
}
