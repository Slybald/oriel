import CoreWLAN
import Foundation
import XCTest
@testable import Oriel

/// Lecture de pmset et d'IOPS, messages d'osascript, garde-fous des accès réels. Les accès réels testés ici sont
/// en lecture seule ; aucune écriture (Wi-Fi, Bluetooth, économie d'énergie, caféine) n'est jamais lancée.
final class QuickSettingsSystemTests: XCTestCase {
    // MARK: - pmset -g accps

    /// pmset écrit les noms en MacRoman (« î » = 0x94) : le texte du test est encodé de la même façon.
    private func pmsetOutput(_ text: String) -> Data {
        text.data(using: .macOSRoman)!
    }

    func testPmsetParserReadsAccentedNamesWrittenInMacRoman() throws {
        let data = pmsetOutput("""
        Now drawing from 'Battery Power'
         -InternalBattery-0 (id=36700259)\t49%; discharging; 3:47 remaining present: true
         -AirPods Pro de Zoé (id=62395919)\t36%; charging; 0:00 remaining present: true
         -Boîtier AirPods Pro de Zoé (id=62395916)\t100%; discharging present: true

        """)
        XCTAssertNil(String(data: data, encoding: .utf8), "le fixture n'est pas de l'UTF-8 valide, comme la vraie sortie")
        let sources = PmsetBatteryParser.parse(data)
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources[0], PowerSourceInfo(name: "InternalBattery-0", kind: .mac, percent: 49,
                                                   isCharging: false, isPluggedIn: false, minutes: 227))
        XCTAssertEqual(sources[1].name, "AirPods Pro de Zoé")
        XCTAssertEqual(sources[1].kind, .accessory)
        XCTAssertTrue(sources[1].isCharging)
        XCTAssertEqual(sources[2].name, "Boîtier AirPods Pro de Zoé")
        XCTAssertEqual(sources[2].kind, .chargingCase)
        XCTAssertEqual(sources[2].percent, 100)
    }

    func testPmsetParserReadsUTF8AndPluggedInStates() {
        let sources = PmsetBatteryParser.parse(Data("""
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true
         -Étui AirPods de Léa (id=2)\t80%; finishing charge; (no estimate) present: true

        """.utf8))
        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources[0].isPluggedIn)
        XCTAssertFalse(sources[0].isCharging)
        XCTAssertNil(sources[0].minutes, "0:00 = pas d'estimation")
        XCTAssertEqual(sources[1].name, "Étui AirPods de Léa")
        XCTAssertEqual(sources[1].kind, .chargingCase)
        XCTAssertTrue(sources[1].isCharging, "finishing charge")
        XCTAssertFalse(sources[1].isPluggedIn, "seul le Mac est branché")
    }

    func testPmsetParserIgnoresNoise() {
        XCTAssertTrue(PmsetBatteryParser.parse(Data()).isEmpty)
        XCTAssertTrue(PmsetBatteryParser.parse(Data("Now drawing from 'AC Power'\n".utf8)).isEmpty)
        XCTAssertTrue(PmsetBatteryParser.parse(Data("\u{0}\u{1}garbage\n -x (id=1)\tabc%; foo\n".utf8)).isEmpty)
        let high = PmsetBatteryParser.parse(Data(" -A (id=1)\t140%; charging\n".utf8))
        XCTAssertEqual(high.first?.percent, 100, "borné")
    }

    func testAccessoryKindRecognisesCasesInSeveralLanguages() {
        for name in ["Boîtier AirPods", "Étui AirPods", "AirPods Pro Case", "AirPods Ladecase", "Estuche de AirPods"] {
            XCTAssertEqual(PowerSourceInfo.kind(ofAccessory: name), .chargingCase, name)
        }
        for name in ["AirPods Pro de Zoé", "Magic Keyboard", "Beats Studio"] {
            XCTAssertEqual(PowerSourceInfo.kind(ofAccessory: name), .accessory, name)
        }
    }

    /// Les accessoires que pmset liste (clavier, souris…) ne sont pas tous des casques.
    func testAccessorySymbolsFollowTheKindOfDevice() {
        func symbol(_ name: String, _ kind: PowerSourceInfo.Kind = .accessory) -> String {
            PowerSourceInfo(name: name, kind: kind, percent: 50, isCharging: false).symbol
        }
        XCTAssertEqual(symbol("Boîtier AirPods Pro", .chargingCase), "airpods.chargingcase")
        for name in ["AirPods Pro de Zoé", "AirPods Max", "Beats Studio Pro", "Powerbeats Pro"] {
            XCTAssertEqual(symbol(name), "headphones", name)
        }
        for name in ["Magic Keyboard", "Magic Mouse", "Magic Trackpad", "Clavier de Zoé"] {
            XCTAssertEqual(symbol(name), "dot.radiowaves.left.and.right", name)
        }
    }

    // MARK: - IOPS

    private func iops(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var description: [String: Any] = [
            "Type": "InternalBattery", "Name": "InternalBattery-0", "Current Capacity": 49, "Max Capacity": 100,
            "Is Charging": false, "Is Present": true, "Power Source State": "Battery Power",
            "Time to Empty": 227, "Time to Full Charge": 0, "Transport Type": "Internal",
        ]
        description.merge(overrides) { $1 }
        return description
    }

    func testIOPSDescriptionOfTheInternalBattery() throws {
        let battery = try XCTUnwrap(PowerSourceInfo(iops: iops()))
        XCTAssertEqual(battery, PowerSourceInfo(name: "InternalBattery-0", kind: .mac, percent: 49,
                                                isCharging: false, isPluggedIn: false, minutes: 227))
    }

    func testIOPSDescriptionWhileCharging() throws {
        let battery = try XCTUnwrap(PowerSourceInfo(iops: iops([
            "Is Charging": true, "Power Source State": "AC Power", "Time to Full Charge": 62, "Time to Empty": -1,
            "Current Capacity": 80,
        ])))
        XCTAssertTrue(battery.isCharging && battery.isPluggedIn)
        XCTAssertEqual(battery.minutes, 62)
        XCTAssertEqual(battery.percent, 80)
    }

    func testIOPSDescriptionEdgeCases() {
        XCTAssertNil(PowerSourceInfo(iops: iops(["Is Present": false])))
        XCTAssertNil(PowerSourceInfo(iops: iops(["Type": "UPS"])))
        XCTAssertNil(PowerSourceInfo(iops: iops(["Max Capacity": 0])))
        XCTAssertNil(PowerSourceInfo(iops: iops(["Time to Empty": -1]))?.minutes, "estimation en cours")
        XCTAssertEqual(PowerSourceInfo(iops: iops(["Current Capacity": 4700, "Max Capacity": 5000]))?.percent, 94,
                       "capacité en mAh : converti en pourcentage")
        let accessory = PowerSourceInfo(iops: iops(["Type": "Accessory Source", "Name": "Boîtier AirPods"]))
        XCTAssertEqual(accessory?.kind, .chargingCase)
        XCTAssertNil(accessory?.minutes)
    }

    /// Lecture réelle d'IOPS (lecture seule) : l'extraction ne plante pas et reste cohérente.
    func testRealIOPSReadIsConsistent() {
        let battery = SystemBattery()
        for _ in 0..<3 {
            let sources = battery.readIOPS()
            XCTAssertLessThanOrEqual(sources.filter { $0.kind == .mac }.count, 1)
            for source in sources { XCTAssertTrue((0...100).contains(source.percent), "\(source)") }
        }
        // Écoute puis arrêt de la source de notification sur la boucle principale.
        battery.startMonitoring {}
        battery.stopMonitoring()
        battery.stopMonitoring()
    }

    // MARK: - osascript, processus

    private func output(_ stderr: String, status: Int32 = 1, timedOut: Bool = false) -> SystemProcess.Output {
        SystemProcess.Output(status: status, stdout: Data(), stderr: Data(stderr.utf8), timedOut: timedOut)
    }

    func testOsascriptFailuresAreClassified() {
        XCTAssertEqual(SystemPowerMode.failure(output("0:60: execution error: User canceled. (-128)\n")).kind,
                       .cancelled)
        XCTAssertEqual(SystemPowerMode.failure(output("execution error: The administrator user name or password "
                                                      + "was incorrect. (-60005)")).kind, .denied)
        XCTAssertEqual(SystemPowerMode.failure(output("", timedOut: true)).kind, .timeout)
        let other = SystemPowerMode.failure(output("\n  execution error: boom (1)\nsecond line\n"))
        XCTAssertEqual(other, QuickSettingsFailure(.failed, "execution error: boom (1)"))
    }

    func testSystemProcessRunsWithoutAShell() throws {
        let echo = try XCTUnwrap(SystemProcess.run("/bin/echo", ["$HOME; touch /nonexistent", "a b"], timeout: 5))
        XCTAssertEqual(String(decoding: echo.stdout, as: UTF8.self), "$HOME; touch /nonexistent a b\n",
                       "les arguments passent tels quels")
        XCTAssertEqual(echo.status, 0)
        XCTAssertEqual(try XCTUnwrap(SystemProcess.run("/usr/bin/false", [], timeout: 5)).status, 1)
        XCTAssertNil(SystemProcess.run("/nonexistent/program", [], timeout: 5))
    }

    func testSystemProcessTimesOut() throws {
        let result = try XCTUnwrap(SystemProcess.run("/bin/sleep", ["5"], timeout: 0.3))
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.status, 0)
    }

    // MARK: - Garde-fous des accès réels

    /// Hors de l'app, IOBluetooth fait avorter le processus (signal 6, mesuré dans xctest, qui porte pourtant la
    /// clé NSBluetoothAlwaysUsageDescription) : l'accès réel ne l'appelle que depuis l'app.
    func testRealBluetoothIsNeverCalledOutsideTheApp() {
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, AppIdentity.bundleId)
        let bluetooth = SystemBluetooth()
        XCTAssertNil(bluetooth.isPoweredOn())
        XCTAssertFalse(bluetooth.setPower(true), "aucune écriture n'est partie")
    }

    func testRealPowerModeReadsOnly() {
        let power = SystemPowerMode()
        _ = power.isLowPowerEnabled
        let supportChecked = expectation(description: "pmset -g custom")
        power.checkSupport { _ in
            XCTAssertTrue(Thread.isMainThread)
            supportChecked.fulfill()
        }
        power.startMonitoring {}
        power.stopMonitoring()
        wait(for: [supportChecked], timeout: 5)
    }

    /// Le SDK documente le refus d'autorisation de CoreWLAN par kCWOperationNotPermittedErr (CWErrorDomain, -3930).
    func testWiFiPermissionRefusalsAreClassifiedAsDenied() {
        let notPermitted = NSError(domain: CWErrorDomain, code: -3930,
                                   userInfo: [NSLocalizedDescriptionKey: "Operation not permitted by the system"])
        XCTAssertEqual(SystemWiFi.failure(notPermitted), QuickSettingsFailure(.denied))
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        XCTAssertEqual(SystemWiFi.failure(posix).kind, .denied)
        XCTAssertEqual(SystemWiFi.failure(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))).kind, .denied)
        let other = NSError(domain: CWErrorDomain, code: -3931, userInfo: [NSLocalizedDescriptionKey: "boom"])
        XCTAssertEqual(SystemWiFi.failure(other), QuickSettingsFailure(.failed, "boom"))
    }

    func testRealWiFiInterfaceIsOnlyRead() {
        let wifi = SystemWiFi()
        let power = wifi.isPoweredOn()
        if power == nil {
            XCTAssertFalse(wifi.isAssociated())
        }
        wifi.startMonitoring {}
        wifi.stopMonitoring()
        wifi.stopMonitoring()
    }
}
