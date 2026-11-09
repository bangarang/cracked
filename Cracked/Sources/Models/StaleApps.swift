import Foundation

/// An app that's been running for a long time *and* is using enough memory
/// that restarting it would actually free something.
struct StaleApp: Identifiable, Sendable, Equatable {
    /// The app's main (user-launched) process.
    let main: ProcessSnapshot
    /// The app's .app bundle path, e.g. "/Applications/Comet.app".
    let bundlePath: String
    /// Memory summed across every process running from this bundle (helpers, renderers…).
    let totalMemoryMB: Int
    let processCount: Int

    var id: String { bundlePath }
    var displayName: String { main.displayName }

    /// "67 GB", "2.4 GB", "850 MB"
    var memoryFormatted: String {
        if totalMemoryMB >= 10 * 1024 {
            return String(format: "%.0f GB", Double(totalMemoryMB) / 1024)
        } else if totalMemoryMB >= 1024 {
            return String(format: "%.1f GB", Double(totalMemoryMB) / 1024)
        }
        return "\(totalMemoryMB) MB"
    }

    static func == (lhs: StaleApp, rhs: StaleApp) -> Bool {
        lhs.bundlePath == rhs.bundlePath && lhs.main.pid == rhs.main.pid
            && lhs.totalMemoryMB == rhs.totalMemoryMB && lhs.processCount == rhs.processCount
    }
}

enum StaleAppDetector {
    /// Finds apps worth restarting: launched by the user, running at least
    /// `stalenessThresholdSeconds`, and using at least `memoryThresholdMB` across
    /// all of their processes. Sorted by memory, biggest first.
    static func detect(
        processes: [ProcessSnapshot],
        launchedAppPIDs: Set<Int32>,
        stalenessThresholdSeconds: Int,
        memoryThresholdMB: Int,
        cpuThreshold: Double,
        ignoredBundlePaths: Set<String> = []
    ) -> [StaleApp] {
        // Group every process by the bundle it runs from, so helpers count toward their app.
        var memoryByBundle: [String: Int] = [:]
        var countByBundle: [String: Int] = [:]
        for process in processes {
            guard let bundle = process.appBundlePath else { continue }
            memoryByBundle[bundle, default: 0] += process.memoryMB
            countByBundle[bundle, default: 0] += 1
        }

        var seen = Set<String>()
        return processes
            .filter { launchedAppPIDs.contains($0.pid) }
            // CPU hogs already get their own section with a Kill button.
            .filter { $0.uptimeSeconds >= stalenessThresholdSeconds && $0.cpuPercent < cpuThreshold }
            .compactMap { main -> StaleApp? in
                guard let bundle = main.appBundlePath,
                      !ignoredBundlePaths.contains(bundle),
                      seen.insert(bundle).inserted else { return nil }
                let memory = memoryByBundle[bundle, default: main.memoryMB]
                guard memory >= memoryThresholdMB else { return nil }
                return StaleApp(main: main, bundlePath: bundle, totalMemoryMB: memory,
                                processCount: countByBundle[bundle, default: 1])
            }
            .sorted { $0.totalMemoryMB > $1.totalMemoryMB }
    }
}

/// Apps the user has asked Cracked to stop suggesting restarts for,
/// either forever or until a snooze expires. Persisted in UserDefaults.
struct IgnoredApps: Codable, Equatable, Sendable {
    static let defaultsKey = "staleAppIgnores"
    static let snoozeDuration: TimeInterval = 7 * 86400

    /// Bundle path → ignored until. `Date.distantFuture` means always.
    var until: [String: Date] = [:]

    func activeBundlePaths(at now: Date = Date()) -> Set<String> {
        Set(until.filter { $0.value > now }.keys)
    }

    func isForever(_ bundlePath: String) -> Bool {
        until[bundlePath] == .distantFuture
    }

    mutating func ignoreForever(_ bundlePath: String) {
        until[bundlePath] = .distantFuture
    }

    mutating func snooze(_ bundlePath: String, from now: Date = Date()) {
        until[bundlePath] = now.addingTimeInterval(Self.snoozeDuration)
    }

    mutating func remove(_ bundlePath: String) {
        until[bundlePath] = nil
    }

    /// Drops snoozes that have expired.
    mutating func prune(at now: Date = Date()) {
        until = until.filter { $0.value > now }
    }

    // MARK: Persistence

    init(until: [String: Date] = [:]) { self.until = until }

    init(data: Data) {
        self = (try? JSONDecoder().decode(IgnoredApps.self, from: data)) ?? IgnoredApps()
    }

    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func load(from defaults: UserDefaults = .standard) -> IgnoredApps {
        defaults.data(forKey: defaultsKey).map(IgnoredApps.init(data:)) ?? IgnoredApps()
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
