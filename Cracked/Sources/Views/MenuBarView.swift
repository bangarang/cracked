import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @Environment(\.openWindow) private var openWindow

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

            // Worth a Restart: long-running apps using a lot of memory
            if !viewModel.staleApps.isEmpty {
                sectionHeader("Worth a Restart")
                ForEach(viewModel.staleApps.prefix(5)) { app in
                    StaleAppRowView(
                        app: app,
                        onRestart: { viewModel.restartApp(app) },
                        onSnooze: { viewModel.snoozeApp(app) },
                        onIgnore: { viewModel.ignoreApp(app) }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }

            // Claude Code sessions reporting through hooks
            if !viewModel.agentSessions.isEmpty {
                sectionHeader("Agents")
                ForEach(sortedAgents.prefix(6)) { session in
                    AgentRowView(session: session) {
                        viewModel.focusAgent(session)
                    }
                    .padding(.horizontal, 8)
                }
            }

            // Tracked Apps
            if !viewModel.trackedApps.isEmpty {
                sectionHeader("Tracked Apps")
                ForEach(viewModel.trackedApps) { app in
                    HStack(spacing: 8) {
                        if let path = app.appBundlePath,
                           FileManager.default.fileExists(atPath: path) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable()
                                .frame(width: 20, height: 20)
                        }
                        Text(app.name)
                            .font(.system(.body))
                        Spacer()
                        Text("\(app.count) \(app.label)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }

            // Nothing to report
            if viewModel.cpuHogs.isEmpty && viewModel.staleApps.isEmpty && viewModel.trackedApps.isEmpty
                && viewModel.agentSessions.isEmpty {
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
            Button("Records & Stats...") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "stats")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Button("Settings...") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 340)
        .onAppear {
            viewModel.refreshNow()
            viewModel.markAgentsSeen()
        }
    }

    /// Blocked sessions first, then finished, working and idle; newest first within each.
    private var sortedAgents: [AgentSession] {
        let rank: [AgentSession.Status: Int] = [.needsInput: 0, .done: 1, .working: 2, .ready: 3]
        return viewModel.agentSessions.sorted {
            (rank[$0.status]!, $1.updatedAt) < (rank[$1.status]!, $0.updatedAt)
        }
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
