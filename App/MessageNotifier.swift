import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#endif

/** Local notifications for incoming APRS messages. Tapping one opens that conversation. */
final class MessageNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = MessageNotifier()

    /** Set when the user taps a notification; the UI opens this conversation and clears it. */
    @Published var openConversation: String?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(sender: String, text: String) {
        let content = UNMutableNotificationContent()
        content.title = sender
        content.body = text
        content.sound = .default
        content.threadIdentifier = sender
        content.userInfo = ["sender": sender]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /** A watched-station or weather alert, with its own sound on the Mac (iOS uses the default sound). */
    func postAlert(title: String, body: String, sound: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "alerts"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        #if os(macOS)
        if sound != "Default" { NSSound(named: NSSound.Name(sound))?.play() }
        #endif
    }

    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let sender = response.notification.request.content.userInfo["sender"] as? String
        DispatchQueue.main.async { [weak self] in
            self?.openConversation = sender
            completionHandler()
        }
    }
}
