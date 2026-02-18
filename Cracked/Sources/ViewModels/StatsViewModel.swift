import Foundation

struct TrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

@MainActor
final class StatsViewModel: ObservableObject {
    @Published var records: [RecordEntry] = []
    @Published var hallOfShame: [DatabaseManager.ShameEntry] = []
    @Published var loadTrend: [TrendPoint] = []
    @Published var memoryTrend: [TrendPoint] = []

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
    }
}
