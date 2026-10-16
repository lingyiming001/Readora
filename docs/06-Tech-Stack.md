# 06 · 技术栈选型与决策记录

核验日期：2026-10-15。工具链版本在工程创建时锁定；最低部署版本为 **iOS 17、macOS 14**，未来 iPadOS 17 起。原因是获得现代 SwiftUI、Observation 与 TextKit 2 基础，减少旧系统兼容分支；代价是放弃更旧设备。最低系统不等于最新提交 SDK 要求。

| 决策 | 选择、原因 | 取舍、风险与替代 |
|---|---|---|
| 语言 | Swift 6 工具链；领域值类型 Sendable，UI MainActor | 迁移严格并发逐模块推进；不可用 unchecked Sendable 掩盖 Core Data/WKWebView 隔离 |
| UI | SwiftUI + AppKit/UIKit representable | 共享业务与组件；选择菜单、TextKit、窗口和 PDF 仍需平台代码；纯 SwiftUI 无法覆盖全部交互 |
| EPUB | 自研受限支持档案解析 + WKWebView | 双平台一致、安全与锚点可控；兼容成本高，必须先通过探针；失败缩减档案或重评平台策略 |
| PDF | PDFKit 两平台桥接 | 原生缩放/选择/目录；扫描无文本，阅读顺序不保证；不自研 PDF 渲染器 |
| TXT | TextKit 2 + 分块文本服务 | 原生选择与无障碍；超长单段需虚拟段落，复杂分页推后；WebKit 为探针失败时替代 |
| 数据 | Core Data + SQLite backing store | 成熟迁移、批量与 CloudKit 镜像；比 SwiftData 代码多；不直接操作其 SQLite |
| 同步 | NSPersistentCloudKitContainer 元数据 + 可选 iCloud Drive 原文 | 系统调度非实时；两通道状态复杂；不混用手写 CKRecord 修改镜像记录 |
| TTS | AVSpeechSynthesizer + 平台 AudioSessionAdapter | 本地声音、队列与回调；质量/声音随系统而异；AI 未来通过 SpeechEngine 替换 |
| 并发 | Swift Concurrency，NSManagedObjectContext.perform | actor 管导入/索引/文件；UI 流用 AsyncStream；Combine 只桥接既有通知，不另建状态总线 |
| 文件 | FileManager、UTType、security-scoped URL | 自有副本作为主路径；持久书签仅可选链接模式，首发不支持 |
| 测试 | XCTest/XCUITest，纯算法可用 Swift Testing | XCTest 支持 UI/性能；Swift Testing 跟工具链而非最低 OS，建工程时验证 target |

## EPUB 方案比较

| 方案 | 官方范围与维护证据 | 许可证 | 定位/分页/朗读 | 结论 |
|---|---|---|---|---|
| Readium Swift | 官方介绍面向 iOS/iPadOS；仓库列出 3.8.0 与工具链要求；不能推断原生 Mac Navigator 可用 | BSD-3-Clause；第三方依赖另审 | 已有 publication/locator/navigation 能力；具体高亮与 TTS 接口需固定 tag 探针 | iOS 方案成熟；首发不引入以免双引擎位置分叉 |
| 自研 WebKit | Apple 提供两平台 WKWebView，EPUB 由应用实现 | 自有代码；ZIP 库独立许可 | 可控 DOM Range、CSS columns、文本索引；CFI/复杂排版成本高 | 选择受限横排重排档案，先滚动 |
| Readium Desktop | 官方项目为 TypeScript/Node/Electron 路线 | 逐包核验，不继承 Swift 许可结论 | 桌面成熟思路可参考 | 不符合原生宿主目标 |
| epub.js 等 Web 引擎 | 可作为后续技术探针候选，未核验版本 | 未核验前不得纳入依赖 | 需验证桥接、定位与大书性能 | 不作为当前实现依据 |

不要为坚持自研而扩张范围：探针用 30 本样书评估正文顺序、目录、字体与锚点，若通用 EPUB 兼容性无法达标，先记录 go/no-go，再决定延迟发布、限制格式或投入 Readium 移植；不得声称可直接将 UIKit Navigator 包进原生 AppKit。

## 依赖控制

仅批准评估一个 ZIP 解包依赖（如 ZIPFoundation），确定具体 tag 后审核许可、传递依赖、路径安全及最低版本，记录 Package.resolved 与 SBOM；当前不宣称已选定其版本。XML 用 Foundation XMLParser 并禁用外部实体。全文索引优先独立 SQLite FTS5，须在目标 SDK 真机验证编译选项；不可用时回退逐章搜索后再决定引入 SQLite 库。

## 证据与待验证表

- [Readium 官方入门](https://readium.org/swift-toolkit/latest/documentation/readium/getting-started/)：平台范围依据；[仓库](https://github.com/readium/swift-toolkit) 与 [许可证](https://github.com/readium/swift-toolkit/blob/develop/LICENSE)：版本/许可核验入口，实施应固定 tag。
- [AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer)：支持队列与 delegate，不等于后台永不中断保证。
- [AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession)：iOS 音频策略；macOS 通过独立适配器管理，不直接复用会话代码。
- [Core Data CloudKit 容器](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/) 与 [同步说明 TN3163](https://developer.apple.com/documentation/technotes/tn3163-understanding-the-synchronization-of-nspersistentcloudkitcontainer)：同步由系统调度。
- [WKURLSchemeHandler](https://developer.apple.com/documentation/webkit/wkurlschemehandler)：资源加载机制入口；自定义 scheme 的字体/CSP/取消行为需探针。

TTS 后台、Mac 媒体中心能力、文本高亮时序、跨 WKWebView 版本定位和 CloudKit 冲突均标为「待真机验证」。不使用尚未核实的新系统 API 来支撑首发承诺。
