import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Oriel

/// Mode édition des onglets dans la notch : règles pures, stockage partagé avec Réglages › Onglets, sorties du mode.
final class TabEditingTests: XCTestCase {
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: - Règles pures

    func testMoveKeepsHiddenTabsInTheirSlots() {
        // b masqué : a, c, d se redistribuent dans leurs cases, b ne bouge pas.
        let order = ["a", "b", "c", "d"]
        let shown = ["a", "c", "d"]
        XCTAssertEqual(TabEditing.move("d", to: 0, order: order, enabled: shown), ["d", "b", "a", "c"])
        XCTAssertEqual(TabEditing.move("a", to: 2, order: order, enabled: shown), ["c", "b", "d", "a"])
        XCTAssertEqual(TabEditing.move("c", to: 1, order: order, enabled: shown), order, "même place")
        XCTAssertEqual(TabEditing.move("a", to: 99, order: order, enabled: shown), ["c", "b", "d", "a"], "borné")
        XCTAssertEqual(TabEditing.move("a", to: -3, order: order, enabled: shown), order, "borné")
        XCTAssertEqual(TabEditing.move("b", to: 0, order: order, enabled: shown), order, "onglet masqué : rien")
    }

    func testLastShownTabCannotBeHidden() {
        XCTAssertTrue(TabEditing.canHide("a", enabled: ["a", "b"]))
        XCTAssertFalse(TabEditing.canHide("a", enabled: ["a"]), "dernier onglet")
        XCTAssertFalse(TabEditing.canHide("c", enabled: ["a", "b"]), "déjà masqué")
    }

    func testDropIndexAndShift() {
        let slot: CGFloat = 29
        XCTAssertEqual(TabEditing.dropIndex(from: 1, translation: 10, slot: slot, count: 4), 1, "moins d'une demi-case")
        XCTAssertEqual(TabEditing.dropIndex(from: 1, translation: 15, slot: slot, count: 4), 2)
        XCTAssertEqual(TabEditing.dropIndex(from: 1, translation: -40, slot: slot, count: 4), 0)
        XCTAssertEqual(TabEditing.dropIndex(from: 1, translation: 500, slot: slot, count: 4), 3, "borné à droite")
        XCTAssertEqual(TabEditing.dropIndex(from: 1, translation: -500, slot: slot, count: 4), 0, "borné à gauche")
        // L'onglet 1 glisse vers 3 : 2 et 3 reculent d'une case, 0 ne bouge pas.
        XCTAssertEqual((0..<4).map { TabEditing.shift($0, from: 1, to: 3) }, [0, 0, -1, -1])
        // L'onglet 3 glisse vers 0 : 0, 1, 2 avancent.
        XCTAssertEqual((0..<4).map { TabEditing.shift($0, from: 3, to: 0) }, [1, 1, 1, 0])
        XCTAssertEqual((0..<4).map { TabEditing.shift($0, from: 2, to: 2) }, [0, 0, 0, 0])
    }

    // MARK: - Stockage partagé avec les réglages

    private func registry(_ ids: [String] = ["a", "b", "c", "d"]) -> (ModuleRegistry, Preferences, [FakeModule]) {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let modules = ids.map { FakeModule(id: $0) }
        return (ModuleRegistry(modules: modules, prefs: prefs), prefs, modules)
    }

    func testMoveFromNotchIsSavedLikeSettings() {
        let (registry, prefs, _) = registry()
        registry.hideTab("b")
        settle()
        registry.moveTab("d", to: 0)
        XCTAssertEqual(prefs.tabOrder, ["d", "b", "a", "c"], "même clé que Réglages › Onglets")
        settle()
        XCTAssertEqual(registry.enabled.map { $0.id }, ["d", "a", "c"])
        XCTAssertEqual(registry.ordered.map { $0.id }, ["d", "b", "a", "c"], "liste des réglages à jour")
    }

    func testHideStopsModuleAndKeepsOneTab() {
        let (registry, prefs, modules) = registry(["a", "b"])
        registry.setPanelOpen(true)
        XCTAssertTrue(modules[0].isRunning)
        XCTAssertTrue(registry.hideTab("a"))
        XCTAssertEqual(prefs.tabEnabled["a"], false, "même clé que l'interrupteur des réglages")
        settle()
        XCTAssertFalse(modules[0].isRunning, "un onglet masqué arrête son module")
        XCTAssertFalse(registry.hideTab("b"), "le dernier onglet reste")
        XCTAssertNotEqual(prefs.tabEnabled["b"], false)
        XCTAssertEqual(registry.hidden.map { $0.id }, ["a"])
    }

    func testShowPutsTabBackAtTheEnd() {
        let (registry, prefs, modules) = registry()
        registry.setPanelOpen(true)
        registry.hideTab("a")
        settle()
        registry.showTab("a")
        settle()
        XCTAssertEqual(registry.enabled.map { $0.id }, ["b", "c", "d", "a"], "en bout de barre, là où est le « + »")
        XCTAssertEqual(prefs.tabEnabled["a"], true)
        XCTAssertTrue(modules[0].isRunning, "son module redémarre")
        XCTAssertTrue(registry.hidden.isEmpty)
        registry.showTab("a")
        registry.showTab("inconnu")
        XCTAssertEqual(prefs.tabOrder, ["b", "c", "d", "a"], "rien pour un onglet déjà affiché ou inconnu")
    }

    /// Les réglages changent pendant le mode édition : la notch suit, et l'inverse.
    func testSettingsAndNotchStayInSync() {
        let (registry, prefs, _) = registry()
        registry.setEnabled("c", false) // interrupteur de Réglages › Onglets
        settle()
        XCTAssertEqual(registry.hidden.map { $0.id }, ["c"], "proposé par le « + » de la notch")
        registry.move(from: IndexSet(integer: 3), to: 0) // glisser dans les réglages
        settle()
        XCTAssertEqual(registry.enabled.map { $0.id }, ["d", "a", "b"])
        // Deux gestes dans la notch avant que le registre se relise : chacun part des réglages, pas d'un ordre périmé.
        registry.moveTab("b", to: 0)
        registry.moveTab("a", to: 0)
        XCTAssertEqual(prefs.tabOrder, ["a", "b", "d", "c"])
        settle()
        XCTAssertEqual(registry.ordered.map { $0.id }, ["a", "b", "d", "c"])
    }

    // MARK: - Sorties du mode

    func testCollapsingLeavesEditMode() {
        let model = NotchViewModel()
        model.isExpanded = true
        model.isEditingTabs = true
        model.isExpanded = false
        XCTAssertFalse(model.isEditingTabs, "le panneau qui se replie sort du mode")
    }

    private func controller() -> (NotchController, Preferences) {
        _ = NSApplication.shared
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.hapticFeedback = false
        // Seul l'onglet Claude : aucun autre module ne démarre à l'ouverture.
        for id in ["media", "quicksettings", "shelf", "clipboard", "timer", "notes"] { prefs.tabEnabled[id] = false }
        let notch = NotchController(store: SessionStore(), monitor: ClaudeMonitor(), prefs: prefs,
                                    tools: ToolsFeed(paths: LayoutTests.absentPaths))
        addTeardownBlock { notch.panel.orderOut(nil) }
        return (notch, prefs)
    }

    private func key(_ code: Int, _ notch: NotchController) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: notch.panel.windowNumber, context: nil, characters: "",
                                       charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)))
    }

    /// Hors de tout écran, donc de la zone de survol.
    private let outside = CGPoint(x: -50_000, y: -50_000)

    /// Notch montrée par le raccourci puis repliée (elle reste affichée, à la place de la vraie encoche), puis
    /// rouverte par un clic sur l'encoche : ni clavier, ni fermeture au clic extérieur.
    private func openByClick(_ notch: NotchController, _ prefs: Preferences) {
        notch.togglePanelFromKeyboard()
        notch.togglePanelFromKeyboard()
        prefs.openTrigger = .click
        notch.mouseDown(at: CGPoint(x: notch.panel.frame.midX, y: notch.panel.frame.maxY - 1))
    }

    /// Ouvert au clic (ni clavier, ni « fermer au clic extérieur ») : le mode prend le clavier pour Échap, Échap en
    /// sort sans replier le panneau, et le clavier revient à l'app de devant.
    func testEscapeLeavesEditModeAndGivesKeyboardBack() throws {
        let (notch, prefs) = controller()
        openByClick(notch, prefs)
        XCTAssertTrue(notch.model.isExpanded)
        XCTAssertFalse(notch.panel.isKeyWindow, "ouvert au clic : pas de clavier")

        notch.model.isEditingTabs = true
        XCTAssertTrue(notch.panel.isKeyWindow, "le mode édition prend le clavier pour Échap")
        XCTAssertTrue(notch.handleKey(try key(kVK_Escape, notch)))
        XCTAssertFalse(notch.model.isEditingTabs)
        XCTAssertTrue(notch.model.isExpanded, "Échap sort du mode, le panneau reste ouvert")
        XCTAssertFalse(notch.panel.isKeyWindow, "clavier rendu")
        XCTAssertFalse(notch.handleKey(try key(kVK_Escape, notch)), "hors du mode, Échap n'est plus au panneau")
    }

    /// Ouvert au clavier : Échap sort d'abord du mode (le panneau garde le clavier), puis ferme.
    func testEscapeWithKeyboardPanelLeavesModeThenCloses() throws {
        let (notch, _) = controller()
        notch.togglePanelFromKeyboard()
        notch.model.isEditingTabs = true
        XCTAssertTrue(notch.handleKey(try key(kVK_Escape, notch)))
        XCTAssertFalse(notch.model.isEditingTabs)
        XCTAssertTrue(notch.model.isExpanded)
        XCTAssertTrue(notch.panel.isKeyWindow, "ouvert au raccourci : il garde le clavier")
        XCTAssertTrue(notch.handleKey(try key(kVK_Escape, notch)))
        XCTAssertFalse(notch.model.isExpanded)
    }

    /// Un clic à l'extérieur sort du mode sans replier le panneau, même quand il se ferme d'habitude à ce clic.
    func testClickOutsideLeavesEditModeOnly() {
        let (notch, _) = controller()
        notch.togglePanelFromKeyboard() // ouvert au clavier : un clic extérieur le ferme d'habitude
        notch.model.isEditingTabs = true
        notch.mouseDown(at: outside)
        XCTAssertFalse(notch.model.isEditingTabs)
        XCTAssertTrue(notch.model.isExpanded, "premier clic : sortie du mode seulement")
        notch.mouseDown(at: outside)
        XCTAssertFalse(notch.model.isExpanded, "clic suivant : règle habituelle")
    }

    func testShortcutCollapseLeavesEditMode() {
        let (notch, _) = controller()
        notch.togglePanelFromKeyboard()
        notch.model.isEditingTabs = true
        notch.togglePanelFromKeyboard()
        XCTAssertFalse(notch.model.isExpanded)
        XCTAssertFalse(notch.model.isEditingTabs)
    }

    /// Souris hors du panneau (ouvert au clic, fermeture à la sortie) : rien ne se replie tant que le mode dure ;
    /// en sortir rend la règle habituelle. Le contrôleur lit la vraie souris : sautée si elle est sur la notch.
    func testPanelStaysOpenWhileEditing() throws {
        let (notch, prefs) = controller()
        prefs.closeDelay = 0.1
        openByClick(notch, prefs)
        // Zone dépliée sans vue mesurée : largeur du panneau, hauteur de l'encoche + 48 pt, en haut de l'écran.
        let frame = notch.panel.frame
        let zone = CGRect(x: frame.midX - 300, y: frame.maxY - 100, width: 600, height: 100)
        try XCTSkipIf(zone.contains(NSEvent.mouseLocation), "souris sur la notch")
        XCTAssertTrue(notch.model.isExpanded)
        notch.model.isEditingTabs = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(notch.model.isExpanded, "ne se replie pas en mode édition")
        notch.model.isEditingTabs = false
        let deadline = Date().addingTimeInterval(2)
        while notch.model.isExpanded, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(notch.model.isExpanded, "hors du mode, la sortie de la souris replie le panneau")
    }
}
