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

    func testRealGlassTintIsInsideTheMaterialAndLighterThanTheBlurFallbackVeil() {
        XCTAssertEqual(PanelGlass.fallbackScrim, 0.55, "repli macOS 13 à 25 inchangé")
        XCTAssertGreaterThan(LiquidGlass.tintOpacity, 0)
        XCTAssertLessThan(LiquidGlass.tintOpacity, PanelGlass.fallbackScrim, "teinte dans le matériau, plus légère que le voile du repli")
    }

    /// Le bloc noir décalé de la 3.3.0 : avec le vrai verre, aucun fond plein dans la vue qui porte le verre, quel que soit l'état.
    func testRealGlassNeverPutsAFillInTheViewCarryingTheGlass() {
        for expanded in [false, true] {
            for hasNotch in [false, true] {
                for chameleon in [false, true] {
                    XCTAssertNotEqual(CollapsedFill.choose(liquidGlass: true, expanded: expanded, hasNotch: hasNotch, chameleon: chameleon),
                                      .inNotchView, "déplié \(expanded), encoche \(hasNotch), caméléon \(chameleon)")
                    XCTAssertEqual(CollapsedFill.choose(liquidGlass: false, expanded: expanded, hasNotch: hasNotch, chameleon: chameleon),
                                   .inNotchView, "autres fonds et repli flou : inchangés")
                }
            }
        }
    }

    func testRealGlassDrawsNoBlackOnARealNotchAndKeepsTheVirtualOnes() {
        XCTAssertEqual(CollapsedFill.choose(liquidGlass: true, expanded: false, hasNotch: true, chameleon: false), .absent,
                       "la caméra est noire d'elle-même")
        XCTAssertEqual(CollapsedFill.choose(liquidGlass: true, expanded: false, hasNotch: false, chameleon: false), .behindGlass,
                       "encoche virtuelle, pilule, perle : le fond reste, hors du verre")
        XCTAssertEqual(CollapsedFill.choose(liquidGlass: true, expanded: false, hasNotch: false, chameleon: true), .absent,
                       "le caméléon est en verre")
        XCTAssertEqual(CollapsedFill.choose(liquidGlass: true, expanded: true, hasNotch: false, chameleon: false), .absent,
                       "le panneau déplié est en verre")
    }

    func testWhiteTextStaysReadableOnTheBrightestBackdropWithTheBlurFallback() {
        XCTAssertGreaterThanOrEqual(PanelGlass.worstCaseContrast(), 4.5, "WCAG AA, fond d'écran blanc pur")
        XCTAssertLessThan(PanelGlass.worstCaseContrast(scrim: 0), 1.1, "sans teinte, le blanc sur blanc est illisible")
        XCTAssertGreaterThan(PanelGlass.worstCaseContrast(scrim: 0.8), PanelGlass.worstCaseContrast(scrim: 0.5))
    }
}
