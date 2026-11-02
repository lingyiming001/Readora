import Foundation
import AVFoundation
import CryptoKit
import SherpaOnnxC

public struct KokoroAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public init(samples: [Float], sampleRate: Int) { self.samples = samples; self.sampleRate = sampleRate }

    /// Remove only exact digital zero padding; quiet consonants and breaths remain untouched.
    public func compactingDigitalPadding() -> Self {
        guard sampleRate > 0, let first = samples.firstIndex(where: { $0 != 0 }),
              let last = samples.lastIndex(where: { $0 != 0 }) else { return self }
        let start = max(0, first - Int(Double(sampleRate) * 0.12))
        let end = min(samples.count, last + 1 + Int(Double(sampleRate) * 0.16))
        guard start > 0 || end < samples.count else { return self }
        return Self(samples: Array(samples[start..<end]), sampleRate: sampleRate)
    }

}

/// Offline model families served through the shared sherpa-onnx runtime.
public enum SherpaTTSModel: Hashable, Sendable {
    case kokoro
    var requiredFiles: [String] {
        switch self {
        case .kokoro: ["model.onnx", "voices.bin", "tokens.txt", "lexicon-zh.txt", "lexicon-us-en.txt", "espeak-ng-data"]
        }
    }
}

public enum KokoroError: LocalizedError {
    case missingModel, initialization, synthesis
    public var errorDescription: String? {
        switch self {
        case .missingModel: "离线语音模型未安装，请运行项目的模型准备脚本后重新构建。"
        case .initialization: "无法加载离线语音模型，请检查模型文件和手机可用内存。"
        case .synthesis: "离线模型未生成有效音频，请缩短文本或切换其他离线音色。"
        }
    }
}

/// Serializes native inference and keeps model construction off the UI thread.
/// Only one model family stays resident at a time; loading a different family
/// evicts the previous one so two large ONNX graphs never compete for memory.
public actor KokoroEngine {
    public static let shared = KokoroEngine()
    private final class Handle: @unchecked Sendable {
        let pointer: OpaquePointer
        let kind: SherpaTTSModel
        init(_ pointer: OpaquePointer, kind: SherpaTTSModel) { self.pointer = pointer; self.kind = kind }
        deinit { SherpaOnnxDestroyOfflineTts(pointer) }
    }
    private var handle: Handle?
    private var idleRelease: Task<Void, Never>?
    private struct CacheKey: Hashable { let text: String; let speaker: Int; let speed: Float }
    private var cache: [(CacheKey, KokoroAudio)] = []
    private var loadedCorrections: [String: String] = [:]
    private var speakerIDs: [Int]?
    private let threadCount: Int
    public init(threadCount: Int? = nil) {
        let measured = UserDefaults.standard.integer(forKey: "ReadoraKokoroThreads.v1")
        let automatic = (2...4).contains(measured) ? measured : min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        self.threadCount = min(8, max(1, threadCount ?? automatic))
    }
    public nonisolated static func isInstalled(at root: URL, kind: SherpaTTSModel = .kokoro) -> Bool {
        kind.requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }
    public func render(text: String, speaker: Int, root: URL, speed: Float = 1, kind: SherpaTTSModel = .kokoro, corrections: [String: String] = [:]) throws -> KokoroAudio {
        idleRelease?.cancel(); idleRelease = nil
        try Task.checkCancellation()
        guard Self.isInstalled(at: root, kind: kind) else { throw KokoroError.missingModel }
        if handle?.kind != kind || loadedRoot != root || loadedCorrections != corrections {
            try load(root, kind: kind, corrections: corrections)
        }
        let speed = speed.isFinite ? min(max(speed, 0.5), 4) : 1
        let key = CacheKey(text: text, speaker: speaker, speed: speed)
        if let index = cache.firstIndex(where: { $0.0 == key }) {
            let hit = cache.remove(at: index); cache.append(hit); return hit.1
        }
        let speaker = speakerIDs?.firstIndex(of: speaker) ?? (speakerIDs == nil ? speaker : -1)
        guard let handle, (0..<Int(SherpaOnnxOfflineTtsNumSpeakers(handle.pointer))).contains(speaker) else { throw KokoroError.initialization }
        var config = SherpaOnnxGenerationConfig()
        config.sid = Int32(speaker); config.speed = speed.isFinite ? min(max(speed, 0.5), 4) : 1; config.silence_scale = 0.15
        guard let audio = text.withCString({ SherpaOnnxOfflineTtsGenerateWithConfig(handle.pointer, $0, &config, nil, nil) }) else { throw KokoroError.synthesis }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        try Task.checkCancellation()
        guard let samples = audio.pointee.samples, audio.pointee.n > 0, audio.pointee.n <= 48_000 * 120,
              audio.pointee.sample_rate > 0 else { throw KokoroError.synthesis }
        #if DEBUG
        if ProcessInfo.processInfo.environment["READORA_SPEECH_SMOKE"] == "1" {
            print("KOKORO_SMOKE_OK kind=\(kind) samples=\(audio.pointee.n) sampleRate=\(audio.pointee.sample_rate)")
        }
        #endif
        let values = Array(UnsafeBufferPointer(start: samples, count: Int(audio.pointee.n)))
        guard values.allSatisfy(\.isFinite), values.contains(where: { abs($0) > 0.00001 }) else { throw KokoroError.synthesis }
        let result = KokoroAudio(samples: values, sampleRate: Int(audio.pointee.sample_rate)).compactingDigitalPadding()
        cache.append((key, result))
        // At most twenty seconds of PCM (about 2 MB at 24 kHz), even for repeated previews.
        while cache.reduce(0, { $0 + $1.1.samples.count }) > 24_000 * 20 { cache.removeFirst() }
        return result
    }
    private var loadedRoot: URL?
    /// Phrase overrides change phonemes, never the source text or UTF-16 positions.
    private func correctedLexicon(_ source: URL, kind: SherpaTTSModel, corrections custom: [String: String]) throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReadoraPronunciation/v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("kokoro-zh.txt")
        let stamp = try source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let signature = "\(source.path)|\(stamp.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(stamp.fileSize ?? 0)|" + custom.keys.sorted().map { $0 + "=" + custom[$0]! }.joined(separator: "|")
        let marker = destination.appendingPathExtension("source")
        if FileManager.default.fileExists(atPath: destination.path), (try? String(contentsOf: marker, encoding: .utf8)) == signature { return destination }
        var corrections = ["还款": "ㄏ 万 2 ㄎ 万 3", "还款日": "ㄏ 万 2 ㄎ 万 3 ㄖ 十 4", "还款额": "ㄏ 万 2 ㄎ 万 3 ㄜ 2"]
        corrections.merge(custom) { _, new in new }
        let original = try String(contentsOf: source, encoding: .utf8)
        var lines = original.split(separator: "\n").filter { line in
            let word = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return corrections[word] == nil
        }.map(String.init)
        lines += corrections.keys.sorted().map { $0 + " " + corrections[$0]! }
        try (lines.joined(separator: "\n") + "\n").write(to: destination, atomically: true, encoding: .utf8)
        try signature.write(to: marker, atomically: true, encoding: .utf8)
        return destination
    }
    private func load(_ root: URL, kind: SherpaTTSModel, corrections: [String: String]) throws {
        // Release the old native session before constructing another graph.
        handle = nil; loadedRoot = nil; cache.removeAll()
        let manifest = try? Data(contentsOf: root.appendingPathComponent("readora-model.json"))
        speakerIDs = manifest.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["speaker_ids"] as? [Int]
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func cString(_ value: String) -> UnsafePointer<CChar>? {
            guard let pointer = strdup(value) else { return nil }
            strings.append(pointer); return UnsafePointer(pointer)
        }
        var config = SherpaOnnxOfflineTtsConfig()
        switch kind {
        case .kokoro:
            config.model.kokoro.model = cString(root.appendingPathComponent("model.onnx").path)
            config.model.kokoro.voices = cString(root.appendingPathComponent("voices.bin").path)
            config.model.kokoro.tokens = cString(root.appendingPathComponent("tokens.txt").path)
            config.model.kokoro.data_dir = cString(root.appendingPathComponent("espeak-ng-data").path)
            config.model.kokoro.lexicon = cString(try ["lexicon-us-en.txt", "lexicon-zh.txt"].map { ($0 == "lexicon-zh.txt" ? try correctedLexicon(root.appendingPathComponent($0), kind: kind, corrections: corrections) : root.appendingPathComponent($0)).path }.joined(separator: ","))
            config.model.kokoro.length_scale = 1
        }
        config.model.provider = cString("cpu")
        // Match inference threads to the device; two threads starves short-chunk pipelines on 6-core phones.
        config.model.num_threads = Int32(threadCount)
        config.max_num_sentences = 1; config.silence_scale = 0.15
        let rules = ["date-zh.fst", "number-zh.fst", "phone-zh.fst"]
        let found = rules.map { root.appendingPathComponent($0).path }.filter { FileManager.default.fileExists(atPath: $0) }
        if !found.isEmpty { config.rule_fsts = cString(found.joined(separator: ",")) }
        guard let pointer = SherpaOnnxCreateOfflineTts(&config) else { throw KokoroError.initialization }
        handle = Handle(pointer, kind: kind); loadedRoot = root; loadedCorrections = corrections
    }
    /// Prepare a complete reading section to a single local PCM file. Playback then needs no inference.
    public func prepare(texts: [String], speaker: Int, root: URL, speed: Float, corrections: [String: String], directory: URL? = nil, progress: @Sendable (Int) -> Void) throws -> KokoroPreparedAudio {
        try Task.checkCancellation()
        let stamp = try root.appendingPathComponent("model.onnx").resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let modelManifest = (try? Data(contentsOf: root.appendingPathComponent("readora-model.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let modelIdentity = modelManifest?["model_sha256"] as? String ?? "\(root.path)|\(stamp.fileSize ?? 0)|\(stamp.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let signature = ["v3-digital-padding", modelIdentity, String(speaker), String(speed)] + corrections.keys.sorted().map { $0 + "=" + corrections[$0]! } + texts
        let digest = SHA256.hash(data: try JSONEncoder().encode(signature)).map { String(format: "%02x", $0) }.joined()
        let directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ReadoraSpeech/Prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(digest + ".caf")
        let manifest = directory.appendingPathComponent(digest + ".json")
        if let data = try? Data(contentsOf: manifest), let stored = try? JSONDecoder().decode(KokoroPreparedAudio.self, from: data),
           stored.file == output, stored.frames.count == texts.count,
           let audio = try? AVAudioFile(forReading: output), audio.length == stored.frames.last?.upperBound {
            progress(texts.count); return stored
        }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".caf")
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: temporary) } }
        var writer: AVAudioFile?
        var ranges: [Range<Int64>] = []
        var position: Int64 = 0
        var sampleRate = 24000
        for (index, text) in texts.enumerated() {
            try Task.checkCancellation()
            let audio = try render(text: text, speaker: speaker, root: root, speed: speed, corrections: corrections)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(audio.sampleRate), channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)) else { throw KokoroError.synthesis }
            if writer == nil { writer = try AVAudioFile(forWriting: temporary, settings: format.settings); sampleRate = audio.sampleRate }
            guard sampleRate == audio.sampleRate else { throw KokoroError.synthesis }
            buffer.frameLength = buffer.frameCapacity
            audio.samples.withUnsafeBufferPointer { input in
                if let base = input.baseAddress { buffer.floatChannelData![0].update(from: base, count: input.count) }
            }
            try writer?.write(from: buffer)
            ranges.append(position..<(position + Int64(audio.samples.count)))
            position += Int64(audio.samples.count)
            progress(index + 1)
        }
        guard position > 0 else { throw KokoroError.synthesis }
        writer = nil
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        try FileManager.default.moveItem(at: temporary, to: output)
        committed = true
        let result = KokoroPreparedAudio(file: output, frames: ranges, sampleRate: sampleRate)
        try JSONEncoder().encode(result).write(to: manifest, options: .atomic)
        // Keep the newly prepared section; evict older cached sections above a 512 MB budget.
        let old = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let files = old.filter { $0.pathExtension == "caf" }.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var size = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        for file in files where file != output && size > 512 * 1024 * 1024 {
            size -= Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.deletingPathExtension().appendingPathExtension("json"))
        }
        return result
    }
    public func releaseAfterIdle() {
        idleRelease?.cancel()
        idleRelease = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await self?.unload()
        }
    }
    public func unload() {
        idleRelease?.cancel(); idleRelease = nil
        handle = nil; loadedRoot = nil; cache.removeAll(); loadedCorrections = [:]; speakerIDs = nil
    }
}

public struct KokoroPreparedAudio: Codable, Sendable {
    public let file: URL
    public let frames: [Range<Int64>]
    public let sampleRate: Int
    public func readChunk(_ index: Int) throws -> KokoroAudio { try makeReader().readChunk(index) }
    public func makeReader() throws -> KokoroPreparedAudioReader { try KokoroPreparedAudioReader(self) }
}

/// Keep an open descriptor for the whole playback; cache eviction cannot interrupt an active reader.
public final class KokoroPreparedAudioReader: @unchecked Sendable {
    private let metadata: KokoroPreparedAudio
    private let audio: AVAudioFile
    private let lock = NSLock()
    fileprivate init(_ metadata: KokoroPreparedAudio) throws {
        self.metadata = metadata
        audio = try AVAudioFile(forReading: metadata.file, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    public func readChunk(_ index: Int) throws -> KokoroAudio {
        try lock.withLock {
            try Task.checkCancellation()
            guard metadata.frames.indices.contains(index), metadata.frames[index].count > 0,
                  metadata.frames[index].count <= Int(UInt32.max) else { throw KokoroError.synthesis }
            let range = metadata.frames[index]
            audio.framePosition = range.lowerBound
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else { throw KokoroError.synthesis }
            var samples: [Float] = []
            samples.reserveCapacity(range.count)
            while samples.count < range.count {
                try Task.checkCancellation()
                buffer.frameLength = 0
                try audio.read(into: buffer, frameCount: buffer.frameCapacity)
                guard buffer.frameLength > 0, let values = buffer.floatChannelData?[0] else { throw KokoroError.synthesis }
                let count = min(range.count - samples.count, Int(buffer.frameLength))
                samples.append(contentsOf: UnsafeBufferPointer(start: values, count: count))
            }
            return KokoroAudio(samples: samples, sampleRate: metadata.sampleRate)
        }
    }
}
