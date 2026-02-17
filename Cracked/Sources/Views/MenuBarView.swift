import SwiftUI

struct MenuBarView: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: viewModel.iconState.systemImage)
                    .foregroundStyle(viewModel.iconState.color)
                Text("Cracked")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // CPU Hogs
            if !viewModel.cpuHogs.isEmpty {
                sectionHeader("CPU Hogs")
                ForEach(viewModel.cpuHogs.prefix(5)) { process in
                    ProcessRowView(
                        process: process,
                        actionLabel: "Kill",
                        action: { viewModel.killProcess(process) }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }

            // Stale Apps
            if !viewModel.staleApps.isEmpty {
                sectionHeader("Stale Apps")
                ForEach(viewModel.staleApps.prefix(5)) { process in
                    ProcessRowView(
                        process: process,
                        actionLabel: "Restart",
                        action: { viewModel.restartApp(process) }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }

            // Nothing to report
            if viewModel.cpuHogs.isEmpty && viewModel.staleApps.isEmpty {
                Text("All systems nominal")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            Divider()

            // System stats footer
            HStack {
                Text(String(format: "Load: %.1f", viewModel.loadAverage))
                Spacer()
                Text(String(format: "RAM: %.0f/%.0f GB", viewModel.memoryUsedGB, viewModel.memoryTotalGB))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Menu items
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 340)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}
