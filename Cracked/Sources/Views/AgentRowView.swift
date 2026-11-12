import SwiftUI
import AppKit

/// One agent in the menu: status dot, project, where it lives (Paseo, Ghostty…), state
/// and age, plus what it's blocked on or working on. Clicking opens it in Paseo or
/// focuses its terminal tab.
struct AgentRowView: View {
    let session: AgentSession
    let onFocus: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onFocus) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .frame(width: 20)
                    Text(session.projectName)
                        .font(.system(.body))
                        .lineLimit(1)
                    if let icon = Self.hostIcon(for: session) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 14, height: 14)
                            .help(hostName ?? "")
                    }
                    Spacer()
                    Text("\(statusText) · \(Self.age(of: session.updatedAt))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(statusTextColor)
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
        .help(helpText)
    }

    private var statusColor: Color {
        switch session.status {
        case .needsInput: .orange
        case .error: .red
        case .done: .green
        case .working: .blue
        case .running: .blue.opacity(0.5)
        case .ready: .secondary
        }
    }

    private var statusText: String {
        switch session.status {
        case .needsInput: "needs input"
        case .error: "error"
        case .done: "done"
        case .working: "working"
        case .running: "running"
        case .ready: "idle"
        }
    }

    private var statusTextColor: Color {
        switch session.status {
        case .needsInput: .orange
        case .error: .red
        default: .secondary
        }
    }

    /// "Paseo", "Ghostty"…
    private var hostName: String? {
        session.source == .paseo ? "Paseo" : session.terminalName
    }

    /// What it's blocked on, else what it's working on, else what it is and where.
    private var detail: String {
        if session.status == .needsInput || session.status == .error, let message = session.message {
            return message
        }
        if let title = session.title { return title }
        let agent = session.provider == "opencode" ? "OpenCode" : "Claude Code"
        return hostName.map { "\(agent) in \($0)" } ?? agent
    }

    private var helpText: String {
        var text = session.cwd
        if let title = session.title { text = "\(title)\n\(text)" }
        if session.source == .paseo {
            text += "\n\(session.agentName) via Paseo · click to open in Paseo"
        } else if let terminal = session.terminalName {
            text += "\nClick to open \(terminal)"
        }
        return text
    }

    private static let paseoAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "sh.paseo.desktop")

    static func hostIcon(for session: AgentSession) -> NSImage? {
        let path = session.source == .paseo ? paseoAppURL?.path : session.terminalBundlePath
        return path.map { NSWorkspace.shared.icon(forFile: $0) }
    }

    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}
