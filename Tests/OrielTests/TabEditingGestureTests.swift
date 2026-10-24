import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Gestes du mode édition, joués par des événements souris envoyés à la notch dépliée (fenêtre hors écran) :
/// appui long, glisser, « − », OK, clic hors de la barre.
final class TabEditingGestureTests: XCTestCase {
    private var notch: NotchHarness!
    private var window: NSPanel!

    override func setUp() {
        super.setUp()
        notch = NotchHarness(self)
        notch.model.isExpanded = true
        let hosting = FirstMouseHostingView(rootView: notch.root)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: NotchController.panelSize)
        window = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        wait(0.6)
    }

    override func tearDown() {
        window.close()
        super.tearDown()
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Géométrie (fenêtre de 800 × 480, origine en bas à gauche)

    /// Bord gauche du contenu : panneau centré, rayon haut de 12 pt, marge de 14 pt.
    private var contentLeft: CGFloat {
        NotchController.panelSize.width / 2 - (notch.prefs.expandedWidth(compact: false) + 24) / 2 + 12 + 14
    }
    private var contentRight: CGFloat { NotchController.panelSize.width - contentLeft }
    /// Milieu de la ligne d'en-tête : sous la bande de 32 pt, ligne de 24 pt.
    private var headerY: CGFloat { NotchController.panelSize.height - 32 - 12 }

    private func tabCenter(_ index: Int) -> CGPoint {
        CGPoint(x: contentLeft + CGFloat(index) * (NotchTabBar.tabWidth + NotchTabBar.spacing)
                + NotchTabBar.tabWidth / 2, y: headerY)
    }

    /// « − » posé en haut à gauche de l'icône (décalé de -3, -4, cercle de 12 pt).
    private func hideBadge(_ index: Int) -> CGPoint {
        let left = contentLeft + CGFloat(index) * (NotchTabBar.tabWidth + NotchTabBar.spacing)
        return CGPoint(x: left + 3, y: headerY + 11 + 4 - 6)
    }

    private func send(_ type: NSEvent.EventType, _ point: CGPoint) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        window.sendEvent(event!)
    }

    private func click(_ point: CGPoint) {
        send(.leftMouseDown, point)
        wait(0.05)
        send(.leftMouseUp, point)
        wait(0.3)
    }

    private func longPress(_ point: CGPoint) {
        send(.leftMouseDown, point)
        wait(TabEditing.pressDuration + 0.25)
        send(.leftMouseUp, point)
        wait(0.4)
    }

    private func drag(from start: CGPoint, by dx: CGFloat) {
        send(.leftMouseDown, start)
        wait(0.05)
        let steps = 12
        for step in 1...steps {
            send(.leftMouseDragged, CGPoint(x: start.x + dx * CGFloat(step) / CGFloat(steps), y: start.y))
            wait(0.02)
        }
        send(.leftMouseUp, CGPoint(x: start.x + dx, y: start.y))
        wait(0.5)
    }

    private var shown: [String] { notch.registry.enabled.map { $0.id } }

    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["ORIEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    /// PNG de la notch telle qu'elle est à l'écran de test, rognée sur le panneau, sur fond gris clair.
    private func snapshot(_ name: String) throws {
        guard let outputDir else { return }
        let layer = try XCTUnwrap(window.contentView?.layer)
        let size = CGSize(width: NotchController.panelSize.width,
                          height: min(NotchController.panelSize.height, ceil(notch.model.contentSize.height) + 24))
        let scale: CGFloat = 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let cg = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        cg.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        cg.translateBy(x: 0, y: size.height * scale)
        cg.scaleBy(x: scale, y: -scale)
        layer.render(in: cg)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try png.write(to: outputDir.appendingPathComponent("tabs-\(name).png"))
    }

    // MARK: - Gestes

    func testShortClickSelectsTabAndLongPressStartsEditing() {
        click(tabCenter(1))
        XCTAssertEqual(notch.model.selectedTab, shown[1], "clic simple : changement d'onglet")
        XCTAssertFalse(notch.model.isEditingTabs, "clic simple : pas de mode édition")
        longPress(tabCenter(2))
        XCTAssertTrue(notch.model.isEditingTabs, "appui long : mode édition")
    }

    func testDragMovesTabAndSavesOrder() {
        let hiddenSlot = notch.registry.ordered.map { $0.id }.firstIndex(of: "codex")
        longPress(tabCenter(0))
        XCTAssertTrue(notch.model.isEditingTabs)
        let before = shown
        // Deux cases vers la droite.
        drag(from: tabCenter(0), by: 2 * (NotchTabBar.tabWidth + NotchTabBar.spacing))
        var expected = before
        expected.insert(expected.removeFirst(), at: 2)
        XCTAssertEqual(shown, expected, "onglet glissé de deux cases")
        // L'ordre enregistré est celui de tous les onglets : un onglet masqué (Codex, désactivé tant qu'il n'est pas
        // détecté) garde sa case, seuls les onglets affichés s'y redistribuent.
        let saved = notch.prefs.tabOrder
        XCTAssertEqual(saved.filter { expected.contains($0) }, expected, "enregistré dans les réglages")
        XCTAssertEqual(saved.firstIndex(of: "codex"), hiddenSlot, "l'onglet masqué garde sa case")
        XCTAssertTrue(notch.model.isEditingTabs, "le glisser ne sort pas du mode")
    }

    func testMinusHidesTab() {
        longPress(tabCenter(0))
        let before = shown
        click(hideBadge(1))
        XCTAssertEqual(shown, before.filter { $0 != before[1] }, "« − » masque l'onglet")
        XCTAssertEqual(notch.prefs.tabEnabled[before[1]], false)
        XCTAssertTrue(notch.model.isEditingTabs)
    }

    func testClickOnBarStaysAndClickElsewhereLeaves() {
        longPress(tabCenter(0))
        click(tabCenter(1))
        XCTAssertTrue(notch.model.isEditingTabs, "clic sur une icône : on reste dans le mode")
        // Dans le contenu de l'onglet (estompé, il ne prend plus les clics), sous la ligne d'en-tête.
        XCTAssertGreaterThan(notch.model.contentSize.height, 32 + 24 + 40, "panneau assez haut")
        click(CGPoint(x: NotchController.panelSize.width / 2, y: headerY - 40))
        XCTAssertFalse(notch.model.isEditingTabs, "clic sous la barre : sortie du mode")
    }

    /// Rendus PNG (`ORIEL_SNAPSHOT_DIR`) : `tabs-normal`, `tabs-editing`, `tabs-editing-dragging` (glisser en
    /// cours, les autres écartés), `tabs-editing-hidden` (« + » actif), `tabs-editing-one-tab` (pas de « − »),
    /// `tabs-editing-reduce-motion` (sans tremblement).
    func testRenderEditMode() throws {
        guard outputDir != nil else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        try snapshot("normal")
        longPress(tabCenter(0))
        try snapshot("editing")

        let start = tabCenter(0)
        send(.leftMouseDown, start)
        for step in 1...8 {
            send(.leftMouseDragged, CGPoint(x: start.x + CGFloat(step) * 6, y: start.y))
            wait(0.03)
        }
        wait(0.6)
        try snapshot("editing-dragging")
        send(.leftMouseUp, CGPoint(x: start.x + 48, y: start.y))
        wait(0.5)

        click(hideBadge(2))
        wait(0.3)
        try snapshot("editing-hidden")

        for id in shown.dropFirst() { notch.registry.hideTab(id) }
        wait(0.6)
        XCTAssertEqual(shown.count, 1)
        try snapshot("editing-one-tab")

        for id in notch.registry.hidden.map({ $0.id }) { notch.registry.showTab(id) }
        notch.model.isEditingTabs = false
        notch.model.reduceMotion = true
        wait(0.4)
        longPress(tabCenter(0))
        wait(0.3)
        try snapshot("editing-reduce-motion")
    }

    private func wiggleViews(_ view: NSView? = nil) -> [WiggleView] {
        guard let view = view ?? window.contentView else { return [] }
        return ((view as? WiggleView).map { [$0] } ?? []) + view.subviews.flatMap { wiggleViews($0) }
    }

    /// Le tremblement est une animation Core Animation par icône, qui n'existe qu'en mode édition (rien à chaque
    /// image côté app) ; aucune avec « Réduire les animations ».
    func testWiggleExistsOnlyInEditMode() {
        XCTAssertTrue(wiggleViews().isEmpty, "mode normal : aucune vue de tremblement")
        longPress(tabCenter(0))
        let views = wiggleViews()
        XCTAssertEqual(views.count, shown.count, "une par onglet")
        XCTAssertTrue(views.allSatisfy { $0.isWiggling }, "toutes tremblent")
        notch.model.isEditingTabs = false
        // La transition de sortie (ressort) dure moins d'une seconde.
        let deadline = Date().addingTimeInterval(2)
        while !wiggleViews().isEmpty, Date() < deadline { wait(0.05) }
        XCTAssertTrue(wiggleViews().isEmpty, "sortie du mode : plus rien ne tremble")

        notch.model.reduceMotion = true
        wait(0.3)
        longPress(tabCenter(0))
        XCTAssertTrue(notch.model.isEditingTabs)
        XCTAssertFalse(wiggleViews().contains { $0.isWiggling }, "« Réduire les animations » : pas de tremblement")
    }

    /// Diagnostic (`ORIEL_FOOTPRINT`, mesures de temps non fiables en CI) : CPU de l'app avant, pendant et après
    /// le mode édition. Mesuré en debug : 0 %, 3 à 4 % (une animation SwiftUI répétée prenait 100 %), 0 % une fois
    /// passée la transition de sortie (moins d'une seconde, comme un changement d'onglet).
    func testEditModeCPU() throws {
        guard ProcessInfo.processInfo.environment["ORIEL_FOOTPRINT"] != nil else {
            throw XCTSkip("ORIEL_FOOTPRINT non défini")
        }
        func cpu(during seconds: TimeInterval) -> Double {
            let start = FootprintTests.sample().cpu
            wait(seconds)
            return (FootprintTests.sample().cpu - start) / seconds * 100
        }
        let before = cpu(during: 2)
        longPress(tabCenter(0))
        let editing = cpu(during: 2)
        notch.model.isEditingTabs = false
        wait(1.5)
        let after = cpu(during: 2)
        print(String(format: "EDIT CPU avant %.1f %%, en mode édition %.1f %%, après %.1f %%", before, editing, after))
        XCTAssertLessThan(editing, 10, "tremblement hors du processus")
        XCTAssertLessThan(after, before + 1, "rien ne reste après le mode")
    }

    private func popUpButtons(_ view: NSView? = nil) -> [NSPopUpButton] {
        guard let view = view ?? window.contentView else { return [] }
        return ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap { popUpButtons($0) }
    }

    /// Le « + » est un vrai menu AppKit, rempli par SwiftUI à son ouverture : grisé sans onglet masqué, puis ouvert
    /// par un clic. Pendant le suivi du menu (boucle bloquante), un minuteur relève les éléments, en choisit un et
    /// ferme le menu ; l'onglet choisi revient en bout de barre.
    func testPlusMenuListsHiddenTabs() throws {
        // Codex, Messages et Mail sont masqués au départ (Codex n'est activé d'office que s'il est détecté) : on les
        // affiche pour partir de « rien de masqué ».
        ["codex", "messages", "mail"].forEach { notch.registry.showTab($0) }
        wait(0.5)
        XCTAssertTrue(shown.contains("codex"))
        longPress(tabCenter(0))
        // Le « … » disparaît avec la transition d'entrée : il ne reste que le « + ».
        let deadline = Date().addingTimeInterval(2)
        while popUpButtons().count > 1, Date() < deadline { wait(0.05) }
        XCTAssertEqual(popUpButtons().count, 1)
        XCTAssertFalse(try XCTUnwrap(popUpButtons().first).isEnabled, "rien de masqué : « + » grisé")

        let hiddenIds = [shown[1], shown[3]]
        hiddenIds.forEach { notch.registry.hideTab($0) }
        wait(0.5)
        let plus = try XCTUnwrap(popUpButtons().first)
        XCTAssertTrue(plus.isEnabled)
        let expected = hiddenIds.compactMap { notch.registry.module($0)?.title }

        var titles: [String] = []
        let timer = Timer(timeInterval: 0.3, repeats: true) { timer in
            guard let menu = plus.menu, !menu.items.isEmpty else { return }
            timer.invalidate()
            titles = menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map { $0.title }
            if let index = menu.items.firstIndex(where: { $0.title == expected.last }) {
                menu.performActionForItem(at: index)
            }
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        // Garde-fou : le menu se ferme quoi qu'il arrive.
        let guardTimer = Timer(timeInterval: 3, repeats: false) { _ in plus.menu?.cancelTracking() }
        RunLoop.main.add(guardTimer, forMode: .common)
        let point = tabCenter(shown.count)
        send(.leftMouseDown, point)
        send(.leftMouseUp, point)
        timer.invalidate()
        guardTimer.invalidate()
        wait(0.5)

        XCTAssertEqual(titles, expected, "les onglets masqués, dans l'ordre des réglages")
        XCTAssertEqual(shown.last, hiddenIds[1], "remis en bout de barre")
        XCTAssertTrue(notch.model.isEditingTabs, "on reste dans le mode")
    }

    func testDoneButtonLeaves() {
        longPress(tabCenter(0))
        click(CGPoint(x: contentRight - 20, y: headerY))
        XCTAssertFalse(notch.model.isEditingTabs, "OK : sortie du mode")
    }
}
