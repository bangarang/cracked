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
        default:
            break
        }
    }
}
