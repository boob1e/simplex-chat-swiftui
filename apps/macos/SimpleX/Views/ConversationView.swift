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
            ComposeBar(enabled: chat.chatInfo.sendMsgEnabled, replyTo: $store.replyTo, editing: $store.editing,
                       replySender: { $0.chatDir.sent ? String(localized: "you") : ($0.memberDisplayName ?? chat.chatInfo.chatViewName) },
                       onEditLast: { store.editLastMessage() }) { text in
                try await store.send(text)
            }
        }
        .navigationTitle(chat.chatInfo.chatViewName)
        .navigationSubtitle(subtitle)
        .background(Color(nsColor: .textBackgroundColor))
        .confirmationDialog("Delete message?", isPresented: Binding(get: { store.deleting != nil }, set: { if !$0 { store.deleting = nil } }),
                            titleVisibility: .visible, presenting: store.deleting) { item in
            Button("Delete for Me", role: .destructive) { delete(item, .cidmInternal) }
            if item.chatDir.sent && item.meta.deletable {
                Button("Delete for Everyone", role: .destructive) { delete(item, .cidmBroadcast) }
            }
        } message: { item in
            Text(item.chatDir.sent && item.meta.deletable
                 ? "Deleting for everyone removes the message from \(chat.chatInfo.chatViewName)'s device too."
                 : "The message will be deleted from this Mac only.")
        }
        .alert("Message not deleted", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    @State private var deleteError: String?

    private func delete(_ item: ChatItem, _ mode: CIDeleteMode) {
        Task {
            do {
                try await store.delete(item, mode: mode)
            } catch {
                deleteError = responseError(error)
            }
        }
    }
}

struct ComposeBar: View {
    let enabled: Bool
    @Binding var replyTo: ChatItem?
    @Binding var editing: ChatItem?
    let replySender: (ChatItem) -> String
    let onEditLast: () -> Void
    let send: (String) async throws -> Void

    @State private var text = ""
    /// What was typed before editing started, restored afterwards.
    @State private var draftBeforeEdit = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let editing {
                strip(icon: "pencil", title: "Editing message", item: editing, cancelHelp: "Cancel editing (Esc)") { self.editing = nil }
            } else if let replyTo {
                strip(icon: "arrowshape.turn.up.left.fill", title: "Replying to \(replySender(replyTo))", item: replyTo,
                      cancelHelp: "Cancel reply (Esc)") { self.replyTo = nil }
            }
            inputRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .animation(.easeOut(duration: 0.15), value: replyTo?.id)
        .animation(.easeOut(duration: 0.15), value: editing?.id)
        .onChange(of: replyTo?.id) { _, id in if id != nil { focused = true } }
        .onChange(of: editing?.id) { old, new in
            if old == nil, new != nil { draftBeforeEdit = text }
            if let editing {
                text = editing.content.msgContent?.text ?? editing.text
                focused = true
            } else {
                text = draftBeforeEdit
                draftBeforeEdit = ""
            }
        }
        .onExitCommand {
            if editing != nil { editing = nil } else { replyTo = nil }
        }
        .onAppear { focused = true }
        .alert(editing == nil ? "Message not sent" : "Message not saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func strip(icon: String, title: String, item: ChatItem, cancelHelp: LocalizedStringKey, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(plainMessageText(item.text, item.formattedText))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(cancelHelp)
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
                .onKeyPress(.upArrow) {
                    guard text.isEmpty, editing == nil else { return .ignored }
                    onEditLast()
                    return .handled
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))

            Button(action: submit) {
                Image(systemName: editing == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(trimmed.isEmpty ? Color.secondary : Color.accentColor)
            .disabled(trimmed.isEmpty || sending || !enabled)
            .keyboardShortcut(.return, modifiers: .command)
            .help(editing == nil ? "Send (Return)" : "Save (Return)")
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
