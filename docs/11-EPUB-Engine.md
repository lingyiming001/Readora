# 11 · EPUB 解析与渲染

## 当前实现状态（2026-10-15）

已接入 macOS 原型的基础 EPUB 2/3 导入和阅读：系统 zlib 有界内存解包、XMLParser、元数据/封面、spine、nav/NCX、资源/段落定位、原生 SwiftUI 正文/图片和系统朗读。当前不保留出版者 CSS、字体和链接交互，尚非下文 WKWebView 目标方案。实际上限以 README 为准（默认200 MB原文，可在设置调整；1 GB展开等），低于目标大书能力。加密资源、固定版式、ZIP64及不支持的正文类型明确拒绝，不绕过 DRM。当前32项核心测试通过；已做样书导入/分页/选区高亮/重开恢复UI验证，30本兼容性门槛和最低系统测试尚未完成。

以下章节保留为后续完整阅读引擎的目标设计，不代表全部已实现。

## 支持档案

首发支持无 DRM 的 EPUB 2/3 常见横排重排书，spine 阅读顺序、nav/NCX 目录、图片、基本字体/CSS 与链接。固定版式、竖排、脚本交互、媒体叠加、复杂数学和加密字体不属于首发承诺；检测到后提示限制或拒绝打开，不静默宣称完整兼容。[EPUB 3.3 标准](https://www.w3.org/TR/epub-33/) 是容器与出版物语义依据，本产品并非完整标准认证实现。

## 导入管线

1. 检查 ZIP 签名与 mimetype、META-INF/container.xml，定位 OPF；扩展名只作提示。
2. 有界解压：归一化路径后拒绝绝对路径、`..`、symlink、重复冲突条目；单书解压总量默认上限 1 GB、20,000 条目、单条 100 MB、压缩比 200:1，任一超限拒绝并给出原因，可后续增加受控大书模式。
3. XMLParser 禁用外部实体，限制 XML 大小/深度；从 metadata、manifest、spine 建 PublicationManifest；所有 href 解析必须留在包内。
4. EPUB 3 nav 优先，回退 NCX；封面按 cover-image/EPUB 2 metadata/guide 规则寻找，最后生成占位；metadata 缺失回退文件名。
5. XHTML 正文规范化和安全过滤在受控解析管线完成，去除书籍脚本、事件处理器、iframe、远端资源与危险 URL；不要用正则表达式承担完整 HTML 解析。
6. 写解析 manifest 和 textVersion 索引，缓存按 contentHash+parserVersion 分区，可重建；不更改原始 EPUB。

XHTML 优先使用 XML 结构读取；非良构 HTML 首发报兼容错误并保留原文件。若要容错需单独审计 HTML parser 依赖，不能假设 Foundation 提供通用 HTML DOM。白名单 CSS 处理复杂且可能破坏外观，先限制危险 url/@import/固定定位覆盖，配合 CSP 和导航拦截；用恶意样书验证，不能只依赖脚本禁用。

## WKWebView 宿主

每窗口一个 WebView，仅加载当前 spine 资源并预取下一章文本与资源；WKURLSchemeHandler 提供 `readora-book://<opaque-book-id>/...`，请求限定当前书根目录，返回明确 MIME 并支持取消。禁用持久 website data store；不暴露任意文件路径。外链经明确用户点击后系统浏览器打开，书中网络请求默认拒绝。[WKURLSchemeHandler 文档](https://developer.apple.com/documentation/webkit/wkurlschemehandler) 仅证明机制存在，字体、跨源与 CSP 兼容仍需双平台测试。

自有 Reader.js 运行在隔离 content world，与原生通过受控消息桥交互；消息白名单、长度/结构验证、资源 ID 和 navigation generation 校验。移除网页自带 JS，不把正文插值到脚本；参数以结构化编码传递。

## 正文与锚点

在同一规范化规则下遍历可读文本节点，排除 script/style/nav/隐藏辅助内容；保留块边界与 ruby 规则。构建 canonical UTF-16 offset → DOM node+local offset 双向表，原始提取与渲染使用相同版本的规范文本清单；隐藏样式识别若离线与 DOM 不一致必须回归修正，不能只靠 innerText 两次各自提取。

跳转先 resourceID，再 offset，quote 校验；选区输出起止锚点。朗读句范围通过 DOM Range rects 绘制独立 overlay，不包裹 span 修改 DOM，因此不改变 offset。滚动/重排后重新计算 rect，屏外句不做多余绘制。CFI 为未来互操作格式，首发不把未经验证的自研 CFI 当作标准兼容。

## 布局与异常

MVP 垂直滚动；V1.1 CSS columns 横向分页与双页，页数每次根据视口、字体和图像重新测量。设置变更先捕获锚点，等待 font ready 和稳定布局后恢复，generation 保证只有最后设置生效。允许关闭出版者字体，禁止全书一次插入造成巨大 DOM。

WebContent 进程终止后保存最后可靠锚点、重建当前章；连续失败进入安全模式关闭出版者样式，再提供导出与问题报告。页面加载超时 10 秒可取消重试；听书内容服务独立，所以无需以 WebView 作为后台存活手段。

## 技术门槛

30 本样书覆盖中文/英文/混合、长章、嵌套目录、字体、图片、脚注和恶意包。两平台字体变化后锚点命中 ≥99.5%；无网络外泄与目录穿越；高亮范围和朗读文本一致。达不到门槛不得开始高级分页。
