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

    init(db: DatabaseManager?) {
        self.db = db
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
