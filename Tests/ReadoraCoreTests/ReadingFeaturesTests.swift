import XCTest
import ReadoraCore
import ReadoraRendering
import AppKit
import AVFoundation

final class ReadingFeaturesTests: XCTestCase {
    func testReadingBoldPreferenceBackwardCompatibility() throws {
        let encoder = JSONEncoder()
        var preferences = ReadingPreferences()
        let old = try encoder.encode(preferences)
        XCTAssertNil(try JSONDecoder().decode(ReadingPreferences.self, from: old).boldText)
        preferences.boldText = true
        let restored = try JSONDecoder().decode(ReadingPreferences.self, from: encoder.encode(preferences))
        XCTAssertEqual(restored.boldText, true)
        XCTAssertEqual(restored.fontSize, preferences.fontSize)
    }

    func testPaginationPreservesAllCharactersAndRestoresInsideLongParagraph() throws {
        let paragraphs = [String(repeating: "很长的一段文字，emoji 😀 与 café é 都不能在翻页时丢失。", count: 120), "下一段。📖"]
        var preferences = ReadingPreferences(); preferences.fontSize = 26
        let pages = try TextPaginator.paginate(paragraphs, preferences: preferences, width: 350, height: 320)
        XCTAssertGreaterThan(pages.count, 3)
        for index in paragraphs.indices {
            let slices = pages.flatMap(\.slices).filter { $0.paragraph == index }
            let source = paragraphs[index] as NSString
            var next = 0, restored = ""
            for slice in slices {
                XCTAssertEqual(slice.range.location, next)
                XCTAssertGreaterThan(slice.range.length, 0)
                restored += source.substring(with: slice.range)
                next = NSMaxRange(slice.range)
            }
            XCTAssertEqual(next, source.length)
            XCTAssertEqual(restored, paragraphs[index])
        }
        let page = pages[2]
        XCTAssertTrue(page.contains(position: page.position, offset: page.textOffset))
        XCTAssertFalse(page.contains(position: 100, offset: 0))
        for page in pages {
            let height = page.slices.reduce(0) { $0 + $1.height } + Double(max(0, page.slices.count - 1)) * preferences.paragraphSpacing
            XCTAssertLessThanOrEqual(height, 320)
        }
    }
    func testPaginationChangesWithFontAndViewportAndKeepsImages() throws {
        let paragraphs = (0..<20).map { "段落\($0)：" + String(repeating: "阅读应当从容而完整。", count: 8) }
        let preferences = ReadingPreferences()
        let small = try TextPaginator.paginate(paragraphs, images: [4], preferences: preferences, width: 320, height: 300)
        let large = try TextPaginator.paginate(paragraphs, images: [4], preferences: preferences, width: 650, height: 650)
        XCTAssertGreaterThan(small.count, large.count)
        XCTAssertEqual(small.filter { $0.imageIndex == 4 }.count, 1)
        XCTAssertFalse(small.flatMap(\.slices).contains { $0.paragraph == 4 })
        XCTAssertTrue(try TextPaginator.paginate([], preferences: preferences, width: 400, height: 400).isEmpty)
    }
    func testPreferenceValidationAndSpeechCeiling() throws {
        var reading = ReadingPreferences()
        reading.brightness = .nan
        XCTAssertThrowsError(try reading.validate())
        reading = ReadingPreferences(); reading.fontSize = 100
        XCTAssertThrowsError(try reading.validate())
        let fast = SpeechPreferences(rate: 1.8, maximumRate: 2)
        let capped = fast.capped(to: 1.2)
        XCTAssertEqual(capped.rate, 1.2)
        XCTAssertLessThanOrEqual(capped.systemRate(defaultRate: 0.5, minimum: 0, maximum: 1), 0.6 + 0.0001)
        XCTAssertEqual(SpeechPreferences(rate: 2).systemRate(defaultRate: 0.5, minimum: 0, maximum: 1), 1)
        XCTAssertThrowsError(try SpeechPreferences(rate: 1, maximumRate: .nan).validate())
        XCTAssertThrowsError(try SpeechPreferences(rate: 0.1).validate())
    }
    func testPageSwipeIgnoresVerticalScrollAndInitialFingerJitter() {
        var tracker = PageSwipeTracker()
        XCTAssertNil(tracker.update(x: 0.2, y: 1))
        XCTAssertEqual(tracker.update(x: -12, y: 0.5), -11.8)
        XCTAssertEqual(tracker.update(x: -50, y: 2), -61.8)
        tracker.reset()
        XCTAssertNil(tracker.update(x: 1, y: 20))
        XCTAssertNil(tracker.update(x: 60, y: 0))
        tracker.reset()
        XCTAssertEqual(tracker.update(x: 80, y: 2), 80)
    }
    func testEightTimesAudioActuallyCompressesPlaybackDuration() throws {
        func audibleDuration(rate: Double) throws -> Double {
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            let pitch = SpeechAudio.timePitch(rate: rate)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
            engine.attach(player); engine.attach(pitch)
            engine.connect(player, to: pitch, format: format)
            engine.connect(pitch, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
            let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
            source.frameLength = 96000
            let samples = try XCTUnwrap(source.floatChannelData)[0]
            for frame in 0..<96000 { samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48000)) * 0.5 }
            player.scheduleBuffer(source)
            try engine.start(); player.play()
            defer { player.stop(); engine.stop() }
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            var rendered = 0, lastAudible = 0
            for _ in 0..<180 {
                let status = try engine.renderOffline(1024, to: output)
                if status == .success {
                    let values = try XCTUnwrap(output.floatChannelData)[0]
                    for frame in 0..<Int(output.frameLength) where abs(values[frame]) > 0.001 { lastAudible = rendered + frame }
                    rendered += Int(output.frameLength)
                }
            }
            return Double(lastAudible) / 48000
        }
        let normal = try audibleDuration(rate: 1), fast = try audibleDuration(rate: 8)
        XCTAssertGreaterThan(normal, 1.8)
        XCTAssertGreaterThan(fast, 0.1)
        XCTAssertLessThan(fast, 0.5)
        XCTAssertGreaterThan(normal / fast, 5)
    }
    func testNeuralSpeechPhrasesPreserveAllTextAndBoundaries() throws {
        let text = String(repeating: "这是一个中英文混读的句子😀，Hello world! 下一句包含 é 和数字123。", count: 20)
        let source = text as NSString
        var offset = 0, pieces: [String] = []
        while let range = SpeechTextSegment.phraseRange(in: text, from: offset) {
            XCTAssertEqual(range.location, offset)
            XCTAssertGreaterThan(range.length, 0)
            XCTAssertLessThanOrEqual(range.length, 82)
            pieces.append(source.substring(with: range)); offset = NSMaxRange(range)
        }
        XCTAssertEqual(pieces.joined(), text)
        XCTAssertEqual(offset, source.length)
        XCTAssertNil(SpeechTextSegment.phraseRange(in: "", from: 0))
        XCTAssertNil(SpeechTextSegment.phraseRange(in: text, from: source.length))
    }
    func testSpokenHighlightClipsAcrossPageAndUTF16Boundaries() throws {
        let spoken = NSRange(location: 95, length: 20)
        XCTAssertEqual(SpeechTextSegment.localIntersection(spoken, in: NSRange(location: 0, length: 100)), NSRange(location: 95, length: 5))
        XCTAssertEqual(SpeechTextSegment.localIntersection(spoken, in: NSRange(location: 100, length: 100)), NSRange(location: 0, length: 15))
        XCTAssertNil(SpeechTextSegment.localIntersection(spoken, in: NSRange(location: 115, length: 100)))
        XCTAssertNil(SpeechTextSegment.localIntersection(NSRange(location: NSNotFound, length: 1), in: NSRange(location: 0, length: 10)))
        XCTAssertNil(SpeechTextSegment.localIntersection(NSRange(location: Int.max - 1, length: 20), in: NSRange(location: 0, length: 10)))
        let text = "甲😀乙é丙" as NSString
        let range = text.range(of: "😀乙é")
        let local = try XCTUnwrap(SpeechTextSegment.localIntersection(range, in: NSRange(location: range.location, length: range.length)))
        XCTAssertEqual(local, NSRange(location: 0, length: range.length))
        let resumed = try XCTUnwrap(SpeechTextSegment.range(in: text as String, from: 2))
        XCTAssertEqual(resumed.location, 1, "Resume must not begin inside an emoji surrogate pair")
    }
    func testCustomSpeechMaximumPersistsAndCanReturnToTwoTimes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        for maximum in [2.0, 3.25, 8.0] {
            let preferences = SpeechPreferences(rate: maximum, maximumRate: maximum)
            try await store.saveSpeechPreferences(preferences)
            let restored = try await LibraryStore(root: root).speechPreferences()
            XCTAssertEqual(restored.maximumRate, maximum)
            XCTAssertEqual(restored.rate, maximum)
        }
        let restored = try await store.speechPreferences()
        let reset = restored.capped(to: 2)
        try await store.saveSpeechPreferences(reset)
        let reopened = try await LibraryStore(root: root).speechPreferences()
        XCTAssertEqual(reopened.maximumRate, 2)
        XCTAssertEqual(reopened.rate, 2)
    }
    func testEightTimesSpeechAndBackwardCompatibleVoicePreferences() throws {
        let old = Data(#"{"rate":1.5,"maximumRate":2}"#.utf8)
        let legacy = try JSONDecoder().decode(SpeechPreferences.self, from: old)
        XCTAssertNil(legacy.voiceIdentifier)
        XCTAssertTrue(legacy.highlightSpokenText)
        let fast = SpeechPreferences(rate: 8, maximumRate: 8, voiceIdentifier: "test.voice", highlightSpokenText: false)
        try fast.validate()
        XCTAssertEqual(fast.capped(to: 4).rate, 4)
        XCTAssertEqual(fast.capped(to: 4).voiceIdentifier, "test.voice")
        XCTAssertFalse(fast.capped(to: 4).highlightSpokenText)
        XCTAssertEqual(try JSONDecoder().decode(SpeechPreferences.self, from: JSONEncoder().encode(fast)), fast)
        XCTAssertThrowsError(try SpeechPreferences(rate: 8.1, maximumRate: 8.1).validate())
        XCTAssertEqual(ReadingLayout.pages.title, "分页阅读")
        XCTAssertEqual(ReadingLayout.scroll.title, "连续滚动")
    }
    func testSpeechSelectionAndChunksPreserveComposedCharacters() throws {
        let text = String(repeating: "从选中处开始 👨‍👩‍👧‍👦 café 😀。", count: 60)
        let source = text as NSString
        var offset = 0, combined = ""
        while let range = SpeechTextSegment.range(in: text, from: offset, maximumLength: 31) {
            combined += source.substring(with: range)
            XCTAssertEqual(range, source.rangeOfComposedCharacterSequences(for: range))
            offset = NSMaxRange(range)
        }
        XCTAssertEqual(combined, text)
        XCTAssertNil(SpeechTextSegment.range(in: text, from: source.length))
        XCTAssertNil(SpeechTextSegment.range(in: text, from: 0, maximumLength: 0))
        let emoji = ("abc😀def" as NSString).range(of: "😀")
        XCTAssertEqual(SpeechTextSegment.range(in: "abc😀def", from: emoji.location + 1)?.location, emoji.location)
    }
    func testLibraryFiltersCollectionsTrashAndRestorePersist() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("A.txt")
        try Data("正文一\n正文二".utf8).write(to: source)
        let store = LibraryStore(root: root.appendingPathComponent("Library"))
        let first = try await store.importFile(source), id = first[0].id
        let collections = try await store.addCollection(title: "  文学  ")
        let duplicate = try await store.addCollection(title: "文学")
        XCTAssertEqual(duplicate.count, 1)
        _ = try await store.changeBook(id: id, change: .collection(collections[0].id, true))
        _ = try await store.changeBook(id: id, change: .favorite(true))
        _ = try await store.updateDocumentInfo(id: id, count: 2)
        var books = try await store.load()
        XCTAssertEqual(LibraryQuery.books(books, filter: .favorites, query: "A", sort: .title).count, 1)
        XCTAssertEqual(LibraryQuery.books(books, filter: .collection(collections[0].id), query: "", sort: .recent).count, 1)
        _ = try await store.changeBook(id: id, change: .finished(true))
        books = try await store.load()
        XCTAssertTrue(LibraryQuery.books(books, filter: .reading, query: "", sort: .recent).isEmpty)
        XCTAssertEqual(LibraryQuery.books(books, filter: .finished, query: "", sort: .recent).count, 1)
        _ = try await store.changeBook(id: id, change: .trash(true))
        books = try await store.load()
        XCTAssertTrue(LibraryQuery.books(books, filter: .all, query: "", sort: .recent).isEmpty)
        XCTAssertEqual(LibraryQuery.books(books, filter: .trash, query: "", sort: .recent).count, 1)
        _ = try await store.changeBook(id: id, change: .trash(false))
        books = try await LibraryStore(root: root.appendingPathComponent("Library")).load()
        XCTAssertEqual(books[0].isFavorite, true)
        XCTAssertEqual(books[0].totalUnitCount, 2)
        XCTAssertNil(books[0].trashedAt)
        let file = await store.fileURL(for: books[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testHighlightsAndBookmarksPersistWithRangeIntersection() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let id = UUID()
        let mark = ReadingMark(bookID: id, kind: .highlight, position: 12, resourceID: "OPS/a.xhtml", paragraphIndex: 3,
                               utf16Offset: 5, utf16Length: 10, quote: "高亮正文", color: .mint)
        _ = try await store.saveMark(mark)
        _ = try await store.saveMark(ReadingMark(bookID: id, kind: .bookmark, position: 12, quote: "书签"))
        let restored = try await LibraryStore(root: root).marks(for: id)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first(where: { $0.id == mark.id })?.color, .mint)
        XCTAssertEqual(mark.range(in: NSRange(location: 10, length: 20)), NSRange(location: 0, length: 5))
        XCTAssertNil(mark.range(in: NSRange(location: 30, length: 10)))
        let remaining = try await store.removeMark(id: mark.id, bookID: id)
        XCTAssertEqual(remaining.count, 1)
        let bad = ReadingMark(bookID: id, kind: .highlight, position: 0, utf16Offset: Int.max, utf16Length: 2, quote: "bad")
        do { _ = try await store.saveMark(bad); XCTFail("Invalid range must be rejected") } catch {}
        let unchanged = try await store.marks(for: id)
        XCTAssertEqual(unchanged.count, 1)
    }
    func testReadingSpeechAndTextOffsetRoundTrip() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        var reading = ReadingPreferences()
        reading.theme = .night; reading.font = .pingfang; reading.layout = .pages; reading.brightness = 0.6
        try await store.saveReadingPreferences(reading)
        let speech = SpeechPreferences(rate: 1.3, maximumRate: 1.5)
        try await store.saveSpeechPreferences(speech)
        let reopened = LibraryStore(root: root)
        let savedReading = try await reopened.readingPreferences(), savedSpeech = try await reopened.speechPreferences()
        XCTAssertEqual(savedReading, reading); XCTAssertEqual(savedSpeech, speech)
        let source = root.appendingPathComponent("Text.txt")
        try Data("长段正文".utf8).write(to: source)
        let books = try await store.importFile(source)
        _ = try await store.updatePosition(id: books[0].id, position: 0, textOffset: 3)
        let restoredBooks = try await store.load()
        XCTAssertEqual(restoredBooks[0].textOffset, 3)
    }
    @MainActor
    func testNativeTextLayoutFitsEveryPageSlice() throws {
        let paragraphs = [String(repeating: "中文排版与 english words，以及 😀。", count: 150)]
        for font in ReaderFont.allCases {
            var preferences = ReadingPreferences(); preferences.font = font
            let pages = try TextPaginator.paginate(paragraphs, preferences: preferences, width: 380, height: 360)
            for slice in pages.flatMap(\.slices) {
                let text = (paragraphs[slice.paragraph] as NSString).substring(with: slice.range)
                let storage = NSTextStorage(string: text, attributes: ReaderTypography.attributes(preferences))
                let layout = NSLayoutManager(), container = NSTextContainer(containerSize: NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                storage.addLayoutManager(layout); layout.addTextContainer(container)
                layout.ensureLayout(for: container)
                XCTAssertLessThanOrEqual(layout.usedRect(for: container).height, slice.height + 1, "Native layout clipping with \(font)")
            }
        }
    }
    func testConcurrentImportsDeduplicateAndKeepLibraryChanges() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Concurrent.txt")
        try Data("并行导入仍应只保留一本书".utf8).write(to: source)
        let store = LibraryStore(root: root.appendingPathComponent("Library"))
        async let first = store.importFile(source)
        async let second = store.importFile(source)
        _ = try await (first, second)
        let books = try await store.load()
        XCTAssertEqual(books.count, 1)
        _ = try await store.changeBook(id: books[0].id, change: .trash(true))
        let restored = try await store.importFile(source)
        XCTAssertEqual(restored.count, 1)
        XCTAssertNil(restored[0].trashedAt)
        XCTAssertEqual(restored[0].id, books[0].id)
    }

    func testRecentSpeechKeepsThreeUniqueBooksIndependentOfSearchAndPersistsClear() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        let store = LibraryStore(root: library)
        var ids: [UUID] = []
        for index in 0..<4 {
            let source = root.appendingPathComponent("Book\(index).txt")
            try Data("正文\(index)\n第二段".utf8).write(to: source)
            let result = try await store.importFile(source)
            ids.append(try XCTUnwrap(result.first { !ids.contains($0.id) }).id)
        }
        for (index, id) in ids.enumerated() {
            _ = try await store.recordSpeech(bookID: id, at: Date(timeIntervalSince1970: Double(index + 1)))
        }
        var history = try await store.speechHistory()
        XCTAssertEqual(history.map(\.bookID), [ids[3], ids[2], ids[1]])
        history = try await store.recordSpeech(bookID: ids[2], at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(history.map(\.bookID), [ids[2], ids[3], ids[1]])
        let books = try await store.updatePosition(id: ids[2], position: 1)
        XCTAssertTrue(LibraryQuery.books(books, filter: .all, query: "没有匹配", sort: .title).isEmpty)
        XCTAssertEqual(SpeechHistoryQuery.books(books, history: history).map(\.id), [ids[2], ids[3], ids[1]])
        let reopened = LibraryStore(root: library)
        let restored = try await reopened.speechHistory()
        XCTAssertEqual(restored, history)
        try await reopened.clearSpeechHistory()
        let again = LibraryStore(root: library)
        let cleared = try await again.speechHistory()
        XCTAssertTrue(cleared.isEmpty)
        let preserved = try await again.load()
        XCTAssertEqual(preserved.count, 4)
        XCTAssertEqual(preserved.first { $0.id == ids[2] }?.position, 1)
        let recorded = try await again.recordSpeech(bookID: ids[0])
        XCTAssertEqual(recorded.map(\.bookID), [ids[0]])
    }
    func testLegacyRecentReadingSeedsSpeechHistoryOnlyOnce() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Legacy.txt")
        try Data("旧版阅读记录\n继续阅读".utf8).write(to: source)
        let library = root.appendingPathComponent("Library")
        let store = LibraryStore(root: library)
        let books = try await store.importFile(source)
        let id = try XCTUnwrap(books.first).id
        _ = try await store.updatePosition(id: id, position: 1)
        let migrated = try await store.speechHistory()
        XCTAssertEqual(migrated.map(\.bookID), [id])
        try await store.clearSpeechHistory()
        let reopened = LibraryStore(root: library)
        let history = try await reopened.speechHistory()
        XCTAssertTrue(history.isEmpty)
    }

    private func directory() throws -> URL {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = project.appendingPathComponent(".agents/test/reading-features/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
