import SwiftUI

struct ProcessRowView: View {
    let process: ProcessSnapshot
    let actionLabel: String
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
            }
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
}
