import XCTest
@testable import Oriel

/// Page Santé : modèle pur, sans fenêtre.
final class HealthTests: XCTestCase {
    func testModuleRunningAndStopped() {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let running = FakeModule(id: "claude", keepsRunning: true)
        let stopped = FakeModule(id: "a")
        let off = FakeModule(id: "b", enabledByDefault: false)
        let registry = ModuleRegistry(modules: [running, stopped, off], prefs: prefs)
        let report = registry.healthReport(version: "1.2.3")
        XCTAssertEqual(report.modules.map { HealthReport.moduleStatus($0) }, ["en marche", "au repos", "désactivé"])
        XCTAssertEqual(report.runningCount, 1)
        XCTAssertEqual(report.version, "1.2.3")
        XCTAssertTrue(report.process.map { $0.memoryBytes > 0 && $0.uptimeSeconds >= 0 } ?? false, "mesure réelle")
        registry.setPanelOpen(true)
        XCTAssertEqual(registry.healthReport(version: "x").runningCount, 2)
    }

    func testMissingPermissionShowsInReportText() {
        let report = HealthReport(version: "1", modules: [],
                                  permissions: [HealthPermissionRow(title: "Calendriers", state: .missing)],
                                  soberReason: nil, process: nil)
        XCTAssertTrue(report.text.contains("Calendriers : manquante"))
        XCTAssertTrue(report.text.contains("Mode sobre : inactif"))
        XCTAssertFalse(report.text.contains("/Users"))
    }

    func testSoberEntersAndLeaves() {
        XCTAssertFalse(SoberMode.isSober(lowPower: false, thermal: .nominal))
        XCTAssertFalse(SoberMode.isSober(lowPower: false, thermal: .fair))
        XCTAssertTrue(SoberMode.isSober(lowPower: true, thermal: .nominal), "économie d'énergie")
        XCTAssertTrue(SoberMode.isSober(lowPower: false, thermal: .serious), "chaleur forte")
        XCTAssertTrue(SoberMode.isSober(lowPower: false, thermal: .critical))
        XCTAssertFalse(SoberMode.isSober(lowPower: false, thermal: .nominal), "sortie")
        XCTAssertEqual(SoberMode.reason(lowPower: true, thermal: .nominal), "économie d'énergie")
        XCTAssertNil(SoberMode.reason(lowPower: false, thermal: .fair))
    }
}
