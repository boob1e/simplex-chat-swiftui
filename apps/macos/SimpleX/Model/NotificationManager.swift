//
//  NotificationManager.swift
//  SimpleX (macOS)
//
//  Local notifications for incoming messages and contact events, and the Dock badge.
//  Notification content comes from the shared iOS builders (SimpleXChat/Notifications.swift),
//  so preview privacy (ntfPreviewModeGroupDefault) works the same way.
//

import AppKit
import UserNotifications
import SimpleXChat

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private var lastSoundTime: [ChatId: Date] = [:]
    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { logger.error("notification authorization: \(error.localizedDescription)") }
            Task { @MainActor in await self.refreshAuthorization() }
        }
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    // MARK: Posting

    func notifyMessage(_ user: User, _ cInfo: ChatInfo, _ cItem: ChatItem) {
        guard cItem.showNotification, cInfo.ntfsEnabled(chatItem: cItem), !ChatStore.shared.isViewing(cInfo.id) else { return }
        post(createMessageReceivedNtf(user, cInfo, cItem, 0), chatId: cInfo.id, id: "\(cInfo.id)/\(cItem.id)")
    }

    func notifyContactConnected(_ user: User, _ contact: Contact) {
        post(createContactConnectedNtf(user, contact, 0), chatId: contact.id, id: "\(contact.id)/connected")
    }

    func notifyContactRequest(_ user: User, _ request: UserContactRequest) {
        post(createContactRequestNtf(user, request, 0), chatId: request.id, id: "\(request.id)/request")
    }

    private func post(_ content: UNMutableNotificationContent, chatId: ChatId, id: String) {
        // Group per chat in Notification Center, and remember the chat so a click opens it.
        content.threadIdentifier = chatId
        content.userInfo["chatId"] = chatId
        content.badge = nil // the Dock badge is managed by updateBadge
        content.sound = shouldPlaySound(chatId) ? .default : nil
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { logger.error("posting notification: \(error.localizedDescription)") }
        }
    }

    /// Like iOS: no repeated sound for a chat within 30 seconds.
    private func shouldPlaySound(_ chatId: ChatId) -> Bool {
        let now = Date.now
        defer { lastSoundTime[chatId] = now }
        if let t = lastSoundTime[chatId] { return now.timeIntervalSince(t) >= 30 }
        return true
    }

    /// Clears a chat's delivered notifications once the user has seen it.
    func removeNotifications(for chatId: ChatId) {
        center.getDeliveredNotifications { notifications in
            let ids = notifications.filter { $0.request.content.threadIdentifier == chatId }.map(\.request.identifier)
            if !ids.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    // MARK: Dock badge

    func updateBadge(_ chats: [ChatData]) {
        let count = chats.reduce(0) { sum, chat in
            let stats = chat.chatStats
            switch chat.chatInfo.chatSettings?.enableNtfs {
            case .some(.none): return sum
            case .some(.mentions): return sum + stats.unreadMentions
            default: return sum + (stats.unreadCount > 0 ? stats.unreadCount : (stats.unreadChat ? 1 : 0))
            }
        }
        let label = count == 0 ? nil : count > 999 ? "999+" : String(count)
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Posting already skipped the chat being viewed and decided on the sound.
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let chatId = response.notification.request.content.userInfo["chatId"] as? String else { return }
        await MainActor.run {
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            ChatStore.shared.selectedChatId = chatId
        }
    }
}
