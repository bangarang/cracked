import Foundation

/// What a Mac did over a stretch of time, computed from the snapshots database
/// (or from a live report for "right now"). Private: stays on your own Macs.
struct PeriodStats: Codable, Sendable, Equatable {
    var start: Date
    var end: Date
    var samples: Int
    var cpuCores: Int
    var peakLoad: Double
    var peakLoadPerCore: Double
    /// 95th percentile of load per core, so one spike doesn't define the week.
    var p95LoadPerCore: Double
    /// Share of samples where macOS reported memory pressure (warning or worse).
    var pressureFraction: Double
    var peakTabs: Int?
    var peakTabsApp: String?
    var peakAgents: Int?
    var peakLocalModelGB: Double?
    var zombieApp: String?
    var zombieDays: Double?
    var zombieGB: Double?

    var zombieScore: Double? {
        guard let days = zombieDays, let gb = zombieGB else { return nil }
        return days * gb
    }

    /// Builds stats from rows; `trackedPeak` is the biggest tab count in the period.
    static func from(snapshots: [SnapshotRecord], start: Date, end: Date, defaultCores: Int,
                     trackedPeak: (app: String, count: Int)?) -> PeriodStats {
        let perCore = snapshots.map { $0.loadAvg / Double(max($0.cpuCores ?? defaultCores, 1)) }
        let worstZombie = snapshots.filter { $0.zombieScore != nil }.max { ($0.zombieScore ?? 0) < ($1.zombieScore ?? 0) }
        let withPressure = snapshots.filter { $0.memoryPressure != nil }
        let agents = snapshots.compactMap(\.activeAgents).max()
        let modelMB = snapshots.compactMap(\.localModelMB).max()
        return PeriodStats(
            start: start, end: end,
            samples: snapshots.count,
            cpuCores: snapshots.last?.cpuCores ?? defaultCores,
            peakLoad: snapshots.map(\.loadAvg).max() ?? 0,
            peakLoadPerCore: perCore.max() ?? 0,
            p95LoadPerCore: percentile(perCore, 0.95),
            pressureFraction: withPressure.isEmpty ? 0
                : Double(withPressure.count { ($0.memoryPressure ?? 0) >= 1 }) / Double(withPressure.count),
            peakTabs: trackedPeak?.count,
            peakTabsApp: trackedPeak?.app,
            peakAgents: agents.flatMap { $0 > 0 ? $0 : nil },
            peakLocalModelGB: modelMB.flatMap { $0 > 0 ? Double($0) / 1024 : nil },
            zombieApp: worstZombie?.zombieApp,
            zombieDays: worstZombie?.zombieDays,
            zombieGB: worstZombie?.zombieGB
        )
    }

    /// A one-sample "period" from a live reading, for the Right Now card.
    static func now(_ report: SystemReport) -> PeriodStats {
        let tabs = report.trackedApps.filter { $0.label == "tabs" }.max { $0.count < $1.count }
        let zombie = report.worthARestart.max {
            Double($0.uptimeSeconds) * Double($0.memoryMB) < Double($1.uptimeSeconds) * Double($1.memoryMB)
        }
        let modelGB = report.localModelsGB
        return PeriodStats(
            start: report.timestamp, end: report.timestamp, samples: 1,
            cpuCores: report.cpuCores,
            peakLoad: report.loadAverage,
            peakLoadPerCore: report.loadPerCore,
            p95LoadPerCore: report.loadPerCore,
            pressureFraction: report.memoryPressure == .normal ? 0 : 1,
            peakTabs: tabs?.count, peakTabsApp: tabs?.name,
            peakAgents: report.activeAgentCount > 0 ? report.activeAgentCount : nil,
            peakLocalModelGB: modelGB > 0 ? modelGB : nil,
            zombieApp: zombie?.name,
            zombieDays: zombie.map { Double($0.uptimeSeconds) / 86400 },
            zombieGB: zombie.map { Double($0.memoryMB) / 1024 }
        )
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}

/// One number for how cooked a Mac was, 0–1000.
enum CrackedScore {
    /// Bump when the formula changes; the leaderboard starts a fresh board per version.
    static let version = 1

    static func compute(_ stats: PeriodStats) -> Int {
        func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
        let load = 300 * clamp(stats.p95LoadPerCore / 3)
        let pressure = 200 * clamp(stats.pressureFraction)
        let tabs = 200 * clamp(log10(1 + Double(stats.peakTabs ?? 0)) / log10(501))
        let agents = 200 * clamp(Double(stats.peakAgents ?? 0) / 20)
        let zombie = 100 * clamp((stats.zombieScore ?? 0) / 500)
        return Int((load + pressure + tabs + agents + zombie).rounded())
    }

    /// "Chill", "Toasty", "Cooking", "Cracked", "Absolutely Cracked".
    static func title(for score: Int) -> String {
        switch score {
        case ..<150: "Chill"
        case ..<350: "Toasty"
        case ..<550: "Cooking"
        case ..<800: "Cracked"
        default: "Absolutely Cracked"
        }
    }
}

/// Everything that may ever leave your own Macs: share cards and the leaderboard.
///
/// Built only from `PeriodStats` and `MachineIdentity`, with app names passed through
/// `PublicAppNames`. No agent titles, paths, window titles or process lists, by
/// construction: there is no field to put them in.
struct PublicStats: Codable, Sendable, Equatable {
    enum Period: Codable, Sendable, Equatable {
        case now
        case week(start: Date)
        case allTime
    }

    struct Zombie: Codable, Sendable, Equatable {
        /// An allowlisted app name, or "An app".
        let app: String
        let days: Int
        let gb: Double
    }

    var scoreVersion: Int = CrackedScore.version
    let chipClass: String
    let memoryGB: Int
    let cpuCores: Int
    let period: Period
    let crackedScore: Int
    let peakLoadPerCore: Double
    let peakTabs: Int?
    let peakTabsApp: String?
    let peakAgents: Int?
    let peakLocalModelGB: Double?
    let zombie: Zombie?

    init(stats: PeriodStats, machine: MachineIdentity, period: Period) {
        chipClass = machine.chipClass
        memoryGB = machine.memoryGB
        cpuCores = machine.cpuCores
        self.period = period
        crackedScore = CrackedScore.compute(stats)
        peakLoadPerCore = (stats.peakLoadPerCore * 100).rounded() / 100
        peakTabs = stats.peakTabs
        peakTabsApp = stats.peakTabsApp.map(PublicAppNames.sanitize)
        peakAgents = stats.peakAgents
        peakLocalModelGB = stats.peakLocalModelGB.map { ($0 * 10).rounded() / 10 }
        if let app = stats.zombieApp, let days = stats.zombieDays, let gb = stats.zombieGB, days >= 1 {
            zombie = Zombie(app: PublicAppNames.sanitize(app), days: Int(days), gb: (gb * 10).rounded() / 10)
        } else {
            zombie = nil
        }
    }

    var title: String { CrackedScore.title(for: crackedScore) }
}

/// App names that are fine to show publicly: well-known apps whose name says nothing
/// about you. Everything else becomes "An app".
enum PublicAppNames {
    static let allowed: Set<String> = [
        // Tracked apps
        "Comet", "Arc", "Chrome", "Google Chrome", "Cursor", "Warp", "Paseo", "Claude Code", "Claude",
        // Browsers
        "Safari", "Firefox", "Brave Browser", "Microsoft Edge", "Dia", "Orion", "Zen",
        // Dev tools
        "Xcode", "Simulator", "Visual Studio Code", "Code", "Zed", "Docker", "Docker Desktop", "OrbStack",
        "Android Studio", "IntelliJ IDEA", "PyCharm", "WebStorm", "Ghostty", "iTerm2", "Terminal", "Ollama",
        "LM Studio", "Tower", "Fork", "Postman", "Figma", "Sketch",
        // Everyday apps
        "Slack", "Discord", "Messages", "Mail", "Notes", "Music", "Spotify", "Photos", "Preview", "Finder",
        "Microsoft Teams", "Zoom", "zoom.us", "Notion", "Obsidian", "Linear", "Telegram", "WhatsApp",
        "Microsoft Word", "Microsoft Excel", "Microsoft PowerPoint", "Microsoft Outlook",
        "Final Cut Pro", "Logic Pro", "Adobe Photoshop", "Adobe Premiere Pro", "Blender",
    ]

    static func sanitize(_ name: String) -> String {
        allowed.contains(name) ? name : "An app"
    }
}
