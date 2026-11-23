import SwiftUI
import AppKit

/// What the share window should show when it opens (set by record cards, the menu, notifications).
@MainActor
final class ShareCenter: ObservableObject {
    static let shared = ShareCenter()

    enum Choice: Hashable {
        case now, thisWeek, lastWeek, fleet
        case record(type: String, app: String?)
    }

    @Published var choice: Choice = .now
    /// Opens windows from places without a SwiftUI environment (notifications).
    var openWindow: ((String) -> Void)?

    func show(_ choice: Choice) {
        self.choice = choice
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow?("share")
    }
}

enum Weeks {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    /// Monday 00:00 to next Monday 00:00 containing `date`.
    static func week(containing date: Date) -> (start: Date, end: Date) {
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)!
        return (interval.start, interval.end)
    }

    static func lastWeek(now: Date = Date()) -> (start: Date, end: Date) {
        week(containing: week(containing: now).start.addingTimeInterval(-3600))
    }
}

struct ShareWindowView: View {
    @ObservedObject var menuBarViewModel: MenuBarViewModel
    @ObservedObject var center = ShareCenter.shared
    @State private var layout: ShareCardLayout = .landscape
    @State private var kind: ShareCardKind?
    @State private var png: Data?
    @State private var loading = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Picker("Card", selection: $center.choice) {
                    Text("Right now").tag(ShareCenter.Choice.now)
                    Text("This week").tag(ShareCenter.Choice.thisWeek)
                    Text("Last week").tag(ShareCenter.Choice.lastWeek)
                    if !menuBarViewModel.fleet.peers.isEmpty {
                        Text("The fleet").tag(ShareCenter.Choice.fleet)
                    }
                    if case .record(let type, _) = center.choice {
                        Text(RecordFormatting.label(type)).tag(center.choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("Size", selection: $layout) {
                    ForEach(ShareCardLayout.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.3))
                if let png, let image = NSImage(data: png) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(8)
                } else if loading {
                    ProgressView()
                } else {
                    Text("Not enough data yet. Cracked saves a reading every minute; check back soon.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: layout == .landscape ? 330 : 520)

            HStack {
                Text("Cards only show numbers, your Mac's chip, and names of well-known apps. Never agent titles, projects or file paths.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    if let png { CardRenderer.copy(png); copied = true }
                }
                .disabled(png == nil)
                Button("Save…") {
                    if let png { CardRenderer.save(png, name: "Cracked \(Date().formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-")).png") }
                }
                .disabled(png == nil)
                if let png {
                    ShareLink(item: CardImage(png: png), preview: SharePreview("Cracked", image: Image(nsImage: NSImage(data: png) ?? NSImage()))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 700)
        .task(id: TaskKey(choice: center.choice, layout: layout)) { await rebuild() }
    }

    private struct TaskKey: Equatable { let choice: ShareCenter.Choice; let layout: ShareCardLayout }

    private func rebuild() async {
        copied = false
        loading = true
        defer { loading = false }
        kind = await ShareCardBuilder.build(center.choice, viewModel: menuBarViewModel)
        png = kind.flatMap { CardRenderer.png($0, layout: layout) }
    }
}

/// Turns a choice into public card data, from the live report, the database and the fleet.
@MainActor
enum ShareCardBuilder {
    static func build(_ choice: ShareCenter.Choice, viewModel: MenuBarViewModel) async -> ShareCardKind? {
        let machine = viewModel.machine
        switch choice {
        case .now:
            guard let report = viewModel.latestReport else { return nil }
            return .now(PublicStats(stats: .now(report), machine: machine, period: .now))
        case .thisWeek, .lastWeek:
            let week = choice == .thisWeek ? Weeks.week(containing: Date()) : Weeks.lastWeek()
            guard let stats = try? viewModel.db?.periodStats(from: week.start, to: week.end, defaultCores: machine.cpuCores),
                  stats.samples > 0 else { return nil }
            return .week(PublicStats(stats: stats, machine: machine, period: .week(start: week.start)),
                         start: week.start, end: week.end)
        case .fleet:
            let week = Weeks.week(containing: Date())
            var entries: [PublicFleetEntry] = []
            if let stats = try? viewModel.db?.periodStats(from: week.start, to: week.end, defaultCores: machine.cpuCores) {
                entries.append(PublicFleetEntry(id: machine.id, formFactor: machine.formFactor, hardware: machine.hardwareSummary,
                                                stats: PublicStats(stats: stats, machine: machine, period: .week(start: week.start))))
            }
            let client = viewModel.fleet.client
            let peers = viewModel.fleet.peers
            let remote = await withTaskGroup(of: PublicFleetEntry?.self) { group in
                for peer in peers {
                    group.addTask {
                        guard let stats = try? await client.stats(peer, from: week.start, to: week.end) else { return nil }
                        return PublicFleetEntry(id: peer.id, formFactor: peer.machine.formFactor,
                                                hardware: peer.machine.hardwareSummary,
                                                stats: PublicStats(stats: stats, machine: peer.machine, period: .week(start: week.start)))
                    }
                }
                var results: [PublicFleetEntry] = []
                for await entry in group { if let entry { results.append(entry) } }
                return results
            }
            entries += remote
            return entries.isEmpty ? nil : .fleet(entries, start: week.start, end: week.end)
        case .record(let type, let app):
            guard let record = (try? viewModel.db?.allRecords())?.first(where: { $0.recordType == type && $0.appName == app }) else {
                return nil
            }
            return .record(PublicRecord(record, machine: machine))
        }
    }
}
