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
    CrackedApp.main()
}
