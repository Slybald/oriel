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

    // MARK: - Claude : JSON de la statusLine

    private func statusLine(_ limits: [String: Any]?) -> Data {
        var json: [String: Any] = ["version": "2.1.304", "model": ["display_name": "Opus"], "session_id": "s1",
                                   "workspace": ["current_dir": "/tmp/demo"]]
        if let limits { json["rate_limits"] = limits }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    func testClaudeParsesBothWindows() throws {
        let data = statusLine(["five_hour": ["used_percentage": 39, "resets_at": 1_800_003_600],
                               "seven_day": ["used_percentage": 63.4, "resets_at": 1_800_400_000]])
        let snapshot = try XCTUnwrap(ClaudeUsage.parse(data, now: now))
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [39, 63])
        XCTAssertEqual(snapshot.windows.map(\.minutes), [300, 10_080])
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertEqual(snapshot.updatedAt, now)
    }

    func testClaudeToleratesMissingWindowsAndGarbage() {
        // Avant la première réponse, ou hors abonnement Pro et Max : pas de rate_limits du tout.
        XCTAssertNil(ClaudeUsage.parse(statusLine(nil), now: now))
        XCTAssertNil(ClaudeUsage.parse(statusLine([:]), now: now))
        XCTAssertNil(ClaudeUsage.parse(Data("pas du JSON".utf8), now: now))
        XCTAssertNil(ClaudeUsage.parse(Data("[1,2]".utf8), now: now))
        // Une seule fenêtre : l'autre manque.
        let only7 = ClaudeUsage.parse(statusLine(["seven_day": ["used_percentage": 5, "resets_at": 1_800_400_000]]), now: now)
        XCTAssertEqual(only7?.windows.count, 1)
        XCTAssertEqual(only7?.windows.first?.minutes, 10_080)
        // Champs de mauvais type ou incomplets : ignorés sans planter. Le plafond « gateway » n'est pas lu.
        let odd = statusLine(["five_hour": ["used_percentage": "beaucoup", "resets_at": 1_800_003_600],
                              "seven_day": ["used_percentage": 5],
                              "spend_limit": ["used_percentage": 50, "resets_at": 1_800_003_600]])
        XCTAssertNil(ClaudeUsage.parse(odd, now: now))
    }

    func testClaudeStoreKeepsTheLastMeasureAndForgets() throws {
        let store = ClaudeUsageStore()
        store.ingest(statusLine(["five_hour": ["used_percentage": 20, "resets_at": 1_800_003_600]]), now: now)
        XCTAssertEqual(store.snapshot?.windows.first?.usedPercent, 20)
        store.ingest(statusLine(nil), now: now.addingTimeInterval(5))
        XCTAssertEqual(store.snapshot?.windows.first?.usedPercent, 20, "un JSON sans quota ne l'efface pas")
        store.ingest(statusLine(["five_hour": ["used_percentage": 25, "resets_at": 1_800_003_600]]), now: now.addingTimeInterval(9))
        XCTAssertEqual(store.snapshot?.windows.first?.usedPercent, 25)
        store.forget()
        XCTAssertNil(store.snapshot)
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

// MARK: - Relais de statusLine : installeur

final class StatusLineInstallerTests: XCTestCase {
    private var dir: URL!
    private var bundled: URL!

    override func setUpWithError() throws {
        dir = try makeTemporaryDirectory(self).appendingPathComponent(".claude")
        bundled = dir.deletingLastPathComponent().appendingPathComponent("oriel-statusline.sh")
        try "#!/bin/sh\nexit 0\n".write(to: bundled, atomically: true, encoding: .utf8)
    }

    private func installer(bundled: URL? = nil) -> StatusLineInstaller {
        StatusLineInstaller(base: HookInstaller(configDirectory: dir, bundledHook: nil), bundledScript: bundled ?? self.bundled)
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    }

    private func settingsText() throws -> String { try String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8) }

    private func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(".oriel-") }
    }

    private let withLine = """
    {
      "model": "opus",
      "statusLine": {
        "type": "command",
        "command": "sh ~/.claude/statusline-command.sh",
        "padding": 1
      },
      "hooks": {}
    }

    """

    func testInstallChainsTheExistingCommandAndKeepsItsOtherKeys() throws {
        try write(withLine)
        let installer = installer()
        XCTAssertEqual(installer.status(), .notInstalled)
        let outcome = try installer.install()
        XCTAssertTrue(outcome.settingsChanged)
        XCTAssertEqual(installer.status(), .installed)
        XCTAssertEqual(installer.previousCommand, "sh ~/.claude/statusline-command.sh")

        let text = try settingsText()
        XCTAssertTrue(text.contains(installer.command.replacingOccurrences(of: "\"", with: "\\\"")), text)
        XCTAssertTrue(text.contains("\"padding\": 1"), "les autres clés de la statusLine restent")
        XCTAssertTrue(text.contains("\"model\": \"opus\""))
        XCTAssertFalse(text.contains("statusline-command"), "l'ancienne commande n'est plus dans settings.json")
        XCTAssertEqual(backups().count, 1, "sauvegarde horodatée")

        let modes = try [installer.scriptURL, installer.previousURL].map {
            (try FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber)?.intValue
        }
        XCTAssertEqual(modes, [0o755, 0o600])
    }

    func testUninstallRestoresTheOriginalFileExactly() throws {
        try write(withLine)
        let original = try settingsText()
        let installer = installer()
        try installer.install()
        let outcome = try installer.uninstall()
        XCTAssertTrue(outcome.settingsChanged)
        XCTAssertEqual(try settingsText(), original, "retrait propre : octet pour octet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.scriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.previousURL.path))
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testInstallWithoutStatusLineCreatesOneAndUninstallRemovesIt() throws {
        try write("{\n  \"model\": \"opus\"\n}\n")
        let original = try settingsText()
        let installer = installer()
        try installer.install()
        XCTAssertEqual(installer.status(), .installed)
        XCTAssertNil(installer.previousCommand)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.previousURL.path))
        try installer.uninstall()
        XCTAssertEqual(try settingsText(), original)
    }

    func testInstallWithoutSettingsFile() throws {
        let installer = installer()
        try installer.install()
        XCTAssertEqual(installer.status(), .installed)
        XCTAssertTrue(backups().isEmpty, "rien à sauvegarder")
        try installer.uninstall()
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testInstallTwiceChangesNothingAndKeepsThePreviousCommand() throws {
        try write(withLine)
        let installer = installer()
        try installer.install()
        let once = try settingsText()
        let outcome = try installer.install()
        XCTAssertFalse(outcome.settingsChanged)
        XCTAssertEqual(try settingsText(), once)
        XCTAssertEqual(installer.previousCommand, "sh ~/.claude/statusline-command.sh", "pas de relais qui se relance lui-même")
        XCTAssertEqual(backups().count, 1)
    }

    func testUnsupportedStatusLineIsRefusedUntouched() throws {
        for line in ["\"echo\"", "{ \"type\": \"static\", \"text\": \"hi\" }", "{ \"type\": \"command\" }", "[1]"] {
            try write("{ \"statusLine\": \(line) }\n")
            let before = try settingsText()
            let installer = installer()
            XCTAssertEqual(installer.status(), .unsupported, line)
            XCTAssertThrowsError(try installer.install(), line) {
                XCTAssertEqual($0 as? StatusLineInstaller.Failure, .unsupportedStatusLine)
            }
            XCTAssertEqual(try settingsText(), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: installer.scriptURL.path), "ni script, ni copie")
            XCTAssertTrue(backups().isEmpty)
        }
    }

    func testInvalidSettingsAreNeverTouched() throws {
        try write("{ pas du json")
        let installer = installer()
        XCTAssertThrowsError(try installer.install())
        XCTAssertThrowsError(try installer.uninstall())
        XCTAssertEqual(try settingsText(), "{ pas du json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.scriptURL.path))
        if case .unreadable = installer.status() {} else { XCTFail("illisible attendu") }
    }

    func testUninstallLeavesAStatusLineTheUserChangedSince() throws {
        try write(withLine)
        let installer = installer()
        try installer.install()
        try write("{ \"statusLine\": { \"type\": \"command\", \"command\": \"echo mine\" } }\n")
        let outcome = try installer.uninstall()
        XCTAssertFalse(outcome.settingsChanged)
        XCTAssertTrue(try settingsText().contains("echo mine"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.scriptURL.path), "nos fichiers partent quand même")
    }

    func testOutdatedScriptIsDetectedAndUpdatedWithoutTouchingSettings() throws {
        try write(withLine)
        let installer = installer()
        try installer.install()
        try "#!/bin/sh\n# nouvelle version\nexit 0\n".write(to: bundled, atomically: true, encoding: .utf8)
        XCTAssertEqual(installer.status(), .scriptOutdated)
        let before = try settingsText()
        try installer.updateScript()
        XCTAssertEqual(installer.status(), .installed)
        XCTAssertEqual(try settingsText(), before)
        XCTAssertEqual(installer.previousCommand, "sh ~/.claude/statusline-command.sh")
    }

    func testMissingBundledScriptChangesNothing() throws {
        try write(withLine)
        let before = try settingsText()
        let missing = StatusLineInstaller(base: HookInstaller(configDirectory: dir, bundledHook: nil), bundledScript: nil)
        XCTAssertThrowsError(try missing.install()) { XCTAssertEqual($0 as? StatusLineInstaller.Failure, .missingBundledScript) }
        XCTAssertEqual(try settingsText(), before)
    }

    func testSetupForgetsTheQuotaWhenTurnedOff() throws {
        try write(withLine)
        let usage = ClaudeUsageStore()
        usage.ingest(Data(#"{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":1800003600}}}"#.utf8))
        let setup = StatusLineSetup(installer: { self.installer() }, usage: usage)
        setup.setOn(true)
        XCTAssertTrue(setup.isOn)
        XCTAssertTrue(setup.chainsPrevious)
        XCTAssertFalse(setup.messageIsError)
        setup.setOn(false)
        XCTAssertFalse(setup.isOn)
        XCTAssertNil(usage.snapshot)
        try write("{ \"statusLine\": 3 }\n")
        setup.setOn(true)
        XCTAssertTrue(setup.messageIsError)
        XCTAssertEqual(setup.status, .unsupported)
    }
}

// MARK: - Route du serveur et vrai script du relais

final class StatusLineRelayTests: XCTestCase {
    private static let script = repositoryRoot.appendingPathComponent("hooks/oriel-statusline.sh")

    private final class Received {
        private let lock = NSLock()
        private var bodies: [Data] = []
        func add(_ data: Data) { lock.withLock { bodies.append(data) } }
        var all: [Data] { lock.withLock { bodies } }
    }

    private func makeFixture() throws -> (ReplyServerFixture, Received) {
        let fixture = try ReplyServerFixture(self)
        let received = Received()
        fixture.server.onClaudeStatus = { received.add($0) }
        return (fixture, received)
    }

    private let json = #"{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":39,"resets_at":1800003600},"seven_day":{"used_percentage":63,"resets_at":1800400000}}}"#

    func testRouteNeedsHostAndTokenAndAnswers204() throws {
        let (fixture, received) = try makeFixture()
        let body = Data(json.utf8)
        func status(_ method: String, _ headers: [(String, String)]) -> Int? {
            RawHTTP.send(port: fixture.port, RawHTTP.request(method, "/claude/status", headers: headers, body: body))?.status
        }
        XCTAssertEqual(status("POST", [fixture.host]), 401, "sans jeton")
        XCTAssertEqual(status("POST", [("Host", "evil.example:\(fixture.port)"), fixture.token]), 403, "DNS rebinding")
        XCTAssertEqual(status("POST", [fixture.host, fixture.token, ("Origin", "https://evil.example")]), 403, "Origin")
        XCTAssertEqual(status("GET", [fixture.host, fixture.token]), 404, "POST seulement")
        XCTAssertTrue(received.all.isEmpty, "aucune requête refusée n'a livré quoi que ce soit")
        XCTAssertEqual(status("POST", [fixture.host, fixture.token]), 204)
        XCTAssertTrue(spin { received.all.count == 1 })
        XCTAssertEqual(received.all.first, body)
    }

    func testPausedServerIgnoresTheStatus() throws {
        let (fixture, received) = try makeFixture()
        fixture.server.isPaused = true
        let request = RawHTTP.request("POST", "/claude/status", headers: [fixture.host, fixture.token], body: Data(json.utf8))
        XCTAssertEqual(RawHTTP.send(port: fixture.port, request)?.status, 204)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(received.all.isEmpty, "onglet Claude désactivé : rien n'est analysé")
    }

    /// Lance le vrai script avec `input` sur l'entrée standard ; `previous` est écrit à côté, comme le fait l'installeur.
    private func runScript(_ input: String, previous: String? = nil, port: UInt16, home: URL) throws -> (out: String, status: Int32) {
        let work = try makeTemporaryDirectory(self)
        let copy = work.appendingPathComponent("oriel-statusline.sh")
        try FileManager.default.copyItem(at: Self.script, to: copy)
        if let previous { try previous.write(to: work.appendingPathComponent("oriel-statusline.previous"), atomically: true, encoding: .utf8) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [copy.path]
        process.environment = ["HOME": home.path, "ORIEL_PORT": String(port), "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        XCTAssertTrue(spin(timeout: 10) { !process.isRunning }, "le script doit finir vite")
        return (String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), process.terminationStatus)
    }

    func testScriptRelaysTheJSONAndPrintsAMinimalLine() throws {
        let (fixture, received) = try makeFixture()
        let result = try runScript(json, port: fixture.port, home: fixture.home)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.out, "5h 39% · 7d 63%\n")
        XCTAssertTrue(spin { received.all.count == 1 })
        XCTAssertEqual(String(decoding: received.all[0], as: UTF8.self), json)
    }

    func testScriptRunsThePreviousCommandWithTheSameJSON() throws {
        let (fixture, received) = try makeFixture()
        // L'ancienne commande lit le JSON sur l'entrée standard, comme une vraie statusLine.
        let previous = #"jq=$(cat); printf 'avant:%s' "${#jq}" ; echo "$jq" | /usr/bin/grep -c rate_limits"#
        let result = try runScript(json, previous: previous, port: fixture.port, home: fixture.home)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.out, "avant:\(json.count)1\n", "même JSON que celui relayé, sortie de l'ancienne commande seule")
        XCTAssertTrue(spin { received.all.count == 1 })
    }

    func testScriptSendsNothingWithoutRateLimitsButStillChains() throws {
        let (fixture, received) = try makeFixture()
        let plain = #"{"model":{"display_name":"Opus"}}"#
        let result = try runScript(plain, previous: "echo ancienne", port: fixture.port, home: fixture.home)
        XCTAssertEqual(result.out, "ancienne\n")
        XCTAssertEqual(try runScript(plain, port: fixture.port, home: fixture.home).out, "", "rien à afficher, rien d'envoyé")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(received.all.isEmpty)
    }

    func testScriptStillChainsWhenTheAppIsClosed() throws {
        let home = try makeTemporaryDirectory(self)
        let result = try runScript(json, previous: "echo ancienne", port: 9, home: home)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.out, "ancienne\n", "app fermée ou jeton absent : la statusLine d'origine n'est jamais cassée")
    }
}
