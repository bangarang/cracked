#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `Cracked snapshot <dir>` renders the menu and Settings
/// with live data to PNGs, for checking UI changes without clicking around.
enum DebugSnapshots {
    @MainActor
    static func run(outputDirectory: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let viewModel = MenuBarViewModel()
        var windows: [NSWindow] = []

        func render<V: View>(_ view: V, size: NSSize, to name: String) {
            let host = NSHostingView(rootView: view.background(Color(white: 0.13)).environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(white: 0.12, alpha: 1)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            windows.append(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let fitting = host.fittingSize
                if fitting.height > 0 { host.setFrameSize(NSSize(width: size.width, height: min(fitting.height, size.height))) }
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(name)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("wrote \(url.path)")
            }
        }

        // Give the monitor a moment to take its first reading.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            render(MenuBarView(viewModel: viewModel), size: NSSize(width: 340, height: 900), to: "menu.png")
            render(SettingsView(fleet: viewModel.fleet), size: NSSize(width: 460, height: 720), to: "settings.png")
            writeSampleCards(to: outputDirectory)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
        }
        app.run()
        return 0
    }

    /// Share cards with made-up numbers, for checking the card design.
    @MainActor static func writeSampleCards(to directory: String) {
        func mac(_ id: String, _ chip: String, _ cores: Int, _ gb: Int, _ form: MachineIdentity.FormFactor) -> MachineIdentity {
            MachineIdentity(id: id, name: id, model: "", chip: "Apple \(chip)", cpuCores: cores, performanceCores: cores,
                            memoryGB: gb, formFactor: form)
        }
        func stats(_ p95: Double, _ peak: Double, _ pressure: Double, tabs: Int?, agents: Int?, models: Double?, zombie: (String, Double, Double)?) -> PeriodStats {
            PeriodStats(start: .now, end: .now, samples: 100, cpuCores: 12, peakLoad: peak * 12, peakLoadPerCore: peak,
                        p95LoadPerCore: p95, pressureFraction: pressure, peakTabs: tabs, peakTabsApp: tabs == nil ? nil : "Comet",
                        peakAgents: agents, peakLocalModelGB: models, zombieApp: zombie?.0, zombieDays: zombie?.1, zombieGB: zombie?.2)
        }
        let mini = mac("mini", "M4 Pro", 12, 48, .mini)
        let max4 = mac("m4max", "M4 Max", 16, 128, .laptop)
        let max1 = mac("m1max", "M1 Max", 10, 64, .laptop)
        let week = Weeks.week(containing: .now)
        let wild = stats(2.1, 3.9, 0.4, tabs: 161, agents: 7, models: 26.7, zombie: ("Comet", 10, 65))
        let calm = stats(0.2, 0.9, 0, tabs: 23, agents: 1, models: nil, zombie: nil)
        let mid = stats(0.9, 2.2, 0.1, tabs: 70, agents: 3, models: nil, zombie: ("Slack", 22, 3))
        let record = RecordEntry(id: nil, recordType: "peak_tabs", value: 161, appName: "Comet",
                                 achievedAt: Date().timeIntervalSince1970, details: nil)
        let kinds: [(String, ShareCardKind)] = [
            ("card-now", .now(PublicStats(stats: calm, machine: mini, period: .now))),
            ("card-week", .week(PublicStats(stats: wild, machine: max4, period: .week(start: week.start)), start: week.start, end: week.end)),
            ("card-record", .record(PublicRecord(record, machine: mini))),
            ("card-fleet", .fleet([
                PublicFleetEntry(id: "a", formFactor: .mini, hardware: mini.hardwareSummary, stats: PublicStats(stats: mid, machine: mini, period: .now)),
                PublicFleetEntry(id: "b", formFactor: .laptop, hardware: max4.hardwareSummary, stats: PublicStats(stats: wild, machine: max4, period: .now)),
                PublicFleetEntry(id: "c", formFactor: .laptop, hardware: max1.hardwareSummary, stats: PublicStats(stats: calm, machine: max1, period: .now)),
            ], start: week.start, end: week.end)),
        ]
        for (name, kind) in kinds {
            for layout in ShareCardLayout.allCases {
                guard let png = CardRenderer.png(kind, layout: layout) else { continue }
                let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(layout.rawValue).png")
                try? png.write(to: url)
                print("wrote \(url.path)")
            }
        }
    }
}
#endif
