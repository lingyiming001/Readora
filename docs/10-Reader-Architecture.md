# 10 · 统一阅读引擎

统一业务合同而非统一渲染器。ReaderEngine 属 MainActor，包含可见渲染操作；TextContentService 是独立可异步调用的内容服务，后台朗读和索引不得依赖 WebView 的存活。

```swift
import Foundation

struct ReaderCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let reflow = Self(rawValue: 1 << 0)
    static let selection = Self(rawValue: 1 << 1)
    static let searchable = Self(rawValue: 1 << 2)
    static let speech = Self(rawValue: 1 << 3)
    static let pagination = Self(rawValue: 1 << 4)
}
struct ReaderDocument: Sendable {
    let book: Book
    let sandboxURL: URL
}
struct ReaderStyle: Sendable {
    let fontSize: Double
    let lineHeight: Double
    let horizontalMargin: Double
    let themeID: String
}
struct SearchHit: Sendable {
    let location: ReadingLocation
    let excerpt: String
}
enum LocationChangeSource: String, Sendable {
    case user, restore, speechFollow, remoteAccepted
}
struct SearchPage: Sendable {
    let hits: [SearchHit]
    let nextCursor: String?
}
enum ReaderEvent: Sendable {
    case visibleLocation(ReadingLocation, source: LocationChangeSource)
    case selected(ReadingLocation)
    case failed(code: String)
}
@MainActor
protocol ReaderEngine: AnyObject {
    var capabilities: ReaderCapabilities { get }
    var events: AsyncStream<ReaderEvent> { get }
    func open(_ document: ReaderDocument) async throws
    func navigate(to location: ReadingLocation) async throws
    func apply(_ style: ReaderStyle) async throws
    func search(_ query: String, cursor: String?, limit: Int) async throws -> SearchPage
    func setSpeechHighlight(_ location: ReadingLocation?) async throws
    func close() async
}
struct TextSegment: Codable, Sendable {
    let id: String
    let text: String
    let source: ReadingLocation
}
protocol TextContentService: Sendable {
    func segments(from location: ReadingLocation, limit: Int) async throws -> [TextSegment]
}
```

示例依赖数据模型文档中的 Book/ReadingLocation，非独立可运行应用。search 使用分页合同，limit 限制为 1...100；游标绑定查询、contentHash 与索引版本，输入变化后旧游标失效并返回可恢复错误。source 使用受控枚举，任意 JS 字符串必须先经白名单转换。

## 状态与恢复

closed → opening → ready → navigating → ready；任意进行中可失败到 recoverableError，close 取消子任务并增加 generation。并发 navigate 仅最终 generation 可更新 UI；旧布局回调丢弃。打开时校验 hash、创建 renderer、等待正文/字体布局、恢复位置，再发布 ready。

位置保存：用户滚动节流 1 秒，手势结束、章节切换、scene inactive 即提交。持久化失败保留内存脏标记并提示，不声称已保存。异步任务取消不可覆盖上次成功位置。

## 格式能力

| 能力 | EPUB 重排 | PDF | TXT |
|---|---|---|---|
| 字号/行距/页边距 | 支持 | 不支持重排 | 支持 |
| 主题 | 正文覆盖需保留插图可读 | 外壳主题，原页默认不反色 | 支持 |
| 选择/高亮 | DOM range | PDF 文本选择/quad | TextKit range |
| 全文搜索 | 规范正文索引 | 提取文本；扫描无 | 规范正文索引 |
| TTS | 可提取正文 | 顺序合理时可用 | 支持 |
| 横翻/双页 | V1.1 探针 | PDFKit 展示模式 | V1.1 |

多窗口每个引擎独立；同书共享只读内容服务和缓存，禁止共享可变 WebView。关闭视图只取消渲染任务，应用级朗读会话仍引用内容服务；删除书则协调停止朗读后清理。

## 事件背压与性能合同

`events` 仅允许协调器单一消费者，不能假设 AsyncStream 会向多个订阅者广播。若多个界面需要状态，由协调器发布状态快照。高频可视位置/高亮采用独立的最新值通道（bufferingNewest(1)），可靠错误/生命周期事件走低频控制通道，不能因高亮积压丢失终止或失败通知；工程实现应将两者拆开，示例 events 表示控制流。close 必须终止事件 continuation、移除 bridge handler/通知和取消任务，避免窗口关闭后仍被闭包强持有。

搜索和正文提取不得在 MainActor 执行全书遍历；引擎方法仅负责转交后台服务并接收不可变结果。每次搜索递增查询 generation，取消后迟到结果不得覆盖当前查询。
