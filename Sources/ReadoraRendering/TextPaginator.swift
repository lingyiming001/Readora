import Foundation
import CoreText
import AppKit
import ReadoraCore

public struct PageSlice: Equatable, Sendable {
    public let paragraph: Int
    public let range: NSRange
    public let height: Double
}
public struct ReaderPage: Identifiable, Equatable, Sendable {
    public let id: Int
    public let slices: [PageSlice]
    public let imageIndex: Int?
    public var position: Int { imageIndex ?? slices.first?.paragraph ?? 0 }
    public var textOffset: Int { slices.first?.range.location ?? 0 }
    public func contains(position: Int, offset: Int) -> Bool {
        imageIndex == position || slices.contains { $0.paragraph == position && offset >= $0.range.location && offset < $0.range.location + $0.range.length }
    }
}
public enum TextPaginator {
    public static func paginate(_ paragraphs: [String], headings: Set<Int> = [], images: Set<Int> = [],
                                preferences: ReadingPreferences, width: Double, height: Double) throws -> [ReaderPage] {
        try preferences.validate()
        guard width.isFinite, height.isFinite, width >= 100, height >= 100 else { return [] }
        var pages: [ReaderPage] = [], slices: [PageSlice] = []
        var used: Double = 0
        func flush() {
            guard !slices.isEmpty else { return }
            pages.append(ReaderPage(id: pages.count, slices: slices, imageIndex: nil))
            slices = []; used = 0
        }
        for (index, text) in paragraphs.enumerated() {
            try Task.checkCancellation()
            if images.contains(index) {
                flush(); pages.append(ReaderPage(id: pages.count, slices: [], imageIndex: index)); continue
            }
            let string = text as NSString
            guard string.length > 0 else { continue }
            let attributed = NSAttributedString(string: text, attributes: ReaderTypography.attributes(preferences, heading: headings.contains(index)))
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            var offset = 0
            while offset < string.length {
                try Task.checkCancellation()
                let available = height - used - 4 // Reserve a few points for native text layout rounding.
                if available < preferences.fontSize + preferences.lineSpacing { flush(); continue }
                let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: available), transform: nil)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.length == 0 {
                    if !slices.isEmpty { flush(); continue }
                    throw ReadingDataError.invalidPreferences
                }
                let length = min(visible.length, string.length - offset)
                let fit = CFRange(location: offset, length: length)
                let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, fit, nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
                let range = NSRange(location: offset, length: length)
                let sliceHeight = min(available, ceil(measured.height) + 2)
                slices.append(PageSlice(paragraph: index, range: range, height: sliceHeight))
                used += sliceHeight + preferences.paragraphSpacing
                offset += length
                if offset < string.length { flush() }
            }
        }
        flush()
        return pages
    }
}
