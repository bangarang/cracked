import Foundation

struct ProcessSnapshot: Sendable, Identifiable {
    let id: Int32  // pid
    let pid: Int32
    let uid: Int
    let name: String
    let cpuPercent: Double
    let memoryMB: Int
    let uptimeSeconds: Int

    /// System processes run as root (0) or other system UIDs (< 500 on macOS).
    var isSystemProcess: Bool {
        uid < 500
    }

    var uptimeFormatted: String {
        if uptimeSeconds >= 86400 {
            return "\(uptimeSeconds / 86400)d"
        } else if uptimeSeconds >= 3600 {
            return "\(uptimeSeconds / 3600)h"
        } else if uptimeSeconds >= 60 {
            return "\(uptimeSeconds / 60)m"
        }
        return "\(uptimeSeconds)s"
    }
}

struct SystemSnapshot: Sendable {
    let timestamp: Date
    let loadAverage: Double
    let totalProcesses: Int
    let memoryUsedMB: Int
    let memoryTotalMB: Int
    let processes: [ProcessSnapshot]

    var memoryUsedGB: Double {
        Double(memoryUsedMB) / 1024.0
    }

    var memoryTotalGB: Double {
        Double(memoryTotalMB) / 1024.0
    }
}
