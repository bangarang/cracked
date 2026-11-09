import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @AppStorage("cpuThreshold") private var cpuThreshold: Double = 80.0
    @AppStorage("stalenessThresholdDays") private var stalenessThresholdDays: Int = 7
    @AppStorage("restartMemoryThresholdGB") private var restartMemoryThresholdGB: Double = 2.0
    @AppStorage(IgnoredApps.defaultsKey) private var ignoredAppsData: Data = Data()

    private var ignoredApps: IgnoredApps { IgnoredApps(data: ignoredAppsData) }
    @AppStorage("pollIntervalSeconds") private var pollInterval: Double = 5.0
    @AppStorage("cooldownMinutes") private var cooldownMinutes: Int = 15
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 480, height: 520)
    }

    private var generalTab: some View {
        Form {
            Section("Thresholds") {
                HStack {
                    Text("CPU alert threshold:")
                    Spacer()
                    TextField("", value: $cpuThreshold, format: .number)
                        .frame(width: 60)
                    Text("%")
                }
                HStack {
                    Text("Suggest restart after running:")
                    Spacer()
                    TextField("", value: $stalenessThresholdDays, format: .number)
                        .frame(width: 60)
                    Text("days")
                }
                HStack {
                    Text("…and using more than:")
                    Spacer()
                    TextField("", value: $restartMemoryThresholdGB, format: .number)
                        .frame(width: 60)
                    Text("GB")
                }
            }

            Section("Never Suggest Restarting") {
                let entries = ignoredApps.until
                    .filter { $0.value > Date() }
                    .sorted { ($0.key as NSString).lastPathComponent < ($1.key as NSString).lastPathComponent }
                if entries.isEmpty {
                    Text("Right-click an app under Worth a Restart to snooze or ignore it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries, id: \.key) { path, until in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
                            Spacer()
                            Text(until == .distantFuture
                                 ? "Always"
                                 : "Until \(until.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Remove") {
                                var updated = ignoredApps
                                updated.remove(path)
                                ignoredAppsData = updated.data
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section("Monitoring") {
                HStack {
                    Text("Poll interval:")
                    Spacer()
                    TextField("", value: $pollInterval, format: .number)
                        .frame(width: 60)
                    Text("seconds")
                }
                HStack {
                    Text("Alert cooldown:")
                    Spacer()
                    TextField("", value: $cooldownMinutes, format: .number)
                        .frame(width: 60)
                    Text("minutes")
                }
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }
        }
        .padding(20)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update login item: \(error)")
        }
    }
}
