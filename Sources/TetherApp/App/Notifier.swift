import AppKit
import UserNotifications
import SessionKit

/// Turns notifications from terminal programs (OSC 9/777/99, the bell) into macOS notifications
/// when their tab is not being looked at. Clicking one brings that tab to the front.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var lastPosted: [UUID: Date] = [:]
    private var authorized: Bool?

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// A program asked for attention in `session`.
    func attention(_ attention: TerminalSession.Attention, in session: TerminalSession) {
        let settings = AppModel.shared.settings
        switch attention {
        case .message: guard settings.notifyFromPrograms else { session.clearAttention(); return }
        case .bell: guard settings.notifyOnBell else { session.clearAttention(); return }
        }
        // The tab is in front of the user: nothing to tell.
        if session.isOnScreen, NSApp.isActive, NSApp.keyWindow != nil {
            session.clearAttention()
            return
        }
        // A burst (a bell after a message, a chatty program) is one notification.
        if let last = lastPosted[session.id], Date().timeIntervalSince(last) < 3 { return }
        lastPosted[session.id] = Date()
        let content = UNMutableNotificationContent()
        let host = session.descriptor.target.displayName
        switch attention {
        case .message(let n):
            content.title = n.title ?? session.displayTitle
            content.subtitle = n.title == nil ? host : "\(session.displayTitle) — \(host)"
            content.body = n.body
        case .bell:
            content.title = session.displayTitle
            content.subtitle = host
            content.body = "Wants your attention (bell)"
        }
        content.sound = .default
        content.threadIdentifier = session.id.uuidString
        content.userInfo = ["session": session.id.uuidString]
        Task {
            let center = UNUserNotificationCenter.current()
            if authorized == nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            }
            guard authorized == true else { return }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// The tab was looked at: its notifications are no longer news.
    func seen(_ session: TerminalSession) {
        session.clearAttention()
        let thread = session.id.uuidString
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == thread }.map(\.request.identifier)
            if !ids.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["session"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            if let id { Self.bringToFront(id) }
            completionHandler()
        }
    }

    /// Shown even while Tether is active (the tab may be in the background or another window).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    private static func bringToFront(_ id: UUID) {
        let model = AppModel.shared
        NSApp.activate()
        guard let session = model.sessions.session(id) else { return }
        if !model.workspaces.focus(id), let state = model.workspaces.frontState {
            state.show(session)
        }
    }
}
