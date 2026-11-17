import Foundation
import XCTest
@testable import Oriel

/// Jauges de quota : lecture des deux sources (JSON de la `statusLine` de Claude Code, `account/rateLimits/read` de Codex),
/// magasin Codex (cache, échec, oubli), installeur du relais, route du serveur et vrai script du relais.
/// Les formes des fixtures sont celles mesurées sur Claude Code 2.1.304 et Codex 0.154 / 0.162 ; aucun vrai Codex lancé.
final class QuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fenêtre

    func testLevelsAndClamping() {
        func window(_ percent: Double) -> QuotaWindow { QuotaWindow(usedPercent: percent, resetsAt: now, minutes: 300) }
        XCTAssertEqual(window(0).level, .normal)
        XCTAssertEqual(window(79.4).level, .normal)
        XCTAssertEqual(window(80).level, .high)
        XCTAssertEqual(window(94.6).level, .critical, "arrondi à 95")
        XCTAssertEqual(window(250).usedPercent, 100)
        XCTAssertEqual(window(-3).usedPercent, 0)
        XCTAssertEqual(window(.nan).usedPercent, 0)
    }

    func testLabelFromMinutes() {
        func label(_ minutes: Int?) -> String { QuotaWindow(usedPercent: 1, resetsAt: now, minutes: minutes).label }
        XCTAssertTrue(label(300).hasPrefix("5"))
        XCTAssertTrue(label(10_080).hasPrefix("7"))
        XCTAssertTrue(label(60).hasPrefix("1"))
        XCTAssertEqual(label(nil), "")
        XCTAssertEqual(label(0), "")
    }

    func testResetTextShowsTheDayOnlyWhenNotToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let today = QuotaWindow(usedPercent: 1, resetsAt: now.addingTimeInterval(600), minutes: 300)
        let later = QuotaWindow(usedPercent: 1, resetsAt: now.addingTimeInterval(3 * 86_400), minutes: 10_080)
        let sameDay = today.resetText(now: now, calendar: calendar, locale: locale)
        let otherDay = later.resetText(now: now, calendar: calendar, locale: locale)
        XCTAssertFalse(sameDay.isEmpty)
        XCTAssertGreaterThan(otherDay.count, sameDay.count, "« \(otherDay) » porte le jour, « \(sameDay) » non")
    }

    func testLiveDropsResetWindowsAndOldMeasures() {
        let past = QuotaWindow(usedPercent: 90, resetsAt: now.addingTimeInterval(-1), minutes: 300)
        let future = QuotaWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(60), minutes: 10_080)
        let snapshot = QuotaSnapshot(windows: [past, future], updatedAt: now)
        XCTAssertEqual(snapshot.live(at: now), [future], "la fenêtre déjà remise à zéro ne vaut plus rien")
        XCTAssertNil(QuotaSnapshot(windows: [past], updatedAt: now).live(at: now))
        XCTAssertNotNil(snapshot.live(at: now.addingTimeInterval(10), maxAge: 15))
        XCTAssertNil(snapshot.live(at: now.addingTimeInterval(20), maxAge: 15), "mesure trop ancienne")
    }

    // MARK: - Codex : account/rateLimits/read

    private func codexAnswer(primary: Any? = ["usedPercent": 19, "windowDurationMins": 300, "resetsAt": 1_800_003_600],
                             secondary: Any? = ["usedPercent": 3, "windowDurationMins": 10_080, "resetsAt": 1_800_400_000])
        -> [String: Any] {
        var limits: [String: Any] = ["limitId": "codex", "planType": "plus", "credits": ["hasCredits": false, "unlimited": false]]
        if let primary { limits["primary"] = primary }
        if let secondary { limits["secondary"] = secondary }
        return ["rateLimits": limits, "rateLimitsByLimitId": ["codex": limits], "ordinaryUsageAllowed": true]
    }

    func testCodexParsesBothWindowsShortestFirst() throws {
        let swapped = codexAnswer(primary: ["usedPercent": 3, "windowDurationMins": 10_080, "resetsAt": 1_800_400_000],
                                  secondary: ["usedPercent": 19, "windowDurationMins": 300, "resetsAt": 1_800_003_600])
        for answer in [codexAnswer(), swapped] {
            let snapshot = try CodexAppServer.parseRateLimits(answer, now: now)
            XCTAssertEqual(snapshot.windows.map(\.minutes), [300, 10_080])
            XCTAssertEqual(snapshot.windows.map(\.usedPercent), [19, 3])
        }
    }

    func testCodexToleratesNullAndIncompleteWindows() throws {
        let noSecondary = try CodexAppServer.parseRateLimits(codexAnswer(secondary: NSNull()), now: now)
        XCTAssertEqual(noSecondary.windows.count, 1)
        let noReset = try CodexAppServer.parseRateLimits(
            codexAnswer(primary: ["usedPercent": 40, "windowDurationMins": 300, "resetsAt": NSNull()]), now: now)
        XCTAssertEqual(noReset.windows.map(\.minutes), [10_080], "sans heure de remise à zéro, la fenêtre est ignorée")
        XCTAssertThrowsError(try CodexAppServer.parseRateLimits([:], now: now))
        XCTAssertThrowsError(try CodexAppServer.parseRateLimits(codexAnswer(primary: nil, secondary: nil), now: now))
    }

    // MARK: - Codex : magasin (cache, échec, oubli), avec un double

    private final class FakeQuota: CodexQuotaService {
        private let lock = NSLock()
        private var calls = 0
        var outcomes: [Result<QuotaSnapshot, Error>] = []
        var callCount: Int { lock.withLock { calls } }
        func rateLimits() throws -> QuotaSnapshot {
            try lock.withLock { () -> Result<QuotaSnapshot, Error> in
                calls += 1
                return outcomes.isEmpty ? .failure(CodexServiceError.timeout) : outcomes.removeFirst()
            }.get()
        }
    }

    private final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private func fresh(_ percent: Double) -> Result<QuotaSnapshot, Error> {
        .success(QuotaSnapshot(windows: [QuotaWindow(usedPercent: percent, resetsAt: now.addingTimeInterval(3600), minutes: 300)],
                               updatedAt: now))
    }

    func testStoreCachesForAMinuteThenReadsAgain() {
        let fake = FakeQuota()
        fake.outcomes = [fresh(10), fresh(20)]
        let clock = Clock(now)
        let store = CodexUsageStore(service: { fake }, now: { clock.date })
        store.refresh()
        XCTAssertTrue(spin { store.snapshot != nil })
        XCTAssertEqual(store.snapshot?.windows.first?.usedPercent, 10)

        clock.date = now.addingTimeInterval(CodexUsageStore.cacheAge - 1)
        store.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(fake.callCount, 1, "ouvrir et refermer le panneau dans la minute ne relance rien")

        clock.date = now.addingTimeInterval(CodexUsageStore.cacheAge + 1)
        store.refresh()
        XCTAssertTrue(spin { store.snapshot?.windows.first?.usedPercent == 20 })
        XCTAssertEqual(fake.callCount, 2)
    }

    func testFailureKeepsLastMeasureAndWaitsLonger() {
        let fake = FakeQuota()
        fake.outcomes = [fresh(10), .failure(CodexServiceError.failure("pas de compte")), fresh(30)]
        let clock = Clock(now)
        let store = CodexUsageStore(service: { fake }, now: { clock.date })
        store.refresh()
        XCTAssertTrue(spin { store.snapshot != nil })
        clock.date = now.addingTimeInterval(CodexUsageStore.cacheAge + 1)
        store.refresh()
        XCTAssertTrue(spin { store.lastError != nil })
        XCTAssertEqual(store.snapshot?.windows.first?.usedPercent, 10, "la dernière mesure reste")

        clock.date = now.addingTimeInterval(CodexUsageStore.cacheAge + 120)
        store.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(fake.callCount, 2, "après un échec, 15 min d'attente")

        clock.date = now.addingTimeInterval(CodexUsageStore.cacheAge + CodexUsageStore.failureBackoff + 5)
        store.refresh()
        XCTAssertTrue(spin { store.snapshot?.windows.first?.usedPercent == 30 })
        XCTAssertNil(store.lastError)
    }

    func testNoCodexMeansNoReadAndForgetDropsEverything() {
        let none = CodexUsageStore(service: { nil })
        none.refresh()
        none.start()
        none.stop()
        XCTAssertNil(none.snapshot)

        let fake = FakeQuota()
        fake.outcomes = [fresh(10)]
        let store = CodexUsageStore(service: { fake })
        store.refresh()
        XCTAssertTrue(spin { store.snapshot != nil })
        store.forget()
        XCTAssertNil(store.snapshot)
        fake.outcomes = [fresh(50)]
        store.refresh()
        XCTAssertTrue(spin { store.snapshot?.windows.first?.usedPercent == 50 }, "oublié, le cache ne bloque plus")
    }

    func testReadInFlightWhenForgottenIsDiscarded() {
        final class Slow: CodexQuotaService {
            let gate = DispatchSemaphore(value: 0)
            func rateLimits() throws -> QuotaSnapshot {
                gate.wait()
                return QuotaSnapshot(windows: [QuotaWindow(usedPercent: 77, resetsAt: Date().addingTimeInterval(600), minutes: 300)],
                                     updatedAt: Date())
            }
        }
        let slow = Slow()
        let store = CodexUsageStore(service: { slow })
        store.refresh()
        store.forget()
        slow.gate.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(store.snapshot, "onglet désactivé pendant la lecture : le résultat arrive trop tard")
    }

    func testTimerExistsOnlyBetweenStartAndStop() {
        let store = CodexUsageStore(service: { nil })
        XCTAssertFalse(store.isTimerRunning)
        store.start()
        store.start()
        XCTAssertTrue(store.isTimerRunning)
        store.stop()
        XCTAssertFalse(store.isTimerRunning, "panneau fermé : aucun minuteur")
    }

    // MARK: - Codex : module

    func testModuleReadsQuotaOnlyWhileOpenAndEnabled() {
        let fake = FakeQuota()
        fake.outcomes = [fresh(10), fresh(11)]
        let defaults = makeEphemeralDefaults(self)
        // ~/.codex jetable : le module ne lit pas les vrais fichiers de Codex.
        let home = (try? makeTemporaryDirectory(self))?.appendingPathComponent(".codex") ?? URL(fileURLWithPath: "/nonexistent")
        let setup = CodexHookSetup(installer: { CodexHookInstaller(configDirectory: home, bundledHook: nil) })
        let module = CodexModule(setup: setup, usage: CodexUsageStore(service: { fake }), defaults: defaults)
        XCTAssertTrue(module.showsQuota, "allumé par défaut")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(fake.callCount, 0, "rien avant l'ouverture du panneau")

        module.start()
        XCTAssertTrue(spin { module.usage.snapshot != nil })
        XCTAssertTrue(module.usage.isTimerRunning)
        module.stop()
        XCTAssertFalse(module.usage.isTimerRunning)

        module.showsQuota = false
        XCTAssertNil(module.usage.snapshot, "réglage coupé : plus de chiffre")
        XCTAssertFalse(CodexModule(setup: setup, usage: CodexUsageStore(service: { fake }), defaults: defaults).showsQuota, "réglage mémorisé")
        module.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(fake.callCount, 1, "réglage coupé : aucun processus Codex")
        module.stop()

        module.showsQuota = true
        module.start()
        XCTAssertTrue(spin { module.usage.snapshot != nil })
        module.setTracking(false)
        XCTAssertNil(module.usage.snapshot, "onglet Codex désactivé : tout est oublié")
        module.stop()
    }
}

// MARK: - Ancien relais de statusLine : retrait au lancement

final class StatusLineInstallerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeTemporaryDirectory(self).appendingPathComponent(".claude")
    }

    private var installer: StatusLineInstaller {
        StatusLineInstaller(base: HookInstaller(configDirectory: dir, bundledHook: nil))
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    }

    private func settingsText() throws -> String { try String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8) }

    /// Relais posé par une version d'avant : script, copie de l'ancienne commande, settings.json qui pointe dessus.
    private func plantRelay(previous: String?, settings: String) throws {
        try FileManager.default.createDirectory(at: installer.scriptURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: installer.scriptURL, atomically: true, encoding: .utf8)
        if let previous { try previous.write(to: installer.previousURL, atomically: true, encoding: .utf8) }
        try write(settings)
    }

    private var relayCommand: String { "\"\(installer.scriptURL.path)\"" }

    func testLeftoverRelayGivesBackTheOriginalCommandAndItsKeys() throws {
        try plantRelay(previous: "sh ~/.claude/statusline-command.sh", settings: """
        {
          "model": "opus",
          "statusLine": {
            "type": "command",
            "command": \(relayCommand.debugDescription),
            "padding": 1
          }
        }

        """)
        installer.removeLeftovers()
        XCTAssertEqual(try settingsText(), """
        {
          "model": "opus",
          "statusLine": {
            "type": "command",
            "command": "sh ~/.claude/statusline-command.sh",
            "padding": 1
          }
        }

        """, "ancienne commande remise, autres clés et ordre gardés")
        XCTAssertFalse(installer.hasLeftovers, "script et copie supprimés")
    }

    func testLeftoverRelayWithoutPreviousCommandRemovesTheStatusLine() throws {
        try plantRelay(previous: nil, settings: "{ \"model\": \"opus\", \"statusLine\": { \"type\": \"command\", \"command\": \(relayCommand.debugDescription) } }\n")
        installer.removeLeftovers()
        XCTAssertFalse(try settingsText().contains("statusLine"))
        XCTAssertTrue(try settingsText().contains("opus"))
        XCTAssertFalse(installer.hasLeftovers)
    }

    func testStatusLineTheUserChangedSinceIsLeftAlone() throws {
        let mine = "{ \"statusLine\": { \"type\": \"command\", \"command\": \"echo mine\" } }\n"
        try plantRelay(previous: "echo old", settings: mine)
        installer.removeLeftovers()
        XCTAssertEqual(try settingsText(), mine)
        XCTAssertFalse(installer.hasLeftovers, "nos fichiers partent quand même")
    }

    func testUnreadableSettingsKeepTheRelayWorking() throws {
        try plantRelay(previous: "echo old", settings: "{ pas du json")
        installer.removeLeftovers()
        XCTAssertEqual(try settingsText(), "{ pas du json")
        XCTAssertTrue(installer.hasLeftovers, "settings.json pointe peut-être encore sur le script : on le garde")
    }

    func testNoLeftoverMeansSettingsAreNeverRead() throws {
        try write("{ pas du json")
        XCTAssertFalse(installer.hasLeftovers)
        installer.removeLeftovers()
        XCTAssertEqual(try settingsText(), "{ pas du json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("hooks").path))
    }
}
