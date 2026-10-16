# 16 · 性能、稳定性、安全与隐私

## 可测量目标

基线建议 iPhone 12（iOS 17 兼容版本）与 M1 Mac 8 GB（macOS 14），另测最新稳定系统；固定 Release 构建、无调试器、20 次操作取 p95。样书使用自制/授权内容。以下都是预算目标，尚未实测；不同设备分别报告，不用平均值遮蔽尾延迟。

| 场景 | 验收目标 | 实现与验证 |
|---|---|---|
| 冷启动、1,000 本元数据 | 首次可交互 ≤1.5 s | 延迟索引/同步、分页 fetch；启动 signpost |
| 温打开 EPUB 10 MB/100章 | 正文 ≤700 ms；位置恢复 ≤1 s | manifest 缓存、当前章加载；首帧与锚点分测 |
| EPUB 100 MB/2,000资源 | 导入 ≤30 s；界面不阻塞 | 流式解包/取消、峰值内存采样 |
| PDF 500页/100 MB | 第一页 ≤2 s、翻页 p95 ≤150 ms | 按页加载、缩略图缓存，PDFKit tracing |
| TXT 100 MB | 首屏 ≤2 s、可取消；索引渐进 | 分块解码、禁止全文件 attributed string |
| 正常滚动 | 60 Hz 设备 ≥55 fps；卡顿帧占比 <1% | Core Animation/Instruments；120 Hz 另报 |
| 本地 TTS 已装声音 | 点击至首音 p95 ≤1 s | 录音/事件时间对照，冷/热分开 |
| 高亮 | 句边界误差 p95 ≤300 ms | 音频/屏幕人工抽样；超标降级句级 |
| 全文搜索 | 已索引 100 MB 文本首批 ≤1 s | FTS/候选核验，中文单独样本 |
| 内存 | 标准 EPUB 阅读常驻目标 <200 MB；2小时增长 <20 MB | 总进程含 WebContent 单独列报，不隐藏子进程 |
| 连续听书 | 2小时无应用原因断流，24小时压力无崩溃 | 真机锁屏/蓝牙/换章；系统中断另归因 |
| 同步 | 测试网络正常时观察收敛时间，目标 p95 <60 s | 系统不保证时限；超时等待状态而非失败删除 |
| 耗电 | 标准亮度下2小时阅读/朗读分别建立基线，迭代回归 ≤10% | Energy Log/MetricKit；无硬件测量不承诺续航 |

## 优化与恢复

封面按目标尺寸下采样；书库虚拟化，预取只涵盖邻屏；后台解析/索引有并发和内存预算。缓存建议总额 500 MB，可配置 LRU，原文不因缓存压力清除。内存警告释放未显示页面与缩略图，不丢持久化检查点。章节仅加载当前和必要预取，解析不得占 MainActor。

建立 import/open/navigation/speech/sync signpost，OSLog 不含原文、书名或完整路径。WebContent 崩溃重建 renderer；数据库迁移失败只读备份/导出，不删库重建；磁盘不足停止导入并保留原始源。崩溃恢复依赖 journal 和定期检查点，不能等待 terminate 回调。

## 威胁与控制

| 威胁 | 控制 | 验证 |
|---|---|---|
| ZIP Slip/zip bomb/XML 实体 | 路径规范、symlink 拒绝、大小/深度/条目上限、禁外部实体 | 恶意夹具不得写沙盒预期目录外 |
| EPUB 脚本/远端跟踪 | 去危险内容、CSP、导航拦截、受控 scheme、隔离 bridge | HTTP/DNS 抓包无外发；桥接消息模糊测试 |
| 来源路径泄漏 | 自有副本、短时 scoped 访问、日志私有化 | 诊断包检查无原文/用户目录 |
| 跨账户数据混合 | 账户隔离 store、切换前保存和确认 | A/B 账户切换回归 |
| 损坏文件与超限内存 | 有界解析、取消、隔离、错误恢复 | fuzz/超大图片/缺 manifest/损坏 PDF |
| 云端服务误用 | 原文同步与AI上传分开授权、最小权限 | 关闭同步无内容网络上传 |

macOS 开启 App Sandbox，按文件选择需求设置 user-selected read-only，导出需要对应写权限；iOS 使用 document picker 和 security-scoped access，不申请无关相册、麦克风权限。后台朗读不需要录音权限。iOS 文件保护类别需兼顾锁屏持续读文，评估 completeUntilFirstUserAuthentication 等策略，锁屏真机测试，不默认 complete 导致后台无法读章。

## 商业合规与辅助能力

不绕过 DRM；第三方依赖固定版本并附许可证、NOTICE/SBOM。数据导出包含笔记和位置，彻底删除有可验证操作范围。默认无第三方分析 SDK，诊断用户主动授权；隐私标签、Privacy Manifest 与实际 required reason API 一致。VoiceOver、键盘、Switch Control、Dynamic Type、Reduce Motion、增加对比度在发布门槛测试。

参考 [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 和 [HIG](https://developer.apple.com/design/human-interface-guidelines)，提交前重新核验适用条款；本文控制项是设计要求，未宣称已通过审核。
