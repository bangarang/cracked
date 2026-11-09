import Testing
@testable import Cracked

@Suite("ProcessMonitor")
struct ProcessMonitorTests {

    @Test("Parses ps output into ProcessSnapshots")
    func parsePsOutput() {
        let psOutput = """
          501 99882     1   0.5  88320  01:23 Comet Helper (Renderer)
          501 24711     1 114.4 517472 1-02:15:30 Comet Helper (Renderer)
          501   786     1  23.4 1084320 22-06:39:00 Warp
        """
        let processes = ProcessMonitor.parsePsOutput(psOutput)

        #expect(processes.count == 3)

        #expect(processes[0].pid == 99882)
        #expect(processes[0].name == "Comet Helper (Renderer)")
        #expect(processes[0].cpuPercent == 0.5)
        #expect(processes[0].memoryMB == 86)  // 88320 KB / 1024
        #expect(processes[0].uptimeSeconds == 83)  // 1*60 + 23

        #expect(processes[1].pid == 24711)
        #expect(processes[1].cpuPercent == 114.4)
        #expect(processes[1].uptimeSeconds == 94530)  // 1*86400 + 2*3600 + 15*60 + 30

        #expect(processes[2].pid == 786)
        #expect(processes[2].name == "Warp")
        #expect(processes[2].uptimeSeconds == 1_924_740)  // 22*86400 + 6*3600 + 39*60
    }

    @Test("Parses etime format dd-HH:MM:SS")
    func parseEtimeFull() {
        #expect(ProcessMonitor.parseEtime("1-02:15:30") == 94530)
    }

    @Test("Parses etime format HH:MM:SS")
    func parseEtimeHours() {
        #expect(ProcessMonitor.parseEtime("02:15:30") == 8130)
    }

    @Test("Parses etime format MM:SS")
    func parseEtimeMinutes() {
        #expect(ProcessMonitor.parseEtime("15:30") == 930)
    }

    @Test("Parses load average from sysctl output")
    func parseLoadAvg() {
        let output = "{ 46.99 26.33 15.46 }"
        #expect(ProcessMonitor.parseLoadAverage(output) == 46.99)
    }

    @Test("Stale apps only include apps the user launched, not bundle extensions")
    func staleAppsIgnoreExtensions() {
        let day = 86400
        func proc(_ pid: Int32, _ name: String, uptime: Int, cpu: Double = 0) -> ProcessSnapshot {
            ProcessSnapshot(id: pid, pid: pid, ppid: 1, uid: 501, name: name,
                            cpuPercent: cpu, memoryMB: 100, uptimeSeconds: uptime)
        }
        let processes = [
            proc(10, "/System/Applications/News.app/Contents/PlugIns/NewsToday2.appex/Contents/MacOS/NewsToday2", uptime: 20 * day),
            proc(11, "/System/Applications/Home.app/Contents/PlugIns/HomeWidget.appex/Contents/MacOS/HomeWidget", uptime: 20 * day),
            proc(20, "/Applications/Warp.app/Contents/MacOS/Warp", uptime: 22 * day),
            proc(21, "/Applications/Spotify.app/Contents/MacOS/Spotify", uptime: 9 * day),
            proc(22, "/Applications/Comet.app/Contents/MacOS/Comet", uptime: 30 * day, cpu: 150),
            proc(23, "/Applications/Cursor.app/Contents/MacOS/Cursor", uptime: 2 * day),
        ]
        let stale = MenuBarViewModel.staleApps(
            from: processes,
            launchedAppPIDs: [20, 21, 22, 23],
            stalenessThresholdSeconds: 7 * day,
            cpuThreshold: 80
        )
        #expect(stale.map(\.displayName) == ["Warp", "Spotify"])
    }
}
