# 08 · Xcode 项目目录结构

以下是待创建的工程蓝图，最初仅交付文档；当前实际工程采用根目录Package.swift与Sources/ReadoraCore、ReadoraRendering、ReadoraMac三个target（CZlib为系统桥接），Tests/ReadoraCoreTests负责领域与排版测试。下方Xcode工程树仍为目标蓝图。初期使用一个本地 Package 多 target，避免仓库碎片化；模块数可合并，但禁止循环依赖。

```text
Readora/
├── README.md                         # 开发入口
├── Readora.xcodeproj/                 # 双应用 target、scheme、构建配置
├── App/
│   ├── Shared/CompositionRoot.swift   # 组装引擎、仓储和协调器
│   ├── macOS/ReadoraMacApp.swift      # 窗口、命令菜单、生命周期
│   └── iOS/ReadoraiOSApp.swift        # Scene 与应用事件桥接
├── Platforms/
│   ├── macOS/WindowCoordinator.swift # 多窗口与活动窗口仲裁
│   ├── macOS/ImportDropAdapter.swift # 拖拽、安全访问
│   └── iOS/ShareExtension/           # V1.1 共享 inbox
├── Shared/                           # 跨 target 资源清单、非业务辅助
├── Packages/ReadoraKit/
│   ├── Package.swift                # 平台、target 与依赖约束
│   └── Sources/
│       ├── ReadoraCore/
│       │   ├── Domain/              # Book、ReadingLocation 等纯值模型
│       │   ├── Protocols/           # ReaderEngine、SpeechEngine、Repository
│       │   ├── Services/            # LibraryService、进度策略
│       │   └── Errors/              # 领域错误与稳定错误码
│       ├── ReadoraFeatures/
│       │   ├── Library/             # View / ViewModel / 状态
│       │   ├── Reader/              # ReaderView、ReadingCoordinator
│       │   ├── Speech/              # 迷你播放器、SpeechCoordinator
│       │   ├── Notes/               # V1 笔记与搜索
│       │   └── Settings/            # 偏好与同步入口
│       ├── ReadoraReader/
│       │   ├── EPUB/                # 包解析、spine、WK 渲染与桥接
│       │   ├── PDF/                 # PDFKit、文字抽取、页锚点
│       │   ├── TXT/                 # 编码、分块、TextKit 适配
│       │   ├── Text/                # 规范文本、分句与位置映射
│       │   └── Resources/Reader.js  # 受信桥接脚本和 CSS
│       ├── ReadoraSpeech/
│       │   ├── NativeSpeechEngine.swift # AVSpeechSynthesizer delegate
│       │   ├── iOS/AudioSessionAdapter.swift # 中断、路由、后台
│       │   ├── macOS/AudioAdapter.swift     # Mac 音频与媒体能力探针
│       │   └── MediaCommandAdapter.swift  # 命令与 Now Playing
│       ├── ReadoraData/
│       │   ├── Persistence/         # Core Data 模型、迁移、上下文
│       │   ├── Repositories/        # 协议实现与快照转换
│       │   ├── FileStore/           # staging、hash、提交 journal
│       │   └── Search/              # 可重建 FTS 索引
│       ├── ReadoraSync/             # 账户、镜像事件、冲突投影、文件传输
│       ├── ReadoraDesignSystem/     # Tokens、平台映射、可复用控件
│       └── ReadoraInfrastructure/   # OSLog、时钟、诊断、配置
├── Resources/
│   ├── Assets.xcassets/             # 合法自有图标和封面占位
│   ├── Localizable.xcstrings        # 中文/未来多语言
│   └── PrivacyInfo.xcprivacy        # 按实际 API 审计填写
├── Tests/
│   ├── DomainTests/                # 位置、冲突、分句规则
│   ├── ReaderContractTests/        # 三引擎共同合同
│   ├── ImportIntegrationTests/     # 文件与数据库崩溃补偿
│   ├── SpeechStateTests/           # 假引擎与事件序列
│   ├── UITests/                    # 两应用 UI 流程
│   └── Fixtures/                   # 自制/授权样书与许可清单
├── docs/                           # 本套设计文档
└── deploy/                         # 将来的签名发布说明和交付包
```

View/ViewModel 就近放 Feature；Model 的业务定义在 Domain，Core Data NSManagedObject 仅在 Persistence。Repository 协议在 Core，实现在 Data；Service 放所属领域，Coordinator 只协调用例，Engine 放独立适配模块。禁止 Features import ReadoraData；测试通过组合根替换协议实现。

Infrastructure 不依赖 Features；DesignSystem 不依赖业务仓储。App target 注入全部实现，因此无需服务定位器。只有真实复用才抽组件；文件超过约 400 行时审查职责，不机械按行数拆分。
