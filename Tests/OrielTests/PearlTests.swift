import AppKit
import XCTest
@testable import Oriel

/// Style « perle » des écrans sans encoche : géométrie, état éveillé / endormi (délais, hystérésis) et contrôleur
/// (zone qui réveille, clics laissés à la barre des menus, ouverture du panneau).
final class PearlGeometryTests: XCTestCase {
    private let notch = CGRect(x: 860, y: 1056, width: 200, height: 24)
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func testPearlSizeAndPlace() {
        XCTAssertEqual(Pearl.size(for: nil), CGSize(width: 44, height: 20), "la place vide a la taille d'une perle")
        let one = EarTab(id: "claude", kind: .claude(.working), priority: 100, text: "3", bars: false, isAlert: false)
        XCTAssertEqual(Pearl.size(for: one), CGSize(width: 44, height: 20), "icône et un chiffre : 44 × 20")
        let long = EarTab(id: "timer", kind: .claude(.working), priority: 5, text: "12:34:56", bars: false, isAlert: false)
        XCTAssertGreaterThan(Pearl.size(for: long).width, 44, "une information longue élargit la perle")
        XCTAssertLessThanOrEqual(Pearl.size(for: long).width, Pearl.maxWidth, "pas plus que le maximum")

        let rect = Pearl.rect(in: notch, size: Pearl.size(for: one))
        XCTAssertEqual(rect, CGRect(x: 938, y: 1060, width: 44, height: 20), "centrée, collée au haut de l'écran")
        XCTAssertEqual(rect.maxY, notch.maxY)
    }

    func testPearlShowsAnAlertFirstThenTheTopPriority() {
        func tab(_ id: String, _ priority: Int, alert: Bool = false) -> EarTab {
            EarTab(id: id, kind: .claude(.working), priority: priority, text: "", bars: false, isAlert: alert)
        }
        XCTAssertNil(Pearl.shown(in: []))
        XCTAssertEqual(Pearl.shown(in: [tab("a", 100), tab("b", 5)])?.id, "a")
        XCTAssertEqual(Pearl.shown(in: [tab("a", 5), tab("b", 100)])?.id, "b")
        XCTAssertEqual(Pearl.shown(in: [tab("a", 100), tab("b", 5, alert: true)])?.id, "b", "une alerte d'abord")
        XCTAssertEqual(Pearl.shown(in: [tab("a", 7), tab("b", 7)])?.id, "a", "à égalité, la première")
    }

    /// La zone est étroite : 12 pt de chaque côté, 4 pt sous la perle ; un menu voisin n'y entre pas.
    func testZoneIsNarrow() {
        let rect = Pearl.rect(in: notch, size: Pearl.size(for: nil))
        let zone = Pearl.zone(around: rect)
        XCTAssertEqual(zone.width, 44 + 24)
        XCTAssertEqual(zone.height, 20 + 4 + 1)
        XCTAssertTrue(Pearl.contains(zone, CGPoint(x: rect.midX, y: notch.maxY)), "pile sur le bord haut de l'écran")
        XCTAssertFalse(Pearl.contains(zone, CGPoint(x: rect.midX + 60, y: notch.maxY - 4)), "un menu à 60 pt")
        XCTAssertFalse(Pearl.contains(zone, CGPoint(x: rect.midX, y: notch.maxY - 30)), "sous la barre des menus")
        XCTAssertLessThan(zone.width, notch.width / 2, "plus étroite que l'encoche éveillée")
    }

    func testPresenceNeedsIntentionToWakeAndToSleep() {
        var presence = Pearl.Presence()
        XCTAssertFalse(presence.isAwake)
        XCTAssertNil(presence.update(near: false, now: t0), "loin : rien à faire")

        // Traverser la zone sans s'y arrêter ne réveille rien.
        XCTAssertEqual(presence.update(near: true, now: t0), t0.addingTimeInterval(Pearl.wakeDelay))
        XCTAssertFalse(presence.isAwake)
        XCTAssertNil(presence.update(near: false, now: t0.addingTimeInterval(0.05)))
        XCTAssertFalse(presence.isAwake)

        // Restée dans la zone assez longtemps : éveillée.
        _ = presence.update(near: true, now: t0.addingTimeInterval(1))
        XCTAssertNil(presence.update(near: true, now: t0.addingTimeInterval(1 + Pearl.wakeDelay)))
        XCTAssertTrue(presence.isAwake)

        // Un écart court ne la rendort pas.
        XCTAssertEqual(presence.update(near: false, now: t0.addingTimeInterval(2)),
                       t0.addingTimeInterval(2 + Pearl.sleepDelay))
        XCTAssertTrue(presence.isAwake)
        XCTAssertNil(presence.update(near: true, now: t0.addingTimeInterval(2.1)))
        XCTAssertTrue(presence.isAwake)
        // Dehors assez longtemps : endormie.
        _ = presence.update(near: false, now: t0.addingTimeInterval(3))
        XCTAssertNil(presence.update(near: false, now: t0.addingTimeInterval(3 + Pearl.sleepDelay)))
        XCTAssertFalse(presence.isAwake)
    }

    /// Souris posée sur la limite de la zone : elle va et vient à chaque événement, la perle ne clignote jamais.
    func testNoFlickerAtTheZoneEdge() {
        var presence = Pearl.Presence()
        var changes = 0
        var wasAwake = false
        for step in 0..<200 {
            let now = t0.addingTimeInterval(Double(step) * 0.01)
            _ = presence.update(near: step.isMultiple(of: 2), now: now)
            if presence.isAwake != wasAwake {
                changes += 1
                wasAwake = presence.isAwake
            }
        }
        XCTAssertEqual(changes, 0, "dedans un événement sur deux : l'intention n'est jamais continue")

        // Éveillée, même va-et-vient : elle reste éveillée.
        presence.wake()
        for step in 0..<200 {
            _ = presence.update(near: step.isMultiple(of: 2), now: t0.addingTimeInterval(10 + Double(step) * 0.01))
            XCTAssertTrue(presence.isAwake)
        }
    }
}

final class PearlControllerTests: XCTestCase {
    /// Écran externe sans encoche, barre des menus de 24 pt.
    private static let screen = ScreenCandidate(
        name: "Écran externe", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1056))

    private func prefs(_ configure: (Preferences) -> Void = { _ in }) -> Preferences {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.hapticFeedback = false
        prefs.virtualNotchStyle = .pearl
        configure(prefs)
        return prefs
    }

    private func controller(_ prefs: Preferences, store: SessionStore = SessionStore(),
                            screen: ScreenCandidate = PearlControllerTests.screen) -> NotchController {
        _ = NSApplication.shared
        let notch = NotchController(store: store, monitor: ClaudeMonitor(), prefs: prefs,
                                    tools: ToolsFeed(paths: LayoutTests.absentPaths))
        notch.screens = { [screen] }
        addTeardownBlock { notch.panel.orderOut(nil) }
        notch.panel.alphaValue = 0
        notch.togglePanelFromKeyboard()
        notch.togglePanelFromKeyboard()
        XCTAssertFalse(notch.model.isExpanded)
        move(notch, to: CGPoint(x: -50_000, y: -50_000))
        // Refermée au raccourci, la perle est encore éveillée : elle se rendort, souris loin.
        XCTAssertTrue(spin(timeout: 3) { !notch.model.pearlAwake }, "perle rendormie")
        return notch
    }

    private func move(_ notch: NotchController, to point: CGPoint) {
        notch.mouseLocation = { point }
        notch.mouseMoved()
    }

    private var top: CGFloat { Self.screen.frame.maxY }
    private var midX: CGFloat { Self.screen.frame.midX }

    /// Fin de l'assistant (C05) : sans encoche, en perle, la notch se montre (perle éveillée = la condition d'opacité
    /// de la vue), puis se rendort toute seule souris loin.
    func testRevealOnceWakesThePearlThenItSleepsAgain() {
        let notch = controller(prefs())
        XCTAssertFalse(notch.model.pearlAwake)
        notch.revealOnce()
        XCTAssertTrue(notch.model.pearlAwake, "visible : perle éveillée")
        XCTAssertTrue(spin(timeout: 3) { !notch.model.pearlAwake }, "rendormie, comme après un survol")
    }

    func testRevealOnceChangesNothingForOtherStylesOrWithANotch() {
        let pill = controller(prefs { $0.virtualNotchStyle = .pill })
        pill.revealOnce()
        XCTAssertFalse(pill.model.pearlAwake, "pas de perle : rien à réveiller")
        let real = ScreenCandidate(name: "Intégré", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945), safeAreaTop: 32,
                                   auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5, isBuiltin: true)
        let withNotch = controller(prefs(), screen: real)
        XCTAssertTrue(withNotch.model.hasNotch)
        withNotch.revealOnce()
        XCTAssertFalse(withNotch.model.pearlAwake, "avec encoche : la perle n'existe pas")
    }

    func testTheFakeScreenHasNoNotch() {
        let notch = controller(prefs())
        XCTAssertFalse(notch.model.hasNotch)
        XCTAssertEqual(notch.model.notchSize, CGSize(width: NotchScreenPicker.virtualNotchWidth, height: 24))
        XCTAssertFalse(notch.model.pearlAwake, "au repos, endormie")
    }

    /// Le test de clic : endormie, seule la zone étroite de la perle compte ; tout le reste de la barre des menus
    /// (menus, icônes, bord de l'encoche virtuelle) n'est pas à nous, y compris là où l'encoche éveillée s'étendrait.
    func testSleepingPearlLeavesTheMenuBarAlone() {
        let notch = controller(prefs(), store: .working(1))
        XCTAssertEqual(notch.collapsedHit(CGPoint(x: midX, y: top - 4)), .notch, "sur la perle")
        XCTAssertEqual(notch.collapsedHit(CGPoint(x: midX, y: top)), .notch, "pile sur le bord haut")
        XCTAssertEqual(notch.collapsedHit(CGPoint(x: midX + 30, y: top - 4)), .notch, "dans la marge de proximité")
        for dx: CGFloat in [-400, -150, -99, -60, 60, 99, 150, 400] {
            XCTAssertEqual(notch.collapsedHit(CGPoint(x: midX + dx, y: top - 10)), .none, "menu voisin à \(dx) pt")
        }
        XCTAssertEqual(notch.collapsedHit(CGPoint(x: midX, y: top - 40)), .none, "sous la barre des menus")
        XCTAssertTrue(notch.panel.ignoresMouseEvents, "la fenêtre laisse passer tous les clics")

        // Un clic (ou un passage) hors de la zone ne déclenche rien : ni réveil, ni ouverture.
        move(notch, to: CGPoint(x: midX + 99, y: top - 10))
        notch.mouseDown(at: CGPoint(x: midX + 99, y: top - 10))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(notch.model.pearlAwake)
        XCTAssertFalse(notch.model.isExpanded)
    }

    func testPearlWakesThenOpensThenGoesBack() {
        let notch = controller(prefs { $0.openDelay = 0.3 }, store: .working(1))
        let onPearl = CGPoint(x: midX, y: top - 5)
        move(notch, to: onPearl)
        XCTAssertFalse(notch.model.pearlAwake, "délai d'intention : traverser ne réveille pas")
        XCTAssertTrue(spin(timeout: 3) { notch.model.pearlAwake }, "souris posée sur la perle : caméléon")
        XCTAssertFalse(notch.model.isExpanded, "le panneau attend son délai, après le réveil")
        XCTAssertTrue(spin(timeout: 3) { notch.model.isExpanded }, "puis le panneau s'ouvre")

        // Encoche éveillée, large : un point à 90 pt du centre est dessus.
        move(notch, to: CGPoint(x: midX, y: top - 600))
        XCTAssertTrue(spin(timeout: 3) { !notch.model.isExpanded }, "souris partie : le panneau se replie")
        XCTAssertTrue(spin(timeout: 3) { !notch.model.pearlAwake }, "retour à la perle")
        XCTAssertTrue(notch.panel.ignoresMouseEvents)
    }

    /// Éveillée, l'encoche (200 pt) garde la perle éveillée tant que la souris est dessus, et seulement elle.
    func testAwakeNotchHoldsTheMouseThenReleasesIt() {
        let notch = controller(prefs { $0.openTrigger = .click }, store: .working(1))
        move(notch, to: CGPoint(x: midX, y: top - 5))
        XCTAssertTrue(spin(timeout: 3) { notch.model.pearlAwake })

        let onAwakeNotch = CGPoint(x: midX + 90, y: top - 10)
        XCTAssertEqual(notch.collapsedHit(onAwakeNotch), .notch, "éveillée, l'encoche s'étend jusqu'à 100 pt")
        move(notch, to: onAwakeNotch)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(notch.model.pearlAwake, "sur l'encoche éveillée : elle reste")
        XCTAssertFalse(notch.model.isExpanded, "mode « au clic » : le survol n'ouvre rien")

        // Un écart de quelques ms hors de l'encoche ne la rendort pas.
        move(notch, to: CGPoint(x: midX + 140, y: top - 10))
        move(notch, to: onAwakeNotch)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(notch.model.pearlAwake)

        move(notch, to: CGPoint(x: midX + 140, y: top - 10))
        XCTAssertTrue(spin(timeout: 3) { !notch.model.pearlAwake }, "dehors : retour à la perle")
        XCTAssertEqual(notch.collapsedHit(onAwakeNotch), .none)
    }

    /// Sans activité : rien de dessiné, mais la place vide réveille quand même le caméléon.
    func testEmptyPlaceStillWakes() {
        let notch = controller(prefs { $0.openTrigger = .click })
        move(notch, to: CGPoint(x: midX, y: top - 5))
        XCTAssertTrue(spin(timeout: 3) { notch.model.pearlAwake })
    }

    func testClickOpensDirectlyInClickMode() {
        let notch = controller(prefs { $0.openTrigger = .click })
        let onPearl = CGPoint(x: midX, y: top - 5)
        notch.mouseLocation = { onPearl }
        notch.mouseDown(at: onPearl)
        XCTAssertTrue(notch.model.isExpanded)
        XCTAssertTrue(notch.model.pearlAwake, "ouverte sans attendre le délai : éveillée d'emblée")
    }

    /// Écran externe rangé au-dessus du MacBook : un point au-dessus de cet écran n'est pas sur l'encoche (il l'ouvrait,
    /// puis la refermait, à l'infini). Le bord haut de l'écran, lui, la touche toujours.
    func testPointAboveTheScreenHitsNothingButTheTopEdgeStillHitsTheNotch() {
        let notch = controller(prefs { $0.virtualNotchStyle = .chameleon }, store: .working(1))
        XCTAssertEqual(notch.collapsedHit(CGPoint(x: midX, y: top + 400)), .none, "écran au-dessus")
        XCTAssertEqual(notch.collapsedHit(CGPoint(x: midX, y: top + 1)), .none, "juste au-dessus")
        XCTAssertEqual(notch.collapsedHit(CGPoint(x: midX, y: top)), .notch, "pile sur le bord haut de l'écran")
        XCTAssertEqual(notch.collapsedHit(CGPoint(x: midX, y: top - 4)), .notch, "sur l'encoche")
    }

    /// Les autres styles et une vraie encoche ne connaissent pas la perle.
    func testOtherStylesNeverWake() {
        let notch = controller(prefs { $0.virtualNotchStyle = .chameleon }, store: .working(1))
        move(notch, to: CGPoint(x: midX, y: top - 5))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(notch.model.pearlAwake)
        XCTAssertEqual(notch.collapsedHit(CGPoint(x: midX + 90, y: top - 10)), .notch, "chameleon : 200 pt comme avant")
    }
}
