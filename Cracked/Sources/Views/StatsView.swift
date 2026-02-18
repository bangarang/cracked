import SwiftUI
import Charts

struct StatsView: View {
    @ObservedObject var viewModel: StatsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Records section
                Text("All-Time Records")
                    .font(.title2.bold())

                if viewModel.records.isEmpty {
                    Text("No records yet. Keep using your Mac!")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 12
                    ) {
                        ForEach(viewModel.records.prefix(8), id: \.id) { record in
                            RecordCard(record: record)
                        }
                    }
                }

                Divider()

                // Load average trend
                Text("Load Average (24h)")
                    .font(.title2.bold())

                if viewModel.loadTrend.isEmpty {
                    Text("Collecting data...")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(viewModel.loadTrend) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Load", point.value)
                        )
                        .foregroundStyle(.red)
                    }
                    .frame(height: 150)
                }

                Divider()

                // Memory trend
                Text("Memory Usage (24h)")
                    .font(.title2.bold())

                if viewModel.memoryTrend.isEmpty {
                    Text("Collecting data...")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(viewModel.memoryTrend) { point in
                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value("GB", point.value)
                        )
                        .foregroundStyle(.blue.opacity(0.3))
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("GB", point.value)
                        )
                        .foregroundStyle(.blue)
                    }
                    .frame(height: 150)
                }

                Divider()

                // Hall of shame
                Text("Hall of Shame")
                    .font(.title2.bold())

                if viewModel.hallOfShame.isEmpty {
                    Text("No data yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        Array(viewModel.hallOfShame.enumerated()),
                        id: \.offset
                    ) { index, entry in
                        HStack {
                            Text("\(index + 1).")
                                .font(.headline)
                                .frame(width: 24)
                            Text(entry.appName)
                                .font(.body)
                            Spacer()
                            Text(String(
                                format: "%.0f%% cumulative CPU",
                                entry.totalCpuPercent
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text("(\(entry.sampleCount) samples)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 500)
        .onAppear { viewModel.refresh() }
    }
}

struct RecordCard: View {
    let record: RecordEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recordTypeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formattedValue)
                .font(.title3.bold())
            if let app = record.appName {
                Text(app)
                    .font(.caption)
                    .lineLimit(1)
            }
            Text(
                Date(timeIntervalSince1970: record.achievedAt),
                style: .date
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var recordTypeLabel: String {
        switch record.recordType {
        case "peak_cpu": "Peak CPU"
        case "process_count": "Most Processes"
        case "total_processes": "Total System Processes"
        case "longest_uptime": "Longest Uptime"
        default: record.recordType
        }
    }

    private var formattedValue: String {
        switch record.recordType {
        case "peak_cpu": String(format: "%.0f%%", record.value)
        case "process_count": "\(Int(record.value)) processes"
        case "total_processes": "\(Int(record.value)) processes"
        case "longest_uptime": "\(Int(record.value)) days"
        default: String(format: "%.1f", record.value)
        }
    }
}
