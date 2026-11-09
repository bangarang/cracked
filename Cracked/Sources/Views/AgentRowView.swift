import SwiftUI
import AppKit

/// One Claude Code session in the menu: status dot, project, state and age.
/// Clicking brings its terminal to the front.
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
                    Spacer()
                    Text("\(statusText) · \(Self.age(of: session.updatedAt))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(session.status == .needsInput ? Color.orange : Color.secondary)
                }
                if session.status == .needsInput, let message = session.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 28)
                }
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
        case .done: .green
        case .working: .blue
        case .ready: .secondary
        }
    }

    private var statusText: String {
        switch session.status {
        case .needsInput: "needs input"
        case .done: "done"
        case .working: "working"
        case .ready: "ready"
        }
    }

    private var helpText: String {
        var text = session.cwd
        if let terminal = session.terminalName { text += "\nClick to open \(terminal)" }
        return text
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
