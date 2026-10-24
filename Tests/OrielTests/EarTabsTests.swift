import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Intercalaires de la notch repliée : activités retenues, répartition à gauche et à droite, géométrie, zones de survol
/// (logique pure, sans fenêtre), puis le contrôleur et la migration du réglage.
final class EarTabsTests: XCTestCase {
    private func entry(_ id: String, _ text: String = "1", priority: Int = 0, bars: Bool = false,
                       alert: Bool = false) -> ModuleEarsEntry {
        ModuleEarsEntry(id: id, ears: ModuleEars(symbol: "circle", text: text, priority: priority, bars: bars, alert: alert))
    }

    private func ids(_ tabs: [EarTab]) -> [String] { tabs.map { $0.id } }

    private func tabs(_ claude: NotchIndicator, _ modules: [ModuleEarsEntry], showEars: Bool = true,
                      claudeEars: SessionStore.EarsContent? = nil) -> [EarTab] {
        EarTabs.tabs(claude: claude, claudeEars: claudeEars, modules: modules, showEars: showEars)
    }

    private func layout(_ tabs: [EarTab], mode: EarTabsMode = .visible,
                        notch: CGSize = CGSize(width: 185, height: 32)) -> EarTabsLayout {
        EarTabsLayout(tabs: tabs, notch: notch, mode: mode)
    }

    private func fakeTabs(_ count: Int) -> [EarTab] {
        tabs(.none, (0..<count).map { entry("m\($0)", "\($0)", priority: 100 - $0) })
    }

    // MARK: - Activités retenues

    /// Claude (attend > travaille > vient de finir) d'abord, puis les modules par priorité décroissante ; à égalité,
    /// l'ordre des onglets. Chaque activité a son intercalaire.
    func testEveryActivityGetsATabInPriorityOrder() {
        let media = entry("media", "", priority: 1, bars: true)
        let coffee = entry("quicksettings", "1h00", priority: -10)
        let timer = entry("timer", "4:59", priority: 5)
        XCTAssertEqual(ids(tabs(.working, [media, coffee, timer])), ["claude", "timer", "media", "quicksettings"])
        XCTAssertEqual(ids(tabs(.attention, [media, timer])), ["claude", "timer", "media"], "plus seul : une alerte parmi les autres")
        XCTAssertEqual(ids(tabs(.done, [media])), ["claude", "media"])
        XCTAssertEqual(ids(tabs(.none, [media, coffee, timer])), ["timer", "media", "quicksettings"])
        XCTAssertEqual(ids(tabs(.none, [])), [])
        XCTAssertEqual(ids(tabs(.working, [entry("a"), entry("b")])), ["claude", "a", "b"], "égalité : l'ordre des onglets")
    }

    func testEarsOffMeansNoTabs() {
        XCTAssertEqual(tabs(.working, [entry("a")], showEars: false), [])
    }

    func testAlertsStayDeployed() {
        XCTAssertTrue(tabs(.attention, []).first?.isAlert == true)
        XCTAssertFalse(tabs(.working, []).first?.isAlert == true)
        XCTAssertTrue(tabs(.none, [entry("codex", "1", priority: 9, alert: true)]).first?.isAlert == true)
    }

    func testClaudeTabCarriesItsShortText() {
        XCTAssertEqual(SessionStore.EarsContent(tasks: "3/7", sessions: 0, agents: 0).label, "3/7")
        XCTAssertEqual(SessionStore.EarsContent(tasks: nil, sessions: 2, agents: 0).label, "2")
        XCTAssertEqual(SessionStore.EarsContent(tasks: nil, sessions: 1, agents: 6).label, "1·6")
        XCTAssertEqual(tabs(.working, [], claudeEars: .init(tasks: nil, sessions: 1, agents: 6)).first?.text, "1·6")
        XCTAssertEqual(tabs(.working, []).first?.text, "", "pas d'information : icône seule")
    }

    // MARK: - Répartition

    /// Le plus prioritaire à gauche contre la notch, le suivant à droite contre elle, puis un cran plus loin.
    func testTabsAlternateSidesNearestFirst() {
        let rows: [(count: Int, left: [String], right: [String])] = [
            (0, [], []),
            (1, ["m0"], []),
            (2, ["m0"], ["m1"]),
            (3, ["m0", "m2"], ["m1"]),
            (4, ["m0", "m2"], ["m1", "m3"]),
            (5, ["m0", "m2", "m4"], ["m1", "m3"]),
            (6, ["m0", "m2", "m4"], ["m1", "m3", "m5"]),
        ]
        for row in rows {
            let placed = EarTabs.distribute(fakeTabs(row.count))
            XCTAssertEqual(ids(placed.left), row.left, "\(row.count) activités, gauche")
            XCTAssertEqual(ids(placed.right), row.right, "\(row.count) activités, droite")
        }
    }

    /// Au plus 3 par côté : au-delà, la sixième place devient « +N » (N = activités sans place, la sixième comprise).
    func testMoreThanSixCollapsesIntoPlusN() {
        for count in 7...10 {
            let placed = EarTabs.distribute(fakeTabs(count))
            XCTAssertEqual(placed.left.count, 3)
            XCTAssertEqual(placed.right.count, 3)
            XCTAssertEqual(ids(placed.left), ["m0", "m2", "m4"], "les plus prioritaires gardent leur place")
            XCTAssertEqual(ids(Array(placed.right.prefix(2))), ["m1", "m3"])
            let more = placed.right[2]
            XCTAssertEqual(more.id, EarTab.moreId)
            XCTAssertEqual(more.text, "+\(count - 5)")
            guard case .more(let hidden) = more.kind else { return XCTFail("« +N » porte les activités cachées") }
            XCTAssertEqual(ids(hidden), (5..<count).map { "m\($0)" })
        }
        XCTAssertNil(EarTabs.distribute(fakeTabs(6)).right.first { $0.id == EarTab.moreId }, "six tiennent sans « +N »")
    }

    // MARK: - Géométrie

    func testTabsAreFlushWithTheNotchAndEachOther() {
        let layout = layout(fakeTabs(6))
        for side in [layout.left, layout.right] {
            var edge: CGFloat = 185 / 2
            for item in side {
                XCTAssertEqual(item.inner, edge, accuracy: 0.001, "\(item.id) colle au précédent, sans jour ni recouvrement")
                edge += item.width
            }
        }
        XCTAssertEqual(layout.left[0].frame.maxX, -185 / 2, accuracy: 0.001)
        XCTAssertEqual(layout.right[0].frame.minX, 185 / 2, accuracy: 0.001)
        XCTAssertEqual(layout.reach, max(layout.left.last!.inner + layout.left.last!.width,
                                        layout.right.last!.inner + layout.right.last!.width))
    }

    /// Aucun décalage vertical : chaque intercalaire a exactement la hauteur de la notch (même haut, même bas), à tout rang.
    /// Le détail par taille d'encoche et la silhouette dessinée sont dans `EarTabsGeometryTests`.
    func testEveryTabHasTheNotchHeight() {
        for height: CGFloat in [32, 24] {
            let layout = layout(fakeTabs(6), notch: CGSize(width: 185, height: height))
            for item in layout.items {
                XCTAssertEqual(item.height, height, "hauteur \(height), rang \(item.rank)")
                XCTAssertEqual(item.frame.minY, 0)
                XCTAssertEqual(item.frame.maxY, height)
            }
        }
    }

    func testWidthsFollowTheModeAndAlertsStayWide() {
        let tabs = tabs(.attention, [entry("timer", "4:59", priority: 5), entry("media", "", priority: 1, bars: true)])
        let visible = layout(tabs, mode: .visible)
        // Contre la notch (ou en alerte) : icône et information. Plus loin dans la pile : la tranche de l'icône.
        XCTAssertEqual(visible.item("claude")?.width, tabs[0].restWidth)
        XCTAssertEqual(visible.item("timer")?.width, tabs[1].restWidth)
        XCTAssertEqual(visible.item("media")?.width, EarTabs.sliceWidth, "rang 1 : glissé sous le premier")
        XCTAssertGreaterThan(visible.left[0].width, EarTabs.sliverWidth)

        let retracted = layout(tabs, mode: .retracted)
        XCTAssertEqual(retracted.item("claude")?.width, tabs[0].restWidth, "une alerte reste déployée")
        XCTAssertEqual(retracted.item("timer")?.width, EarTabs.sliverWidth)
        XCTAssertEqual(retracted.item("media")?.width, EarTabs.sliverWidth)
        XCTAssertLessThan(retracted.reach, visible.reach)
    }

    /// Texte plus long, largeur plus grande, bornée.
    func testRestWidthGrowsWithItsContentUpToACap() {
        func width(_ text: String, bars: Bool = false) -> CGFloat {
            EarTab(id: "x", kind: .module(ModuleEars(symbol: "circle", text: text)), priority: 0, text: text, bars: bars,
                   isAlert: false).restWidth
        }
        XCTAssertLessThan(width(""), width("3"))
        XCTAssertLessThan(width("3"), width("4:59"))
        XCTAssertEqual(width("Terminé"), width("Terminé et plus long encore"), "bornée")
        XCTAssertGreaterThan(width("", bars: true), width(""))
    }

    func testLayoutSignatureIgnoresTextButNotShape() {
        let a = layout(tabs(.none, [entry("timer", "4:59")]))
        let b = layout(tabs(.none, [entry("timer", "4:58")]))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.signature, b.signature, "le décompte ne relance pas l'animation de mise en page")
        let c = layout(tabs(.none, [entry("timer", "12:00")]))
        XCTAssertNotEqual(a.signature, c.signature)
    }

    // MARK: - Zones de survol

    func testNotchCenterAndTabsNeverOverlap() {
        let layout = layout(fakeTabs(6))
        let notch = CGRect(x: -92.5, y: 0, width: 185.0, height: 32.0)
        func overlap(_ a: CGRect, _ b: CGRect) -> Bool {
            let shared = a.intersection(b)
            return !shared.isNull && shared.width > 0.001 && shared.height > 0.001
        }
        // Les tranches visibles se touchent sans se recouvrir ; le corps de chacun glisse sous le précédent.
        for item in layout.items {
            XCTAssertFalse(overlap(item.frame, notch), "\(item.id) ne recouvre pas la notch")
            for other in layout.items where other.id != item.id {
                XCTAssertFalse(overlap(item.frame, other.frame), "\(item.id) et \(other.id)")
            }
        }
        // Chaque point de la bande n'est que dans une zone : le survol d'un intercalaire n'ouvre jamais le panneau.
        var x: CGFloat = -330
        while x <= 330 {
            for y in stride(from: CGFloat(0), through: 34, by: 1) {
                let point = CGPoint(x: x, y: y)
                // Deux intercalaires voisins partagent leur bord, et le coin arrondi de l'un laisse voir le corps de l'autre.
                let inBodies = layout.items.filter { $0.bodyFrame.insetBy(dx: -0.001, dy: -0.001).contains(point) }.map { $0.id }
                let inSlices = layout.items.filter { $0.frame.insetBy(dx: -0.001, dy: -0.001).contains(point) }.map { $0.id }
                switch layout.hit(point, hovered: nil, cardHeight: 0) {
                case .tab(let id): XCTAssertTrue(inBodies.contains(id), "(\(x), \(y))")
                case .notch: XCTAssertTrue(abs(x) <= 92.5 && (inSlices.isEmpty || abs(x) == 92.5), "(\(x), \(y))")
                case .none: XCTAssertGreaterThan(abs(x), 92.5, "(\(x), \(y)) : jamais de trou dans la notch")
                }
            }
            x += 0.5
        }
    }

    func testHitZonesAreExact() {
        let layout = layout(tabs(.working, [entry("timer", "4:59", priority: 5)]))
        let claude = layout.left[0]
        let timer = layout.right[0]
        // Notch : bords inclusifs, marge de 2 pt sous la bande.
        XCTAssertEqual(layout.hit(CGPoint(x: 0, y: 0), hovered: nil, cardHeight: 0), .notch, "pile sur le bord haut")
        XCTAssertEqual(layout.hit(CGPoint(x: 92.5, y: 10), hovered: nil, cardHeight: 0), .notch)
        XCTAssertEqual(layout.hit(CGPoint(x: -92.5, y: 34), hovered: nil, cardHeight: 0), .notch)
        XCTAssertEqual(layout.hit(CGPoint(x: 0, y: 34.5), hovered: nil, cardHeight: 0), .none)
        // Juste de l'autre côté du bord : l'intercalaire, plus la notch.
        XCTAssertEqual(layout.hit(CGPoint(x: -92.6, y: 10), hovered: nil, cardHeight: 0), .tab("claude"))
        XCTAssertEqual(layout.hit(CGPoint(x: 92.6, y: 10), hovered: nil, cardHeight: 0), .tab("timer"))
        // Bord extérieur et bas de chaque intercalaire.
        XCTAssertEqual(layout.hit(CGPoint(x: claude.frame.minX + 0.5, y: 5), hovered: nil, cardHeight: 0), .tab("claude"))
        XCTAssertEqual(layout.hit(CGPoint(x: claude.frame.minX - 0.5, y: 5), hovered: nil, cardHeight: 0), .none)
        XCTAssertEqual(layout.hit(CGPoint(x: claude.frame.midX, y: claude.height), hovered: nil, cardHeight: 0), .tab("claude"))
        XCTAssertEqual(layout.hit(CGPoint(x: claude.frame.midX, y: claude.height + 0.5), hovered: nil, cardHeight: 0), .none,
                       "sous la languette : plus rien")
        XCTAssertEqual(layout.hit(CGPoint(x: timer.frame.maxX + 0.5, y: 5), hovered: nil, cardHeight: 0), .none)
    }

    /// La forme réelle : le coin extérieur bas est arrondi, la zone aussi.
    func testRoundedOuterCornerIsOutsideTheZone() {
        let layout = layout(tabs(.working, []))
        let item = layout.left[0]
        let corner = CGPoint(x: item.frame.minX + 0.4, y: item.height - 0.4)
        XCTAssertEqual(layout.hit(corner, hovered: nil, cardHeight: 0), .none, "le coin arrondi n'est pas la forme")
        let inner = CGPoint(x: item.frame.maxX - 0.4, y: item.height - 0.4)
        XCTAssertEqual(layout.hit(inner, hovered: nil, cardHeight: 0), .tab("claude"), "le coin intérieur est collé")
    }

    // MARK: - Intercalaire déployé

    /// Le bord intérieur ne bouge pas : il grandit vers l'extérieur et vers le bas, passe devant ses voisins et ne
    /// touche ni la notch ni l'intercalaire plus proche.
    func testDeployedTabGrowsOutwardAndDownKeepingItsInnerEdge() {
        let layout = layout(fakeTabs(4))
        for item in layout.items {
            let card = layout.cardFrame(item, height: 80)
            XCTAssertEqual(card.height, 80)
            XCTAssertGreaterThan(card.width, item.width)
            if item.side == .left {
                XCTAssertEqual(card.maxX, item.frame.maxX, accuracy: 0.001, "\(item.id) : bord intérieur fixe")
                XCTAssertLessThan(card.minX, item.frame.minX)
            } else {
                XCTAssertEqual(card.minX, item.frame.minX, accuracy: 0.001)
                XCTAssertGreaterThan(card.maxX, item.frame.maxX)
            }
            XCTAssertEqual(layout.cardFrame(item, height: 5).height, 32, "au moins la bande de la notch")
        }
        let outer = layout.left[1]
        let card = layout.cardFrame(outer, height: 80)
        let probe = CGPoint(x: card.minX + 20, y: 60)
        XCTAssertEqual(layout.hit(probe, hovered: outer.id, cardHeight: 80), .tab(outer.id), "sous la bande, dans le cadre")
        XCTAssertEqual(layout.hit(probe, hovered: nil, cardHeight: 80), .none, "replié : plus rien là")
        XCTAssertEqual(layout.hit(CGPoint(x: card.maxX + 1, y: 60), hovered: outer.id, cardHeight: 80), .none)
        XCTAssertEqual(layout.hit(CGPoint(x: card.minX - 1, y: 20), hovered: outer.id, cardHeight: 80), .none)
        XCTAssertEqual(layout.hit(CGPoint(x: 0, y: 20), hovered: outer.id, cardHeight: 80), .notch, "le centre reste la notch")
        XCTAssertEqual(layout.hit(CGPoint(x: 0, y: 60), hovered: outer.id, cardHeight: 80), .none)
        XCTAssertEqual(layout.hit(CGPoint(x: layout.left[0].frame.midX, y: 10), hovered: outer.id, cardHeight: 80),
                       .tab(layout.left[0].id), "l'intercalaire plus proche garde sa zone")
    }

    /// Un intercalaire déployé recouvre ses voisins extérieurs : rien ne glisse sous une souris immobile.
    func testNeighborsDoNotMoveWhenATabIsDeployed() {
        let layout = layout(fakeTabs(6))
        let before = layout.items.map { $0.frame }
        _ = layout.cardFrame(layout.left[0], height: 120)
        XCTAssertEqual(layout.items.map { $0.frame }, before)
    }

    func testDeployedWidthStaysInsideTheWindow() {
        let layout = layout(fakeTabs(6))
        let half = NotchController.panelSize.width / 2
        for item in layout.items {
            let card = layout.cardFrame(item, height: 100)
            XCTAssertLessThanOrEqual(card.maxX, half - EarTabs.windowMargin + 0.001, item.id)
            XCTAssertGreaterThanOrEqual(card.minX, -half + EarTabs.windowMargin - 0.001, item.id)
            XCTAssertGreaterThanOrEqual(card.width, item.width)
        }
        XCTAssertEqual(layout.cardWidth(layout.left[0]), EarTabs.cardWidth, "assez de place : la largeur voulue")
    }

    // MARK: - Registre

    func testRegistryBuildsTabsFromRunningModules() {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let player = FakeModule(id: "media", ears: entry("media", "", priority: 1, bars: true).ears, keepsRunning: true)
        let minuteur = FakeModule(id: "timer", ears: entry("timer", "4:59", priority: 5).ears, keepsRunning: true)
        let sleeping = FakeModule(id: "notes", ears: ModuleEars(symbol: "note", text: "!", priority: 9))
        let registry = ModuleRegistry(modules: [FakeModule(id: "claude"), player, minuteur, sleeping], prefs: prefs)
        registry.reconcile()
        XCTAssertEqual(registry.earsEntries.map { $0.id }, ["media", "timer"], "seuls les modules qui tournent")

        XCTAssertEqual(ids(registry.earTabs(claude: .working, claudeEars: nil)), ["claude", "timer", "media"])
        XCTAssertEqual(ids(registry.earTabs(claude: .attention, claudeEars: nil)), ["claude", "timer", "media"])
        XCTAssertEqual(ids(registry.earTabs(claude: .none, claudeEars: nil)), ["timer", "media"])
        XCTAssertEqual(registry.earLayout(claude: .working, claudeEars: nil, notch: CGSize(width: 185, height: 32))
            .left.map { $0.id }, ["claude", "media"])

        registry.setEnabled("claude", false)
        XCTAssertEqual(ids(registry.earTabs(claude: .working, claudeEars: nil)), ["timer", "media"], "sans onglet Claude")

        prefs.showEars = false
        XCTAssertEqual(registry.earTabs(claude: .working, claudeEars: nil), [])
    }

    // MARK: - Réglage et migration

    func testModeIsStoredAndVisibleByDefault() {
        let defaults = makeEphemeralDefaults(self)
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.earTabsMode, .visible, "par défaut : l'information est visible d'un coup d'œil")
        prefs.earTabsMode = .retracted
        XCTAssertEqual(defaults.string(forKey: "appearance.earTabs"), "retracted")
        XCTAssertEqual(Preferences(defaults: defaults).earTabsMode, .retracted)
        defaults.set("n'importe quoi", forKey: "appearance.earTabs")
        XCTAssertEqual(Preferences(defaults: defaults).earTabsMode, .visible, "valeur inconnue : le défaut")
    }

    /// Ancien « Alterner Claude et les autres oreilles » : activé ou jamais réglé → toujours visibles ; désactivé
    /// (qui voulait Claude seul, une notch discrète) → rétractés. L'ancienne clé disparaît.
    func testOldAlternateSettingMigrates() {
        XCTAssertEqual(Preferences.migratedEarTabs(alternateEars: nil), .visible)
        XCTAssertEqual(Preferences.migratedEarTabs(alternateEars: true), .visible)
        XCTAssertEqual(Preferences.migratedEarTabs(alternateEars: false), .retracted)

        for (old, expected) in [(true, EarTabsMode.visible), (false, .retracted)] {
            let defaults = makeEphemeralDefaults(self)
            defaults.set(old, forKey: "appearance.alternateEars")
            XCTAssertEqual(Preferences(defaults: defaults).earTabsMode, expected, "ancien réglage \(old)")
            XCTAssertNil(defaults.object(forKey: "appearance.alternateEars"), "migré une fois, l'ancienne clé est retirée")
            XCTAssertEqual(defaults.string(forKey: "appearance.earTabs"), expected.rawValue)
            XCTAssertEqual(Preferences(defaults: defaults).earTabsMode, expected, "stable au lancement suivant")
        }
        // Le nouveau réglage prime sur l'ancien (retour à une ancienne version puis mise à jour).
        let defaults = makeEphemeralDefaults(self)
        defaults.set("visible", forKey: "appearance.earTabs")
        defaults.set(false, forKey: "appearance.alternateEars")
        XCTAssertEqual(Preferences(defaults: defaults).earTabsMode, .visible)
    }

    func testResetRestoresTheDefaultMode() {
        let defaults = makeEphemeralDefaults(self)
        let prefs = Preferences(defaults: defaults)
        prefs.earTabsMode = .retracted
        prefs.resetNotchSettings()
        XCTAssertEqual(prefs.earTabsMode, .visible)
        XCTAssertEqual(Preferences(defaults: defaults).earTabsMode, .visible)
    }
}

/// Le contrôleur : survol d'un intercalaire (déploiement, zones, clic) sans toucher à l'ouverture du panneau.
final class EarTabsHoverTests: XCTestCase {
    /// Durée fixe, seulement avant une assertion « rien ne s'est passé » (elle ne peut pas échouer par lenteur).
    private func settle(_ seconds: TimeInterval = 0.35) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Attend l'état asynchrone (3 s au plus) plutôt qu'une durée fixe, que le minuteur de l'app dépasse sur une machine chargée.
    private func wait(_ message: String, until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(spin(timeout: 3, until: condition), message, file: file, line: line)
    }

    private let store = SessionStore.working(1)
    private lazy var prefs: Preferences = {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.hapticFeedback = false
        return prefs
    }()

    private func controller() -> NotchController {
        _ = NSApplication.shared
        let notch = NotchController(store: store, monitor: ClaudeMonitor(), prefs: prefs,
                                    tools: ToolsFeed(paths: LayoutTests.absentPaths))
        addTeardownBlock { notch.panel.orderOut(nil) }
        // Transparente : la fenêtre passe à l'écran mais l'utilisateur ne voit rien.
        notch.panel.alphaValue = 0
        // Montrée par le raccourci, puis repliée : la notch reste à l'écran, géométrie calculée.
        notch.togglePanelFromKeyboard()
        notch.togglePanelFromKeyboard()
        XCTAssertFalse(notch.model.isExpanded)
        // Refermée au raccourci, la notch ignore la souris jusqu'à ce qu'elle sorte de sa zone.
        notch.mouseLocation = { CGPoint(x: -50_000, y: -50_000) }
        notch.mouseMoved()
        return notch
    }

    /// Point écran au milieu de l'intercalaire `id` (dans la bande de la notch), ou `dx` / `dy` plus loin.
    private func point(_ notch: NotchController, tab id: String, dy: CGFloat = 4) -> CGPoint {
        let layout = notch.registry.earLayout(claude: store.indicator, claudeEars: store.ears,
                                              notch: notch.model.notchSize)
        let item = layout.item(id)!
        return CGPoint(x: notch.panel.frame.midX + item.frame.midX, y: notch.panel.frame.maxY - dy)
    }

    private func move(_ notch: NotchController, to point: CGPoint) {
        notch.mouseLocation = { point }
        notch.mouseMoved()
    }

    /// Rien ne tourne au repos ; survoler un intercalaire le déploie après un court délai, sans ouvrir le panneau ;
    /// le quitter le replie et remet tout au repos.
    func testHoverDeploysATabWithoutOpeningThePanel() {
        let notch = controller()
        XCTAssertEqual(notch.debugInfo["polling"] as? Bool, false, "au repos : aucun relevé")
        XCTAssertNil(notch.model.hoveredTab)
        XCTAssertTrue(notch.panel.ignoresMouseEvents)

        let onClaude = point(notch, tab: "claude")
        move(notch, to: onClaude)
        XCTAssertNil(notch.model.hoveredTab, "délai d'intention : traverser la barre ne déploie rien")
        wait("déployé après le délai d'intention") { notch.model.hoveredTab == "claude" }
        XCTAssertEqual(notch.model.hoveredTab, "claude")
        settle()
        XCTAssertFalse(notch.model.isExpanded, "un intercalaire n'ouvre pas le panneau, même plus longtemps que le délai")
        XCTAssertFalse(notch.panel.ignoresMouseEvents, "déployé : ses boutons reçoivent la souris")
        XCTAssertEqual(notch.debugInfo["polling"] as? Bool, true)
        XCTAssertEqual((notch.debugInfo["earTabs"] as? [String: Any])?["hovered"] as? String, "claude")

        move(notch, to: CGPoint(x: onClaude.x - 400, y: onClaude.y - 200))
        XCTAssertEqual(notch.model.hoveredTab, "claude", "un écart ne le referme pas aussitôt")
        wait("replié") {
            notch.model.hoveredTab == nil && notch.panel.ignoresMouseEvents && notch.debugInfo["polling"] as? Bool == false
        }
        XCTAssertNil(notch.model.hoveredTab)
        XCTAssertTrue(notch.panel.ignoresMouseEvents)
        XCTAssertEqual(notch.debugInfo["polling"] as? Bool, false, "plus de relevé une fois replié")
    }

    func testPassingOverATabQuicklyDeploysNothing() {
        let notch = controller()
        move(notch, to: point(notch, tab: "claude"))
        notch.mouseLocation = { CGPoint(x: -50_000, y: -50_000) }
        notch.mouseMoved()
        settle(0.5)
        XCTAssertNil(notch.model.hoveredTab)
        XCTAssertEqual(notch.debugInfo["polling"] as? Bool, false)
    }

    /// Le centre de la notch ouvre le panneau comme avant ; il replie l'intercalaire déployé tout de suite.
    func testNotchCenterStillOpensThePanelAndFoldsTheTab() {
        let notch = controller()
        move(notch, to: point(notch, tab: "claude"))
        wait("déployé") { notch.model.hoveredTab == "claude" }
        XCTAssertEqual(notch.model.hoveredTab, "claude")

        move(notch, to: CGPoint(x: notch.panel.frame.midX, y: notch.panel.frame.maxY - 4))
        XCTAssertNil(notch.model.hoveredTab, "le centre n'est pas un intercalaire")
        wait("ouvert par le centre") { notch.model.isExpanded }
        XCTAssertTrue(notch.model.isExpanded, "comportement validé : le centre ouvre le panneau")
        XCTAssertNil(notch.model.hoveredTab)
    }

    func testClickOnATabOpensThePanelOnItsTab() {
        let notch = controller()
        notch.mouseDown(at: point(notch, tab: "claude"))
        XCTAssertTrue(notch.model.isExpanded)
        XCTAssertEqual(notch.model.selectedTab, "claude")
        XCTAssertNil(notch.model.hoveredTab)
    }

    /// Un clic sur le centre en mode « au clic » ouvre toujours ; un clic sur un intercalaire ouvre son onglet.
    func testClickModeKeepsTheCenterAndTheTabsApart() {
        let notch = controller()
        prefs.openTrigger = .click
        move(notch, to: CGPoint(x: notch.panel.frame.midX, y: notch.panel.frame.maxY - 4))
        settle()
        XCTAssertFalse(notch.model.isExpanded, "en mode « au clic », survoler le centre n'ouvre rien")
        notch.mouseDown(at: CGPoint(x: notch.panel.frame.midX, y: notch.panel.frame.maxY - 4))
        XCTAssertTrue(notch.model.isExpanded)
    }

    func testDeployedTabFoldsWhenItsActivityEnds() {
        let notch = controller()
        move(notch, to: point(notch, tab: "claude"))
        wait("déployé") { notch.model.hoveredTab == "claude" }
        XCTAssertEqual(notch.model.hoveredTab, "claude")
        prefs.showEars = false
        wait("replié") { notch.model.hoveredTab == nil && notch.panel.ignoresMouseEvents }
        XCTAssertNil(notch.model.hoveredTab, "plus d'intercalaire : rien ne reste déployé")
        XCTAssertTrue(notch.panel.ignoresMouseEvents)
    }

    func testStateListsTheTabsByIdentifier() throws {
        let notch = controller()
        let info = try XCTUnwrap(notch.debugInfo["earTabs"] as? [String: Any])
        XCTAssertEqual(info["left"] as? [String], ["claude"])
        XCTAssertEqual(info["right"] as? [String], [])
        XCTAssertEqual(info["mode"] as? String, "visible")
        XCTAssertNil(info["hovered"])
        XCTAssertNil(notch.debugInfo["earsRotating"], "plus d'alternance")
    }
}
