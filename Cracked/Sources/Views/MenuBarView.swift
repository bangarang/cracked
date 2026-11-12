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

            // Agents waiting on you: blocked, errored or finished
            if !attentionAgents.isEmpty {
                sectionHeader("Needs You")
                agentRows(attentionAgents)
            }

            // Models Ollama has loaded: the biggest, least visible memory users
            if !viewModel.localModels.isEmpty {
                HStack {
                    Text("Local Models")
                        .textCase(.uppercase)
                    Spacer()
                    Text(localModelsSummary)
                        .monospacedDigit()
                        .foregroundStyle(memoryColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                ForEach(viewModel.localModels) { model in
                    LocalModelRowView(model: model, unloading: viewModel.unloadingModels.contains(model.name)) {
                        viewModel.unloadModel(model)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }

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

            // Everything else: Paseo agents, terminal sessions and hook sessions that are busy or idle
            if !otherAgents.isEmpty {
                sectionHeader("Agents")
                agentRows(Array(otherAgents.prefix(8)))
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
                        Text(app.countText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }

            // Nothing to report
            if viewModel.cpuHogs.isEmpty && viewModel.staleApps.isEmpty && viewModel.trackedApps.isEmpty
                && viewModel.localModels.isEmpty
                && viewModel.agentSessions.isEmpty {
                Text("All systems nominal")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            Divider()

            // Footer: live stats (click for Records & Stats), Settings and Quit
            HStack(spacing: 2) {
                Button(action: openStats) {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.xyaxis.line")
                        Text("Load ") + Text(String(format: "%.1f", viewModel.loadAverage)).foregroundColor(loadColor)
                        Text("·").foregroundStyle(.tertiary)
                        Text(String(format: "RAM %.0f/%.0f GB", viewModel.memoryUsedGB, viewModel.memoryTotalGB))
                            .foregroundColor(memoryColor)
                    }
                    .monospacedDigit()
                }
                .buttonStyle(FooterButtonStyle())
                .help("Records & Stats (⌘R)")
                .keyboardShortcut("r")

                Spacer(minLength: 8)

                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(FooterButtonStyle())
                .help("Settings (⌘,)")
                .keyboardShortcut(",")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(FooterButtonStyle())
                .help("Quit Cracked (⌘Q)")
                .keyboardShortcut("q")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .frame(width: 340)
        .onAppear {
            viewModel.refreshNow()
            viewModel.markAgentsSeen()
        }
    }

    private func openStats() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "stats")
    }

    private func openSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    /// "26.7 GB · 56% of RAM"
    private var localModelsSummary: String {
        let total = viewModel.localModelsGB
        guard viewModel.memoryTotalGB > 0 else { return String(format: "%.1f GB", total) }
        return String(format: "%.1f GB · %.0f%% of RAM", total, total / viewModel.memoryTotalGB * 100)
    }

    /// Memory figures turn yellow or red with macOS's memory pressure.
    private var memoryColor: Color {
        switch viewModel.memoryPressure {
        case .normal: .secondary
        case .warning: .yellow
        case .critical: .red
        }
    }

    /// Load reads as normal text until the Mac is under pressure.
    private var loadColor: Color {
        viewModel.iconState == .normal ? .secondary : viewModel.iconState.color
    }

    /// Blocked first, then errored, finished, working, running and idle; newest first within each.
    private var sortedAgents: [AgentSession] {
        let rank: [AgentSession.Status: Int] = [.needsInput: 0, .error: 1, .done: 2, .working: 3, .running: 4, .ready: 5]
        return viewModel.agentSessions.sorted {
            (rank[$0.status]!, $1.updatedAt) < (rank[$1.status]!, $0.updatedAt)
        }
    }

    private var attentionAgents: [AgentSession] { sortedAgents.filter(\.isWaiting) }
    private var otherAgents: [AgentSession] { sortedAgents.filter { !$0.isWaiting } }

    private func agentRows(_ sessions: [AgentSession]) -> some View {
        ForEach(sessions) { session in
            AgentRowView(session: session) {
                viewModel.focusAgent(session)
            }
            .padding(.horizontal, 8)
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

/// Borderless footer control: a rounded highlight on hover and while pressed,
/// like a toolbar button.
private struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            configuration.label
                .padding(.horizontal, 7)
                .frame(minWidth: 26, minHeight: 24)
                .foregroundStyle(hovering ? .primary : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.08 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private struct Hovering<Content: View>: View {
        @ViewBuilder let content: (Bool) -> Content
        @State private var hovering = false

        var body: some View {
            content(hovering).onHover { hovering = $0 }
        }
    }
}
