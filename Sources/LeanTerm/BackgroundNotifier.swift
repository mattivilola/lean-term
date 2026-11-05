import AppKit
import UserNotifications

/// Opt-in notifications and Dock badge for activity you missed. Touches the notification centre only
/// while the preference is on, so nobody who never opts in sees a permission prompt.
@MainActor
final class BackgroundNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Brings the session with this id to the front.
    var openSession: ((UUID) -> Void)?
    private let disabled: Bool
    private var enabled = false
    private var authorized = false

    init(disabled: Bool) {
        self.disabled = disabled
    }

    /// Follows the preference. Turning it on asks for permission; `onDenied` runs when that fails.
    /// At launch pass nil: the saved status is only read, never prompted for or reported.
    func setEnabled(_ on: Bool, onDenied: (@MainActor () -> Void)?) {
        guard !disabled, on != enabled else { return }
        enabled = on
        guard on else { authorized = false; return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            if let onDenied {
                let granted = (try? await center.requestAuthorization(options: [.alert, .badge])) ?? false
                guard enabled else { return }
                authorized = granted
                if !granted { onDenied() }
            } else {
                let status = await center.notificationSettings().authorizationStatus
                guard enabled else { return }
                authorized = status == .authorized || status == .provisional
            }
        }
    }

    func postFinished(sessionID: UUID, title: String, duration: TimeInterval) {
        guard enabled, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "Finished after " + Self.durationText(duration)
        content.userInfo = ["session": sessionID.uuidString]
        let request = UNNotificationRequest(identifier: sessionID.uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        Task { try? await center.add(request) }
    }

    func clear(sessionID: UUID) {
        guard enabled else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [sessionID.uuidString])
    }

    func refreshBadge(count: Int) {
        NSApp.dockTile.badgeLabel = enabled && count > 0 ? String(count) : nil
    }

    static func showDeniedSheet(on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Notifications are off for Lean Term"
        alert.informativeText = "Allow them in System Settings › Notifications, then turn this on again."
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: duration.rounded()) ?? "\(Int(duration)) s"
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["session"] as? String,
              let id = UUID(uuidString: value) else { return }
        await MainActor.run { openSession?(id) }
    }
}
