//
//  ConversationView.swift
//  SimpleX (macOS)
//

import SwiftUI
import SimpleXChat

struct ConversationView: View {
    @Environment(ChatStore.self) private var store
    let chat: ChatData

    private var subtitle: String {
        switch chat.chatInfo {
        case let .direct(contact):
            if contact.ready { return contact.profile.fullName }
            return String(localized: "Connecting…")
        case let .group(groupInfo, _):
            return groupInfo.groupProfile.fullName
        case .contactConnection:
            return String(localized: "Waiting for the other side to connect")
        default:
            return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MessageList(items: store.items, isGroup: chat.chatInfo.chatType == .group,
                        onReachTop: { store.loadOlderItems() })
            Divider()
            ComposeBar(enabled: chat.chatInfo.sendMsgEnabled) { text in
                try await store.send(text)
            }
        }
        .navigationTitle(chat.chatInfo.chatViewName)
        .navigationSubtitle(subtitle)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct ComposeBar: View {
    let enabled: Bool
    let send: (String) async throws -> Void

    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(enabled ? "Message" : "You can't send messages yet", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .disabled(!enabled)
                .onSubmit(submit)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(trimmed.isEmpty ? Color.secondary : Color.accentColor)
            .disabled(trimmed.isEmpty || sending || !enabled)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (Return)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .onAppear { focused = true }
        .alert("Message not sent", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    /// Return sends; Option-Return inserts a newline (handled by the vertical TextField).
    private func submit() {
        let msg = trimmed
        guard !msg.isEmpty, !sending, enabled else { return }
        sending = true
        text = ""
        Task {
            defer { sending = false }
            do {
                try await send(msg)
            } catch {
                text = msg
                self.error = responseError(error)
            }
        }
    }
}
