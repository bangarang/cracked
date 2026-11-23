import SwiftUI
import AppKit

struct CrackedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = MenuBarViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            Image(systemName: viewModel.iconState.systemImage)
                .symbolRenderingMode(.palette)
                .foregroundStyle(viewModel.iconState.color)
            // Agents waiting on you, on this Mac and paired Macs
            if viewModel.agentsWaitingCount > 0 {
                Text("\(viewModel.agentsWaitingCount)")
            }
        }
        .menuBarExtraStyle(.window)

        Window("Records & Stats", id: "stats") {
            StatsWindowContent(menuBarViewModel: viewModel)
        }

        // A regular window rather than a `Settings` scene: menu bar-only apps can't
        // reliably open the Settings scene (the old `showSettingsWindow:` action
        // is a no-op on macOS 14+), but `openWindow` works like Records & Stats.
        Window("Cracked Settings", id: "settings") {
            SettingsView(fleet: viewModel.fleet)
        }
        .windowResizability(.contentSize)

        Window("Share", id: "share") {
            ShareWindowView(menuBarViewModel: viewModel)
        }
        .windowResizability(.contentSize)
    }
}

/// Opening Cracked again while it's running (from Finder, Spotlight or `open`) shows
/// Settings, so it's reachable even when the menu bar icon is hidden behind the notch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let open = ShareCenter.shared.openWindow {
                open("settings")
            } else {
                Self.showSettingsFallback()
            }
        }
        return false
    }

    /// Before the menu bar label has appeared there's no SwiftUI `openWindow`, so host Settings directly.
    @MainActor private static var fallbackWindow: NSWindow?

    @MainActor private static func showSettingsFallback() {
        guard let fleet = MenuBarViewModel.shared?.fleet else { return }
        if fallbackWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(fleet: fleet)))
            window.title = "Cracked Settings"
            window.isReleasedWhenClosed = false
            fallbackWindow = window
        }
        fallbackWindow?.center()
        fallbackWindow?.makeKeyAndOrderFront(nil)
    }
}
