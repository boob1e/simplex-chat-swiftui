//
//  SwipeToReply.swift
//  SimpleX (macOS)
//
//  Two-finger trackpad swipe to the left on a message starts a reply.
//

import AppKit

/// Scroll view that lets a horizontal trackpad swipe over a message drive swipe-to-reply,
/// while vertical scrolling behaves as usual.
final class MessageScrollView: NSScrollView {
    weak var swipeTracker: SwipeTracker?

    override func scrollWheel(with event: NSEvent) {
        guard let swipeTracker else { return super.scrollWheel(with: event) }
        for e in swipeTracker.handle(event) { super.scrollWheel(with: e) }
    }
}

@MainActor
final class SwipeTracker {
    /// Distance at which releasing starts a reply.
    static let threshold: CGFloat = 60
    private static let maxOffset: CGFloat = 110

    weak var table: NSTableView?
    var canReply: (Int) -> Bool = { _ in false }
    var onReply: (Int) -> Void = { _ in }

    private enum State {
        case idle
        /// Gesture started, direction not known yet. Events are held back until it is.
        case undecided(row: Int?, dx: CGFloat, dy: CGFloat, held: [NSEvent])
        case swiping(row: Int, travel: CGFloat, armed: Bool)
        /// Vertical scroll, passed through until the gesture ends.
        case scrolling
        /// The swipe ended; its momentum events are swallowed.
        case afterSwipe
    }

    private var state: State = .idle

    /// Returns the events the scroll view should still handle itself.
    func handle(_ event: NSEvent) -> [NSEvent] {
        // Mouse wheels have no phases or precise deltas; they only scroll.
        guard event.hasPreciseScrollingDeltas else { return [event] }

        if event.momentumPhase != [] {
            if case .afterSwipe = state {
                if event.momentumPhase == .ended || event.momentumPhase == .cancelled { state = .idle }
                return []
            }
            return [event]
        }

        switch (event.phase, state) {
        case (.began, _):
            state = .undecided(row: row(at: event), dx: 0, dy: 0, held: [event])
            return []

        case let (.changed, .undecided(row, dx, dy, held)):
            let dx = dx + event.scrollingDeltaX
            let dy = dy + event.scrollingDeltaY
            if abs(dx) > 6, abs(dx) > abs(dy) * 1.5, dx < 0, let row, canReply(row) {
                state = .swiping(row: row, travel: 0, armed: false)
                return handle(event)
            }
            if abs(dx) > 6 || abs(dy) > 6 {
                state = .scrolling
                return held + [event]
            }
            state = .undecided(row: row, dx: dx, dy: dy, held: held + [event])
            return []

        case let (.changed, .swiping(row, travel, armed)):
            let travel = min(0, travel + event.scrollingDeltaX)
            let armedNow = -travel >= Self.threshold
            if armedNow && !armed {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            state = .swiping(row: row, travel: travel, armed: armedNow)
            cell(row)?.setSwipe(offset: Self.rubberBand(-travel), armed: armedNow)
            return []

        case let (.ended, .swiping(row, _, armed)), let (.cancelled, .swiping(row, _, armed)):
            state = .afterSwipe
            cell(row)?.endSwipe()
            if armed && event.phase == .ended { onReply(row) }
            return []

        case let (.ended, .undecided(_, _, _, held)), let (.cancelled, .undecided(_, _, _, held)):
            state = .idle
            return held + [event]

        case (.ended, _), (.cancelled, _):
            state = .idle
            return [event]

        default:
            return [event]
        }
    }

    private func row(at event: NSEvent) -> Int? {
        guard let table else { return nil }
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        return row >= 0 ? row : nil
    }

    private func cell(_ row: Int) -> HostingCell? {
        table?.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostingCell
    }

    /// Follows the fingers up to the threshold, then resists.
    private static func rubberBand(_ distance: CGFloat) -> CGFloat {
        guard distance > threshold else { return distance }
        let extra = distance - threshold
        let range = maxOffset - threshold
        return threshold + range * (1 - 1 / (extra / range + 1))
    }
}
