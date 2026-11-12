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
            render(SettingsView(), size: NSSize(width: 460, height: 720), to: "settings.png")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
        }
        app.run()
        return 0
    }
}
#endif
