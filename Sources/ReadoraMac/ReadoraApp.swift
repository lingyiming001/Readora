import SwiftUI
import AppKit
import PDFKit
import AVFoundation
import UniformTypeIdentifiers
import ReadoraCore

@main
struct ReadoraApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(ReaderAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup(AppModel.testLibrary == nil ? "Readora" : "Readora · 测试", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 620)
                .background(MainWindowReference { appDelegate.mainWindow = $0 })
                .task {
                    appDelegate.model = model
                    appDelegate.openMainWindow = { openWindow(id: "main") }
                    await model.load()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 800)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await model.flushProgress(); await model.flushPreferences() } }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入书籍…") { model.chooseFile() }.keyboardShortcut("o").disabled(model.libraryFilter == .trash && model.current == nil)
            }
        }
        Settings { ImportSettingsView(model: model) }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        let deletionSnapshot = model.manualDeletion ?? []
        Group {
            if let book = model.current {
                ReaderView(model: model, book: book).id(book.id)
                    .toolbar(.hidden, for: .windowToolbar)
            } else {
                NavigationSplitView {
                    LibrarySidebar(model: model)
                        .navigationSplitViewColumnWidth(min: 210, ideal: 235)
                } detail: { LibraryView(model: model) }
                .toolbar {
                    if model.libraryFilter != .trash {
                        ToolbarItem { Button("导入书籍", systemImage: "plus") { model.chooseFile() }.disabled(model.isImporting) }
                    }
                    ToolbarItem { if model.isLoading || model.isImporting { ProgressView().controlSize(.small) } }
                }
            }
        }
        .readoraTheme(model.preferences.theme)
        .overlay(alignment: .topTrailing) { ExternalOperationConfirmation(model: model) }
        .onChange(of: model.externalSettingsRequest) { _, _ in openSettings() }
        .sheet(isPresented: $model.showAIAssistant, onDismiss: {
            if model.pendingAIImport { model.pendingAIImport = false; model.chooseFile() }
        }) { AIReadingAssistant(model: model) }
        .confirmationDialog("永久删除这\(deletionSnapshot.count)本书？", isPresented: Binding(get: { model.manualDeletion != nil }, set: { if !$0 { model.manualDeletion = nil } }), titleVisibility: .visible) {
            Button("永久删除", role: .destructive) {
                model.manualDeletion = nil
                Task {
                    do { try await model.deleteConfirmedTrash(Set(deletionSnapshot)) }
                    catch { model.error = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) { model.manualDeletion = nil }
        } message: {
            Text("删除应用内的书籍副本、相关标记与缓存，无法在应用中还原；原始导入来源文件不修改。只删除本次确认清单中的书籍。")
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.plainText, .pdf, UTType(filenameExtension: "epub") ?? .data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.importFiles(urls) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .task(id: model.requestedBookID) { await model.open(model.requestedBookID) }
        .alert("Readora", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private struct MainWindowReference: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onWindow = onWindow
        return view
    }
    func updateNSView(_ nsView: WindowView, context: Context) { nsView.onWindow = onWindow }
    final class WindowView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

@MainActor
final class ReaderAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isTerminating = false
    weak var mainWindow: NSWindow? {
        didSet {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: oldValue)
            if let mainWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWillClose(_:)),
                    name: NSWindow.willCloseNotification, object: mainWindow)
            }
        }
    }
    private var closingPanels = false

    @objc private func mainWindowWillClose(_ notification: Notification) {
        guard !closingPanels, let window = notification.object as? NSWindow, window === mainWindow else { return }
        closingPanels = true
        // Clear deferred actions before sheet dismissal can trigger their callbacks.
        model?.pendingAIImport = false
        model?.showAIAssistant = false
        model?.showImporter = false
        model?.manualDeletion = nil
        model?.error = nil
        model?.mcp.resolve(false)
        for other in NSApplication.shared.windows where other !== window {
            closePanels(attachedTo: other)
            other.close()
        }
        closePanels(attachedTo: window)
        closingPanels = false
        if let model {
            Task { await model.flushProgress(); await model.flushPreferences() }
        }
    }

    private func closePanels(attachedTo window: NSWindow) {
        for sheet in window.sheets {
            closePanels(attachedTo: sheet)
            window.endSheet(sheet, returnCode: .cancel)
            sheet.close()
        }
        for child in window.childWindows ?? [] {
            closePanels(attachedTo: child)
            child.close()
        }
    }
    var openMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = mainWindow {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            model.mcp.stop()
            await model.flushProgress()
            await model.flushPreferences()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
