import AppKit
import SwiftUI
import UserNotifications

struct OrganiserReminder: Equatable {
    let id: String
    let date: Date
    let text: String
    var identifier: String { "organiser-reminder." + id + "." + String(Int(date.timeIntervalSince1970)) }

    static func make(id: String, item: OrganiserItem) -> OrganiserReminder? {
        guard !item.completed, !item.deleted, let value = item.reminder_at else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = parser.date(from: value)
        parser.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? parser.date(from: value) else { return nil }
        let text = item.body_markdown.replacingOccurrences(of: #"^[-*+] \[[ xX]\] "#, with: "", options: .regularExpression)
        return OrganiserReminder(id: id, date: date, text: String(text.prefix(300)))
    }
}

@MainActor
final class OrganiserReminders: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = OrganiserReminders()
    @Published var status = "Enable notifications to receive reminders on this Mac."
    @Published var enabled = UserDefaults.standard.bool(forKey: "organiser.reminders.enabled")
    private let center = UNUserNotificationCenter.current()
    private override init() { super.init(); center.delegate = self }

    func enable() async {
        do {
            enabled = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            UserDefaults.standard.set(enabled, forKey: "organiser.reminders.enabled")
            status = enabled ? "Reminders enabled on this Mac." : "Allow Quick Capture notifications in System Settings → Notifications."
        } catch { status = "Could not enable reminders: " + error.localizedDescription }
    }
    func disable() {
        enabled = false
        UserDefaults.standard.set(false, forKey: "organiser.reminders.enabled")
        center.removeAllPendingNotificationRequests()
        status = "Reminder notifications are off. Reminder dates are still retained."
    }
    func reconcile(outbox: OrganiserOutbox, records: [OrganiserDelivery], now: Date = Date()) async {
        guard enabled else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            status = "Allow Quick Capture notifications in System Settings → Notifications."; return
        }
        do {
            let reminders = try records.compactMap { record -> OrganiserReminder? in
                guard record.conflict == nil else { return nil }
                let item = record.state == "pending" ? try outbox.operation(record).item : try outbox.baseline(record).item
                return OrganiserReminder.make(id: record.id, item: item)
            }.sorted { $0.date < $1.date }
            var notified = UserDefaults.standard.dictionary(forKey: "organiser.reminders.scheduled") as? [String: String] ?? [:]
            let pending = await center.pendingNotificationRequests()
            let pendingIDs = Set(pending.map(\.identifier))
            let wanted = Array(reminders.filter { $0.date > now || notified[$0.id] != $0.identifier || pendingIDs.contains($0.identifier) }.prefix(64))
            let ids = Set(wanted.map(\.identifier))
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("organiser-reminder.") && !ids.contains($0.identifier) }.map(\.identifier))
            for reminder in wanted {
                if let old = pending.first(where: { $0.identifier == reminder.identifier }), old.content.body == reminder.text { continue }
                let content = UNMutableNotificationContent()
                content.title = reminder.date < now ? "Overdue reminder" : "Reminder"
                content.body = reminder.text; content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.date.timeIntervalSince(now)), repeats: false)
                try await center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger))
                notified[reminder.id] = reminder.identifier
                UserDefaults.standard.set(notified, forKey: "organiser.reminders.scheduled")
            }
            status = "Reminders enabled. The next \(wanted.count) reminders are scheduled locally."
        } catch { status = "Could not schedule reminders: " + error.localizedDescription }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            if let endpoint = try? OrganiserOutbox.endpoint(OrganiserController.shared.endpoint), let url = URL(string: endpoint) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

struct OrganiserReminderSettings: View {
    @ObservedObject private var reminders = OrganiserReminders.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REMINDER NOTIFICATIONS").font(.headline)
            Text(reminders.status).font(.caption)
            if reminders.enabled {
                Button("Turn Off Reminder Notifications") { reminders.disable() }
            } else {
                Button("Enable Reminder Notifications") { Task { await reminders.enable() } }
            }
            Text("Reminder times are set in the organiser. Synced reminders can notify you while offline; completed or deleted items cancel their pending notifications after sync.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
