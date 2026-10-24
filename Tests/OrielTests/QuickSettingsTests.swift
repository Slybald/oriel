import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Module « Réglages rapides » : tout passe par des doubles, aucune bascule réelle.
final class QuickSettingsTests: XCTestCase {
    private func settle(_ duration: TimeInterval = 0.05) { QuickSettingsFixture.settle(duration) }

    // MARK: - Cycle de vie

    func testNothingIsTouchedBeforeStart() {
        let f = QuickSettingsFixture(self)
        _ = f.module
        XCTAssertEqual(f.wifi.reads + f.bluetooth.reads + f.battery.iopsReads + f.battery.pmsetReads, 0)
        XCTAssertFalse(f.wifi.monitoring || f.power.monitoring || f.battery.monitoring)
        XCTAssertEqual(f.power.supportChecks, 0)
        XCTAssertTrue(f.caffeine.acquires.isEmpty)
        XCTAssertFalse(f.module.keepsRunningWhenCollapsed)
        XCTAssertNil(f.module.ears)
    }

    func testStartListensAndShowReadsDevices() {
        let f = QuickSettingsFixture(self)
        f.power.lowPower = true
        f.module.start()
        XCTAssertTrue(f.power.monitoring && f.battery.monitoring)
        XCTAssertFalse(f.wifi.monitoring, "le Wi-Fi n'est écouté que pendant l'affichage de l'onglet")
        XCTAssertTrue(f.module.lowPower)
        XCTAssertTrue(f.module.lowPowerSupported)
        XCTAssertEqual(f.module.mac?.percent, 78)
        // Pas de lecture Wi-Fi ni Bluetooth tant que l'onglet n'est pas affiché (le premier accès au Bluetooth
        // peut afficher la demande d'autorisation du système).
        XCTAssertEqual(f.wifi.reads + f.bluetooth.reads, 0)
        XCTAssertNil(f.module.wifi)

        f.module.viewAppeared()
        XCTAssertEqual(f.module.wifi, true)
        XCTAssertTrue(f.module.wifiConnected)
        XCTAssertEqual(f.module.bluetooth, true)
        XCTAssertTrue(f.wifi.monitoring)
        f.module.viewDisappeared()
        XCTAssertFalse(f.wifi.monitoring)
    }

    func testStartTwiceListensOnce() {
        let f = QuickSettingsFixture(self)
        f.module.start()
        f.module.start()
        XCTAssertEqual(f.power.supportChecks, 1)
        XCTAssertEqual(f.battery.iopsReads, 1)
    }

    func testSupportIsCheckedOncePerModule() {
        let f = QuickSettingsFixture(self)
        f.module.start()
        f.module.stop()
        f.module.start()
        XCTAssertEqual(f.power.supportChecks, 1, "pmset -g custom n'est pas relancé à chaque ouverture")
    }

    func testStopReleasesEverythingIncludingCaffeine() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.startCaffeine(.oneHour)
        f.module.stop()
        XCTAssertFalse(f.wifi.monitoring || f.power.monitoring || f.battery.monitoring)
        XCTAssertNil(f.module.caffeine)
        XCTAssertGreaterThan(f.caffeine.releases, 0)
        let reads = f.wifi.reads
        f.wifi.fire()
        f.battery.fire(percent: 50)
        XCTAssertEqual(f.wifi.reads, reads, "plus d'écoute après stop()")
    }

    func testWiFiEventsOnlyMatterWhileTheTabIsShown() {
        let f = QuickSettingsFixture(self)
        f.module.start()
        f.wifi.fire()
        XCTAssertEqual(f.wifi.reads, 0)
        f.module.viewAppeared()
        f.wifi.power = false
        f.wifi.fire()
        XCTAssertEqual(f.module.wifi, false)
        XCTAssertFalse(f.module.wifiConnected)
        f.module.viewDisappeared()
        f.wifi.power = true
        f.wifi.fire()
        XCTAssertEqual(f.module.wifi, false, "onglet masqué : plus d'écoute")
    }

    /// En changeant d'onglet vite, la nouvelle vue apparaît avant que l'ancienne ne disparaisse.
    func testQuickTabSwitchKeepsListening() {
        let f = QuickSettingsFixture(self)
        f.module.start()
        f.module.viewAppeared()
        f.module.viewAppeared()
        f.module.viewDisappeared()
        XCTAssertTrue(f.wifi.monitoring)
        f.module.viewDisappeared()
        XCTAssertFalse(f.wifi.monitoring)
        f.module.viewDisappeared()
        f.module.viewAppeared()
        XCTAssertTrue(f.wifi.monitoring, "un compteur jamais négatif")
    }

    func testMissingHardwareHidesTilesState() {
        let f = QuickSettingsFixture(self)
        f.wifi.power = nil
        f.bluetooth.power = nil
        f.battery.iops = []
        f.startAndShow()
        XCTAssertNil(f.module.wifi)
        XCTAssertNil(f.module.bluetooth)
        XCTAssertNil(f.module.mac)
        f.module.toggleWiFi()
        f.module.toggleBluetooth()
        XCTAssertTrue(f.wifi.setCalls.isEmpty && f.bluetooth.setCalls.isEmpty)
    }

    // MARK: - Wi-Fi

    func testWiFiToggleIsImmediateThenConfirmed() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.wifi.holdsCompletion = true
        f.module.toggleWiFi()
        XCTAssertEqual(f.module.wifi, false, "retour visuel immédiat")
        XCTAssertTrue(f.module.busy.contains(.wifi))
        f.module.toggleWiFi()
        XCTAssertEqual(f.wifi.setCalls, [false], "pas de deuxième ordre pendant le premier")
        f.wifi.release()
        XCTAssertFalse(f.module.busy.contains(.wifi))
        XCTAssertEqual(f.module.wifi, false)
        XCTAssertNil(f.module.issue)
    }

    func testWiFiFailureRevertsAndExplains() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.wifi.failure = QuickSettingsFailure(.denied, "Operation not permitted")
        f.module.toggleWiFi()
        XCTAssertEqual(f.module.wifi, true, "l'état réel est relu")
        XCTAssertEqual(f.module.issue?.message, "Wi-Fi : autorisation refusée.")
        XCTAssertEqual(f.module.issue?.actionURL, SystemPane.wifi)

        f.wifi.failure = QuickSettingsFailure(.failed, "boom")
        f.module.toggleWiFi()
        XCTAssertEqual(f.module.issue?.message, "Wi-Fi : boom")
        f.module.perform(try! XCTUnwrap(f.module.issue))
        XCTAssertEqual(f.opened, [SystemPane.wifi])
        f.module.dismissIssue()
        XCTAssertNil(f.module.issue)
    }

    // MARK: - Bluetooth

    func testBluetoothToggleIsConfirmedByARead() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.toggleBluetooth()
        XCTAssertEqual(f.module.bluetooth, false)
        XCTAssertTrue(f.module.busy.contains(.bluetooth))
        settle()
        XCTAssertFalse(f.module.busy.contains(.bluetooth))
        XCTAssertEqual(f.bluetooth.setCalls, [false])
        XCTAssertNil(f.module.issue)
    }

    func testBluetoothThatDoesNotChangeIsReported() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.bluetooth.ignoresWrites = true
        f.module.toggleBluetooth()
        settle(0.2)
        XCTAssertEqual(f.module.bluetooth, true, "l'état réel reprend le dessus")
        XCTAssertFalse(f.module.busy.contains(.bluetooth))
        XCTAssertEqual(f.module.issue?.actionURL, SystemPane.bluetoothPrivacy)
        XCTAssertEqual(f.bluetooth.reads, 1 + 3, "lecture de l'onglet puis trois relectures au plus")
    }

    /// La notch se replie (délai de fermeture de 0,25 s) avant la relecture : la tuile ne reste pas « occupée ».
    func testStopDuringABluetoothToggleDoesNotLeaveTheTileBusy() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.toggleBluetooth()
        XCTAssertTrue(f.module.busy.contains(.bluetooth))
        f.module.stop()
        XCTAssertFalse(f.module.busy.contains(.bluetooth))
        settle()
        XCTAssertFalse(f.module.busy.contains(.bluetooth), "la relecture annulée ne revient pas")

        f.module.start()
        f.module.viewAppeared()
        XCTAssertFalse(f.module.busy.contains(.bluetooth))
        XCTAssertEqual(f.module.bluetooth, false, "l'état réel est relu à la réapparition de l'onglet")
        f.module.toggleBluetooth()
        XCTAssertEqual(f.bluetooth.setCalls, [false, true], "un deuxième clic fonctionne")
    }

    func testBluetoothCallThatCannotLeaveIsReported() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.bluetooth.acceptsCalls = false
        f.module.toggleBluetooth()
        XCTAssertEqual(f.module.bluetooth, true)
        XCTAssertFalse(f.module.busy.contains(.bluetooth))
        XCTAssertNotNil(f.module.issue)
    }

    // MARK: - Économie d'énergie

    func testLowPowerToggleKeepsRequestedValueThenConfirms() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.power.holdsCompletion = true
        f.module.toggleLowPower()
        XCTAssertTrue(f.module.lowPower, "immédiat")
        XCTAssertTrue(f.module.busy.contains(.lowPower))
        f.power.release()
        settle()
        XCTAssertTrue(f.module.lowPower)
        XCTAssertNil(f.module.issue)
        XCTAssertEqual(f.power.setCalls, [true])

        // Le système l'a coupée depuis (Centre de contrôle) : la notification remet l'état réel.
        f.power.lowPower = false
        f.power.fire()
        XCTAssertFalse(f.module.lowPower)
    }

    func testCancelledAuthorizationIsNotAnError() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.power.failure = QuickSettingsFailure(.cancelled, "User canceled. (-128)")
        f.module.toggleLowPower()
        XCTAssertFalse(f.module.lowPower, "retour à l'état réel")
        XCTAssertNil(f.module.issue)
        XCTAssertFalse(f.module.busy.contains(.lowPower))
    }

    func testLowPowerFailuresAreExplained() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.power.failure = QuickSettingsFailure(.denied)
        f.module.toggleLowPower()
        XCTAssertEqual(f.module.issue?.message, "Économie d'énergie : identifiants administrateur refusés.")
        XCTAssertEqual(f.module.issue?.actionURL, SystemPane.battery)
        f.power.failure = QuickSettingsFailure(.failed, "pmset: boom")
        f.module.toggleLowPower()
        XCTAssertEqual(f.module.issue?.message, "Économie d'énergie : pmset: boom")
        f.power.failure = QuickSettingsFailure(.timeout)
        f.module.toggleLowPower()
        XCTAssertEqual(f.module.issue?.message, "Économie d'énergie : pas de réponse à la demande d'autorisation.")
    }

    func testLowPowerThatDoesNotChangeIsReported() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.power.ignoresWrites = true
        f.module.toggleLowPower()
        settle()
        XCTAssertFalse(f.module.lowPower)
        XCTAssertEqual(f.module.issue?.message, "Économie d'énergie : le système n'a pas changé d'état.")
    }

    func testUnsupportedLowPowerNeverWrites() {
        let f = QuickSettingsFixture(self)
        f.power.supported = false
        f.startAndShow()
        XCTAssertFalse(f.module.lowPowerSupported)
        f.module.toggleLowPower()
        XCTAssertTrue(f.power.setCalls.isEmpty)
    }

    // MARK: - Concentration

    func testFocusNeedsAShortcut() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.toggleFocus()
        XCTAssertFalse(f.module.focus)
        XCTAssertTrue(f.module.issue?.message.contains("« activer »") == true)
        XCTAssertTrue(f.shortcuts.runs.isEmpty)
    }

    func testFocusRunsTheChosenShortcutsAndRemembersTheState() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.prefs.focusOnShortcut = "  Concentration on "
        f.module.prefs.focusOffShortcut = "Concentration off"
        f.module.toggleFocus()
        XCTAssertTrue(f.module.focus)
        f.module.toggleFocus()
        XCTAssertFalse(f.module.focus)
        XCTAssertEqual(f.shortcuts.runs, ["Concentration on", "Concentration off"])
        f.module.toggleFocus()
        XCTAssertTrue(f.makeModule().focus, "le dernier état demandé survit à une relance")
    }

    func testFocusOffNeedsItsOwnShortcut() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.prefs.focusOnShortcut = "On"
        f.module.toggleFocus()
        f.module.toggleFocus()
        XCTAssertTrue(f.module.focus, "pas de raccourci « désactiver » : l'état ne bouge pas")
        XCTAssertTrue(f.module.issue?.message.contains("« désactiver »") == true)
    }

    func testFocusShortcutFailureRevertsAndOffersShortcuts() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.prefs.focusOnShortcut = "Inconnu"
        f.shortcuts.failure = QuickSettingsFailure(.failed, "Error: Couldn't find shortcut")
        f.module.toggleFocus()
        XCTAssertFalse(f.module.focus)
        XCTAssertEqual(f.module.issue?.message, "Raccourci « Inconnu » : Error: Couldn't find shortcut")
        XCTAssertEqual(f.module.issue?.actionURL, SystemPane.shortcuts)
        XCTAssertFalse(f.makeModule().focus)
    }

    func testShortcutNamesCannotBecomeOptions() {
        XCTAssertNil(QuickSettingsPrefs.usable("--help"))
        XCTAssertNil(QuickSettingsPrefs.usable("   "))
        XCTAssertEqual(QuickSettingsPrefs.usable("  Mon raccourci  "), "Mon raccourci")
    }

    // MARK: - Caféine

    func testCaffeineDurationsAndExpiry() throws {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.toggleCaffeine()
        XCTAssertEqual(f.module.caffeine?.end, f.now.addingTimeInterval(3600), "1 h par défaut")
        XCTAssertEqual(f.caffeine.acquires, [true], "écran allumé par défaut")
        XCTAssertTrue(f.module.keepsRunningWhenCollapsed)
        XCTAssertEqual(f.module.ears, ModuleEars(symbol: "cup.and.saucer.fill", text: "1h00", priority: -10))

        f.now = f.now.addingTimeInterval(25 * 60)
        f.module.tick()
        XCTAssertEqual(f.module.ears?.text, "35m")
        XCTAssertNotNil(f.module.caffeine)

        f.now = f.now.addingTimeInterval(35 * 60)
        let releases = f.caffeine.releases
        f.module.tick()
        XCTAssertNil(f.module.caffeine, "terminée")
        XCTAssertGreaterThan(f.caffeine.releases, releases)
        XCTAssertNil(f.module.ears)
        XCTAssertFalse(f.module.keepsRunningWhenCollapsed)
    }

    func testIndefiniteCaffeineHasNoTimer() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.selectCaffeineDuration(.indefinite)
        f.module.toggleCaffeine()
        XCTAssertNil(f.module.caffeine?.end)
        XCTAssertEqual(f.module.ears?.text, "∞")
        f.now = f.now.addingTimeInterval(86_400)
        f.module.tick()
        XCTAssertNotNil(f.module.caffeine, "sans limite : jamais d'expiration")
        f.module.toggleCaffeine()
        XCTAssertNil(f.module.caffeine)
    }

    func testChangingTheDurationRestartsRunningCaffeine() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.toggleCaffeine()
        f.module.selectCaffeineDuration(.twoHours)
        XCTAssertEqual(f.module.caffeine?.end, f.now.addingTimeInterval(7200))
        XCTAssertEqual(f.caffeine.acquires.count, 2)
        XCTAssertEqual(f.module.prefs.caffeineDuration, .twoHours)
        // Hors caféine, choisir une durée ne démarre rien.
        f.module.toggleCaffeine()
        f.module.selectCaffeineDuration(.oneHour)
        XCTAssertNil(f.module.caffeine)
        XCTAssertEqual(f.caffeine.acquires.count, 2)
    }

    func testCaffeineCanKeepOnlyTheMacAwake() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.prefs.caffeineKeepsDisplayOn = false
        f.module.toggleCaffeine()
        XCTAssertEqual(f.caffeine.acquires, [false])
        // Réglage changé pendant que la caféine tourne : l'assertion est reprise.
        f.module.prefs.caffeineKeepsDisplayOn = true
        XCTAssertEqual(f.caffeine.acquires, [false, true])
        XCTAssertNotNil(f.module.caffeine)
    }

    func testCaffeineFailureIsReported() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.caffeine.fails = true
        f.module.toggleCaffeine()
        XCTAssertNil(f.module.caffeine)
        XCTAssertNotNil(f.module.issue)
    }

    func testCaffeineEarsAreLowPriority() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.toggleCaffeine()
        let other = ModuleEars(symbol: "timer", text: "4:59")
        XCTAssertEqual(ModuleRegistry.pickEars([f.module.ears!, other]), other)
        XCTAssertEqual(ModuleRegistry.pickEars([f.module.ears!]), f.module.ears)
    }

    // MARK: - Batterie

    func testAccessoriesComeFromPmsetWhenIOPSListsNone() {
        let f = QuickSettingsFixture(self)
        f.battery.pmset = [FakeBatteryFixtures.mac, FakeBatteryFixtures.pods, FakeBatteryFixtures.case]
        f.startAndShow()
        XCTAssertEqual(f.battery.pmsetReads, 1)
        XCTAssertEqual(f.module.accessories.map { $0.name }, ["AirPods Pro de Zoé", "Boîtier AirPods Pro de Zoé"])
        XCTAssertEqual(f.module.mac?.percent, 78, "la batterie du Mac vient d'IOPS, pas de pmset")

        // Les notifications IOPS ne relancent pas pmset à chaque pour cent.
        f.now = f.now.addingTimeInterval(10)
        f.battery.fire(percent: 77)
        XCTAssertEqual(f.battery.pmsetReads, 1)
        XCTAssertEqual(f.module.mac?.percent, 77)
        f.now = f.now.addingTimeInterval(61)
        f.battery.fire(percent: 76)
        XCTAssertEqual(f.battery.pmsetReads, 2, "au plus une fois par minute")
        // L'onglet s'affiche à nouveau : relecture tout de suite.
        f.module.viewAppeared()
        XCTAssertEqual(f.battery.pmsetReads, 3)
    }

    /// Les accessoires ne figurent ni dans les oreilles ni dans le résumé compact : pmset ne se lance que si
    /// l'onglet est affiché.
    func testPmsetIsOnlyReadWhileTheTabIsShown() {
        let f = QuickSettingsFixture(self)
        f.battery.pmset = [FakeBatteryFixtures.pods, FakeBatteryFixtures.case]
        f.module.prefs.autoAutonomy = true
        f.module.start()
        XCTAssertEqual(f.battery.pmsetReads, 0, "ouvrir la notch sur un autre onglet ne lance rien")
        for percent in [77, 76, 75] {
            f.now = f.now.addingTimeInterval(61)
            f.battery.fire(percent: percent)
        }
        XCTAssertEqual(f.battery.pmsetReads, 0, "replié ou sans onglet : jamais")
        XCTAssertTrue(f.module.accessories.isEmpty)

        f.module.viewAppeared()
        XCTAssertEqual(f.battery.pmsetReads, 1)
        XCTAssertEqual(f.module.accessories.count, 2)
        f.module.viewDisappeared()
        f.now = f.now.addingTimeInterval(61)
        f.battery.fire(percent: 74)
        XCTAssertEqual(f.battery.pmsetReads, 1, "l'onglet a disparu")
        f.module.stop()
        f.module.start()
        XCTAssertEqual(f.battery.pmsetReads, 1, "une réouverture sans l'onglet non plus")
    }

    func testPmsetProvidesEverythingWhenIOPSGivesNothing() {
        let f = QuickSettingsFixture(self)
        f.battery.iops = []
        f.battery.pmset = [FakeBatteryFixtures.mac, FakeBatteryFixtures.pods]
        f.startAndShow()
        XCTAssertEqual(f.module.mac?.percent, 49)
        XCTAssertEqual(f.module.accessories.count, 1)
    }

    func testPmsetIsNotReadWhenIOPSListsAccessories() {
        let f = QuickSettingsFixture(self)
        f.battery.iops = [FakeBatteryFixtures.mac, FakeBatteryFixtures.pods]
        f.module.start()
        f.module.viewAppeared()
        XCTAssertEqual(f.battery.pmsetReads, 0)
        XCTAssertEqual(f.module.accessories.count, 1)
    }

    func testDesktopMacHasNoBattery() {
        let f = QuickSettingsFixture(self)
        f.battery.iops = []
        f.module.start()
        XCTAssertNil(f.module.mac)
        XCTAssertTrue(f.module.accessories.isEmpty)
    }

    // MARK: - Registre

    func testRegistryRunsTheModuleOnlyWhenUseful() {
        let f = QuickSettingsFixture(self)
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let registry = ModuleRegistry(modules: [FakeModule(id: "claude"), f.module], prefs: prefs)
        registry.reconcile()
        XCTAssertFalse(f.battery.monitoring, "replié : rien ne tourne")
        XCTAssertEqual(f.battery.iopsReads, 0)

        registry.setPanelOpen(true)
        XCTAssertTrue(f.battery.monitoring)

        // La caféine retient le module panneau replié, avec ses oreilles.
        f.module.startCaffeine(.oneHour)
        settle()
        registry.setPanelOpen(false)
        XCTAssertTrue(f.battery.monitoring)
        XCTAssertEqual(registry.moduleEars?.symbol, "cup.and.saucer.fill")

        f.module.stopCaffeine()
        settle()
        XCTAssertFalse(f.battery.monitoring, "plus de caféine : le module s'arrête")
        XCTAssertNil(registry.moduleEars)
    }

    func testDisablingTheTabReleasesCaffeine() {
        let f = QuickSettingsFixture(self)
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let registry = ModuleRegistry(modules: [FakeModule(id: "claude"), f.module], prefs: prefs)
        registry.setPanelOpen(true)
        f.module.startCaffeine(.indefinite)
        settle()
        prefs.tabEnabled["quicksettings"] = false
        settle()
        XCTAssertNil(f.module.caffeine)
        XCTAssertFalse(f.battery.monitoring)
        XCTAssertGreaterThan(f.caffeine.releases, 0)
    }

    func testAutoSwitchKeepsTheModuleRunningCollapsed() {
        let f = QuickSettingsFixture(self)
        XCTAssertFalse(f.module.keepsRunningWhenCollapsed)
        f.module.prefs.autoAutonomy = true
        XCTAssertTrue(f.module.keepsRunningWhenCollapsed)
    }

    // MARK: - Mise en forme

    func testFormats() {
        XCTAssertEqual(QuickSettingsFormat.percent(78), "78 %")
        XCTAssertEqual(QuickSettingsFormat.duration(minutes: 227), "3 h 47")
        XCTAssertEqual(QuickSettingsFormat.duration(minutes: 125), "2 h 05")
        XCTAssertEqual(QuickSettingsFormat.duration(minutes: 45), "45 min")
        XCTAssertEqual(QuickSettingsFormat.earsDuration(minutes: 72), "1h12")
        XCTAssertEqual(QuickSettingsFormat.earsDuration(minutes: 9), "9m")
        XCTAssertEqual(QuickSettingsFormat.earsDuration(minutes: nil), "∞")
        let start = Date(timeIntervalSince1970: 0)
        let session = CaffeineSession(start: start, end: start.addingTimeInterval(61))
        XCTAssertEqual(QuickSettingsFormat.remainingMinutes(of: session, now: start), 2, "arrondi au-dessus")
        XCTAssertEqual(QuickSettingsFormat.remainingMinutes(of: session, now: start.addingTimeInterval(60.5)), 1)
        XCTAssertNil(QuickSettingsFormat.remainingMinutes(of: CaffeineSession(start: start, end: nil), now: start))
    }

    func testBatteryDetail() {
        let detail = QuickSettingsView.batteryDetail
        XCTAssertEqual(detail(QSFakeBattery.mac(percent: 50, charging: true, minutes: 62)), "En charge · 1 h 02")
        XCTAssertEqual(detail(QSFakeBattery.mac(percent: 50, charging: true, minutes: nil)), "En charge")
        XCTAssertEqual(detail(QSFakeBattery.mac(percent: 100, pluggedIn: true, minutes: nil)), "Chargée")
        XCTAssertEqual(detail(QSFakeBattery.mac(percent: 90, pluggedIn: true, minutes: nil)), "Branchée")
        XCTAssertEqual(detail(QSFakeBattery.mac(percent: 49)), "Il reste 3 h 47")
        XCTAssertEqual(detail(QSFakeBattery.mac(percent: 49, minutes: nil)), "Sur batterie")
    }

    func testPreferencesDefaultsAndBounds() {
        let defaults = makeEphemeralDefaults(self)
        let prefs = QuickSettingsPrefs(defaults: defaults)
        XCTAssertFalse(prefs.autoAutonomy, "désactivé par défaut")
        XCTAssertEqual(prefs.autoThreshold, 20)
        XCTAssertEqual(prefs.caffeineDuration, .oneHour)
        XCTAssertTrue(prefs.caffeineKeepsDisplayOn)
        XCTAssertFalse(prefs.autonomyBluetoothOff || prefs.presentationFocus)
        defaults.set(999, forKey: "quicksettings.auto.threshold")
        XCTAssertEqual(QuickSettingsPrefs(defaults: defaults).autoThreshold, 50)
        defaults.set(0, forKey: "quicksettings.auto.threshold")
        XCTAssertEqual(QuickSettingsPrefs(defaults: defaults).autoThreshold, 5)
        defaults.set("n'importe quoi", forKey: "quicksettings.caffeine.duration")
        XCTAssertEqual(QuickSettingsPrefs(defaults: defaults).caffeineDuration, .oneHour)
        prefs.caffeineDuration = .indefinite
        XCTAssertEqual(QuickSettingsPrefs(defaults: defaults).caffeineDuration, .indefinite)
    }

    func testModuleIdentityAndSymbols() throws {
        let module = QuickSettingsModule(backends: QuickSettingsFixture(self).backends,
                                         defaults: makeEphemeralDefaults(self))
        XCTAssertEqual(module.id, "quicksettings")
        XCTAssertFalse(module.title.isEmpty)
        XCTAssertNotNil(module.makeCompactView())
        XCTAssertNotNil(module.makeSettingsView())
        let symbols = ["switch.2", "wifi", "wifi.slash", "moon.fill", "leaf.fill", "cup.and.saucer.fill",
                       "powerplug.fill", "bolt.fill", "headphones", "airpods.chargingcase", "lock.fill", "xmark",
                       "exclamationmark.triangle.fill", "arrow.uturn.backward", "play.rectangle.fill"]
        for symbol in symbols + QuickScene.allCases.map({ $0.symbol }) {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    /// Le module standard se construit sans toucher au matériel (le registre l'instancie au lancement).
    func testStandardModuleIsInertUntilStarted() {
        let module = QuickSettingsModule()
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
        XCTAssertNil(module.ears)
        XCTAssertNil(module.wifi)
    }
}

/// Sources de batterie récurrentes des tests (noms génériques : le dépôt est public).
enum FakeBatteryFixtures {
    static let mac = QSFakeBattery.mac(percent: 49)
    static let pods = PowerSourceInfo(name: "AirPods Pro de Zoé", kind: .accessory, percent: 36, isCharging: true)
    static let `case` = PowerSourceInfo(name: "Boîtier AirPods Pro de Zoé", kind: .chargingCase, percent: 100,
                                        isCharging: false)
}
