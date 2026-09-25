import Foundation
import UserNotifications
import MacBenchCore

/// Notifications are rationed on purpose.
///
/// Two kinds get through: a message a person addressed to you, and an iCloud
/// conflict copy. Everything else waits quietly in the counter, because the
/// fastest way to make this app useless is to make it interrupt.
@MainActor
final class Notifier {
    private var isAuthorised = false
    private var announcedConflicts: Set<String> = []

    func requestAuthorisation() async {
        let center = UNUserNotificationCenter.current()
        isAuthorised = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func announce(_ items: [TimelineItem], projects: [Project]) async {
        guard isAuthorised else { return }
        for item in items {
            let project = projects.first { $0.id == item.entry.projectID }?.name ?? ""
            let content = UNMutableNotificationContent()
            content.title = item.author?.name ?? String(localized: "New message")
            content.subtitle = project
            content.body = item.entry.isTask
                ? String(localized: "Task: \(item.entry.text)")
                : item.entry.text
            content.sound = .default
            content.userInfo = ["entry": item.entry.id.uuidString]
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: item.entry.id.uuidString,
                                      content: content, trigger: nil))
        }
    }

    /// The single exception to "system entries never notify". A conflict copy is
    /// created silently by iCloud and is typically discovered weeks later, when
    /// whichever version lost is long forgotten.
    func announceConflicts(_ paths: [String], project: String) async {
        guard isAuthorised else { return }
        for path in paths where !announcedConflicts.contains(path) {
            announcedConflicts.insert(path)
            let content = UNMutableNotificationContent()
            content.title = String(localized: "iCloud made a conflict copy")
            content.subtitle = project
            content.body = String(localized: "\(path) — you both saved it at the same time. Open the folder and keep the version you want.")
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "conflict-" + path, content: content, trigger: nil))
        }
    }
}
