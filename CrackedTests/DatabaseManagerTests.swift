import Testing
import Foundation
@testable import Cracked

@Suite("DatabaseManager")
struct DatabaseManagerTests {

    @Test("Creates database and tables")
    func createDatabase() throws {
        let db = try DatabaseManager(inMemory: true)
        let count = try db.snapshotCount()
        #expect(count == 0)
    }

    @Test("Stores and retrieves snapshots")
    func storeSnapshot() throws {
        let db = try DatabaseManager(inMemory: true)

        let snapshot = SystemSnapshot(
            timestamp: Date(),
            loadAverage: 5.0,
            totalProcesses: 100,
            memoryUsedMB: 64000,
            memoryTotalMB: 131072,
            processes: [
                ProcessSnapshot(id: 123, pid: 123, ppid: 0, uid: 501, name: "TestApp", cpuPercent: 50.0, memoryMB: 512, uptimeSeconds: 3600)
            ]
        )

        try db.saveSnapshot(snapshot)
        let count = try db.snapshotCount()
        #expect(count == 1)
    }

    @Test("Stores and retrieves records")
    func storeRecord() throws {
        let db = try DatabaseManager(inMemory: true)

        try db.saveRecord(
            type: "peak_cpu",
            value: 114.4,
            appName: "Comet",
            details: "Comet Helper (Renderer)"
        )

        let records = try db.allRecords()
        #expect(records.count == 1)
        #expect(records[0].recordType == "peak_cpu")
        #expect(records[0].value == 114.4)
        #expect(records[0].appName == "Comet")
    }

    @Test("Saves and retrieves app configs")
    func appConfigs() throws {
        let db = try DatabaseManager(inMemory: true)

        try db.saveAppConfig(AppConfigRecord(
            appName: "Comet",
            cpuThreshold: 150.0,
            stalenessDays: 3,
            autoKill: true
        ))

        let config = try db.appConfig(for: "Comet")
        #expect(config?.cpuThreshold == 150.0)
        #expect(config?.stalenessDays == 3)
        #expect(config?.autoKill == true)
    }
}
