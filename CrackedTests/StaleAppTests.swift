import Foundation
import Testing
@testable import Cracked

@Suite("StaleAppDetector")
struct StaleAppTests {
    let day = 86400
    let gb = 1024

    func proc(_ pid: Int32, _ name: String, uptime: Int = 20 * 86400, mb: Int = 100, cpu: Double = 0) -> ProcessSnapshot {
        ProcessSnapshot(id: pid, pid: pid, ppid: 1, uid: 501, name: name,
                        cpuPercent: cpu, memoryMB: mb, uptimeSeconds: uptime)
    }

    func detect(_ processes: [ProcessSnapshot], launched: Set<Int32>,
                ignored: Set<String> = []) -> [StaleApp] {
        StaleAppDetector.detect(
            processes: processes,
            launchedAppPIDs: launched,
            stalenessThresholdSeconds: 7 * day,
            memoryThresholdMB: 2 * gb,
            cpuThreshold: 80,
            ignoredBundlePaths: ignored
        )
    }

    @Test("Long-running but lightweight apps are not suggested")
    func lightweightAppsAreQuiet() {
        let processes = [
            proc(1, "/System/Applications/Messages.app/Contents/MacOS/Messages", mb: 700),
            proc(2, "/Applications/1Password.app/Contents/MacOS/1Password", mb: 400),
            proc(3, "/Applications/1Password.app/Contents/Frameworks/1Password Helper.app/Contents/MacOS/1Password Helper", mb: 370),
            proc(4, "/Applications/Slack.app/Contents/MacOS/Slack", mb: 620),
        ]
        #expect(detect(processes, launched: [1, 2, 4]).isEmpty)
    }

    @Test("Helper memory counts toward the app, so a bloated browser is caught")
    func helpersCountTowardTheirApp() {
        var processes = [proc(10, "/Applications/Comet.app/Contents/MacOS/Comet", mb: 500)]
        for pid in Int32(11)...Int32(30) {
            processes.append(proc(pid, "/Applications/Comet.app/Contents/Frameworks/Comet Helper (Renderer).app/Contents/MacOS/Comet Helper (Renderer)", mb: 400))
        }
        let stale = detect(processes, launched: [10])
        #expect(stale.count == 1)
        #expect(stale.first?.displayName == "Comet")
        #expect(stale.first?.totalMemoryMB == 500 + 20 * 400)
        #expect(stale.first?.processCount == 21)
        #expect(stale.first?.memoryFormatted == "8.3 GB")
    }

    @Test("Extensions and recent or busy apps are excluded; results sorted by memory")
    func filtersAndSorting() {
        let processes = [
            // Widget extension inside an app the user never opened
            proc(1, "/System/Applications/News.app/Contents/PlugIns/NewsToday2.appex/Contents/MacOS/NewsToday2", mb: 3 * gb),
            // Recently launched
            proc(2, "/Applications/Cursor.app/Contents/MacOS/Cursor", uptime: 2 * day, mb: 3 * gb),
            // CPU hog, which gets its own section
            proc(3, "/Applications/Spotify.app/Contents/MacOS/Spotify", mb: 3 * gb, cpu: 150),
            proc(4, "/Applications/Warp.app/Contents/MacOS/Warp", mb: 3 * gb),
            proc(5, "/Applications/Claude.app/Contents/MacOS/Claude", mb: 5 * gb),
        ]
        let stale = detect(processes, launched: [2, 3, 4, 5])
        #expect(stale.map(\.displayName) == ["Claude", "Warp"])
    }

    @Test("Ignored apps are skipped")
    func ignoredAppsAreSkipped() {
        let processes = [proc(1, "/Applications/Warp.app/Contents/MacOS/Warp", mb: 3 * gb)]
        #expect(detect(processes, launched: [1], ignored: ["/Applications/Warp.app"]).isEmpty)
    }
}

@Suite("IgnoredApps")
struct IgnoredAppsTests {
    @Test("Snoozes expire, ignores last forever, and both survive a round trip")
    func snoozeAndIgnore() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var ignored = IgnoredApps()
        ignored.ignoreForever("/Applications/Slack.app")
        ignored.snooze("/Applications/Warp.app", from: now)

        let restored = IgnoredApps(data: ignored.data)
        #expect(restored == ignored)
        #expect(restored.isForever("/Applications/Slack.app"))

        #expect(restored.activeBundlePaths(at: now) == ["/Applications/Slack.app", "/Applications/Warp.app"])
        let later = now.addingTimeInterval(8 * 86400)
        #expect(restored.activeBundlePaths(at: later) == ["/Applications/Slack.app"])

        var pruned = restored
        pruned.prune(at: later)
        #expect(pruned.until.keys.sorted() == ["/Applications/Slack.app"])
    }

    @Test("Corrupt data falls back to empty")
    func corruptData() {
        #expect(IgnoredApps(data: Data("nope".utf8)).until.isEmpty)
    }
}
