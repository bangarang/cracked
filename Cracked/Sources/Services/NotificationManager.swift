import Foundation
import UserNotifications
import AppKit

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationManager()

    private static let killActionID = "KILL_ACTION"
    private static let restartActionID = "RESTART_ACTION"
    private static let cpuCategoryID = "CPU_ALERT"
    private static let staleCategoryID = "STALE_ALERT"
    private static let recordCategoryID = "RECORD_ALERT"
    private static let agentCategoryID = "AGENT_ALERT"

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

        let agentCategory = UNNotificationCategory(identifier: Self.agentCategoryID, actions: [], intentIdentifiers: [])

        UNUserNotificationCenter.current().setNotificationCategories([cpuCategory, staleCategory, recordCategory, agentCategory])
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

    /// "my-project: Claude needs your input" / "my-project: Claude is done".
    func sendAgentNotification(_ session: AgentSession) {
        let content = UNMutableNotificationContent()
        content.title = session.projectName
        let name = session.agentName
        let via = session.source == .paseo ? "Paseo" : session.terminalName
        switch session.status {
        case .needsInput:
            content.body = session.message ?? "\(name) needs your input"
        case .error:
            content.body = "\(name) hit an error" + (session.message.map { ": \($0)" } ?? "")
        default:
            content.body = "\(name) is done" + (via.map { " · \($0)" } ?? "")
        }
        if let title = session.title { content.subtitle = title }
        content.sound = .default
        content.categoryIdentifier = Self.agentCategoryID
        content.threadIdentifier = session.sessionID
        // Clicking the notification focuses the agent the same way clicking its row does.
        if let data = try? JSONEncoder().encode(session) { content.userInfo = ["agentSession": data] }

        let request = UNNotificationRequest(identifier: "agent-\(session.sessionID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show banners even while Cracked's own window is focused.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Handle notification actions
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let data = userInfo["agentSession"] as? Data,
           let session = try? JSONDecoder().decode(AgentSession.self, from: data) {
            await AgentNavigator.focus(session)
            return
        }
        guard let pid = userInfo["pid"] as? Int32 else { return }

        switch response.actionIdentifier {
        case Self.killActionID:
            kill(pid, SIGTERM)
        case Self.restartActionID:
            kill(pid, SIGTERM)
        default:
            break
        }
    }
}
