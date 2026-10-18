# 本地 macOS 启动包

`Readora.app` 由 `scripts/run-macos.sh` 生成，使用 ad-hoc 本地签名，仅供本机开发；未公证、未提交商店。

在终端运行 `./scripts/run-macos.sh`。若在受限工具沙盒中 Launch Services 拒绝启动，应由宿主环境打开生成的应用包，不修改系统安全设置。

当前包版本0.6.0 build 13。包含 `Contents/MacOS/ReadoraMCP` 原生桥接程序，以及麦克风/语音识别用途说明和权限声明。外部客户端从设置 → MCP 复制配置；应用包移动后须重新复制。使用说明见 [MCP 与语音聊天](../docs/MCP-and-Voice.md)。

本轮只打包，不自动退出或重启用户窗口；请保存现有配置后退出旧版并重新打开。首次语音聊天由系统请求授权，本轮未进行界面/麦克风测试。

原生Xcode入口：打开根目录`Readora.xcodeproj`，选择`Readora → My Mac`并按⌘R。Xcode构建的App位于DerivedData，脚本生成的App位于此目录；两者共用`Resources/Info.plist`与`Resources/Readora.xcconfig`。图标在Xcode的Assets目录中管理，修改根目录Logo.png后运行图标脚本会同步ICNS与Assets图标。
