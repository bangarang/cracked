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
