import XCTest
import ReadoraCore
@testable import ReadoraMac

@MainActor
final class SpeechPlayerTests: XCTestCase {
    func testSelectingTextPreservesPausedPlaybackUntilExplicitRead() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".agents/test/selection-\(UUID().uuidString)")
        let model = AppModel(libraryRoot: root)
        defer { model.speech.stop(); try? FileManager.default.removeItem(at: root) }
        model.paragraphs = ["原来的暂停位置。", "甲😀乙银行。"]
        model.speech.play(model.paragraphs, from: 0, startPaused: true) { _, _ in }
        model.selectForSpeech(index: 1, range: NSRange(location: 2, length: 1))
        XCTAssertEqual(model.speechSelection?.index, 1)
        XCTAssertEqual(model.speechSelection?.offset, 1)
        XCTAssertEqual(model.selectedAIText, "😀")
        XCTAssertEqual(model.speech.index, 0)
        XCTAssertTrue(model.speech.isActive)
        XCTAssertFalse(model.speech.isPlaying)
    }
    func testPausedReconfigurationKeepsParagraphAndComposedOffset() {
        let speech = SpeechPlayer()
        let text = "甲👨‍👩‍👧‍👦乙银行。"
        var updates = 0
        speech.play(["第一段。", text], from: 1, offset: 3, startPaused: true) { _, _ in updates += 1 }
        XCTAssertTrue(speech.isActive)
        XCTAssertFalse(speech.isPlaying)
        XCTAssertEqual(speech.index, 1)
        XCTAssertEqual(speech.spokenRange.location, 1)
        speech.configure(SpeechPreferences(rate: 1.5, pronunciationDictionary: "银行 = yin2 hang2"))
        XCTAssertTrue(speech.isActive)
        XCTAssertFalse(speech.isPlaying)
        XCTAssertEqual(speech.index, 1)
        XCTAssertEqual(speech.spokenRange.location, 1)
        XCTAssertEqual(updates, 0)
        speech.stop()
    }
    func testStopBeforeProducerStartsCannotReviveOldPlayback() async {
        let speech = SpeechPlayer()
        var updates = 0
        speech.play(["已取消的朗读。"], from: 0) { _, _ in updates += 1 }
        speech.stop()
        speech.play(["第一段。", "新书的暂停位置。"], from: 1, offset: 3, startPaused: true) { _, _ in updates += 1 }
        await Task.yield()
        XCTAssertTrue(speech.isActive)
        XCTAssertFalse(speech.isPlaying)
        XCTAssertEqual(speech.index, 1)
        XCTAssertEqual(speech.spokenRange.location, 3)
        XCTAssertEqual(updates, 0)
        speech.stop()
    }
}
