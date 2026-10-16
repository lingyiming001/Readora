import SwiftUI
import AppKit
import ImageIO
import ReadoraCore

@MainActor
private func thumbnail(_ data: Data, maxPixel: Int) async -> NSImage? {
    let image = await Task.detached(priority: .utility) { () -> CGImage? in
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 100_000_000 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }.value
    guard !Task.isCancelled, let image else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
}

struct BookCoverView: View {
    let book: Book
    let model: AppModel
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(image == nil ? (book.format == "pdf" ? Color(red: 0.28, green: 0.37, blue: 0.41) : Color(red: 0.53, green: 0.36, blue: 0.25)) : .clear)
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "book.closed").font(.largeTitle)
                    Text(book.title).font(.title3.weight(.medium)).multilineTextAlignment(.center).lineLimit(4)
                }.foregroundStyle(.white).padding(20)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: book.id) {
                if let data = await model.coverData(for: book) { image = await thumbnail(data, maxPixel: 440) }
            }
    }
}

struct EPUBIllustration: View {
    let loadData: @MainActor () async -> Data?
    let alt: String
    @State private var image: NSImage?
    var body: some View {
        VStack {
            if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 640).accessibilityLabel(alt) }
            else { Label(alt, systemImage: "photo").foregroundStyle(.secondary).padding() }
        }.frame(maxWidth: .infinity)
            .task { if let data = await loadData() { image = await thumbnail(data, maxPixel: 1400) } }
            .onDisappear { image = nil }
    }
}
