import SwiftUI
import AppKit

/// A "Worth a Restart" row: icon, name, why it's here (memory · uptime),
/// a Restart button, and Ignore / Snooze options.
struct StaleAppRowView: View {
    let app: StaleApp
    let onRestart: () -> Void
    let onSnooze: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if FileManager.default.fileExists(atPath: app.bundlePath) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            Text(app.displayName)
                .font(.system(.body))
                .lineLimit(1)
            Spacer()
            Text("\(app.memoryFormatted) · \(app.main.uptimeFormatted)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .help("\(app.processCount) processes using \(app.memoryFormatted), running for \(app.main.uptimeFormatted)")

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Snooze or ignore \(app.displayName)")

            Button("Restart", action: onRestart)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .contentShape(Rectangle())
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Snooze for 7 Days", action: onSnooze)
        Button("Never Suggest \(app.displayName)", action: onIgnore)
    }
}
