import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Intégration Claude Code optionnelle : fenêtre du premier lancement, arrêt du suivi des sessions.
final class OptionalClaudeTests: XCTestCase {
    /// Assistant de configuration une fois, l'onglet Claude proposé seulement s'il est activé ; jamais après une mise
    /// à jour depuis une version qui avait posé les hooks ; mise à jour silencieuse ratée : on la propose.
    func testLaunchWindow() {
        func window(_ claude: Bool, _ status: HookInstaller.Status, shown: Bool = false) -> HookSetup.LaunchWindow {
            HookSetup.launchWindow(claudeEnabled: claude, status: status, welcomeShown: shown)
        }
        XCTAssertEqual(window(false, .notInstalled), .welcome(claude: false), "sans Claude Code : rien sur les hooks")
        XCTAssertEqual(window(true, .notInstalled), .welcome(claude: true), "Claude Code détecté : hooks proposés")
        XCTAssertEqual(window(true, .unreadable("x")), .welcome(claude: true))
        XCTAssertEqual(window(true, .installed), .none, "mise à jour avec hooks : pas un premier lancement")
        XCTAssertEqual(window(true, .outdated), .update)
        XCTAssertEqual(window(true, .scriptOutdated, shown: true), .update, "mise à jour ratée : proposée")
        XCTAssertEqual(window(false, .outdated), .welcome(claude: false), "onglet désactivé : hooks ignorés")
        XCTAssertEqual(window(false, .notInstalled, shown: true), .none, "une seule fois")
        XCTAssertEqual(window(true, .notInstalled, shown: true), .none, "« Plus tard » n'est pas redemandé")
    }

    /// Onglet Claude désactivé : sessions oubliées, plus de timer (donc plus de lecture de transcript) ; réactivé,
    /// elles reviennent à leur prochain événement.
    func testStoreStopForgetsSessionsAndTimer() {
        let store = SessionStore.working(2)
        store.start()
        XCTAssertTrue(store.isTicking)
        XCTAssertEqual(store.indicator, .working)

        store.stop()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(store.isTicking)
        XCTAssertEqual(store.indicator, .none)

        store.start()
        store.send("UserPromptSubmit", "s9", ["prompt": "x"])
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertTrue(store.isTicking, "réactivé : tout repart")
        store.stop()
    }

    /// Notch sans l'onglet Claude : pas d'intercalaire Claude, même avec une session au travail.
    func testNoClaudeEarsWhenTabDisabled() {
        let notch = NotchHarness(self, store: .working(1))
        func tabs() -> [String] {
            notch.registry.earTabs(claude: notch.store.indicator, claudeEars: notch.store.ears).map { $0.id }
        }
        XCTAssertEqual(tabs(), ["claude"], "intercalaire Claude")
        notch.prefs.tabEnabled["claude"] = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(notch.registry.isClaudeEnabled)
        XCTAssertEqual(tabs(), [])
        XCTAssertEqual(notch.measure().width, 185, accuracy: 1, "replié : exactement la notch")
    }
}

/// Rendus PNG : réglages et notch sans l'onglet Claude (l'assistant a les siens, voir `SetupAssistantSnapshotTests`).
/// Ne fait rien sans `ORIEL_SNAPSHOT_DIR`.
final class OptionalClaudeSnapshotTests: XCTestCase {
    func testRenderWithoutClaudeTab() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let notch = NotchHarness(self, store: .working(1))
        notch.prefs.tabEnabled["claude"] = false
        notch.prefs.visibility = .whenClaudeOpen
        notch.prefs.lastTab = "timer"
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for (section, name) in [(SettingsSection.tabs, "tabs"), (.general, "general"), (.appearance, "appearance")] {
            let view = SettingsView(prefs: notch.prefs, registry: notch.registry, updater: Updater(), selection: section)
            try TimerNotesSnapshot.render(view, "no-claude-settings-\(name)", dir, size: SettingsWindow.size,
                                          background: nil)
        }

        // Minuteur en cours, une session Claude au travail ignorée : dépliée sur le minuteur, repliée avec ses oreilles.
        for expanded in [true, false] {
            let rig = try TimerRig(self)
            let timer = rig.startedModule()
            addTeardownBlock { timer.stop() }
            timer.startSimple(minutes: 25)
            rig.clock.advance(1)
            timer.tick()
            let modules = ModuleRegistry.standardModules(claude: notch.claude).map { $0.id == timer.id ? timer : $0 }
            let registry = ModuleRegistry(modules: modules, prefs: notch.prefs)
            notch.model.isExpanded = expanded
            notch.model.selectedTab = registry.initialTab(claudeNeedsAttention: true)
            if !expanded { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let root = NotchRootView(model: notch.model, store: notch.store, registry: registry, prefs: notch.prefs,
                                     actions: NotchActions())
            try TimerNotesSnapshot.render(root, expanded ? "no-claude-expanded" : "no-claude-collapsed-timer-ears", dir)
        }
    }
}
