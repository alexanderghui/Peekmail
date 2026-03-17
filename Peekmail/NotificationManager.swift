import AppKit
import UserNotifications

class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private override init() {
        super.init()
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
        UNUserNotificationCenter.current().delegate = self
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

    func sendEmailNotification(sender: String, subject: String, snippet: String, link: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = sender
        content.subtitle = subject
        content.body = snippet
        content.sound = nil

        if let link = link {
            content.userInfo = ["link": link]
        }

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
        print("[Peekmail] Notification clicked!")
        let userInfo = response.notification.request.content.userInfo
        print("[Peekmail] userInfo: \(userInfo)")

        DispatchQueue.main.async {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.showMainWindow()
                NSApp.activate(ignoringOtherApps: true)

                // Navigate to the specific email if we have a link
                if let link = userInfo["link"] as? String,
                   let url = URL(string: link) {
                    print("[Peekmail] Navigating to: \(link)")
                    AccountManager.shared.currentWebView?.load(URLRequest(url: url))
                } else {
                    print("[Peekmail] No link in notification")
                }
            } else {
                print("[Peekmail] Could not get AppDelegate")
            }
        }
        completionHandler()
    }
}
