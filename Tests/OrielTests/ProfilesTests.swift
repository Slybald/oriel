import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Profils (développeur, étudiant, créatif, minimal) : la logique pure, leur écriture dans les réglages, la première
/// étape de l'assistant et la feuille de Réglages › Général. Aucune fenêtre, rien d'écrit hors des réglages jetables.
final class ProfilesTests: XCTestCase {
    private static let ids = ["claude", "media", "quicksettings", "shelf", "clipboard", "timer", "notes"]
    /// Après la fusion du module Codex : il vient juste après Claude.
    private static let idsWithCodex = ["claude", "codex", "media", "quicksettings", "shelf", "clipboard", "timer", "notes"]

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private func makeRegistry(_ ids: [String] = ProfilesTests.ids, defaults: UserDefaults? = nil)
        -> (ModuleRegistry, Preferences) {
        let prefs = Preferences(defaults: defaults ?? makeEphemeralDefaults(self))
        return (ModuleRegistry(modules: ids.map { FakeModule(id: $0) }, prefs: prefs), prefs)
    }

    // MARK: - Définition des profils

    func testEachProfileHasItsOwnNonEmptyTabsWithoutDuplicates() {
        let known = Set(Self.idsWithCodex + ["agenda"])
        var seen = Set<[String]>()
        for profile in NotchProfile.allCases {
            XCTAssertFalse(profile.tabs.isEmpty, "\(profile)")
            XCTAssertEqual(Set(profile.tabs).count, profile.tabs.count, "doublon dans \(profile)")
            XCTAssertTrue(Set(profile.tabs).isSubset(of: known), "onglet inconnu dans \(profile)")
            XCTAssertTrue(seen.insert(profile.tabs).inserted, "deux profils identiques")
            XCTAssertFalse(profile.title.isEmpty)
            XCTAssertFalse(profile.symbol.isEmpty)
        }
    }

    func testProfilesAsDocumented() {
        XCTAssertEqual(NotchProfile.developer.tabs, ["claude", "codex", "clipboard", "timer", "notes"])
        XCTAssertEqual(NotchProfile.student.tabs, ["agenda", "media", "timer", "notes", "quicksettings"])
        XCTAssertEqual(NotchProfile.creative.tabs, ["media", "shelf", "clipboard"])
        XCTAssertEqual(NotchProfile.minimal.tabs, ["media", "quicksettings"])
        XCTAssertEqual(NotchProfile.allCases.map { $0.openTrigger }, [.hover, .click, .hover, .click])
        XCTAssertEqual(NotchProfile.allCases.map { $0.showEars }, [true, true, true, false])
    }

    // MARK: - Onglets proposés

    func testShownKeepsTheProfileOrderAndIgnoresWhatTheAppDoesNotHave() {
        // Pas de module Codex dans l'app : l'identifiant est ignoré.
        XCTAssertEqual(NotchProfile.developer.shown(offered: Self.ids),
                       ["claude", "clipboard", "timer", "notes"])
        XCTAssertEqual(NotchProfile.developer.shown(offered: Self.idsWithCodex),
                       ["claude", "codex", "clipboard", "timer", "notes"])
        XCTAssertEqual(NotchProfile.student.shown(offered: Self.ids.reversed()),
                       ["media", "timer", "notes", "quicksettings"], "l'ordre du profil, pas celui des réglages")
    }

    func testShownIsNeverEmpty() {
        XCTAssertEqual(NotchProfile.minimal.shown(offered: ["shelf", "notes"]), ["shelf"])
        XCTAssertEqual(NotchProfile.minimal.shown(offered: []), [])
    }

    func testAgentsAreOfferedOnlyIfDetectedOrAlreadyOn() {
        let order = Self.idsWithCodex
        XCTAssertEqual(NotchProfile.offered(order: order, detected: [], isEnabled: { _ in false }),
                       ["media", "quicksettings", "shelf", "clipboard", "timer", "notes"])
        XCTAssertEqual(Array(NotchProfile.offered(order: order, detected: ["claude"], isEnabled: { _ in false }).prefix(2)),
                       ["claude", "media"])
        XCTAssertEqual(Array(NotchProfile.offered(order: order, detected: [], isEnabled: { $0 == "codex" }).prefix(2)),
                       ["codex", "media"], "déjà activé : on le garde")
        // Les profils ne proposent donc jamais Claude ni Codex sans l'outil.
        let offered = NotchProfile.offered(order: order, detected: [], isEnabled: { _ in false })
        XCTAssertEqual(NotchProfile.developer.shown(offered: offered), ["clipboard", "timer", "notes"])
    }

    func testArrangePutsTheProfileTabsFirst() {
        XCTAssertEqual(NotchProfile.creative.arrange(["notes", "clipboard", "media", "timer"]),
                       ["media", "clipboard", "notes", "timer"])
    }

    // MARK: - Plan

    func testPlanShowsTheProfileAndHidesTheRest() {
        let plan = ProfilePlan(.creative, current: Self.ids, offered: Self.ids)
        XCTAssertEqual(plan.shown, ["media", "shelf", "clipboard"])
        XCTAssertEqual(plan.hidden, ["claude", "quicksettings", "timer", "notes"])
        XCTAssertEqual(plan.order, ["media", "shelf", "clipboard", "claude", "quicksettings", "timer", "notes"],
                       "les masqués gardent leur ordre")
        XCTAssertEqual(plan.newlyHidden(enabled: ["media", "timer", "notes"]), ["timer", "notes"])
    }

    func testPlanLeavesAnUndetectedAgentAlone() {
        let offered = Self.ids.filter { $0 != "claude" }
        let plan = ProfilePlan(.developer, current: Self.ids, offered: offered)
        XCTAssertEqual(plan.shown, ["clipboard", "timer", "notes"])
        XCTAssertFalse(plan.hidden.contains("claude"), "Claude n'est pas proposé : son choix n'est pas touché")
        XCTAssertFalse(plan.shown.contains("claude"))
    }

    func testApplyWritesOnlyTabsOrderOpeningAndEars() {
        let defaults = makeEphemeralDefaults(self)
        let (registry, prefs) = makeRegistry(defaults: defaults)
        prefs.hapticFeedback = false
        prefs.accentHex = "4C8DFF"
        prefs.visibility = .duringActivity
        prefs.toggleHotKey = .controlOptionSpace
        settle()
        let before = defaults.dictionaryRepresentation()

        ProfilePlan(.minimal, current: registry.ordered.map { $0.id }, offered: Self.ids).apply(to: registry, prefs: prefs)
        settle()

        let after = defaults.dictionaryRepresentation()
        let changed = Set(after.keys.filter { !(before[$0] as AnyObject? ?? NSNull()).isEqual(after[$0]) })
        XCTAssertTrue(changed.isSubset(of: ["tabs.order", "tabs.enabled", "hover.trigger", "appearance.showEars"]),
                      "\(changed)")
        XCTAssertEqual(registry.enabled.map { $0.id }, ["media", "quicksettings"])
        XCTAssertEqual(prefs.openTrigger, .click)
        XCTAssertFalse(prefs.showEars)
        XCTAssertFalse(prefs.hapticFeedback)
        XCTAssertEqual(prefs.visibility, .duringActivity)
        XCTAssertEqual(prefs.toggleHotKey, .controlOptionSpace)
        XCTAssertEqual(prefs.accentHex, "4C8DFF")
    }

    func testApplyStopsHiddenModulesWithoutTouchingAnythingElse() throws {
        let modules = Self.ids.map { FakeModule(id: $0) }
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let registry = ModuleRegistry(modules: modules, prefs: prefs)
        registry.setPanelOpen(true)
        settle()
        XCTAssertTrue(try XCTUnwrap(modules.first { $0.id == "notes" }).isRunning)

        ProfilePlan(.minimal, current: Self.ids, offered: Self.ids).apply(to: registry, prefs: prefs)
        settle()

        XCTAssertFalse(try XCTUnwrap(modules.first { $0.id == "notes" }).isRunning, "masqué : arrêté, pas supprimé")
        XCTAssertTrue(try XCTUnwrap(modules.first { $0.id == "media" }).isRunning)
    }

    // MARK: - Profil actuel

    func testMatchingFindsTheProfileWhoseTabsAreOn() {
        let known = Self.ids
        for profile in NotchProfile.allCases {
            // Avec ou sans Claude : le profil se reconnaît.
            for agents in [true, false] {
                let offered = Self.ids.filter { agents || $0 != "claude" }
                let shown = ProfilePlan(profile, current: Self.ids, offered: offered).shown
                XCTAssertEqual(NotchProfile.matching(enabled: shown, known: known), profile, "\(profile) \(agents)")
            }
        }
        XCTAssertEqual(NotchProfile.matching(enabled: ["notes", "timer", "media", "quicksettings"], known: Self.ids),
                       .student, "l'ordre ne compte pas")
    }

    func testMatchingIsNilForACustomSet() {
        XCTAssertNil(NotchProfile.matching(enabled: Self.ids, known: Self.ids), "tout activé : personnalisé")
        XCTAssertNil(NotchProfile.matching(enabled: ["media", "shelf"], known: Self.ids))
        XCTAssertNil(NotchProfile.matching(enabled: ["media", "quicksettings", "notes"], known: Self.ids))
        XCTAssertNil(NotchProfile.matching(enabled: [], known: Self.ids))
        XCTAssertNil(NotchProfile.matching(enabled: ["claude"], known: Self.ids), "Claude seul n'est pas « Développeur »")
    }

    // MARK: - Feuille « Changer de profil »

    private func sheet(_ registry: ModuleRegistry, _ prefs: Preferences, detected: Set<String> = ["claude"],
                       closes: Box = Box()) -> ProfileChangeModel {
        ProfileChangeModel(registry: registry, prefs: prefs, detected: detected, close: { closes.count += 1 })
    }

    private final class Box { var count = 0 }

    func testSheetStartsWithNoChoiceAndCancelWritesNothing() {
        let defaults = makeEphemeralDefaults(self)
        let (registry, prefs) = makeRegistry(defaults: defaults)
        settle()
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let closes = Box()
        let model = sheet(registry, prefs, closes: closes)
        XCTAssertNil(model.selected)
        XCTAssertNil(model.plan)
        XCTAssertNil(model.current, "tout est activé : personnalisé")
        model.selected = .student
        XCTAssertNotNil(model.plan)
        model.cancel()
        settle()
        XCTAssertEqual(closes.count, 1)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before, "rien n'est écrit avant « Appliquer »")
        XCTAssertEqual(registry.enabled.map { $0.id }, Self.ids)
    }

    func testSheetApplyChangesProfileAndCloses() throws {
        let (registry, prefs) = makeRegistry()
        let closes = Box()
        let model = sheet(registry, prefs, closes: closes)
        model.selected = .creative
        XCTAssertEqual(model.titles(model.plan?.shown ?? []), ["media", "shelf", "clipboard"])
        XCTAssertEqual(Set(model.hiddenTitles(try XCTUnwrap(model.plan))), ["claude", "quicksettings", "timer", "notes"])
        model.apply()
        settle()
        XCTAssertEqual(closes.count, 1)
        XCTAssertEqual(registry.enabled.map { $0.id }, ["media", "shelf", "clipboard"])
        XCTAssertEqual(prefs.openTrigger, .hover)
        XCTAssertTrue(prefs.showEars)

        // Et la fois suivante, le profil se reconnaît, puis on en change encore.
        let again = sheet(registry, prefs)
        XCTAssertEqual(again.current, .creative)
        again.selected = .minimal
        again.apply()
        settle()
        XCTAssertEqual(registry.enabled.map { $0.id }, ["media", "quicksettings"])
        XCTAssertEqual(prefs.openTrigger, .click)
        XCTAssertFalse(prefs.showEars)
    }

    func testSheetWithoutClaudeDetectedDoesNotTurnItOn() {
        let (registry, prefs) = makeRegistry()
        prefs.tabEnabled["claude"] = false
        settle()
        let model = sheet(registry, prefs, detected: [])
        model.selected = .developer
        XCTAssertEqual(model.plan?.shown, ["clipboard", "timer", "notes"])
        model.apply()
        settle()
        XCTAssertEqual(prefs.tabEnabled["claude"], false, "pas détecté : on n'y touche pas")
        XCTAssertEqual(registry.enabled.map { $0.id }, ["clipboard", "timer", "notes"])

        // Détecté : le profil le propose et l'active, sans jamais poser de hooks (rien d'autre n'est écrit).
        let detected = sheet(registry, prefs, detected: ["claude"])
        detected.selected = .developer
        detected.apply()
        settle()
        XCTAssertEqual(registry.enabled.map { $0.id }, ["claude", "clipboard", "timer", "notes"])
    }

    func testSheetKeepsAnAgentThatIsAlreadyOnEvenIfNotDetected() {
        let (registry, prefs) = makeRegistry()
        let model = sheet(registry, prefs, detected: [])
        model.selected = .developer
        XCTAssertEqual(model.plan?.shown, ["claude", "clipboard", "timer", "notes"])
    }

    // MARK: - Assistant : première étape

    private final class Rig {
        let prefs: Preferences
        let registry: ModuleRegistry
        let model: SetupAssistantModel

        init(_ test: XCTestCase, claudeDetected: Bool = true) {
            prefs = Preferences(defaults: makeEphemeralDefaults(test))
            prefs.decideClaudeTab(claudeCodePresent: { claudeDetected })
            registry = ModuleRegistry(modules: ProfilesTests.ids.map { FakeModule(id: $0) }, prefs: prefs)
            model = SetupAssistantModel(
                registry: registry, prefs: prefs, claudeDetected: claudeDetected, hookStatus: .notInstalled,
                firstRun: true, inApplications: true, installHooks: { nil }, applyLaunchAtLogin: { _ in },
                close: {})
        }

        func apply() {
            model.step = .behavior
            model.next()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testNoProfileChangesNothingByItself() {
        let rig = Rig(self)
        XCTAssertNil(rig.model.choices.profile)
        XCTAssertEqual(rig.model.choices.selected, Self.ids)
        rig.apply()
        XCTAssertEqual(rig.prefs.tabOrder, [], "l'ordre n'est écrit qu'avec un profil")
        XCTAssertTrue(rig.prefs.showEars)
        XCTAssertEqual(rig.prefs.openTrigger, .hover)
    }

    func testChoosingAProfileTicksItsTabsAndSetsTheOpening() {
        let rig = Rig(self)
        rig.model.choose(.student)
        XCTAssertEqual(rig.model.choices.profile, .student)
        XCTAssertEqual(rig.model.choices.selected, ["media", "timer", "notes", "quicksettings"])
        XCTAssertEqual(rig.model.choices.openTrigger, .click)
        XCTAssertEqual(rig.model.selectedTabs.map { $0.id }, ["media", "timer", "notes", "quicksettings"])
        XCTAssertEqual(rig.model.step, .welcome)
    }

    func testNothingIsWrittenBeforeApply() {
        let rig = Rig(self)
        rig.model.choose(.minimal)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(rig.registry.enabled.map { $0.id }, Self.ids)
        XCTAssertTrue(rig.prefs.showEars)
        rig.model.skip()
        XCTAssertEqual(rig.registry.enabled.map { $0.id }, Self.ids)
        XCTAssertEqual(rig.prefs.tabOrder, [])
    }

    func testDeveloperWithClaudeDetectedTicksClaudeButInstallsNoHooks() {
        let rig = Rig(self)
        rig.model.choose(.developer)
        XCTAssertEqual(rig.model.choices.selected, ["claude", "clipboard", "timer", "notes"])
        XCTAssertFalse(rig.model.choices.installHooks, "un profil ne pose jamais les hooks")
        rig.apply()
        XCTAssertNil(rig.model.hooksOutcome)
        XCTAssertEqual(rig.registry.enabled.map { $0.id }, ["claude", "clipboard", "timer", "notes"])
        XCTAssertEqual(rig.prefs.openTrigger, .hover)
    }

    func testDeveloperWithoutClaudeCodeOffersNeitherClaudeNorCodex() {
        let rig = Rig(self, claudeDetected: false)
        rig.model.choose(.developer)
        XCTAssertEqual(rig.model.choices.selected, ["clipboard", "timer", "notes"])
        XCTAssertFalse(rig.model.choices.set("claude", true))
        XCTAssertEqual(rig.model.summary(of: .developer), "clipboard, timer, notes")
        rig.apply()
        XCTAssertEqual(rig.prefs.tabEnabled["claude"], false, "la détection reste ce qu'elle était")
        XCTAssertEqual(rig.registry.enabled.map { $0.id }, ["clipboard", "timer", "notes"])
    }

    func testApplyWritesTheProfileOrderAndEarsAfterTheUsersAdjustments() {
        let rig = Rig(self)
        rig.model.choose(.student)
        rig.model.choices.set("notes", false)
        rig.model.choices.set("shelf", true)
        rig.model.choices.openTrigger = .hover
        XCTAssertEqual(rig.model.choices.selected, ["media", "timer", "quicksettings", "shelf"])
        rig.apply()
        XCTAssertEqual(rig.registry.enabled.map { $0.id }, ["media", "timer", "quicksettings", "shelf"])
        XCTAssertEqual(rig.prefs.openTrigger, .hover, "le choix fait à l'étape Comportement l'emporte")
        XCTAssertTrue(rig.prefs.showEars)

        let minimal = Rig(self)
        minimal.model.choose(.minimal)
        minimal.apply()
        XCTAssertFalse(minimal.prefs.showEars)
        XCTAssertEqual(minimal.registry.enabled.map { $0.id }, ["media", "quicksettings"])
    }

    func testChoosingAnotherProfileReplacesTheFirst() {
        let rig = Rig(self)
        rig.model.choose(.minimal)
        rig.model.choose(.creative)
        XCTAssertEqual(rig.model.choices.profile, .creative)
        XCTAssertEqual(rig.model.choices.selected, ["media", "shelf", "clipboard"])
        XCTAssertEqual(rig.model.choices.openTrigger, .hover)
    }
}

/// Rendus PNG de la première étape de l'assistant et de Réglages › Général. Ne fait rien sans `ORIEL_SNAPSHOT_DIR`.
final class ProfilesSnapshotTests: XCTestCase {
    private func assistant(claude: Bool, profile: NotchProfile?, inApplications: Bool = true) -> SetupAssistantModel {
        let notch = NotchHarness(self)
        notch.prefs.decideClaudeTab(claudeCodePresent: { claude })
        let model = SetupAssistantModel(
            registry: notch.registry, prefs: notch.prefs, claudeDetected: claude, hookStatus: .notInstalled,
            firstRun: true, inApplications: inApplications, installHooks: { nil }, applyLaunchAtLogin: { _ in },
            close: {})
        if let profile { model.choose(profile) }
        return model
    }

    private func render(_ model: SetupAssistantModel, _ name: String, _ dir: URL) throws {
        try TimerNotesSnapshot.render(SetupAssistantView(model: model).padding(.top, 32).background(Color.black), name, dir,
                                      size: CGSize(width: SetupAssistantView.size.width,
                                                   height: SetupAssistantView.size.height + 32))
    }

    func testRenderAssistantWelcome() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        try render(assistant(claude: true, profile: nil), "profile-1-welcome-none", dir)
        try render(assistant(claude: true, profile: .developer), "profile-1-welcome-developer", dir)
        try render(assistant(claude: true, profile: .student), "profile-1-welcome-student", dir)
        try render(assistant(claude: false, profile: .developer), "profile-1-welcome-developer-no-claude", dir)
        try render(assistant(claude: true, profile: .minimal, inApplications: false),
                   "profile-1-welcome-minimal-not-in-applications", dir)
        // L'étape suivante part du profil.
        let creative = assistant(claude: true, profile: .creative)
        creative.step = .tabs
        try render(creative, "profile-2-tabs-creative", dir)
    }

    func testRenderSettingsAndSheet() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let notch = NotchHarness(self)
        func general(_ name: String) throws {
            let view = SettingsView(prefs: notch.prefs, registry: notch.registry, updater: Updater(), selection: .general)
            try TimerNotesSnapshot.render(view, name, dir, size: SettingsWindow.size, background: nil)
        }
        try general("profile-settings-general-custom")

        func sheet(_ profile: NotchProfile?, _ name: String) throws {
            let model = ProfileChangeModel(registry: notch.registry, prefs: notch.prefs, detected: ["claude"], close: {})
            model.selected = profile
            try TimerNotesSnapshot.render(ProfileChangeView(model: model), name, dir, size: ProfileChangeView.size)
        }
        try sheet(nil, "profile-sheet-none")
        try sheet(.student, "profile-sheet-student")
        try sheet(.developer, "profile-sheet-developer")

        // Un profil appliqué : le volet le nomme, la feuille le marque « Actuel ».
        ProfilePlan(.creative, current: notch.registry.ordered.map { $0.id },
                    offered: notch.registry.ordered.map { $0.id }).apply(to: notch.registry, prefs: notch.prefs)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try general("profile-settings-general-creative")
        try sheet(.minimal, "profile-sheet-from-creative")
    }
}
