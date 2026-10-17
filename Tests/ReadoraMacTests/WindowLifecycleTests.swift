import AppKit
import XCTest
@testable import ReadoraMac

@MainActor
final class WindowLifecycleTests: XCTestCase {
    func testClosingMainWindowClosesAuxiliaryWindows() {
        _ = NSApplication.shared
        let main = TrackingWindow()
        let settings = TrackingWindow()
        let delegate = ReaderAppDelegate()
        delegate.mainWindow = main
        main.close()
        XCTAssertGreaterThan(settings.closeCount, 0)
        XCTAssertEqual(main.closeCount, 1)
    }

    func testClosingAuxiliaryWindowDoesNotCloseMainWindow() {
        _ = NSApplication.shared
        let main = TrackingWindow()
        let settings = TrackingWindow()
        let delegate = ReaderAppDelegate()
        delegate.mainWindow = main
        settings.close()
        XCTAssertEqual(main.closeCount, 0)
        delegate.mainWindow = nil
        main.close()
    }
}

@MainActor
private final class TrackingWindow: NSWindow {
    var closeCount = 0
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }
    override func close() {
        closeCount += 1
        super.close()
    }
}
