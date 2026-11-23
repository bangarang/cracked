import SwiftUI
import AppKit

/// One paired Mac in the menu: its mood, load and RAM; click to see its hogs, models,
/// restart candidates and agents, with remote actions where that Mac allows them.
struct FleetRowView: View {
    let peer: FleetPeer
    let state: PeerState?
    @ObservedObject var fleet: FleetMonitor
    @State private var expanded = false
    @State private var hovering = false

    private var report: SystemReport? { state?.isOnline() == true ? state?.report : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: peer.machine.formFactor.symbol)
                        .foregroundStyle(moodColor)
                        .frame(width: 20)
                    Text(peer.name)
                        .lineLimit(1)
                    Spacer()
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(report == nil ? .tertiary : .secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(peer.machine.hardwareSummary + " · " + peer.address)

            if expanded {
                details
                    .padding(.leading, 32)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
            }
        }
    }

    private var moodColor: Color {
        switch report?.pressure {
        case .critical: .red
        case .warning: .yellow
        case .normal: .primary
        case nil: .secondary.opacity(0.5)
        }
    }

    /// "load 3.1/12 · 30/48 GB", or how long it's been unreachable.
    private var summary: String {
        if let report {
            return String(format: "%.1f/%d · %.0f/%.0f GB", report.loadAverage, report.cpuCores,
                          report.memoryUsedGB, report.memoryTotalGB)
        }
        if let seen = state?.lastSeen { return "seen \(AgentRowView.age(of: seen)) ago" }
        return state == nil ? "connecting…" : "offline"
    }

    @ViewBuilder
    private var details: some View {
        if let report {
            VStack(alignment: .leading, spacing: 3) {
                if !report.cpuHogs.isEmpty {
                    detailLine("flame", report.cpuHogs.prefix(3).map { "\($0.name) \(Int($0.cpuPercent))%" }.joined(separator: ", "))
                }
                ForEach(report.localModels) { model in
                    actionLine("cpu", String(format: "%@ · %.1f GB", model.name, model.sizeGB),
                               action: "Unload", key: model.name) {
                        fleet.perform("unload-model", on: peer, target: model.name)
                    }
                }
                ForEach(report.worthARestart.prefix(3), id: \.bundlePath) { app in
                    actionLine("arrow.clockwise", "\(app.name) · \(app.memory) · \(app.uptime)",
                               action: "Restart", key: app.name) {
                        fleet.perform("restart-app", on: peer, target: app.name)
                    }
                }
                let working = report.agents.filter { $0.status == "working" }.count
                if !report.agents.isEmpty {
                    detailLine("sparkles", "\(report.agents.count) agent\(report.agents.count == 1 ? "" : "s")"
                               + (working > 0 ? " · \(working) working" : ""))
                }
                if report.cpuHogs.isEmpty && report.localModels.isEmpty && report.worthARestart.isEmpty && report.agents.isEmpty {
                    detailLine("checkmark", "All systems nominal")
                }
                if let message = fleet.lastActionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text(state?.error ?? "Waiting for \(peer.name) to answer…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailLine(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 14)
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func actionLine(_ symbol: String, _ text: String, action: String, key: String,
                            perform: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 14)
            Text(text).lineLimit(1)
            Spacer()
            if fleet.busy.contains("\(peer.id)/\(key)") {
                ProgressView().controlSize(.mini)
            } else {
                Button(action, action: perform)
                    .controlSize(.mini)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// An agent on another Mac, in Needs You.
struct RemoteAgentRowView: View {
    let item: FleetAgent
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .frame(width: 20)
                    Text(item.agent.project)
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        Image(systemName: item.peer.machine.formFactor.symbol)
                        Text(item.peer.name).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(statusText) · \(AgentRowView.age(of: item.agent.updatedAt))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(item.agent.status == "needsInput" ? .orange : .secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 28)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.agent.paseoURL != nil ? "Open in Paseo" : "Running in \(item.agent.terminal ?? "a terminal") on \(item.peer.name)")
    }

    private func open() {
        if let link = item.agent.paseoURL, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    private var statusColor: Color {
        switch item.agent.status {
        case "needsInput": .orange
        case "error": .red
        case "done": .green
        default: .blue
        }
    }

    private var statusText: String {
        ["needsInput": "needs input", "error": "error", "done": "done", "working": "working",
         "running": "running", "ready": "idle"][item.agent.status] ?? item.agent.status
    }

    private var detail: String {
        if ["needsInput", "error"].contains(item.agent.status), let message = item.agent.message { return message }
        if let title = item.agent.title { return title }
        return item.agent.paseoURL != nil ? "via Paseo" : "in \(item.agent.terminal ?? "a terminal")"
    }
}
