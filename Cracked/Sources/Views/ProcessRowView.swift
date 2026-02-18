import SwiftUI
import AppKit

struct ProcessRowView: View {
    let process: ProcessSnapshot
    let actionLabel: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            Text(process.displayName)
                .font(.system(.body))
                .lineLimit(1)
            Spacer()
            if process.cpuPercent >= 1.0 {
                Text(String(format: "%.0f%%", process.cpuPercent))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(process.cpuPercent >= 100 ? .red : .secondary)
            }
            if process.uptimeSeconds >= 86400 {
                Text(process.uptimeFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(actionLabel) {
                action()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var appIcon: NSImage? {
        guard let path = process.appBundlePath else { return nil }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }
}
