import Testing
import Foundation
@testable import Cracked

@Suite("AlertEngine")
struct AlertEngineTests {

    @Test("Detects CPU hog above threshold")
    func cpuHogDetection() {
        let engine = AlertEngine(cpuThreshold: 80, sustainedSeconds: 0)
        let process = ProcessSnapshot(id: 1, pid: 1, name: "TestApp", cpuPercent: 90, memoryMB: 100, uptimeSeconds: 60)

        let alerts = engine.evaluate(processes: [process], loadAverage: 1.0)
        #expect(alerts.contains { $0.type == .highCPU && $0.processName == "TestApp" })
    }

    @Test("Does not alert below threshold")
    func noCpuAlert() {
        let engine = AlertEngine(cpuThreshold: 80, sustainedSeconds: 0)
        let process = ProcessSnapshot(id: 1, pid: 1, name: "TestApp", cpuPercent: 50, memoryMB: 100, uptimeSeconds: 60)

        let alerts = engine.evaluate(processes: [process], loadAverage: 1.0)
        #expect(alerts.isEmpty)
    }

    @Test("Detects stale app")
    func staleAppDetection() {
        let engine = AlertEngine(stalenessThresholdSeconds: 86400)  // 1 day
        let process = ProcessSnapshot(id: 1, pid: 1, name: "OldApp", cpuPercent: 1, memoryMB: 100, uptimeSeconds: 172800)  // 2 days

        let alerts = engine.evaluate(processes: [process], loadAverage: 1.0)
        #expect(alerts.contains { $0.type == .staleApp && $0.processName == "OldApp" })
    }

    @Test("Respects cooldown period")
    func cooldown() {
        let engine = AlertEngine(cpuThreshold: 80, sustainedSeconds: 0, cooldownSeconds: 900)
        let process = ProcessSnapshot(id: 1, pid: 1, name: "TestApp", cpuPercent: 90, memoryMB: 100, uptimeSeconds: 60)

        let alerts1 = engine.evaluate(processes: [process], loadAverage: 1.0)
        #expect(alerts1.count == 1)

        // Second evaluation should be suppressed by cooldown
        let alerts2 = engine.evaluate(processes: [process], loadAverage: 1.0)
        #expect(alerts2.isEmpty)
    }
}
