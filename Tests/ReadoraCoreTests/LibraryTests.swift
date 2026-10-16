import XCTest
@testable import ReadoraCore

final class LibraryTests: XCTestCase {
    func testTextDecodingAndParagraphs() throws {
        XCTAssertEqual(try TextContent.decode(Data([0xEF, 0xBB, 0xBF]) + Data("你好😀\r\n世界".utf8)), "你好😀\r\n世界")
        XCTAssertEqual(TextContent.paragraphs("甲\r\n\r\n乙\r丙"), ["甲", "乙", "丙"])
        XCTAssertThrowsError(try TextContent.decode(Data([0xFF, 0xFF, 0x01])))
        XCTAssertEqual(TextContent.clampedPosition(-1, count: 0), 0)
        XCTAssertEqual(TextContent.clampedPosition(99, count: 3), 2)
    }
    func testImportDeduplicationAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root.appendingPathComponent("library"))
        _ = try await store.load()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("阅读.txt")
        try Data("第一段\n第二段".utf8).write(to: source)
        let first = try await store.importFile(source)
        let duplicate = try await store.importFile(source)
        XCTAssertEqual(first.count, 1); XCTAssertEqual(duplicate.count, 1)
        _ = try await store.updatePosition(id: first[0].id, position: 1)
        let restored = try await LibraryStore(root: root.appendingPathComponent("library")).load()
        XCTAssertEqual(restored[0].position, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
