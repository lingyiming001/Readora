# 13 · TTS 朗读引擎

## 抽象与所有权

应用级 SpeechCoordinator 强持有 SpeechEngine，管理唯一会话；NativeSpeechEngine 强持有 AVSpeechSynthesizer。delegate 只发事件，不同时更新数据库和 UI。[Apple 文档](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer) 提供队列、暂停和 delegate 能力，应用必须保持 synthesizer 生命周期。

```swift
import Foundation

struct SpeechRequest: Sendable {
    let sessionID: UUID
    let generation: UInt64
    let segment: TextSegment
    let voiceIdentifier: String?
    let normalizedRate: Double // 0...1，适配到系统合法范围
}
enum SpeechEvent: Sendable {
    case started(UUID, UInt64, String)
    case range(UUID, UInt64, String, NSRange)
    case paused(UUID, UInt64, String)
    case resumed(UUID, UInt64, String)
    case finished(UUID, UInt64, String)
    case cancelled(UUID, UInt64, String)
    case failed(UUID, UInt64, String)
}
@MainActor
protocol SpeechEngine: AnyObject {
    var events: AsyncStream<SpeechEvent> { get }
    func start(_ request: SpeechRequest) async throws
    func pause() async throws
    func resume() async throws
    func stop() async
}
```

依赖 TextSegment 定义见阅读协议。start 表示开始一个有界 segment；Coordinator 负责取下一段，适配器内部可预排 1–2 句但不可排全书。事件携带 session/generation/segmentID，换章/换声音/seek 后拒收旧事件。接口不假定所有引擎有字级时间戳；后续增加 SpeechCapabilities 声明支持粒度。

## 状态机

idle → preparing → playing ↔ paused → completed；playing 可进入 interrupted / failed / stopping；stop 最终 idle。preparing 期间再次播放合并，seek 递增 generation、清空旧队列后从新句起播。pause 调用成功不代表系统已暂停，收到对应 delegate 才进入 paused；超时后提供重试，不谎报播放状态。

paused 与 interrupted 区分用户意图。来电结束只在之前 playing、用户未暂停、系统允许且音频激活成功时尝试恢复；失败保持暂停。冷启动将历史 playing 转为 resumable，不自动播放。

## 文本分句和位置

使用 NLTokenizer(.sentence) 初分句，针对中文引号、英文缩写、数字、小数、章节标题回归；每段带 UTF-16 源范围，禁止用标点字符串 split 作为全部逻辑。超长句按语义边界切为约 200–500 UTF-16 单元，保持映射；跳过纯导航、页码、不可见文本，脚注是否朗读由用户选择。

每句 utterance 对应 segment，delegate range 是 utterance 局部 NSRange，需加回规范文本源偏移。若替换字符或移除控制符，保存单调 offset map，不得直接相加。语言识别优先 EPUB lang/段落 lang，再 NaturalLanguage 检测，低置信度回退用户语言；不对每个外来词切声。声音按当前设备 `speechVoices()` 枚举，标识失效时提示并回退，不能程序化承诺下载所有高质量声音。

## 播放导航和设置

上下句/段/章均以文本索引找边界，章末预取下一章。速率归一化映射系统最小/默认/最大范围；UI 显示相对档位，不承诺线性真实倍速。修改声音或速度从当前句重启，向用户说明可能重听一句。睡眠定时存绝对 deadline 与章末策略，每次事件/进入后台/恢复时复核，不依赖单次主线程 Timer。

每 1 秒及暂停、切句、切章、scene inactive 保存 SpeechPosition；恢复默认从检查点句首，异常终止可能重听数秒。保存失败保持脏标记并可导出诊断。

## 后台与媒体适配

iOS 在用户开始播放时配置 AVAudioSession `.playback`、适当 `.spokenAudio` mode、激活会话，启用 audio background mode；播放结束后按策略释放。监听 interruption、routeChange、mediaServicesWereReset，旧设备断开默认暂停，蓝牙切换不直接假定可恢复。[AVAudioSession 文档](https://developer.apple.com/documentation/avfaudio/avaudiosession) 描述后台音频配置基础；AVSpeechSynthesizer 在各系统/设备的连续后台表现仍须真机测试，不保证应用被强杀后继续。

MPRemoteCommandCenter 只注册可履行的播放、暂停、上一/下一段命令，清理重复 handler；Now Playing 设置书名/章节/播放状态。文本合成没有可靠时长时不提供虚假 duration 与任意时间 seek；elapsed time 可显示当前会话实际经过时间但不作为文字百分比。iPhone 锁屏能力是 V1 P0 门槛；Mac 媒体键与系统中心表现单独验证，不能把 iOS 支持推断为 Mac 一致。

## 原生与云端取舍

| 维度 | 系统 TTS | 未来 AI TTS |
|---|---|---|
| 自然度 | 因已安装语言/声音而异 | 供应商、声音、文本差异大，需试听评估 |
| 离线 | 已安装系统声音可离线，设备实测 | 通常需联网；本地模型另作评估 |
| 延迟/成本 | 无应用侧逐字 API 计费；仍有设备资源成本 | 首包延迟、按量计费、缓存和重试成本 |
| 隐私 | 应用不主动上传正文 | 需要明确逐次或设置授权、供应商保留策略 |
| 对齐 | 系统 range 回调，非硬实时 | 必须提供标记或降级段高亮 |

未来 CloudSpeechEngine 下载音频采用 AVPlayer/AVAudioEngine 等独立实现，缓存按内容/声音/模型版本标识；用户撤回授权即取消请求和清理缓存。当前不集成、不上传、不承诺厂商效果。

## 回归修正规则

暂停/继续的确认必须由 paused/resumed 事件进入状态机；不能仅靠方法返回或只包含 start/finish 的旧事件合同推断。delegate 回调需先转换为可发送的值，再切到 MainActor；只在新会话已建立时恢复接收对应 generation。

range 高频事件采用独立可合并最新值通道，paused/finished/cancelled/failed 走可靠控制通道；不得无界缓存逐词事件，也不得用同一 bufferingNewest(1) 丢弃完成通知。持续播放的定时停止使用可取消的 deadline 调度任务，并在句边界复核；仅在句边界检查会导致长句超时，只有 Timer 则可能受调度影响，两者结合并在真机测最大误差。
