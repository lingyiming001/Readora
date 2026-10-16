# 07 · 系统架构

采用轻量 MVVM + 领域协议 + 基础设施适配，不为每个按钮建立独立 use case。View 只处理布局和用户意图，ViewModel 为 MainActor 状态持有者；业务协调器处理跨阅读、朗读和进度的流程；引擎不直接写数据库。

## 1. 系统总体

```mermaid
flowchart TB
    UI[SwiftUI 平台界面] --> VM[ViewModel]
    VM --> RC[ReadingCoordinator]
    VM --> LC[LibraryService]
    RC --> RE[ReaderEngine]
    RC --> SC[SpeechCoordinator]
    SC --> SE[SpeechEngine]
    RC --> PR[ProgressRepository]
    LC --> BR[BookRepository]
    BR --> CD[Core Data]
    PR --> CD
    LC --> FS[FileStore]
    CD --> CK[CloudKit 私有元数据]
    FS --> ID[iCloud Drive 可选原文]
```

只有组合根知道具体实现。Core Data 和 FileStore 是平行的数据通道，不能用「同步完成」掩盖原文仍未下载。错误在适配器转换为领域错误，最终由界面提供恢复操作。

## 2. 跨平台模块

```mermaid
flowchart TB
    Mac[ReadoraMac / AppKit] --> Features[Features / SwiftUI]
    iOS[ReadoraiOS / UIKit] --> Features
    Features --> Core[ReadoraCore / Domain]
    Data[ReadoraData] --> Core
    Reader[ReadoraReader] --> Core
    Speech[ReadoraSpeech] --> Core
    Sync[ReadoraSync] --> Core
    Features --> Design[DesignSystem]
    Root[App CompositionRoot] --> Data
    Root --> Reader
    Root --> Speech
    Root --> Sync
```

箭头为编译依赖。Features 只依赖 Core 和 DesignSystem；App 组合根注入 Data/Reader/Speech/Sync 实例。平台桥接在对应模块条件编译文件中实现，不让 Domain 引入 UIKit。

## 3. 阅读引擎

```mermaid
flowchart LR
    Contract[ReaderEngine] --> EPUB[EPUBEngine]
    Contract --> PDF[PDFEngine]
    Contract --> TXT[TXTEngine]
    EPUB --> WK[WKWebView + DOM Bridge]
    PDF --> PK[PDFKit Adapter]
    TXT --> TK[TextKit Adapter]
    EPUB --> Text[Canonical Text + Locator]
    TXT --> Text
    PDF --> PT[PDF Text Range + Quad]
```

统一接口表达打开、导航和能力，不强迫 PDF 提供字体重排。内容提取服务独立于可见视图，避免后台换章必须创建 WKWebView。

## 4. TTS 引擎

```mermaid
flowchart TB
    Commands[播放器 / Remote Commands] --> Coordinator[SpeechCoordinator 状态机]
    Coordinator --> Segmenter[分句与小队列]
    Segmenter --> Engine[SpeechEngine]
    Engine --> Native[NativeSpeechEngine]
    Engine -.-> Cloud[未来 CloudSpeechEngine]
    Native --> Synth[AVSpeechSynthesizer]
    Coordinator --> Audio[平台音频适配]
    Synth --> Events[进度与完成事件]
    Events --> Coordinator
```

Coordinator 是播放状态唯一写入者，原生 delegate 转为带 session/generation 的事件；未来云端必须提供时间对齐能力或降级为段高亮。

## 5. 阅读与朗读数据流

```mermaid
flowchart LR
    Text[版本化规范正文] --> Seg[TextSegment 与 UTF16 映射]
    Seg --> Utterance[Utterance]
    Utterance --> Range[delegate 局部 range]
    Range --> Mapper[映射为 ReadingLocation]
    Mapper --> SpeechPos[SpeechPosition]
    SpeechPos --> Follow[跟随策略]
    Follow --> Reader[阅读视图高亮]
    Reader --> Visual[可视位置事件]
    Visual --> Policy[来源与版本过滤]
    Policy --> Save[进度仓储]
```

高亮产生的可视事件带 speechFollow 来源，不作为新的手动阅读位置再次驱动朗读。阅读位置和朗读位置独立存储，通过明确用户动作切换，防止回路。

## 6. 本地与云端

```mermaid
flowchart TB
    App[Repository] --> Local[Core Data 本地记录]
    Local <--> Mirror[NSPersistentCloudKitContainer]
    Mirror <--> Private[CloudKit Private Database]
    Import[导入服务] --> Files[沙盒原文 / hash]
    Files <--> Transfer[可选文件传输协调器]
    Transfer <--> Drive[iCloud Drive 容器]
    Files --> Cache[可重建文本索引 / 封面]
```

索引和解压缓存不进云端；书籍元数据含 contentHash 关联文件，接收端需校验匹配。系统镜像的记录不得再由手写 CloudKit 客户端修改。

## 7. 导入时序

```mermaid
sequenceDiagram
    actor User as 用户
    participant UI as 导入界面
    participant Import as ImportService
    participant File as FileStore
    participant Parser as Parser
    participant DB as BookRepository
    User->>UI: 选择或拖入文件
    UI->>Import: import(url)
    Import->>File: scoped访问并复制到 staging
    File-->>Import: hash 与暂存路径
    Import->>DB: 查询重复 hash
    DB-->>Import: 未存在
    Import->>Parser: 校验与提取元数据
    Parser-->>Import: PublicationManifest
    Import->>File: 原子提交原文
    Import->>DB: 事务写入记录与导入凭证
    DB-->>UI: 书库更新
```

重复分支直接返回已有书并清理 staging。文件与数据库不能跨介质原子提交，因此必须用 journal 在崩溃后补偿，详见存储文档。

## 8. 朗读时序

```mermaid
sequenceDiagram
    actor User as 用户
    participant C as SpeechCoordinator
    participant T as TextContentService
    participant E as SpeechEngine
    participant R as ReaderEngine
    participant P as ProgressRepository
    User->>C: 从当前位置播放
    C->>T: 获取版本匹配的文本段
    T-->>C: 句子和源范围
    C->>E: start(segment, generation)
    E-->>C: range事件
    C->>R: 高亮对应范围
    C->>P: 节流保存 SpeechPosition
    E-->>C: finished(segment)
    C->>T: 下一句或下一章
```

range 不是硬实时音频时钟；句级高亮是首发承诺。章节预取与句子解析在后台，视图加载失败不应使纯听书停止；内容提取失败则暂停并提供重试。

## 生命周期和隔离

AppState 负责启动恢复与账户事件，WindowState 负责窗口位置；SpeechCoordinator 应用级单实例。ImportActor/IndexActor/FileStore 串行化各自可变资源；NSManagedObject 不跨 context/actor 传递，仅输出不可变快照。生命周期离开前台提交检查点，不能依赖应用退出回调一定执行。日志用 OSLog，书名、文本、路径默认 private。
