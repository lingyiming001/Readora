import SwiftUI
import AppKit
import ReadoraCore
import ReadoraRendering

struct SelectableParagraph: NSViewRepresentable {
    let text: String
    let sourceOffset: Int
    let preferences: ReadingPreferences
    let heading: Bool
    let highlights: [ReadingMark]
    let onHighlight: (NSRange, HighlightColor) -> Void
    let onBookmark: () -> Void
    var spokenRange: NSRange? = nil
    var onSelect: ((NSRange) -> Void)? = nil
    var onRead: ((NSRange) -> Void)? = nil
    var onAI: ((NSRange) -> Void)? = nil

    func makeNSView(context: Context) -> MarkableTextView {
        let view = MarkableTextView()
        view.delegate = view
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: MarkableTextView, context: Context) {
        let attributed = NSMutableAttributedString(string: text, attributes: ReaderTypography.attributes(preferences, heading: heading))
        let slice = NSRange(location: sourceOffset, length: (text as NSString).length)
        for mark in highlights {
            if let range = mark.range(in: slice) {
                attributed.addAttribute(.backgroundColor, value: ReaderTypography.highlight(mark.color, theme: preferences.theme), range: range)
            }
        }
        if let spokenRange {
            let intersection = NSIntersectionRange(slice, spokenRange)
            if intersection.length > 0 {
                attributed.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(preferences.theme == .night ? 0.3 : 0.24), range: NSRange(location: intersection.location - sourceOffset, length: intersection.length))
            }
        }
        if !view.attributedString().isEqual(to: attributed) {
            let selection = view.selectedRange()
            view.suppressSelectionEvents = true
            view.textStorage?.setAttributedString(attributed)
            if selection.location <= attributed.length, selection.length <= attributed.length - selection.location { view.setSelectedRange(selection) }
            view.suppressSelectionEvents = false
        }
        view.onHighlight = { range, color in onHighlight(NSRange(location: sourceOffset + range.location, length: range.length), color) }
        view.onSelect = { range in onSelect?(NSRange(location: sourceOffset + range.location, length: range.length)) }
        view.onRead = { range in onRead?(NSRange(location: sourceOffset + range.location, length: range.length)) }
        view.onAI = { range in onAI?(NSRange(location: sourceOffset + range.location, length: range.length)) }
        view.onBookmark = onBookmark
        view.setAccessibilityLabel(text)
    }
    static func dismantleNSView(_ view: MarkableTextView, coordinator: ()) {
        view.cancelSelectionTracking(); view.onSelect = nil; view.onRead = nil; view.onAI = nil
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkableTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 640)
        nsView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        guard let container = nsView.textContainer, let manager = nsView.layoutManager else { return nil }
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(manager.usedRect(for: container).height) + 2)
    }
}

final class MarkableTextView: NSTextView, NSTextViewDelegate {
    var onHighlight: ((NSRange, HighlightColor) -> Void)?
    var onBookmark: (() -> Void)?
    var onSelect: ((NSRange) -> Void)?
    var onRead: ((NSRange) -> Void)?
    var onAI: ((NSRange) -> Void)?
    var suppressSelectionEvents = false
    private var reportedSelection = NSRange(location: 0, length: 0)
    private var selectionTask: Task<Void, Never>?
    func cancelSelectionTracking() { selectionTask?.cancel(); selectionTask = nil }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !suppressSelectionEvents else { return }
        cancelSelectionTracking()
        let selection = selectedRange()
        guard selection.length > 0 else { reportedSelection = selection; return }
        guard selection != reportedSelection else { return }
        selectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, self.window?.firstResponder === self, self.selectedRange() == selection else { return }
            self.reportedSelection = selection; self.onSelect?(selection)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        let read = NSMenuItem(title: "从这里开始朗读", action: #selector(startReadingSelection), keyEquivalent: "")
        read.target = self; menu.addItem(read)
        let ai = NSMenuItem(title: "用 AI 解读所选文字…", action: #selector(explainSelection), keyEquivalent: "")
        ai.target = self; menu.addItem(ai)
        let selection = selectedRange()
        let title = selection.length > 0 ? "高亮所选文字" : "高亮此处文字"
        let submenu = NSMenu()
        for (index, color) in HighlightColor.allCases.enumerated() {
            let item = NSMenuItem(title: color.title, action: #selector(addHighlight(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; submenu.addItem(item)
        }
        let highlight = NSMenuItem(title: title, action: nil, keyEquivalent: ""); highlight.submenu = submenu
        menu.addItem(highlight)
        let bookmark = NSMenuItem(title: "切换此段书签", action: #selector(toggleBookmark), keyEquivalent: "")
        bookmark.target = self; menu.addItem(bookmark)
        return menu
    }
    @objc private func addHighlight(_ item: NSMenuItem) {
        guard HighlightColor.allCases.indices.contains(item.tag) else { return }
        let selection = selectedRange()
        let range = selection.length > 0 ? selection : NSRange(location: 0, length: (string as NSString).length)
        onHighlight?(range, HighlightColor.allCases[item.tag])
    }
    @objc private func explainSelection() {
        let selection = selectedRange()
        onAI?(selection.length > 0 ? selection : NSRange(location: 0, length: (string as NSString).length))
    }
    @objc private func startReadingSelection() { onRead?(selectedRange()) }
    @objc private func toggleBookmark() { onBookmark?() }
}
