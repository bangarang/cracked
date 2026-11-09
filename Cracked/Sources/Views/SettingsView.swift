import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @AppStorage("cpuThreshold") private var cpuThreshold: Double = 80.0
    @AppStorage("stalenessThresholdDays") private var stalenessThresholdDays: Int = 7
    @AppStorage("restartMemoryThresholdGB") private var restartMemoryThresholdGB: Double = 2.0
    @AppStorage("pollIntervalSeconds") private var pollInterval: Double = 5.0
    @AppStorage("cooldownMinutes") private var cooldownMinutes: Int = 15
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage(IgnoredApps.defaultsKey) private var ignoredAppsData: Data = Data()

    private var ignoredApps: IgnoredApps { IgnoredApps(data: ignoredAppsData) }

    var body: some View {
        Form {
            Section {
                numberField("Flag apps using more than", value: $cpuThreshold, unit: "% CPU")
            } header: {
                Text("CPU Hogs")
            }

            Section {
                numberField("Running for at least", value: $stalenessThresholdDays, unit: "days")
                numberField("And using more than", value: $restartMemoryThresholdGB, unit: "GB")
            } header: {
                Text("Worth a Restart")
            } footer: {
                Text("Memory includes all of an app's helper processes, such as browser tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ignoredAppsList
            } header: {
                Text("Snoozed & Ignored Apps")
            }

            Section {
                numberField("Check every", value: $pollInterval, unit: "seconds")
                numberField("Alert cooldown", value: $cooldownMinutes, unit: "minutes")
            } header: {
                Text("Monitoring")
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            } header: {
                Text("General")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
    }

    // MARK: - Rows

    /// Label on the left; a compact right-aligned number field and its unit on the right.
    private func numberField(_ label: String, value: Binding<Int>, unit: String) -> some View {
        LabeledContent(label) {
            fieldWithUnit(TextField(label, value: value, format: .number), unit: unit)
        }
    }

    private func numberField(_ label: String, value: Binding<Double>, unit: String) -> some View {
        LabeledContent(label) {
            fieldWithUnit(TextField(label, value: value, format: .number), unit: unit)
        }
    }

    private func fieldWithUnit(_ field: TextField<Text>, unit: String) -> some View {
        HStack(spacing: 6) {
            field
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
        }
    }

    @ViewBuilder
    private var ignoredAppsList: some View {
        let entries = ignoredApps.until
            .filter { $0.value > Date() }
            .sorted { appName($0.key) < appName($1.key) }

        if entries.isEmpty {
            Text("None. Use the ··· menu or right-click an app under Worth a Restart to snooze or ignore it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(entries, id: \.key) { path, until in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(appName(path))
                    Spacer()
                    Text(until == .distantFuture
                         ? "Always"
                         : "Until \(until.formatted(date: .abbreviated, time: .omitted))")
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

    private func appName(_ bundlePath: String) -> String {
        ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
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
