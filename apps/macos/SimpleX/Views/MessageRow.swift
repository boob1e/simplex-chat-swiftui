//
//  MessageRow.swift
//  SimpleX (macOS)
//

import SwiftUI
import SimpleXChat

/// Everything a row needs to draw itself, so the table can diff rows cheaply.
struct MessageRowModel: Equatable, Identifiable {
    let item: ChatItem
    /// Sender name above the first message of a run in a group.
    let senderName: String?
    let senderImage: String?
    /// Day header before the first message of each day.
    let dayHeader: Date?
    /// Last message in a run from the same sender: shows the avatar and a bubble tail.
    let endsRun: Bool
    let isGroup: Bool
    /// The user's member ID in a group, to highlight mentions of the user.
    let userMemberId: String?

    var id: Int64 { item.id }

    static func rows(for items: [ChatItem], isGroup: Bool, userMemberId: String?) -> [MessageRowModel] {
        let cal = Calendar.current
        return items.indices.map { i in
            let item = items[i]
            let prev = i > 0 ? items[i - 1] : nil
            let next = i + 1 < items.count ? items[i + 1] : nil
            let newDay = prev.map { !cal.isDate($0.meta.itemTs, inSameDayAs: item.meta.itemTs) } ?? true
            let member = Self.member(item)
            let startsRun = newDay || prev.map { Self.member($0)?.groupMemberId != member?.groupMemberId || $0.chatDir.sent != item.chatDir.sent } ?? true
            let endsRun = next.map {
                !cal.isDate($0.meta.itemTs, inSameDayAs: item.meta.itemTs)
                || Self.member($0)?.groupMemberId != member?.groupMemberId
                || $0.chatDir.sent != item.chatDir.sent
            } ?? true
            return MessageRowModel(
                item: item,
                senderName: isGroup && startsRun ? member?.chatViewName : nil,
                senderImage: member?.image,
                dayHeader: newDay ? item.meta.itemTs : nil,
                endsRun: endsRun,
                isGroup: isGroup,
                userMemberId: userMemberId
            )
        }
    }

    private static func member(_ item: ChatItem) -> GroupMember? {
        if case let .groupRcv(m) = item.chatDir { return m }
        return nil
    }
}

struct MessageRow: View {
    let model: MessageRowModel
    @State private var revealedSecrets: Set<Int> = []
    @Environment(\.openURL) private var openURL

    private var item: ChatItem { model.item }
    private var sent: Bool { item.chatDir.sent }

    var body: some View {
        VStack(spacing: 6) {
            if let day = model.dayHeader {
                Text(day, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
            }
            if isEvent {
                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            } else {
                bubbleRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, model.endsRun ? 6 : 0)
        // Table cells are reused, so per-message state must not carry over to another message.
        .id(model.id)
    }

    /// Group events, connection events and similar service items render as centered captions.
    private var isEvent: Bool {
        switch item.content {
        case .sndMsgContent, .rcvMsgContent: false
        case .sndDeleted, .rcvDeleted: false
        default: true
        }
    }

    private var bubbleRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if sent { Spacer(minLength: 60) }
            if model.isGroup && !sent {
                Group {
                    if model.endsRun {
                        AvatarView(image: model.senderImage, name: model.senderName ?? "", size: 26)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 26, height: 26)
            }
            VStack(alignment: sent ? .trailing : .leading, spacing: 2) {
                if let name = model.senderName {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                }
                bubble
            }
            if !sent { Spacer(minLength: 60) }
        }
    }

    private var bubble: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(messageText)
                .font(.body)
                .textSelection(.enabled)
                .foregroundStyle(sent ? Color.white : Color.primary)
                .tint(sent ? .white : .accentColor)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == MessageLink.secretScheme, let i = url.host().flatMap(Int.init) {
                        revealedSecrets.formSymmetricDifference([i])
                        return .handled
                    }
                    if let uri = MessageLink.connectUri(url) {
                        ChatStore.shared.pendingConnectLink = .init(uri: uri)
                        return .handled
                    }
                    openURL(url)
                    return .handled
                })
            HStack(spacing: 3) {
                if item.meta.itemEdited { Text("edited") }
                Text(item.meta.itemTs, format: .dateTime.hour().minute())
                if sent, let icon = statusIcon { Image(systemName: icon) }
            }
            .font(.caption2)
            .foregroundStyle(sent ? Color.white.opacity(0.75) : Color.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(sent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(nsColor: .unemphasizedSelectedContentBackgroundColor)))
        )
        .frame(maxWidth: 560, alignment: sent ? .trailing : .leading)
    }

    private var messageText: AttributedString {
        if item.isDeletedContent {
            var s = AttributedString(String(localized: "message deleted"))
            s.inlinePresentationIntent = .emphasized
            return s
        }
        return formattedMessage(item.text, item.formattedText, style: MessageTextStyle(
            onAccent: sent,
            revealedSecrets: revealedSecrets,
            mentions: item.mentions,
            userMemberId: model.userMemberId
        ))
    }

    private var statusIcon: String? {
        switch item.meta.itemStatus {
        case .sndNew: "clock"
        case .sndSent: "checkmark"
        case .sndRcvd: "checkmark.circle"
        case .sndErrorAuth, .sndError: "exclamationmark.circle"
        case .sndWarning: "exclamationmark.triangle"
        default: nil
        }
    }
}
