import XCTest
import ReadoraCore
@testable import ReadoraMac

@MainActor
final class AIAppOperationsTests: XCTestCase {
    private func fixture() async throws -> (URL, AppModel, Book) {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent(".agents/test/app-operations/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("sample.txt")
        try Data("自制测试正文\n第二段内容".utf8).write(to: source)
        let model = AppModel(libraryRoot: root.appendingPathComponent("Library"))
        _ = try await model.store.importFile(source)
        await model.load()
        return (root, model, try XCTUnwrap(model.books.first))
    }
    func testAIAddsShelfAndChangesConfigurationWithoutConfirmation() async throws {
        let (root, model, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await model.executeAICommand(AIAppCommand(action: .createShelf, text: "AI创建的书架"))
        XCTAssertEqual(model.collections.first?.title, "AI创建的书架")
        _ = try await model.executeAICommand(AIAppCommand(action: .readingPreference, target: "theme", text: "night"))
        _ = try await model.executeAICommand(AIAppCommand(action: .readingPreference, target: "fontSize", number: 28))
        XCTAssertEqual(model.preferences.theme, .night)
        XCTAssertEqual(model.preferences.fontSize, 28)
        do { _ = try await model.executeAICommand(AIAppCommand(action: .readingPreference, target: "fontSize", number: 100)); XCTFail("invalid size accepted") } catch {}
        XCTAssertEqual(model.preferences.fontSize, 28)
        await model.flushPreferences()
    }
    func testDeletionCannotRunWithoutConfirmationAndEmptyTrashUsesSnapshot() async throws {
        let (root, model, first) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.books = try await model.store.changeBook(id: first.id, change: .trash(true))
        let command = model.boundAICommand(AIAppCommand(action: .emptyTrash))
        do { _ = try await model.executeAICommand(command); XCTFail("deletion bypassed confirmation") } catch {}
        XCTAssertEqual(model.books.count, 1)
        let source = root.appendingPathComponent("other.txt")
        try Data("另一本自制材料".utf8).write(to: source)
        let imported = try await model.store.importFile(source)
        let second = try XCTUnwrap(imported.first { $0.id != first.id })
        model.books = try await model.store.changeBook(id: second.id, change: .trash(true))
        _ = try await model.executeAICommand(command, confirmed: true)
        XCTAssertEqual(model.books.map(\.id), [second.id])
        XCTAssertNotNil(model.books.first?.trashedAt)
    }
    func testQueuedBookSwitchCannotOperateOnPreviouslyOpenedBook() async throws {
        let (root, model, book) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.requestedBookID = book.id
        await model.open(book.id)
        XCTAssertEqual(model.current?.id, book.id)
        model.requestedBookID = UUID()
        do { _ = try await model.executeAICommand(AIAppCommand(action: .jump, bookID: book.id, number: 1)); XCTFail("old book operated while switching") } catch {}
        XCTAssertEqual(model.position, 0)
        await model.flushProgress()
    }
    func testBookmarkedRemovalAndShelfDeletionRequireConfirmation() async throws {
        let (root, model, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await model.executeAICommand(AIAppCommand(action: .createShelf, text: "保留书籍"))
        let shelf = try XCTUnwrap(model.collections.first)
        let removal = AIAppCommand(action: .deleteShelf, id: shelf.id)
        do { _ = try await model.executeAICommand(removal); XCTFail("shelf removed") } catch {}
        XCTAssertEqual(model.collections.count, 1)
        _ = try await model.executeAICommand(removal, confirmed: true)
        XCTAssertTrue(model.collections.isEmpty)
        XCTAssertEqual(model.books.count, 1)
        XCTAssertTrue(AIAppCommand(action: .bookmark, flag: false).requiresConfirmation)
    }
}
