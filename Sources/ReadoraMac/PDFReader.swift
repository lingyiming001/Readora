import SwiftUI
import PDFKit
import ReadoraCore
import ReadoraRendering

struct PDFReader: NSViewRepresentable {
    let document: PDFDocument
    let position: Int
    let jumpID: UUID
    let layout: ReadingLayout
    let marks: [ReadingMark]
    let markRevision: UUID
    let background: NSColor
    let onPageChange: (Int) -> Void
    let onHighlight: (Int, [PageRectangle], String, HighlightColor) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPageChange) }
    func makeNSView(context: Context) -> MarkablePDFView {
        let view = MarkablePDFView()
        view.autoScales = true; view.displaysPageBreaks = true
        context.coordinator.observe(view)
        return view
    }
    func updateNSView(_ view: MarkablePDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.change = onPageChange
        let changedDocument = view.document !== document
        if changedDocument { view.document = document; view.autoScales = true }
        view.displayMode = layout == .pages ? .singlePage : .singlePageContinuous
        view.backgroundColor = background
        view.onHighlight = onHighlight
        if changedDocument || coordinator.lastJumpID != jumpID {
            coordinator.lastJumpID = jumpID
            if let page = document.page(at: position) { view.go(to: page) }
        }
        if changedDocument || coordinator.lastMarkRevision != markRevision {
            coordinator.lastMarkRevision = markRevision
            for (page, annotation) in coordinator.annotations { page.removeAnnotation(annotation) }
            coordinator.annotations = []
            for mark in marks where mark.kind == .highlight {
                guard let page = document.page(at: mark.position) else { continue }
                for rect in mark.rectangles ?? [] {
                    let bounds = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height).intersection(page.bounds(for: .cropBox))
                    guard !bounds.isEmpty, !bounds.isNull else { continue }
                    let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                    annotation.color = ReaderTypography.highlight(mark.color, theme: .paper)
                    page.addAnnotation(annotation); coordinator.annotations.append((page, annotation))
                }
            }
        }
    }
    @MainActor
    final class Coordinator: NSObject {
        var change: (Int) -> Void
        var lastJumpID: UUID?
        var lastMarkRevision: UUID?
        var annotations: [(PDFPage, PDFAnnotation)] = []
        init(_ change: @escaping (Int) -> Void) { self.change = change }
        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        }
        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView, let page = view.currentPage,
                  let document = view.document else { return }
            change(document.index(for: page))
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

final class MarkablePDFView: PDFView {
    var onHighlight: ((Int, [PageRectangle], String, HighlightColor) -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let selection = currentSelection, selection.string?.isEmpty == false else { return menu }
        let submenu = NSMenu()
        for (index, color) in HighlightColor.allCases.enumerated() {
            let item = NSMenuItem(title: color.title, action: #selector(highlightSelection(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; submenu.addItem(item)
        }
        menu.addItem(.separator())
        let item = NSMenuItem(title: "高亮所选文字", action: nil, keyEquivalent: ""); item.submenu = submenu; menu.addItem(item)
        return menu
    }
    @objc private func highlightSelection(_ item: NSMenuItem) {
        guard let selection = currentSelection, let document, HighlightColor.allCases.indices.contains(item.tag),
              document.allowsCommenting else { return }
        for page in selection.pages {
            let rectangles = selection.selectionsByLine().filter { $0.pages.contains(page) }.compactMap { line -> PageRectangle? in
                let rect = line.bounds(for: page)
                guard !rect.isEmpty, !rect.isNull else { return nil }
                return PageRectangle(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            }
            if !rectangles.isEmpty { onHighlight?(document.index(for: page), rectangles, selection.string ?? "", HighlightColor.allCases[item.tag]) }
        }
    }
}
