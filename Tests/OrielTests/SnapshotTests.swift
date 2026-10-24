import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rend la notch hors écran en PNG pour contrôle visuel.
/// Ne fait rien sans `ORIEL_SNAPSHOT_DIR`.
final class SnapshotTests: XCTestCase {
    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["ORIEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    /// Trois sessions : une au travail (tâches, agents), une qui attend une permission, une terminée.
    static func sampleStore() -> SessionStore {
        let store = SessionStore()
        let context = ProcessContext(source: .cli, hostName: "iTerm2", hostBundleId: "com.googlecode.iterm2")
        func send(_ name: String, _ sid: String, _ extra: [String: Any] = [:]) {
            store.send(name, sid, extra, context: context)
        }
        send("SessionStart", "mon-app", ["source": "startup"])
        send("UserPromptSubmit", "mon-app", ["prompt": "Lance les tests puis corrige le parseur"])
        send("PreToolUse", "mon-app", ["tool_name": "TodoWrite", "tool_use_id": "t0", "tool_input": ["todos": [
            ["content": "Lancer les tests", "status": "completed", "activeForm": "Lancement des tests"],
            ["content": "Corriger le parseur", "status": "in_progress", "activeForm": "Correction du parseur"],
            ["content": "Relancer la suite", "status": "pending", "activeForm": "Relance"],
        ]]])
        send("PreToolUse", "mon-app", ["tool_name": "Bash", "tool_use_id": "t1",
                                       "tool_input": ["command": "npm test -- --watch=false"]])
        send("SubagentStart", "mon-app", ["agent_id": "a1"])
        send("SubagentStart", "mon-app", ["agent_id": "a2"])

        send("UserPromptSubmit", "api", ["prompt": "Supprime le dossier build"])
        send("PreToolUse", "api", ["tool_name": "Bash", "tool_use_id": "p1", "tool_input": ["command": "rm -rf build"]])
        send("PermissionRequest", "api", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]])

        send("UserPromptSubmit", "site", ["prompt": "Mets à jour le README"])
        send("Stop", "site", ["last_assistant_message": "## **README à jour** : section installation réécrite."])
        return store
    }

    func testRenderStates() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let store = Self.sampleStore()
        let empty = SessionStore()
        func notch(_ store: SessionStore, _ tools: ToolsFeed = ToolsFeed(paths: LayoutTests.absentPaths),
                   expanded: Bool = true) -> NotchHarness {
            let notch = NotchHarness(self, store: store, tools: tools)
            notch.model.isExpanded = expanded
            return notch
        }

        try render(notch(store, expanded: false).root, name: "collapsed", to: outputDir)
        try render(notch(store).root, name: "expanded", to: outputDir)
        try render(notch(empty).root, name: "empty", to: outputDir)

        // Section outils : fichiers récents (dont un supprimé), git avec deux dépôts à traiter, usage du jour.
        let fixtures = try ToolsFixtures()
        defer { fixtures.remove() }
        try fixtures.writeSample(now: Date())
        let tools = ToolsFeed(paths: fixtures.paths) { !$0.hasSuffix("old-config.ts") }
        tools.refreshNow()

        for (pane, name) in [(nil, "tools"), (ToolsPane.files, "tools-files"), (.git, "tools-git")] {
            let withTools = notch(store, tools)
            withTools.claude.toolsPane = pane
            try render(withTools.root, name: name, to: outputDir)
        }
        try render(notch(empty, tools).root, name: "tools-no-session", to: outputDir)

        // Beaucoup de sessions et volet ouvert : la liste rétrécit, tout tient dans le panneau.
        let crowded = Self.sampleStore()
        for index in 0..<5 {
            crowded.send("UserPromptSubmit", "projet-\(index)", ["prompt": "Tâche \(index)"])
        }
        let crowdedNotch = notch(crowded, tools)
        crowdedNotch.claude.toolsPane = .files
        try render(crowdedNotch.root, name: "tools-crowded", to: outputDir)

        // Onglets : chaque module vide, et les trois tailles de panneau.
        for id in ["media", "quicksettings", "shelf", "clipboard", "timer", "notes"] {
            let tab = notch(store)
            tab.model.selectedTab = id
            try render(tab.root, name: "tab-\(id)", to: outputDir)
        }
        for size in [PanelSize.compact, .large] {
            let sized = notch(store)
            sized.prefs.panelSize = size
            try render(sized.root, name: "panel-\(size.rawValue)", to: outputDir)
        }
        let translucent = notch(store)
        translucent.prefs.backgroundOpacity = 0.8
        try render(translucent.root, name: "panel-opacity-80", to: outputDir)

        // Plein écran, réglage compact : demi-largeur, sessions en cours et résumés des modules.
        let fullScreen = notch(crowded)
        fullScreen.model.isFullScreen = true
        try render(fullScreen.root, name: "fullscreen-compact", to: outputDir)
        let fullScreenEmpty = notch(empty)
        fullScreenEmpty.model.isFullScreen = true
        try render(fullScreenEmpty.root, name: "fullscreen-compact-empty", to: outputDir)

        // Oreilles d'un module (minuteur) quand Claude ne fait rien.
        let idle = notch(empty, expanded: false)
        let timer = FakeModule(id: "timer", ears: ModuleEars(symbol: "timer", text: "4:59"), keepsRunning: true)
        let registry = ModuleRegistry(modules: [idle.claude, timer], prefs: idle.prefs)
        registry.reconcile()
        try render(NotchRootView(model: idle.model, store: empty, registry: registry, prefs: idle.prefs,
                                 actions: NotchActions()), name: "collapsed-module-ears", to: outputDir)

        // Couleur d'accent : lue dans les réglages partagés, remise en état ensuite.
        let original = Preferences.shared.accentHex
        Preferences.shared.accentHex = "4C8DFF"
        defer {
            Preferences.shared.accentHex = original
            UserDefaults.standard.removeObject(forKey: "appearance.accent")
        }
        try render(notch(store).root, name: "accent-blue", to: outputDir)
        try render(notch(store, expanded: false).root, name: "accent-blue-collapsed", to: outputDir)
        Preferences.shared.accentHex = original

        // Git propre et usage seul.
        try fixtures.writeSample(now: Date(), gitClean: true)
        try FileManager.default.removeItem(at: fixtures.paths.files)
        tools.refreshNow()
        try render(notch(empty, tools).root, name: "tools-git-clean", to: outputDir)

        // Autres données (lecture seule) : `ORIEL_TOOLS_DIR` = dossier contenant files.jsonl, state.json
        // et today.json, ou `standard` pour les vrais fichiers partagés de l'utilisateur.
        if let dir = ProcessInfo.processInfo.environment["ORIEL_TOOLS_DIR"] {
            let base = URL(fileURLWithPath: dir)
            let real = ToolsFeed(paths: dir == "standard" ? .standard : ToolsFeed.Paths(
                files: base.appendingPathComponent("files.jsonl"), gitState: base.appendingPathComponent("state.json"),
                usage: base.appendingPathComponent("today.json")))
            real.refreshNow()
            print("TOOLS \(real.debugSummary)")
            for (pane, name) in [(nil, "tools-real"), (ToolsPane.files, "tools-real-files"), (.git, "tools-real-git")] {
                let realNotch = notch(store, real)
                realNotch.claude.toolsPane = pane
                try render(realNotch.root, name: name, to: outputDir)
            }
        }

        // Fenêtre de premier lancement : installation normale, depuis le DMG, mise à jour en erreur.
        // 32 pt en haut : la place de la barre de titre transparente de la vraie fenêtre.
        func onboarding(_ view: OnboardingView, _ name: String) throws {
            try render(view.padding(.top, 32).background(Color.black), name: name, to: outputDir,
                       size: CGSize(width: 470, height: 640))
        }
        try onboarding(OnboardingView(mode: .install, inApplications: true, launchAtLogin: true,
                                      onInstall: { _ in nil }, onClose: { _ in }), "onboarding")
        try onboarding(OnboardingView(mode: .install, inApplications: false, launchAtLogin: true,
                                      onInstall: { _ in nil }, onClose: { _ in }), "onboarding-dmg")
        let error = HookInstaller.Failure.invalidSettings("« , » ou « } » attendu, ligne 3, colonne 8")
        try onboarding(OnboardingView(mode: .update, inApplications: true, launchAtLogin: false,
                                      error: error.localizedDescription, onInstall: { _ in nil }, onClose: { _ in }),
                       "onboarding-error")
    }

    /// Fenêtre de réglages, chaque volet. Réglages jetables ; aucun bouton n'est actionné.
    func testRenderSettings() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let notch = NotchHarness(self)
        let sections: [(SettingsSection, String)] = [
            (.general, "general"), (.tabs, "tabs"), (.appearance, "appearance"), (.module("claude"), "claude"),
            (.updates, "updates"), (.about, "about"),
        ]
        for (section, name) in sections {
            let view = SettingsView(prefs: notch.prefs, registry: notch.registry, updater: Updater(),
                                    selection: section)
            try render(view, name: "settings-\(name)", to: outputDir, size: SettingsWindow.size, background: nil)
        }
    }

    /// Fenêtre hors écran + rendu de l'arbre de calques (ScrollView compris, contrairement à ImageRenderer).
    private func render<V: View>(_ view: V, name: String, to dir: URL,
                                 size: CGSize = NotchController.panelSize,
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
        // Le calque de NSHostingView est géométriquement retourné : on remet l'origine en haut.
        cg.translateBy(x: 0, y: size.height * scale)
        cg.scaleBy(x: scale, y: -scale)
        layer.render(in: cg)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return XCTFail("PNG") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        window.close()
    }
}
