# 手机与 Mac 功能对齐

2026-10-22，macOS 0.6.0 build14 / iOS 0.6.0 build27。

| 能力 | 实现 |
|---|---|
| 书库 | 两端导入 EPUB/TXT/PDF、搜索、封面列表/网格、收藏、已读、书架与归类、排序、最近朗读及清除、回收站还原与永久删除 |
| 阅读 | 目录、分页/滚动、外观、位置保存、书签、文本高亮、PDF选区高亮及标记跳转/移除；手机分页选区从菜单“选择文字与高亮”进入 |
| 朗读 | 两端悬浮球点击展开，暂停/继续/结束、回到朗读、高亮和跟随；共享 Kokoro 15 音色、Qwen3 7 音色标识；移除系统语音；默认最高2×，上限可设至8× |
| 多音词 | 两端使用相同词组词典覆盖，修正已确认的“还款/还款日/还款额”误音，原始文本和高亮偏移保持不变；并非通用多音词消歧模型 |
| AI操作 | 两端完整 AIAppAction 操作集：书库、书架、阅读导航、朗读、外观、模型管理与导入设置；删除等需具体确认 |
| 语音聊天 | 两端录音识别、自动发送选项、朗读AI回复、停止；手机首次使用请求麦克风和语音识别权限 |
| 外部AI控制 | Mac现有 MCP；手机新增设置中启用的令牌鉴权 HTTP MCP（同一工具协议），仅前台运行，局域网连接 |

## 验证和交付

- `swift test --disable-sandbox`：72项通过，含两种离线模型实际生成非静音音频、词典修正及HTTP鉴权/请求边界测试。
- 两个native scheme Release构建通过；Mac交付包由 `scripts/run-macos.sh` 打包，两端交付包签名校验通过。Mac包位于 `deploy/Readora.app`，手机签名包位于 `.build/ios-device/Build/Products/Release-iphoneos/Readora.app`。
- Mac实际打开书籍、音色列表、试听状态、悬浮球展开与暂停已核验。iPhone build27已安装并从设备应用列表核对版本；自动启动被锁屏拒绝。语音听感、手机新界面/录音/MCP尚待解锁后真机验收。
- 两端书库仍独立保存，没有新增跨设备自动数据同步。PDF朗读不在现有功能范围。手机MCP不能作为后台常驻服务。

## 构建

先运行 `scripts/prepare-kokoro.py` 与 `scripts/prepare-qwen-tts.py` 准备已校验模型。两个native target和 `scripts/run-macos.sh` 均打包同一份模型资源。Mac首次从旧的构建缓存升级后若出现模块目标不匹配，执行scheme Clean再构建。

Mac native Xcode构建会为静态二进制生成多余的framework壳，ONNX上游包包含冗余循环符号链接，导致该native包deep签名校验失败。交付统一使用 `scripts/run-macos.sh`（静态链接且移除这些未使用的壳），交付包deep签名校验通过；勿直接分发native中间包。
