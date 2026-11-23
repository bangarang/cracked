import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Card content (public data only)

/// A record, reduced to what's safe to post.
struct PublicRecord: Equatable, Sendable {
    let label: String
    let value: String
    let app: String?
    let detail: String?
    let date: Date
    let chipClass: String

    init(_ record: RecordEntry, machine: MachineIdentity) {
        label = RecordFormatting.label(record.recordType)
        value = RecordFormatting.value(record)
        chipClass = machine.chipClass
        date = Date(timeIntervalSince1970: record.achievedAt)
        if record.recordType == "zombie_score", let details = record.details {
            // "Comet · 65 GB · 10d": keep the numbers, filter the app name.
            var parts = details.components(separatedBy: " · ")
            let name = parts.isEmpty ? nil : PublicAppNames.sanitize(parts.removeFirst())
            app = name
            detail = parts.joined(separator: " · ")
        } else {
            app = record.appName.map { PublicAppNames.sanitize(RecordFormatting.appName($0)) }
            detail = nil
        }
    }
}

/// One Mac on a fleet card: hardware, not its name ("Alex's MacBook Pro" stays private).
struct PublicFleetEntry: Equatable, Sendable, Identifiable {
    let id: String
    let formFactor: MachineIdentity.FormFactor
    let hardware: String
    let stats: PublicStats
}

enum ShareCardKind: Equatable, Sendable {
    case record(PublicRecord)
    case now(PublicStats)
    case week(PublicStats, start: Date, end: Date)
    case fleet([PublicFleetEntry], start: Date, end: Date)
}

enum ShareCardLayout: String, CaseIterable, Identifiable, Sendable {
    case landscape, portrait
    var id: String { rawValue }
    var size: CGSize { self == .landscape ? CGSize(width: 1200, height: 630) : CGSize(width: 1080, height: 1350) }
    var title: String { self == .landscape ? "Wide (links, X)" : "Tall (Instagram)" }
}

/// How cooked: picks the gauge, colour and whether the glass is shattered.
enum CardMood: Sendable {
    case chill, toasty, cooking, cracked

    init(score: Int) {
        switch score {
        case ..<150: self = .chill
        case ..<350: self = .toasty
        case ..<550: self = .cooking
        default: self = .cracked
        }
    }

    var color: Color {
        switch self {
        case .chill: Color(white: 0.92)
        case .toasty: .yellow
        case .cooking: .orange
        case .cracked: Color(red: 1, green: 0.23, blue: 0.19)
        }
    }

    var gauge: String {
        switch self {
        case .chill: "gauge.low"
        case .toasty: "gauge.medium"
        case .cooking, .cracked: "gauge.high"
        }
    }
}

// MARK: - Card view

/// A share card. Takes only public types, so nothing private can end up in an image.
struct ShareCardView: View {
    let kind: ShareCardKind
    let layout: ShareCardLayout

    private var mood: CardMood {
        switch kind {
        case .record: .cracked
        case .now(let stats), .week(let stats, _, _): CardMood(score: stats.crackedScore)
        case .fleet(let entries, _, _): CardMood(score: entries.map(\.stats.crackedScore).max() ?? 0)
        }
    }

    private var scale: CGFloat { layout == .landscape ? 1 : 1.1 }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.06), mood.color.opacity(0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if mood == .cracked {
                // Fade the cracks out toward the text on the left so they never strike through it.
                ShatterOverlay(seed: seedValue)
                    .opacity(0.55)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black, location: 0.8)],
                                         startPoint: .leading, endPoint: .trailing))
            }
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 24)
                content
                Spacer(minLength: 24)
                footer
            }
            .padding(56 * scale)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var seedValue: Int {
        switch kind {
        case .record(let record): Int(record.date.timeIntervalSince1970)
        case .now(let stats): stats.crackedScore
        case .week(_, let start, _), .fleet(_, let start, _): Int(start.timeIntervalSince1970)
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: mood.gauge)
                .font(.system(size: 44 * scale, weight: .semibold))
                .foregroundStyle(mood.color)
            Text(headerTitle)
                .font(.system(size: 30 * scale, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            if case .record = kind {
                Text("NEW PR")
                    .font(.system(size: 24 * scale, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Capsule().fill(.orange))
            }
        }
    }

    private var headerTitle: String {
        switch kind {
        case .record: "Personal record"
        case .now: "Right now"
        case .week(_, let start, let end): "Week of " + Self.range(start, end)
        case .fleet(_, let start, let end): "The fleet · " + Self.range(start, end)
        }
    }

    private var footer: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("cracked")
                .font(.system(size: 34 * scale, weight: .black, design: .rounded))
                .foregroundStyle(mood.color)
            Text("a menu bar app for Macs that are absolutely cooking")
                .font(.system(size: 18 * scale, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(footerDetail)
                .font(.system(size: 20 * scale, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var footerDetail: String {
        switch kind {
        case .record(let record): "\(record.chipClass) · \(record.date.formatted(date: .abbreviated, time: .omitted))"
        case .now(let stats), .week(let stats, _, _): "\(stats.chipClass) · \(stats.memoryGB) GB · \(stats.cpuCores) cores"
        case .fleet(let entries, _, _): "\(entries.count) Macs"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .record(let record): recordContent(record)
        case .now(let stats), .week(let stats, _, _): statsContent(stats)
        case .fleet(let entries, _, _): fleetContent(entries)
        }
    }

    private func recordContent(_ record: PublicRecord) -> some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            Text(record.label.uppercased())
                .font(.system(size: 26 * scale, weight: .bold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.6))
            Text(record.value)
                .font(.system(size: 150 * scale, weight: .black, design: .rounded))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .foregroundStyle(mood.color)
            if let line = [record.app, record.detail].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                Text(line)
                    .font(.system(size: 38 * scale, weight: .semibold, design: .rounded))
            }
        }
    }

    private func statsContent(_ stats: PublicStats) -> some View {
        let tiles = Self.tiles(for: stats)
        return VStack(alignment: .leading, spacing: 28 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text("\(stats.crackedScore)")
                    .font(.system(size: 130 * scale, weight: .black, design: .rounded))
                    .foregroundStyle(mood.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(stats.title)
                        .font(.system(size: 44 * scale, weight: .heavy, design: .rounded))
                    Text("cracked score")
                        .font(.system(size: 22 * scale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            let columns = layout == .landscape ? 4 : 2
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns),
                      alignment: .leading, spacing: 24 * scale) {
                ForEach(tiles.prefix(columns * 2), id: \.label) { tile in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tile.value)
                            .font(.system(size: 40 * scale, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(tile.label)
                            .font(.system(size: 20 * scale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func fleetContent(_ entries: [PublicFleetEntry]) -> some View {
        let sorted = entries.sorted { $0.stats.crackedScore > $1.stats.crackedScore }
        let rowsLayout = layout == .portrait || sorted.count > 3
        return Group {
            if rowsLayout {
                VStack(alignment: .leading, spacing: 22 * scale) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, entry in
                        fleetEntry(entry, rank: index + 1, compact: true)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, entry in
                        fleetEntry(entry, rank: index + 1, compact: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func fleetEntry(_ entry: PublicFleetEntry, rank: Int, compact: Bool) -> some View {
        let mood = CardMood(score: entry.stats.crackedScore)
        let layoutView = compact ? AnyLayout(HStackLayout(alignment: .center, spacing: 20))
                                 : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        return layoutView {
            HStack(spacing: 10) {
                Text(rank == 1 ? "👑" : "#\(rank)")
                    .font(.system(size: 30 * scale, weight: .heavy, design: .rounded))
                Image(systemName: entry.formFactor.symbol)
                    .font(.system(size: 34 * scale))
                    .foregroundStyle(mood.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.hardware)
                    .font(.system(size: 26 * scale, weight: .semibold))
                    .lineLimit(1)
                Text(Self.tiles(for: entry.stats).prefix(2).map { "\($0.value) \($0.shortLabel)" }.joined(separator: " · "))
                    .font(.system(size: 19 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            if compact { Spacer() }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(entry.stats.crackedScore)")
                    .font(.system(size: (compact ? 56 : 80) * scale, weight: .black, design: .rounded))
                    .foregroundStyle(mood.color)
                Text(entry.stats.title)
                    .font(.system(size: 20 * scale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    // MARK: Helpers

    struct Tile { let value: String; let label: String; let shortLabel: String }

    static func tiles(for stats: PublicStats) -> [Tile] {
        var tiles: [Tile] = [Tile(value: String(format: "%.1f×", stats.peakLoadPerCore),
                                  label: "peak load per core", shortLabel: "load/core")]
        if let tabs = stats.peakTabs {
            tiles.append(Tile(value: "\(tabs)", label: "tabs" + (stats.peakTabsApp.map { " in \($0)" } ?? ""), shortLabel: "tabs"))
        }
        if let agents = stats.peakAgents {
            tiles.append(Tile(value: "\(agents)", label: "agents at once", shortLabel: "agents"))
        }
        if let gb = stats.peakLocalModelGB {
            tiles.append(Tile(value: String(format: "%.0f GB", gb), label: "of local models", shortLabel: "GB models"))
        }
        if let zombie = stats.zombie {
            tiles.append(Tile(value: String(format: "%.0f GB", zombie.gb),
                              label: "\(zombie.app), up \(zombie.days) days", shortLabel: "zombie"))
        }
        return tiles
    }

    static func range(_ start: Date, _ end: Date) -> String {
        let last = end.addingTimeInterval(-1)
        return start.formatted(.dateTime.month(.abbreviated).day()) + "–" + last.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Cracks radiating from a point, drawn the same way every time for a given seed.
struct ShatterOverlay: View {
    let seed: Int

    var body: some View {
        Canvas { context, size in
            var rng = SeededRandom(seed: UInt64(truncatingIfNeeded: seed &+ 0x9E3779B9))
            let center = CGPoint(x: size.width * (0.62 + rng.next() * 0.25), y: size.height * (0.15 + rng.next() * 0.3))
            for _ in 0..<14 {
                var path = Path()
                var point = center
                path.move(to: point)
                var angle = rng.next() * 2 * .pi
                for _ in 0..<6 {
                    angle += (rng.next() - 0.5) * 0.7
                    let length = 40 + rng.next() * 120
                    point = CGPoint(x: point.x + cos(angle) * length, y: point.y + sin(angle) * length)
                    path.addLine(to: point)
                }
                context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 1.5)
            }
            for ring in 1...3 {
                let radius = CGFloat(ring) * 38
                context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                      width: radius * 2, height: radius * 2)),
                               with: .color(.white.opacity(0.12)), lineWidth: 1)
            }
        }
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    /// 0..<1
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}

// MARK: - Rendering and sharing

/// A rendered card as PNG data, shareable with `ShareLink`.
struct CardImage: Transferable {
    let png: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.png }
            .suggestedFileName("Cracked.png")
    }
}

@MainActor
enum CardRenderer {
    static func png(_ kind: ShareCardKind, layout: ShareCardLayout) -> Data? {
        let renderer = ImageRenderer(content: ShareCardView(kind: kind, layout: layout))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func copy(_ png: Data) {
        guard let image = NSImage(data: png) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    static func save(_ png: Data, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name
        NSApplication.shared.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }
}

// MARK: - Record labels (shared with Records & Stats)

enum RecordFormatting {
    static func label(_ type: String) -> String {
        switch type {
        case "peak_cpu": "Peak CPU"
        case "process_count": "Most Processes"
        case "total_processes": "Total System Processes"
        case "peak_tabs": "Most Tabs"
        case "peak_windows": "Most Windows"
        case "peak_sessions": "Most Sessions"
        case "peak_agents": "Most Agents"
        case "peak_load_per_core": "Peak Load per Core"
        case "peak_concurrent_agents": "Most Agents at Once"
        case "peak_local_model_gb": "Most Local Model Memory"
        case "zombie_score": "Biggest Zombie App"
        default: type
        }
    }

    static func value(_ record: RecordEntry) -> String {
        switch record.recordType {
        case "peak_cpu": String(format: "%.0f%%", record.value)
        case "process_count", "total_processes": "\(Int(record.value)) processes"
        case "peak_tabs": "\(Int(record.value)) tabs"
        case "peak_windows": "\(Int(record.value)) windows"
        case "peak_sessions": "\(Int(record.value)) sessions"
        case "peak_agents", "peak_concurrent_agents": "\(Int(record.value)) agents"
        case "peak_load_per_core": String(format: "%.1f× load", record.value)
        case "peak_local_model_gb": String(format: "%.0f GB", record.value)
        case "zombie_score": String(format: "%.0f GB·days", record.value)
        default: String(format: "%.0f", record.value)
        }
    }

    /// Process paths like ".../Comet.app/Contents/..." → "Comet".
    static func appName(_ fullPath: String) -> String {
        guard let range = fullPath.range(of: ".app/") ?? fullPath.range(of: ".app") else {
            return (fullPath as NSString).lastPathComponent
        }
        return (String(fullPath[fullPath.startIndex..<range.lowerBound]) as NSString).lastPathComponent
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
