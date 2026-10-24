import XCTest
@testable import FanControl

/// Bibliothèque FanControl et outil `fanctl` : décodage des valeurs, lecture des ventilateurs et des sondes,
/// validation des lignes de l'app, séquences d'écriture, bail et sécurité de température. Tout passe par un double
/// du SMC : aucun test n'écrit dans le vrai SMC (sans root, le noyau le refuserait de toute façon).
final class FanControlTests: XCTestCase {
    // MARK: - Double du SMC

    final class FakeSMC: SMCDevice {
        var values: [String: SMCValue]
        /// Décide si une écriture passe (par défaut : oui) ; appelé avant de changer la valeur.
        var accepts: (String, [UInt8]) -> Bool = { _, _ in true }
        private(set) var writes: [String] = []

        init(_ values: [String: SMCValue]) { self.values = values }

        func read(_ key: String) -> SMCValue? { values[key] }

        func write(_ key: String, _ bytes: [UInt8]) -> Bool {
            guard let value = values[key], value.bytes.count == bytes.count, accepts(key, bytes) else { return false }
            values[key]?.bytes = bytes
            writes.append("\(key)=\(SMCValue(type: value.type, bytes: bytes).number.map { String(Int($0)) } ?? "?")")
            return true
        }

        func allKeys() -> [String] { values.keys.sorted() }

        func number(_ key: String) -> Double? { values[key]?.number }

        static func flt(_ value: Float) -> SMCValue { SMCValue(type: "flt ", bytes: SMCValue.float(value)) }
        static func ui8(_ value: UInt8) -> SMCValue { SMCValue(type: "ui8 ", bytes: [value]) }

        /// Les clés et valeurs lues sur un MacBook Pro M3 Pro (deux ventilateurs, en automatique).
        static func macBookPro(cpu: Float = 70, gpu: Float = 55) -> FakeSMC {
            var values: [String: SMCValue] = ["FNum": ui8(2), "Ftst": ui8(0)]
            for fan in 0..<2 {
                values["F\(fan)Ac"] = flt(2317)
                values["F\(fan)Mn"] = flt(2317)
                values["F\(fan)Mx"] = flt(6800)
                values["F\(fan)Tg"] = flt(2317)
                values["F\(fan)Md"] = ui8(0)
            }
            values["Tp04"] = flt(cpu - 5)
            values["Tp05"] = flt(cpu)
            values["Te04"] = flt(cpu - 10)
            values["Tg04"] = flt(gpu)
            values["Tf12"] = flt(-20) // sonde sans sens : ignorée
            values["TB0T"] = flt(30) // batterie : pas une sonde du processeur
            return FakeSMC(values)
        }
    }

    // MARK: - Valeurs

    /// Octets lus sur le vrai SMC du M3 Pro : `flt ` est un Float32 petit-boutiste.
    func testDecodesTheBytesMeasuredOnAnM3Pro() {
        XCTAssertEqual(SMCValue(type: "flt ", bytes: [0x00, 0xd0, 0x10, 0x45]).number, 2317)
        XCTAssertEqual(SMCValue(type: "flt ", bytes: [0x00, 0x80, 0xd4, 0x45]).number, 6800)
        XCTAssertEqual(SMCValue(type: "ui8 ", bytes: [2]).number, 2)
        XCTAssertEqual(SMCValue.float(2317), [0x00, 0xd0, 0x10, 0x45])
        XCTAssertEqual(SMCValue(type: "fpe2", bytes: [0x1f, 0x40]).number, 2000) // Intel : 14.2 gros-boutiste
        XCTAssertEqual(SMCValue(type: "sp78", bytes: [0x3e, 0x80]).number, 62.5) // Intel : 8.8 signé
        XCTAssertNil(SMCValue(type: "flt ", bytes: [0, 0]).number, "taille fausse")
        XCTAssertNil(SMCValue(type: "ch8*", bytes: [0x41]).number)
    }

    func testKeyCodesAreFourPrintableCharacters() {
        XCTAssertEqual(SMCConnection.code("FNum"), 0x464E_756D)
        XCTAssertEqual(SMCConnection.code("FS! "), 0x4653_2120)
        XCTAssertEqual(SMCConnection.text(0x464E_756D), "FNum")
        for bad in ["", "FNu", "FNumm", "F\u{0}um", "Fé1"] { XCTAssertNil(SMCConnection.code(bad), bad) }
    }

    // MARK: - Lecture

    func testReadsBothFansWithTheirBounds() {
        let fans = Fans.read(FakeSMC.macBookPro())
        XCTAssertEqual(fans, [FanReading(index: 0, actual: 2317, minimum: 2317, maximum: 6800, target: 2317, mode: 0),
                              FanReading(index: 1, actual: 2317, minimum: 2317, maximum: 6800, target: 2317, mode: 0)])
        XCTAssertTrue(Fans.supportsManualMode(FakeSMC.macBookPro(), fan: 0))
    }

    /// MacBook Air : pas de ventilateur, rien à afficher.
    func testAMacWithoutFansReadsNothing() {
        XCTAssertEqual(Fans.read(FakeSMC(["FNum": FakeSMC.ui8(0)])), [])
        XCTAssertEqual(Fans.read(FakeSMC([:])), [])
    }

    /// Un ventilateur sans bornes lisibles ou cohérentes ne peut pas être borné : il est écarté.
    func testFansWithoutUsableBoundsAreSkipped() {
        let smc = FakeSMC.macBookPro()
        smc.values["F0Mn"] = nil
        smc.values["F1Mx"] = FakeSMC.flt(1000) // maximum sous le minimum
        XCTAssertEqual(Fans.read(smc), [])
        smc.values["FNum"] = FakeSMC.ui8(200)
        smc.values["F1Mx"] = FakeSMC.flt(6800)
        XCTAssertEqual(Fans.read(smc).map(\.index), [1], "FNum absurde : on s'arrête à huit")
    }

    /// Mac Intel : ni `F<n>Md` ni cible `flt ` ; lecture seule.
    func testIntelFansAreReadOnly() {
        let smc = FakeSMC.macBookPro()
        smc.values["F0Md"] = nil
        XCTAssertFalse(Fans.supportsManualMode(smc, fan: 0))
        smc.values["F1Tg"] = SMCValue(type: "fpe2", bytes: [0x24, 0x34])
        XCTAssertFalse(Fans.supportsManualMode(smc, fan: 1))
    }

    func testThermalsKeepTheHottestCPUAndGPUProbes() {
        XCTAssertEqual(Thermals(smc: FakeSMC.macBookPro(cpu: 81, gpu: 57)).read(), Thermals.Reading(cpu: 81, gpu: 57))
        XCTAssertEqual(Thermals.Reading(cpu: 81, gpu: 57).hottest, 81)
        XCTAssertNil(Thermals(smc: FakeSMC(["FNum": FakeSMC.ui8(0)])).read().hottest)
        // Intel : sondes TC… / TG… en sp78.
        let intel = FakeSMC(["TC0P": SMCValue(type: "sp78", bytes: [0x40, 0x00]),
                             "TG0P": SMCValue(type: "sp78", bytes: [0x30, 0x00])])
        XCTAssertEqual(Thermals(smc: intel).read(), Thermals.Reading(cpu: 64, gpu: 48))
    }

    // MARK: - Lignes de l'app

    private let fans = Fans.read(FakeSMC.macBookPro())

    func testValidRequests() {
        XCTAssertEqual(try FanRequest.parse("ping", fans: fans).get(), .ping)
        XCTAssertEqual(try FanRequest.parse("auto", fans: fans).get(), .automatic)
        XCTAssertEqual(try FanRequest.parse("fan 0 2317", fans: fans).get(), .manual(fan: 0, rpm: 2317))
        XCTAssertEqual(try FanRequest.parse("fan 1 6800", fans: fans).get(), .manual(fan: 1, rpm: 6800))
        XCTAssertEqual(try FanRequest.parse("fan 1 4000", fans: fans).get(), .manual(fan: 1, rpm: 4000))
    }

    /// Jamais sous le minimum ni au-dessus du maximum lus dans le SMC ; aucun ventilateur inventé.
    func testOutOfBoundsRequestsAreRefused() {
        XCTAssertEqual(refusal("fan 0 2316"), .belowMinimum)
        XCTAssertEqual(refusal("fan 0 0"), .belowMinimum)
        XCTAssertEqual(refusal("fan 0 6801"), .aboveMaximum)
        XCTAssertEqual(refusal("fan 1 99999"), .aboveMaximum)
        XCTAssertEqual(refusal("fan 2 3000"), .unknownFan)
        XCTAssertEqual(refusal("fan 9 3000"), .unknownFan)
    }

    /// Syntaxe stricte : pas de signe, d'espace en trop, de zéro de tête, de chiffres non ASCII, d'autre mot.
    func testMalformedRequestsAreRefused() {
        let lines = ["", " ", "PING", "ping ", " ping", "auto now", "manual", "fan", "fan 0", "fan 0 3000 1",
                     "fan  0 3000", "fan 0  3000", "fan -1 3000", "fan +1 3000", "fan 01 3000", "fan 0 03000",
                     "fan 0 3e3", "fan 0 3000.5", "fan 0 -3000", "fan 0 ３０００", "fan 0 123456", "fan\t0\t3000",
                     "fan 0 3000\u{0}", "fan 0 3000\r", "FAN 0 3000", "fan x 3000", "fan 0 " + String(repeating: "9", count: 40)]
        for line in lines { XCTAssertEqual(refusal(line), .syntax, line.debugDescription) }
    }

    private func refusal(_ line: String) -> FanRequest.Refusal? {
        if case .failure(let refusal) = FanRequest.parse(line, fans: fans) { return refusal }
        return nil
    }

    // MARK: - Écriture

    func testManualModeWritesTheModeThenTheTarget() {
        let smc = FakeSMC.macBookPro()
        XCTAssertTrue(Fans.setManual(smc, fan: 1, rpm: 4000, pause: { _ in }))
        XCTAssertEqual(smc.writes, ["F1Md=1", "F1Tg=4000"])
        XCTAssertEqual(smc.number("Ftst"), 0, "pas de déverrouillage quand le mode passe directement")
    }

    /// M3 et suivantes : `F<n>Md` refusé tant que `Ftst` ne vaut pas 1, puis encore quelques essais.
    func testManualModeUnlocksWithFtstAndRetries() {
        let smc = FakeSMC.macBookPro()
        var refusalsAfterUnlock = 3
        smc.accepts = { key, _ in
            guard key == "F0Md" else { return true }
            guard smc.number("Ftst") == 1 else { return false }
            refusalsAfterUnlock -= 1
            return refusalsAfterUnlock < 0
        }
        var pauses: [Double] = []
        XCTAssertTrue(Fans.setManual(smc, fan: 0, rpm: 3000, pause: { pauses.append($0) }))
        XCTAssertEqual(smc.writes, ["Ftst=1", "F0Md=1", "F0Tg=3000"])
        XCTAssertEqual(pauses, [0.1, 0.1, 0.1, 0.1])
    }

    /// Mode jamais accepté : on abandonne après 10 s, sans écrire de cible.
    func testManualModeGivesUpWithoutWritingTheTarget() {
        let smc = FakeSMC.macBookPro()
        smc.accepts = { key, _ in key != "F0Md" }
        var pauses = 0
        XCTAssertFalse(Fans.setManual(smc, fan: 0, rpm: 3000, pause: { _ in pauses += 1 }))
        XCTAssertEqual(pauses, 100)
        XCTAssertEqual(smc.writes, ["Ftst=1"])
        smc.values["Ftst"] = nil
        XCTAssertFalse(Fans.setManual(smc, fan: 0, rpm: 3000, pause: { _ in }), "pas de clé de déverrouillage")
    }

    func testAutomaticReleasesEveryFanThenFtst() {
        let smc = FakeSMC.macBookPro()
        XCTAssertTrue(Fans.setManual(smc, fan: 0, rpm: 3000, pause: { _ in }))
        smc.values["Ftst"] = FakeSMC.ui8(1)
        XCTAssertTrue(Fans.setAutomatic(smc))
        XCTAssertEqual(Array(smc.writes.suffix(3)), ["F0Md=0", "F1Md=0", "Ftst=0"])
        XCTAssertEqual(smc.number("F0Md"), 0)
    }

    /// Un refus n'arrête pas le retour : les autres ventilateurs sont rendus quand même.
    func testAutomaticTriesEveryFanEvenAfterARefusal() {
        let smc = FakeSMC.macBookPro()
        smc.accepts = { key, _ in key != "F0Md" }
        XCTAssertFalse(Fans.setAutomatic(smc))
        XCTAssertEqual(smc.writes, ["F1Md=0", "Ftst=0"])
    }

    // MARK: - Tenue (bail)

    func testHoldAppliesValidLinesAndRefusesTheRest() {
        let smc = FakeSMC.macBookPro()
        let hold = FanHold(smc: smc, now: 0, pause: { _ in })
        XCTAssertEqual(hold.receive("fan 0 4000", now: 1), "ok")
        XCTAssertEqual(hold.receive("fan 1 4000", now: 1), "ok")
        XCTAssertEqual(hold.receive("fan 0 2000", now: 2), "refused below-minimum")
        XCTAssertEqual(hold.receive("fan 0 9000", now: 2), "refused above-maximum")
        XCTAssertEqual(hold.receive("rm -rf /", now: 2), "refused syntax")
        XCTAssertEqual(hold.targets, [0: 4000, 1: 4000])
        XCTAssertEqual(smc.writes, ["F0Md=1", "F0Tg=4000", "F1Md=1", "F1Tg=4000"], "rien d'écrit pour un refus")
        XCTAssertEqual(hold.receive("ping", now: 3), "ok")
        XCTAssertNil(hold.tick(now: 4, hottest: 70))
    }

    func testAutoLineReturnsEverythingToMacOSAndEndsTheHold() {
        let smc = FakeSMC.macBookPro()
        let hold = FanHold(smc: smc, now: 0, pause: { _ in })
        _ = hold.receive("fan 0 4000", now: 1)
        XCTAssertEqual(hold.receive("auto", now: 2), "auto requested")
        XCTAssertEqual(smc.number("F0Md"), 0)
        XCTAssertEqual(hold.ending, .requested)
        XCTAssertEqual(hold.receive("fan 0 5000", now: 3), "auto requested", "plus rien n'est appliqué ensuite")
        XCTAssertEqual(smc.number("F0Tg"), 4000)
    }

    /// Sans nouvelles de l'app pendant 30 s (figée, ou Mac sorti de veille) : automatique. Une ligne refusée ne
    /// renouvelle pas le bail.
    func testLeaseExpiresWithoutValidLines() {
        let smc = FakeSMC.macBookPro()
        let hold = FanHold(smc: smc, now: 0, pause: { _ in })
        _ = hold.receive("fan 0 4000", now: 0)
        XCTAssertEqual(hold.receive("ping", now: 25), "ok")
        XCTAssertNil(hold.tick(now: 50, hottest: 70), "renouvelé à 25 s")
        _ = hold.receive("n'importe quoi", now: 54)
        XCTAssertEqual(hold.tick(now: 55.5, hottest: 70), "auto lease")
        XCTAssertEqual(smc.number("F0Md"), 0)
        XCTAssertEqual(hold.ending, .lease)
    }

    /// L'app ferme le tube (elle quitte ou plante) ou un signal arrive : automatique, une seule fois.
    func testClosingOrSignalReturnsToAutomatic() {
        let smc = FakeSMC.macBookPro()
        let hold = FanHold(smc: smc, now: 0, pause: { _ in })
        _ = hold.receive("fan 1 5000", now: 0)
        XCTAssertEqual(hold.end(.closed), "auto closed")
        XCTAssertEqual(hold.end(.signal), "auto closed", "la première raison reste")
        XCTAssertEqual(smc.writes.filter { $0 == "F1Md=0" }.count, 1)
    }

    /// Au-delà du seuil, retour en automatique, sauf si tout est déjà au maximum (macOS ne ferait pas mieux).
    func testTemperatureSafety() {
        let smc = FakeSMC.macBookPro()
        let hold = FanHold(smc: smc, now: 0, pause: { _ in })
        XCTAssertNil(hold.tick(now: 1, hottest: 120), "rien de tenu : rien à rendre")
        _ = hold.receive("fan 0 6800", now: 1)
        XCTAssertNil(hold.tick(now: 2, hottest: FanHold.temperatureLimit + 3), "au maximum")
        _ = hold.receive("fan 1 3000", now: 2)
        XCTAssertNil(hold.tick(now: 3, hottest: FanHold.temperatureLimit - 0.1))
        XCTAssertNil(hold.tick(now: 3, hottest: nil))
        XCTAssertEqual(hold.tick(now: 4, hottest: FanHold.temperatureLimit), "auto temperature")
        XCTAssertEqual(smc.number("F0Md"), 0)
        XCTAssertEqual(smc.number("F1Md"), 0)
    }

    /// macOS reprend un ventilateur tenu : on ne lutte pas, tout revient en automatique.
    func testSystemTakingBackAFanEndsTheHold() {
        let smc = FakeSMC.macBookPro()
        let hold = FanHold(smc: smc, now: 0, pause: { _ in })
        _ = hold.receive("fan 0 4000", now: 0)
        smc.values["F0Md"] = FakeSMC.ui8(3)
        XCTAssertEqual(hold.tick(now: 2, hottest: 60), "auto system")
    }

    /// Le SMC refuse la vitesse : automatique tout de suite.
    func testWriteRefusalEndsTheHold() {
        let smc = FakeSMC.macBookPro()
        smc.accepts = { key, _ in key != "F0Tg" }
        let hold = FanHold(smc: smc, now: 0, pause: { _ in })
        XCTAssertEqual(hold.receive("fan 0 4000", now: 0), "auto write")
        XCTAssertEqual(smc.number("F0Md"), 0)
    }

    func testHoldOnlyKnowsFansThatSupportManualMode() {
        let smc = FakeSMC.macBookPro()
        smc.values["F1Md"] = nil
        let hold = FanHold(smc: smc, now: 0, pause: { _ in })
        XCTAssertEqual(hold.fans.map(\.index), [0])
        XCTAssertEqual(hold.receive("fan 1 4000", now: 0), "refused unknown-fan")
    }

    // MARK: - Outil compilé

    /// Le vrai binaire : arguments refusés (code 64), puis droits root exigés avant tout accès au SMC (code 77).
    /// Jamais exécuté en root, pour ne rien écrire.
    func testToolRefusesBadArgumentsAndRequiresRoot() throws {
        guard geteuid() != 0 else { throw XCTSkip("tests lancés en root : l'outil écrirait pour de vrai") }
        let tool = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("fanctl")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw XCTSkip("fanctl non compilé") }
        func run(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        for bad in [[], ["status"], ["auto", "now"], ["hold", "1"], ["--help"], ["AUTO"], ["fan", "0", "3000"]] {
            XCTAssertEqual(try run(bad), 64, bad.joined(separator: " "))
        }
        XCTAssertEqual(try run(["auto"]), 77)
        XCTAssertEqual(try run(["hold"]), 77)
    }
}
