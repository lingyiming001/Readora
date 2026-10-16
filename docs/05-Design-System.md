# 05 · Design System

## 设计规则

以系统控件语义为基础，书库使用系统字体，正文允许用户选择衬线/无衬线及出版者字体；不使用 Apple Books 品牌资源。以下为初始设计 token，正式配色需在实际材质和内容上测量对比度。

| Token | 浅色 / 深色初值 | 用途 |
|---|---|---|
| surface.window | 系统 background / windowBackground | 窗口与系统容器，平台适配 |
| surface.reader.paper | #FBF8F1 / #181817 | 阅读背景，不使用模糊 |
| surface.reader.sepia | #F2E7D3 / #252018 | 护眼偏好，不宣称医学效果 |
| text.reader | #262522 / #E8E5DF | 正文 |
| text.secondary | 系统 secondary | 元信息；实际背景校验 |
| accent.primary | #805538 / #D3AE86 | 自有强调色，按钮优先系统 tint |
| feedback.error | 系统 red | 配合图标和中文错误 |
| annotation.yellow | #F4D66D，背景混合 ≤35% | 用户高亮，需兼容深色 |
| speech.active | accent + 下划线 | 当前句，区别永久批注 |

正文与背景对比度至少 4.5:1，大号文本至少 3:1；非文本必要控件至少 3:1。验收以最终合成颜色为准，不能只验 token 十六进制。增加对比度开启时取消低透明度边框。

## 排版与尺寸

| 角色 | iPhone | Mac |
|---|---|---|
| 页标题 | 系统 largeTitle，随 Dynamic Type | 系统 title/title2 |
| 控件与列表 | 系统 body 语义字号 | 系统标准控件字号 |
| 正文默认 | 20 pt，用户 14–40 pt，可继续放大 | 20 pt，用户 14–40 pt，可继续放大 |
| 元信息 | 系统 caption，支持放大 | 系统 caption |

阅读正文行高默认 1.65、范围 1.2–2.2；段间距默认 0.6 em、范围 0–1.5 em；内容最大宽 680 pt，目标每行约 28–40 汉字或 55–75 拉丁字符。iPhone 页边距 20 pt、Mac 48 pt 起；窄屏自动减至 16 pt。字体缩放后重新测量，以上不成为辅助字号上限。出版者样式可保留，但用户无障碍覆盖优先。

间距 scale 为 4/8/12/16/24/32/48 pt；控件间隙通常 8，区块 24，阅读页至少 16。圆角控件 8、卡片 12、面板使用系统规范；封面 4 避免过度圆润。阴影只用于封面和浮层，初值 y=2 blur=8 opacity=0.10，深色优先细边界。系统 sheet、popover、sidebar 使用原生材质，正文实色。

## 图标、动效与状态

SF Symbols 使用 book、books.vertical、play.fill、pause.fill、bookmark、textformat、magnifyingglass；按最低系统验证符号存在，缺失时替代。按钮应有 label 和 accessibilityLabel，不能只凭图标理解关键动作。

普通过渡 160–220 ms、面板遵循系统动画；字体重排不做弹性动画；Reduce Motion 下用短淡入或无动画。翻页动画为 V1.1，不能延迟阅读响应。

组件包含 BookCoverCard、LibraryRow、ImportTaskRow、ReaderToolbar、TOCRow、SelectionActions、MiniSpeechPlayer、SpeechPanel、SyncStatusBadge、ErrorRecoveryView。每个组件覆盖默认/悬停（Mac）/按下/焦点/选中/不可用/加载/错误；不可用解释通过辅助文本或工具提示，不依赖低透明度。

## 平台共享与覆盖

共享语义 token、图标意图、数据状态和正文样式；平台覆写工具栏密度、控件尺寸、导航容器、窗口最小尺寸。iPhone 触控目标至少 44×44 pt；Mac 保留紧凑原生控件与足够点击区域，键盘焦点环可见。布局不按设备型号硬编码，采用可用宽度和 size class。

新增组件必须给出 Preview：浅/深、最长中文标题、英文、最大辅助字号、错误态。设计资产、字体授权和颜色对比报告随版本保存；当前只交付规范，未生成资产或截图。
