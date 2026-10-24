import Combine
import Foundation
import XCTest
@testable import Oriel

/// Le module Codex dans l'architecture des onglets : contrat, cycle de vie, oreilles, premier lancement.
final class CodexModuleTests: XCTestCase {
    private func makeModule(reply: Bool = false) -> CodexModule {
        let module = CodexModule(defaults: makeEphemeralDefaults(self))
        module.replyFromNotch = reply
        module.setTracking(true)
        addTeardownBlock { module.setTracking(false) }
        return module
    }

    private func send(_ module: CodexModule, _ event: HookEvent) {
        module.store.handle(event, context: CodexFixtures.terminal)
    }

    func testIdentityAndDefaults() {
        let module = makeModule()
        XCTAssertEqual(module.id, "codex", "l'identifiant est la clé des réglages : il ne change jamais")
        XCTAssertEqual(ModuleRegistry.codexId, "codex")
        XCTAssertFalse(module.isEnabledByDefault, "activé seulement si Codex est détecté (décidé au premier lancement)")
        XCTAssertFalse(module.replyFromNotch, "approbation depuis la notch : désactivée par défaut")
        XCTAssertNotNil(module.makeSettingsView())
        XCTAssertNotNil(module.makeCompactView())
        XCTAssertNotNil(module.makeTabIcon())
        XCTAssertFalse(module.symbol.isEmpty)
    }

    func testReplySettingIsStoredUnderTheModuleNamespace() {
        let defaults = makeEphemeralDefaults(self)
        let module = CodexModule(defaults: defaults)
        module.replyFromNotch = true
        XCTAssertTrue(defaults.bool(forKey: "codex.replyFromNotch"))
        XCTAssertTrue(CodexModule(defaults: defaults).replyFromNotch)
    }

    func testEarsFollowTheActivity() {
        let module = makeModule()
        XCTAssertNil(module.ears)
        XCTAssertFalse(module.keepsRunningWhenCollapsed, "au repos : rien ne tourne panneau replié")

        send(module, CodexFixtures.event("UserPromptSubmit", ["prompt": "x"]))
        XCTAssertEqual(module.ears?.text, "1")
        XCTAssertEqual(module.ears?.priority, 6)
        XCTAssertTrue(module.keepsRunningWhenCollapsed)

        module.store.markWaiting(sessionId: CodexFixtures.session, tool: CodexTools.describe(name: "Bash", input: ["command": "ls"]),
                                 context: CodexFixtures.terminal, cwd: nil)
        XCTAssertEqual(module.ears?.symbol, "hand.raised.fill")
        XCTAssertEqual(module.ears?.priority, 9, "une approbation attendue passe devant le minuteur (5)")
        XCTAssertTrue(module.needsAttention)

        send(module, CodexFixtures.event("Stop", ["last_assistant_message": "ok"]))
        XCTAssertEqual(module.ears?.symbol, "checkmark.circle.fill")
        XCTAssertFalse(module.needsAttention)

        // Un « Terminé » dont les 5 s sont passées ne montre plus rien.
        send(module, CodexFixtures.event("UserPromptSubmit", ["prompt": "y"]))
        module.store.handle(CodexFixtures.event("Stop", ["last_assistant_message": "ok"]), context: CodexFixtures.terminal,
                            now: Date().addingTimeInterval(-CodexStore.doneFlashDuration - 1))
        XCTAssertNil(module.ears, "le « terminé » dure 5 s")
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
    }

    /// Les oreilles de Codex ont leur intercalaire comme celles de n'importe quel module ; une approbation attendue
    /// est une alerte (elle reste déployée en mode « Rétractés »).
    func testEarsGetTheirOwnTab() {
        let codex = ModuleEarsEntry(id: "codex", ears: ModuleEars(symbol: "x", text: "1", priority: 6))
        let timer = ModuleEarsEntry(id: "timer", ears: ModuleEars(symbol: "timer", text: "4:59", priority: 5))
        func ids(_ claude: NotchIndicator, _ modules: [ModuleEarsEntry]) -> [String] {
            EarTabs.tabs(claude: claude, claudeEars: nil, modules: modules, showEars: true).map(\.id)
        }
        XCTAssertEqual(ids(.working, [timer, codex]), ["claude", "codex", "timer"], "Claude, puis par priorité décroissante")
        XCTAssertEqual(ids(.none, [timer, codex]), ["codex", "timer"])
        XCTAssertEqual(ids(.attention, [codex]), ["claude", "codex"])
    }

    func testWaitingForApprovalIsAnAlertTab() {
        let module = makeModule()
        send(module, CodexFixtures.event("UserPromptSubmit", ["prompt": "x"]))
        XCTAssertEqual(module.ears?.alert, false, "au travail : pas une alerte")
        module.store.markWaiting(sessionId: CodexFixtures.session, tool: CodexTools.describe(name: "Bash", input: ["command": "ls"]),
                                 context: CodexFixtures.terminal, cwd: nil)
        XCTAssertEqual(module.ears?.alert, true, "une approbation attend : alerte")
    }

    func testRegistryStartsTheModuleOnlyWhileUseful() throws {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let module = makeModule()
        let registry = ModuleRegistry(modules: [FakeModule(id: "claude"), module], prefs: prefs)
        XCTAssertFalse(registry.isEnabled("codex"), "désactivé tant que le premier lancement n'a rien décidé")
        registry.setEnabled("codex", true)
        XCTAssertTrue(spin { registry.isEnabled("codex") && registry.enabled.map(\.id).contains("codex") })
        XCTAssertFalse(registry.running.contains("codex"), "replié et sans activité : rien ne tourne")

        send(module, CodexFixtures.event("UserPromptSubmit", ["prompt": "x"]))
        XCTAssertTrue(spin { registry.running.contains("codex") }, "Codex travaille : le module tourne replié")
        XCTAssertTrue(spin { registry.earsEntries.contains { $0.id == "codex" } })

        send(module, CodexFixtures.event("Interrupt"))
        XCTAssertTrue(spin { !registry.running.contains("codex") }, "plus d'activité : le module s'arrête")

        registry.setEnabled("codex", true)
        registry.setPanelOpen(true)
        XCTAssertTrue(spin { registry.running.contains("codex") }, "panneau ouvert : tous les onglets activés tournent")
        registry.setEnabled("codex", false)
        XCTAssertTrue(spin { !registry.running.contains("codex") }, "désactivé : arrêté")
    }

    func testPanelOpensOnCodexWhenItNeedsYou() throws {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.tabEnabled = ["claude": true, "codex": true]
        let module = makeModule()
        let registry = ModuleRegistry(modules: [FakeModule(id: "claude"), module], prefs: prefs)
        XCTAssertTrue(spin { registry.enabled.count == 2 })
        XCTAssertEqual(registry.initialTab(claudeNeedsAttention: false), "claude")
        module.store.markWaiting(sessionId: CodexFixtures.session, tool: CodexTools.describe(name: "Bash", input: ["command": "ls"]),
                                 context: CodexFixtures.terminal, cwd: nil)
        XCTAssertEqual(registry.initialTab(claudeNeedsAttention: false), "codex")
        XCTAssertEqual(registry.initialTab(claudeNeedsAttention: true), "claude", "Claude garde la priorité")
        registry.setEnabled("codex", false)
        XCTAssertTrue(spin { registry.enabled.count == 1 })
        XCTAssertEqual(registry.initialTab(claudeNeedsAttention: false), "claude", "onglet désactivé : jamais ouvert")
    }

    func testStandardModulesIncludeCodexAfterClaude() {
        let ids = ModuleRegistry.standardModules(claude: ClaudeModule(
            store: SessionStore(), monitor: ClaudeMonitor(), tools: ToolsFeed(paths: LayoutTests.absentPaths),
            prefs: Preferences(defaults: makeEphemeralDefaults(self)))).map(\.id)
        XCTAssertEqual(Array(ids.prefix(2)), ["claude", "codex"])
    }

    /// Onglet désactivé : sessions oubliées, plus de minuterie, demandes rendues, plus d'état « dernier événement ».
    func testDisablingTheTabStopsEverything() {
        let module = makeModule(reply: true)
        send(module, CodexFixtures.event("Stop", ["last_assistant_message": "ok"]))
        var released: [Data?] = []
        module.approvals.hold(CodexFixtures.bash("ls", "PermissionRequest"), reply: { released.append($0) })
        XCTAssertEqual(module.approvals.requests.count, 1)
        XCTAssertTrue(module.store.isTicking)

        module.setTracking(false)
        XCTAssertTrue(module.store.sessions.isEmpty)
        XCTAssertFalse(module.store.isTicking)
        XCTAssertTrue(module.approvals.requests.isEmpty)
        XCTAssertEqual(released.count, 1)
        XCTAssertNil(released[0], "rendue sans décision : Codex pose sa question dans le terminal")
        XCTAssertNil(module.lastEventAt)
        XCTAssertNil(module.ears)
    }

    func testDebugInfoListsIdsAndPhasesOnly() throws {
        let module = makeModule()
        send(module, CodexFixtures.event("UserPromptSubmit", ["prompt": "secret du prompt"]))
        let info = module.debugInfo
        XCTAssertEqual(info["indicator"] as? String, "working")
        XCTAssertEqual(info["timer"] as? Bool, false)
        let text = String(describing: info)
        XCTAssertFalse(text.contains("secret du prompt"), "/state ne contient pas le texte des prompts")
    }

    // MARK: - Assistant de premier lancement

    func testSetupAssistantOffersCodexOnlyWhenDetectedOrEnabled() {
        let order = ["claude", "codex", "media"]
        func offered(detected: Bool, enabled: Set<String>) -> [String] {
            SetupChoices(order: order, claudeDetected: true, codexDetected: detected, isEnabled: { enabled.contains($0) },
                         openTrigger: .hover, toggleHotKey: .none, launchAtLogin: false, installHooks: false).offered
        }
        XCTAssertEqual(offered(detected: false, enabled: ["media"]), ["claude", "media"], "Codex absent : pas proposé")
        XCTAssertEqual(offered(detected: true, enabled: ["media"]), ["claude", "codex", "media"])
        XCTAssertEqual(offered(detected: false, enabled: ["codex"]), ["claude", "codex", "media"],
                       "assistant relancé avec l'onglet déjà activé")
        XCTAssertFalse(SetupTab.usage(of: "codex").isEmpty, "une ligne d'usage par onglet")
        XCTAssertEqual(NotchProfile.codexId, "codex")
        XCTAssertTrue(NotchProfile.agentsOnThisMac().isEmpty, "jamais le vrai Mac sous XCTest : ni Claude ni Codex")
    }
}
