import XCTest
@testable import Oriel

/// Choix « Verre » pour le fond du panneau : réglage, couleur de repli et lisibilité (sans fenêtre).
final class PanelGlassTests: XCTestCase {
    func testGlassIsAChoiceThatPersistsAndLeavesTheOthersAlone() {
        let defaults = makeEphemeralDefaults(self)
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.panelBackground, .black, "rien ne change pour qui ne choisit pas Verre")
        XCTAssertTrue(PanelBackground.allCases.contains(.glass))
        for other in [PanelBackground.black, .graphite, .midnight] { XCTAssertNotNil(other.hex) }
        XCTAssertNil(PanelBackground.glass.hex)

        prefs.panelBackground = .glass
        XCTAssertEqual(Preferences(defaults: defaults).panelBackground, .glass)
        XCTAssertEqual(defaults.string(forKey: "appearance.background"), "glass")
        XCTAssertEqual(prefs.panelColor.hexString, Preferences.glassFallbackHex, "couleur de repli (bulle, teinte repliée)")
        prefs.panelBackground = .graphite
        XCTAssertEqual(prefs.panelColor.hexString, PanelBackground.graphite.hex)
    }

    func testRealGlassHasNoDarkVeilAndTheBlurFallbackKeepsIt() {
        XCTAssertEqual(PanelGlass.scrim(liquid: true), 0, "le Liquid Glass assure seul la lisibilité, sans voile noir")
        XCTAssertEqual(PanelGlass.scrim(liquid: false), PanelGlass.fallbackScrim)
        XCTAssertEqual(PanelGlass.fallbackScrim, 0.55, "repli macOS 13 à 25 inchangé")
        XCTAssertLessThan(LiquidGlass.tintOpacity, PanelGlass.fallbackScrim, "teinte dans le matériau, plus légère que le voile du repli")
    }

    func testWhiteTextStaysReadableOnTheBrightestBackdropWithTheBlurFallback() {
        XCTAssertGreaterThanOrEqual(PanelGlass.worstCaseContrast(), 4.5, "WCAG AA, fond d'écran blanc pur")
        XCTAssertLessThan(PanelGlass.worstCaseContrast(scrim: 0), 1.1, "sans teinte, le blanc sur blanc est illisible")
        XCTAssertGreaterThan(PanelGlass.worstCaseContrast(scrim: 0.8), PanelGlass.worstCaseContrast(scrim: 0.5))
    }
}
