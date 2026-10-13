import Foundation
@preconcurrency import UserNotifications

/// macOS notifications. Only works inside an .app bundle (not a bare `swift run` binary).
enum Notifier {
    private static var available: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    /// Notification kinds; each has its own action buttons.
    enum Category: String, CaseIterable {
        case linkCopied, completed, failed, trayHint
    }

    enum Action {
        static let downloadVideo = "downloadVideo"
        static let downloadAudio = "downloadAudio"
        static let openFile = "openFile"
        static let showInFolder = "showInFolder"
        static let retry = "retry"
        static let dismiss = "dismiss"
        static let gotIt = "gotIt"
        /// The notification itself was clicked.
        static let open = UNNotificationDefaultActionIdentifier
    }

    /// Called with (category, action, userInfo) when the user clicks a notification or one of its buttons.
    @MainActor static var onResponse: ((Category, String, [String: String]) -> Void)?

    /// Register action buttons and start receiving clicks. Call once at launch.
    static func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationDelegate.shared
        func action(_ id: String, _ title: String) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: title, options: [])
        }
        let actions: [Category: [UNNotificationAction]] = [
            .linkCopied: [action(Action.downloadVideo, "Download video"), action(Action.downloadAudio, "Audio only")],
            .completed: [action(Action.openFile, "Open file"), action(Action.showInFolder, "Show in folder")],
            .failed: [action(Action.retry, "Try again"), action(Action.dismiss, "Dismiss")],
            .trayHint: [action(Action.gotIt, "Got it")],
        ]
        center.setNotificationCategories(Set(Category.allCases.map {
            UNNotificationCategory(identifier: $0.rawValue, actions: actions[$0] ?? [], intentIdentifiers: [])
        }))
    }

    static func notify(title: String, body: String, category: Category? = nil, info: [String: String] = [:]) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = info
            if let category { content.categoryIdentifier = category.rawValue }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        let info = content.userInfo as? [String: String] ?? [:]
        if let category = Notifier.Category(rawValue: content.categoryIdentifier) {
            Task { @MainActor in Notifier.onResponse?(category, action, info) }
        }
        completionHandler()
    }

    /// Only called while the app is in front. Finished/failed downloads are already visible in the
    /// window or menu bar panel then, so only the other kinds are shown as banners.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        switch Notifier.Category(rawValue: notification.request.content.categoryIdentifier) {
        case .completed, .failed, .none: completionHandler([])
        default: completionHandler([.banner, .list])
        }
    }
}
