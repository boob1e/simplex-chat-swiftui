//
//  MessageList.swift
//  SimpleX (macOS)
//
//  Message history backed by NSTableView: native scrolling, row reuse and
//  automatic row heights, with each row drawn in SwiftUI.
//

import SwiftUI
import AppKit
import SimpleXChat

struct MessageList: NSViewRepresentable {
    let items: [ChatItem]
    let context: MessageRowModel.Context
    let scrollRequest: ChatStore.ScrollRequest?
    let onReachTop: () -> Void
    let onReachBottom: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.usesAutomaticRowHeights = true
        table.style = .plain
        table.allowsColumnSelection = false
        let column = NSTableColumn(identifier: .init("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = MessageScrollView()
        scroll.documentView = table
        scroll.horizontalScrollElasticity = .none
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.postsBoundsChangedNotifications = true

        context.coordinator.table = table
        context.coordinator.scrollView = scroll
        context.coordinator.swipe.table = table
        scroll.swipeTracker = context.coordinator.swipe
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onReachTop = onReachTop
        context.coordinator.onReachBottom = onReachBottom
        context.coordinator.context = self.context
        context.coordinator.apply(items)
        context.coordinator.handle(scrollRequest)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        weak var scrollView: NSScrollView?
        var onReachTop: () -> Void = {}
        var onReachBottom: () -> Void = {}
        var context = MessageRowModel.Context(isGroup: false, chatName: "", membership: nil, highlightedItemId: nil)
        private var rows: [MessageRowModel] = []
        private var lastScrollRequest: ChatStore.ScrollRequest?
        let swipe = SwipeTracker()

        override init() {
            super.init()
            swipe.canReply = { [unowned self] row in row < rows.count && rows[row].canReply }
            swipe.onReply = { [unowned self] row in
                guard row < rows.count else { return }
                ChatStore.shared.replyTo = rows[row].item
            }
        }

        func handle(_ request: ChatStore.ScrollRequest?) {
            guard let request, request != lastScrollRequest, let table,
                  let row = rows.firstIndex(where: { $0.id == request.itemId }) else { return }
            lastScrollRequest = request
            table.layoutSubtreeIfNeeded()
            // Center the item rather than leaving it at the edge.
            let rect = table.rect(ofRow: row)
            let visible = scrollView?.contentView.bounds.height ?? 0
            let y = max(0, min(rect.midY - visible / 2, table.bounds.height - visible))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                scrollView?.contentView.scroll(to: NSPoint(x: 0, y: y))
            }
            scrollView.map { $0.reflectScrolledClipView($0.contentView) }
        }

        func apply(_ items: [ChatItem]) {
            guard let table else { return }
            let newRows = MessageRowModel.rows(for: items, context)
            let old = rows
            guard newRows != old else { return }
            let wasAtBottom = isAtBottom
            rows = newRows

            if !old.isEmpty, newRows.count > old.count, Array(newRows.prefix(old.count)).map(\.id) == old.map(\.id) {
                // New messages at the end
                table.insertRows(at: IndexSet(old.count..<newRows.count), withAnimation: .effectFade)
                reloadChanged(old: old, upTo: old.count)
                if wasAtBottom || newRows.last?.item.chatDir.sent == true { scrollToBottom(animated: true) }
            } else if !old.isEmpty, newRows.count > old.count, Array(newRows.suffix(old.count)).map(\.id) == old.map(\.id) {
                // Older messages loaded at the top: keep the visible content where it is
                let distanceFromBottom = table.bounds.height - (scrollView?.contentView.bounds.origin.y ?? 0)
                table.insertRows(at: IndexSet(0..<(newRows.count - old.count)), withAnimation: [])
                table.layoutSubtreeIfNeeded()
                scrollView?.contentView.scroll(to: NSPoint(x: 0, y: table.bounds.height - distanceFromBottom))
                scrollView.map { $0.reflectScrolledClipView($0.contentView) }
            } else if newRows.count == old.count, newRows.map(\.id) == old.map(\.id) {
                reloadChanged(old: old, upTo: old.count)
            } else {
                table.reloadData()
                if old.isEmpty || wasAtBottom { scrollToBottom(animated: false) }
            }
        }

        private func reloadChanged(old: [MessageRowModel], upTo count: Int) {
            guard let table else { return }
            let changed = IndexSet((0..<count).filter { rows[$0] != old[$0] })
            guard !changed.isEmpty else { return }
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            // The hosted SwiftUI rows only report their new size after their next layout pass,
            // so measure on the next turn of the run loop; measuring now gets the old height.
            DispatchQueue.main.async { [weak table] in
                guard let table else { return }
                let rows = IndexSet(changed.filter { $0 < table.numberOfRows })
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    table.noteHeightOfRows(withIndexesChanged: rows)
                }
            }
        }

        private var isAtBottom: Bool {
            guard let scrollView, let doc = scrollView.documentView else { return true }
            let visible = scrollView.contentView.bounds
            return doc.bounds.height - visible.maxY < 60
        }

        private func scrollToBottom(animated: Bool) {
            guard let table, !rows.isEmpty else { return }
            table.layoutSubtreeIfNeeded()
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    ctx.allowsImplicitAnimation = true
                    table.scrollRowToVisible(rows.count - 1)
                }
            } else {
                table.scrollRowToVisible(rows.count - 1)
            }
        }

        @objc func boundsChanged() {
            guard let scrollView, let doc = scrollView.documentView, !rows.isEmpty else { return }
            let visible = scrollView.contentView.bounds
            if visible.origin.y < 300 { onReachTop() }
            if doc.bounds.height - visible.maxY < 300 { onReachBottom() }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("MessageCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? HostingCell) ?? HostingCell(identifier: id)
            cell.set(MessageRow(model: rows[row]))
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    }
}

/// Reusable table cell hosting a SwiftUI row. It can slide left for swipe-to-reply.
final class HostingCell: NSTableCellView {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let replyIcon = NSImageView()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var armed = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false

        replyIcon.image = NSImage(systemSymbolName: "arrowshape.turn.up.left.circle.fill", accessibilityDescription: "Reply")
        replyIcon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        replyIcon.contentTintColor = .secondaryLabelColor
        replyIcon.translatesAutoresizingMaskIntoConstraints = false
        replyIcon.wantsLayer = true
        replyIcon.alphaValue = 0

        addSubview(replyIcon)
        addSubview(host)
        leading = host.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailing = host.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            leading, trailing,
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            replyIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            replyIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ row: MessageRow) {
        host.rootView = AnyView(row)
        host.invalidateIntrinsicContentSize()
        resetSwipe()
    }

    func setSwipe(offset: CGFloat, armed: Bool) {
        if spring != nil {
            spring?.invalidate()
            spring = nil
            springStart = nil
        }
        leading.constant = -offset
        trailing.constant = -offset
        let progress = min(1, offset / SwipeTracker.threshold)
        replyIcon.alphaValue = progress
        let scale = 0.5 + 0.5 * progress
        replyIcon.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        if armed != self.armed {
            self.armed = armed
            replyIcon.contentTintColor = armed ? .controlAccentColor : .secondaryLabelColor
        }
    }

    private var spring: CADisplayLink?
    private var springStart: (offset: CGFloat, time: CFTimeInterval)?

    /// Springs back with an underdamped spring, so the bubble overshoots and settles (the wiggle).
    func endSwipe() {
        springStart = (-leading.constant, CACurrentMediaTime())
        spring?.invalidate()
        spring = displayLink(target: self, selector: #selector(springStep))
        spring?.add(to: .main, forMode: .common)
    }

    @objc private func springStep(_ link: CADisplayLink) {
        guard let start = springStart else { return link.invalidate() }
        let t = CACurrentMediaTime() - start.time
        // x(t) = x0 * e^(-zeta*w*t) * cos(wd*t)
        let w = 22.0, zeta = 0.42
        let wd = w * (1 - zeta * zeta).squareRoot()
        let x = start.offset * exp(-zeta * w * t) * cos(wd * t)
        if t > 0.6 || (abs(x) < 0.3 && t > 0.15) {
            link.invalidate()
            spring = nil
            springStart = nil
            resetSwipe()
            return
        }
        leading.constant = -x
        trailing.constant = -x
        replyIcon.alphaValue = max(0, min(1, x / SwipeTracker.threshold))
    }

    private func resetSwipe() {
        spring?.invalidate()
        spring = nil
        springStart = nil
        leading.constant = 0
        trailing.constant = 0
        replyIcon.alphaValue = 0
        replyIcon.layer?.setAffineTransform(.identity)
        armed = false
        replyIcon.contentTintColor = .secondaryLabelColor
    }
}
