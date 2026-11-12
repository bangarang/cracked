import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @AppStorage("cpuThreshold") private var cpuThreshold: Double = CrackedSettings.defaultCPUThreshold
    @AppStorage("stalenessThresholdDays") private var stalenessThresholdDays: Int = 7
    @AppStorage("restartMemoryThresholdGB") private var restartMemoryThresholdGB: Double = 2.0
    @AppStorage("pollIntervalSeconds") private var pollInterval: Double = 5.0
    @AppStorage("cooldownMinutes") private var cooldownMinutes: Int = 15
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage(IgnoredApps.defaultsKey) private var ignoredAppsData: Data = Data()
    @AppStorage("agentNotifications") private var agentNotifications: Bool = false
    @AppStorage(SidePulseLights.enabledKey) private var sidePulseEnabled: Bool = true
    @AppStorage(SidePulseLights.brightnessKey) private var sidePulseBrightness: Int = 255
    @AppStorage(SidePulseEjectGuard.enabledKey) private var sidePulseKeepMounted: Bool = true

    @State private var hooksInstalled = ClaudeCodeSetup.areHooksInstalled
    @State private var mcpInstalled = ClaudeCodeSetup.isMCPInstalled
    @State private var mcpBusy = false
    @State private var setupError: String?
    @State private var sidePulseDevices: [SidePulseDevice] = []
    @State private var sidePulseUSBDots: [SidePulseUSB.Device] = []
    /// Mounted Dots whose firmware supports switching USB storage, with their USB side.
    @State private var sidePulseStorageDots: [String: SidePulseUSB.Device] = [:]
    @State private var firmwareReleases: [SidePulseDevice.Model: SidePulseFirmware.Release]?
    @State private var firmwareChecking = false
    @State private var firmwareBusy: String?
    @State private var firmwareMessage: String?
    @State private var firmwareToInstall: (device: SidePulseDevice, release: SidePulseFirmware.Release)?
    @State private var sidePulseServiceRunning = false

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

            claudeCodeSection
            sidePulseSection

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
        .frame(width: 460, height: 780)
        .onAppear {
            hooksInstalled = ClaudeCodeSetup.areHooksInstalled
            mcpInstalled = ClaudeCodeSetup.isMCPInstalled
            sidePulseDevices = SidePulse.discover()
            refreshSidePulseUSB()
            sidePulseServiceRunning = SidePulse.isServiceRunning()
        }
    }

    // MARK: - SidePulse

    private var sidePulseSection: some View {
        Section {
            Toggle(isOn: $sidePulseEnabled) {
                Text("Show agent status on SidePulse")
                Text("Amber when an agent needs you, cyan while working, solid when done")
            }

            LabeledContent("Brightness") {
                Slider(value: Binding(get: { Double(sidePulseBrightness) },
                                      set: { sidePulseBrightness = Int($0) }),
                       in: 10...255)
                    .frame(width: 180)
            }
            .disabled(!sidePulseEnabled)

            Toggle(isOn: $sidePulseKeepMounted) {
                Text("Keep SidePulse Pro mounted")
                Text("Stops macOS ejecting the SD card when the Mac is locked or wakes from hibernation. While on, the Pro can't be ejected from Finder; just pull it out.")
            }

            if sidePulseDevices.isEmpty && sidePulseUSBDots.isEmpty {
                Text("No SidePulse connected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sidePulseDevices) { device in
                    sidePulseRow(device)
                }
                ForEach(sidePulseUSBDots, id: \.registryID) { dot in
                    LabeledContent {
                        Button("Turn storage on") { setStorage(true, dot: dot, eject: nil) }
                            .controlSize(.small)
                            .disabled(firmwareBusy != nil)
                    } label: {
                        Text("SidePulse Dot")
                        Text("Over USB, storage off. Firmware updates need storage on.")
                    }
                }
                HStack {
                    Button(firmwareChecking ? "Checking…" : "Check for firmware updates") { checkFirmware() }
                        .disabled(firmwareChecking || firmwareBusy != nil)
                    if firmwareReleases != nil, !firmwareChecking, firmwareMessage == nil {
                        Text(sidePulseDevices.contains { update(for: $0) != nil } ? "Updates available" : "Up to date")
                            .foregroundStyle(.secondary)
                    }
                }
                if let firmwareMessage {
                    Text(firmwareMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if sidePulseServiceRunning {
                Text("SidePulse's own background service is running and drives the lights, so Cracked leaves them alone. Stop or uninstall it to let Cracked take over.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("SidePulse")
        } footer: {
            Text("Checking for firmware downloads release information from SidePulse's GitHub repository.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .alert("Update firmware?", isPresented: Binding(get: { firmwareToInstall != nil },
                                                        set: { if !$0 { firmwareToInstall = nil } }),
               presenting: firmwareToInstall) { pending in
            Button("Update") { install(pending.release, on: pending.device) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("\(pending.device.model.rawValue) \(pending.device.serial) will get firmware \(pending.release.version). Keep it connected while it updates and restarts.")
        }
    }

    private func sidePulseRow(_ device: SidePulseDevice) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if firmwareBusy == device.id {
                    ProgressView().controlSize(.small)
                } else if let release = update(for: device) {
                    Button("Update to \(release.version)") { firmwareToInstall = (device, release) }
                        .controlSize(.small)
                        .disabled(firmwareBusy != nil)
                }
                if let dot = sidePulseStorageDots[device.id] {
                    Button("Turn storage off") { setStorage(false, dot: dot, eject: device.root) }
                        .controlSize(.small)
                        .disabled(firmwareBusy != nil)
                }
            }
        } label: {
            Text(device.model.rawValue)
            Text([device.serial, device.version.map { "firmware \($0)" }].compactMap { $0 }.joined(separator: " · "))
        }
    }

    /// A newer release for this device, once checked.
    private func update(for device: SidePulseDevice) -> SidePulseFirmware.Release? {
        guard let release = firmwareReleases?[device.model],
              let installed = device.version.flatMap(SidePulseFirmware.Version.init),
              release.version > installed else { return nil }
        return release
    }

    private func refreshSidePulseUSB() {
        sidePulseUSBDots = SidePulseUSB.unmountedDots(mounted: sidePulseDevices)
        var storage: [String: SidePulseUSB.Device] = [:]
        for device in sidePulseDevices where device.model == .dot {
            // Only firmware that reports its storage setting can switch it.
            if let id = SidePulseUSB.usbDeviceID(forVolume: device.root),
               SidePulseUSB.storageStatus(SidePulseUSB.Device(registryID: id)) != nil {
                storage[device.id] = SidePulseUSB.Device(registryID: id)
            }
        }
        sidePulseStorageDots = storage
    }

    private func checkFirmware() {
        firmwareChecking = true
        firmwareMessage = nil
        Task {
            do {
                firmwareReleases = try await SidePulseFirmware.latest()
            } catch {
                firmwareMessage = error.localizedDescription
            }
            firmwareChecking = false
        }
    }

    private func install(_ release: SidePulseFirmware.Release, on device: SidePulseDevice) {
        firmwareBusy = device.id
        firmwareMessage = "Downloading and checking firmware \(release.version)…"
        // Hold the lights so nothing else is written to the device meanwhile.
        SidePulseLights.pausedUntil = Date().addingTimeInterval(300)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            do {
                try await SidePulseFirmware.install(release, on: device)
                firmwareMessage = "Firmware \(release.version) sent. Leave the \(device.model.rawValue) connected for 10 seconds while it updates and restarts, then unplug it and plug it back in."
            } catch {
                firmwareMessage = error.localizedDescription
            }
            SidePulseLights.pausedUntil = Date().addingTimeInterval(SidePulseFirmware.applySeconds + 5)
            firmwareBusy = nil
        }
    }

    private func setStorage(_ on: Bool, dot: SidePulseUSB.Device, eject root: URL?) {
        firmwareBusy = "storage"
        firmwareMessage = on ? "Turning storage on…" : "Turning storage off…"
        Task.detached {
            if let root {
                let eject = Process()
                eject.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                eject.arguments = ["eject", root.path]
                try? eject.run()
                eject.waitUntilExit()
            }
            let done = SidePulseUSB.setStorage(on, device: dot)
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                firmwareMessage = done ? nil : "The Dot didn't accept the storage change."
                firmwareBusy = nil
                sidePulseDevices = SidePulse.discover()
                refreshSidePulseUSB()
            }
        }
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

    private var claudeCodeSection: some View {
        Section {
            LabeledContent {
                if hooksInstalled {
                    connectedControls { perform { try ClaudeCodeSetup.uninstallHooks() } }
                } else {
                    Button("Connect") { perform { try ClaudeCodeSetup.installHooks() } }
                        .controlSize(.small)
                }
            } label: {
                Text("Agent inbox")
                Text("Shows each session's status under Agents")
            }

            LabeledContent {
                if mcpBusy {
                    ProgressView().controlSize(.small)
                } else if mcpInstalled {
                    connectedControls { setMCP(installed: false) }
                } else {
                    Button("Connect") { setMCP(installed: true) }
                        .controlSize(.small)
                }
            } label: {
                Text("MCP server")
                Text("Lets agents check this Mac before heavy work")
            }

            LabeledContent {
                if paseoDetected {
                    Label("Detected", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                } else {
                    Text("Not found").foregroundStyle(.secondary)
                }
            } label: {
                Text("Paseo")
                Text("Paseo agents show up under Agents automatically")
            }

            Toggle(isOn: $agentNotifications) {
                Text("Notify me when an agent is done")
                Text("Or when it's blocked waiting for you")
            }
            .onChange(of: agentNotifications) { _, enabled in
                if enabled { NotificationManager.shared.requestPermission() }
            }

            if let setupError {
                Text(setupError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Agents")
        } footer: {
            Text("Hook and MCP changes apply to new Claude Code sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var paseoDetected: Bool {
        FileManager.default.fileExists(atPath: PaseoAgents.home().appendingPathComponent("agents").path)
    }

    private func connectedControls(disconnect: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Label("Connected", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
            Button("Disconnect", action: disconnect)
                .controlSize(.small)
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            setupError = nil
        } catch {
            setupError = error.localizedDescription
        }
        hooksInstalled = ClaudeCodeSetup.areHooksInstalled
    }

    /// The claude CLI takes a moment, so run it off the main thread.
    private func setMCP(installed: Bool) {
        mcpBusy = true
        Task.detached {
            var message: String?
            do {
                if installed { try ClaudeCodeSetup.installMCP() } else { try ClaudeCodeSetup.uninstallMCP() }
            } catch {
                message = error.localizedDescription
            }
            let nowInstalled = ClaudeCodeSetup.isMCPInstalled
            await MainActor.run {
                setupError = message
                mcpInstalled = nowInstalled
                mcpBusy = false
            }
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
