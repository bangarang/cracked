import Foundation

struct Alert: Sendable, Identifiable {
    let id = UUID()
    let type: AlertType
    let processName: String
    let pid: Int32
    let value: Double  // CPU% or uptime in days
    let message: String

    enum AlertType: Sendable {
        case highCPU
        case staleApp
        case highLoad
    }
}

final class AlertEngine: Sendable {
    let cpuThreshold: Double
    let sustainedSeconds: Int
    let stalenessThresholdSeconds: Int
    let cooldownSeconds: Int

    // Track when we last alerted for each process (by name)
    private let lastAlerted = Mutex<[String: Date]>([:])

    init(
        cpuThreshold: Double = 80,
        sustainedSeconds: Int = 30,
        stalenessThresholdSeconds: Int = 7 * 86400,
        cooldownSeconds: Int = 900
    ) {
        self.cpuThreshold = cpuThreshold
        self.sustainedSeconds = sustainedSeconds
        self.stalenessThresholdSeconds = stalenessThresholdSeconds
        self.cooldownSeconds = cooldownSeconds
    }

    func evaluate(processes: [ProcessSnapshot], loadAverage: Double) -> [Alert] {
        var alerts: [Alert] = []
        let now = Date()

        // Check CPU hogs
        for process in processes where process.cpuPercent >= cpuThreshold {
            if shouldAlert(for: process.name, at: now) {
                alerts.append(Alert(
                    type: .highCPU,
                    processName: process.name,
                    pid: process.pid,
                    value: process.cpuPercent,
                    message: "\(process.name) is using \(String(format: "%.0f", process.cpuPercent))% CPU"
                ))
                markAlerted(for: process.name, at: now)
            }
        }

        // Check load average
        if loadAverage > 20 {
            let key = "load_average"
            if shouldAlert(for: key, at: now) {
                alerts.append(Alert(
                    type: .highLoad,
                    processName: "System",
                    pid: 0,
                    value: loadAverage,
                    message: String(format: "System load is extremely high: %.1f", loadAverage)
                ))
                markAlerted(for: key, at: now)
            }
        }

        return alerts
    }

    private func shouldAlert(for key: String, at now: Date) -> Bool {
        lastAlerted.withLock { dict in
            guard let last = dict[key] else { return true }
            return now.timeIntervalSince(last) >= Double(cooldownSeconds)
        }
    }

    private func markAlerted(for key: String, at now: Date) {
        lastAlerted.withLock { dict in
            dict[key] = now
        }
    }
}

// Simple mutex for thread-safe access
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
