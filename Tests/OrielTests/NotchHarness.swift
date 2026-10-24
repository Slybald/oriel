import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Notch complète (modules standard, réglages jetables) pour les tests de mise en page et les captures.
final class NotchHarness {
    let model = NotchViewModel()
    let store: SessionStore
    let prefs: Preferences
    let claude: ClaudeModule
    let registry: ModuleRegistry

    init(_ testCase: XCTestCase, store: SessionStore = SessionStore(),
         tools: ToolsFeed = ToolsFeed(paths: LayoutTests.absentPaths)) {
        _ = NSApplication.shared
        self.store = store
        prefs = Preferences(defaults: makeEphemeralDefaults(testCase))
        // Sans la carte qui propose les réponses : les mesures portent sur la liste des sessions.
        prefs.replyPromptDismissed = true
        // Jamais le vrai ~/.claude : un dossier de configuration vide.
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("oriel-no-config")
        let hooks = HookSetup(installer: HookInstaller(configDirectory: config, bundledHook: nil))
        claude = ClaudeModule(store: store, monitor: ClaudeMonitor(), tools: tools, prefs: prefs, hooks: hooks)
        registry = ModuleRegistry(modules: ModuleRegistry.standardModules(claude: claude), prefs: prefs)
        model.notchSize = CGSize(width: 185, height: 32)
        model.hasNotch = true
    }

    var root: NotchRootView {
        NotchRootView(model: model, store: store, registry: registry, prefs: prefs, actions: NotchActions())
    }

    /// Affiche la notch dans un panneau hors écran, laisse SwiftUI la mettre en page et rend la taille mesurée.
    @discardableResult
    func measure(settle: TimeInterval = 0.6) -> CGSize {
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: NotchController.panelSize)
        let window = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        window.close()
        return model.contentSize
    }
}

/// Événements de hook simulés.
extension SessionStore {
    func send(_ name: String, _ sid: String, _ extra: [String: Any] = [:],
              context: ProcessContext = ProcessContext()) {
        var raw: [String: Any] = ["hook_event_name": name, "session_id": sid, "cwd": "/Users/x/Projets/\(sid)"]
        raw.merge(extra) { $1 }
        handle(HookEvent(raw: raw), context: context)
    }

    /// `count` sessions qui lancent `npm test`.
    static func working(_ count: Int) -> SessionStore {
        let store = SessionStore()
        for index in 0..<count {
            let sid = "s\(index)"
            store.send("UserPromptSubmit", sid, ["prompt": "x"])
            store.send("PreToolUse", sid, ["tool_name": "Bash", "tool_use_id": "t\(index)",
                                           "tool_input": ["command": "npm test"]])
        }
        return store
    }
}
