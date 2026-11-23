import Foundation
import GRDB

struct SnapshotRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "snapshots"

    var id: Int64?
    var timestamp: Double
    var loadAvg: Double
    var totalProcesses: Int
    var memoryUsedMB: Int
    var memoryTotalMB: Int
    // v3: what the share cards and the cracked score need. Nil for older rows.
    var cpuCores: Int?
    /// macOS memory pressure: 0 normal, 1 warning, 2 critical.
    var memoryPressure: Int?
    /// Agents working or waiting on input.
    var activeAgents: Int?
    var localModelMB: Int?
    /// Days × GB of the worst Worth a Restart app.
    var zombieScore: Double?
    var zombieApp: String?
    var zombieDays: Double?
    var zombieGB: Double?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// The parts of a snapshot that come from outside `ps` (agents, Ollama, Worth a Restart).
struct SnapshotExtras: Sendable, Equatable {
    var cpuCores: Int
    var memoryPressure: MemoryPressure = .normal
    var activeAgents: Int = 0
    var localModelMB: Int = 0
    var zombie: Zombie?

    struct Zombie: Sendable, Equatable {
        let app: String
        let days: Double
        let gb: Double
        var score: Double { days * gb }
    }

    /// The worst Worth a Restart app by days × GB.
    static func worstZombie(_ apps: [StaleApp], now: Date = Date()) -> Zombie? {
        apps.map { app in
            Zombie(app: app.displayName, days: Double(app.main.uptimeSeconds) / 86400,
                   gb: Double(app.totalMemoryMB) / 1024)
        }
        .max { $0.score < $1.score }
    }
}

struct ProcessSnapRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "process_snaps"

    var id: Int64?
    var snapshotId: Int64
    var pid: Int32
    var appName: String
    var cpuPercent: Double
    var memoryMB: Int
    var uptimeSeconds: Int

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct RecordEntry: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "records"

    var id: Int64?
    var recordType: String
    var value: Double
    var appName: String?
    var achievedAt: Double
    var details: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct TrackedAppRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tracked_app_snapshots"

    var id: Int64?
    var timestamp: Double
    var appName: String
    var count: Int
    var label: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct AppConfigRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "app_configs"

    var appName: String
    var cpuThreshold: Double?
    var stalenessDays: Int?
    var autoKill: Bool

    enum CodingKeys: String, CodingKey {
        case appName, cpuThreshold, stalenessDays, autoKill
    }

    init(appName: String, cpuThreshold: Double? = nil, stalenessDays: Int? = nil, autoKill: Bool = false) {
        self.appName = appName
        self.cpuThreshold = cpuThreshold
        self.stalenessDays = stalenessDays
        self.autoKill = autoKill
    }
}
