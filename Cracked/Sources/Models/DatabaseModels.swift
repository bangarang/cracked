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

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
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
