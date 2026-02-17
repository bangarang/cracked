# Cracked Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a macOS menu bar app that monitors system resources, alerts about runaway/stale processes, and tracks humorous personal records.

**Architecture:** Single-process SwiftUI app with three layers (UI, Monitor, Data). Process monitoring via `ps` shell commands parsed in Swift. Data persisted in SQLite via GRDB.swift. Menu bar via SwiftUI `MenuBarExtra`.

**Tech Stack:** Swift 6.2, SwiftUI, MenuBarExtra, GRDB.swift (SQLite), UserNotifications, Swift Charts, XcodeGen

**Prerequisites:** Xcode 26.1, macOS 13+

---

## Phase 1: Project Foundation

### Task 1: Install XcodeGen and create project structure

**Files:**
- Create: `project.yml`
- Create: `.gitignore`

**Step 1: Install XcodeGen**

Run: `brew install xcodegen`
Expected: XcodeGen installed successfully

**Step 2: Create .gitignore**

Create `.gitignore`:

```
# Xcode
*.xcodeproj/xcuserdata/
*.xcworkspace/xcuserdata/
DerivedData/
build/
*.pbxuser
*.mode1v3
*.mode2v3
*.perspectivev3
*.moved-aside
*.hmap
*.ipa
*.dSYM.zip
*.dSYM
xcuserdata/

# Swift Package Manager
.build/
.swiftpm/
Package.resolved

# macOS
.DS_Store
```

**Step 3: Create project.yml**

```yaml
name: Cracked
options:
  bundleIdPrefix: com.bangarang
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "26.1"
  minimumXcodeGenVersion: "2.0"

packages:
  GRDB:
    url: https://github.com/groue/GRDB.swift
    from: "7.0.0"

targets:
  Cracked:
    type: application
    platform: macOS
    sources:
      - Cracked/Sources
    resources:
      - Cracked/Resources
    settings:
      base:
        INFOPLIST_FILE: Cracked/Resources/Info.plist
        PRODUCT_BUNDLE_IDENTIFIER: com.bangarang.cracked
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: 1
        SWIFT_VERSION: "6.0"
        MACOSX_DEPLOYMENT_TARGET: "14.0"
    dependencies:
      - package: GRDB
    entitlements:
      path: Cracked/Resources/Cracked.entitlements
      properties:
        com.apple.security.app-sandbox: false

  CrackedTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - CrackedTests
    dependencies:
      - target: Cracked
    settings:
      base:
        SWIFT_VERSION: "6.0"
```

**Step 4: Create directory structure**

Run:
```bash
cd /Users/rock/Developer/bangarang/cracked
mkdir -p Cracked/Sources/App
mkdir -p Cracked/Sources/Models
mkdir -p Cracked/Sources/Services
mkdir -p Cracked/Sources/ViewModels
mkdir -p Cracked/Sources/Views
mkdir -p Cracked/Resources
mkdir -p CrackedTests
```

**Step 5: Commit**

```bash
git add .gitignore project.yml
git commit -m "Add XcodeGen project config and gitignore"
```

---

### Task 2: Create Info.plist, entitlements, and app entry point

**Files:**
- Create: `Cracked/Resources/Info.plist`
- Create: `Cracked/Resources/Cracked.entitlements`
- Create: `Cracked/Sources/App/CrackedApp.swift`

**Step 1: Create Info.plist**

`Cracked/Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleName</key>
    <string>Cracked</string>
    <key>CFBundleDisplayName</key>
    <string>Cracked</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
</dict>
</plist>
```

Note: `LSUIElement = true` hides the app from the Dock. Menu bar apps should not appear in the Dock.

**Step 2: Create entitlements**

`Cracked/Resources/Cracked.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
```

Note: Sandbox is off because we need to read process info and send `kill` signals. For App Store, we'd revisit this.

**Step 3: Create CrackedApp.swift**

`Cracked/Sources/App/CrackedApp.swift`:

```swift
import SwiftUI

@main
struct CrackedApp: App {
    var body: some Scene {
        MenuBarExtra("Cracked", systemImage: "gauge.medium") {
            Text("Cracked is running")
                .padding()
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
```

**Step 4: Generate Xcode project and build**

Run:
```bash
cd /Users/rock/Developer/bangarang/cracked
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme Cracked -configuration Debug build
```

Expected: Build succeeds. The app should show a gauge icon in the menu bar when run.

**Step 5: Commit**

```bash
git add Cracked/Resources/Info.plist Cracked/Resources/Cracked.entitlements Cracked/Sources/App/CrackedApp.swift
git commit -m "Add minimal menu bar app entry point"
```

---

## Phase 2: Process Monitoring

### Task 3: Create process info model

**Files:**
- Create: `Cracked/Sources/Models/ProcessInfo.swift`

**Step 1: Create ProcessInfo model**

`Cracked/Sources/Models/ProcessInfo.swift`:

```swift
import Foundation

struct ProcessSnapshot: Sendable, Identifiable {
    let id: Int32  // pid
    let pid: Int32
    let name: String
    let cpuPercent: Double
    let memoryMB: Int
    let uptimeSeconds: Int

    var uptimeFormatted: String {
        if uptimeSeconds >= 86400 {
            return "\(uptimeSeconds / 86400)d"
        } else if uptimeSeconds >= 3600 {
            return "\(uptimeSeconds / 3600)h"
        } else if uptimeSeconds >= 60 {
            return "\(uptimeSeconds / 60)m"
        }
        return "\(uptimeSeconds)s"
    }
}

struct SystemSnapshot: Sendable {
    let timestamp: Date
    let loadAverage: Double
    let totalProcesses: Int
    let memoryUsedMB: Int
    let memoryTotalMB: Int
    let processes: [ProcessSnapshot]

    var memoryUsedGB: Double {
        Double(memoryUsedMB) / 1024.0
    }

    var memoryTotalGB: Double {
        Double(memoryTotalMB) / 1024.0
    }
}
```

**Step 2: Commit**

```bash
git add Cracked/Sources/Models/ProcessInfo.swift
git commit -m "Add ProcessSnapshot and SystemSnapshot models"
```

---

### Task 4: Write ProcessMonitor tests

**Files:**
- Create: `CrackedTests/ProcessMonitorTests.swift`

**Step 1: Write the tests**

`CrackedTests/ProcessMonitorTests.swift`:

```swift
import Testing
@testable import Cracked

@Suite("ProcessMonitor")
struct ProcessMonitorTests {

    @Test("Parses ps output into ProcessSnapshots")
    func parsePsOutput() {
        let psOutput = """
          501 99882   0.5  88320  01:23 Comet Helper (Renderer)
          501 24711 114.4 517472 1-02:15:30 Comet Helper (Renderer)
          501   786  23.4 1084320 22-06:39:00 Warp
        """
        let processes = ProcessMonitor.parsePsOutput(psOutput)

        #expect(processes.count == 3)

        #expect(processes[0].pid == 99882)
        #expect(processes[0].name == "Comet Helper (Renderer)")
        #expect(processes[0].cpuPercent == 0.5)
        #expect(processes[0].memoryMB == 86)  // 88320 KB / 1024
        #expect(processes[0].uptimeSeconds == 83)  // 1*60 + 23

        #expect(processes[1].pid == 24711)
        #expect(processes[1].cpuPercent == 114.4)
        #expect(processes[1].uptimeSeconds == 94530)  // 1*86400 + 2*3600 + 15*60 + 30

        #expect(processes[2].pid == 786)
        #expect(processes[2].name == "Warp")
        #expect(processes[2].uptimeSeconds == 1_924_740)  // 22*86400 + 6*3600 + 39*60
    }

    @Test("Parses etime format dd-HH:MM:SS")
    func parseEtimeFull() {
        #expect(ProcessMonitor.parseEtime("1-02:15:30") == 94530)
    }

    @Test("Parses etime format HH:MM:SS")
    func parseEtimeHours() {
        #expect(ProcessMonitor.parseEtime("02:15:30") == 8130)
    }

    @Test("Parses etime format MM:SS")
    func parseEtimeMinutes() {
        #expect(ProcessMonitor.parseEtime("15:30") == 930)
    }

    @Test("Parses load average from sysctl output")
    func parseLoadAvg() {
        let output = "{ 46.99 26.33 15.46 }"
        #expect(ProcessMonitor.parseLoadAverage(output) == 46.99)
    }
}
```

**Step 2: Regenerate project and run tests to verify they fail**

Run:
```bash
cd /Users/rock/Developer/bangarang/cracked
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme CrackedTests -configuration Debug test -destination 'platform=macOS'
```

Expected: FAIL — `ProcessMonitor` type not found.

**Step 3: Commit**

```bash
git add CrackedTests/ProcessMonitorTests.swift
git commit -m "Add failing ProcessMonitor tests"
```

---

### Task 5: Implement ProcessMonitor

**Files:**
- Create: `Cracked/Sources/Services/ProcessMonitor.swift`

**Step 1: Implement ProcessMonitor**

`Cracked/Sources/Services/ProcessMonitor.swift`:

```swift
import Foundation

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published var latestSnapshot: SystemSnapshot?

    private var timer: Timer?
    private let pollInterval: TimeInterval

    init(pollInterval: TimeInterval = 5.0) {
        self.pollInterval = pollInterval
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let processes = Self.fetchProcesses()
        let loadAvg = Self.fetchLoadAverage()
        let (usedMB, totalMB) = Self.fetchMemory()

        latestSnapshot = SystemSnapshot(
            timestamp: Date(),
            loadAverage: loadAvg,
            totalProcesses: processes.count,
            memoryUsedMB: usedMB,
            memoryTotalMB: totalMB,
            processes: processes
        )
    }

    // MARK: - Process list

    static func fetchProcesses() -> [ProcessSnapshot] {
        let output = shell("ps", "-axo", "uid,pid,pcpu,rss,etime,comm")
        return parsePsOutput(output)
    }

    static func parsePsOutput(_ output: String) -> [ProcessSnapshot] {
        var results: [ProcessSnapshot] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("UID") { continue }

            // Split into at most 6 components: uid, pid, cpu, rss, etime, comm (may contain spaces)
            let parts = trimmed.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count >= 6 else { continue }

            guard let pid = Int32(parts[1]),
                  let cpu = Double(parts[2]),
                  let rssKB = Int(parts[3]) else { continue }

            let etime = String(parts[4])
            let comm = String(parts[5])
            let uptimeSeconds = parseEtime(etime)
            let memoryMB = rssKB / 1024

            results.append(ProcessSnapshot(
                id: pid,
                pid: pid,
                name: comm,
                cpuPercent: cpu,
                memoryMB: memoryMB,
                uptimeSeconds: uptimeSeconds
            ))
        }
        return results
    }

    // MARK: - Elapsed time parsing

    /// Parses ps etime format: [[dd-]HH:]MM:SS
    static func parseEtime(_ etime: String) -> Int {
        var days = 0
        var remainder = etime

        // Check for dd- prefix
        if let dashIndex = remainder.firstIndex(of: "-") {
            days = Int(remainder[remainder.startIndex..<dashIndex]) ?? 0
            remainder = String(remainder[remainder.index(after: dashIndex)...])
        }

        let components = remainder.split(separator: ":").compactMap { Int($0) }

        switch components.count {
        case 3: // HH:MM:SS
            return days * 86400 + components[0] * 3600 + components[1] * 60 + components[2]
        case 2: // MM:SS
            return days * 86400 + components[0] * 60 + components[1]
        case 1: // SS
            return days * 86400 + components[0]
        default:
            return 0
        }
    }

    // MARK: - Load average

    static func fetchLoadAverage() -> Double {
        let output = shell("sysctl", "-n", "vm.loadavg")
        return parseLoadAverage(output)
    }

    static func parseLoadAverage(_ output: String) -> Double {
        // Format: "{ 1.23 2.34 3.45 }"
        let cleaned = output.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespaces)
        let parts = cleaned.split(separator: " ")
        return Double(parts.first ?? "0") ?? 0
    }

    // MARK: - Memory

    static func fetchMemory() -> (usedMB: Int, totalMB: Int) {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalMB = Int(totalBytes / 1_048_576)

        // Parse vm_stat for pages free/inactive/speculative
        let output = shell("vm_stat")
        let pageSize = 16384 // macOS Apple Silicon default
        var pagesUsed = 0

        for line in output.components(separatedBy: "\n") {
            if line.contains("Pages active") || line.contains("Pages wired") || line.contains("Pages occupied by compressor") {
                let parts = line.components(separatedBy: ":")
                if let valueStr = parts.last?.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))),
                   let value = Int(valueStr) {
                    pagesUsed += value
                }
            }
        }
        let usedMB = (pagesUsed * pageSize) / 1_048_576
        return (usedMB, totalMB)
    }

    // MARK: - Shell helper

    private static func shell(_ args: String...) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
```

**Step 2: Regenerate project and run tests**

Run:
```bash
cd /Users/rock/Developer/bangarang/cracked
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme CrackedTests -configuration Debug test -destination 'platform=macOS'
```

Expected: All tests PASS.

**Step 3: Commit**

```bash
git add Cracked/Sources/Services/ProcessMonitor.swift
git commit -m "Implement ProcessMonitor with ps parsing"
```

---

## Phase 3: Menu Bar UI

### Task 6: Create MenuBarViewModel and wire to monitor

**Files:**
- Create: `Cracked/Sources/ViewModels/MenuBarViewModel.swift`
- Modify: `Cracked/Sources/App/CrackedApp.swift`

**Step 1: Create MenuBarViewModel**

`Cracked/Sources/ViewModels/MenuBarViewModel.swift`:

```swift
import Foundation
import SwiftUI

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var cpuHogs: [ProcessSnapshot] = []
    @Published var staleApps: [ProcessSnapshot] = []
    @Published var loadAverage: Double = 0
    @Published var memoryUsedGB: Double = 0
    @Published var memoryTotalGB: Double = 0
    @Published var totalProcesses: Int = 0
    @Published var iconState: IconState = .normal

    let monitor = ProcessMonitor()

    // Thresholds (will be configurable later via Settings)
    var cpuThreshold: Double = 30.0
    var stalenessThresholdSeconds: Int = 7 * 86400  // 7 days

    enum IconState {
        case normal
        case warning
        case critical

        var systemImage: String {
            switch self {
            case .normal: "gauge.low"
            case .warning: "gauge.medium"
            case .critical: "gauge.high"
            }
        }

        var color: Color {
            switch self {
            case .normal: .primary
            case .warning: .yellow
            case .critical: .red
            }
        }
    }

    func start() {
        monitor.start()
        // Observe changes from monitor
        Task {
            while true {
                try? await Task.sleep(for: .seconds(1))
                updateFromSnapshot()
            }
        }
    }

    private func updateFromSnapshot() {
        guard let snapshot = monitor.latestSnapshot else { return }

        loadAverage = snapshot.loadAverage
        memoryUsedGB = snapshot.memoryUsedGB
        memoryTotalGB = snapshot.memoryTotalGB
        totalProcesses = snapshot.totalProcesses

        cpuHogs = snapshot.processes
            .filter { $0.cpuPercent >= cpuThreshold }
            .sorted { $0.cpuPercent > $1.cpuPercent }

        staleApps = snapshot.processes
            .filter { $0.uptimeSeconds >= stalenessThresholdSeconds && $0.cpuPercent < cpuThreshold }
            .sorted { $0.uptimeSeconds > $1.uptimeSeconds }
        // Deduplicate stale apps by name, keeping the longest-running instance
        var seen = Set<String>()
        staleApps = staleApps.filter { seen.insert($0.name).inserted }

        // Determine icon state
        let hasCritical = cpuHogs.contains { $0.cpuPercent >= 100 }
        let hasWarning = !cpuHogs.isEmpty || loadAverage > 8
        if hasCritical || loadAverage > 20 {
            iconState = .critical
        } else if hasWarning {
            iconState = .warning
        } else {
            iconState = .normal
        }
    }

    func killProcess(_ process: ProcessSnapshot) {
        kill(process.pid, SIGTERM)
    }

    func restartApp(_ process: ProcessSnapshot) {
        // Get the app bundle URL before killing
        let appName = process.name
        kill(process.pid, SIGTERM)

        // Attempt to relaunch after a short delay
        Task {
            try? await Task.sleep(for: .seconds(1))
            let workspace = NSWorkspace.shared
            if let app = workspace.runningApplications.first(where: { $0.localizedName == appName }) {
                app.terminate()
            }
            // Try to open by app name
            let appURL = URL(fileURLWithPath: "/Applications/\(appName).app")
            if FileManager.default.fileExists(atPath: appURL.path) {
                try? await NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
            }
        }
    }
}
```

**Step 2: Update CrackedApp.swift**

Replace `Cracked/Sources/App/CrackedApp.swift`:

```swift
import SwiftUI

@main
struct CrackedApp: App {
    @StateObject private var viewModel = MenuBarViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            Image(systemName: viewModel.iconState.systemImage)
                .symbolRenderingMode(.palette)
                .foregroundStyle(viewModel.iconState.color)
        }
        .menuBarExtraStyle(.window)
        .onAppear {
            viewModel.start()
        }
    }
}
```

**Step 3: Regenerate and build**

Run:
```bash
cd /Users/rock/Developer/bangarang/cracked
xcodegen generate
```

Note: This will not build yet — we need `MenuBarView` from the next task. Commit what we have.

**Step 4: Commit**

```bash
git add Cracked/Sources/ViewModels/MenuBarViewModel.swift Cracked/Sources/App/CrackedApp.swift
git commit -m "Add MenuBarViewModel with icon state logic"
```

---

### Task 7: Create the dropdown MenuBarView

**Files:**
- Create: `Cracked/Sources/Views/MenuBarView.swift`
- Create: `Cracked/Sources/Views/ProcessRowView.swift`

**Step 1: Create ProcessRowView**

`Cracked/Sources/Views/ProcessRowView.swift`:

```swift
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
```

**Step 2: Create MenuBarView**

`Cracked/Sources/Views/MenuBarView.swift`:

```swift
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: viewModel.iconState.systemImage)
                    .foregroundStyle(viewModel.iconState.color)
                Text("Cracked")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // CPU Hogs
            if !viewModel.cpuHogs.isEmpty {
                sectionHeader("CPU Hogs")
                ForEach(viewModel.cpuHogs.prefix(5)) { process in
                    ProcessRowView(
                        process: process,
                        actionLabel: "Kill",
                        action: { viewModel.killProcess(process) }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }

            // Stale Apps
            if !viewModel.staleApps.isEmpty {
                sectionHeader("Stale Apps")
                ForEach(viewModel.staleApps.prefix(5)) { process in
                    ProcessRowView(
                        process: process,
                        actionLabel: "Restart",
                        action: { viewModel.restartApp(process) }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }

            // Nothing to report
            if viewModel.cpuHogs.isEmpty && viewModel.staleApps.isEmpty {
                Text("All systems nominal")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            Divider()

            // System stats footer
            HStack {
                Text(String(format: "Load: %.1f", viewModel.loadAverage))
                Spacer()
                Text(String(format: "RAM: %.0f/%.0f GB", viewModel.memoryUsedGB, viewModel.memoryTotalGB))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Menu items
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 340)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}
```

**Step 3: Build and run**

Run:
```bash
cd /Users/rock/Developer/bangarang/cracked
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme Cracked -configuration Debug build
```

Expected: Build succeeds. To test, run the built app:
```bash
open /Users/rock/Developer/bangarang/cracked/build/Debug/Cracked.app
```

You should see a gauge icon in the menu bar. Click it to see the dropdown with live process data.

**Step 4: Commit**

```bash
git add Cracked/Sources/Views/MenuBarView.swift Cracked/Sources/Views/ProcessRowView.swift
git commit -m "Add MenuBarView dropdown with CPU hogs and stale apps"
```

---

## Phase 4: Database Layer

### Task 8: Write DatabaseManager tests

**Files:**
- Create: `CrackedTests/DatabaseManagerTests.swift`

**Step 1: Write the tests**

`CrackedTests/DatabaseManagerTests.swift`:

```swift
import Testing
import Foundation
@testable import Cracked

@Suite("DatabaseManager")
struct DatabaseManagerTests {

    @Test("Creates database and tables")
    func createDatabase() throws {
        let db = try DatabaseManager(inMemory: true)
        // Should not throw — tables exist
        let count = try db.snapshotCount()
        #expect(count == 0)
    }

    @Test("Stores and retrieves snapshots")
    func storeSnapshot() throws {
        let db = try DatabaseManager(inMemory: true)

        let snapshot = SystemSnapshot(
            timestamp: Date(),
            loadAverage: 5.0,
            totalProcesses: 100,
            memoryUsedMB: 64000,
            memoryTotalMB: 131072,
            processes: [
                ProcessSnapshot(id: 123, pid: 123, name: "TestApp", cpuPercent: 50.0, memoryMB: 512, uptimeSeconds: 3600)
            ]
        )

        try db.saveSnapshot(snapshot)
        let count = try db.snapshotCount()
        #expect(count == 1)
    }

    @Test("Stores and retrieves records")
    func storeRecord() throws {
        let db = try DatabaseManager(inMemory: true)

        try db.saveRecord(
            type: "peak_cpu",
            value: 114.4,
            appName: "Comet",
            details: "Comet Helper (Renderer)"
        )

        let records = try db.allRecords()
        #expect(records.count == 1)
        #expect(records[0].recordType == "peak_cpu")
        #expect(records[0].value == 114.4)
        #expect(records[0].appName == "Comet")
    }

    @Test("Saves and retrieves app configs")
    func appConfigs() throws {
        let db = try DatabaseManager(inMemory: true)

        try db.saveAppConfig(AppConfigRecord(
            appName: "Comet",
            cpuThreshold: 150.0,
            stalenessDays: 3,
            autoKill: true
        ))

        let config = try db.appConfig(for: "Comet")
        #expect(config?.cpuThreshold == 150.0)
        #expect(config?.stalenessDays == 3)
        #expect(config?.autoKill == true)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:
```bash
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme CrackedTests -configuration Debug test -destination 'platform=macOS'
```

Expected: FAIL — `DatabaseManager` not found.

**Step 3: Commit**

```bash
git add CrackedTests/DatabaseManagerTests.swift
git commit -m "Add failing DatabaseManager tests"
```

---

### Task 9: Implement DatabaseManager

**Files:**
- Create: `Cracked/Sources/Models/DatabaseModels.swift`
- Create: `Cracked/Sources/Services/DatabaseManager.swift`

**Step 1: Create database record models**

`Cracked/Sources/Models/DatabaseModels.swift`:

```swift
import Foundation
import GRDB

// MARK: - Snapshot record (stored in DB)

struct SnapshotRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "snapshots"

    var id: Int64?
    var timestamp: Double
    var loadAvg: Double
    var totalProcesses: Int
    var memoryUsedMB: Int
    var memoryTotalMB: Int

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Process snapshot record (stored in DB)

struct ProcessSnapRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "process_snaps"

    var id: Int64?
    var snapshotId: Int64
    var pid: Int32
    var appName: String
    var cpuPercent: Double
    var memoryMB: Int
    var uptimeSeconds: Int

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Record (personal records / achievements)

struct RecordEntry: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "records"

    var id: Int64?
    var recordType: String
    var value: Double
    var appName: String?
    var achievedAt: Double
    var details: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - App config

struct AppConfigRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "app_configs"

    var appName: String
    var cpuThreshold: Double?
    var stalenessDays: Int?
    var autoKill: Bool

    enum CodingKeys: String, CodingKey {
        case appName, cpuThreshold, stalenessDays, autoKill
    }

    init(appName: String, cpuThreshold: Double? = nil, stalenessDays: Int? = nil, autoKill: Bool = false) {
        self.appName = appName
        self.cpuThreshold = cpuThreshold
        self.stalenessDays = stalenessDays
        self.autoKill = autoKill
    }
}
```

**Step 2: Create DatabaseManager**

`Cracked/Sources/Services/DatabaseManager.swift`:

```swift
import Foundation
import GRDB

final class DatabaseManager: Sendable {
    private let dbQueue: DatabaseQueue

    init(inMemory: Bool = false) throws {
        if inMemory {
            dbQueue = try DatabaseQueue()
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbDir = appSupport.appendingPathComponent("Cracked", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            let dbPath = dbDir.appendingPathComponent("cracked.sqlite").path
            dbQueue = try DatabaseQueue(path: dbPath)
        }
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "snapshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull()
                t.column("loadAvg", .double).notNull()
                t.column("totalProcesses", .integer).notNull()
                t.column("memoryUsedMB", .integer).notNull()
                t.column("memoryTotalMB", .integer).notNull()
            }

            try db.create(table: "process_snaps") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("snapshotId", .integer).notNull().references("snapshots", onDelete: .cascade)
                t.column("pid", .integer).notNull()
                t.column("appName", .text).notNull()
                t.column("cpuPercent", .double).notNull()
                t.column("memoryMB", .integer).notNull()
                t.column("uptimeSeconds", .integer).notNull()
            }

            try db.create(table: "records") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("recordType", .text).notNull()
                t.column("value", .double).notNull()
                t.column("appName", .text)
                t.column("achievedAt", .double).notNull()
                t.column("details", .text)
            }

            try db.create(table: "app_configs") { t in
                t.column("appName", .text).primaryKey()
                t.column("cpuThreshold", .double)
                t.column("stalenessDays", .integer)
                t.column("autoKill", .integer).notNull().defaults(to: 0)
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Snapshots

    func saveSnapshot(_ snapshot: SystemSnapshot) throws {
        try dbQueue.write { db in
            var record = SnapshotRecord(
                timestamp: snapshot.timestamp.timeIntervalSince1970,
                loadAvg: snapshot.loadAverage,
                totalProcesses: snapshot.totalProcesses,
                memoryUsedMB: snapshot.memoryUsedMB,
                memoryTotalMB: snapshot.memoryTotalMB
            )
            try record.insert(db)

            guard let snapshotId = record.id else { return }

            // Only save top CPU consumers (>5%) to avoid bloating the DB
            for process in snapshot.processes where process.cpuPercent > 5.0 {
                var processRecord = ProcessSnapRecord(
                    snapshotId: snapshotId,
                    pid: process.pid,
                    appName: process.name,
                    cpuPercent: process.cpuPercent,
                    memoryMB: process.memoryMB,
                    uptimeSeconds: process.uptimeSeconds
                )
                try processRecord.insert(db)
            }
        }
    }

    func snapshotCount() throws -> Int {
        try dbQueue.read { db in
            try SnapshotRecord.fetchCount(db)
        }
    }

    // MARK: - Records

    func saveRecord(type: String, value: Double, appName: String? = nil, details: String? = nil) throws {
        try dbQueue.write { db in
            var record = RecordEntry(
                recordType: type,
                value: value,
                appName: appName,
                achievedAt: Date().timeIntervalSince1970,
                details: details
            )
            try record.insert(db)
        }
    }

    func allRecords() throws -> [RecordEntry] {
        try dbQueue.read { db in
            try RecordEntry.order(Column("achievedAt").desc).fetchAll(db)
        }
    }

    func currentRecord(type: String, appName: String? = nil) throws -> RecordEntry? {
        try dbQueue.read { db in
            var request = RecordEntry.filter(Column("recordType") == type)
            if let appName {
                request = request.filter(Column("appName") == appName)
            }
            return try request.order(Column("value").desc).fetchOne(db)
        }
    }

    // MARK: - App configs

    func saveAppConfig(_ config: AppConfigRecord) throws {
        try dbQueue.write { db in
            try config.save(db)
        }
    }

    func appConfig(for appName: String) throws -> AppConfigRecord? {
        try dbQueue.read { db in
            try AppConfigRecord.fetchOne(db, key: appName)
        }
    }

    func allAppConfigs() throws -> [AppConfigRecord] {
        try dbQueue.read { db in
            try AppConfigRecord.fetchAll(db)
        }
    }

    // MARK: - Trend queries

    func recentSnapshots(hours: Int = 24) throws -> [SnapshotRecord] {
        let cutoff = Date().timeIntervalSince1970 - Double(hours * 3600)
        return try dbQueue.read { db in
            try SnapshotRecord
                .filter(Column("timestamp") > cutoff)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Hall of shame (top CPU consumers by cumulative time)

    struct ShameEntry: FetchableRecord, Decodable {
        var appName: String
        var totalCpuPercent: Double
        var sampleCount: Int
    }

    func hallOfShame(limit: Int = 5) throws -> [ShameEntry] {
        try dbQueue.read { db in
            let sql = """
                SELECT appName,
                       SUM(cpuPercent) as totalCpuPercent,
                       COUNT(*) as sampleCount
                FROM process_snaps
                GROUP BY appName
                ORDER BY totalCpuPercent DESC
                LIMIT ?
                """
            return try ShameEntry.fetchAll(db, sql: sql, arguments: [limit])
        }
    }
}
```

**Step 3: Run tests**

Run:
```bash
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme CrackedTests -configuration Debug test -destination 'platform=macOS'
```

Expected: All tests PASS.

**Step 4: Commit**

```bash
git add Cracked/Sources/Models/DatabaseModels.swift Cracked/Sources/Services/DatabaseManager.swift
git commit -m "Implement DatabaseManager with GRDB migrations and CRUD"
```

---

## Phase 5: Alert Engine & Notifications

### Task 10: Write AlertEngine tests

**Files:**
- Create: `CrackedTests/AlertEngineTests.swift`

**Step 1: Write the tests**

`CrackedTests/AlertEngineTests.swift`:

```swift
import Testing
import Foundation
@testable import Cracked

@Suite("AlertEngine")
struct AlertEngineTests {

    @Test("Detects CPU hog above threshold")
    func cpuHogDetection() {
        let engine = AlertEngine(cpuThreshold: 80, sustainedSeconds: 0)
        let process = ProcessSnapshot(id: 1, pid: 1, name: "TestApp", cpuPercent: 90, memoryMB: 100, uptimeSeconds: 60)

        let alerts = engine.evaluate(processes: [process], loadAverage: 1.0)
        #expect(alerts.contains { $0.type == .highCPU && $0.processName == "TestApp" })
    }

    @Test("Does not alert below threshold")
    func noCpuAlert() {
        let engine = AlertEngine(cpuThreshold: 80, sustainedSeconds: 0)
        let process = ProcessSnapshot(id: 1, pid: 1, name: "TestApp", cpuPercent: 50, memoryMB: 100, uptimeSeconds: 60)

        let alerts = engine.evaluate(processes: [process], loadAverage: 1.0)
        #expect(alerts.isEmpty)
    }

    @Test("Detects stale app")
    func staleAppDetection() {
        let engine = AlertEngine(stalenessThresholdSeconds: 86400)  // 1 day
        let process = ProcessSnapshot(id: 1, pid: 1, name: "OldApp", cpuPercent: 1, memoryMB: 100, uptimeSeconds: 172800)  // 2 days

        let alerts = engine.evaluate(processes: [process], loadAverage: 1.0)
        #expect(alerts.contains { $0.type == .staleApp && $0.processName == "OldApp" })
    }

    @Test("Respects cooldown period")
    func cooldown() {
        let engine = AlertEngine(cpuThreshold: 80, sustainedSeconds: 0, cooldownSeconds: 900)
        let process = ProcessSnapshot(id: 1, pid: 1, name: "TestApp", cpuPercent: 90, memoryMB: 100, uptimeSeconds: 60)

        let alerts1 = engine.evaluate(processes: [process], loadAverage: 1.0)
        #expect(alerts1.count == 1)

        // Second evaluation should be suppressed by cooldown
        let alerts2 = engine.evaluate(processes: [process], loadAverage: 1.0)
        #expect(alerts2.isEmpty)
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: FAIL — `AlertEngine` not found.

**Step 3: Commit**

```bash
git add CrackedTests/AlertEngineTests.swift
git commit -m "Add failing AlertEngine tests"
```

---

### Task 11: Implement AlertEngine

**Files:**
- Create: `Cracked/Sources/Services/AlertEngine.swift`

**Step 1: Implement AlertEngine**

`Cracked/Sources/Services/AlertEngine.swift`:

```swift
import Foundation

struct Alert: Sendable, Identifiable {
    let id = UUID()
    let type: AlertType
    let processName: String
    let pid: Int32
    let value: Double  // CPU% or uptime in days
    let message: String

    enum AlertType: Sendable {
        case highCPU
        case staleApp
        case highLoad
    }
}

final class AlertEngine: Sendable {
    let cpuThreshold: Double
    let sustainedSeconds: Int
    let stalenessThresholdSeconds: Int
    let cooldownSeconds: Int

    // Track when we last alerted for each process (by name)
    private let lastAlerted = Mutex<[String: Date]>([:])

    init(
        cpuThreshold: Double = 80,
        sustainedSeconds: Int = 30,
        stalenessThresholdSeconds: Int = 7 * 86400,
        cooldownSeconds: Int = 900
    ) {
        self.cpuThreshold = cpuThreshold
        self.sustainedSeconds = sustainedSeconds
        self.stalenessThresholdSeconds = stalenessThresholdSeconds
        self.cooldownSeconds = cooldownSeconds
    }

    func evaluate(processes: [ProcessSnapshot], loadAverage: Double) -> [Alert] {
        var alerts: [Alert] = []
        let now = Date()

        // Check CPU hogs
        for process in processes where process.cpuPercent >= cpuThreshold {
            if shouldAlert(for: process.name, at: now) {
                alerts.append(Alert(
                    type: .highCPU,
                    processName: process.name,
                    pid: process.pid,
                    value: process.cpuPercent,
                    message: "\(process.name) is using \(String(format: "%.0f", process.cpuPercent))% CPU"
                ))
                markAlerted(for: process.name, at: now)
            }
        }

        // Check stale apps
        for process in processes where process.uptimeSeconds >= stalenessThresholdSeconds {
            let days = process.uptimeSeconds / 86400
            let key = "stale:\(process.name)"
            if shouldAlert(for: key, at: now) {
                alerts.append(Alert(
                    type: .staleApp,
                    processName: process.name,
                    pid: process.pid,
                    value: Double(days),
                    message: "\(process.name) has been running for \(days) days"
                ))
                markAlerted(for: key, at: now)
            }
        }

        // Check load average
        if loadAverage > 20 {
            let key = "load_average"
            if shouldAlert(for: key, at: now) {
                alerts.append(Alert(
                    type: .highLoad,
                    processName: "System",
                    pid: 0,
                    value: loadAverage,
                    message: String(format: "System load is extremely high: %.1f", loadAverage)
                ))
                markAlerted(for: key, at: now)
            }
        }

        return alerts
    }

    private func shouldAlert(for key: String, at now: Date) -> Bool {
        lastAlerted.withLock { dict in
            guard let last = dict[key] else { return true }
            return now.timeIntervalSince(last) >= Double(cooldownSeconds)
        }
    }

    private func markAlerted(for key: String, at now: Date) {
        lastAlerted.withLock { dict in
            dict[key] = now
        }
    }
}

// Simple mutex for thread-safe access
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
```

**Step 2: Run tests**

Run:
```bash
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme CrackedTests -configuration Debug test -destination 'platform=macOS'
```

Expected: All tests PASS.

**Step 3: Commit**

```bash
git add Cracked/Sources/Services/AlertEngine.swift
git commit -m "Implement AlertEngine with CPU, staleness, and load alerts"
```

---

### Task 12: Implement NotificationManager

**Files:**
- Create: `Cracked/Sources/Services/NotificationManager.swift`
- Modify: `Cracked/Sources/ViewModels/MenuBarViewModel.swift`

**Step 1: Create NotificationManager**

`Cracked/Sources/Services/NotificationManager.swift`:

```swift
import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationManager()

    private static let killActionID = "KILL_ACTION"
    private static let restartActionID = "RESTART_ACTION"
    private static let cpuCategoryID = "CPU_ALERT"
    private static let staleCategoryID = "STALE_ALERT"
    private static let recordCategoryID = "RECORD_ALERT"

    override init() {
        super.init()
        setupCategories()
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { print("Notification permission error: \(error)") }
        }
        UNUserNotificationCenter.current().delegate = self
    }

    private func setupCategories() {
        let killAction = UNNotificationAction(identifier: Self.killActionID, title: "Kill", options: .destructive)
        let restartAction = UNNotificationAction(identifier: Self.restartActionID, title: "Restart", options: .destructive)

        let cpuCategory = UNNotificationCategory(identifier: Self.cpuCategoryID, actions: [killAction], intentIdentifiers: [])
        let staleCategory = UNNotificationCategory(identifier: Self.staleCategoryID, actions: [restartAction], intentIdentifiers: [])
        let recordCategory = UNNotificationCategory(identifier: Self.recordCategoryID, actions: [], intentIdentifiers: [])

        UNUserNotificationCenter.current().setNotificationCategories([cpuCategory, staleCategory, recordCategory])
    }

    func sendAlert(_ alert: Alert) {
        let content = UNMutableNotificationContent()
        content.title = "Cracked"
        content.body = alert.message
        content.sound = .default
        content.userInfo = ["pid": alert.pid, "processName": alert.processName]

        switch alert.type {
        case .highCPU, .highLoad:
            content.categoryIdentifier = Self.cpuCategoryID
        case .staleApp:
            content.categoryIdentifier = Self.staleCategoryID
        }

        let request = UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func sendRecordNotification(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Cracked — New Record!"
        content.body = message
        content.sound = .default
        content.categoryIdentifier = Self.recordCategoryID

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Handle notification actions
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let pid = userInfo["pid"] as? Int32 else { return }

        switch response.actionIdentifier {
        case Self.killActionID:
            kill(pid, SIGTERM)
        case Self.restartActionID:
            kill(pid, SIGTERM)
            // Restart logic would need the app path — simplified here
        default:
            break
        }
    }
}
```

**Step 2: Wire AlertEngine and NotificationManager into MenuBarViewModel**

Add to `MenuBarViewModel.swift` — update the class to include:

Add these properties after the existing properties:

```swift
    let alertEngine = AlertEngine()
    let notificationManager = NotificationManager.shared
    private var db: DatabaseManager?
```

Add this to the `start()` method, before the Task:

```swift
        notificationManager.requestPermission()
        db = try? DatabaseManager()
```

Add this call at the end of `updateFromSnapshot()`:

```swift
        // Check for alerts
        let alerts = alertEngine.evaluate(
            processes: snapshot.processes,
            loadAverage: snapshot.loadAverage
        )
        for alert in alerts {
            notificationManager.sendAlert(alert)
        }

        // Persist snapshot to database (every 12th poll ≈ once per minute at 5s interval)
        persistCounter += 1
        if persistCounter % 12 == 0 {
            try? db?.saveSnapshot(snapshot)
        }
```

Add a counter property:

```swift
    private var persistCounter = 0
```

**Step 3: Build and verify**

Run:
```bash
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme Cracked -configuration Debug build
```

Expected: Build succeeds.

**Step 4: Commit**

```bash
git add Cracked/Sources/Services/NotificationManager.swift Cracked/Sources/ViewModels/MenuBarViewModel.swift
git commit -m "Add notifications with kill/restart actions and DB persistence"
```

---

## Phase 6: Records & Stats

### Task 13: Implement RecordTracker

**Files:**
- Create: `Cracked/Sources/Services/RecordTracker.swift`
- Create: `CrackedTests/RecordTrackerTests.swift`

**Step 1: Write failing tests**

`CrackedTests/RecordTrackerTests.swift`:

```swift
import Testing
import Foundation
@testable import Cracked

@Suite("RecordTracker")
struct RecordTrackerTests {

    @Test("Detects new peak CPU record")
    func peakCpuRecord() throws {
        let db = try DatabaseManager(inMemory: true)
        let tracker = RecordTracker(db: db)

        let processes = [
            ProcessSnapshot(id: 1, pid: 1, name: "TestApp", cpuPercent: 200.0, memoryMB: 100, uptimeSeconds: 60)
        ]

        let newRecords = try tracker.checkForRecords(processes: processes, totalProcessCount: 10)
        #expect(newRecords.contains { $0.contains("CPU") })
    }

    @Test("Detects process count record for an app")
    func processCountRecord() throws {
        let db = try DatabaseManager(inMemory: true)
        let tracker = RecordTracker(db: db)

        // 50 processes from one app
        let processes = (0..<50).map { i in
            ProcessSnapshot(id: Int32(i), pid: Int32(i), name: "Comet", cpuPercent: 1.0, memoryMB: 100, uptimeSeconds: 60)
        }

        let newRecords = try tracker.checkForRecords(processes: processes, totalProcessCount: 50)
        #expect(newRecords.contains { $0.contains("Comet") && $0.contains("50") })
    }

    @Test("Does not re-record same value")
    func noDoubleRecord() throws {
        let db = try DatabaseManager(inMemory: true)
        let tracker = RecordTracker(db: db)

        let processes = [
            ProcessSnapshot(id: 1, pid: 1, name: "TestApp", cpuPercent: 200.0, memoryMB: 100, uptimeSeconds: 60)
        ]

        let first = try tracker.checkForRecords(processes: processes, totalProcessCount: 1)
        #expect(!first.isEmpty)

        let second = try tracker.checkForRecords(processes: processes, totalProcessCount: 1)
        #expect(second.isEmpty)
    }
}
```

**Step 2: Implement RecordTracker**

`Cracked/Sources/Services/RecordTracker.swift`:

```swift
import Foundation

final class RecordTracker {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    /// Check current state for new records. Returns list of human-readable record messages.
    func checkForRecords(processes: [ProcessSnapshot], totalProcessCount: Int) throws -> [String] {
        var messages: [String] = []

        // 1. Peak CPU for any single process
        if let topCPU = processes.max(by: { $0.cpuPercent < $1.cpuPercent }), topCPU.cpuPercent > 50 {
            let existing = try db.currentRecord(type: "peak_cpu")
            if existing == nil || topCPU.cpuPercent > existing!.value {
                try db.saveRecord(
                    type: "peak_cpu",
                    value: topCPU.cpuPercent,
                    appName: topCPU.name,
                    details: "PID \(topCPU.pid)"
                )
                messages.append("\(topCPU.name) hit \(String(format: "%.0f", topCPU.cpuPercent))% CPU!")
            }
        }

        // 2. Most processes from a single app
        let grouped = Dictionary(grouping: processes, by: \.name)
        for (appName, appProcesses) in grouped where appProcesses.count >= 10 {
            let count = Double(appProcesses.count)
            let existing = try db.currentRecord(type: "process_count", appName: appName)
            if existing == nil || count > existing!.value {
                try db.saveRecord(
                    type: "process_count",
                    value: count,
                    appName: appName,
                    details: "That's cracked."
                )
                messages.append("\(Int(count)) \(appName) processes at once!")
            }
        }

        // 3. Total system process count
        let totalCount = Double(totalProcessCount)
        if totalProcessCount >= 500 {
            let existing = try db.currentRecord(type: "total_processes")
            if existing == nil || totalCount > existing!.value {
                try db.saveRecord(
                    type: "total_processes",
                    value: totalCount,
                    details: "System-wide"
                )
                messages.append("\(totalProcessCount) total processes running!")
            }
        }

        // 4. Longest uptime for a single app
        if let longestRunning = processes.max(by: { $0.uptimeSeconds < $1.uptimeSeconds }),
           longestRunning.uptimeSeconds >= 86400 {
            let days = Double(longestRunning.uptimeSeconds) / 86400.0
            let existing = try db.currentRecord(type: "longest_uptime", appName: longestRunning.name)
            if existing == nil || days > existing!.value {
                try db.saveRecord(
                    type: "longest_uptime",
                    value: days,
                    appName: longestRunning.name,
                    details: "\(longestRunning.uptimeFormatted)"
                )
                messages.append("\(longestRunning.name) running for \(Int(days)) days!")
            }
        }

        return messages
    }
}
```

**Step 3: Run tests**

Run:
```bash
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme CrackedTests -configuration Debug test -destination 'platform=macOS'
```

Expected: All tests PASS.

**Step 4: Wire RecordTracker into MenuBarViewModel**

Add to `MenuBarViewModel.swift`:

Property:
```swift
    private var recordTracker: RecordTracker?
```

In `start()`, after `db = try? DatabaseManager()`:
```swift
        if let db { recordTracker = RecordTracker(db: db) }
```

At the end of `updateFromSnapshot()`:
```swift
        // Check for new records
        if let records = try? recordTracker?.checkForRecords(
            processes: snapshot.processes,
            totalProcessCount: snapshot.totalProcesses
        ) {
            for message in records {
                notificationManager.sendRecordNotification(message: message)
            }
        }
```

**Step 5: Commit**

```bash
git add Cracked/Sources/Services/RecordTracker.swift CrackedTests/RecordTrackerTests.swift Cracked/Sources/ViewModels/MenuBarViewModel.swift
git commit -m "Add RecordTracker for personal records and achievements"
```

---

### Task 14: Create Stats window

**Files:**
- Create: `Cracked/Sources/ViewModels/StatsViewModel.swift`
- Create: `Cracked/Sources/Views/StatsView.swift`
- Modify: `Cracked/Sources/App/CrackedApp.swift`
- Modify: `Cracked/Sources/Views/MenuBarView.swift`

**Step 1: Create StatsViewModel**

`Cracked/Sources/ViewModels/StatsViewModel.swift`:

```swift
import Foundation

struct TrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

@MainActor
final class StatsViewModel: ObservableObject {
    @Published var records: [RecordEntry] = []
    @Published var hallOfShame: [DatabaseManager.ShameEntry] = []
    @Published var loadTrend: [TrendPoint] = []
    @Published var memoryTrend: [TrendPoint] = []

    private let db: DatabaseManager?

    init(db: DatabaseManager?) {
        self.db = db
    }

    func refresh() {
        guard let db else { return }

        records = (try? db.allRecords()) ?? []
        hallOfShame = (try? db.hallOfShame()) ?? []

        // Build trend data from recent snapshots
        if let snapshots = try? db.recentSnapshots(hours: 24) {
            loadTrend = snapshots.map { TrendPoint(date: Date(timeIntervalSince1970: $0.timestamp), value: $0.loadAvg) }
            memoryTrend = snapshots.map { TrendPoint(date: Date(timeIntervalSince1970: $0.timestamp), value: Double($0.memoryUsedMB) / 1024.0) }
        }
    }
}
```

**Step 2: Create StatsView**

`Cracked/Sources/Views/StatsView.swift`:

```swift
import SwiftUI
import Charts

struct StatsView: View {
    @ObservedObject var viewModel: StatsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Records section
                Text("All-Time Records")
                    .font(.title2.bold())

                if viewModel.records.isEmpty {
                    Text("No records yet. Keep using your Mac!")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(viewModel.records.prefix(8), id: \.id) { record in
                            RecordCard(record: record)
                        }
                    }
                }

                Divider()

                // Load average trend
                Text("Load Average (24h)")
                    .font(.title2.bold())

                if viewModel.loadTrend.isEmpty {
                    Text("Collecting data...")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(viewModel.loadTrend) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Load", point.value))
                            .foregroundStyle(.red)
                    }
                    .frame(height: 150)
                }

                Divider()

                // Memory trend
                Text("Memory Usage (24h)")
                    .font(.title2.bold())

                if viewModel.memoryTrend.isEmpty {
                    Text("Collecting data...")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(viewModel.memoryTrend) { point in
                        AreaMark(x: .value("Time", point.date), y: .value("GB", point.value))
                            .foregroundStyle(.blue.opacity(0.3))
                        LineMark(x: .value("Time", point.date), y: .value("GB", point.value))
                            .foregroundStyle(.blue)
                    }
                    .frame(height: 150)
                }

                Divider()

                // Hall of shame
                Text("Hall of Shame")
                    .font(.title2.bold())

                if viewModel.hallOfShame.isEmpty {
                    Text("No data yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(viewModel.hallOfShame.enumerated()), id: \.offset) { index, entry in
                        HStack {
                            Text("\(index + 1).")
                                .font(.headline)
                                .frame(width: 24)
                            Text(entry.appName)
                                .font(.body)
                            Spacer()
                            Text(String(format: "%.0f%% cumulative CPU", entry.totalCpuPercent))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("(\(entry.sampleCount) samples)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 500)
        .onAppear { viewModel.refresh() }
    }
}

struct RecordCard: View {
    let record: RecordEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recordTypeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formattedValue)
                .font(.title3.bold())
            if let app = record.appName {
                Text(app)
                    .font(.caption)
                    .lineLimit(1)
            }
            Text(Date(timeIntervalSince1970: record.achievedAt), style: .date)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var recordTypeLabel: String {
        switch record.recordType {
        case "peak_cpu": "Peak CPU"
        case "process_count": "Most Processes"
        case "total_processes": "Total System Processes"
        case "longest_uptime": "Longest Uptime"
        default: record.recordType
        }
    }

    private var formattedValue: String {
        switch record.recordType {
        case "peak_cpu": String(format: "%.0f%%", record.value)
        case "process_count": "\(Int(record.value)) processes"
        case "total_processes": "\(Int(record.value)) processes"
        case "longest_uptime": "\(Int(record.value)) days"
        default: String(format: "%.1f", record.value)
        }
    }
}
```

**Step 3: Add Stats window to CrackedApp and MenuBarView**

Update `CrackedApp.swift` — add a `Window` scene and state for showing it:

```swift
import SwiftUI

@main
struct CrackedApp: App {
    @StateObject private var viewModel = MenuBarViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
                .environment(\.openWindow, openWindow)
        } label: {
            Image(systemName: viewModel.iconState.systemImage)
                .symbolRenderingMode(.palette)
                .foregroundStyle(viewModel.iconState.color)
        }
        .menuBarExtraStyle(.window)
        .onAppear {
            viewModel.start()
        }

        Window("Cracked — Records & Stats", id: "stats") {
            StatsView(viewModel: StatsViewModel(db: viewModel.db))
        }
    }
}
```

Update `MenuBarViewModel` to make `db` accessible:

Change `private var db: DatabaseManager?` to `private(set) var db: DatabaseManager?`

Update `MenuBarView.swift` — add "Records & Stats..." button before Quit:

```swift
            Button("Records & Stats...") {
                openWindow(id: "stats")
                // Bring app to front since we're an LSUIElement app
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
```

Add the environment property to MenuBarView:

```swift
    @Environment(\.openWindow) private var openWindow
```

**Step 4: Build and verify**

Run:
```bash
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme Cracked -configuration Debug build
```

Expected: Build succeeds.

**Step 5: Commit**

```bash
git add Cracked/Sources/ViewModels/StatsViewModel.swift Cracked/Sources/Views/StatsView.swift Cracked/Sources/App/CrackedApp.swift Cracked/Sources/Views/MenuBarView.swift Cracked/Sources/ViewModels/MenuBarViewModel.swift
git commit -m "Add Records & Stats window with charts and hall of shame"
```

---

## Phase 7: Settings

### Task 15: Create Settings window

**Files:**
- Create: `Cracked/Sources/Views/SettingsView.swift`
- Modify: `Cracked/Sources/App/CrackedApp.swift`
- Modify: `Cracked/Sources/Views/MenuBarView.swift`

**Step 1: Create SettingsView**

`Cracked/Sources/Views/SettingsView.swift`:

```swift
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
```

**Step 2: Add Settings window to CrackedApp.swift**

Add after the Stats `Window` scene:

```swift
        Settings {
            SettingsView()
        }
```

**Step 3: Add Settings button to MenuBarView**

In `MenuBarView.swift`, add before the Quit button:

```swift
            Button("Settings...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
```

**Step 4: Build and verify**

Run:
```bash
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme Cracked -configuration Debug build
```

Expected: Build succeeds.

**Step 5: Commit**

```bash
git add Cracked/Sources/Views/SettingsView.swift Cracked/Sources/App/CrackedApp.swift Cracked/Sources/Views/MenuBarView.swift
git commit -m "Add Settings window with thresholds and launch at login"
```

---

## Phase 8: Data Downsampling

### Task 16: Add snapshot downsampling

**Files:**
- Modify: `Cracked/Sources/Services/DatabaseManager.swift`
- Modify: `Cracked/Sources/ViewModels/MenuBarViewModel.swift`

**Step 1: Add downsampling methods to DatabaseManager**

Add to `DatabaseManager.swift`:

```swift
    // MARK: - Downsampling

    /// Downsample old snapshots: keep per-minute for 24h, per-hour for 30d, daily after that.
    func downsample() throws {
        try dbQueue.write { db in
            let now = Date().timeIntervalSince1970

            // Delete raw process_snaps older than 24 hours (keep aggregated snapshots)
            let oneDayAgo = now - 86400
            try db.execute(sql: """
                DELETE FROM process_snaps
                WHERE snapshotId IN (SELECT id FROM snapshots WHERE timestamp < ?)
                """, arguments: [oneDayAgo])

            // Thin out snapshots: keep one per hour for data older than 24h
            let thirtyDaysAgo = now - (30 * 86400)

            // For data between 1-30 days old: keep one snapshot per hour
            try db.execute(sql: """
                DELETE FROM snapshots
                WHERE timestamp < ? AND timestamp > ?
                AND id NOT IN (
                    SELECT MIN(id) FROM snapshots
                    WHERE timestamp < ? AND timestamp > ?
                    GROUP BY CAST(timestamp / 3600 AS INTEGER)
                )
                """, arguments: [oneDayAgo, thirtyDaysAgo, oneDayAgo, thirtyDaysAgo])

            // For data older than 30 days: keep one snapshot per day
            try db.execute(sql: """
                DELETE FROM snapshots
                WHERE timestamp < ?
                AND id NOT IN (
                    SELECT MIN(id) FROM snapshots
                    WHERE timestamp < ?
                    GROUP BY CAST(timestamp / 86400 AS INTEGER)
                )
                """, arguments: [thirtyDaysAgo, thirtyDaysAgo])
        }
    }
```

**Step 2: Run downsampling periodically in MenuBarViewModel**

In `updateFromSnapshot()`, add after the persist logic:

```swift
        // Downsample every ~hour (720 polls at 5s interval)
        if persistCounter % 720 == 0 {
            try? db?.downsample()
        }
```

**Step 3: Build and run tests**

Run:
```bash
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme CrackedTests -configuration Debug test -destination 'platform=macOS'
```

Expected: All tests PASS.

**Step 4: Commit**

```bash
git add Cracked/Sources/Services/DatabaseManager.swift Cracked/Sources/ViewModels/MenuBarViewModel.swift
git commit -m "Add snapshot downsampling for long-term storage efficiency"
```

---

## Phase 9: Final Polish

### Task 17: Wire Settings values into monitoring

**Files:**
- Modify: `Cracked/Sources/ViewModels/MenuBarViewModel.swift`

**Step 1: Read thresholds from UserDefaults**

Update `MenuBarViewModel` to read from `@AppStorage`:

```swift
    @AppStorage("cpuThreshold") var cpuThreshold: Double = 30.0
    @AppStorage("stalenessThresholdDays") private var stalenessThresholdDays: Int = 7
    @AppStorage("pollIntervalSeconds") private var pollInterval: Double = 5.0
    @AppStorage("cooldownMinutes") private var cooldownMinutes: Int = 15
```

Update `updateFromSnapshot()` to use the dynamic staleness threshold:

```swift
    var stalenessThresholdSeconds: Int { stalenessThresholdDays * 86400 }
```

**Step 2: Build and verify**

Run:
```bash
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme Cracked -configuration Debug build
```

**Step 3: Commit**

```bash
git add Cracked/Sources/ViewModels/MenuBarViewModel.swift
git commit -m "Wire Settings values into monitoring thresholds"
```

---

### Task 18: Final build and smoke test

**Step 1: Clean build**

Run:
```bash
cd /Users/rock/Developer/bangarang/cracked
xcodegen generate
xcodebuild -project Cracked.xcodeproj -scheme Cracked -configuration Debug clean build
```

**Step 2: Run all tests**

Run:
```bash
xcodebuild -project Cracked.xcodeproj -scheme CrackedTests -configuration Debug test -destination 'platform=macOS'
```

Expected: All tests PASS.

**Step 3: Launch the app**

Run:
```bash
open build/Debug/Cracked.app
```

**Smoke test checklist:**
- [ ] Gauge icon appears in menu bar
- [ ] Click reveals dropdown with CPU hogs and stale apps
- [ ] Kill button terminates a process
- [ ] Icon turns yellow/red when processes exceed thresholds
- [ ] "Records & Stats..." opens the stats window
- [ ] "Settings..." opens preferences
- [ ] Quit terminates the app

**Step 4: Commit any fixes**

```bash
git add -A
git commit -m "Final polish and smoke test"
```
