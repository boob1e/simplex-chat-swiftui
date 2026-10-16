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

    private var membership: GroupMember? {
        if case let .group(groupInfo, _) = chat.chatInfo { return groupInfo.membership }
        return nil
    }

    private var rowContext: MessageRowModel.Context {
        MessageRowModel.Context(isGroup: chat.chatInfo.chatType == .group, chatName: chat.chatInfo.chatViewName,
                                membership: membership, highlightedItemId: store.highlightedItemId)
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            MessageList(items: store.items, context: rowContext, scrollRequest: store.scrollRequest,
                        onReachTop: { store.loadOlderItems() },
                        onReachBottom: { store.loadNewerItems() })
            Divider()
            ComposeBar(enabled: chat.chatInfo.sendMsgEnabled, replyTo: $store.replyTo,
                       replySender: { $0.chatDir.sent ? String(localized: "you") : ($0.memberDisplayName ?? chat.chatInfo.chatViewName) }) { text in
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
    @Binding var replyTo: ChatItem?
    let replySender: (ChatItem) -> String
    let send: (String) async throws -> Void

    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let replyTo {
                replyStrip(replyTo)
            }
            inputRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .animation(.easeOut(duration: 0.15), value: replyTo?.id)
        .onChange(of: replyTo?.id) { _, id in if id != nil { focused = true } }
        .onExitCommand { replyTo = nil }
        .onAppear { focused = true }
        .alert("Message not sent", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func replyStrip(_ item: ChatItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(replySender(item))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(plainMessageText(item.text, item.formattedText))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { replyTo = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel reply (Esc)")
        }
        .padding(.horizontal, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var inputRow: some View {
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
