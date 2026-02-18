import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("cpuThreshold") private var cpuThreshold: Double = 80.0
    @AppStorage("stalenessThresholdDays") private var stalenessThresholdDays: Int = 7
    @AppStorage("pollIntervalSeconds") private var pollInterval: Double = 5.0
    @AppStorage("cooldownMinutes") private var cooldownMinutes: Int = 15
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 450, height: 300)
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
                    Text("Stale app threshold:")
                    Spacer()
                    TextField("", value: $stalenessThresholdDays, format: .number)
                        .frame(width: 60)
                    Text("days")
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
