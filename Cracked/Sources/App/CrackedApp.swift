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

        Settings {
            SettingsView()
        }
    }
}
