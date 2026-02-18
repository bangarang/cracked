import Foundation

final class RecordTracker {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    /// Check current state for new records. Returns list of human-readable record messages.
    func checkForRecords(processes: [ProcessSnapshot], totalProcessCount: Int) throws -> [String] {
        let userProcesses = processes.filter { !$0.isSystemProcess }
        var messages: [String] = []

        // 1. Peak CPU for any single process (user apps only)
        if let topCPU = userProcesses.max(by: { $0.cpuPercent < $1.cpuPercent }), topCPU.cpuPercent > 50 {
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
        let grouped = Dictionary(grouping: userProcesses, by: \.name)
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

        // 4. Longest uptime for a single app (user apps only)
        if let longestRunning = userProcesses.max(by: { $0.uptimeSeconds < $1.uptimeSeconds }),
           longestRunning.uptimeSeconds >= 86400 {
            let days = Double(longestRunning.uptimeSeconds) / 86400.0
            let existing = try db.currentRecord(type: "longest_uptime", appName: longestRunning.name)
            if existing == nil || days > existing!.value {
                try db.saveRecord(
                    type: "longest_uptime",
                    value: days,
                    appName: longestRunning.name,
                    details: "\(longestRunning.uptimeFormatted)"
                )
                messages.append("\(longestRunning.name) running for \(Int(days)) days!")
            }
        }

        return messages
    }
}
