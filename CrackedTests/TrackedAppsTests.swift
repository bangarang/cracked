import Foundation
import Testing
@testable import Cracked

@Suite("Tracked apps")
struct TrackedAppsTests {
    private func proc(_ pid: Int32, _ name: String) -> ProcessSnapshot {
        ProcessSnapshot(id: pid, pid: pid, ppid: 1, uid: 501, name: name, cpuPercent: 0, memoryMB: 100, uptimeSeconds: 60)
    }

    @Test("Counts tabs with old and new Chromium renderer names, not other helpers")
    func rendererNames() {
        let base = "/Applications/Comet.app/Contents/Frameworks/Comet Framework.framework/Helpers/"
        let processes = [
            proc(1, base + "Comet Helper (Renderer).app/Contents/MacOS/Comet Helper (Renderer)"),
            proc(2, base + "Comet Helper (Aperitif Renderer).app/Contents/MacOS/Comet Helper (Aperitif Renderer)"),
            proc(3, "Comet Helper (Aperitif Renderer)"),
            proc(4, base + "Comet Helper (Aperitif).app/Contents/MacOS/Comet Helper (Aperitif)"),
            proc(5, base + "Comet Helper (GPU).app/Contents/MacOS/Comet Helper (GPU)"),
            proc(6, "/Applications/Comet.app/Contents/MacOS/Comet"),
            proc(7, "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)"),
        ]
        let tracked = MenuBarViewModel.computeTrackedApps(from: processes)
        #expect(tracked.first { $0.name == "Comet" }?.count == 3)
        #expect(tracked.first { $0.name == "Cursor" }?.count == 1)
    }

    @Test("Live: every running renderer helper on this Mac is counted")
    func live() {
        let processes = ProcessMonitor.fetchProcesses()
        let renderers = processes.filter { ($0.name as NSString).lastPathComponent.contains("Renderer)") && $0.name.contains("Comet") }
        let comet = MenuBarViewModel.computeTrackedApps(from: processes).first { $0.name == "Comet" }?.count ?? 0
        #expect(comet == renderers.count)
    }
}
