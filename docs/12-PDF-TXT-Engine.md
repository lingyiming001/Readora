# 12 · PDF / TXT 阅读引擎

## PDF

使用 PDFDocument/PDFView，通过 NSViewRepresentable/UIViewRepresentable 桥接。优先系统缩放、选择、链接和 PDFOutline；当前页与可视区域保存为 PDFAnchor。pageIndex 从零开始，rect 相对 crop box 左上归一化，处理 page rotation、裁剪与缩放后再投影，不保存屏幕坐标。

读取每页 text/string 与 selection range，记录抽取文本版本和 page range。多栏、脚注与阅读顺序需在预览验证；不能把 PDF text 顺序当作语义正文保证。扫描页显示「此页无可提取文字」，禁用朗读和搜索，不内置 OCR。加密 PDF 允许系统支持的密码打开（不保存密码到日志），权限限制复制/提取时尊重限制；DRM 或不支持保护拒绝。

高亮批注先存应用数据库，不修改用户原始 PDF；导出带注释副本是后续独立能力。语音高亮由文本范围定位 PDFSelection 与 quads，范围不可靠则降级为页级提示并说明。PDF 无行距、字体和页边距重排；夜间只改外壳，避免默认反色伤害图表。双页在大窗口启用，窄宽返回单页。

大 PDF 按需加载当前页与少量邻页缩略图，生成任务限并发 2，可取消；文档对象隔离在所属执行上下文，不假设 PDFKit 全部 API 线程安全。显示操作在 MainActor，后台文本抽取使用独立文档实例并先通过压力测试。

## TXT

导入读取前部样本：UTF-8、带 BOM 的 UTF-16 优先；其他编码检测只给建议，用户预览确认 GB18030 等候选，不自动覆盖原文。统一换行为 LF，不随意 trim 段内空格；规范化版本固定。保留原文 hash、编码、byte→canonical UTF-16 检查点表。

按约 64–256 KB 块渐进解码，跨块保留不完整字节序列与组合字符；段落建立稳定虚拟 resourceID，通常按章节或约 64K UTF-16 单元分段，分段边界不切 surrogate pair。长单段为渲染拆块但映射回同一规范文本，不人为插入可朗读的段落。

TextKit 2 管理当前分块的 NSTextContentStorage/NSTextLayoutManager 等平台适配，选择跨块与全选须专门设计；MVP 可限制跨块长选择并明确说明。文档虚拟化保留当前/邻块，不能对 100 MB TXT 一次创建完整 attributed string。TXT 章节通过保守标题规则推断，用户可关闭；误判目录不改变文本顺序。

## 搜索与限制

EPUB/TXT 共用规范文本索引，PDF 为页文本索引；结果返回真实 ReadingLocation。中文默认需验证 FTS tokenizer，不能假定 unicode61 自动获得中文词分割。MVP 只搜索书库元数据，V1 全文可用规范文本 n-gram 候选 + 原文核验，索引膨胀超标时回退逐章匹配。搜索按页返回、可取消，不在主线程遍历全书。

## 格式回归集

PDF 覆盖文本、扫描、多栏、旋转、裁剪、密码、权限限制、500/2,000 页与损坏交叉引用。TXT 覆盖 UTF-8/UTF-16/GB18030、无换行、emoji、组合附标、CRLF、100 MB 大文件与误判编码。恢复、选择、搜索和朗读必须共用同一映射，所有范围截断均先验证 Unicode 边界。
