import Foundation

struct TrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct AppTrend: Identifiable {
    let id = UUID()
    let appName: String
    let label: String
    let points: [TrendPoint]
    let peak: Int
    let peakDate: Date?
}

@MainActor
final class StatsViewModel: ObservableObject {
    @Published var records: [RecordEntry] = []
    @Published var hallOfShame: [DatabaseManager.ShameEntry] = []
    @Published var loadTrend: [TrendPoint] = []
    @Published var memoryTrend: [TrendPoint] = []
    @Published var appTrends: [AppTrend] = []

    private let db: DatabaseManager?
    private var refreshTimer: Timer?

    init(db: DatabaseManager?) {
        self.db = db
    }

    func startAutoRefresh() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        guard let db else { return }

        records = (try? db.allRecords()) ?? []
        hallOfShame = (try? db.hallOfShame()) ?? []

        if let snapshots = try? db.recentSnapshots(hours: 24) {
            loadTrend = snapshots.map {
                TrendPoint(
                    date: Date(timeIntervalSince1970: $0.timestamp),
                    value: $0.loadAvg
                )
            }
            memoryTrend = snapshots.map {
                TrendPoint(
                    date: Date(timeIntervalSince1970: $0.timestamp),
                    value: Double($0.memoryUsedMB) / 1024.0
                )
            }
        }

        // Tracked app trends and PRs
        if let peaks = try? db.trackedAppPeaks() {
            appTrends = peaks.compactMap { peak in
                let points = (try? db.trackedAppTrend(appName: peak.appName, hours: 24)) ?? []
                let trendPoints = points.map {
                    TrendPoint(date: Date(timeIntervalSince1970: $0.timestamp), value: Double($0.count))
                }
                return AppTrend(
                    appName: peak.appName,
                    label: peak.label,
                    points: trendPoints,
                    peak: peak.peakCount,
                    peakDate: Date(timeIntervalSince1970: peak.achievedAt)
                )
            }
        }
    }
}
