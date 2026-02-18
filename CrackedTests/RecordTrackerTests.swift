import Testing
import Foundation
@testable import Cracked

@Suite("RecordTracker")
struct RecordTrackerTests {

    @Test("Detects new peak CPU record")
    func peakCpuRecord() throws {
        let db = try DatabaseManager(inMemory: true)
        let tracker = RecordTracker(db: db)

        let processes = [
            ProcessSnapshot(id: 1, pid: 1, name: "TestApp", cpuPercent: 200.0, memoryMB: 100, uptimeSeconds: 60)
        ]

        let newRecords = try tracker.checkForRecords(processes: processes, totalProcessCount: 10)
        #expect(newRecords.contains { $0.contains("CPU") })
    }

    @Test("Detects process count record for an app")
    func processCountRecord() throws {
        let db = try DatabaseManager(inMemory: true)
        let tracker = RecordTracker(db: db)

        // 50 processes from one app
        let processes = (0..<50).map { i in
            ProcessSnapshot(id: Int32(i), pid: Int32(i), name: "Comet", cpuPercent: 1.0, memoryMB: 100, uptimeSeconds: 60)
        }

        let newRecords = try tracker.checkForRecords(processes: processes, totalProcessCount: 50)
        #expect(newRecords.contains { $0.contains("Comet") && $0.contains("50") })
    }

    @Test("Does not re-record same value")
    func noDoubleRecord() throws {
        let db = try DatabaseManager(inMemory: true)
        let tracker = RecordTracker(db: db)

        let processes = [
            ProcessSnapshot(id: 1, pid: 1, name: "TestApp", cpuPercent: 200.0, memoryMB: 100, uptimeSeconds: 60)
        ]

        let first = try tracker.checkForRecords(processes: processes, totalProcessCount: 1)
        #expect(!first.isEmpty)

        let second = try tracker.checkForRecords(processes: processes, totalProcessCount: 1)
        #expect(second.isEmpty)
    }
}
