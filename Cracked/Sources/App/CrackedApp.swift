import SwiftUI

struct CrackedApp: App {
    @StateObject private var viewModel = MenuBarViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            Image(systemName: viewModel.iconState.systemImage)
                .symbolRenderingMode(.palette)
                .foregroundStyle(viewModel.iconState.color)
        }
        .menuBarExtraStyle(.window)

        Window("Records & Stats", id: "stats") {
            StatsWindowContent(menuBarViewModel: viewModel)
        }

        // A regular window rather than a `Settings` scene: menu bar-only apps can't
        // reliably open the Settings scene (the old `showSettingsWindow:` action
        // is a no-op on macOS 14+), but `openWindow` works like Records & Stats.
        Window("Cracked Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}
