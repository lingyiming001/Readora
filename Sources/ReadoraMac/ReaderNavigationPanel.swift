import SwiftUI
import ReadoraCore

struct ReaderNavigationPanel: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Picker("导航", selection: $model.readerNavigationTab) {
                Text("目录").tag(0); Text("书签").tag(1); Text("高亮").tag(2)
            }.pickerStyle(.segmented).padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if model.readerNavigationTab == 0 {
                        if let publication = model.publication {
                            ForEach(publication.chapters) { chapter in
                                Button { model.jump(to: chapter.position) } label: {
                                    Text(chapter.title).font(.system(size: 13)).lineLimit(3)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                        .background(model.position >= chapter.position && chapter.id == currentChapterID ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                            }
                        } else { empty("此书暂无章节目录") }
                    } else {
                        let marks = model.marks.filter { $0.kind == (model.readerNavigationTab == 1 ? .bookmark : .highlight) }
                        if marks.isEmpty { empty(model.readerNavigationTab == 1 ? "在喜欢的位置，留下一枚书签。" : "选择文字，右键即可添加高亮。") }
                        ForEach(marks) { mark in
                            HStack(alignment: .top, spacing: 8) {
                                Button { model.jump(to: model.position(for: mark), offset: mark.utf16Offset) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Label("第 \(model.position(for: mark) + 1) \(model.pdf == nil ? "段" : "页")", systemImage: mark.kind == .bookmark ? "bookmark.fill" : "highlighter")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(mark.quote).font(.system(size: 13)).lineLimit(4).multilineTextAlignment(.leading)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                Button { Task { await model.deleteMark(mark) } } label: { Image(systemName: "xmark").font(.caption2) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("移除标记")
                            }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }.padding(10)
            }
        }.frame(width: 260)
    }
    private var currentChapterID: String? { model.publication?.chapters.last(where: { $0.position <= model.position })?.id }
    private func empty(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.secondary).padding(16) }
}
