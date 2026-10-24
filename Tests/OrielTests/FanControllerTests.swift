import AppKit
import FanControl
import XCTest
@testable import Oriel

/// Ventilateurs dans l'onglet Réglages rapides : lecture seulement onglet affiché, vitesse fixe bornée, installation
/// au premier usage, retours en automatique (demande, outil, veille, session, arrêt, plantage), reprise au
/// lancement. Doubles seulement : aucun outil, aucun sudo, aucune écriture dans le SMC.
final class FanControllerTests: XCTestCase {
    private var backend: QSFakeFans!
    private var defaults: UserDefaults!
    private var workspace: NotificationCenter!
    private var issues: [QuickSettingsIssue] = []
    /// Minuteurs créés par le contrôleur : jamais planifiés, le test les déclenche à la main (aucune attente réelle).
    private var timers: [Timer] = []

    override func setUp() {
        backend = QSFakeFans()
        defaults = makeEphemeralDefaults(self)
        workspace = NotificationCenter()
        issues = []
        timers = []
    }

    private func controller(readInterval: TimeInterval = 60, heartbeat: TimeInterval = 60) -> FanController {
        let fans = FanController(backend: backend, defaults: defaults, readInterval: readInterval,
                                 heartbeatInterval: heartbeat, workspace: workspace,
                                 makeTimer: { [weak self] interval, _, fire in
                                     let timer = Timer(timeInterval: interval, repeats: true) { _ in fire() }
                                     self?.timers.append(timer)
                                     return timer
                                 })
        fans.report = { [weak self] in self?.issues.append($0) }
        return fans
    }

    /// Démarré, onglet affiché, vitesse fixe à `rpm` demandée.
    private func fixed(_ rpm: Int = 4000) -> FanController {
        let fans = controller()
        fans.start()
        fans.viewAppeared()
        fans.setFixed(rpm: rpm)
        return fans
    }

    // MARK: - Lecture

    func testReadsOnlyWhileTheTabIsVisible() throws {
        let fans = controller(readInterval: 2)
        fans.start()
        XCTAssertEqual(backend.reads, 0, "rien avant l'affichage de l'onglet")
        XCTAssertTrue(timers.isEmpty)
        XCTAssertNil(fans.status)
        fans.viewAppeared()
        XCTAssertEqual(backend.reads, 1)
        XCTAssertEqual(fans.status, QSFakeFans.macBookPro())
        let timer = try XCTUnwrap(timers.first)
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timer.timeInterval, 2)
        for tick in 1...3 { timer.fire(); XCTAssertEqual(backend.reads, 1 + tick, "rafraîchi à chaque top tant que l'onglet est affiché") }
        fans.viewDisappeared()
        XCTAssertFalse(timer.isValid, "plus rien onglet masqué (panneau replié)")
    }

    /// Mac sans ventilateur : pas de statut, donc pas de carte ni de vitesse fixe.
    func testNoFansMeansNoCard() {
        backend.status = nil
        let fans = controller()
        fans.viewAppeared()
        XCTAssertNil(fans.status)
        XCTAssertFalse(fans.canFix)
        fans.setFixed(rpm: 4000)
        XCTAssertEqual(backend.holds, 0)
    }

    /// Lecture seule si le Mac ne permet pas le mode manuel (Intel) ou si l'outil n'est pas livré.
    func testFixedSpeedNeedsManualSupportAndTheBundledTool() {
        backend.status?.supportsManual = false
        let fans = controller()
        fans.viewAppeared()
        XCTAssertFalse(fans.canFix)
        backend.status?.supportsManual = true
        fans.read()
        XCTAssertTrue(fans.canFix)
        backend.canInstall = false
        XCTAssertFalse(fans.canFix)
    }

    // MARK: - Vitesse fixe

    func testFixedSpeedStartsAHoldAndSetsEveryFan() {
        let fans = fixed(4000)
        XCTAssertEqual(backend.holds, 1)
        XCTAssertEqual(backend.sent, ["fan 0 4000", "fan 1 4000"])
        XCTAssertEqual(fans.mode, .fixed(rpm: 4000))
        XCTAssertTrue(fans.isFixed)
        XCTAssertTrue(defaults.bool(forKey: FanController.manualFlagKey), "noté pour la reprise après un arrêt brutal")
        fans.setFixed(rpm: 5000)
        XCTAssertEqual(backend.holds, 1, "même tenue")
        XCTAssertEqual(Array(backend.sent.suffix(2)), ["fan 0 5000", "fan 1 5000"])
    }

    /// Jamais sous le minimum ni au-dessus du maximum du Mac.
    func testSpeedIsClampedToTheMacBounds() {
        let fans = fixed(100)
        XCTAssertEqual(fans.mode, .fixed(rpm: 2317))
        XCTAssertEqual(backend.sent, ["fan 0 2317", "fan 1 2317"])
        fans.setFixed(rpm: 50_000)
        XCTAssertEqual(fans.mode, .fixed(rpm: 6800))
        XCTAssertEqual(fans.range, 2317...6800)
    }

    /// Bornes différentes d'un ventilateur à l'autre : la plage commune.
    func testRangeIsCommonToAllFans() {
        backend.status?.fans[1].minimum = 2500
        backend.status?.fans[1].maximum = 6000
        let fans = controller()
        fans.viewAppeared()
        XCTAssertEqual(fans.range, 2500...6000)
    }

    /// Le bouton part de la vitesse actuelle (arrondie à 100) : rien ne change à l'oreille.
    func testEnableFixedStartsFromTheCurrentSpeed() {
        backend.status = QSFakeFans.macBookPro(actual: 3460)
        let fans = controller()
        fans.viewAppeared()
        fans.enableFixed()
        XCTAssertEqual(fans.mode, .fixed(rpm: 3500))
    }

    /// Premier usage : l'outil est installé d'abord (mot de passe administrateur), puis la tenue commence.
    func testFirstUseInstallsTheTool() {
        backend.authorization = .notInstalled
        let fans = fixed(4000)
        XCTAssertEqual(backend.installs, 1)
        XCTAssertEqual(fans.authorization, .installed)
        XCTAssertEqual(backend.holds, 1)
        XCTAssertEqual(fans.mode, .fixed(rpm: 4000))
    }

    /// Outil d'une autre version de l'app : remplacé avant usage.
    func testOutdatedToolIsReplacedBeforeUse() {
        backend.authorization = .outdated
        _ = fixed()
        XCTAssertEqual(backend.installs, 1)
        XCTAssertEqual(backend.holds, 1)
    }

    /// Fenêtre d'autorisation fermée : rien ne se passe, pas de message. Mot de passe refusé : un message.
    func testInstallCancelledOrRefused() {
        backend.authorization = .notInstalled
        backend.installFailure = QuickSettingsFailure(.cancelled)
        let fans = fixed()
        XCTAssertEqual(backend.holds, 0)
        XCTAssertEqual(fans.mode, .automatic)
        XCTAssertTrue(issues.isEmpty)
        backend.installFailure = QuickSettingsFailure(.denied)
        fans.setFixed(rpm: 4000)
        XCTAssertEqual(backend.holds, 0)
        XCTAssertEqual(issues.count, 1)
    }

    func testToolThatCannotStartIsReported() {
        backend.startSucceeds = false
        let fans = fixed()
        XCTAssertEqual(fans.mode, .automatic)
        XCTAssertEqual(issues.count, 1)
        XCTAssertFalse(defaults.bool(forKey: FanController.manualFlagKey))
    }

    // MARK: - Retours en automatique

    /// « Rendre la main à macOS » : `auto` puis fin de l'entrée de l'outil ; l'outil confirme.
    func testGivingControlBack() {
        let fans = fixed()
        fans.returnToAutomatic()
        XCTAssertEqual(backend.sent.last, "auto")
        XCTAssertEqual(backend.endHolds, 1)
        XCTAssertEqual(fans.mode, .automatic)
        XCTAssertTrue(defaults.bool(forKey: FanController.manualFlagKey), "pas encore confirmé par l'outil")
        backend.say("auto requested")
        backend.exit()
        XCTAssertFalse(defaults.bool(forKey: FanController.manualFlagKey))
        XCTAssertNil(fans.notice)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(backend.resets, 0)
    }

    /// L'outil rend la main de lui-même (température, bail, macOS) : la carte dit pourquoi.
    func testToolEndingIsShownWithItsReason() {
        for (reason, expected) in [("temperature", "Rendu à macOS : température élevée"),
                                   ("lease", "Rendu à macOS : l'app ne répondait plus"),
                                   ("system", "macOS a repris la main")] {
            let fans = fixed()
            backend.say("auto \(reason)")
            XCTAssertEqual(fans.mode, .automatic, reason)
            XCTAssertEqual(fans.notice, expected)
            backend.exit()
            XCTAssertEqual(backend.resets, 0, "l'outil a confirmé : rien à refaire")
            fans.setFixed(rpm: 4000)
            XCTAssertNil(fans.notice, "effacé au prochain passage en manuel")
            fans.returnToAutomatic()
            backend.say("auto requested")
        }
    }

    /// L'outil s'arrête sans confirmer l'automatique (plantage) : l'app le redemande par `fanctl auto`.
    func testToolCrashTriggersAReset() {
        let fans = fixed()
        backend.exit(status: 134)
        XCTAssertEqual(fans.mode, .automatic)
        XCTAssertEqual(backend.resets, 1)
        XCTAssertEqual(issues.count, 1)
        XCTAssertFalse(defaults.bool(forKey: FanController.manualFlagKey))
    }

    /// sudo refuse la règle (fichier retiré à la main…) : l'outil n'a pas tourné, l'autorisation est à redonner.
    func testSudoRefusalAsksToGrantAgain() {
        let fans = fixed()
        backend.authorization = .notInstalled
        backend.exit(status: 1, error: "sudo: a password is required")
        XCTAssertEqual(fans.mode, .automatic)
        XCTAssertEqual(backend.resets, 0)
        XCTAssertEqual(fans.authorization, .notInstalled)
        XCTAssertEqual(issues.count, 1)
    }

    /// Un refus de l'outil (ne devrait pas arriver : l'app borne déjà) rend la main.
    func testRefusalFromTheToolGivesControlBack() {
        let fans = fixed()
        backend.say("refused below-minimum")
        XCTAssertEqual(fans.mode, .automatic)
        XCTAssertEqual(backend.sent.last, "auto")
        XCTAssertEqual(issues.count, 1)
    }

    func testSleepAndSessionChangesGiveControlBack() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            let fans = fixed()
            workspace.post(name: name, object: nil)
            XCTAssertEqual(fans.mode, .automatic, name.rawValue)
            XCTAssertEqual(backend.sent.last, "auto")
        }
        // Plus d'observateur une fois la main rendue.
        let sent = backend.sent.count
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(backend.sent.count, sent)
    }

    /// Arrêt du module (désactivé, app qui quitte) : la main revient à macOS, plus aucune lecture.
    func testStopGivesControlBack() {
        let fans = fixed()
        fans.stop()
        XCTAssertEqual(fans.mode, .automatic)
        XCTAssertEqual(backend.sent.last, "auto")
    }

    /// Le bail : un `ping` régulier tant que la vitesse fixe tient, plus rien ensuite.
    func testHeartbeatKeepsTheLeaseAlive() throws {
        let fans = controller(heartbeat: 10)
        fans.viewAppeared()
        fans.setFixed(rpm: 4000)
        let heartbeat = try XCTUnwrap(timers.last)
        XCTAssertEqual(heartbeat.timeInterval, 10)
        XCTAssertEqual(backend.sent.filter { $0 == "ping" }.count, 0, "rien avant le premier top")
        for tick in 1...3 { heartbeat.fire(); XCTAssertEqual(backend.sent.filter { $0 == "ping" }.count, tick) }
        fans.returnToAutomatic()
        XCTAssertFalse(heartbeat.isValid, "plus de ping une fois la main rendue")
    }

    /// Le message tardif d'une ancienne tenue ne termine pas la nouvelle.
    func testLateMessagesFromAnOldHoldAreIgnored() {
        let fans = fixed()
        fans.returnToAutomatic()
        fans.setFixed(rpm: 5000)
        XCTAssertEqual(backend.holds, 2)
        backend.say("auto requested", hold: 0)
        backend.exit(hold: 0)
        XCTAssertEqual(fans.mode, .fixed(rpm: 5000))
        XCTAssertTrue(defaults.bool(forKey: FanController.manualFlagKey))
        XCTAssertTrue(issues.isEmpty)
    }

    // MARK: - Reprise au lancement

    /// L'app s'est arrêtée en vitesse fixe sans confirmation : au démarrage, `fanctl auto` une fois.
    func testStartAfterAnAbruptStopResetsTheFans() {
        defaults.set(true, forKey: FanController.manualFlagKey)
        controller().start()
        XCTAssertEqual(backend.resets, 1)
        XCTAssertFalse(defaults.bool(forKey: FanController.manualFlagKey))
        controller().start()
        XCTAssertEqual(backend.resets, 1, "une seule fois")
    }

    func testStartWithoutTheToolForgetsTheFlag() {
        defaults.set(true, forKey: FanController.manualFlagKey)
        backend.authorization = .notInstalled
        controller().start()
        XCTAssertEqual(backend.resets, 0)
        XCTAssertFalse(defaults.bool(forKey: FanController.manualFlagKey))
    }

    // MARK: - Réglages

    func testRemovingTheAuthorizationGivesControlBackFirst() {
        let fans = fixed()
        fans.uninstall()
        XCTAssertEqual(backend.sent.last, "auto")
        XCTAssertEqual(backend.uninstalls, 1)
        XCTAssertEqual(fans.authorization, .notInstalled)
    }

    func testEndingReasonsMapToTexts() {
        XCTAssertNil(FanController.notice(forEnding: "requested"))
        XCTAssertNil(FanController.notice(forEnding: "closed"))
        XCTAssertNil(FanController.notice(forEnding: "n'importe quoi"))
        for reason in ["temperature", "lease", "system", "write", "signal"] {
            XCTAssertNotNil(FanController.notice(forEnding: reason), reason)
        }
    }

    // MARK: - Module

    /// Vitesse fixe : le module tourne panneau replié (l'outil attend ses nouvelles) et ses oreilles le montrent,
    /// avant la caféine.
    func testModuleKeepsRunningAndShowsEarsWhileFixed() {
        let f = QuickSettingsFixture(self)
        let module = f.startAndShow()
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
        module.fans.setFixed(rpm: 4200)
        XCTAssertTrue(module.keepsRunningWhenCollapsed)
        module.startCaffeine(.oneHour)
        XCTAssertEqual(module.ears?.symbol, "fanblades.fill")
        XCTAssertEqual(module.ears?.text, QuickSettingsFormat.earsRPM(4200))
        module.fans.returnToAutomatic()
        XCTAssertEqual(module.ears?.symbol, "cup.and.saucer.fill")
        module.stop()
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
    }

    func testModuleStopGivesControlBackAndErrorsReachTheBanner() {
        let f = QuickSettingsFixture(self)
        let module = f.startAndShow()
        module.fans.setFixed(rpm: 4000)
        f.fans.exit(status: 134)
        XCTAssertNotNil(module.issue)
        module.fans.setFixed(rpm: 4000)
        module.stop()
        XCTAssertEqual(f.fans.sent.last, "auto")
        XCTAssertFalse(module.fans.isFixed)
    }

    func testSymbolsExist() {
        for symbol in ["fanblades.fill", "lock.fill"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }
}
