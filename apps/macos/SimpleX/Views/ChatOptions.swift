//
//  ChatOptions.swift
//  SimpleX (macOS)
//
//  Per-chat options shared by the sidebar context menu and the conversation toolbar.
//

import SwiftUI
import SimpleXChat

/// Notification mode and Clear History, as menu items.
struct ChatOptionsMenuItems: View {
    @Environment(ChatStore.self) private var store
    let chat: ChatData

    var body: some View {
        if let mode = chat.chatInfo.chatSettings?.enableNtfs {
            Picker("Notifications", selection: Binding(get: { mode }, set: { setMode($0) })) {
                Text("All Messages").tag(MsgFilter.all)
                if chat.chatInfo.hasMentions {
                    Text("Mentions Only").tag(MsgFilter.mentions)
                }
                Text("Off").tag(MsgFilter.none)
            }
            .pickerStyle(.inline)
            Divider()
        }
        if canClear {
            Button("Clear History…") { store.chatToClear = chat }
        }
    }

    private var canClear: Bool {
        switch chat.chatInfo {
        case .direct, .group, .local: true
        default: false
        }
    }

    private func setMode(_ mode: MsgFilter) {
        Task {
            do {
                try await store.setNotifications(chat, mode)
            } catch {
                logger.error("setting notifications: \(responseError(error))")
            }
        }
    }
}

extension ChatInfo {
    /// Notifications are off or limited to mentions.
    var isMuted: Bool {
        switch chatSettings?.enableNtfs {
        case .some(.none), .some(.mentions): true
        default: false
        }
    }
}

/// Confirmation for clearing a chat's history, attached once to the main window.
struct ClearChatConfirmation: ViewModifier {
    @Environment(ChatStore.self) private var store
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Clear chat history?", isPresented: Binding(get: { store.chatToClear != nil }, set: { if !$0 { store.chatToClear = nil } }),
                                titleVisibility: .visible, presenting: store.chatToClear) { chat in
                Button("Clear History", role: .destructive) { clear(chat) }
            } message: { chat in
                Text("All messages with \(chat.chatInfo.chatViewName) will be deleted from this Mac. This can't be undone. The contact keeps their copy.")
            }
            .alert("History not cleared", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: {
                Text(error ?? "")
            }
    }

    private func clear(_ chat: ChatData) {
        Task {
            do {
                try await store.clearChat(chat)
            } catch {
                self.error = responseError(error)
            }
        }
    }
}
