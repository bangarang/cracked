import CoreGraphics

enum UserActivity {
    /// Seconds since the last keyboard, mouse or trackpad input on this Mac.
    static func idleSeconds() -> Double {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
