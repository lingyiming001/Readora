import XCTest
@testable import ReadoraCore

final class EPUBTests: XCTestCase {
    private var demo: URL { Bundle.module.url(forResource: "ReadingJourney", withExtension: "epub", subdirectory: "Fixtures")! }

    func testCompressedEPUBMetadataSpineImagesAndNavigation() throws {
        let book = try EPUBPublication.read(url: demo)
        XCTAssertEqual(book.title, "Readora · 阅读之旅")
        XCTAssertEqual(book.author, "Readora 测试团队")
        XCTAssertEqual(book.language, "zh-CN")
        XCTAssertEqual(book.blocks.first?.text, "第一章 · 开始阅读")
        XCTAssertEqual(book.chapters.map(\.title), ["第一章 · 开始阅读", "第二章 · 继续旅程"])
        XCTAssertEqual(book.blocks[book.chapters[1].position].text, "第二章 · 继续旅程")
        XCTAssertEqual(book.cover, book.images["OPS/Images/cover.png"])
        XCTAssertNotNil(book.cover)
        XCTAssertTrue(book.blocks.contains { $0.text.contains("😀") })
        XCTAssertFalse(book.blocks.contains { $0.text.contains("DoNotExecuteOrRead") || $0.text.contains("隐藏内容") })
        let position = book.chapters[1].position + 1
        let block = book.blocks[position]
        XCTAssertEqual(book.restoredPosition(resourceID: block.resourceID, paragraphIndex: block.paragraphIndex, fallback: 0), position)
        XCTAssertEqual(book.restoredPosition(resourceID: "missing", paragraphIndex: 0, fallback: 999999), book.blocks.count - 1)
    }
    func testEPUB2NCXAndInlineText() throws {
        let book = try EPUBPublication.read(data: fixture(ncx: true))
        XCTAssertEqual(book.chapters.map(\.title), ["来自 NCX 的标题"])
        XCTAssertEqual(book.blocks.map(\.text), ["Hello world & 你好", "Second paragraph"])
    }
    func testFallbackTOCAndEmptyMetadata() throws {
        let book = try EPUBPublication.read(data: fixture())
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertEqual(book.chapters[0].position, 0)
    }
    func testContainerTraversalAndMissingResourceRejected() throws {
        XCTAssertThrowsError(try EPUBPublication.read(data: fixture(packagePath: "../evil.opf")))
        XCTAssertThrowsError(try EPUBPublication.read(data: fixture(spineHref: "missing.xhtml")))
        XCTAssertThrowsError(try EPUBPublication.read(data: fixture(spineHref: "../../evil.xhtml")))
    }
    func testUnsafeArchiveNamesRejected() {
        for path in ["../evil", "/evil", "C:/evil", "a\\evil", "a/../../evil", "a/\u{0}b"] {
            XCTAssertThrowsError(try EPUBArchive(data: zip([(path, Data("x".utf8))])), path)
        }
    }
    func testDuplicateZipEntriesAndCRCMismatchRejected() throws {
        XCTAssertThrowsError(try EPUBArchive(data: zip([("a", Data()), ("a", Data())])))
        var broken = zip([("a", Data("hello".utf8))])
        broken[31] ^= 0x01
        let archive = try EPUBArchive(data: broken)
        XCTAssertThrowsError(try archive.read("a"))
    }
    func testTruncationAndRandomInputsNeverAccepted() throws {
        let bytes = try Data(contentsOf: demo)
        for length in [0, 1, 21, 22, 100, bytes.count - 1] {
            XCTAssertThrowsError(try EPUBPublication.read(data: Data(bytes.prefix(length))))
        }
        for count in stride(from: 22, to: 300, by: 7) {
            XCTAssertThrowsError(try EPUBPublication.read(data: Data(repeating: 0x41, count: count)))
        }
    }
    func testEncryptionFixedLayoutAndEmptyTextRejected() {
        XCTAssertThrowsError(try EPUBPublication.read(data: fixture(extra: [("META-INF/encryption.xml", Data("<encryption/>".utf8))])))
        XCTAssertThrowsError(try EPUBPublication.read(data: fixture(meta: "<meta property=\"rendition:layout\">pre-paginated</meta>")))
        XCTAssertThrowsError(try EPUBPublication.read(data: fixture(body: "<script>not text</script><p hidden=\"hidden\">hidden</p>")))
    }
    func testXMLExternalEntitiesAndMalformedContentRejected() {
        XCTAssertThrowsError(try EPUBXML.parse(Data("<!DOCTYPE x [<!ENTITY bad SYSTEM 'file:///etc/passwd'>]><x>&bad;</x>".utf8), name: "test"))
        XCTAssertThrowsError(try EPUBPublication.read(data: fixture(body: "<p>not closed")))
        XCTAssertThrowsError(try EPUBXML.parse(Data((String(repeating: "<x>", count: 130) + String(repeating: "</x>", count: 130)).utf8), name: "deep"))
    }
    func testEntityDeclarationsAcrossXMLEncodings() throws {
        let document = "<!DOCTYPE x [<!ENTITY bad 'expanded'>]><x>&bad;</x>"
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32] {
            XCTAssertThrowsError(try EPUBXML.parse(XCTUnwrap(document.data(using: encoding)), name: "entity"))
        }
    }
    func testZipSymlinksEncryptionAndExpansionLimits() throws {
        let original = zip([("a", Data("abc".utf8))])
        let central = 34 // local header + name + three content bytes
        var symlink = original
        symlink.replaceSubrange(central + 38..<central + 42, with: [0, 0, 0, 0xA0])
        XCTAssertThrowsError(try EPUBArchive(data: symlink))
        var encrypted = original
        encrypted[central + 8] |= 1
        XCTAssertThrowsError(try EPUBArchive(data: encrypted))
        var bomb = original
        bomb.replaceSubrange(central + 24..<central + 28, with: [0, 0, 0, 0x10])
        XCTAssertThrowsError(try EPUBArchive(data: bomb))
    }

    func testResourceResolution() throws {
        let resolved = try epubResolve("../Images/a%20b.png#anchor", relativeTo: "OPS/Text/a.xhtml")
        XCTAssertEqual(resolved.path, "OPS/Images/a b.png")
        XCTAssertEqual(resolved.fragment, "anchor")
        XCTAssertEqual(try epubResolve("#same", relativeTo: "OPS/Text/a.xhtml").path, "OPS/Text/a.xhtml")
        for href in ["https://evil/a", "//evil/a", "../../../a", "%2Fetc/passwd", "a%5Cb", "%00a"] {
            XCTAssertThrowsError(try epubResolve(href, relativeTo: "OPS/Text/a.xhtml"), href)
        }
    }
    func testOldLibrarySchemaStillDecodes() throws {
        let id = UUID()
        let json = "[{\"id\":\"\(id)\",\"title\":\"Old\",\"filename\":\"old.txt\",\"hash\":\"123\",\"format\":\"txt\",\"position\":3}]"
        let books = try JSONDecoder().decode([Book].self, from: Data(json.utf8))
        XCTAssertEqual(books[0].position, 3)
        XCTAssertNil(books[0].author)
        XCTAssertNil(books[0].resourceID)
    }
    func testImportCacheDuplicateAndProgressRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let books = try await store.importFile(demo)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "Readora · 阅读之旅")
        XCTAssertNotNil(books[0].coverFilename)
        let duplicate = try await store.importFile(demo)
        XCTAssertEqual(duplicate[0].id, books[0].id)
        let firstRead = try await store.publication(for: books[0])
        let cachedRead = try await store.publication(for: books[0])
        XCTAssertEqual(firstRead.blocks.count, cachedRead.blocks.count)
        let block = firstRead.blocks[10]
        _ = try await store.updatePosition(id: books[0].id, position: 10, resourceID: block.resourceID, paragraphIndex: block.paragraphIndex)
        let reopened = try await LibraryStore(root: root).load()
        XCTAssertEqual(reopened[0].resourceID, block.resourceID)
        XCTAssertEqual(reopened[0].paragraphIndex, block.paragraphIndex)
    }
    func testFailedImportLeavesLibraryUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("bad.epub")
        try Data("not epub".utf8).write(to: source)
        let store = LibraryStore(root: root.appendingPathComponent("library"))
        do { _ = try await store.importFile(source); XCTFail("Expected invalid EPUB") } catch {}
        let books = try await store.load()
        XCTAssertTrue(books.isEmpty)
    }
    func testCompressedFixtureParsingPerformance() throws {
        let data = try Data(contentsOf: demo)
        measure { _ = try? EPUBPublication.read(data: data) }
    }

    func testLargeChapterAndMissingCacheRecovery() async throws {
        let body = (0..<5000).map { "<p id=\"p\($0)\">段落 \($0)：中文与 emoji 😀 保持原序。</p>" }.joined()
        let data = fixture(body: body)
        let book = try EPUBPublication.read(data: data)
        XCTAssertEqual(book.blocks.count, 5000)
        XCTAssertEqual(book.blocks[4999].paragraphIndex, 4999)
        XCTAssertEqual(book.blocks[4999].text, "段落 4999：中文与 emoji 😀 保持原序。")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let books = try await store.importFile(demo)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Cache"))
        let recovered = try await store.publication(for: books[0])
        XCTAssertFalse(recovered.blocks.isEmpty)
    }
    func testCorruptLibraryIsNotOverwrittenByImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = Data("broken library".utf8)
        let url = root.appendingPathComponent("library.json")
        try corrupt.write(to: url)
        let store = LibraryStore(root: root)
        do { _ = try await store.importFile(demo); XCTFail("Must preserve corrupt library") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    private func fixture(packagePath: String = "OPS/book.opf", spineHref: String = "chapter.xhtml", ncx: Bool = false, meta: String = "", body: String = "<p>Hello <em>world</em> &amp; 你好</p><p>Second paragraph</p>", extra: [(String, Data)] = []) -> Data {
        let package = """
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Test</dc:title>\(meta)</metadata><manifest><item id="chapter" href="\(spineHref)" media-type="application/xhtml+xml"/>\(ncx ? "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>" : "")</manifest><spine toc="ncx"><itemref idref="chapter"/></spine></package>
        """
        let entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("<container><rootfiles><rootfile full-path=\"\(packagePath)\"/></rootfiles></container>".utf8)),
            ("OPS/book.opf", Data(package.utf8)),
            ("OPS/chapter.xhtml", Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\(body)</body></html>".utf8)),
            ("OPS/toc.ncx", Data("<ncx><navMap><navPoint><navLabel><text>来自 NCX 的标题</text></navLabel><content src=\"chapter.xhtml\"/></navPoint></navMap></ncx>".utf8))
        ] + extra
        return zip(entries)
    }
}

private func zip(_ entries: [(String, Data)]) -> Data {
    var result = Data(), directory = Data()
    for (name, bytes) in entries {
        let filename = Data(name.utf8), offset = result.count, crc = checksum(bytes)
        result.le(UInt32(0x04034b50)); result.le(UInt16(20)); result.le(UInt16(0x800)); result.le(UInt16(0))
        result.le(UInt16(0)); result.le(UInt16(0)); result.le(crc); result.le(UInt32(bytes.count)); result.le(UInt32(bytes.count))
        result.le(UInt16(filename.count)); result.le(UInt16(0)); result += filename; result += bytes
        directory.le(UInt32(0x02014b50)); directory.le(UInt16(20)); directory.le(UInt16(20)); directory.le(UInt16(0x800)); directory.le(UInt16(0))
        directory.le(UInt16(0)); directory.le(UInt16(0)); directory.le(crc); directory.le(UInt32(bytes.count)); directory.le(UInt32(bytes.count))
        directory.le(UInt16(filename.count)); directory.le(UInt16(0)); directory.le(UInt16(0)); directory.le(UInt16(0)); directory.le(UInt16(0))
        directory.le(UInt32(0)); directory.le(UInt32(offset)); directory += filename
    }
    let start = result.count
    result += directory
    result.le(UInt32(0x06054b50)); result.le(UInt16(0)); result.le(UInt16(0))
    result.le(UInt16(entries.count)); result.le(UInt16(entries.count)); result.le(UInt32(directory.count)); result.le(UInt32(start)); result.le(UInt16(0))
    return result
}
private func checksum(_ data: Data) -> UInt32 {
    var value: UInt32 = 0xFFFFFFFF
    for byte in data {
        value ^= UInt32(byte)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB88320 : value >> 1 }
    }
    return value ^ 0xFFFFFFFF
}
private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }
}
