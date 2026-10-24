import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendus PNG de l'onglet Codex : sessions, approbation, états vides, plein écran compact, réglages, oreilles.
/// Ne fait rien sans `ORIEL_SNAPSHOT_DIR`. Données fictives, aucun hook réel, faux ~/.codex jetable.
final class CodexSnapshotTests: XCTestCase {
    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["ORIEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static let iterm = CodexContext(pid: nil, start: nil, hostName: "iTerm2", hostBundleId: "com.googlecode.iterm2")
    private static let editor = CodexContext(pid: nil, start: nil, hostName: "VS Code", hostBundleId: "com.microsoft.VSCode")
    private static let app = CodexContext(pid: nil, start: nil, hostName: "ChatGPT", hostBundleId: "com.openai.codex")

    /// Notch dépliée sur l'onglet Codex, avec son propre module et des réglages jetables.
    private final class Scene {
        let prefs: Preferences
        let codex: CodexModule
        let registry: ModuleRegistry
        let model = NotchViewModel()
        let installer: CodexHookInstaller
        let home: URL

        init(_ testCase: XCTestCase, reply: Bool = true, hooks: Hooks = .installed) throws {
            _ = NSApplication.shared
            prefs = Preferences(defaults: makeEphemeralDefaults(testCase))
            prefs.tabEnabled = ["codex": true]
            home = try makeTemporaryDirectory(testCase).appendingPathComponent(".codex")
            let script = home.deletingLastPathComponent().appendingPathComponent("codex-notch-hook.sh")
            try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
            installer = CodexHookInstaller(configDirectory: home, bundledHook: script)
            let setup = CodexHookSetup(installer: { [installer] in installer })
            codex = CodexModule(setup: setup, defaults: makeEphemeralDefaults(testCase))
            codex.replyFromNotch = reply
            codex.setTracking(true)
            let claude = ClaudeModule(store: SessionStore(), monitor: ClaudeMonitor(),
                                      tools: ToolsFeed(paths: LayoutTests.absentPaths), prefs: prefs,
                                      hooks: HookSetup(installer: HookInstaller(
                                          configDirectory: FileManager.default.temporaryDirectory
                                              .appendingPathComponent("oriel-no-config"), bundledHook: nil)))
            registry = ModuleRegistry(modules: ModuleRegistry.standardModules(claude: claude, codex: codex), prefs: prefs)
            model.notchSize = CGSize(width: 185, height: 32)
            model.hasNotch = true
            model.isExpanded = true
            model.selectedTab = "codex"
            if hooks != .none { try installer.install() }
            if hooks == .reviewed {
                try installer.hookKeys().map { "[hooks.state.\(CodexAppServer.tomlQuoted($0))]\ntrusted_hash = \"sha256:00\"\n" }
                    .joined(separator: "\n").write(to: installer.configURL, atomically: true, encoding: .utf8)
            }
            setup.refresh()
            testCase.addTeardownBlock { [codex] in codex.setTracking(false) }
        }

        enum Hooks { case none, installed, reviewed }

        var root: NotchRootView {
            NotchRootView(model: model, store: SessionStore(), registry: registry, prefs: prefs, actions: NotchActions())
        }

        func send(_ name: String, _ sid: String, _ context: CodexContext, _ extra: [String: Any] = [:],
                  cwd: String = "/Users/demo/projets/site") {
            codex.store.handle(CodexFixtures.event(name, session: sid, ["cwd": cwd].merging(extra) { $1 }), context: context)
        }

        /// Session en attente d'approbation : événements relayés, puis requête tenue (carte d'approbation).
        func ask(_ sid: String, prompt: String, command: String, note: String? = nil, context: CodexContext,
                 cwd: String = "/Users/demo/projets/api") {
            send("UserPromptSubmit", sid, context, ["prompt": prompt], cwd: cwd)
            let event = CodexFixtures.bash(command, "PermissionRequest", session: sid, description: note)
            codex.codexHold(HookEvent(raw: event.raw.merging(["cwd": cwd]) { $1 }), context: context, id: UUID()) { _ in }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        func working(_ sid: String, command: String, context: CodexContext, cwd: String) {
            send("UserPromptSubmit", sid, context, ["prompt": "Lance les tests"], cwd: cwd)
            codex.store.handle(CodexFixtures.bash(command, session: sid), context: context)
        }

        func done(_ sid: String, _ message: String, context: CodexContext, cwd: String) {
            send("UserPromptSubmit", sid, context, ["prompt": "Mets à jour le README"], cwd: cwd)
            send("Stop", sid, context, ["last_assistant_message": message], cwd: cwd)
        }
    }

    func testRenderCodexTab() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }

        // Trois sessions : une attend une approbation (carte), une travaille, une a fini.
        let sessions = try Scene(self)
        sessions.ask("a", prompt: "Nettoie le build", command: "rm -rf build && swift build -c release",
                     note: "Rebuild propre", context: Self.iterm)
        sessions.working("b", command: "swift test --parallel", context: Self.editor, cwd: "/Users/demo/projets/mon-app")
        sessions.done("c", "README à jour : section installation réécrite.", context: Self.app, cwd: "/Users/demo/projets/docs")
        try render(sessions.root, name: "codex-sessions", to: outputDir)

        // Commande longue : coupée, avec l'invitation à la lire dans la session.
        let long = try Scene(self)
        long.ask("a", prompt: "Déploie", command: (1...9).map {
            "kubectl --context prod-\($0) rollout restart deployment/api-\($0) --namespace services"
        }.joined(separator: " && \\\n"), context: Self.iterm)
        try render(long.root, name: "codex-approval-long", to: outputDir)

        // Patch de fichiers et outil MCP.
        let patch = try Scene(self)
        patch.send("UserPromptSubmit", "a", Self.app, ["prompt": "Corrige le bug"])
        let edit = CodexFixtures.event("PermissionRequest", session: "a", [
            "tool_name": "apply_patch",
            "tool_input": ["command": "*** Begin Patch\n*** Update File: Sources/App/main.swift\n@@\n-a\n+b\n*** Add File: docs/NOTES.md\n+x\n*** End Patch"],
        ])
        patch.codex.codexHold(edit, context: Self.app, id: UUID()) { _ in }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try render(patch.root, name: "codex-approval-patch", to: outputDir)

        // Réglage coupé : pas de carte, la consigne « Réponds dans … ».
        let off = try Scene(self, reply: false)
        off.ask("a", prompt: "Supprime le cache", command: "rm -rf .cache", context: Self.iterm)
        off.working("b", command: "git status", context: Self.editor, cwd: "/Users/demo/projets/mon-app")
        try render(off.root, name: "codex-reply-off", to: outputDir)

        // Retour après un clic : « Autorisé depuis la notch ».
        let decided = try Scene(self)
        decided.ask("a", prompt: "Supprime le cache", command: "rm -rf .cache", context: Self.iterm)
        decided.codex.decide(try XCTUnwrap(decided.codex.approvals.requests.first), .allow)
        try render(decided.root, name: "codex-approval-allowed", to: outputDir)
    }

    func testRenderEmptyStates() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        try render(try Scene(self, hooks: .none).root, name: "codex-empty-no-hooks", to: outputDir)
        try render(try Scene(self, hooks: .installed).root, name: "codex-empty-to-review", to: outputDir)
        try render(try Scene(self, hooks: .reviewed).root, name: "codex-empty-ready", to: outputDir)
    }

    func testRenderCompactAndSettings() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let scene = try Scene(self)
        scene.ask("a", prompt: "Nettoie le build", command: "rm -rf build", context: Self.iterm)
        scene.working("b", command: "swift test --parallel", context: Self.editor, cwd: "/Users/demo/projets/mon-app")
        scene.done("c", "README à jour.", context: Self.app, cwd: "/Users/demo/projets/docs")
        let compact = scene.codex.makeCompactView()!
            .frame(width: 270)
            .padding(10)
            .background(Color.black)
        try render(compact, name: "codex-compact", to: outputDir, size: CGSize(width: 290, height: 330), background: nil)

        let installed = try Scene(self, hooks: .installed)
        try render(SettingsView(prefs: installed.prefs, registry: installed.registry, updater: Updater(),
                                selection: .module("codex")),
                   name: "codex-settings-to-approve", to: outputDir, size: SettingsWindow.size, background: nil)
        let active = try Scene(self, hooks: .reviewed)
        try render(SettingsView(prefs: active.prefs, registry: active.registry, updater: Updater(),
                                selection: .module("codex")),
                   name: "codex-settings-active", to: outputDir, size: SettingsWindow.size, background: nil)
        let bare = try Scene(self, hooks: .none)
        try render(SettingsView(prefs: bare.prefs, registry: bare.registry, updater: Updater(), selection: .module("codex")),
                   name: "codex-settings-no-hooks", to: outputDir, size: SettingsWindow.size, background: nil)
    }

    /// Notch repliée : les oreilles de Codex (travaille, attend une approbation).
    func testRenderEars() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let working = try Scene(self)
        working.model.isExpanded = false
        working.working("a", command: "swift test", context: Self.iterm, cwd: "/Users/demo/projets/api")
        XCTAssertTrue(spin { working.registry.earsEntries.contains { $0.id == "codex" } })
        try render(working.root, name: "codex-ears-working", to: outputDir, size: CGSize(width: 420, height: 90))

        let waiting = try Scene(self)
        waiting.model.isExpanded = false
        waiting.ask("a", prompt: "x", command: "rm -rf build", context: Self.iterm)
        XCTAssertTrue(spin { waiting.registry.earsEntries.first?.ears.priority == 9 })
        try render(waiting.root, name: "codex-ears-attention", to: outputDir, size: CGSize(width: 420, height: 90))
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
