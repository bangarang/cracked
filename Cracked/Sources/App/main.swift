import AppKit
import SwiftUI

// When running under the test host, start a minimal NSApplication run loop
// instead of the full SwiftUI app. The SwiftUI MenuBarExtra lifecycle causes
// the test runner to hang waiting for the app to become ready.
let isTesting = NSClassFromString("XCTestCase") != nil
    || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil

let arguments = Array(CommandLine.arguments.dropFirst())

if isTesting {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
} else if let command = arguments.first, CrackedCLI.commands.contains(command) {
    exit(CrackedCLI.run(command, arguments: Array(arguments.dropFirst())))
} else {
    // New menu bar items go to the far left of the existing ones, which on a notched MacBook
    // with a busy menu bar is behind the notch, where they can't be seen or dragged. Start
    // near the right edge instead (macOS stores this as the distance from the right edge
    // in points). Once the user ⌘-drags the icon, macOS saves their position here instead.
    let statusItemPositionKey = "NSStatusItem Preferred Position Item-0"
    if UserDefaults.standard.object(forKey: statusItemPositionKey) == nil {
        UserDefaults.standard.set(320.0, forKey: statusItemPositionKey)
    }
    CrackedApp.main()
}
