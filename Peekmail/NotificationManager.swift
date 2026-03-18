import AppKit
import UserNotifications
import os

class NotificationManager: NSObject {
    static let shared = NotificationManager()
    private let logger = Logger(subsystem: "com.peekmail.app", category: "notifications")

    private override init() {
        super.init()
        // Set delegate immediately so notification clicks are always handled
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    func sendNewMailNotification(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Peekmail"
        content.body = count == 1 ? "You have a new email" : "You have \(count) new emails"
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    func sendEmailNotification(sender: String, subject: String, snippet: String, link: String? = nil, accountId: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = sender
        content.subtitle = subject
        content.body = snippet
        content.sound = nil

        var info: [String: String] = [:]
        if let link = link { info["link"] = link }
        if let accountId = accountId { info["accountId"] = accountId }
        if !info.isEmpty { content.userInfo = info }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    // Show notifications even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    // Handle notification click — open the email thread
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        logger.notice("Notification clicked, userInfo: \(userInfo.description)")

        DispatchQueue.main.async {
            guard let appDelegate = AppDelegate.shared else {
                self.logger.error("Could not get AppDelegate")
                return
            }
            let accountManager = AccountManager.shared

            self.logger.notice("Account count: \(accountManager.accounts.count), selectedIndex: \(accountManager.selectedIndex)")

            // Switch to the correct account if we know which one
            if let accountId = userInfo["accountId"] as? String,
               let index = accountManager.accounts.firstIndex(where: { $0.id.uuidString == accountId }) {
                self.logger.notice("Switching to account index: \(index)")
                accountManager.selectedIndex = index
            }

            appDelegate.showMainWindow()
            NSApp.activate()

            // Navigate to the specific email thread
            let link = userInfo["link"] as? String
            self.logger.notice("Link value: \(link ?? "nil", privacy: .public)")
            if let link = link {
                // Atom feed links use message_id param — convert to a Gmail thread URL
                let threadURL: URL?
                if let range = link.range(of: "message_id="),
                   let ampRange = link[range.upperBound...].range(of: "&") {
                    let messageId = String(link[range.upperBound..<ampRange.lowerBound])
                    threadURL = URL(string: "https://mail.google.com/mail/u/0/#inbox/\(messageId)")
                } else if let range = link.range(of: "message_id=") {
                    let messageId = String(link[range.upperBound...])
                    threadURL = URL(string: "https://mail.google.com/mail/u/0/#inbox/\(messageId)")
                } else {
                    threadURL = URL(string: link)
                }

                if let url = threadURL {
                    self.logger.notice("Navigating to: \(url.absoluteString, privacy: .public)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        accountManager.currentWebView?.load(URLRequest(url: url))
                    }
                }
            }
        }
        completionHandler()
    }
}
