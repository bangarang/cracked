import Foundation
import GRDB

final class DatabaseManager: Sendable {
    private let dbQueue: DatabaseQueue

    init(inMemory: Bool = false) throws {
        if inMemory {
            dbQueue = try DatabaseQueue()
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbDir = appSupport.appendingPathComponent("Cracked", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            let dbPath = dbDir.appendingPathComponent("cracked.sqlite").path
            dbQueue = try DatabaseQueue(path: dbPath)
        }
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "snapshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull()
                t.column("loadAvg", .double).notNull()
                t.column("totalProcesses", .integer).notNull()
                t.column("memoryUsedMB", .integer).notNull()
                t.column("memoryTotalMB", .integer).notNull()
            }

            try db.create(table: "process_snaps") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("snapshotId", .integer).notNull().references("snapshots", onDelete: .cascade)
                t.column("pid", .integer).notNull()
                t.column("appName", .text).notNull()
                t.column("cpuPercent", .double).notNull()
                t.column("memoryMB", .integer).notNull()
                t.column("uptimeSeconds", .integer).notNull()
            }

            try db.create(table: "records") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("recordType", .text).notNull()
                t.column("value", .double).notNull()
                t.column("appName", .text)
                t.column("achievedAt", .double).notNull()
                t.column("details", .text)
            }

            try db.create(table: "app_configs") { t in
                t.column("appName", .text).primaryKey()
                t.column("cpuThreshold", .double)
                t.column("stalenessDays", .integer)
                t.column("autoKill", .integer).notNull().defaults(to: 0)
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Snapshots

    func saveSnapshot(_ snapshot: SystemSnapshot) throws {
        try dbQueue.write { db in
            var record = SnapshotRecord(
                timestamp: snapshot.timestamp.timeIntervalSince1970,
                loadAvg: snapshot.loadAverage,
                totalProcesses: snapshot.totalProcesses,
                memoryUsedMB: snapshot.memoryUsedMB,
                memoryTotalMB: snapshot.memoryTotalMB
            )
            try record.insert(db)

            guard let snapshotId = record.id else { return }

            for process in snapshot.processes where process.cpuPercent > 5.0 {
                var processRecord = ProcessSnapRecord(
                    snapshotId: snapshotId,
                    pid: process.pid,
                    appName: process.name,
                    cpuPercent: process.cpuPercent,
                    memoryMB: process.memoryMB,
                    uptimeSeconds: process.uptimeSeconds
                )
                try processRecord.insert(db)
            }
        }
    }

    func snapshotCount() throws -> Int {
        try dbQueue.read { db in
            try SnapshotRecord.fetchCount(db)
        }
    }

    // MARK: - Records

    func saveRecord(type: String, value: Double, appName: String? = nil, details: String? = nil) throws {
        try dbQueue.write { db in
            var record = RecordEntry(
                recordType: type,
                value: value,
                appName: appName,
                achievedAt: Date().timeIntervalSince1970,
                details: details
            )
            try record.insert(db)
        }
    }

    func allRecords() throws -> [RecordEntry] {
        try dbQueue.read { db in
            try RecordEntry.order(Column("achievedAt").desc).fetchAll(db)
        }
    }

    func currentRecord(type: String, appName: String? = nil) throws -> RecordEntry? {
        try dbQueue.read { db in
            var request = RecordEntry.filter(Column("recordType") == type)
            if let appName {
                request = request.filter(Column("appName") == appName)
            }
            return try request.order(Column("value").desc).fetchOne(db)
        }
    }

    // MARK: - App configs

    func saveAppConfig(_ config: AppConfigRecord) throws {
        try dbQueue.write { db in
            try config.save(db)
        }
    }

    func appConfig(for appName: String) throws -> AppConfigRecord? {
        try dbQueue.read { db in
            try AppConfigRecord.fetchOne(db, key: appName)
        }
    }

    func allAppConfigs() throws -> [AppConfigRecord] {
        try dbQueue.read { db in
            try AppConfigRecord.fetchAll(db)
        }
    }

    // MARK: - Downsampling

    /// Downsample old snapshots: keep per-minute for 24h, per-hour for 30d, daily after that.
    func downsample() throws {
        try dbQueue.write { db in
            let now = Date().timeIntervalSince1970

            // Delete raw process_snaps older than 24 hours
            let oneDayAgo = now - 86400
            try db.execute(sql: """
                DELETE FROM process_snaps
                WHERE snapshotId IN (SELECT id FROM snapshots WHERE timestamp < ?)
                """, arguments: [oneDayAgo])

            // For data between 1-30 days old: keep one snapshot per hour
            let thirtyDaysAgo = now - (30 * 86400)
            try db.execute(sql: """
                DELETE FROM snapshots
                WHERE timestamp < ? AND timestamp > ?
                AND id NOT IN (
                    SELECT MIN(id) FROM snapshots
                    WHERE timestamp < ? AND timestamp > ?
                    GROUP BY CAST(timestamp / 3600 AS INTEGER)
                )
                """, arguments: [oneDayAgo, thirtyDaysAgo, oneDayAgo, thirtyDaysAgo])

            // For data older than 30 days: keep one snapshot per day
            try db.execute(sql: """
                DELETE FROM snapshots
                WHERE timestamp < ?
                AND id NOT IN (
                    SELECT MIN(id) FROM snapshots
                    WHERE timestamp < ?
                    GROUP BY CAST(timestamp / 86400 AS INTEGER)
                )
                """, arguments: [thirtyDaysAgo, thirtyDaysAgo])
        }
    }

    // MARK: - Trend queries

    func recentSnapshots(hours: Int = 24) throws -> [SnapshotRecord] {
        let cutoff = Date().timeIntervalSince1970 - Double(hours * 3600)
        return try dbQueue.read { db in
            try SnapshotRecord
                .filter(Column("timestamp") > cutoff)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Hall of shame

    struct ShameEntry: FetchableRecord, Decodable {
        var appName: String
        var totalCpuPercent: Double
        var sampleCount: Int
    }

    func hallOfShame(limit: Int = 5) throws -> [ShameEntry] {
        try dbQueue.read { db in
            let sql = """
                SELECT appName,
                       SUM(cpuPercent) as totalCpuPercent,
                       COUNT(*) as sampleCount
                FROM process_snaps
                GROUP BY appName
                ORDER BY totalCpuPercent DESC
                LIMIT ?
                """
            return try ShameEntry.fetchAll(db, sql: sql, arguments: [limit])
        }
    }
}
