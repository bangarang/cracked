import SwiftUI
import AppKit

/// One model Ollama has loaded: name, memory, when it unloads, and an Unload button.
struct LocalModelRowView: View {
    let model: LocalModel
    let unloading: Bool
    let onUnload: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let icon = Self.ollamaIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                    .font(.system(.body))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(String(format: "%.1f GB", model.sizeGB))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button(unloading ? "Unloading…" : "Unload", action: onUnload)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(unloading)
        }
        .help(helpText)
    }

    /// "mlx · unloads in 12m"
    private var detail: String {
        [model.runner, Self.unloadText(expiresAt: model.expiresAt)].compactMap { $0 }.joined(separator: " · ")
    }

    private var helpText: String {
        let gpu = model.vramBytes > 0 ? String(format: "\n%.1f GB of it wired as GPU memory", Double(model.vramBytes) / 1_073_741_824) : ""
        let context = model.contextLength.map { "\n\($0 / 1024)K context" } ?? ""
        return "\(model.name) is using \(String(format: "%.1f GB", model.sizeGB))\(gpu)\(context)\nUnload frees it now; Ollama reloads it on next use."
    }

    static func unloadText(expiresAt: Date?, now: Date = Date()) -> String {
        guard let expiresAt else { return "loaded" }
        let seconds = expiresAt.timeIntervalSince(now)
        // keep_alive -1 means "forever", which Ollama reports as a date centuries away.
        if seconds > 365 * 86400 { return "stays loaded" }
        if seconds <= 0 { return "unloading" }
        return "unloads in " + AgentRowView.age(of: now.addingTimeInterval(-seconds), now: now)
            .replacingOccurrences(of: "now", with: "<1m")
    }

    private static let ollamaIcon: NSImage? = {
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama")?.path
            ?? (FileManager.default.fileExists(atPath: "/Applications/Ollama.app") ? "/Applications/Ollama.app" : nil)
        return path.map { NSWorkspace.shared.icon(forFile: $0) }
    }()
}
