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
    /// Who wrote the quoted message, when this message is a reply.
    let quoteSender: String?
    let highlighted: Bool
    let reactionsEnabled: Bool

    var id: Int64 { item.id }

    var canReply: Bool {
        switch item.content {
        case .sndMsgContent, .rcvMsgContent: !item.isDeletedContent && item.meta.itemDeleted == nil
        default: false
        }
    }

    struct Context {
        let isGroup: Bool
        /// Reactions are allowed by the chat's preferences.
        var reactionsEnabled = false
        let chatName: String
        let membership: GroupMember?
        let highlightedItemId: Int64?
    }

    static func rows(for items: [ChatItem], _ ctx: Context) -> [MessageRowModel] {
        let isGroup = ctx.isGroup
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
                userMemberId: ctx.membership?.memberId,
                quoteSender: item.quotedItem.map { $0.getSender(ctx.membership) ?? ctx.chatName },
                highlighted: item.id == ctx.highlightedItemId,
                reactionsEnabled: ctx.reactionsEnabled
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
                    .contextMenu { contextMenu }
                    .scaleEffect(model.highlighted ? 1.03 : 1)
                    .shadow(color: .accentColor.opacity(model.highlighted ? 0.6 : 0), radius: 8)
                    .animation(.spring(duration: 0.3), value: model.highlighted)
                if !item.reactions.isEmpty {
                    ReactionPills(reactions: item.reactions, canToggle: model.reactionsEnabled) { reaction in
                        ChatStore.shared.toggleReaction(reaction, on: item)
                    }
                    .frame(maxWidth: 560, alignment: sent ? .trailing : .leading)
                }
            }
            .layoutPriority(1)
            if !sent { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if model.reactionsEnabled && model.canReply && (item.allowAddReaction || item.reactions.contains(where: \.userReacted)) {
            Menu("React") {
                ForEach(MREmojiChar.allCases, id: \.self) { emoji in
                    let reaction = MsgReaction.emoji(emoji: emoji)
                    let reacted = item.reactions.contains { $0.reaction == reaction && $0.userReacted }
                    Toggle(isOn: Binding(get: { reacted }, set: { _ in ChatStore.shared.toggleReaction(reaction, on: item) })) {
                        Text(reaction.text)
                    }
                    .disabled(!reacted && !item.allowAddReaction)
                }
            }
            Divider()
        }
        if model.canReply {
            Button("Reply") { ChatStore.shared.replyTo = item }
        }
        if ChatStore.canEdit(item) {
            Button("Edit") { ChatStore.shared.editing = item }
        }
        if let file = item.file, !isDeleted, loadedFileSource(file) != nil {
            Button("Quick Look") { ChatStore.shared.quickLook(item) }
            Button("Save As…") { ChatStore.shared.saveFileAs(item) }
        }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(plainMessageText(item.text, item.formattedText), forType: .string)
        }
        .disabled(item.isDeletedContent)
        if item.canBeDeletedForSelf {
            Divider()
            Button("Delete…", role: .destructive) { ChatStore.shared.deleting = item }
        }
    }

    private var bubble: some View {
        BubbleStack(spacing: 2) {
            if let quote = item.quotedItem {
                QuoteView(quote: quote, sender: model.quoteSender, onAccent: sent)
                    .onTapGesture {
                        if let id = quote.itemId { ChatStore.shared.jump(to: id) }
                    }
                    // A long quote truncates rather than widening the bubble past this.
                    .layoutValue(key: BubbleStack.WidthCap.self, value: 300)
            }
            if !isDeleted, let file = item.file {
                attachmentView(file)
                    .padding(.top, item.quotedItem == nil ? 2 : 4)
                    .padding(.bottom, hasCaption ? 4 : 0)
            }
            if hasCaption || isDeleted || item.file == nil {
                Text(messageText)
                    .font(.body)
                    .textSelection(.enabled)
                    .foregroundStyle(sent ? Color.white : Color.primary)
                    .tint(sent ? .white : .accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            }
            HStack(spacing: 3) {
                if item.meta.itemEdited { Text("edited") }
                Text(item.meta.itemTs, format: .dateTime.hour().minute())
                if sent, let icon = statusIcon { Image(systemName: icon) }
            }
            .font(.caption2)
            .foregroundStyle(sent ? Color.white.opacity(0.75) : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(sent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(nsColor: .unemphasizedSelectedContentBackgroundColor)))
        )
        .frame(maxWidth: 560, alignment: sent ? .trailing : .leading)
    }

    private var isDeleted: Bool { item.isDeletedContent || item.meta.itemDeleted != nil }

    private var hasCaption: Bool { !(item.content.msgContent?.text ?? item.text).isEmpty }

    @ViewBuilder
    private func attachmentView(_ file: CIFile) -> some View {
        switch item.content.msgContent {
        case let .image(_, preview):
            MessageMediaView(item: item, file: file, preview: preview)
        case let .video(_, preview, _):
            MessageMediaView(item: item, file: file, preview: preview, isVideo: true)
        default:
            FileRowView(item: item, file: file, onAccent: sent)
        }
    }

    private var messageText: AttributedString {
        if isDeleted {
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

/// Reaction counts under a bubble. The user's own reactions are tinted, and clicking toggles them.
struct ReactionPills: View {
    let reactions: [CIReactionCount]
    let canToggle: Bool
    let toggle: (MsgReaction) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(reactions, id: \.reaction) { r in
                Button { toggle(r.reaction) } label: {
                    HStack(spacing: 3) {
                        Text(r.reaction.text)
                        if r.totalReacted > 1 {
                            Text("\(r.totalReacted)").monospacedDigit()
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(r.userReacted ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07)))
                    .overlay(Capsule().strokeBorder(r.userReacted ? Color.accentColor.opacity(0.7) : Color.clear))
                }
                .buttonStyle(.plain)
                .disabled(!canToggle)
                .help(r.userReacted ? "Remove your reaction" : "React with \(r.reaction.text)")
                .fixedSize()
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Lays children out left to right, wrapping to a new line when the available width runs out.
/// Unlike an HStack it never squeezes children, so a short bubble can't hide reactions.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty && needed > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Stacks bubble content vertically at the width of its widest child (up to the available width),
/// and gives every child that width. So a quote fills the bubble without stretching it,
/// and long text still wraps at the maximum bubble width.
struct BubbleStack: Layout {
    var spacing: CGFloat = 0

    /// Limits how much a child's natural width can widen the bubble.
    struct WidthCap: LayoutValueKey {
        static let defaultValue: CGFloat = .infinity
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = contentWidth(proposal, subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let p = ProposedViewSize(width: bounds.width, height: nil)
            let h = subview.sizeThatFits(p).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
            y += h + spacing
        }
    }

    private func contentWidth(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let available = proposal.width ?? .infinity
        let natural = subviews.map { min($0.sizeThatFits(.unspecified).width, $0[WidthCap.self]) }.max() ?? 0
        return min(natural, available)
    }
}

/// The quoted message shown at the top of a reply bubble, and above the message box while replying.
struct QuoteView: View {
    let quote: CIQuote
    let sender: String?
    var onAccent = false

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(onAccent ? Color.white.opacity(0.8) : Color.accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                if let sender {
                    Text(sender)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(onAccent ? Color.white : Color.accentColor)
                }
                Text(plainMessageText(quote.text, quote.formattedText))
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(onAccent ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(onAccent ? Color.white.opacity(0.18) : Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
    }
}
