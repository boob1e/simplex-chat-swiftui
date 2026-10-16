//
//  ChatListView.swift
//  SimpleX (macOS)
//

import SwiftUI
import SimpleXChat

struct ChatListView: View {
    @Environment(ChatStore.self) private var store
    @Binding var selection: ChatId?
    @State private var search = ""
    @State private var chatToDelete: ChatData?

    private var visibleChats: [ChatData] {
        let chats = store.chats.filter { chat in
            switch chat.chatInfo {
            case .invalidJSON: false
            default: true
            }
        }
        guard !search.isEmpty else { return chats }
        return chats.filter {
            $0.chatInfo.chatViewName.localizedCaseInsensitiveContains(search)
            || $0.chatInfo.fullName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List(visibleChats, selection: $selection) { chat in
            ChatRow(chat: chat)
                .tag(chat.id)
                .contextMenu {
                    Button("Delete Chat…", role: .destructive) { chatToDelete = chat }
                }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .overlay {
            if store.chats.isEmpty {
                ContentUnavailableView("No Chats", systemImage: "bubble.left",
                                       description: Text("Press ⌘N to connect with someone."))
            } else if visibleChats.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .confirmationDialog("Delete this chat?", isPresented: Binding(get: { chatToDelete != nil }, set: { if !$0 { chatToDelete = nil } }),
                            presenting: chatToDelete) { chat in
            Button("Delete", role: .destructive) {
                Task { try? await store.deleteChat(chat) }
            }
        } message: { chat in
            Text("The conversation with \(chat.chatInfo.chatViewName) will be deleted for you and the contact will be notified.")
        }
    }
}

struct ChatRow: View {
    let chat: ChatData

    private var preview: String {
        switch chat.chatInfo {
        case .contactRequest: return String(localized: "Wants to connect with you")
        case .contactConnection: return String(localized: "Waiting for connection…")
        default:
            guard let item = chat.chatItems.last else { return "" }
            return plainMessageText(item.text, item.formattedText)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(image: chat.chatInfo.image, name: chat.chatInfo.chatViewName, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.chatInfo.chatViewName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let ts = chat.chatItems.last?.meta.itemTs {
                        Text(ts, format: Date.relativeChatFormat(ts))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top) {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if chat.chatStats.unreadCount > 0 || chat.chatStats.unreadChat {
                        UnreadBadge(count: chat.chatStats.unreadCount)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 0 ? (count > 999 ? "999+" : "\(count)") : " ")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 18)
            .background(Capsule().fill(.tint))
    }
}

extension Date {
    /// Time for today, weekday for the last week, short date otherwise.
    static func relativeChatFormat(_ date: Date) -> Date.FormatStyle {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .dateTime.hour().minute() }
        if let days = cal.dateComponents([.day], from: date, to: .now).day, days < 7 { return .dateTime.weekday(.abbreviated) }
        return .dateTime.day().month(.abbreviated).year(.twoDigits)
    }
}
