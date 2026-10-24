import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Assistant de configuration : les choix, les étapes et leur écriture dans les réglages. Aucune fenêtre, rien
/// d'écrit hors des réglages jetables : « Lancer à l'ouverture de session » et les hooks sont des fermetures espionnes.
final class SetupAssistantTests: XCTestCase {
    /// Les onglets proposés par défaut, puis ceux qui sont désactivés tant que l'utilisateur ne les choisit pas.
    private static let defaultIds = ["claude", "media", "agenda", "quicksettings", "shelf", "clipboard", "timer", "notes"]
    private static let optionalIds = ["messages", "mail"]
    private static let ids = defaultIds + optionalIds

    /// Un assistant sur un registre factice, avec ce que ses fermetures ont reçu.
    private final class Rig {
        let prefs: Preferences
        let registry: ModuleRegistry
        var model: SetupAssistantModel!
        var installs = 0
        var installError: String?
        var logins: [Bool] = []
        var closes = 0

        init(_ test: XCTestCase, claudeDetected: Bool = true, hookStatus: HookInstaller.Status = .notInstalled,
             firstRun: Bool = true, inApplications: Bool = true, prepare: (Preferences) -> Void = { _ in }) {
            prefs = Preferences(defaults: makeEphemeralDefaults(test))
            // Comme AppCore.start : l'onglet Claude est décidé par la détection avant l'assistant.
            prefs.decideClaudeTab(claudeCodePresent: { claudeDetected })
            prepare(prefs)
            registry = ModuleRegistry(modules: SetupAssistantTests.ids.map {
                FakeModule(id: $0, enabledByDefault: !SetupAssistantTests.optionalIds.contains($0))
            }, prefs: prefs)
            model = SetupAssistantModel(
                registry: registry, prefs: prefs, claudeDetected: claudeDetected, hookStatus: hookStatus,
                firstRun: firstRun, inApplications: inApplications,
                installHooks: { [unowned self] in
                    installs += 1
                    return installError
                },
                applyLaunchAtLogin: { [unowned self] in logins.append($0) },
                close: { [unowned self] in closes += 1 })
        }

        /// Les réglages sont relus au tour de boucle suivant.
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        func goToEnd() {
            model.step = .behavior
            model.next()
        }
    }

    // MARK: - Choix par défaut

    func testDefaultsWithClaudeCodeDetected() {
        let rig = Rig(self)
        let choices = rig.model.choices
        XCTAssertEqual(choices.selected, Self.defaultIds, "les onglets activés par défaut, dans l'ordre")
        XCTAssertEqual(rig.model.tabs.map { $0.id }, Self.ids)
        XCTAssertTrue(rig.model.claudeOffered)
        XCTAssertEqual(choices.openTrigger, .hover)
        XCTAssertEqual(choices.toggleHotKey, .none, "raccourci facultatif : aucun au départ")
        XCTAssertTrue(choices.launchAtLogin, "comme l'ancienne bienvenue : coché au premier lancement")
        XCTAssertFalse(choices.installHooks, "les hooks ne sont jamais posés sans un clic")
        XCTAssertEqual(rig.model.hooksOffer, .install)
        XCTAssertEqual(rig.model.step, .welcome)
    }

    func testClaudeIsNotOfferedWithoutClaudeCode() {
        let rig = Rig(self, claudeDetected: false)
        XCTAssertFalse(rig.model.claudeOffered)
        XCTAssertEqual(rig.model.hooksOffer, .none)
        XCTAssertEqual(rig.model.tabs.map { $0.id }, Array(Self.ids.dropFirst()), "aucune carte Claude")
        XCTAssertEqual(rig.model.choices.selected, Array(Self.defaultIds.dropFirst()))
        XCTAssertFalse(rig.model.choices.set("claude", true), "pas proposé : on ne le coche pas en douce")

        // Même case des hooks forcée : rien n'est installé sans onglet Claude.
        rig.model.choices.installHooks = true
        rig.goToEnd()
        rig.settle()
        XCTAssertEqual(rig.installs, 0)
        XCTAssertNil(rig.model.hooksOutcome)
        XCTAssertEqual(rig.prefs.tabEnabled["claude"], false, "la décision de la détection n'est pas touchée")
        XCTAssertFalse(rig.registry.isClaudeEnabled)
    }

    func testClaudeAlreadyOnIsOfferedEvenIfNotDetected() {
        let rig = Rig(self, claudeDetected: false, firstRun: false, prepare: { $0.tabEnabled["claude"] = true })
        XCTAssertTrue(rig.model.claudeOffered, "relancé : un onglet déjà activé ne disparaît pas sans le dire")
        XCTAssertTrue(rig.model.choices.isOn("claude"))
    }

    func testRerunStartsFromCurrentSettings() {
        let rig = Rig(self, firstRun: false, inApplications: false) { prefs in
            prefs.tabEnabled = ["media": false, "timer": false]
            prefs.tabOrder = ["notes", "claude"]
            prefs.openTrigger = .click
            prefs.toggleHotKey = .controlCommandN
        }
        XCTAssertEqual(rig.model.tabs.map { $0.id },
                       ["notes", "claude", "media", "agenda", "quicksettings", "shelf", "clipboard", "timer", "messages", "mail"],
                       "les cartes suivent l'ordre des réglages")
        XCTAssertEqual(rig.model.choices.selected, ["notes", "claude", "agenda", "quicksettings", "shelf", "clipboard"])
        XCTAssertEqual(rig.model.choices.openTrigger, .click)
        XCTAssertEqual(rig.model.choices.toggleHotKey, .controlCommandN)
        XCTAssertFalse(rig.model.choices.launchAtLogin, "hors Applications : jamais coché")
    }

    func testHooksOfferFollowsStatus() {
        func offer(_ status: HookInstaller.Status, claude: Bool = true) -> SetupHooksOffer {
            SetupHooksOffer(claudeOffered: claude, status: status)
        }
        XCTAssertEqual(offer(.notInstalled), .install)
        XCTAssertEqual(offer(.unreadable("x")), .install, "l'erreur s'affichera à l'installation")
        XCTAssertEqual(offer(.installed), .installed)
        XCTAssertEqual(offer(.outdated), .update)
        XCTAssertEqual(offer(.scriptOutdated), .update)
        XCTAssertEqual(offer(.installed, claude: false), .none)
        XCTAssertFalse(SetupHooksOffer.install.checkedByDefault, "première installation : jamais cochée d'office")
        XCTAssertTrue(SetupHooksOffer.update.checkedByDefault, "mise à jour : l'accord a déjà été donné")
        XCTAssertFalse(SetupHooksOffer.installed.canInstall)
        XCTAssertTrue(Rig(self, hookStatus: .outdated).model.choices.installHooks)
    }

    // MARK: - Au moins un onglet

    func testLastTabCannotBeTurnedOff() {
        let rig = Rig(self)
        var choices = rig.model.choices
        for id in Self.ids where id != "notes" { XCTAssertTrue(choices.set(id, false), id) }
        XCTAssertEqual(choices.selected, ["notes"])
        XCTAssertFalse(choices.set("notes", false), "le dernier reste")
        XCTAssertEqual(choices.selected, ["notes"])
        XCTAssertTrue(choices.set("notes", true), "recocher ce qui l'est déjà ne casse rien")
        XCTAssertTrue(choices.set("media", false), "déjà décoché")
        XCTAssertTrue(choices.set("media", true))
        XCTAssertTrue(choices.set("notes", false), "un autre est coché : on peut décocher celui-ci")
        XCTAssertEqual(choices.selected, ["media"])
        XCTAssertFalse(choices.set("inconnu", true), "onglet non proposé")
    }

    func testEmptySettingsStartWithOneTab() {
        let rig = Rig(self, firstRun: false) { prefs in
            prefs.tabEnabled = Dictionary(uniqueKeysWithValues: SetupAssistantTests.ids.map { ($0, false) })
        }
        XCTAssertEqual(rig.model.choices.selected.count, 1, "jamais de barre vide")
    }

    // MARK: - Écriture

    func testApplyWritesTabsThroughTheRegistry() {
        let rig = Rig(self)
        rig.model.choices.set("media", false)
        rig.model.choices.set("notes", false)
        rig.model.choices.openTrigger = .click
        rig.model.choices.toggleHotKey = .optionCommandJ
        rig.model.choices.launchAtLogin = false
        XCTAssertEqual(rig.prefs.tabEnabled, ["claude": true], "rien n'est écrit avant « Appliquer »")

        rig.goToEnd()
        rig.settle()
        XCTAssertEqual(rig.model.step, .done)
        XCTAssertEqual(rig.prefs.tabEnabled, ["claude": true, "media": false, "agenda": true, "quicksettings": true, "shelf": true,
                                             "clipboard": true, "timer": true, "notes": false, "messages": false, "mail": false])
        XCTAssertEqual(rig.registry.enabled.map { $0.id }, ["claude", "agenda", "quicksettings", "shelf", "clipboard", "timer"])
        XCTAssertEqual(rig.prefs.openTrigger, .click)
        XCTAssertEqual(rig.prefs.toggleHotKey, .optionCommandJ)
        XCTAssertEqual(rig.logins, [false])
        XCTAssertTrue(rig.prefs.tabOrder.isEmpty, "l'ordre reste celui des réglages")
        XCTAssertEqual(rig.model.selectedTabs.map { $0.id }, ["claude", "agenda", "quicksettings", "shelf", "clipboard", "timer"])
    }

    func testClaudeTabCanBeTurnedOff() {
        let rig = Rig(self)
        rig.model.choices.set("claude", false)
        rig.model.choices.installHooks = true
        rig.goToEnd()
        rig.settle()
        XCTAssertFalse(rig.registry.isClaudeEnabled)
        XCTAssertEqual(rig.prefs.tabEnabled["claude"], false)
        XCTAssertEqual(rig.installs, 0, "pas d'onglet Claude, pas de hooks")
    }

    func testSkipChangesNothing() {
        let rig = Rig(self)
        rig.model.choices.set("media", false)
        rig.model.choices.openTrigger = .click
        rig.model.choices.installHooks = true
        rig.model.skip()
        rig.settle()
        XCTAssertEqual(rig.closes, 1)
        XCTAssertEqual(rig.prefs.tabEnabled, ["claude": true], "les onglets restent ceux d'avant")
        XCTAssertEqual(rig.prefs.openTrigger, .hover)
        XCTAssertEqual(rig.prefs.toggleHotKey, .none)
        XCTAssertTrue(rig.logins.isEmpty)
        XCTAssertEqual(rig.installs, 0)
    }

    // MARK: - Étapes et hooks

    func testStepsForwardAndBack() {
        let rig = Rig(self)
        let model = rig.model!
        XCTAssertFalse(model.canGoBack)
        model.back()
        XCTAssertEqual(model.step, .welcome)
        model.next()
        XCTAssertEqual(model.step, .tabs)
        XCTAssertTrue(model.canGoBack)
        model.next()
        XCTAssertEqual(model.step, .behavior)
        model.back()
        XCTAssertEqual(model.step, .tabs)
        model.next()
        model.next()
        XCTAssertEqual(model.step, .done)
        XCTAssertFalse(model.canGoBack, "appliqué : pas de retour")
        model.back()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(rig.closes, 0)
        model.next()
        XCTAssertEqual(rig.closes, 1, "« C'est parti » ferme")
    }

    func testHooksAreInstalledOnlyWhenAskedAndReportedAtTheEnd() {
        let none = Rig(self)
        none.goToEnd()
        XCTAssertEqual(none.installs, 0, "case non cochée : rien")
        XCTAssertNil(none.model.hooksOutcome)

        let asked = Rig(self)
        asked.model.choices.installHooks = true
        asked.goToEnd()
        XCTAssertEqual(asked.installs, 1)
        XCTAssertEqual(asked.model.hooksOutcome, .success)

        let failing = Rig(self)
        failing.installError = "settings.json illisible"
        failing.model.choices.installHooks = true
        failing.goToEnd()
        failing.settle()
        XCTAssertEqual(failing.model.hooksOutcome, .failure("settings.json illisible"))
        XCTAssertEqual(failing.model.step, .done, "l'échec des hooks n'annule pas le reste")
        XCTAssertEqual(failing.prefs.tabEnabled["media"], true)

        let installed = Rig(self, hookStatus: .installed)
        installed.model.choices.installHooks = true
        installed.goToEnd()
        XCTAssertEqual(installed.installs, 0, "déjà posés : rien à écrire")
    }

    // MARK: - Contenu

    /// Chaque onglet de l'app a sa ligne d'usage dans l'assistant : un nouveau module doit en ajouter une.
    func testEveryStandardModuleHasAUsageLine() {
        let notch = NotchHarness(self)
        var lines = Set<String>()
        for module in notch.registry.modules {
            let usage = SetupTab.usage(of: module.id)
            XCTAssertFalse(usage.isEmpty, "ligne d'usage manquante pour \(module.id) (SetupTab.usage)")
            XCTAssertTrue(lines.insert(usage).inserted, "ligne d'usage en double pour \(module.id)")
            XCTAssertFalse(SetupTab(module).title.isEmpty)
        }
        // Codex a sa propre règle de proposition (détecté ou déjà activé) : testée dans CodexModuleTests.
        XCTAssertEqual(SetupAssistantTests.ids, notch.registry.modules.map { $0.id }.filter { $0 != "codex" },
                       "la liste des tests suit l'app")
        XCTAssertTrue(notch.registry.modules.contains { $0.id == "codex" })
    }

    /// La vraie fenêtre (jamais affichée ici) garde la même taille à chaque étape et tient sur un petit écran.
    func testWindowKeepsItsSizeAcrossSteps() {
        _ = NSApplication.shared
        let rig = Rig(self)
        let controller = OnboardingWindowController(rootView: SetupAssistantView(model: rig.model))
        let window = try! XCTUnwrap(controller.window)
        addTeardownBlock { window.close() }
        // SwiftUI donne sa taille préférée à la fenêtre au tour de boucle suivant.
        rig.settle()
        let first = window.frame.size
        XCTAssertEqual(first.width, SetupAssistantView.size.width, accuracy: 1)
        XCTAssertLessThanOrEqual(first.height, 780, "tient sur un écran de 800 pt avec la barre des menus")
        for step in SetupAssistantModel.Step.allCases {
            rig.model.step = step
            rig.settle()
            XCTAssertEqual(window.frame.size.height, first.height, accuracy: 1, "\(step)")
        }
    }

    /// Premier lancement : le drapeau tombe même sans fenêtre à montrer ; ensuite, plus rien (voir aussi
    /// `OptionalClaudeTests.testLaunchWindow` pour toutes les combinaisons).
    func testFirstLaunchMarksTheAssistantAsShown() {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("oriel-no-config")
        let setup = HookSetup(installer: HookInstaller(configDirectory: config, bundledHook: nil))
        XCTAssertFalse(prefs.welcomeShown)
        // Pas de registre : la fenêtre n'est pas créée, seul le drapeau est posé.
        setup.showOnboardingIfNeeded(claudeEnabled: false, prefs: prefs, registry: nil)
        XCTAssertTrue(prefs.welcomeShown)
    }
}

/// Rendus PNG de chaque étape, avec et sans Claude Code. Ne fait rien sans `ORIEL_SNAPSHOT_DIR`.
final class SetupAssistantSnapshotTests: XCTestCase {
    private func model(_ claude: Bool, _ step: SetupAssistantModel.Step, inApplications: Bool = true,
                       hookStatus: HookInstaller.Status = .notInstalled, firstRun: Bool = true,
                       installError: String? = nil) -> SetupAssistantModel {
        let notch = NotchHarness(self)
        notch.prefs.decideClaudeTab(claudeCodePresent: { claude })
        return SetupAssistantModel(
            registry: notch.registry, prefs: notch.prefs, claudeDetected: claude, hookStatus: hookStatus,
            firstRun: firstRun, inApplications: inApplications, step: step,
            installHooks: { installError }, applyLaunchAtLogin: { _ in }, close: {})
    }

    private func render(_ model: SetupAssistantModel, _ name: String, _ dir: URL) throws {
        // 32 pt en haut : la place de la barre de titre transparente de la vraie fenêtre.
        try TimerNotesSnapshot.render(SetupAssistantView(model: model).padding(.top, 32).background(Color.black), name, dir,
                                      size: CGSize(width: SetupAssistantView.size.width,
                                                   height: SetupAssistantView.size.height + 32))
    }

    func testRenderEachStep() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let steps: [(SetupAssistantModel.Step, String)] = [(.welcome, "1-welcome"), (.tabs, "2-tabs"),
                                                          (.behavior, "3-behavior"), (.done, "4-done")]
        for (step, name) in steps {
            // Avec Claude Code : hooks proposés, cochés pour la capture de l'étape 2.
            let withClaude = model(true, step)
            withClaude.choices.installHooks = true
            withClaude.choices.openTrigger = .click
            withClaude.choices.toggleHotKey = .controlOptionSpace
            if step == .done { withClaude.step = .behavior; withClaude.next() }
            try render(withClaude, "setup-claude-\(name)", dir)

            // Sans Claude Code, app hors d'Applications : pas de carte Claude, la ligne qui l'explique.
            let without = model(false, step, inApplications: false)
            if step == .done { without.step = .behavior; without.next() }
            try render(without, "setup-no-claude-\(name)", dir)
        }

        // Cas limites : hooks décochés, un seul onglet, échec des hooks, hooks déjà posés (assistant relancé).
        try render(model(true, .tabs), "setup-claude-2-tabs-hooks-unchecked", dir)
        let single = model(false, .tabs)
        for tab in single.tabs.dropFirst() { single.choices.set(tab.id, false) }
        try render(single, "setup-no-claude-2-tabs-single", dir)
        try render(model(true, .tabs, hookStatus: .installed, firstRun: false), "setup-claude-2-tabs-hooks-installed", dir)
        let failed = model(true, .behavior, installError: "settings.json n'est pas un JSON valide.")
        failed.choices.installHooks = true
        failed.next()
        try render(failed, "setup-claude-4-done-hooks-failed", dir)
        let installed = model(true, .behavior)
        installed.choices.installHooks = true
        installed.next()
        try render(installed, "setup-claude-4-done-hooks-installed", dir)
    }
}
