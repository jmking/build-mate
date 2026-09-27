import SwiftUI
import UserNotifications

@MainActor
final class AttentionNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let receiptURL: URL
    private var seen: Set<String>
    private var delivering = false
    var open: ((String, UUID) -> Void)?
    init(root: URL) {
        receiptURL = root.appending(path: "notification-receipts.json")
        seen = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: receiptURL))) ?? []
        super.init()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "needs-you", actions: [UNNotificationAction(identifier: "open", title: "Open", options: .foreground)], intentIdentifiers: [])])
    }
    func update(_ items: [AttentionItem]) async {
        guard !delivering else { return }
        delivering = true; defer { delivering = false }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for item in items where !seen.contains(item.id) {
            let content = UNMutableNotificationContent()
            content.title = item.title; content.body = item.detail
            content.threadIdentifier = item.projectID.uuidString; content.categoryIdentifier = "needs-you"
            content.userInfo = ["owner": item.ownerID.uuidString, "type": item.ownerType]
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
                seen.insert(item.id)
                try JSONEncoder().encode(seen).write(to: receiptURL, options: .atomic)
            } catch { return } // Retry next refresh; never mark a failed delivery as sent.
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = info["owner"] as? String, let owner = UUID(uuidString: id), let type = info["type"] as? String else { return }
        await MainActor.run { self.open?(type, owner) }
    }
}

struct NotificationSettings: View {
    @State private var allowed = false
    @State private var error: String?
    var body: some View {
        HStack {
            Text(allowed ? "Needs You notifications enabled" : "Needs You notifications disabled")
            Spacer()
            Button(allowed ? "System Settings…" : "Enable…") {
                Task {
                    do {
                        let center = UNUserNotificationCenter.current()
                        let status = await center.notificationSettings().authorizationStatus
                        if status == .notDetermined { allowed = try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
                        else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
                    } catch { self.error = error.localizedDescription }
                }
            }.help("Manage notifications for questions, approvals, review and errors; macOS Focus settings are respected")
        }.task { await refreshPermission() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await refreshPermission() }
            }
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
    private func refreshPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        allowed = status == .authorized || status == .provisional
    }
}
