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
    let isGroup: Bool
    let onReachTop: () -> Void

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

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.postsBoundsChangedNotifications = true

        context.coordinator.table = table
        context.coordinator.scrollView = scroll
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onReachTop = onReachTop
        context.coordinator.isGroup = isGroup
        context.coordinator.apply(items)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        weak var scrollView: NSScrollView?
        var onReachTop: () -> Void = {}
        var isGroup = false
        private var rows: [MessageRowModel] = []

        func apply(_ items: [ChatItem]) {
            guard let table else { return }
            let newRows = MessageRowModel.rows(for: items, isGroup: isGroup)
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
            table.noteHeightOfRows(withIndexesChanged: changed)
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
            guard let scrollView, scrollView.contentView.bounds.origin.y < 300, !rows.isEmpty else { return }
            onReachTop()
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

/// Reusable table cell hosting a SwiftUI row.
final class HostingCell: NSTableCellView {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ row: MessageRow) {
        host.rootView = AnyView(row)
    }
}
