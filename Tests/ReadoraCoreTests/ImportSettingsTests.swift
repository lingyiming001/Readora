import XCTest
import CZlib
@testable import ReadoraCore

final class ImportSettingsTests: XCTestCase {
    func testDefaultAndExactBoundaries() throws {
        let settings = ImportSettings()
        XCTAssertEqual(settings.maxBookSizeMB, 200)
        try settings.validateFileSize(200 * 1024 * 1024)
        XCTAssertThrowsError(try settings.validateFileSize(200 * 1024 * 1024 + 1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("200 MB"))
        }
        for limit in [-1, 0, 2049, Int.max] {
            XCTAssertThrowsError(try ImportSettings(maxBookSizeMB: limit).validate())
        }
        try ImportSettings(maxBookSizeMB: 2048).validate()
    }
    func testSettingsPersistAndInvalidChangesDoNotOverwrite() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let defaults = try await store.importSettings()
        XCTAssertEqual(defaults, ImportSettings())
        try await store.saveImportSettings(ImportSettings(maxBookSizeMB: 350))
        let restored = try await LibraryStore(root: root).importSettings()
        XCTAssertEqual(restored.maxBookSizeMB, 350)
        do { try await store.saveImportSettings(ImportSettings(maxBookSizeMB: 0)); XCTFail("Invalid setting accepted") } catch {}
        let unchanged = try await store.importSettings()
        XCTAssertEqual(unchanged.maxBookSizeMB, 350)
    }
    func testSmallerConfiguredLimitRejectsBeforeCopyAndKeepsExistingBooks() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.txt")
        try Data(repeating: 0x41, count: 2 * 1024 * 1024).write(to: source)
        let store = LibraryStore(root: root.appendingPathComponent("Library"))
        let books = try await store.importFile(source)
        XCTAssertEqual(books.count, 1)
        try await store.saveImportSettings(ImportSettings(maxBookSizeMB: 1))
        do { _ = try await store.importFile(source); XCTFail("Must reject oversized file") } catch {}
        let after = try await store.load()
        XCTAssertEqual(after[0].id, books[0].id)
        let original = await store.fileURL(for: books[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Library/Staging").path).isEmpty)
    }
    func testTwoHundredMBEPUBImportsAndReopensAfterLimitIsReduced() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "ReadingJourney", withExtension: "epub", subdirectory: "Fixtures"))
        let source = root.appendingPathComponent("200MB.epub")
        try largeEPUB(from: fixture, to: source, size: 200 * 1024 * 1024)
        XCTAssertEqual(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, 200 * 1024 * 1024)
        let store = LibraryStore(root: root.appendingPathComponent("Library"))
        let books = try await store.importFile(source)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "Readora · 阅读之旅")
        try await store.saveImportSettings(ImportSettings(maxBookSizeMB: 10))
        // Delete cache to ensure reopening the original is independent of the new import cap.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Library/Cache"))
        let publication = try await store.publication(for: books[0])
        XCTAssertEqual(publication.chapters.count, 2)
        XCTAssertEqual(publication.images.count, 1) // Only the small cover is retained eagerly.
        let image = try await store.imageData(for: books[0], path: "OPS/Images/cover.png")
        XCTAssertEqual(image, publication.cover)
        // Make the same archive one byte larger with a valid ZIP comment.
        let handle = try FileHandle(forUpdating: source)
        try handle.seek(toOffset: UInt64(200 * 1024 * 1024 - 2))
        try handle.write(contentsOf: Data([1, 0, 65])); try handle.close()
        try await store.saveImportSettings(ImportSettings())
        do { _ = try await store.importFile(source); XCTFail("200MB + 1 byte must fail at default") } catch {
            XCTAssertTrue(error.localizedDescription.contains("200 MB"))
        }
        try await store.saveImportSettings(ImportSettings(maxBookSizeMB: 201))
        let larger = try await store.importFile(source)
        XCTAssertEqual(larger.count, 2)
    }
    private func directory() throws -> URL {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = project.appendingPathComponent(".agents/test/import-settings/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// A valid stored ZIP exactly at the requested byte size; padding entries are sparse,
// bounded and unused by the publication. It exercises actual import, not just a mock size.
private func largeEPUB(from source: URL, to target: URL, size: Int) throws {
    let archive = try EPUBArchive(data: Data(contentsOf: source))
    let paths = ["mimetype"] + archive.entries.keys.filter { $0 != "mimetype" }.sorted()
    let entries = try paths.map { ($0, try archive.read($0)) }
    var content = Data(), directory = Data()
    func local(_ name: Data, count: Int, crc: UInt32) -> Data {
        var data = Data()
        data.le(UInt32(0x04034b50)); data.le(UInt16(20)); data.le(UInt16(0x800)); data.le(UInt16(0))
        data.le(UInt16(0)); data.le(UInt16(0)); data.le(crc); data.le(UInt32(count)); data.le(UInt32(count))
        data.le(UInt16(name.count)); data.le(UInt16(0)); data += name
        return data
    }
    func central(_ name: Data, count: Int, crc: UInt32, offset: Int) -> Data {
        var data = Data()
        data.le(UInt32(0x02014b50)); data.le(UInt16(20)); data.le(UInt16(20)); data.le(UInt16(0x800)); data.le(UInt16(0))
        data.le(UInt16(0)); data.le(UInt16(0)); data.le(crc); data.le(UInt32(count)); data.le(UInt32(count))
        data.le(UInt16(name.count)); data.le(UInt16(0)); data.le(UInt16(0)); data.le(UInt16(0)); data.le(UInt16(0))
        data.le(UInt32(0)); data.le(UInt32(offset)); data += name
        return data
    }
    for (name, bytes) in entries {
        let name = Data(name.utf8)
        let crc = bytes.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))) }
        directory += central(name, count: bytes.count, crc: crc, offset: content.count)
        content += local(name, count: bytes.count, crc: crc); content += bytes
    }
    let names = (0..<16).map { Data("Padding/\($0).bin".utf8) }
    let paddingBytes = size - content.count - directory.count - 22 - names.reduce(0) { $0 + 30 + 46 + 2 * $1.count }
    guard paddingBytes > 0 else { throw EPUBError.invalidArchive }
    FileManager.default.createFile(atPath: target.path, contents: content)
    let output = try FileHandle(forWritingTo: target)
    defer { try? output.close() }
    var position = content.count
    try output.seek(toOffset: UInt64(position))
    let zeros = Data(count: 1024 * 1024)
    var cachedCRCs: [Int: UInt32] = [:]
    for (index, name) in names.enumerated() {
        let count = paddingBytes / names.count + (index < paddingBytes % names.count ? 1 : 0)
        let crc: UInt32
        if let cached = cachedCRCs[count] { crc = cached }
        else {
            var sum: uLong = 0, remaining = count
            while remaining > 0 {
                let chunk = min(zeros.count, remaining)
                sum = zeros.withUnsafeBytes { crc32(sum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(chunk)) }
                remaining -= chunk
            }
            crc = UInt32(sum); cachedCRCs[count] = crc
        }
        directory += central(name, count: count, crc: crc, offset: position)
        let header = local(name, count: count, crc: crc)
        try output.write(contentsOf: header)
        position += header.count + count
        try output.seek(toOffset: UInt64(position))
    }
    var end = Data()
    end.le(UInt32(0x06054b50)); end.le(UInt16(0)); end.le(UInt16(0))
    end.le(UInt16(entries.count + names.count)); end.le(UInt16(entries.count + names.count))
    end.le(UInt32(directory.count)); end.le(UInt32(position)); end.le(UInt16(0))
    try output.write(contentsOf: directory + end)
}
private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }
}
