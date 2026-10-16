import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

final class EPUBNode {
    enum Content { case text(String), node(EPUBNode) }
    let name: String
    let attributes: [String: String]
    var content: [Content] = []
    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
    var children: [EPUBNode] { content.compactMap { if case .node(let n) = $0 { n } else { nil } } }
    var text: String { content.map { switch $0 { case .text(let t): t; case .node(let n): n.text } }.joined() }
    func descendants(_ name: String) -> [EPUBNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
    var hidden: Bool {
        let style = (attributes["style"] ?? "").lowercased().filter { !$0.isWhitespace }
        return attributes["hidden"] != nil || attributes["aria-hidden"] == "true" || style.contains("display:none") || style.contains("visibility:hidden")
    }
}

final class EPUBXML: NSObject, XMLParserDelegate {
    private var stack: [EPUBNode] = []
    private var root: EPUBNode?
    private var count = 0
    private var invalid = false
    static func parse(_ data: Data, name: String) throws -> EPUBNode {
        guard data.count <= 8 * 1024 * 1024 else { throw EPUBError.limitExceeded }
        // XMLParser may silently skip an external entity without reporting its declaration.
        // Reject entity declarations before parsing, including UTF-16/32 XML encodings.
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian, .isoLatin1] {
            if String(data: data, encoding: encoding)?.contains("<!ENTITY") == true {
                throw EPUBError.invalidDocument(name)
            }
        }
        let delegate = EPUBXML()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, let root = delegate.root else { throw EPUBError.invalidDocument(name) }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard stack.count < 128, count <= 100_000 else { invalid = true; parser.abortParsing(); return }
        let node = EPUBNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last { parent.content.append(.node(node)) }
        else if root == nil { root = node } else { invalid = true; parser.abortParsing(); return }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.content.append(.text(string)) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { stack.last?.content.append(.text(text)) }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
}

func epubText(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

func epubResolve(_ href: String, relativeTo resource: String) throws -> (path: String, fragment: String?) {
    let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    guard let decoded = String(parts[0]).removingPercentEncoding, !decoded.contains("?"), !decoded.hasPrefix("/") else { throw EPUBError.unsafePath }
    var components = resource.split(separator: "/").dropLast().map(String.init)
    if !decoded.isEmpty {
        for part in decoded.split(separator: "/", omittingEmptySubsequences: false) {
            if part == ".." { guard !components.isEmpty else { throw EPUBError.unsafePath }; components.removeLast() }
            else if part != "." && !part.isEmpty { components.append(String(part)) }
        }
    } else { components = resource.split(separator: "/").map(String.init) }
    let path = components.joined(separator: "/")
    try EPUBArchive.validatePath(path)
    guard !path.isEmpty else { throw EPUBError.unsafePath }
    return (path, parts.count == 2 ? String(parts[1]).removingPercentEncoding : nil)
}
