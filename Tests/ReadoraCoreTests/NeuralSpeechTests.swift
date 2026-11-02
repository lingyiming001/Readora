import XCTest
import AVFoundation
import ReadoraCore
import ReadoraKokoroRuntime

final class NeuralSpeechTests: XCTestCase {
    func testNeuralVoiceCatalogUsesUniqueStableIdentifiers() {
        XCTAssertEqual(Set(NeuralSpeechVoice.all.map(\.id)).count, NeuralSpeechVoice.all.count)
        XCTAssertEqual(NeuralSpeechVoice.all.filter { $0.id.hasPrefix("kokoro:") }.count, 15)
        XCTAssertEqual(NeuralSpeechVoice.all.filter { $0.id.hasPrefix("qwen:") }.count, 0)
        XCTAssertEqual(SpeechPreferences().maximumRate, 2)
    }
    func testPreparedModelsGenerateOfflineAndApplyPhraseCorrections() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = KokoroEngine()
        for (folder, kind, speaker, corrected) in [
            ("Kokoro", SherpaTTSModel.kokoro, 56, "还款 ㄏ 万 2 ㄎ 万 3")
        ] {
            let root = project.appendingPathComponent("Resources/iOS/" + folder)
            guard KokoroEngine.isInstalled(at: root, kind: kind) else { throw XCTSkip("Run model preparation scripts for offline inference validation") }
            let audio = try await engine.render(text: "请在银行办理还款，重庆的行长正在听音乐。", speaker: speaker, root: root, kind: kind)
            XCTAssertGreaterThan(audio.sampleRate, 0)
            XCTAssertGreaterThan(audio.samples.count, audio.sampleRate)
            XCTAssertTrue(audio.samples.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(audio.samples.map { abs($0) }.max() ?? 0, 0.001)
            let lexicon = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ReadoraPronunciation/v1/" + "kokoro-zh.txt")
            let content = try String(contentsOf: lexicon, encoding: .utf8)
            XCTAssertTrue(content.split(separator: "\n").contains { $0 == corrected })
        }
        await engine.unload()
    }
    func testRemovedVoicePreferencesMigrateWithoutChangingRate() throws {
        for id in [nil, "melo:0", "com.apple.voice.compact.zh-CN.Tingting", "unknown"] as [String?] {
            XCTAssertEqual(NeuralSpeechVoice.resolvedIdentifier(id), "kokoro:56")
        }
        for voice in NeuralSpeechVoice.all {
            XCTAssertEqual(NeuralSpeechVoice.resolvedIdentifier(voice.id), voice.id)
        }
    }
    func testLightModelBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["READORA_LIGHT_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in model benchmark") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = KokoroEngine()
        for folder in ["Resources/iOS/Kokoro", ".build/kokoro-light"] {
            let root = project.appendingPathComponent(folder)
            for (text, speaker, speed) in [("你好。", 56, Float(1)), ("银行的行长正在办理还款。重庆的音乐很好听。", 56, 1), ("Hello, welcome to Readora. Enjoy your reading.", 0, 1), ("今天我们学习 English，明天再去重庆。", 102, 1.5), ("好。", 56, 0.5), ("行长。", 56, 2)] {
                let start = Date()
                let audio = try await engine.render(text: text, speaker: speaker, root: root, speed: speed)
                XCTAssertTrue(audio.samples.allSatisfy(\.isFinite))
                XCTAssertGreaterThan(audio.samples.count, 1000)
                print("KOKORO_BENCH root=\(folder) text=\(text) speaker=\(speaker) speed=\(speed) elapsed=\(Date().timeIntervalSince(start)) audio=\(Double(audio.samples.count)/Double(audio.sampleRate)) peak=\(audio.samples.map { abs($0) }.max() ?? 0)")
            }
            await engine.unload()
        }
    }
    func testPronunciationDictionaryConvertsToneNumbersAndMarks() throws {
        let entries = try PronunciationDictionary.parse("银行 = yin2 hang2\n行长 = háng zhǎng\n重庆 = chong2 qing4\n女绿 = nv3 lü4\n音乐 = yin1 yue4")
        XCTAssertEqual(entries["银行"], "阴 2 ㄏ ㄤ 2")
        XCTAssertEqual(entries["行长"], "ㄏ ㄤ 2 ㄓ ㄤ 3")
        XCTAssertEqual(entries["重庆"], "ㄔ 中 2 ㄑ 应 4")
        XCTAssertEqual(entries["女绿"], "ㄋ ㄩ 3 ㄌ ㄩ 4")
        XCTAssertEqual(entries["音乐"], "阴 1 月 4")
        XCTAssertEqual(try PronunciationDictionary.phonemes("zhi1"), "ㄓ 十 1")
        XCTAssertEqual(try PronunciationDictionary.phonemes("ci4"), "ㄘ ㄭ 4")
        XCTAssertEqual(try PronunciationDictionary.phonemes("xue2"), "ㄒ 月 2")
        XCTAssertEqual(try PronunciationDictionary.phonemes("yuan2"), "元 2")
        for invalid in ["银行 yin2 hang2", "银行 = yin2", "银行 = yin6 hang2", "银行 = y!n2 hang2", "银行 = yín4 hang2", "bank = yin2 hang2", "银行 = yin2 hang2\n银行 = yin2 xing2"] {
            XCTAssertThrowsError(try PronunciationDictionary.parse(invalid), invalid)
        }
        let preferences = SpeechPreferences(pronunciationDictionary: "银行 = yin2 hang2")
        XCTAssertEqual(try JSONDecoder().decode(SpeechPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
        XCTAssertEqual(preferences.capped(to: 1.5).pronunciationDictionary, preferences.pronunciationDictionary)
        let old = Data(#"{"rate":1,"maximumRate":2,"voiceIdentifier":"kokoro:56"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SpeechPreferences.self, from: old).pronunciationDictionary, "")
    }
    func testPhraseBoundariesKeepQuotesAndDictionaryWords() throws {
        let quote = "她说：“今天银行的行长会过来。”然后我们一起学习 English。"
        let first = try XCTUnwrap(SpeechTextSegment.phraseRange(in: quote, from: 0))
        XCTAssertEqual((quote as NSString).substring(with: first), "她说：“今天银行的行长会过来。”")
        let source = String(repeating: "文", count: 78) + "银行行长已经到了。"
        let range = try XCTUnwrap(SpeechTextSegment.phraseRange(in: source, from: 0, protectedWords: ["银行行长"]))
        XCTAssertEqual(NSMaxRange(range), 82)
        var offset = 0, reconstructed = ""
        while let range = SpeechTextSegment.phraseRange(in: quote, from: offset, maximumLength: 12) {
            reconstructed += (quote as NSString).substring(with: range); offset = NSMaxRange(range)
        }
        XCTAssertEqual(reconstructed, quote)
    }
    func testDictionaryReloadInvalidatesPCMCache() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("Resources/iOS/Kokoro")
        guard KokoroEngine.isInstalled(at: root) else { throw XCTSkip("Model not installed") }
        let engine = KokoroEngine()
        let a = try await engine.render(text: "银行。", speaker: 56, root: root, corrections: ["银行":"阴 2 ㄏ ㄤ 2"])
        let cached = try await engine.render(text: "银行。", speaker: 56, root: root, corrections: ["银行":"阴 2 ㄏ ㄤ 2"])
        XCTAssertEqual(a.samples, cached.samples)
        let b = try await engine.render(text: "银行。", speaker: 56, root: root, corrections: ["银行":"阴 2 ㄒ 应 2"])
        XCTAssertNotEqual(a.samples, b.samples)
        XCTAssertTrue(b.samples.allSatisfy(\.isFinite))
        await engine.releaseAfterIdle()
        let c = try await engine.render(text: "银行。", speaker: 56, root: root, corrections: ["银行":"阴 2 ㄒ 应 2"])
        XCTAssertEqual(b.samples, c.samples)
        await engine.unload()
    }
    func testInferenceThreadBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["READORA_THREAD_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in thread benchmark") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("Resources/iOS/Kokoro")
        for threads in [2, 4, 1, 3] {
            let engine = KokoroEngine(threadCount: threads)
            let cold = Date()
            _ = try await engine.render(text: "你好，欢迎阅读。", speaker: 56, root: root)
            print("THREAD_COLD threads=\(threads) seconds=\(Date().timeIntervalSince(cold))")
            for text in ["银行的行长正在办理还款。重庆的音乐很好听。", "Hello, welcome to Readora. Enjoy your reading.", "今天我们学习 English，明天再去重庆。"] {
                let start = Date()
                let audio = try await engine.render(text: text, speaker: 56, root: root)
                XCTAssertTrue(audio.samples.allSatisfy(\.isFinite))
                print("THREAD_BENCH threads=\(threads) seconds=\(Date().timeIntervalSince(start)) audio=\(Double(audio.samples.count)/Double(audio.sampleRate))")
            }
            await engine.unload()
        }
    }
    func testOrderedCursorKeepsSourceOffsetsAndSkipsSilentTails() throws {
        let content = String(repeating: "今天在重庆银行办理业务，", count: 18) + "结束了。”"
        let paragraphs = ["\n", "……", content, "Dr. Smith paid 3.14 dollars. Then he left."]
        var cursor = SpeechChunkCursor(paragraphs: paragraphs, paragraph: 0, offset: 0, protectedWords: ["重庆", "银行"])
        var reconstructed: [Int: String] = [:]
        var chunks: [SpeechChunk] = []
        while let chunk = cursor.next() {
            chunks.append(chunk)
            reconstructed[chunk.paragraph, default: ""] += (paragraphs[chunk.paragraph] as NSString).substring(with: chunk.range)
        }
        XCTAssertEqual(chunks.first?.paragraph, 2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(chunks.first).range.length, 40)
        XCTAssertEqual(reconstructed[2], content)
        XCTAssertEqual(reconstructed[3], paragraphs[3])
        XCTAssertNil(cursor.next())
        let english = try XCTUnwrap(SpeechTextSegment.phraseRange(in: paragraphs[3], from: 0))
        XCTAssertEqual((paragraphs[3] as NSString).substring(with: english), "Dr. Smith paid 3.14 dollars.")
        let quote = try XCTUnwrap(SpeechTextSegment.phraseRange(in: "银行。”再说。", from: 0, maximumLength: 3))
        XCTAssertEqual(quote.length, 4)
        var resumed = SpeechChunkCursor(paragraphs: [content], paragraph: 0, offset: 12)
        XCTAssertEqual(resumed.next()?.range.location, 12)
    }
    func testStartupChunkBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["READORA_STARTUP_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in startup benchmark") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = "今天我们准备去重庆的一家银行办理业务顺便了解新的服务随后大家一起回到图书馆讨论昨天读过的书籍并分享各自喜欢的音乐和旅行故事希望每个人都能在忙碌的生活中找到适合自己的阅读时间和安静空间。"
        for limit in [80, 40] {
            let range = try XCTUnwrap(SpeechTextSegment.phraseRange(in: text, from: 0, maximumLength: limit))
            let engine = KokoroEngine()
            let start = Date()
            let audio = try await engine.render(text: (text as NSString).substring(with: range), speaker: 56, root: project.appendingPathComponent("Resources/iOS/Kokoro"))
            print("STARTUP_BENCH limit=\(limit) chars=\(range.length) cold=\(Date().timeIntervalSince(start)) audio=\(Double(audio.samples.count)/Double(audio.sampleRate))")
            XCTAssertTrue(audio.samples.allSatisfy(\.isFinite))
            await engine.unload()
        }
    }
    func testFastPlaybackThroughput() async throws {
        guard ProcessInfo.processInfo.environment["READORA_FAST_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in high speed throughput") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("Resources/iOS/Kokoro")
        let engine = KokoroEngine()
        _ = try await engine.render(text: "你好，欢迎阅读。", speaker: 56, root: root)
        for speed in [Float(2), 3, 4] {
            for text in ["你好。欢迎阅读。我们今天去银行。行长正在等你。别着急。先听一首音乐。然后出发。重庆是一个很好的地方。", "今天我们准备去重庆的一家银行办理业务，随后大家一起回到图书馆讨论昨天读过的书籍，并分享各自喜欢的音乐和旅行故事。"] {
                let start = Date()
                let audio = try await engine.render(text: text, speaker: 56, root: root, speed: speed)
                let elapsed = Date().timeIntervalSince(start)
                let playback = Double(audio.samples.count) / Double(audio.sampleRate) / (4 / Double(speed))
                XCTAssertTrue(audio.samples.allSatisfy(\.isFinite))
                print("FAST_BENCH speed=\(speed) generate=\(elapsed) playAt4=\(playback) RTF4=\(elapsed/playback)")
            }
        }
        await engine.unload()
    }
    func testDigitalPaddingCompactionPreservesAllNonzeroSamples() {
        let voice: [Float] = [0.00000001, 0.2, -0.1, 0.00000001]
        let source = KokoroAudio(samples: Array(repeating: 0, count: 500) + voice + Array(repeating: 0, count: 600), sampleRate: 1000)
        let compact = source.compactingDigitalPadding()
        XCTAssertEqual(compact.samples.count, 120 + voice.count + 160)
        XCTAssertEqual(Array(compact.samples[120..<124]), voice)
        XCTAssertEqual(compact.compactingDigitalPadding().samples, compact.samples)
        let silence = KokoroAudio(samples: Array(repeating: 0, count: 400), sampleRate: 1000)
        XCTAssertEqual(silence.compactingDigitalPadding().samples, silence.samples)
    }
    func testStreamingKeepsShortFirstChunkThenMergesShortSentences() {
        let text = String(repeating: "今天读书。窗外很安静。我们继续阅读。", count: 20)
        var cursor = SpeechChunkCursor(paragraphs: [text], paragraph: 0, offset: 0, initialLength: 24, mergeAfterFirst: true)
        var chunks: [String] = []
        while let chunk = cursor.next() { chunks.append((text as NSString).substring(with: chunk.range)) }
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertLessThanOrEqual((chunks[0] as NSString).length, 24)
        XCTAssertGreaterThan(chunks[1].count, chunks[0].count)
    }
    func testShortStartupChunkPreservesSourceAndProtectedWord() {
        let text = String(repeating: "甲😀这是测试正文，今天去重庆银行办理业务。", count: 12)
        let source = text as NSString
        var cursor = SpeechChunkCursor(paragraphs: [text], paragraph: 0, offset: 0, protectedWords: ["重庆银行"], initialLength: 24)
        var pieces: [String] = []
        while let chunk = cursor.next() {
            XCTAssertEqual(source.rangeOfComposedCharacterSequences(for: chunk.range), chunk.range)
            pieces.append(source.substring(with: chunk.range))
        }
        XCTAssertEqual(pieces.joined(), text)
        XCTAssertLessThanOrEqual((pieces[0] as NSString).length, 26)
        XCTAssertFalse(pieces.contains { $0.hasSuffix("重庆") })
    }
    func testPreparedOrExplicitImmediatePlaybackDoesNotWaitForInferenceReserve() {
        var buffer = SpeechBufferState(rate: 4)
        XCTAssertFalse(buffer.canStart(at: 0, exhausted: false, immediately: true))
        buffer.append(audioSeconds: 2, modelSpeed: 1, generationSeconds: 3)
        XCTAssertFalse(buffer.canStart(at: 0, exhausted: false))
        XCTAssertTrue(buffer.canStart(at: 0, exhausted: false, immediately: true))
        XCTAssertEqual(buffer.rate, 4)
        buffer.resume(at: 0)
        buffer.completed(at: 0.5)
        XCTAssertFalse(buffer.canStart(at: 1, exhausted: true, immediately: true))
    }
    func testHighSpeedBufferTracksWallTimeAndPause() {
        var buffer = SpeechBufferState(rate: 4)
        for _ in 0..<3 { buffer.append(audioSeconds: 6, modelSpeed: 2, generationSeconds: 0.5) }
        XCTAssertEqual(buffer.seconds(at: 0), 9)
        XCTAssertFalse(buffer.canStart(at: 0, exhausted: false))
        buffer.append(audioSeconds: 6, modelSpeed: 2, generationSeconds: 0.5)
        XCTAssertTrue(buffer.canStart(at: 0, exhausted: false))
        buffer.resume(at: 10)
        XCTAssertEqual(buffer.seconds(at: 12), 10)
        buffer.pause(at: 12)
        XCTAssertEqual(buffer.seconds(at: 100), 10)
        buffer.resume(at: 100)
        XCTAssertEqual(buffer.seconds(at: 101), 9)
        buffer.completed(at: 101)
        XCTAssertEqual(buffer.seconds(at: 101), 9)
        XCTAssertTrue(buffer.needsMore(at: 101))
        var slow = SpeechBufferState(rate: 4)
        slow.append(audioSeconds: 4, modelSpeed: 2, generationSeconds: 3)
        XCTAssertGreaterThan(slow.startupSeconds, buffer.startupSeconds)
        XCTAssertTrue(slow.canStart(at: 0, exhausted: true))
        var two = SpeechBufferState(rate: 2)
        two.append(audioSeconds: 6, modelSpeed: 2, generationSeconds: 0.5)
        XCTAssertTrue(two.canStart(at: 0, exhausted: false))
    }
    func testBufferBoundsAndEndOfTextAvoidDeadlock() {
        var buffer = SpeechBufferState(rate: 4)
        for _ in 0..<64 { buffer.append(audioSeconds: 0.1, modelSpeed: 2, generationSeconds: 0.02) }
        XCTAssertFalse(buffer.needsMore(at: 0))
        XCTAssertTrue(buffer.canStart(at: 0, exhausted: false))
        var short = SpeechBufferState(rate: 4)
        short.append(audioSeconds: 0.3, modelSpeed: 2, generationSeconds: 0.3)
        XCTAssertFalse(short.canStart(at: 0, exhausted: false))
        XCTAssertTrue(short.canStart(at: 0, exhausted: true))
        short.resume(at: 0)
        short.completed(at: 0.15)
        XCTAssertFalse(short.isRunning)
        XCTAssertEqual(short.seconds(at: 1), 0)
        XCTAssertFalse(short.canStart(at: 1, exhausted: true))
        XCTAssertTrue(short.needsMore(at: 1))
    }
    func testSourceSelectionMapsPageOffsetsAndComposedCharacters() {
        XCTAssertEqual(SpeechTextSegment.sourceSelection(NSRange(location: 1, length: 1), in: "A😀中", sourceOffset: 12), NSRange(location: 13, length: 2))
        XCTAssertEqual(SpeechTextSegment.sourceSelection(NSRange(location: 2, length: 1), in: "A😀中"), NSRange(location: 1, length: 2))
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: 0, length: 0), NSRange(location: 4, length: 2)] {
            XCTAssertNil(SpeechTextSegment.sourceSelection(range, in: "A😀中"))
        }
        XCTAssertNil(SpeechTextSegment.sourceSelection(NSRange(location: 0, length: 1), in: "中", sourceOffset: Int.max))
    }
    func testContinuousChunkingPreservesCompleteText() {
        let text = "你好。欢迎阅读。我们今天去银行。行长正在等你。随后去重庆。"
        var cursor = SpeechChunkCursor(paragraphs: [text], paragraph: 0, offset: 0, continuous: true)
        var parts: [String] = []
        while let chunk = cursor.next() { parts.append((text as NSString).substring(with: chunk.range)) }
        XCTAssertEqual(parts.joined(), text)
        XCTAssertGreaterThan(parts[0].count, 3)
        XCTAssertLessThan(parts.count, 5)
    }
    func testPreparedAudioIsOneContinuousFileAndReusable() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("Resources/iOS/Kokoro")
        guard KokoroEngine.isInstalled(at: root) else { throw XCTSkip("Model not installed") }
        let engine = KokoroEngine()
        let texts = ["银行的行长。", "我们一起去重庆。"]
        let destination = project.appendingPathComponent(".agents/test/prepared-audio/" + UUID().uuidString, isDirectory: true)
        let result = try await engine.prepare(texts: texts, speaker: 56, root: root, speed: 2, corrections: [:], directory: destination) { _ in }
        XCTAssertEqual(result.frames.count, 2)
        XCTAssertEqual(result.frames[0].upperBound, result.frames[1].lowerBound)
        let file = try AVAudioFile(forReading: result.file)
        XCTAssertEqual(file.length, result.frames[1].upperBound)
        let first = try result.readChunk(0), second = try result.readChunk(1)
        let reference1 = try await engine.render(text: texts[0], speaker: 56, root: root, speed: 2)
        let reference2 = try await engine.render(text: texts[1], speaker: 56, root: root, speed: 2)
        XCTAssertEqual(first.samples, reference1.samples)
        XCTAssertEqual(second.samples, reference2.samples)
        XCTAssertEqual(Int64(first.samples.count + second.samples.count), file.length)
        XCTAssertThrowsError(try result.readChunk(2))
        let preferences = SpeechPreferences(rate: 4, maximumRate: 4, cacheBeforePlayback: true)
        XCTAssertTrue(try JSONDecoder().decode(SpeechPreferences.self, from: JSONEncoder().encode(preferences)).cacheBeforePlayback)
        XCTAssertTrue(preferences.capped(to: 2).cacheBeforePlayback)
        let again = try await engine.prepare(texts: texts, speaker: 56, root: root, speed: 2, corrections: [:], directory: destination) { _ in }
        XCTAssertEqual(again.file, result.file)
        XCTAssertEqual(again.frames, result.frames)
        let reader = try again.makeReader()
        try FileManager.default.removeItem(at: again.file)
        XCTAssertEqual(try reader.readChunk(0).samples, first.samples)
        await engine.unload()
    }
}
