import SwiftUI
import Charts
import AppKit

/// Wrapper that owns the StatsViewModel lifecycle so it survives SwiftUI re-renders.
struct StatsWindowContent: View {
    @ObservedObject var menuBarViewModel: MenuBarViewModel
    @StateObject private var statsViewModel: StatsViewModel

    init(menuBarViewModel: MenuBarViewModel) {
        self.menuBarViewModel = menuBarViewModel
        // StateObject init only runs once, so db is captured stably
        _statsViewModel = StateObject(wrappedValue: StatsViewModel(db: menuBarViewModel.db))
    }

    var body: some View {
        StatsView(viewModel: statsViewModel, menuBarViewModel: menuBarViewModel)
    }
}

struct StatsView: View {
    @ObservedObject var viewModel: StatsViewModel
    @ObservedObject var menuBarViewModel: MenuBarViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Live Stats
                liveStatsSection

                Divider()

                // Tracked Apps
                if !menuBarViewModel.trackedApps.isEmpty {
                    trackedAppsSection
                    Divider()
                }

                // App Activity (Strava-style PRs + trends)
                if !viewModel.appTrends.isEmpty {
                    appActivitySection
                    Divider()
                }

                // Load Average Trend
                trendSection(
                    title: "Load Average (24h)",
                    data: viewModel.loadTrend,
                    color: .red,
                    chartType: .line
                )

                Divider()

                // Memory Trend
                trendSection(
                    title: "Memory Usage (24h)",
                    data: viewModel.memoryTrend,
                    color: .blue,
                    chartType: .area
                )

                Divider()

                // Records
                recordsSection

                // Hall of Shame
                if !viewModel.hallOfShame.isEmpty {
                    Divider()
                    hallOfShameSection
                }
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 600)
        .onAppear { viewModel.startAutoRefresh() }
        .onDisappear { viewModel.stopAutoRefresh() }
    }

    // MARK: - Live Stats

    private var liveStatsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live System Stats")
                .font(.title2.bold())

            HStack(spacing: 20) {
                statCard(
                    label: "Load Average",
                    value: String(format: "%.1f", menuBarViewModel.loadAverage),
                    color: menuBarViewModel.loadAverage > 8 ? .red : .green
                )
                statCard(
                    label: "Memory",
                    value: String(format: "%.0f / %.0f GB", menuBarViewModel.memoryUsedGB, menuBarViewModel.memoryTotalGB),
                    color: menuBarViewModel.memoryUsedGB / max(menuBarViewModel.memoryTotalGB, 1) > 0.85 ? .orange : .green
                )
                statCard(
                    label: "Processes",
                    value: "\(menuBarViewModel.totalProcesses)",
                    color: .secondary
                )
                statCard(
                    label: "CPU Hogs",
                    value: "\(menuBarViewModel.cpuHogs.count)",
                    color: menuBarViewModel.cpuHogs.isEmpty ? .green : .red
                )
            }
        }
    }

    private func statCard(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Tracked Apps

    private var trackedAppsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tracked Apps")
                .font(.title2.bold())

            HStack(spacing: 16) {
                ForEach(menuBarViewModel.trackedApps) { app in
                    HStack(spacing: 8) {
                        if let path = app.appBundlePath,
                           FileManager.default.fileExists(atPath: path) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable()
                                .frame(width: 28, height: 28)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(app.count)")
                                .font(.title2.bold().monospacedDigit())
                            Text(app.label)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - App Activity (Strava-style)

    private static let appColors: [String: Color] = [
        "Comet": .orange,
        "Arc": .purple,
        "Chrome": .green,
        "Cursor": .cyan,
        "Claude Code": .pink,
        "Warp": .yellow,
    ]

    private var appActivitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App Activity")
                .font(.title2.bold())

            ForEach(viewModel.appTrends) { trend in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if let app = menuBarViewModel.trackedApps.first(where: { $0.name == trend.appName }),
                           let path = app.appBundlePath,
                           FileManager.default.fileExists(atPath: path) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable()
                                .frame(width: 24, height: 24)
                        }
                        Text(trend.appName)
                            .font(.headline)
                        Spacer()
                        // PR badge
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("PR")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                                Text("\(trend.peak) \(trend.label)")
                                    .font(.subheadline.bold().monospacedDigit())
                            }
                            if let date = trend.peakDate {
                                Text(date, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    if trend.points.count >= 2 {
                        let color = Self.appColors[trend.appName] ?? .accentColor
                        Chart(trend.points) { point in
                            AreaMark(
                                x: .value("Time", point.date),
                                y: .value("Count", point.value)
                            )
                            .foregroundStyle(color.opacity(0.15))
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Count", point.value)
                            )
                            .foregroundStyle(color)

                            // PR line
                            RuleMark(y: .value("PR", Double(trend.peak)))
                                .foregroundStyle(.orange.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                        .frame(height: 100)
                        .chartYScale(domain: 0...Double(max(trend.peak, 1)) * 1.2)
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                                AxisGridLine()
                                AxisValueLabel(format: .dateTime.hour())
                            }
                        }
                    } else {
                        Text("Collecting trend data...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Trend Charts

    private enum ChartType { case line, area }

    private func trendSection(title: String, data: [TrendPoint], color: Color, chartType: ChartType) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())

            if data.count < 2 {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Collecting data... (\(data.count) data points so far)")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                Chart(data) { point in
                    if chartType == .area {
                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(color.opacity(0.2))
                    }
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(color)
                }
                .frame(height: 160)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
            }
        }
    }

    // MARK: - Records

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("All-Time Records")
                .font(.title2.bold())

            if viewModel.records.isEmpty {
                Text("No records yet — keep using your Mac and records will appear here.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
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
        }
    }

    // MARK: - Hall of Shame

    private var hallOfShameSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hall of Shame")
                .font(.title2.bold())

            ForEach(
                Array(viewModel.hallOfShame.enumerated()),
                id: \.offset
            ) { index, entry in
                HStack(spacing: 8) {
                    Text("\(index + 1).")
                        .font(.headline.monospacedDigit())
                        .frame(width: 24)
                    let displayName = extractAppName(entry.appName)
                    if let bundlePath = extractBundlePath(entry.appName),
                       FileManager.default.fileExists(atPath: bundlePath) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                            .resizable()
                            .frame(width: 20, height: 20)
                    }
                    Text(displayName)
                        .font(.body)
                    Spacer()
                    Text(String(format: "%.0f%% cumulative CPU", entry.totalCpuPercent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("(\(entry.sampleCount) samples)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func extractAppName(_ fullPath: String) -> String {
        guard let range = fullPath.range(of: ".app/") ?? fullPath.range(of: ".app") else {
            return (fullPath as NSString).lastPathComponent
        }
        let appPath = String(fullPath[fullPath.startIndex..<range.lowerBound])
        return (appPath as NSString).lastPathComponent
    }

    private func extractBundlePath(_ fullPath: String) -> String? {
        guard let range = fullPath.range(of: ".app/") ?? fullPath.range(of: ".app") else {
            return nil
        }
        return String(fullPath[fullPath.startIndex...range.lowerBound]) + "app"
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
                let displayName = extractAppName(app)
                Text(displayName)
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
        case "peak_tabs": "Most Tabs"
        case "peak_windows": "Most Windows"
        case "peak_sessions": "Most Sessions"
        default: record.recordType
        }
    }

    private var formattedValue: String {
        switch record.recordType {
        case "peak_cpu": String(format: "%.0f%%", record.value)
        case "process_count": "\(Int(record.value)) processes"
        case "total_processes": "\(Int(record.value)) processes"
        case "peak_tabs": "\(Int(record.value)) tabs"
        case "peak_windows": "\(Int(record.value)) windows"
        case "peak_sessions": "\(Int(record.value)) sessions"
        default: String(format: "%.0f", record.value)
        }
    }

    private func extractAppName(_ fullPath: String) -> String {
        guard let range = fullPath.range(of: ".app/") ?? fullPath.range(of: ".app") else {
            return (fullPath as NSString).lastPathComponent
        }
        let appPath = String(fullPath[fullPath.startIndex..<range.lowerBound])
        return (appPath as NSString).lastPathComponent
    }
}
