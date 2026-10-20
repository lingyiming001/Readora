import Foundation

public enum AIAppAction: String, Codable, CaseIterable, Sendable {
    case state, listBooks = "list_books", searchBooks = "search_books", openBook = "open_book", showLibrary = "show_library"
    case sortBooks = "sort_books", listMode = "list_mode", favorite, finished, trash, restore
    case listShelves = "list_shelves", createShelf = "create_shelf", shelfMembership = "shelf_membership"
    case readingPreference = "reading_preference", speechPreference = "speech_preference", listVoices = "list_voices"
    case speak, pause, resume, stop, jump, page, navigation, bookmark, highlight, listMarks = "list_marks", removeMark = "remove_mark"
    case listModels = "list_models", addModel = "add_model", modelEnabled = "model_enabled", moveModel = "move_model", deleteModel = "delete_model"
    case renameShelf = "rename_shelf"
    case deleteBook = "delete_book", emptyTrash = "empty_trash", deleteShelf = "delete_shelf"
    case clearHistory = "clear_history", importBooks = "import_books", importLimit = "import_limit", settings
}
public struct AIAppCommand: Codable, Equatable, Sendable {
    public let action: AIAppAction
    public var bookID: UUID?
    public var target: String?
    public var text: String?
    public var number: Double?
    public var flag: Bool?
    public var id: UUID?
    public var ids: [UUID]?
    public init(action: AIAppAction, bookID: UUID? = nil, target: String? = nil, text: String? = nil, number: Double? = nil, flag: Bool? = nil, id: UUID? = nil, ids: [UUID]? = nil) {
        self.action = action; self.bookID = bookID; self.target = target; self.text = text; self.number = number; self.flag = flag; self.id = id; self.ids = ids
    }
    enum CodingKeys: String, CodingKey { case action, bookID = "book_id", target, text, number, flag, id, ids }
    public var requiresConfirmation: Bool { [.trash, .clearHistory, .removeMark, .deleteBook, .emptyTrash, .deleteShelf, .deleteModel].contains(action) || (action == .bookmark && flag == false) }
    public static func parse(_ arguments: String) throws -> Self {
        guard arguments.utf8.count <= 16000, let data = arguments.data(using: .utf8) else { throw AIError.invalidResponse }
        let command = try JSONDecoder().decode(Self.self, from: data)
        guard (command.text?.count ?? 0) <= 6000, (command.target?.count ?? 0) <= 200,
              command.number?.isFinite != false else { throw AIError.invalidResponse }
        return command
    }
    public static var tool: [String: Any] {
        ["type": "function", "function": [
            "name": "readora", "description": "操作Readora应用。只执行用户本次明确要求的动作；先用list_books/list_shelves等查询ID，不猜测ID。不访问API Key、文件原文或系统命令。删除类需用户界面确认。",
            "parameters": ["type": "object", "properties": [
                "action": ["type": "string", "enum": AIAppAction.allCases.map(\.rawValue)],
                "book_id": ["type": "string", "description": "书籍UUID；省略时仅指当前已打开书籍。"],
                "id": ["type": "string", "description": "书架、标记或模型配置UUID；add_model用已有配置ID复制连接和密钥，text填新模型ID，target填显示名。move_model用number指定从1起的新顺序。"],
                "target": ["type": "string", "description": "reading_preference: theme/font/layout/fontSize/lineSpacing/paragraphSpacing/contentWidth/brightness/animateTransitions；speech_preference: rate/maximumRate/voice/highlight/follow；settings: appearance/importing/reading/speech/ai/mcp。"],
                "text": ["type": "string", "description": "搜索词/书架名/精确高亮原文；主题paper/parchment/sage/night，字体songti/pingfang/serif/rounded，布局scroll/pages；show_library筛选all/reading/favorites/finished/trash或书架UUID；sort_books recent/title/author；navigation chapters/bookmarks/highlights。"],
                "number": ["type": "number", "description": "字号14–40，亮度0.35–1，行距2–18，段距8–36，页宽480–1400；语速/上限0.5–8，语速不能超上限；jump段落或PDF页、page排版页（从1起）；import_limit 1–2048MB。"],
                "flag": ["type": "boolean", "description": "收藏/已读/书架归属/书签/列表模式/高亮/跟随/动画的启用状态。"]
            ], "required": ["action"], "additionalProperties": false]
        ]]
    }
}
public struct AIToolCall: Codable, Equatable, Sendable, Identifiable {
    public struct Function: Codable, Equatable, Sendable {
        public let name: String
        public let arguments: String
        public init(name: String, arguments: String) { self.name = name; self.arguments = arguments }
    }
    public let id: String
    public let type: String
    public let function: Function
    public init(id: String, type: String, function: Function) { self.id = id; self.type = type; self.function = function }
}
public struct AIChatMessage: Codable, Sendable {
    public let role: String
    public var content: String?
    public var tool_calls: [AIToolCall]?
    public var tool_call_id: String?
    public var reasoning_content: String?
    public init(role: String, content: String? = nil, calls: [AIToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role; self.content = content; tool_calls = calls; tool_call_id = toolCallID; reasoning_content = nil
    }
}
public struct AIChatTurn: Sendable {
    public let message: AIChatMessage
    public var calls: [AIToolCall] { message.tool_calls ?? [] }
    public static func parse(_ data: Data) throws -> Self {
        struct Response: Decodable { struct Choice: Decodable { let message: AIChatMessage }; let choices: [Choice] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let message = response.choices.first?.message,
              message.role == "assistant", (message.tool_calls?.count ?? 0) <= 8 else { throw AIError.invalidResponse }
        let calls = message.tool_calls ?? []
        guard Set(calls.map(\.id)).count == calls.count, calls.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 200 && $0.type == "function" && $0.function.name == "readora" && $0.function.arguments.utf8.count <= 16000 }),
              !calls.isEmpty || !(message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else { throw AIError.invalidResponse }
        return Self(message: message)
    }
}
