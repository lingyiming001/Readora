import Foundation
import SherpaOnnxC

public struct KokoroAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
}

/// Offline model families served through the shared sherpa-onnx runtime.
public enum SherpaTTSModel: Hashable, Sendable {
    case kokoro
    case melo
    var requiredFiles: [String] {
        switch self {
        case .kokoro: ["model.onnx", "voices.bin", "tokens.txt", "lexicon-zh.txt", "lexicon-us-en.txt", "espeak-ng-data"]
        case .melo: ["model.onnx", "lexicon.txt", "tokens.txt", "dict"]
        }
    }
}

public enum KokoroError: LocalizedError {
    case missingModel, initialization, synthesis
    public var errorDescription: String? {
        switch self {
        case .missingModel: "离线语音模型未安装，请运行项目的模型准备脚本后重新构建。"
        case .initialization: "无法加载离线语音模型，请检查模型文件和手机可用内存。"
        case .synthesis: "离线模型未生成有效音频，请缩短文本或切换系统音色。"
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
    public init() {}
    public nonisolated static func isInstalled(at root: URL, kind: SherpaTTSModel = .kokoro) -> Bool {
        kind.requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }
    public func render(text: String, speaker: Int, root: URL, speed: Float = 1, kind: SherpaTTSModel = .kokoro) throws -> KokoroAudio {
        try Task.checkCancellation()
        guard Self.isInstalled(at: root, kind: kind) else { throw KokoroError.missingModel }
        if handle?.kind != kind || loadedRoot != root { try load(root, kind: kind) }
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
        return KokoroAudio(samples: Array(UnsafeBufferPointer(start: samples, count: Int(audio.pointee.n))), sampleRate: Int(audio.pointee.sample_rate))
    }
    private var loadedRoot: URL?
    private func load(_ root: URL, kind: SherpaTTSModel) throws {
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
            config.model.kokoro.lexicon = cString(["lexicon-us-en.txt", "lexicon-zh.txt"].map { root.appendingPathComponent($0).path }.joined(separator: ","))
            config.model.kokoro.length_scale = 1
        case .melo:
            // sherpa-onnx ≥ v1.13 builds the Melo frontend from lexicon.txt (PhraseMatcher);
            // no runtime jieba dictionary is needed, hence the C API dropped dict_dir.
            config.model.vits.model = cString(root.appendingPathComponent("model.onnx").path)
            config.model.vits.lexicon = cString(root.appendingPathComponent("lexicon.txt").path)
            config.model.vits.tokens = cString(root.appendingPathComponent("tokens.txt").path)
            config.model.vits.noise_scale = 0.667
            config.model.vits.noise_scale_w = 0.8
            config.model.vits.length_scale = 1
        }
        config.model.provider = cString("cpu")
        // Match inference threads to the device; two threads starves short-chunk pipelines on 6-core phones.
        config.model.num_threads = Int32(min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)))
        config.max_num_sentences = 1; config.silence_scale = 0.15
        let rules = kind == .kokoro
            ? ["date-zh.fst", "number-zh.fst", "phone-zh.fst"]
            : ["date.fst", "number.fst", "phone.fst", "new_heteronym.fst"]
        let found = rules.map { root.appendingPathComponent($0).path }.filter { FileManager.default.fileExists(atPath: $0) }
        if !found.isEmpty { config.rule_fsts = cString(found.joined(separator: ",")) }
        guard let pointer = SherpaOnnxCreateOfflineTts(&config) else { throw KokoroError.initialization }
        handle = Handle(pointer, kind: kind); loadedRoot = root
    }
    public func unload() { handle = nil; loadedRoot = nil }
}
