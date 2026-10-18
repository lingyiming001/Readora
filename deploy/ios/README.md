# Readora iPhone 版

打开根目录 `Readora.xcodeproj`，选择 **ReadoraiOS** scheme。iOS 17起，手机界面使用SwiftUI/UIKit/PDFKit，复用ReadoraCore的解析、书库、位置、模型与钥匙串代码；不运行Mac的AppKit窗口或MCP程序。

## 安装到你的 iPhone

1. 用数据线连接并解锁iPhone，在手机上信任此电脑。
2. 在Xcode → Settings → Accounts登录你自己的Apple ID。
3. 项目 → Targets → **ReadoraiOS** → Signing & Capabilities，保持Automatically manage signing，选择自己的Team。必要时将Bundle Identifier改为自己唯一的标识，例如`com.yourname.Readora`。
4. 顶部运行目标选择连接的iPhone，按⌘R。按手机/Xcode提示启用Developer Mode，必要时在手机设置中信任你的开发者证书。
5. 启动后，书库右上角“+”从“文件”导入EPUB、TXT或PDF；也可以使用其他App的“用Readora打开”。

Apple说明：[运行到真机](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)、[开发者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。签名由你自己的账号完成，项目不包含个人Team、证书、密钥或描述文件。

## 编译产物

本次已编译真机和模拟器目标，生成 `Readora-unsigned.xcarchive`（本目录，Git忽略）。归档中的App位于 `Products/Applications/Readora.app`，**它没有签名，不能直接安装到手机，也不是可分发IPA**。请按上面的Xcode步骤使用自己的Team重新构建安装。

重建未签名Release归档：

```sh
./scripts/build-ios.sh
```

首次本机验证环境：Xcode27.1 / Swift6.4 / iOS27.1 SDK；最低部署iOS17。本次未检测到连接设备或本地代码签名证书，未安装模拟器运行环境，因此未完成真机/模拟器交互、音频、Keychain或云服务验证。

## 当前手机端范围

| 能力 | 手机首版 |
|---|---|
| 书库 | 导入EPUB/TXT/PDF、书名作者搜索、收藏、回收站与还原 |
| 阅读 | EPUB/TXT连续滚动、EPUB图片与目录、PDFKit原生阅读、进度保存、书签与跳转 |
| 外观 | 主题、字体、字号、行距；适配手机宽度 |
| 朗读 | EPUB/TXT系统语音，从当前段落或指定段落开始、暂停/继续/停止；已配置后台音频与来电/拔耳机暂停，锁屏及真实中断仍待设备验证 |
| AI | 配置/编辑/启停多个模型、钥匙串保管Key、当前段落解释/摘要/翻译/问答、后台有限对话上下文，界面仅当前回答 |
| 尚未移植 | Mac MCP、AI应用自动操作、语音聊天录音、8倍速引擎、Mac分页/高亮选区操作、自定义书架管理、跨设备同步 |

书库保存在手机App沙盒的Application Support/Readora，和Mac独立；卸载App会移除App内书库，导入时原文件不改写。通过文件导入不等于自动同步。手机上的localhost指手机本身，不是Mac上的Ollama服务；目前模型地址继续使用共享核心的HTTPS/本机HTTP校验，没有放宽任意明文HTTP访问。

## 工程与资源

- `Sources/ReadoraiOS/`：手机界面、阅读状态、音频会话与AI界面。
- `Resources/iOS/Info.plist`：文件类型、启动场景、后台音频、用途配置。
- `Resources/iOS/Readora-iOS.xcconfig`：App标识、版本、最低系统。
- `Resources/iOS/Assets.xcassets`：手机图标，取自现有Logo。
- `ReadoraCoreiOS`：与Mac复用源码的静态framework，不单独签名或嵌入。
- 新增共享核心文件时在Xcode勾选ReadoraCore和ReadoraCoreiOS的Target Membership。
- `Readora` scheme继续运行Mac；`ReadoraiOS` scheme运行手机。Mac回归仍用根目录`swift test`。

默认200 MB导入上限来自共享解析器配置，不代表大体积书籍已在手机上完成内存、速度和耗电验证。
