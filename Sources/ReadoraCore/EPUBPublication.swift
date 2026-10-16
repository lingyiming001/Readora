import Foundation

public struct EPUBBlock: Codable, Sendable {
    public let resourceID: String
    public let paragraphIndex: Int
    public let text: String
    public let headingLevel: Int?
    public let imagePath: String?
}
public struct EPUBChapter: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let position: Int
}
public struct EPUBPublication: Codable, Sendable {
    public static let parserVersion = 2
    public let title: String
    public let author: String
    public let language: String?
    public let blocks: [EPUBBlock]
    public let chapters: [EPUBChapter]
    public let images: [String: Data] // Cover preview only; body illustrations are loaded on demand.
    public let imageResources: Set<String>
    public let cover: Data?
    public let coverResource: String?

    public static func read(url: URL) throws -> Self { try read(data: Data(contentsOf: url, options: .mappedIfSafe)) }
    public static func read(data: Data) throws -> Self {
        let archive = try EPUBArchive(data: data)
        guard try archive.read("mimetype") == Data("application/epub+zip".utf8) else { throw EPUBError.invalidArchive }
        if archive.entries["META-INF/encryption.xml"] != nil { throw EPUBError.encrypted }
        let container = try EPUBXML.parse(archive.read("META-INF/container.xml"), name: "container.xml")
        guard let packagePath = container.descendants("rootfile").first?.attributes["full-path"] else { throw EPUBError.invalidDocument("container.xml") }
        try EPUBArchive.validatePath(packagePath)
        let package = try EPUBXML.parse(archive.read(packagePath), name: packagePath)
        guard let metadata = package.children.first(where: { $0.name == "metadata" }),
              let manifest = package.children.first(where: { $0.name == "manifest" }),
              let spine = package.children.first(where: { $0.name == "spine" }) else { throw EPUBError.invalidDocument(packagePath) }
        if metadata.descendants("meta").contains(where: {
            ($0.attributes["property"] == "rendition:layout" && epubText($0.text) == "pre-paginated") ||
            ($0.attributes["name"] == "fixed-layout" && $0.attributes["content"] == "true")
        }) || spine.children.contains(where: { ($0.attributes["properties"] ?? "").contains("rendition:layout-pre-paginated") }) {
            throw EPUBError.fixedLayout
        }
        let title = epubText(metadata.descendants("title").first?.text ?? "")
        let author = metadata.descendants("creator").map { epubText($0.text) }.filter { !$0.isEmpty }.joined(separator: "、")
        let language = metadata.descendants("language").first.map { epubText($0.text) }
        struct Item { let path: String; let type: String; let properties: Set<String> }
        var items: [String: Item] = [:]
        for node in manifest.children where node.name == "item" {
            guard let id = node.attributes["id"], let href = node.attributes["href"], items[id] == nil else { throw EPUBError.invalidDocument("manifest") }
            // Remote supplemental resources are ignored, never fetched.
            if href.contains(":") || href.hasPrefix("//") { continue }
            let path = try epubResolve(href, relativeTo: packagePath).path
            items[id] = Item(path: path, type: node.attributes["media-type"] ?? "", properties: Set((node.attributes["properties"] ?? "").split(separator: " ").map(String.init)))
        }
        let imageResources = Set(items.values.filter { ["image/png", "image/jpeg", "image/gif"].contains($0.type) }.map(\.path))
        var images: [String: Data] = [:]
        func readImage(_ path: String) throws -> Data? {
            guard imageResources.contains(path), let entry = archive.entries[path],
                  entry.size <= 8 * 1024 * 1024 else { return nil } // Large covers are loaded on demand.
            let bytes = try archive.read(path)
            images[path] = bytes
            return bytes
        }
        let coverID = metadata.descendants("meta").first(where: { $0.attributes["name"] == "cover" })?.attributes["content"]
        let coverItem = items.values.first(where: { $0.properties.contains("cover-image") }) ?? coverID.flatMap { items[$0] }
        let cover = try coverItem.flatMap { try readImage($0.path) }
        var blocks: [EPUBBlock] = [], fallbackChapters: [EPUBChapter] = []
        var resourceStarts: [String: Int] = [:], anchors: [String: Int] = [:]
        var totalText = 0
        for ref in spine.children where ref.name == "itemref" && ref.attributes["linear"] != "no" {
            try Task.checkCancellation()
            guard let id = ref.attributes["idref"], let item = items[id], item.type == "application/xhtml+xml" else { throw EPUBError.invalidDocument("spine") }
            guard resourceStarts[item.path] == nil else { throw EPUBError.invalidDocument("重复 spine 资源") }
            let document = try EPUBXML.parse(archive.read(item.path), name: item.path)
            guard let body = document.descendants("body").first else { throw EPUBError.invalidDocument(item.path) }
            let start = blocks.count
            resourceStarts[item.path] = start
            let builder = EPUBBlockBuilder(resource: item.path, offset: start)
            builder.walk(body)
            builder.flush()
            for block in builder.blocks {
                totalText += block.text.utf8.count
            }
            guard totalText <= 8 * 1024 * 1024, blocks.count + builder.blocks.count <= 100_000 else { throw EPUBError.limitExceeded }
            blocks += builder.blocks
            anchors.merge(builder.anchors, uniquingKeysWith: { first, _ in first })
            if blocks.count > start {
                let heading = builder.blocks.first(where: { $0.headingLevel != nil })?.text
                fallbackChapters.append(EPUBChapter(id: item.path, title: heading ?? "第 \(fallbackChapters.count + 1) 章", position: start))
            }
        }
        guard !blocks.isEmpty else { throw EPUBError.empty }
        func target(_ href: String, relativeTo resource: String) -> Int? {
            guard let resolved = try? epubResolve(href, relativeTo: resource) else { return nil }
            if let fragment = resolved.fragment, let position = anchors[resolved.path + "#" + fragment] { return position }
            return resourceStarts[resolved.path]
        }
        var chapters: [EPUBChapter] = []
        if let nav = items.values.first(where: { $0.properties.contains("nav") }) {
            let document = try EPUBXML.parse(archive.read(nav.path), name: nav.path)
            let navigation = document.descendants("nav").first { node in
                (node.attributes["epub:type"] ?? node.attributes["type"] ?? "").split(separator: " ").contains("toc") || node.attributes["role"] == "doc-toc"
            }
            for link in navigation?.descendants("a") ?? [] {
                if let href = link.attributes["href"], let position = target(href, relativeTo: nav.path), position < blocks.count {
                    let label = epubText(link.text)
                    if !label.isEmpty { chapters.append(EPUBChapter(id: "nav-\(chapters.count)", title: label, position: position)) }
                }
            }
        }
        if chapters.isEmpty, let ncx = spine.attributes["toc"].flatMap({ items[$0] }) ?? items.values.first(where: { $0.type == "application/x-dtbncx+xml" }) {
            let document = try EPUBXML.parse(archive.read(ncx.path), name: ncx.path)
            for point in document.descendants("navPoint") {
                if let href = point.children.first(where: { $0.name == "content" })?.attributes["src"],
                   let position = target(href, relativeTo: ncx.path), position < blocks.count {
                    let label = epubText(point.children.first(where: { $0.name == "navLabel" })?.text ?? "")
                    if !label.isEmpty { chapters.append(EPUBChapter(id: "ncx-\(chapters.count)", title: label, position: position)) }
                }
            }
        }
        return Self(title: title, author: author, language: language, blocks: blocks,
                    chapters: chapters.isEmpty ? fallbackChapters : chapters, images: images, imageResources: imageResources, cover: cover, coverResource: coverItem?.path)
    }
    public func restoredPosition(resourceID: String?, paragraphIndex: Int?, fallback: Int) -> Int {
        if let resourceID, let paragraphIndex,
           let index = blocks.firstIndex(where: { $0.resourceID == resourceID && $0.paragraphIndex == paragraphIndex }) { return index }
        return TextContent.clampedPosition(fallback, count: blocks.count)
    }
}

private final class EPUBBlockBuilder {
    let resource: String
    let offset: Int
    var blocks: [EPUBBlock] = []
    var anchors: [String: Int] = [:]
    var pending = ""
    var heading: Int?
    let ignored: Set<String> = ["script", "style", "head", "nav", "iframe", "object", "audio", "video", "rt", "rp"]
    let blockTags: Set<String> = ["p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre", "figure", "figcaption", "tr"]
    init(resource: String, offset: Int) { self.resource = resource; self.offset = offset }
    func flush() {
        let text = epubText(pending)
        if !text.isEmpty {
            blocks.append(EPUBBlock(resourceID: resource, paragraphIndex: blocks.count, text: text, headingLevel: heading, imagePath: nil))
        }
        pending = ""
    }
    func walk(_ node: EPUBNode) {
        guard !ignored.contains(node.name), !node.hidden else { return }
        let isBlock = blockTags.contains(node.name)
        let previousHeading = heading
        if isBlock { flush(); heading = node.name.first == "h" ? Int(node.name.dropFirst()) : nil }
        if let id = node.attributes["id"] { anchors[resource + "#" + id] = offset + blocks.count }
        if node.name == "br" { pending += "\n" }
        if node.name == "td" || node.name == "th" { pending += " " }
        if node.name == "img" || node.name == "image" {
            flush()
            let href = node.attributes["src"] ?? node.attributes["xlink:href"] ?? node.attributes["href"] ?? ""
            let path = try? epubResolve(href, relativeTo: resource).path
            let alt = epubText(node.attributes["alt"] ?? "")
            blocks.append(EPUBBlock(resourceID: resource, paragraphIndex: blocks.count,
                                    text: alt.isEmpty ? "插图" : alt, headingLevel: nil, imagePath: path))
        }
        for child in node.content {
            switch child { case .text(let value): pending += value; case .node(let value): walk(value) }
        }
        if isBlock { flush(); heading = previousHeading }
    }
}
