import AppKit
import SwiftUI

// When running under the test host, start a minimal NSApplication run loop
// instead of the full SwiftUI app. The SwiftUI MenuBarExtra lifecycle causes
// the test runner to hang waiting for the app to become ready.
let isTesting = NSClassFromString("XCTestCase") != nil
    || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil

if isTesting {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
} else {
    CrackedApp.main()
}
