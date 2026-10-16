import AppKit
import SwiftUI
import ReadoraRendering

/// Observes only events inside this reader, leaving native text selection intact.
struct PageSwipeSurface: NSViewRepresentable {
    var enabled: Bool
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat) -> Void
    func makeNSView(context: Context) -> SwipeView { SwipeView() }
    func updateNSView(_ view: SwipeView, context: Context) {
        view.enabled = enabled; view.onChange = onChange; view.onEnd = onEnd
    }
    static func dismantleNSView(_ view: SwipeView, coordinator: ()) { view.stop() }

    final class SwipeView: NSView {
        var enabled = false
        var onChange: ((CGFloat) -> Void)?
        var onEnd: ((CGFloat) -> Void)?
        private var monitor: Any?
        private var start: NSPoint?
        private var distance: CGFloat = 0
        private var tracker = PageSwipeTracker()
        private var settle: Task<Void, Never>?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) == nil }
                return consumed ? nil : event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil; settle?.cancel(); settle = nil; start = nil; distance = 0; tracker.reset()
        }
        private func finish() {
            let value = distance
            distance = 0; tracker.reset(); start = nil
            onEnd?(value)
        }
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard enabled, event.window === window else { return event }
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            if event.type == .leftMouseDown {
                guard inside else { return event }
                var hit = window?.contentView?.hitTest(event.locationInWindow)
                while let view = hit {
                    if view is NSTextView || view is NSControl { return event }
                    hit = view.superview
                }
                start = event.locationInWindow
                return event
            }
            if event.type == .leftMouseDragged, let start {
                let dx = event.locationInWindow.x - start.x
                let dy = event.locationInWindow.y - start.y
                guard abs(dx) > abs(dy), abs(dx) > 8 else { return event }
                distance = dx; onChange?(distance)
                return nil
            }
            if event.type == .leftMouseUp, start != nil { finish(); return event }
            guard event.type == .scrollWheel, inside else { return event }
            guard event.momentumPhase.isEmpty else { return event }
            if event.phase.contains(.began) { distance = 0; tracker.reset() }
            if event.phase.contains(.cancelled) { distance = 0; finish(); return event }
            if event.phase.contains(.ended) { finish(); return event }
            settle?.cancel()
            // Discrete mouse wheels do not send an ended phase.
            if event.phase.isEmpty {
                settle = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                    self?.finish()
                }
            }
            let scale = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
            guard let value = tracker.update(x: event.scrollingDeltaX * scale, y: event.scrollingDeltaY * scale) else { return event }
            distance = value
            onChange?(distance)
            return nil
        }
    }
}
