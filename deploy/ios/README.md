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
| 书库 | 导入EPUB/TXT/PDF、书名作者搜索、收藏、自定义书架（创建/重命名/删除、多书架归类）、回收站与还原 |
| 阅读 | EPUB/TXT连续滚动、EPUB图片与目录、PDFKit原生阅读、进度保存、书签与跳转 |
| 外观 | 主题、字体、字号、行距；适配手机宽度 |
| 朗读 | EPUB/TXT系统语音，从当前段落或指定段落开始、暂停/继续/停止；已配置后台音频与来电/拔耳机暂停，锁屏及真实中断仍待设备验证 |
| AI | 配置/编辑/启停多个模型、钥匙串保管Key、当前段落解释/摘要/翻译/问答、应用使用指导，以及书库查询、创建/重命名书架、归类、收藏/已读、排序和阅读外观操作；模型须支持tools，按需发送书库元数据 |
| 尚未移植 | Mac MCP、完整Mac AI应用操作、语音聊天录音、8倍速引擎、Mac分页/高亮选区操作、跨设备同步 |

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

## 2026-10-18 Xcode签名归档更新

已在Xcode为ReadoraiOS选择现有Personal Team并执行Product → Archive成功。开发签名归档位于`Readora-development.xcarchive`，`codesign --verify --deep --strict`通过。该归档不是可分发IPA，尚未在真机安装。Xcode的Debugging导出被账号资格阻止，提示Personal Team未加入Apple Developer Program。当前设备列表仅有模拟设备；连接并信任真实iPhone后，选择该设备通过⌘R安装。

## 手机更新 build17

已构建并安装到已配对的iPhone。EPUB/TXT支持左右卷页、上下页按钮；阅读菜单 → 阅读外观与翻页可切换连续滚动，PDF也支持横向分页。阅读菜单 → 朗读设置 · 速度与音色提供0.5–2×及本机系统音色，点击保存生效；播放栏也有入口。朗读中修改从当前段落重新开始，暂停状态保留。分页保存段落及页内位置。已核对真机正文分页和设置入口，实际声音及手势效果待用户确认。

## 手机书架与 AI 优化（2026-10-18，源码更新）

书库顶部“书架”管理自定义书架，点击书架查看书籍，向左滑书架行可重命名或删除；删除书架保留书籍。长按书库中的书籍，选择“加入或移出书架”。左上菜单支持书架/收藏/正在读/已读筛选和排序。

AI 可直接说“创建一个科幻书架”“把某本书加入科幻书架”“切换夜间主题”。手机只向模型开放已实现的工具，并在执行时再次验证动作；阅读页打开的助手携带当前书籍ID。其他功能给出实际入口说明。尚不支持通过手机AI打开书籍、翻页、控制朗读、删除和修改模型。

模拟器目标构建通过，`swift test --disable-sandbox` 64项测试通过（含工具能力限制及书架重启持久化回归）。本次未安装到手机，未使用真实模型服务做端到端验证。

## 手机阅读更新 build19

移除阅读页上一页/下一页按钮和段落计数，滑动翻页，底部保留页码及百分比。调整字号后重新计算分页并保留当前位置，刷新卷页缓存；卷页采用双面纸张及微弱背面透字。打开搜索结果书籍后清空书库搜索词。build19已签名构建、安装并启动，5种字号分页和文字位置检查通过；实际翻页手感待设备体验。

## 手机朗读更新 build20

阅读菜单 → 朗读设置：按语言地区选择精选音色，显示男女声及系统音质等级，并提供试听。每个地区仅保留已安装最高质量的最多3款；没有高质量版时留1款标准备用。可到系统辅助功能下载增强/优质音色。

最大朗读速度默认2倍，可用加减自定义为1–8倍（步长0.25），保存后保留；降低上限会同步降低超限的当前速度。超过2倍使用短块PCM与保音调加速。试听会暂停正式朗读，返回阅读页可继续。

16项针对测试及真机签名构建通过，build20已安装；手机锁定导致自动启动失败，请解锁后打开Readora。设备上的音质、试听和高速长时播放待实际听音验收。

## 阅读页崩溃修复 build21

根据手机崩溃记录，打开书籍时异常发生在自定义双面卷页控制器初始化。现改用单页系统仿真卷曲和系统纸背，并增加重排时旧回调与下标保护。build21已构建、安装、启动，版本查询确认；手机预览已观察到两本书正文正常显示。

## build23 命令行签名发布（2026-10-19）

使用 `xcodebuild -scheme ReadoraiOS -configuration Release -destination <设备UDID> -allowProvisioningUpdates build` 对连接的 iPhone 12（iOS 27.0.1）完成真机 Release 签名构建，Personal Team `W78LSLCJQG` 自动签名通过。随后 `xcrun devicectl device install app` 安装并 `devicectl device process launch` 启动成功。未在设备上进行功能回归，实际阅读、朗读与 AI 表现待用户确认。

## Kokoro 卡顿优化 + 音色扩充 build24（2026-10-19）

朗读管道重写：旧实现每句“播完→等合成→node.stop()→重新调度”，合成赶不上播放时句间必卡。新管道预取深度 3，句子按顺序连续合成（KokoroEngine actor 串行），AVAudioPlayerNode 运行中持续 scheduleBuffer，句间不再停启；倍速前 2× 交给模型原生 speed（同算力下音频更短，预取余量更大），超出部分才用 timePitch 补差；推理线程改为按核数自适应（最多 4）。音色按官方 v1.1-zh 索引表（0-2 双语女声、3-57 女声 zf_*、58-102 男声 zm_*）扩充为 15 个可选，原 4 个选择的索引不变、标题修正为真实编号。本 build 同时包含 AI 助手回复的 SSE 流式输出与共享 URLSession。Release 签名构建通过，已安装并启动到 iPhone；68 项 swift test 全部通过。句间无缝与音色效果待真机体验。

## 高亮同步修复 + 音色命名 build25（2026-10-19）

build24 的句间高亮取了待合成队列头，而播放节点里已提前排了下一句，高亮比声音超前一句。现新增 scheduledChunks 记录“已排进播放节点但未播完”的句子，队首即正在发声的句子：完成回调弹出已播句后发布新队首；首句在首次入节点时才发布高亮；恢复暂停时也重新校准。音色改名为“名称+编号”：双语·枫/晴/谷，女声·晓001/甜009/婉021/静031/莺041/暖054，男声·朗001/健003/岳011/川021/沉031/苍045（编号对应官方 zf_/zm_ 序号，性格标签为试听建议，可按听感再调）。build25 Release 签名构建、安装、启动成功。

## MeloTTS 离线引擎 build26（2026-10-19）

新增第二个神经朗读引擎：sherpa-onnx vits-melo-tts-zh_en（MeloTTS 中文，myshell-ai 转换版，44.1kHz，中英混读）。模型由 `scripts/prepare-melotts.py` 下载并校验（sha256 已钉入脚本），产出 `Resources/iOS/MeloTTS`（已剔除发布包内 133 字节的 model.int8.onnx LFS 占位残片）；工程以 folder 引用随 App 打包，包体 631MB。运行时 `KokoroEngine` 泛化为 `SherpaTTSModel`（kokoro/melo）双模型族 actor，换族加载即卸载旧模型避免双 ONNX 驻留内存；Melo 走 vits 配置（model/lexicon/tokens + date/number/phone/new_heteronym FST），v1.13.8 C API 不再转发 dict_dir——新版运行时用 lexicon.txt 内置 PhraseMatcher 分词，无需 jieba 字典，官方文档示例也已省略该参数。官方中文模型仅 1 个说话人，引擎内音色列表按模型元数据可扩展，当前为「双语 · 泠 Melo」；多音色请用 Kokoro 引擎 15 款。朗读设置页引擎选择增为 Kokoro/Melo/系统三档。build26 Release 签名构建、安装、启动成功，devicectl 确认版本 26；Melo 真机合成效果待验收。
