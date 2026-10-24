import AppKit
import XCTest
@testable import Oriel

/// Niveau de la fenêtre de la notch : au-dessus de la barre des menus (24), y compris pour le serveur de fenêtres.
final class WindowLevelTests: XCTestCase {
    /// Comportement d'AppKit qui causait le bug : `isFloatingPanel = true` remet le niveau à `.floating` (3).
    func testFloatingPanelSetterResetsLevel() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = NotchController.windowLevel
        panel.isFloatingPanel = true
        XCTAssertEqual(panel.level, .floating)
    }

    func testNotchPanelLevelIsAboveMenuBar() throws {
        _ = NSApplication.shared
        let controller = NotchController(store: SessionStore(), monitor: ClaudeMonitor(), prefs: Preferences(),
                                         tools: ToolsFeed(paths: LayoutTests.absentPaths))
        XCTAssertEqual(controller.panel.level.rawValue, NSWindow.Level.mainMenu.rawValue + 3)
        XCTAssertTrue(controller.panel.isFloatingPanel)

        controller.panel.orderFrontRegardless()
        defer { controller.panel.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let measured = try XCTUnwrap(NotchController.windowServerLevel(of: controller.panel))
        XCTAssertEqual(measured, NSWindow.Level.mainMenu.rawValue + 3, "niveau vu par le serveur de fenêtres")
    }
}
