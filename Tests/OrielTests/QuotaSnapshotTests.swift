import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendus PNG des jauges de quota : onglets Claude et Codex (normal, ambre, rouge, une seule fenêtre), résumé compact,
/// carte de l'intercalaire, réglages. Ne fait rien sans `ORIEL_SNAPSHOT_DIR`. Données fictives, aucun hook réel,
/// faux ~/.claude et ~/.codex jetables.
final class QuotaSnapshotTests: XCTestCase {
    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["ORIEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static let iterm = ProcessContext(source: .cli, hostName: "iTerm2", hostBundleId: "com.googlecode.iterm2")
    private static let codexTerminal = CodexContext(pid: nil, start: nil, hostName: "iTerm2", hostBundleId: "com.googlecode.iterm2")

    private func windows(five: Double?, seven: Double?) -> QuotaSnapshot {
        let now = Date()
        var list: [QuotaWindow] = []
        if let five { list.append(QuotaWindow(usedPercent: five, resetsAt: now.addingTimeInterval(95 * 60), minutes: 300)) }
        if let seven { list.append(QuotaWindow(usedPercent: seven, resetsAt: now.addingTimeInterval(3 * 86_400 + 3600), minutes: 10_080)) }
        return QuotaSnapshot(windows: list, updatedAt: now)
    }

    private final class Fixed: CodexQuotaService {
        let snapshot: QuotaSnapshot
        init(_ snapshot: QuotaSnapshot) { self.snapshot = snapshot }
        func rateLimits() throws -> QuotaSnapshot { snapshot }
    }

    private final class Scene {
        let prefs: Preferences
        let store = SessionStore()
        let usage = ClaudeUsageStore()
        let claude: ClaudeModule
        let codex: CodexModule
        let registry: ModuleRegistry
        let model = NotchViewModel()
        let quota: StatusLineSetup
        let configDirectory: URL

        init(_ testCase: XCTestCase, codexQuota: QuotaSnapshot? = nil) throws {
            _ = NSApplication.shared
            prefs = Preferences(defaults: makeEphemeralDefaults(testCase))
            prefs.tabEnabled = ["claude": true, "codex": true]
            let root = try makeTemporaryDirectory(testCase)
            configDirectory = root.appendingPathComponent(".claude")
            let script = root.appendingPathComponent("oriel-statusline.sh")
            try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
            let base = HookInstaller(configDirectory: configDirectory, bundledHook: nil)
            quota = StatusLineSetup(installer: { StatusLineInstaller(base: base, bundledScript: script) }, usage: usage)
            claude = ClaudeModule(store: store, monitor: ClaudeMonitor(), tools: ToolsFeed(paths: LayoutTests.absentPaths),
                                  prefs: prefs, hooks: HookSetup(installer: base), usage: usage, quota: quota)
            let home = root.appendingPathComponent(".codex")
            let setup = CodexHookSetup(installer: { CodexHookInstaller(configDirectory: home, bundledHook: nil) })
            let reading = CodexUsageStore(service: { codexQuota.map(Fixed.init) })
            codex = CodexModule(setup: setup, usage: reading, defaults: makeEphemeralDefaults(testCase))
            codex.setTracking(true)
            registry = ModuleRegistry(modules: ModuleRegistry.standardModules(claude: claude, codex: codex), prefs: prefs)
            model.notchSize = CGSize(width: 185, height: 32)
            model.hasNotch = true
            model.isExpanded = true
            testCase.addTeardownBlock { [codex] in codex.setTracking(false) }
        }

        var root: NotchRootView {
            NotchRootView(model: model, store: store, registry: registry, prefs: prefs, actions: NotchActions())
        }

        func claudeSessions() {
            store.send("UserPromptSubmit", "site", ["prompt": "Mets à jour le README"], context: QuotaSnapshotTests.iterm)
            store.send("Stop", "site", ["last_assistant_message": "README à jour."], context: QuotaSnapshotTests.iterm)
            store.send("UserPromptSubmit", "api", ["prompt": "Lance les tests"], context: QuotaSnapshotTests.iterm)
            store.send("PreToolUse", "api", ["tool_name": "Bash", "tool_use_id": "t",
                                             "tool_input": ["command": "swift test --parallel"]], context: QuotaSnapshotTests.iterm)
        }

        func codexSession() {
            codex.store.handle(CodexFixtures.event("UserPromptSubmit", session: "c1",
                                                   ["cwd": "/Users/demo/projets/api", "prompt": "Corrige le test"]),
                               context: QuotaSnapshotTests.codexTerminal)
            codex.store.handle(CodexFixtures.event("Stop", session: "c1",
                                                   ["cwd": "/Users/demo/projets/api", "last_assistant_message": "Test corrigé."]),
                               context: QuotaSnapshotTests.codexTerminal)
        }

        /// Attend la fin de la lecture Codex (double instantané, mais sur un autre thread).
        func codexReads() -> Bool { spin { self.codex.usage.snapshot != nil } }
    }

    func testRenderClaudeTab() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        for (name, five, seven) in [("normal", 19.0, 3.0), ("high", 87.0, 63.0), ("critical", 97.0, 99.0), ("five-only", 41.0, nil)] {
            let scene = try Scene(self)
            scene.claudeSessions()
            scene.usage.ingest(try json(five: five, seven: seven))
            scene.model.selectedTab = "claude"
            try render(scene.root, name: "quota-claude-\(name)", to: outputDir)
        }
        // Pas encore de mesure (relais pas posé, ou avant la première réponse) : rien de plus dans l'onglet.
        let empty = try Scene(self)
        empty.claudeSessions()
        empty.model.selectedTab = "claude"
        try render(empty.root, name: "quota-claude-none", to: outputDir)
    }

    func testRenderCodexTab() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        for (name, five, seven) in [("normal", 19.0, 3.0), ("high", 82.0, 40.0)] {
            let scene = try Scene(self, codexQuota: windows(five: five, seven: seven))
            scene.codexSession()
            scene.model.selectedTab = "codex"
            scene.codex.start()
            XCTAssertTrue(scene.codexReads())
            try render(scene.root, name: "quota-codex-\(name)", to: outputDir)
            scene.codex.stop()
        }
    }

    /// Plein écran compact, et carte de l'intercalaire (survol de l'intercalaire, notch repliée).
    func testRenderCompactAndEarCards() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let scene = try Scene(self, codexQuota: windows(five: 62, seven: 11))
        scene.claudeSessions()
        scene.codexSession()
        scene.usage.ingest(try json(five: 84, seven: 38))
        scene.codex.start()
        XCTAssertTrue(scene.codexReads())
        scene.model.selectedTab = "claude"
        scene.model.isFullScreen = true
        try render(scene.root, name: "quota-fullscreen-compact", to: outputDir)

        for (name, module) in [("claude", scene.claude as any NotchModule), ("codex", scene.codex as any NotchModule)] {
            guard let card = module.makeTabDetailView() else { return XCTFail("carte absente") }
            try render(card.frame(width: 300).padding(10).background(Color.black), name: "quota-card-\(name)", to: outputDir,
                       size: CGSize(width: 320, height: 150), background: .black)
        }
        scene.codex.stop()
    }

    func testRenderSettings() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let scene = try Scene(self)
        // Une statusLine existante : le relais la chaîne.
        try FileManager.default.createDirectory(at: scene.configDirectory, withIntermediateDirectories: true)
        try #"{"statusLine":{"type":"command","command":"sh ~/.claude/statusline-command.sh"}}"#
            .write(to: scene.configDirectory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        func settings(_ module: String) -> SettingsView {
            SettingsView(prefs: scene.prefs, registry: scene.registry, updater: Updater(), selection: .module(module))
        }
        try render(settings("claude"), name: "quota-settings-claude-off", to: outputDir, size: SettingsWindow.size, background: nil)
        scene.quota.setOn(true)
        try render(settings("claude"), name: "quota-settings-claude-on", to: outputDir, size: SettingsWindow.size, background: nil)
        try render(settings("codex"), name: "quota-settings-codex", to: outputDir, size: SettingsWindow.size, background: nil)
        // Une statusLine qui n'est pas une commande : réglage grisé, avertissement.
        try #"{"statusLine":{"type":"static","text":"x"}}"#
            .write(to: scene.configDirectory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        scene.quota.refresh()
        try render(settings("claude"), name: "quota-settings-claude-unsupported", to: outputDir, size: SettingsWindow.size, background: nil)
    }

    private func json(five: Double?, seven: Double?) throws -> Data {
        let now = Date().timeIntervalSince1970
        var limits: [String: Any] = [:]
        if let five { limits["five_hour"] = ["used_percentage": five, "resets_at": now + 95 * 60] }
        if let seven { limits["seven_day"] = ["used_percentage": seven, "resets_at": now + 3 * 86_400 + 3600] }
        return try JSONSerialization.data(withJSONObject: ["rate_limits": limits])
    }

    /// Fenêtre hors écran + rendu de l'arbre de calques, comme ClaudeSnapshotTests.
    private func render<V: View>(_ view: V, name: String, to dir: URL, size: CGSize = NotchController.panelSize,
                                 background: Color? = Color(white: 0.85)) throws {
        let hosting = NSHostingView(rootView: view.background(background ?? Color(nsColor: .windowBackgroundColor)))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let layer = hosting.layer,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                            pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return XCTFail("rendu impossible")
        }
        let cg = context.cgContext
        cg.translateBy(x: 0, y: size.height * scale)
        cg.scaleBy(x: scale, y: -scale)
        layer.render(in: cg)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return XCTFail("PNG") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        window.close()
    }
}
