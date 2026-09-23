import AppKit
import UserNotifications

/// Pointer's own notifications: its icon and name, a frame as the preview, and a click that opens the write-up.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var allowed = false

    func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open write-up", options: [.foreground])
        let folder = UNNotificationAction(identifier: "folder", title: "Show files", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: "watch", actions: [open, folder],
                                                                intentIdentifiers: [], options: [])])
        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            self?.allowed = granted
            if let error { Log.write("notify: \(error.localizedDescription)") }
        }
    }

    /// Posts a notification. Falls back to the HUD when notifications are turned off for Pointer.
    func post(title: String, body: String, page: URL?, image: URL?, hud: HUDController?) {
        guard allowed else {
            hud?.flash(title, hint: body, tone: .done, for: 5)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = "watch"
        if let page { content.userInfo = ["page": page.path] }
        if let image, let copy = temporaryCopy(of: image),
           let attachment = try? UNNotificationAttachment(identifier: "frame", url: copy) {
            content.attachments = [attachment]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["page"] as? String {
            let page = URL(fileURLWithPath: path)
            if response.actionIdentifier == "folder" {
                NSWorkspace.shared.activateFileViewerSelecting([page])
            } else {
                NSWorkspace.shared.open(page)
            }
        }
        done()
    }

    /// Notification attachments take ownership of the file, so hand over a copy.
    private func temporaryCopy(of image: URL) -> URL? {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("pointer-\(UUID().uuidString)-\(image.lastPathComponent)")
        return (try? FileManager.default.copyItem(at: image, to: copy)) == nil ? nil : copy
    }
}
