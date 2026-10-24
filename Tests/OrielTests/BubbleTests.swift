import Combine
import CoreGraphics
import XCTest
@testable import Oriel

/// Notch détachée : machine à états, seuils de décollage et d'aimantation, écrans, barillet, goutte, réglages.
/// Logique pure, sans fenêtre.
final class BubbleTests: XCTestCase {
    /// MacBook Pro 14" : encoche de 185 × 32 pt au milieu, barre des menus de 37 pt.
    private static let builtin = ScreenCandidate(
        name: "Écran Retina intégré", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945), safeAreaTop: 32,
        auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5, isBuiltin: true)
    /// Écran externe à droite, plus haut.
    private static let external = ScreenCandidate(
        name: "DELL U2720Q", frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1415))
    private static let notch = CGRect(x: 663.5, y: 950, width: 185, height: 32)

    // MARK: - États

    func testPhaseTransitions() {
        XCTAssertEqual(BubblePhase.attached.next(.grab), .detaching)
        XCTAssertEqual(BubblePhase.detaching.next(.release(detached: false)), .attached, "relâché avant le seuil")
        XCTAssertEqual(BubblePhase.detaching.next(.release(detached: true)), .bubble)
        XCTAssertEqual(BubblePhase.bubble.next(.open), .bubblePanel)
        XCTAssertEqual(BubblePhase.bubblePanel.next(.close), .bubble)
        XCTAssertEqual(BubblePhase.bubble.next(.reattach), .reattaching)
        XCTAssertEqual(BubblePhase.bubblePanel.next(.reattach), .reattaching, "menu « … » du panneau de la bulle")
        XCTAssertEqual(BubblePhase.reattaching.next(.merged), .attached)
        for phase in [BubblePhase.attached, .detaching, .bubble, .bubblePanel, .reattaching] {
            XCTAssertEqual(phase.next(.reset), .attached, "\(phase)")
        }
        // Sans effet hors de leur état.
        XCTAssertEqual(BubblePhase.attached.next(.open), .attached)
        XCTAssertEqual(BubblePhase.attached.next(.reattach), .attached)
        XCTAssertEqual(BubblePhase.bubble.next(.grab), .bubble, "pas de second décollage")
        XCTAssertEqual(BubblePhase.reattaching.next(.open), .reattaching)
        XCTAssertEqual(BubblePhase.detaching.next(.open), .detaching)
    }

    /// La notch ne s'ouvre pas tant que la bulle la remplace ; le décollage en cours n'est pas encore une bulle.
    func testDetachedPhases() {
        XCTAssertEqual([BubblePhase.attached, .detaching, .bubble, .bubblePanel, .reattaching].map(\.isDetached),
                       [false, false, true, true, true])
    }

    // MARK: - Seuils et écrans

    func testDetachProgress() {
        XCTAssertEqual(Goo.progress(distance: 0), 0)
        XCTAssertEqual(Goo.progress(distance: BubbleGeometry.detachDistance / 2), 0.5, accuracy: 0.001)
        XCTAssertEqual(Goo.progress(distance: BubbleGeometry.detachDistance), 1)
        XCTAssertEqual(Goo.progress(distance: 1000), 1)
        XCTAssertEqual(Goo.progress(distance: -5), 0)
    }

    func testMagnetThreshold() {
        let dock = BubbleGeometry.dockPoint(notch: Self.notch)
        XCTAssertTrue(BubbleGeometry.isNearNotch(center: dock, notch: Self.notch))
        // Juste sous la notch, le plus haut que l'écran visible le permet.
        let highest = BubbleGeometry.clamp(CGPoint(x: Self.notch.midX, y: 2000),
                                           visibleFrames: [Self.builtin.visibleFrame])
        XCTAssertTrue(BubbleGeometry.isNearNotch(center: highest, notch: Self.notch))
        let edge = BubbleGeometry.radius + BubbleGeometry.magnetGap
        XCTAssertTrue(BubbleGeometry.isNearNotch(center: CGPoint(x: Self.notch.midX, y: Self.notch.minY - edge + 1),
                                                 notch: Self.notch))
        XCTAssertFalse(BubbleGeometry.isNearNotch(center: CGPoint(x: Self.notch.midX, y: Self.notch.minY - edge - 1),
                                                  notch: Self.notch))
        XCTAssertFalse(BubbleGeometry.isNearNotch(center: CGPoint(x: 200, y: 500), notch: Self.notch))
        // Aimantée : tirée vers la notch ; loin : inchangée.
        let near = CGPoint(x: Self.notch.midX + 40, y: dock.y - 10)
        let pulled = BubbleGeometry.magnetized(center: near, notch: Self.notch)
        XCTAssertLessThan(hypot(pulled.x - dock.x, pulled.y - dock.y), hypot(near.x - dock.x, near.y - dock.y))
        XCTAssertEqual(BubbleGeometry.magnetized(center: CGPoint(x: 200, y: 500), notch: Self.notch),
                       CGPoint(x: 200, y: 500))
    }

    func testClampToVisibleScreens() {
        let frames = [Self.builtin.visibleFrame, Self.external.visibleFrame]
        let inset = BubbleGeometry.radius + BubbleGeometry.screenInset
        XCTAssertEqual(BubbleGeometry.clamp(CGPoint(x: 700, y: 500), visibleFrames: frames), CGPoint(x: 700, y: 500))
        // Sous la barre des menus : redescend sous le haut de l'écran visible.
        XCTAssertEqual(BubbleGeometry.clamp(CGPoint(x: 700, y: 970), visibleFrames: frames),
                       CGPoint(x: 700, y: 945 - inset))
        // Hors de tout écran à gauche.
        XCTAssertEqual(BubbleGeometry.clamp(CGPoint(x: -300, y: 400), visibleFrames: frames), CGPoint(x: inset, y: 400))
        // Sur l'écran externe, plus bas que l'écran intégré : reste sur l'externe.
        XCTAssertEqual(BubbleGeometry.clamp(CGPoint(x: 2000, y: -100), visibleFrames: frames), CGPoint(x: 2000, y: -100))
        // Sous l'écran intégré, à côté de l'externe : le plus proche est l'externe.
        let below = BubbleGeometry.clamp(CGPoint(x: 1490, y: -100), visibleFrames: frames)
        XCTAssertEqual(below, CGPoint(x: 1512 + inset, y: -100))
        XCTAssertEqual(BubbleGeometry.clamp(CGPoint(x: 5, y: 5), visibleFrames: []), CGPoint(x: 5, y: 5))
    }

    func testPanelFrameStaysOnScreen() {
        let visible = Self.builtin.visibleFrame
        let size = CGSize(width: 560, height: 400)
        let middle = BubbleGeometry.panelFrame(size: size, bubble: CGPoint(x: 700, y: 600), visible: visible)
        XCTAssertEqual(middle.midX, 700)
        XCTAssertEqual(middle.maxY, 600 + BubbleGeometry.radius, "le haut au niveau du haut de la bulle")
        // Bulle en bas à droite : le panneau remonte et rentre dans l'écran.
        let corner = BubbleGeometry.panelFrame(size: size, bubble: CGPoint(x: 1450, y: 90), visible: visible)
        XCTAssertTrue(visible.contains(corner), "\(corner)")
    }

    // MARK: - Position par écran

    func testPositionIsRememberedPerScreen() throws {
        let screens = [Self.builtin, Self.external]
        let saved = try XCTUnwrap(BubblePlacement.save(center: CGPoint(x: 2100, y: 300), screens: screens))
        XCTAssertEqual(saved.label, "DELL U2720Q")
        XCTAssertEqual(saved.offset, [588, 500], "décalage depuis l'origine de l'écran")
        let onBuiltin = try XCTUnwrap(BubblePlacement.save(center: CGPoint(x: 400, y: 300), screens: screens))
        let positions = [saved.label: saved.offset, onBuiltin.label: onBuiltin.offset]

        // Dernier écran branché : sa position.
        let back = try XCTUnwrap(BubblePlacement.restore(screens: screens, notchScreen: 0, notch: Self.notch,
                                                         lastScreen: "DELL U2720Q", saved: positions))
        XCTAssertEqual(back.screen, 1)
        XCTAssertEqual(back.center, CGPoint(x: 2100, y: 300))
        // L'écran externe a bougé dans l'arrangement : la bulle reste au même endroit de cet écran.
        var moved = Self.external
        moved.frame.origin = CGPoint(x: -2560, y: 0)
        moved.visibleFrame.origin = CGPoint(x: -2560, y: 0)
        let follow = try XCTUnwrap(BubblePlacement.restore(screens: [Self.builtin, moved], notchScreen: 0,
                                                           notch: Self.notch, lastScreen: "DELL U2720Q",
                                                           saved: positions))
        XCTAssertEqual(follow.center, CGPoint(x: -2560 + 588, y: 500))
        // Écran débranché : celui de la notch, avec sa propre position.
        let unplugged = try XCTUnwrap(BubblePlacement.restore(screens: [Self.builtin], notchScreen: 0,
                                                              notch: Self.notch, lastScreen: "DELL U2720Q",
                                                              saved: positions))
        XCTAssertEqual(unplugged.screen, 0)
        XCTAssertEqual(unplugged.center, CGPoint(x: 400, y: 300))
        // Rien de rangé : sous la notch, à droite, dans l'écran visible.
        let fresh = try XCTUnwrap(BubblePlacement.restore(screens: [Self.builtin], notchScreen: 0, notch: Self.notch,
                                                          lastScreen: nil, saved: [:]))
        XCTAssertEqual(fresh.center, BubblePlacement.defaultCenter(notch: Self.notch))
        XCTAssertTrue(Self.builtin.visibleFrame.contains(fresh.center))
        // Valeur abîmée dans les réglages : ignorée.
        let broken = try XCTUnwrap(BubblePlacement.restore(screens: [Self.builtin], notchScreen: 0, notch: Self.notch,
                                                           lastScreen: nil,
                                                           saved: ["Écran Retina intégré": [.nan, 3]]))
        XCTAssertEqual(broken.center, fresh.center)
        // Position rangée hors de l'écran visible (Dock agrandi depuis) : ramenée dedans.
        let clamped = try XCTUnwrap(BubblePlacement.restore(screens: [Self.builtin], notchScreen: 0, notch: Self.notch,
                                                            lastScreen: nil,
                                                            saved: ["Écran Retina intégré": [5, 5]]))
        XCTAssertEqual(clamped.center, BubbleGeometry.clamp(CGPoint(x: 5, y: 5),
                                                            visibleFrames: [Self.builtin.visibleFrame]))
        XCTAssertNil(BubblePlacement.restore(screens: [], notchScreen: 0, notch: Self.notch, lastScreen: nil, saved: [:]))
    }

    func testPreferencesPersistBubble() {
        let defaults = makeEphemeralDefaults(self)
        let prefs = Preferences(defaults: defaults)
        XCTAssertTrue(prefs.allowsDetach, "activé par défaut")
        XCTAssertFalse(prefs.bubbleReturnsOnRelaunch)
        XCTAssertFalse(prefs.bubbleDetached)
        XCTAssertNil(prefs.bubbleScreen)
        XCTAssertEqual(prefs.bubblePositions, [:])

        prefs.allowsDetach = false
        prefs.bubbleReturnsOnRelaunch = true
        prefs.bubbleDetached = true
        prefs.bubbleScreen = "DELL U2720Q"
        prefs.bubblePositions = ["DELL U2720Q": [588, 500], "Écran Retina intégré": [400, 300]]
        let reread = Preferences(defaults: defaults)
        XCTAssertFalse(reread.allowsDetach)
        XCTAssertTrue(reread.bubbleReturnsOnRelaunch)
        XCTAssertTrue(reread.bubbleDetached)
        XCTAssertEqual(reread.bubbleScreen, "DELL U2720Q")
        XCTAssertEqual(reread.bubblePositions["DELL U2720Q"], [588, 500])

        // « Rétablir les réglages par défaut » : les réglages reviennent, pas l'état ni les positions de la bulle.
        reread.resetNotchSettings()
        XCTAssertTrue(reread.allowsDetach)
        XCTAssertFalse(reread.bubbleReturnsOnRelaunch)
        XCTAssertTrue(reread.bubbleDetached)
        XCTAssertEqual(reread.bubblePositions.count, 2)
    }

    // MARK: - Barillet

    func testRevolverGeometry() {
        for count in 4...10 {
            let revolver = Revolver(count: count, turn: 0)
            let center = CGPoint(x: 74, y: 74)
            let top = revolver.position(of: 0, center: center)
            XCTAssertEqual(top.x, 74, accuracy: 0.001, "onglet actif en haut (\(count))")
            XCTAssertEqual(top.y, 74 - Revolver.ringRadius, accuracy: 0.001)
            // Sens horaire : le suivant est à droite du haut.
            XCTAssertGreaterThan(revolver.position(of: 1, center: center).x, 74)
            // Les chambres ne se touchent pas et restent dans la bulle.
            let chamber = Revolver.chamberDiameter(count: count)
            let a = revolver.position(of: 0, center: center), b = revolver.position(of: 1, center: center)
            XCTAssertGreaterThan(hypot(a.x - b.x, a.y - b.y), chamber + 2, "\(count) onglets")
            XCTAssertLessThan(Revolver.ringRadius + chamber / 2, BubbleGeometry.radius - 4)
            XCTAssertGreaterThan(Revolver.ringRadius - chamber / 2, Revolver.hubRadius, "le moyeu ne touche pas")
        }
        XCTAssertEqual(Revolver.chamberDiameter(count: 4), 28)
        XCTAssertLessThan(Revolver.chamberDiameter(count: 10), 28)
    }

    func testRevolverTurnsByDetents() {
        var revolver = Revolver(count: 6, turn: 0)
        XCTAssertEqual(revolver.activeIndex, 0)
        revolver.rotate(by: 1)
        XCTAssertEqual(revolver.activeIndex, 1)
        XCTAssertEqual(revolver.angle(of: 1), 0, accuracy: 1e-9, "l'onglet 1 est en haut")
        revolver.rotate(by: -3)
        XCTAssertEqual(revolver.turn, -2)
        XCTAssertEqual(revolver.activeIndex, 4, "tour négatif ramené dans les onglets")
        revolver.rotate(by: 14)
        XCTAssertEqual(revolver.activeIndex, 0)
        XCTAssertEqual(revolver.rotation, -Double(revolver.turn) * revolver.step, accuracy: 1e-9)

        // Clic sur une chambre : le plus court chemin.
        let still = Revolver(count: 6, turn: 0)
        XCTAssertEqual(still.steps(toTop: 0), 0)
        XCTAssertEqual(still.steps(toTop: 1), 1)
        XCTAssertEqual(still.steps(toTop: 5), -1)
        XCTAssertEqual(still.steps(toTop: 3), 3, "à égalité : sens horaire")
        XCTAssertEqual(Revolver(count: 6, turn: -2).steps(toTop: 3), -1)
        XCTAssertEqual(Revolver(count: 7, turn: 0).steps(toTop: 4), -3)
        XCTAssertEqual(Revolver(count: 0, turn: 3).steps(toTop: 0), 0)
        XCTAssertEqual(Revolver(count: 0, turn: 3).activeIndex, 0)
    }

    func testRevolverZones() {
        let revolver = Revolver(count: 8, turn: 0)
        let center = CGPoint(x: 74, y: 74)
        XCTAssertEqual(revolver.zone(at: center, center: center), .hub)
        XCTAssertEqual(revolver.zone(at: revolver.position(of: 3, center: center), center: center), .chamber(3))
        XCTAssertEqual(Revolver(count: 8, turn: 3).zone(at: CGPoint(x: 74, y: 74 - Revolver.ringRadius), center: center),
                       .chamber(3), "la chambre du haut après trois crans")
        XCTAssertEqual(revolver.zone(at: CGPoint(x: 74, y: 3), center: center), .rim)
        XCTAssertEqual(revolver.zone(at: CGPoint(x: 2, y: 2), center: center), .outside)
    }

    func testScrollAccumulatesToDetents() {
        var scroll = RevolverScroll()
        // Trackpad : 28 pt par cran, le reste attend.
        XCTAssertEqual(scroll.add(deltaX: 0, deltaY: -10, precise: true), 0)
        XCTAssertEqual(scroll.add(deltaX: 0, deltaY: -10, precise: true), 0)
        XCTAssertEqual(scroll.add(deltaX: 0, deltaY: -10, precise: true), 1)
        XCTAssertEqual(scroll.add(deltaX: 0, deltaY: -60, precise: true), 2)
        // Demi-tour : le reste dans l'autre sens est oublié.
        XCTAssertEqual(scroll.add(deltaX: 0, deltaY: 20, precise: true), 0)
        XCTAssertEqual(scroll.add(deltaX: 0, deltaY: 10, precise: true), -1)
        // Molette : une ligne = un cran, quelle que soit sa taille.
        scroll.reset()
        XCTAssertEqual(scroll.add(deltaX: 0, deltaY: -0.1, precise: false), 1)
        XCTAssertEqual(scroll.add(deltaX: 0, deltaY: 3, precise: false), -1)
        // Glisser horizontal sur le trackpad.
        scroll.reset()
        XCTAssertEqual(scroll.add(deltaX: 30, deltaY: 2, precise: true), 1)
        XCTAssertEqual(scroll.add(deltaX: 0, deltaY: 0, precise: true), 0)
    }

    func testCircularDragTurnsByDetents() {
        let step = 2 * Double.pi / 6
        var drag = RevolverDrag(startAngle: 0, step: step)
        XCTAssertEqual(drag.move(to: step * 0.4), 0)
        XCTAssertEqual(drag.move(to: step * 0.6), -1, "sens horaire : l'onglet de gauche monte")
        XCTAssertEqual(drag.move(to: step * 1.4), 0)
        XCTAssertEqual(drag.move(to: step * 0.2), 1, "retour en arrière")
        // Plus d'un demi-tour, à travers ±π.
        var long = RevolverDrag(startAngle: 0, step: step)
        var total = 0
        for index in 1...24 { total += long.move(to: Double(index) * step / 4) }
        XCTAssertEqual(total, -6, "un tour complet = six crans")
        // À travers ±π (atan2) : 63° parcourus, pas un tour à l'envers.
        var wrap = RevolverDrag(startAngle: .pi - 0.3, step: step)
        XCTAssertEqual(wrap.move(to: -.pi + 0.8), -1)
        var none = RevolverDrag(startAngle: 0, step: 0)
        XCTAssertEqual(none.move(to: 1), 0)
    }

    // MARK: - Goutte

    func testNeckThinsUntilItSnaps() {
        func middle(_ p: CGFloat) -> CGFloat { Goo.neckRadius(t: 0.5, progress: p, start: 30, end: 40) }
        XCTAssertGreaterThan(middle(0.1), middle(0.5))
        XCTAssertGreaterThan(middle(0.5), middle(0.9))
        XCTAssertEqual(middle(1), Goo.neckFloor, accuracy: 0.001, "au seuil, le col est au plus fin, encore visible")
        XCTAssertGreaterThanOrEqual(Goo.neckFloor, Goo.blur * 0.7, "plus fin, le seuil l'effacerait avant la rupture")
        // Pincé au milieu, épais aux bouts.
        XCTAssertLessThan(Goo.neckRadius(t: 0.5, progress: 0.6, start: 30, end: 30),
                          Goo.neckRadius(t: 0.05, progress: 0.6, start: 30, end: 30))
        XCTAssertGreaterThan(Goo.dropRadius(progress: 1), Goo.dropRadius(progress: 0))
        XCTAssertEqual(Goo.dropRadius(progress: 1), BubbleGeometry.radius * 0.72, accuracy: 0.001,
                       "au seuil, la goutte a la taille de la bulle à son apparition (échelle 0,72)")
    }

    func testGooStagesFollowTheDrop() {
        let panel = CGRect(x: 100, y: -20, width: 540, height: 320)
        let notch = CGRect(x: 277, y: -20, width: 185, height: 52)
        let handle = CGPoint(x: 620, y: 290)
        let state = GooState(panel: panel, notch: notch, handle: handle, drop: CGPoint(x: 660, y: 360))
        let shapes = state.shapes(at: Date())
        XCTAssertEqual(shapes.drop.center, CGPoint(x: 660, y: 360))
        XCTAssertEqual(shapes.neck.count, Goo.neckCount)
        assertEqual(shapes.neck.last?.center ?? .zero, shapes.drop.center, "le col finit sur la goutte")
        XCTAssertTrue(shapes.body.insetBy(dx: -1, dy: -1).contains(shapes.neck[0].center), "et part du corps")
        // Le corps se replie vers la notch quand la goutte s'éloigne.
        let far = GooState(panel: panel, notch: notch, handle: handle, drop: CGPoint(x: 700, y: 400)).shapes(at: Date())
        XCTAssertLessThan(far.body.width, shapes.body.width)

        // Décollé : la goutte reste un instant sous la bulle qui la remplace (rien ne clignote si la fenêtre de la bulle
        // arrive une image plus tard), puis disparaît ; le corps rentre dans la notch et y repose.
        let start = Date()
        var snap = state
        snap.mode = .snap(start: start)
        XCTAssertEqual(snap.shapes(at: start).drop.radius, Goo.dropRadius(progress: 1), accuracy: 0.001)
        let gone = start.addingTimeInterval(Goo.snapDuration * Double(Goo.snapOverlap) + 0.001)
        XCTAssertEqual(snap.shapes(at: gone).drop.radius, 0)
        XCTAssertLessThan(Goo.snapDuration * Double(Goo.snapOverlap), 0.06, "trois images au plus à 60 i/s")
        let done = snap.shapes(at: start.addingTimeInterval(Goo.snapDuration))
        assertEqual(done.body, notch)
        XCTAssertTrue(done.neck.allSatisfy { $0.radius == 0 })
        var rest = state
        rest.mode = .rest
        XCTAssertEqual(rest.shapes(at: start), done, "au repos : la fin du décollage, dessin fixe")

        // Abandonné : la goutte revient à la poignée et disparaît, le corps redevient le panneau.
        var cancel = state
        cancel.mode = .cancel(start: start, from: state.drop, progress: state.progress)
        let back = cancel.shapes(at: start.addingTimeInterval(Goo.cancelDuration))
        XCTAssertEqual(back.drop.radius, 0, accuracy: 0.001)
        XCTAssertEqual(back.body, panel)

        // Détachement par le menu : la goutte va seule jusqu'au seuil.
        var auto = state
        auto.drop = handle
        auto.mode = .autoPull(start: start, to: CGPoint(x: handle.x, y: handle.y + BubbleGeometry.detachDistance))
        XCTAssertEqual(auto.shapes(at: start).drop.center, handle)
        let arrived = auto.shapes(at: start.addingTimeInterval(Goo.autoPullDuration))
        XCTAssertEqual(arrived.drop.center.y, handle.y + BubbleGeometry.detachDistance, accuracy: 0.001)
        XCTAssertEqual(arrived.drop.center.x, handle.x, accuracy: 0.001)
        XCTAssertEqual(arrived.drop.radius, Goo.dropRadius(progress: 1), accuracy: 0.001)
    }

    /// La goutte suit la souris sans être publiée : la vue la lit à chaque image (une seule image par rafraîchissement).
    func testGooReadsTheLiveDrop() {
        let goo = GooModel()
        XCTAssertNil(goo.shapes(at: Date()))
        goo.state = GooState(panel: CGRect(x: 0, y: -20, width: 400, height: 300),
                             notch: CGRect(x: 100, y: -20, width: 185, height: 52), handle: CGPoint(x: 380, y: 270),
                             drop: CGPoint(x: 380, y: 270))
        var published = 0
        let watch = goo.objectWillChange.sink { published += 1 }
        goo.liveDrop = CGPoint(x: 420, y: 330)
        XCTAssertEqual(published, 0)
        XCTAssertEqual(goo.shapes(at: Date())?.drop.center, CGPoint(x: 420, y: 330))
        watch.cancel()
    }

    // MARK: - Retour aimanté (ferrofluide)

    /// Comme un aimant : rien au-delà de la portée, 1 à l'aspiration, de plus en plus fort en approchant.
    func testMagnetStrengthGrowsAsTheGapShrinks() {
        XCTAssertEqual(Ferro.strength(gap: Ferro.reach), 0)
        XCTAssertEqual(Ferro.strength(gap: Ferro.reach + 100), 0)
        XCTAssertEqual(Ferro.strength(gap: Ferro.captureGap), 1)
        XCTAssertEqual(Ferro.strength(gap: 0), 1)
        var previous: CGFloat = -1, previousStep: CGFloat = 0
        for gap in stride(from: Ferro.reach, through: Ferro.captureGap, by: -2) {
            let s = Ferro.strength(gap: gap)
            XCTAssertGreaterThan(s, previous - 1e-9, "croissante quand l'écart diminue")
            if previous >= 0 { XCTAssertGreaterThanOrEqual(s - previous, previousStep - 1e-9, "et de plus en plus vite") }
            if previous >= 0 { previousStep = s - previous }
            previous = s
        }
    }

    /// La bulle suit la souris, tirée vers le bas de la notch d'autant plus qu'elle en est près, jamais au-delà.
    func testAttractionPullsTowardTheNotch() {
        let far = CGPoint(x: Self.notch.midX + 400, y: 500)
        let farPull = Ferro.attract(far, notch: Self.notch)
        XCTAssertEqual(farPull.center, far, "hors de portée : la souris seule")
        XCTAssertEqual(farPull.strength, 0)

        var lastPull: CGFloat = 0
        for gap in [140.0, 100, 70, 45, 30] as [CGFloat] {
            let center = CGPoint(x: Self.notch.midX + 20, y: Self.notch.minY - BubbleGeometry.radius - gap)
            let pulled = Ferro.attract(center, notch: Self.notch)
            let pull = hypot(pulled.center.x - center.x, pulled.center.y - center.y)
            XCTAssertGreaterThan(pull, lastPull, "écart \(gap)")
            XCTAssertGreaterThan(pulled.center.y, center.y, "vers la notch (en haut)")
            XCTAssertLessThan(pulled.gap, BubbleGeometry.gap(center: center, notch: Self.notch))
            XCTAssertGreaterThanOrEqual(pulled.gap, -0.001, "jamais dans la notch")
            lastPull = pull
        }
        XCTAssertLessThanOrEqual(lastPull, Ferro.maxPull + 0.001)
        // Collée sous la notch, le plus haut que l'écran visible permette : assez près pour être aspirée.
        let highest = BubbleGeometry.clamp(BubbleGeometry.dockPoint(notch: Self.notch),
                                           visibleFrames: [Self.builtin.visibleFrame])
        XCTAssertLessThanOrEqual(Ferro.attract(highest, notch: Self.notch).gap, Ferro.captureGap)
    }

    /// Lâchée dans le champ, elle se détend : un peu d'oscillation (elle s'aplatit), puis ronde.
    func testRelaxSettlesBackToRound() {
        XCTAssertEqual(Ferro.relax(from: 0.8, t: 0), 0.8, accuracy: 0.001)
        let samples = stride(from: 0.0, through: Ferro.relaxDuration, by: 0.01).map { Ferro.relax(from: 0.8, t: $0) }
        XCTAssertLessThan(samples.min() ?? 0, 0, "dépasse un peu : la bulle s'aplatit avant de redevenir ronde")
        XCTAssertGreaterThan(samples.min() ?? 0, -0.2, "un petit rebond, pas une seconde déformation")
        XCTAssertEqual(Ferro.relax(from: 0.8, t: Ferro.relaxDuration), 0)
        XCTAssertLessThan(abs(Ferro.relax(from: 0.8, t: Ferro.relaxDuration - 0.01)), 0.02, "pas de saut à la fin")
    }

    /// Contour : rond sans attraction ; attirée, tendu et hérissé de pointes vers la notch seulement.
    func testOutlineStretchesAndSpikesTowardTheNotch() {
        let r = BubbleGeometry.radius
        for delta in stride(from: 0.0, to: 2 * Double.pi, by: 0.3) {
            XCTAssertEqual(Ferro.outlineRadius(CGFloat(delta), radius: r, stretch: 0, spikes: 0, phase: 0), r,
                           accuracy: 0.001)
        }
        let front = Ferro.outlineRadius(0, radius: r, stretch: 0.16, spikes: Ferro.spikeHeight, phase: 0)
        let back = Ferro.outlineRadius(.pi, radius: r, stretch: 0.16, spikes: Ferro.spikeHeight, phase: 0)
        XCTAssertGreaterThan(front, r + Ferro.spikeHeight * 0.8, "pointe du milieu vers la notch")
        XCTAssertEqual(back, r, accuracy: 0.001, "l'arrière reste rond")
        // Entre deux pointes, le contour redescend : des pointes, pas une bosse.
        let between = Ferro.outlineRadius(Ferro.spikeSpacing / 2, radius: r, stretch: 0.16, spikes: Ferro.spikeHeight,
                                          phase: 0)
        XCTAssertLessThan(between, front - Ferro.spikeHeight * 0.5)
        // Le sommet de chaque pointe tombe sur un point du contour : les pointes ne scintillent pas en tournant.
        let step = 2 * CGFloat.pi / CGFloat(Ferro.samples)
        XCTAssertEqual((Ferro.spikeSpacing / step).rounded(), Ferro.spikeSpacing / step, accuracy: 1e-9)
        let outline = Ferro.outline(center: CGPoint(x: 200, y: 300), radius: r, toward: -.pi / 2, stretch: 0.16,
                                    spikes: Ferro.spikeHeight, phase: 0)
        XCTAssertEqual(outline.count, Ferro.samples)
        let top = outline.min { $0.y < $1.y }!
        XCTAssertEqual(top.x, 200, accuracy: 0.5, "la pointe la plus haute est sur l'axe de la notch")
        XCTAssertLessThan(top.y, 300 - r - Ferro.spikeHeight * 0.8)
    }

    /// Pont : la notch et la bulle s'avancent l'une vers l'autre et se touchent à `bridgeGap` ; le pont se forme alors
    /// (col nul, qui s'épaissit), grossit en approchant, s'étire en s'éloignant et ne casse qu'au-delà de `breakGap` ;
    /// rompu, les deux moitiés reviennent avec un ressort.
    func testBridgeFormsGrowsStretchesAndBreaks() {
        let notch = CGRect(x: 260, y: -20, width: 185, height: 52)
        func center(gap: CGFloat) -> CGPoint { CGPoint(x: notch.midX + 10, y: notch.maxY + BubbleGeometry.radius + gap) }
        // Avant le contact : les pointes approchent ; au contact, elles se touchent.
        XCTAssertEqual(Ferro.reachOut(gap: Ferro.reach, bridged: false), 0)
        XCTAssertEqual(Ferro.reachOut(gap: Ferro.bridgeGap, bridged: false), 1)
        func tips(gap: CGFloat) -> CGFloat {
            let shapes = Ferro.shapes(notch: notch, center: center(gap: gap), radius: BubbleGeometry.radius,
                                      reachOut: Ferro.reachOut(gap: gap, bridged: false), waist: 0,
                                      spikes: Ferro.spikeHeight, bulge: 0, phase: 0)
            let notchTip = shapes.cone.map { $0.y }.max() ?? notch.maxY
            return (shapes.outline.map { $0.y }.min() ?? 0) - notchTip
        }
        XCTAssertGreaterThan(tips(gap: 120), tips(gap: 90))
        XCTAssertGreaterThan(tips(gap: 90), 3, "pas encore en contact")
        XCTAssertEqual(tips(gap: Ferro.bridgeGap), 0, accuracy: 3, "les pointes se touchent (à leur ondulation près)")

        // Hystérésis : se forme au contact, tient étiré, casse au-delà.
        XCTAssertFalse(Ferro.isBridged(was: false, gap: Ferro.bridgeGap + 1))
        XCTAssertTrue(Ferro.isBridged(was: false, gap: Ferro.bridgeGap))
        XCTAssertTrue(Ferro.isBridged(was: true, gap: Ferro.breakGap - 1))
        XCTAssertFalse(Ferro.isBridged(was: true, gap: Ferro.breakGap + 1))
        XCTAssertGreaterThan(Ferro.waist(gap: 30), Ferro.waist(gap: 60), "plus épais tout près")
        XCTAssertLessThan(Ferro.waist(gap: Ferro.breakGap), 1.5, "un fil au moment de casser")

        let start = Date()
        var state = FerroState(notch: notch, center: center(gap: 140))
        state.move(to: center(gap: 140), strength: Ferro.strength(gap: 140), at: start)
        XCTAssertFalse(state.bridged)
        XCTAssertTrue(state.shapes(at: start).bridge.isEmpty)
        let formed = start.addingTimeInterval(0.5)
        state.move(to: center(gap: 60), strength: Ferro.strength(gap: 60), at: formed)
        XCTAssertTrue(state.bridged)
        XCTAssertEqual(state.waist(at: formed), 0, "le col part de rien")
        let thick = state.waist(at: formed.addingTimeInterval(Ferro.formDuration))
        XCTAssertEqual(thick, Ferro.waist(gap: state.gap), accuracy: 0.01)
        XCTAssertFalse(state.shapes(at: formed.addingTimeInterval(Ferro.formDuration)).bridge.isEmpty)
        // Plus près : plus épais.
        let later = formed.addingTimeInterval(1)
        state.move(to: center(gap: 35), strength: Ferro.strength(gap: 35), at: later)
        XCTAssertGreaterThan(state.waist(at: later), thick)
        // Le bas de la notch se bombe vers la bulle.
        XCTAssertGreaterThan(state.shapes(at: later).edge.map { $0.y }.max() ?? 0, notch.maxY + 2)
        // Éloignée : étirée, toujours pontée, puis rompue.
        state.move(to: center(gap: 95), strength: Ferro.strength(gap: 95), at: later)
        XCTAssertTrue(state.bridged)
        XCTAssertLessThan(state.waist(at: later), thick)
        let broke = later.addingTimeInterval(0.3)
        state.move(to: center(gap: 110), strength: Ferro.strength(gap: 110), at: broke)
        XCTAssertFalse(state.bridged)
        XCTAssertEqual(state.bridgeChanged, broke)
        let snapped = state.shapes(at: broke.addingTimeInterval(0.02))
        XCTAssertTrue(snapped.bridge.isEmpty, "rompu : plus de pont")
        let rest = state.shapes(at: broke.addingTimeInterval(Ferro.breakDuration))
        XCTAssertLessThan(snapped.outline.map { $0.y }.min()!, rest.outline.map { $0.y }.min()!,
                          "la moitié de la bulle revient vers elle")
    }

    /// Aspiration : elle part de l'état du pont (rien ne saute), la bulle accélère vers la notch, rétrécit, le
    /// barillet s'efface, le pont s'élargit ; puis une onde court sur le bord de la notch vers les coins et s'éteint.
    func testAspirationMergesWithARipple() {
        let notch = CGRect(x: 260, y: -20, width: 185, height: 52)
        let from = CGPoint(x: 380, y: notch.maxY + BubbleGeometry.radius + 30)
        let start = Date()
        var state = FerroState(notch: notch, center: from)
        state.move(to: from, strength: Ferro.strength(gap: 30), at: start.addingTimeInterval(-1))
        XCTAssertTrue(state.bridged)
        let approach = state.shapes(at: start)
        state.mode = .aspirate(start: start, from: from)
        func at(_ t: Double) -> FerroShapes { state.shapes(at: start.addingTimeInterval(t * Ferro.aspirateDuration)) }
        XCTAssertEqual(at(0), approach, "aucun saut au début de l'aspiration")
        // Accélère : moins de chemin dans la première moitié que dans la seconde.
        let travel1 = from.y - at(0.5).center.y, travel2 = at(0.5).center.y - at(0.99).center.y
        XCTAssertLessThan(travel1, travel2)
        XCTAssertLessThan(at(0.5).radius, at(0.2).radius)
        XCTAssertEqual(at(0.4).contentOpacity, 0, "le barillet s'est effacé")
        XCTAssertTrue(at(1).outline.isEmpty, "avalée")
        for t in stride(from: 0.0, to: 1, by: 0.05) {
            let top = at(t).bridge.filter { $0.y <= notch.maxY + 0.01 }
            XCTAssertGreaterThan(top.map { $0.x }.min() ?? notch.midX, notch.minX, "pont dans la notch, t \(t)")
            XCTAssertLessThan(top.map { $0.x }.max() ?? notch.midX, notch.maxX, "pont dans la notch, t \(t)")
        }
        // L'onde s'éloigne du point d'arrivée, vers les coins, et s'amortit.
        let arrival = Ferro.base(notch: notch, bottom: notch.maxY, toward: from).x
        func crest(_ t: Double) -> CGFloat {
            let right = at(t).edge.filter { $0.x > arrival + 10 }
            return right.max { $0.y < $1.y }?.x ?? arrival
        }
        XCTAssertGreaterThan(crest(1.25), crest(1.1))
        XCTAssertFalse(at(1.1).edge.isEmpty)
        let end = state.shapes(at: start.addingTimeInterval(FerroState.aspirateTotal))
        XCTAssertTrue(end.edge.isEmpty && end.outline.isEmpty && end.cone.isEmpty && end.bridge.isEmpty)
    }

    /// Le champ couvre la notch et toute bulle attirée (gardée sous la barre des menus, puis tirée), marge comprise :
    /// la fenêtre ne bouge plus. Au-dessus du haut de l'écran, rien n'est dessiné.
    func testFieldCoversEveryAttractedBubble() {
        let field = Ferro.fieldFrame(notch: Self.notch)
        XCTAssertTrue(field.contains(Self.notch))
        XCTAssertEqual(field.maxY, Self.builtin.frame.maxY, "collé en haut de l'écran")
        let margin = BubbleGeometry.radius + BubbleGeometry.windowMargin
        for angle in stride(from: 0.0, to: 2 * Double.pi, by: 0.1) {
            for distance in [BubbleGeometry.radius + Ferro.reach - 0.5, BubbleGeometry.radius + 60] {
                let wanted = BubbleGeometry.clamp(CGPoint(x: Self.notch.midX + distance * CGFloat(cos(angle)),
                                                          y: Self.notch.minY + distance * CGFloat(sin(angle))),
                                                  visibleFrames: [Self.builtin.visibleFrame])
                let pulled = Ferro.attract(wanted, notch: Self.notch)
                guard pulled.strength > 0 else { continue }
                let center = pulled.center
                XCTAssertGreaterThanOrEqual(center.x - margin, field.minX, "angle \(angle)")
                XCTAssertLessThanOrEqual(center.x + margin, field.maxX, "angle \(angle)")
                XCTAssertGreaterThanOrEqual(center.y - margin, field.minY, "angle \(angle)")
                XCTAssertLessThanOrEqual(center.y + BubbleGeometry.radius, field.maxY, "angle \(angle)")
            }
        }
    }

    // MARK: - Contrôleur (sans fenêtre à l'écran)

    /// Même niveau, mêmes Spaces et même confidentialité que la notch ; la fenêtre n'est jamais affichée ici.
    func testBubbleWindowMatchesTheNotchWindow() {
        let notch = NotchHarness(self)
        let controller = BubbleController(model: notch.model, prefs: notch.prefs, registry: notch.registry,
                                          store: notch.store)
        XCTAssertEqual(controller.window.level, NotchController.windowLevel, "isFloatingPanel posé avant level")
        XCTAssertTrue(controller.window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(controller.window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(controller.window.isVisible)
        XCTAssertEqual(controller.window.sharingType, .readOnly)
        notch.prefs.hideFromCapture = true
        XCTAssertEqual(controller.window.sharingType, .none)
    }

    /// Le barillet et l'onglet actif restent liés, dans les deux sens.
    func testRevolverFollowsTheSelectedTab() {
        let notch = NotchHarness(self)
        let controller = BubbleController(model: notch.model, prefs: notch.prefs, registry: notch.registry,
                                          store: notch.store)
        let ids = notch.registry.enabled.map { $0.id }
        XCTAssertGreaterThan(ids.count, 4)
        notch.model.selectedTab = ids[0]
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        controller.rotate(by: 2)
        XCTAssertEqual(notch.model.selectedTab, ids[0], "attachée : le barillet ne tourne pas")
        notch.model.bubble = .bubble
        controller.rotate(by: 2)
        XCTAssertEqual(notch.model.selectedTab, ids[2])
        controller.rotate(by: -3)
        XCTAssertEqual(notch.model.selectedTab, ids[ids.count - 1], "dans l'autre sens, en bouclant")

        // Onglet changé ailleurs (barre d'onglets du panneau, raccourci) : il vient en haut par le plus court.
        notch.model.selectedTab = ids[1]
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(Revolver(count: ids.count, turn: controller.bubble.turn).activeIndex, 1)
        XCTAssertEqual(controller.bubble.turn, 1, "deux crans en avant depuis −1, pas un tour complet")
    }

    /// Notch détachée, la barre de commande s'ouvre dans le panneau de la bulle : elle se referme avec lui (sans quoi
    /// le prochain panneau, de la bulle ou de la notch, rouvrirait la barre). La fenêtre n'est jamais affichée ici.
    func testCommandBarClosesWithTheBubblePanel() {
        let notch = NotchHarness(self)
        let controller = BubbleController(model: notch.model, prefs: notch.prefs, registry: notch.registry,
                                          store: notch.store)
        notch.model.bubble = .bubblePanel
        notch.model.isCommandBarOpen = true
        controller.close()
        XCTAssertEqual(notch.model.bubble, .bubble)
        XCTAssertFalse(notch.model.isCommandBarOpen)
        XCTAssertFalse(controller.window.isVisible)
    }

    /// L'angle se montre aux trois premières ouvertures du panneau, plus jamais ensuite ni une fois le geste trouvé ;
    /// le compte survit au redémarrage.
    func testHandleHintShowsOnlyAtFirst() {
        let defaults = makeEphemeralDefaults(self)
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual((0..<5).map { _ in prefs.takeHandleHint() }, [true, true, true, false, false])
        XCTAssertFalse(Preferences(defaults: defaults).takeHandleHint())
        let other = Preferences(defaults: makeEphemeralDefaults(self))
        XCTAssertTrue(other.takeHandleHint())
        other.bubbleHandleHints = Preferences.handleHintCount
        XCTAssertFalse(other.takeHandleHint())
    }

    /// Aucun état sans issue : de chaque phase, des gestes de l'utilisateur ramènent à la notch.
    func testEveryPhaseHasAWayOut() {
        let events: [BubblePhase.Event] = [.grab, .release(detached: false), .release(detached: true), .open, .close,
                                           .reattach, .merged]
        for phase in [BubblePhase.attached, .detaching, .bubble, .bubblePanel, .reattaching] {
            var seen: Set<BubblePhase> = [phase], queue = [phase]
            while let current = queue.popLast() {
                for next in events.map(current.next) where !seen.contains(next) {
                    seen.insert(next)
                    queue.append(next)
                }
            }
            XCTAssertTrue(seen.contains(.attached), "\(phase)")
        }
        XCTAssertEqual(BubblePhase.bubblePanel.next(.close), .bubble, "du panneau, retour au barillet")
    }

    /// Panneau ouvert depuis le barillet : le bouton retour (comme Échap, le pincement et le clic à l'extérieur) sort du
    /// mode édition, puis referme le panneau en barillet. Le clic à l'extérieur le fait même sans « Fermer au clic à
    /// l'extérieur ». La fenêtre n'est jamais affichée ici.
    func testBackReturnsToTheRevolver() {
        let notch = NotchHarness(self)
        let controller = BubbleController(model: notch.model, prefs: notch.prefs, registry: notch.registry,
                                          store: notch.store)
        var actions = NotchActions()
        actions.detach = {}
        controller.start(actions: actions)
        notch.model.bubble = .bubblePanel
        notch.model.isEditingTabs = true
        controller.back()
        XCTAssertFalse(notch.model.isEditingTabs, "d'abord sortir du mode édition")
        XCTAssertEqual(notch.model.bubble, .bubblePanel)
        controller.back()
        XCTAssertEqual(notch.model.bubble, .bubble, "puis le barillet")
        controller.back()
        XCTAssertEqual(notch.model.bubble, .bubble, "sans effet sur le barillet")

        notch.prefs.closeOnClickOutside = false
        notch.model.bubble = .bubblePanel
        controller.mouseDown(at: CGPoint(x: -5000, y: -5000))
        XCTAssertEqual(notch.model.bubble, .bubble)
        XCTAssertFalse(controller.window.isVisible)
    }

    private func assertEqual(_ a: CGPoint, _ b: CGPoint, _ message: String = "", line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.001, message, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.001, message, line: line)
    }

    private func assertEqual(_ a: CGRect, _ b: CGRect, line: UInt = #line) {
        assertEqual(a.origin, b.origin, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: 0.001, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: 0.001, line: line)
    }

    func testGooCoordinates() {
        let local = GooCoordinates(CGRect(x: 100, y: 500, width: 400, height: 300))
        XCTAssertEqual(local.point(CGPoint(x: 150, y: 790)), CGPoint(x: 50, y: 10), "y vers le bas depuis le haut")
        // Forme collée en haut de l'écran : prolongée au-dessus de la fenêtre.
        let body = local.body(CGRect(x: 200, y: 700, width: 100, height: 70))
        XCTAssertEqual(body.minX, 100)
        XCTAssertLessThan(body.minY, 0)
        XCTAssertEqual(body.maxY, 100, "bas de la forme : 800 − 700")
    }
}
