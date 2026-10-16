import Foundation
import CryptoKit

public enum AIProvider: String, Codable, CaseIterable, Sendable {
    case openAI, deepSeek, qwen, ollama, custom
    public var title: String {
        switch self { case .openAI: "OpenAI"; case .deepSeek: "DeepSeek"; case .qwen: "通义千问"; case .ollama: "Ollama · 本地"; case .custom: "自定义兼容接口" }
    }
    public var baseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .ollama: "http://127.0.0.1:11434/v1"
        case .custom: "https://"
        }
    }
}
public struct AIConfiguration: Codable, Equatable, Sendable {
    public var enabled = false
    public var provider = AIProvider.openAI
    public var baseURL = AIProvider.openAI.baseURL
    public var model = ""
    public init() {}
    public func endpoint(_ path: String) throws -> URL {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())) else { throw AIError.invalidEndpoint }
        parts.scheme = parts.scheme?.lowercased(); parts.host = host.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.hasSuffix("/chat/completions") { parts.path.removeLast("/chat/completions".count) }
        guard !parts.path.split(separator: "/").contains(".."), let url = parts.url else { throw AIError.invalidEndpoint }
        return path.isEmpty ? url : url.appendingPathComponent(path)
    }
    public func validate(requireModel: Bool = true) throws {
        _ = try endpoint("")
        if requireModel, model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AIError.missingModel }
        guard model.count <= 200 else { throw AIError.missingModel }
    }
    public var credentialAccount: String {
        let endpoint = (try? endpoint("").absoluteString) ?? baseURL
        return provider.rawValue + "." + SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var allowsEmptyKey: Bool {
        guard let url = try? endpoint(""), let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
    }
}
public enum AIReadingAction: String, CaseIterable, Sendable {
    case explain, summarize, translate, vocabulary, question, operate
    public var title: String { switch self { case .explain: "解释选文"; case .summarize: "提炼摘要"; case .translate: "翻译为中文"; case .vocabulary: "单词释义"; case .question: "自由问答"; case .operate: "操作应用" } }
    public var instruction: String {
        switch self {
        case .explain: "用清楚易懂的中文解释这段文字，说明关键概念；区分原文事实与补充推断。"
        case .summarize: "用中文概括这段文字的核心观点与论据，不补写原文没有的信息。"
        case .translate: "将这段文字翻译为自然准确的简体中文，保留段落。若已是中文，转述成易懂的现代汉语。"
        case .vocabulary: "解释所选单词或短语的含义、词性、常见用法，结合原文上下文给出中文释义和简短例句；不确定时说明。"
        case .question: "回答读者的问题，可以回答一般知识与单词问题。有引用时结合引用，依据不足或不确定时明确说明。"
        case .operate: "根据用户明确要求操作Readora，先查询必要信息，不要推断用户未要求的更改。"
        }
    }
}
public enum AIError: LocalizedError, Equatable {
    case invalidEndpoint, missingModel, missingKey, emptyContext, invalidResponse, invalidModelRegistry, oversizedResponse, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "请输入有效的 HTTPS API 地址；本机服务可使用 http://127.0.0.1 或 localhost。地址不能包含账号、密码、查询参数或片段。"
        case .missingModel: "请填写供应商提供的模型 ID（最多200字）。"
        case .missingKey: "请在 AI 设置中保存此供应商与地址对应的 API Key。"
        case .emptyContext: "请先选择文字或添加要处理的内容。"
        case .invalidModelRegistry: "最多保存30个模型，显示名称最多100字，且配置ID不能重复。"
        case .invalidResponse: "服务未返回有效的文字回答，请检查模型是否支持 Chat Completions。"
        case .oversizedResponse: "服务响应过大，已停止接收。"
        case .http(let status):
            switch status {
            case 401, 403: "认证失败（\(status)），请检查 API Key 和模型权限。"
            case 404: "接口或模型不存在（404），请检查 API 地址与模型 ID。"
            case 429: "请求过于频繁或额度不足（429），请稍后重试并检查供应商额度。"
            case 300..<400: "服务要求重定向，已停止；请在设置中填写最终 API 地址。"
            default: "AI 服务请求失败（HTTP \(status)），请稍后重试。"
            }
        }
    }
}
