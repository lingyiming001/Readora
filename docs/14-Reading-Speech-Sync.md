# 14 · 阅读与朗读同步机制

## 三种位置与唯一写入者

visualLocation = 用户当前可见位置；speechPosition = 合成器检查点；resumeLocation = 用户下一次打开的建议位置。ProgressRepository 分开存储，不用单个百分比互相覆盖。ReadingCoordinator 决定界面行为，SpeechCoordinator 决定播放，仓储负责持久化。

| 事件 | 阅读位置 | 朗读位置 | UI 行为 |
|---|---|---|---|
| 用户滚动 | 更新 visualLocation | 不变 | 暂停自动跟随 |
| 点击开始朗读 | 保留历史 | 从所选句或当前可读段起 | 高亮并进入跟随 |
| speech range | 跟随时只更新临时视口 | 更新 sentence/range | 句高亮，屏外才滚动 |
| 暂停/退出 | 保存可视位置 | 立即保存检查点 | 显示可恢复状态 |
| 远端位置到达 | 保留本地活动位置 | 不触发音频 | 横幅询问是否采用 |
| 用户采用远端 | 显式更新 visualLocation | 若正在播放先确认替换 | navigate 一次，过滤回环 |

resumeLocation 默认选择最近一次用户明确读或听的活动，不用页码最大值；从正文中段回看不会误判倒退冲突。打开时可显示「继续阅读」「继续朗读」两个上下文，用户控制。

## 映射算法

1. 校验 contentHash、resourceID、textVersion、sessionID、generation。
2. 校验回调 NSRange 在 utterance UTF-16 边界内；使用 offset map 得到 canonical start/end。
3. 构造与文本段相同版本 ReadingLocation，保存 speechPosition。
4. renderer 通过当前 DOM/TextKit/PDF 映射绘制高亮；不改变文本树。
5. 跟随开启且句子离开视口舒适区域时滚动到上方约 1/3；对屏内词只刷新句样式，不每词滚动。
6. 渲染响应带 speechFollow 来源；该事件不得触发重新起播或覆盖手动阅读历史。

高亮合并批次最高约 10 Hz，首发以句级为主。range 回调与可听声音之间存在系统调度延迟，目标误差在真机中测量，不宣称逐词卡拉 OK 同步。

## 章节和自由浏览

speechPosition 进入下一章前预取内容；阅读视图若跟随则 navigate 并等待 ready 后高亮。自由浏览时不切视图，迷你播放器显示正在听的章。点击跟随恢复按钮才跳到当前 speechPosition。手动触控、滚轮和键盘导航都算自由浏览；程序滚动事件按来源过滤。

视图关闭后仅 detach renderer，内容服务和 SpeechCoordinator 继续；重开重新 attach 并按用户选择恢复。换书、删除书、切换引擎都递增 generation。重排期间缓存最新有效高亮，不对旧 rect 连续绘制。

## 降级与测试

映射失败先校验 quote，在同章唯一匹配才恢复；不唯一则降为段/章提示，标记 approximate，不把错误位置写回为精确位置。扫描 PDF 无映射则禁用文本朗读。离线、语音消失、WebContent 崩溃、文本版本迁移都必须有可恢复状态。

测试用 fake speech engine 按乱序发送 range/finish/cancel，验证旧 generation 不生效、手动滚动不回拉、事件不成环。真机录音与屏幕标记对齐测句级误差；不以渲染帧率替代声音测量。
