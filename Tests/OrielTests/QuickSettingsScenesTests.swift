import XCTest
@testable import Oriel

/// Scènes (Autonomie, Normal, Présentation) et passage automatique en Autonomie : doubles seulement.
final class QuickSettingsScenesTests: XCTestCase {
    private func settle() { QuickSettingsFixture.settle() }

    // MARK: - Autonomie

    func testAutonomySetsLowPowerStopsCaffeineAndKeepsAnInstantaneous() throws {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.startCaffeine(until: f.now.addingTimeInterval(1800))
        f.module.applyScene(.autonomy)
        settle()

        XCTAssertEqual(f.power.setCalls, [true])
        XCTAssertTrue(f.module.lowPower)
        XCTAssertNil(f.module.caffeine)
        XCTAssertTrue(f.bluetooth.setCalls.isEmpty, "Bluetooth seulement si l'option est cochée")
        let snapshot = try XCTUnwrap(f.module.snapshot)
        XCTAssertEqual(snapshot, SceneSnapshot(scene: .autonomy, lowPower: false, bluetooth: nil, caffeine: true,
                                               caffeineEnd: f.now.addingTimeInterval(1800), focus: false),
                       "le Bluetooth n'est ni lu ni gardé : la scène n'y touche pas")
        XCTAssertTrue(f.module.isSceneActive(.autonomy))
        XCTAssertFalse(f.module.isSceneActive(.presentation))
        XCTAssertTrue(f.module.canRestoreNormal)
    }

    func testAutonomyCanAlsoTurnBluetoothOff() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.prefs.autonomyBluetoothOff = true
        f.module.applyScene(.autonomy)
        settle()
        XCTAssertEqual(f.bluetooth.setCalls, [false])
        XCTAssertEqual(f.module.bluetooth, false)
        XCTAssertTrue(f.module.isSceneActive(.autonomy))
    }

    func testNormalRestoresTheStateBeforeTheScene() throws {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.prefs.autonomyBluetoothOff = true
        f.module.startCaffeine(until: nil)
        f.module.applyScene(.autonomy)
        settle()
        XCTAssertFalse(f.module.isSceneActive(.presentation))

        f.module.applyScene(.normal)
        settle()
        XCTAssertEqual(f.power.setCalls, [true, false])
        XCTAssertFalse(f.module.lowPower)
        XCTAssertEqual(f.bluetooth.setCalls, [false, true])
        XCTAssertEqual(f.module.bluetooth, true)
        XCTAssertNotNil(f.module.caffeine, "la caféine d'avant revient")
        XCTAssertNil(f.module.caffeine?.end)
        XCTAssertNil(f.module.snapshot)
        XCTAssertFalse(f.module.canRestoreNormal)
        XCTAssertNil(f.makeModule().snapshot, "l'instantané est effacé aussi sur disque")
    }

    func testNormalWithoutSnapshotDoesNothing() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.applyScene(.normal)
        XCTAssertTrue(f.power.setCalls.isEmpty)
        XCTAssertNil(f.module.snapshot)
    }

    func testSwitchingBetweenScenesKeepsTheFirstSnapshot() throws {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.applyScene(.autonomy)
        settle()
        f.module.applyScene(.presentation)
        settle()
        XCTAssertEqual(f.power.setCalls, [true, false])
        XCTAssertNotNil(f.module.caffeine, "Présentation : écran allumé")
        XCTAssertNil(f.module.caffeine?.end, "sans limite")
        let snapshot = try XCTUnwrap(f.module.snapshot)
        XCTAssertEqual(snapshot.scene, .presentation)
        XCTAssertFalse(snapshot.lowPower, "l'état d'avant la première scène, pas celui d'Autonomie")
        XCTAssertFalse(snapshot.caffeine)
        XCTAssertTrue(f.module.isSceneActive(.presentation))
        XCTAssertFalse(f.module.isSceneActive(.autonomy))

        f.module.applyScene(.normal)
        settle()
        XCTAssertNil(f.module.caffeine)
        XCTAssertNil(f.module.snapshot)
    }

    /// Un réglage changé à la main entre deux scènes : « Normal » revient à cet état, pas à un instantané ancien.
    func testSnapshotIsRetakenWhenTheMacNoLongerMatchesTheLastScene() throws {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.applyScene(.presentation)
        settle()
        XCTAssertEqual(f.module.snapshot?.lowPower, false)

        f.power.lowPower = true
        f.power.fire()
        XCTAssertFalse(f.module.isSceneActive(.presentation), "l'utilisateur a changé un réglage")
        f.module.applyScene(.autonomy)
        settle()
        XCTAssertEqual(f.module.snapshot?.lowPower, true, "instantané repris à partir de l'état du moment")

        f.module.applyScene(.normal)
        settle()
        XCTAssertTrue(f.power.setCalls.isEmpty, "économie d'énergie déjà réglée comme l'utilisateur la voulait")
        XCTAssertTrue(f.module.lowPower)
        XCTAssertNil(f.module.snapshot)
    }

    func testSnapshotIsNotRetakenWhileTheLastSceneStillMatches() throws {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.startCaffeine(until: nil)
        f.module.applyScene(.autonomy)
        settle()
        XCTAssertTrue(f.module.isSceneActive(.autonomy))
        f.module.applyScene(.presentation)
        settle()
        let snapshot = try XCTUnwrap(f.module.snapshot)
        XCTAssertTrue(snapshot.caffeine && !snapshot.lowPower, "toujours l'état d'avant la première scène")
    }

    /// Scène suivante qui touche au Bluetooth alors que la première n'y touchait pas : il est gardé à ce moment-là.
    func testBluetoothIsKeptWhenALaterSceneStartsTouchingIt() throws {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.applyScene(.autonomy)
        settle()
        XCTAssertNil(f.module.snapshot?.bluetooth)
        f.module.prefs.autonomyBluetoothOff = true
        f.module.applyScene(.autonomy)
        settle()
        XCTAssertEqual(f.module.snapshot?.bluetooth, true)
        f.module.applyScene(.normal)
        settle()
        XCTAssertEqual(f.bluetooth.setCalls, [false, true])
    }

    // MARK: - Présentation

    func testPresentationRunsTheFocusShortcutOnlyWhenAsked() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.prefs.focusOnShortcut = "Concentration on"
        f.module.prefs.focusOffShortcut = "Concentration off"
        f.module.applyScene(.presentation)
        XCTAssertTrue(f.shortcuts.runs.isEmpty, "option décochée")

        f.module.applyScene(.normal)
        settle()
        f.module.prefs.presentationFocus = true
        f.module.applyScene(.presentation)
        XCTAssertEqual(f.shortcuts.runs, ["Concentration on"])
        XCTAssertTrue(f.module.focus)
        XCTAssertTrue(f.module.isSceneActive(.presentation))

        f.module.applyScene(.normal)
        settle()
        XCTAssertEqual(f.shortcuts.runs, ["Concentration on", "Concentration off"])
        XCTAssertFalse(f.module.focus)
    }

    func testPresentationSkipsFocusWithoutShortcut() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.prefs.presentationFocus = true
        f.module.applyScene(.presentation)
        XCTAssertTrue(f.shortcuts.runs.isEmpty)
        XCTAssertNil(f.module.issue, "pas d'erreur : l'option ne s'applique simplement pas")
        XCTAssertNotNil(f.module.caffeine)
    }

    func testPresentationTurnsLowPowerOffOnlyIfNeeded() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.applyScene(.presentation)
        XCTAssertTrue(f.power.setCalls.isEmpty, "déjà coupée : pas de demande d'autorisation pour rien")

        let g = QuickSettingsFixture(self)
        g.power.lowPower = true
        g.startAndShow()
        g.module.applyScene(.presentation)
        XCTAssertEqual(g.power.setCalls, [false])
    }

    // MARK: - Autorisation refusée

    func testCancelledAuthorizationLeavesEverythingUntouched() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.prefs.autonomyBluetoothOff = true
        f.module.startCaffeine(.oneHour)
        f.power.failure = QuickSettingsFailure(.cancelled)
        f.module.applyScene(.autonomy)
        settle()

        XCTAssertNil(f.module.snapshot, "aucun instantané si la scène n'a pas été appliquée")
        XCTAssertNotNil(f.module.caffeine, "pas de scène à moitié appliquée")
        XCTAssertTrue(f.bluetooth.setCalls.isEmpty)
        XCTAssertNil(f.module.issue)
        XCTAssertFalse(f.module.busy.contains(.scene))
        XCTAssertFalse(f.module.lowPower)
    }

    func testDeniedAuthorizationIsReported() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.power.failure = QuickSettingsFailure(.denied)
        f.module.applyScene(.autonomy)
        XCTAssertNil(f.module.snapshot)
        XCTAssertNotNil(f.module.issue)
    }

    func testSceneWaitsForTheAuthorizationBeforeTheRest() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.startCaffeine(.oneHour)
        f.power.holdsCompletion = true
        f.module.applyScene(.autonomy)
        XCTAssertTrue(f.module.busy.contains(.scene))
        XCTAssertNotNil(f.module.caffeine, "rien d'autre tant que l'autorisation n'est pas donnée")
        f.module.applyScene(.presentation)
        XCTAssertEqual(f.power.setCalls, [true], "une scène à la fois")
        f.power.release()
        XCTAssertNil(f.module.caffeine)
        XCTAssertFalse(f.module.busy.contains(.scene))
    }

    func testScenesWithoutLowPowerSupportOnlyTouchTheRest() {
        let f = QuickSettingsFixture(self)
        f.power.supported = false
        f.startAndShow()
        f.module.startCaffeine(.oneHour)
        f.module.applyScene(.autonomy)
        XCTAssertTrue(f.power.setCalls.isEmpty)
        XCTAssertNil(f.module.caffeine)
        XCTAssertNotNil(f.module.snapshot)
    }

    func testSnapshotSurvivesARelaunch() throws {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.applyScene(.autonomy)
        let snapshot = try XCTUnwrap(f.module.snapshot)

        let relaunched = f.makeModule()
        XCTAssertEqual(relaunched.snapshot, snapshot)
        XCTAssertTrue(relaunched.canRestoreNormal)
    }

    // MARK: - Passage automatique

    private func autoFixture(threshold: Int = 20) -> QuickSettingsFixture {
        let f = QuickSettingsFixture(self)
        f.battery.iops = [QSFakeBattery.mac(percent: 50)]
        f.module.prefs.autoAutonomy = true
        f.module.prefs.autoThreshold = threshold
        settle()
        f.module.start()
        return f
    }

    func testAutoSwitchIsOffByDefault() {
        let f = QuickSettingsFixture(self)
        f.battery.iops = [QSFakeBattery.mac(percent: 50)]
        f.module.start()
        f.battery.fire(percent: 5)
        XCTAssertTrue(f.power.setCalls.isEmpty)
        XCTAssertNil(f.module.snapshot)
    }

    func testAutoSwitchTriggersOncePerDescent() {
        let f = autoFixture()
        f.battery.fire(percent: 21)
        XCTAssertTrue(f.power.setCalls.isEmpty)
        f.battery.fire(percent: 20)
        XCTAssertEqual(f.power.setCalls, [true], "au seuil")
        XCTAssertEqual(f.module.snapshot?.scene, .autonomy)
        f.battery.fire(percent: 19)
        f.battery.fire(percent: 18)
        XCTAssertEqual(f.power.setCalls, [true], "une seule fois")

        // Retour à la normale à la main, toujours sous le seuil : pas de nouveau déclenchement.
        f.module.applyScene(.normal)
        settle()
        f.battery.fire(percent: 17)
        XCTAssertEqual(f.power.setCalls, [true, false])

        // Branché puis débranché sous le seuil : une nouvelle descente.
        f.battery.fire(percent: 17, pluggedIn: true)
        f.battery.fire(percent: 17)
        XCTAssertEqual(f.power.setCalls, [true, false, true])
    }

    func testAutoSwitchIsRearmedByClimbingAboveTheThreshold() {
        let f = autoFixture()
        f.battery.fire(percent: 19)
        f.module.applyScene(.normal)
        settle()
        f.battery.fire(percent: 40)
        f.battery.fire(percent: 19)
        XCTAssertEqual(f.power.setCalls, [true, false, true])
    }

    func testAutoSwitchNeverFiresWhilePluggedIn() {
        let f = autoFixture()
        f.battery.fire(percent: 10, pluggedIn: true)
        f.battery.fire(percent: 9, pluggedIn: true)
        XCTAssertTrue(f.power.setCalls.isEmpty)
    }

    func testAutoSwitchDoesNotSurpriseAtLaunchWhenAlreadyLow() {
        let f = QuickSettingsFixture(self)
        f.battery.iops = [QSFakeBattery.mac(percent: 12)]
        f.module.prefs.autoAutonomy = true
        settle()
        f.module.start()
        f.battery.fire(percent: 11)
        XCTAssertTrue(f.power.setCalls.isEmpty, "pas de demande d'autorisation à l'ouverture de la notch")
    }

    func testAutoSwitchWaitsForTheFirstDescentAfterBeingEnabled() {
        let f = QuickSettingsFixture(self)
        f.battery.iops = [QSFakeBattery.mac(percent: 15)]
        f.module.start()
        f.module.prefs.autoAutonomy = true
        settle()
        f.battery.fire(percent: 14)
        XCTAssertTrue(f.power.setCalls.isEmpty, "activé alors que la batterie est déjà basse")
        f.battery.fire(percent: 60)
        f.battery.fire(percent: 20)
        XCTAssertEqual(f.power.setCalls, [true])
    }

    func testAutoSwitchUsesTheThresholdSetting() {
        let f = autoFixture(threshold: 35)
        f.battery.fire(percent: 36)
        XCTAssertTrue(f.power.setCalls.isEmpty)
        f.battery.fire(percent: 35)
        XCTAssertEqual(f.power.setCalls, [true])
    }

    /// Le premier accès au Bluetooth affiche la demande d'autorisation du système : pas à un moment imprévu.
    func testAutoSwitchDoesNotReadBluetoothUnlessTheSceneTouchesIt() {
        let f = autoFixture()
        f.battery.fire(percent: 15)
        XCTAssertEqual(f.power.setCalls, [true])
        XCTAssertEqual(f.bluetooth.reads, 0)

        let g = autoFixture()
        g.module.prefs.autonomyBluetoothOff = true
        g.battery.fire(percent: 15)
        XCTAssertEqual(g.bluetooth.reads, 1)
        XCTAssertEqual(g.bluetooth.setCalls, [false])
    }

    func testAutoSwitchDoesNotStackOnAnAppliedScene() {
        let f = autoFixture()
        f.module.applyScene(.presentation)
        f.battery.fire(percent: 15)
        XCTAssertEqual(f.module.snapshot?.scene, .presentation, "une scène choisie à la main n'est pas écrasée")
    }
}
