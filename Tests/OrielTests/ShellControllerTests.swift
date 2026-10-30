import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Oriel

/// Fenêtre de la notch et choix de l'écran : doubles d'écrans (avec ou sans encoche, plusieurs écrans),
/// encoche virtuelle, confidentialité, niveau de fenêtre, largeur et fond du panneau.
final class ShellControllerTests: XCTestCase {
    /// MacBook Pro 14" : encoche de 185 × 32 pt au milieu.
    private static let builtin = ScreenCandidate(
        name: "Écran Retina intégré", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), safeAreaTop: 32,
        auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5, isBuiltin: true)
    /// Écran externe à droite, plus haut, barre des menus de 25 pt.
    private static let external = ScreenCandidate(
        name: "DELL U2720Q", frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1415))
    /// Écran externe à gauche, principal (barre des menus « principale »), sans barre visible (masquée).
    private static let leftMain = ScreenCandidate(
        name: "LG HDR 4K", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))

    // MARK: - Choix de l'écran

    func testScreenPickerChoices() {
        let screens = [Self.leftMain, Self.builtin, Self.external]
        let onExternal = CGPoint(x: 2000, y: 100)
        XCTAssertEqual(NotchScreenPicker.pick(ScreenChoice.builtin, among: screens, mouse: onExternal), 1,
                       "écran avec encoche")
        XCTAssertEqual(NotchScreenPicker.pick(ScreenChoice.main, among: screens, mouse: onExternal), 0,
                       "premier écran = barre des menus principale")
        XCTAssertEqual(NotchScreenPicker.pick(ScreenChoice.mouse, among: screens, mouse: onExternal), 2)
        XCTAssertEqual(NotchScreenPicker.pick(ScreenChoice.mouse, among: screens, mouse: CGPoint(x: -10, y: 1080)), 0,
                       "bord haut compris")
        XCTAssertEqual(NotchScreenPicker.pick(ScreenChoice.mouse, among: screens, mouse: CGPoint(x: 1512, y: 500)), 2,
                       "bord commun : l'écran de droite")
        XCTAssertEqual(NotchScreenPicker.pick(ScreenChoice.mouse, among: screens, mouse: CGPoint(x: 9999, y: 9999)), 1,
                       "souris hors de tout écran : l'écran intégré")
        XCTAssertEqual(NotchScreenPicker.pick("DELL U2720Q", among: screens, mouse: .zero), 2, "par nom")
        XCTAssertEqual(NotchScreenPicker.pick("Projecteur", among: screens, mouse: .zero), 1, "nom débranché")
        XCTAssertNil(NotchScreenPicker.pick(ScreenChoice.builtin, among: [], mouse: .zero))

        // Capot fermé : plus d'encoche ; l'écran intégré n'est plus là, le premier sert.
        XCTAssertEqual(NotchScreenPicker.pick(ScreenChoice.builtin, among: [Self.leftMain, Self.external], mouse: .zero), 0)
        // Écran intégré sans encoche (MacBook Air d'avant 2022) : reconnu comme intégré.
        var oldAir = Self.builtin
        oldAir.safeAreaTop = 0
        oldAir.auxiliaryLeftWidth = nil
        oldAir.auxiliaryRightWidth = nil
        XCTAssertEqual(NotchScreenPicker.pick(ScreenChoice.builtin, among: [Self.external, oldAir], mouse: .zero), 1)
    }

    /// Deux écrans du même modèle : numérotés dans la liste, et le second reste choisissable.
    func testIdenticalScreensAreNumbered() {
        var twin = Self.external
        twin.frame.origin.x += 2560
        twin.visibleFrame.origin.x += 2560
        let screens = [Self.builtin, Self.external, twin]
        XCTAssertEqual(NotchScreenPicker.labels(screens), ["Écran Retina intégré", "DELL U2720Q", "DELL U2720Q (2)"])
        XCTAssertEqual(NotchScreenPicker.pick("DELL U2720Q", among: screens, mouse: .zero), 1)
        XCTAssertEqual(NotchScreenPicker.pick("DELL U2720Q (2)", among: screens, mouse: .zero), 2)
        XCTAssertEqual(NotchScreenPicker.pick("DELL U2720Q (2)", among: [Self.builtin, Self.external], mouse: .zero), 0,
                       "second écran débranché : l'écran intégré")
    }

    func testRealNotchAndVirtualNotchGeometry() {
        let real = NotchScreenPicker.notchRect(on: Self.builtin, menuBarThickness: 24)
        XCTAssertTrue(real.hasNotch)
        XCTAssertEqual(real.rect, CGRect(x: 663.5, y: 950, width: 185, height: 32))

        // Sans encoche : 200 pt, centrée, à la hauteur de la barre des menus de cet écran.
        let virtual = NotchScreenPicker.notchRect(on: Self.external, menuBarThickness: 24)
        XCTAssertFalse(virtual.hasNotch)
        XCTAssertEqual(virtual.rect.width, NotchScreenPicker.virtualNotchWidth)
        XCTAssertEqual(virtual.rect.height, 25)
        XCTAssertEqual(virtual.rect.midX, Self.external.frame.midX)
        XCTAssertEqual(virtual.rect.maxY, Self.external.frame.maxY)

        // Pilule : même taille, `pillGap` sous le haut de l'écran ; une vraie encoche ne bouge pas.
        let pill = NotchScreenPicker.notchRect(on: Self.external, menuBarThickness: 24, style: .pill)
        XCTAssertEqual(pill.rect.size, virtual.rect.size)
        XCTAssertEqual(pill.rect.maxY, Self.external.frame.maxY - NotchScreenPicker.pillGap)
        XCTAssertEqual(NotchScreenPicker.notchRect(on: Self.builtin, menuBarThickness: 24, style: .pill).rect, real.rect)

        // Barre des menus masquée automatiquement : épaisseur système.
        let hidden = NotchScreenPicker.notchRect(on: Self.leftMain, menuBarThickness: 24)
        XCTAssertEqual(hidden.rect.height, 24)
        XCTAssertEqual(hidden.rect.minX, -1920 + (1920 - 200) / 2)
    }

    // MARK: - Fenêtre

    private func controller(_ prefs: Preferences) -> NotchController {
        _ = NSApplication.shared
        return NotchController(store: SessionStore(), monitor: ClaudeMonitor(), prefs: prefs,
                               tools: ToolsFeed(paths: LayoutTests.absentPaths))
    }

    func testSharingTypeFollowsPrivacySetting() {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let notch = controller(prefs)
        XCTAssertEqual(notch.panel.sharingType, .readOnly, "visible dans les captures par défaut")
        prefs.hideFromCapture = true
        XCTAssertEqual(notch.panel.sharingType, .none, "appliqué à chaud")
        prefs.hideFromCapture = false
        XCTAssertEqual(notch.panel.sharingType, .readOnly)

        let hiddenAtLaunch = Preferences(defaults: makeEphemeralDefaults(self))
        hiddenAtLaunch.hideFromCapture = true
        XCTAssertEqual(controller(hiddenAtLaunch).panel.sharingType, .none, "dès la création")
    }

    /// Le réglage de confidentialité ne touche pas au niveau (isFloatingPanel avant level).
    func testWindowLevelUnchangedByShellSettings() throws {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.hideFromCapture = true
        let notch = controller(prefs)
        XCTAssertEqual(notch.panel.level.rawValue, NSWindow.Level.mainMenu.rawValue + 3)
        XCTAssertTrue(notch.panel.isFloatingPanel)
        notch.panel.orderFrontRegardless()
        defer { notch.panel.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(try XCTUnwrap(NotchController.windowServerLevel(of: notch.panel)),
                       NSWindow.Level.mainMenu.rawValue + 3)
    }

    /// Panneau ouvert au raccourci : Échap le ferme et rend le clavier, plein écran compact compris ; en compact,
    /// les flèches ne changent pas d'onglet (il n'y en a pas).
    func testEscapeClosesKeyboardPanelEvenInCompactFullScreen() throws {
        func key(_ code: Int, _ notch: NotchController) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: notch.panel.windowNumber, context: nil, characters: "",
                                           charactersIgnoringModifiers: "", isARepeat: false,
                                           keyCode: UInt16(code)))
        }
        for compact in [false, true] {
            let prefs = Preferences(defaults: makeEphemeralDefaults(self))
            prefs.hapticFeedback = false
            // Seul l'onglet Claude : aucun autre module ne démarre à l'ouverture.
            for id in ["media", "quicksettings", "shelf", "clipboard", "timer", "notes"] { prefs.tabEnabled[id] = false }
            let notch = controller(prefs)
            defer { notch.panel.orderOut(nil) }
            notch.model.isFullScreen = compact
            notch.togglePanelFromKeyboard()
            XCTAssertTrue(notch.model.isExpanded)
            XCTAssertTrue(notch.panel.isKeyWindow, "le raccourci donne le clavier au panneau")
            if compact { XCTAssertFalse(notch.handleKey(try key(kVK_RightArrow, notch)), "pas d'onglets en compact") }
            XCTAssertTrue(notch.handleKey(try key(kVK_Escape, notch)), compact ? "compact" : "normal")
            XCTAssertFalse(notch.model.isExpanded, compact ? "compact" : "normal")
            XCTAssertFalse(notch.panel.isKeyWindow, "clavier rendu")
        }
    }

    /// La fenêtre (fixe) contient la largeur libre maximale, ses rayons et son ombre.
    func testPanelWindowFitsWidestCustomPanel() {
        let widest = CGFloat(Preferences.customWidthRange.upperBound) + 2 * 12 + 2 * 20
        XCTAssertGreaterThanOrEqual(NotchController.panelSize.width, widest)
        XCTAssertLessThan(ExpandedPanel.maxPanelHeight, NotchController.panelSize.height)
    }

    // MARK: - Vue : largeur, fond, encoche virtuelle

    func testCustomWidthAppliedToView() {
        for width in [460.0, 650, 720] {
            let notch = NotchHarness(self, store: .working(1))
            notch.prefs.customPanelWidth = width
            notch.model.isExpanded = true
            XCTAssertEqual(notch.measure().width, CGFloat(width) + 24, accuracy: 1, "\(width)")
        }
        // Plein écran compact : demi-largeur quelle que soit la largeur libre.
        let compact = NotchHarness(self, store: .working(1))
        compact.prefs.customPanelWidth = 720
        compact.model.isFullScreen = true
        compact.model.isExpanded = true
        XCTAssertEqual(compact.measure().width, Preferences.compactPanelWidth + 24, accuracy: 1)
    }

    /// Repliée et sans activité : invisible sur une vraie encoche, dessinée sur un écran sans encoche ; noire
    /// sauf si « Teinter aussi la notch repliée » (et seulement sans encoche).
    func testCollapsedNotchColorAndVirtualNotch() throws {
        func collapsedPixel(hasNotch: Bool, tint: Bool) throws -> NSColor {
            let notch = NotchHarness(self)
            notch.model.hasNotch = hasNotch
            notch.model.notchSize = CGSize(width: 200, height: 24)
            notch.prefs.panelBackground = .midnight
            notch.prefs.tintCollapsed = tint
            return try pixel(of: notch.root, at: CGPoint(x: NotchController.panelSize.width / 2, y: 12))
        }
        XCTAssertLessThan(try collapsedPixel(hasNotch: true, tint: false).alphaComponent, 0.05,
                          "vraie encoche : la forme se fond dedans (transparente)")
        XCTAssertLessThan(try collapsedPixel(hasNotch: true, tint: true).alphaComponent, 0.05,
                          "teinte sans effet sur une vraie encoche")
        let virtual = try collapsedPixel(hasNotch: false, tint: false)
        XCTAssertGreaterThan(virtual.alphaComponent, 0.95, "encoche virtuelle dessinée")
        XCTAssertLessThan(virtual.brightnessComponent, 0.05, "noire")
        let tinted = try collapsedPixel(hasNotch: false, tint: true)
        XCTAssertGreaterThan(tinted.blueComponent, tinted.redComponent + 0.05, "teintée bleu nuit")
    }

    func testExpandedBackgroundFollowsSetting() throws {
        func expandedPixel(_ background: PanelBackground, custom: String? = nil) throws -> NSColor {
            let notch = NotchHarness(self)
            notch.prefs.panelBackground = background
            if let custom { notch.prefs.customBackgroundHex = custom }
            notch.model.isExpanded = true
            // Sous la bande et l'en-tête, à gauche du contenu : le fond seul.
            let left = (NotchController.panelSize.width - PanelSize.standard.width) / 2
            return try pixel(of: notch.root, at: CGPoint(x: left + 6, y: 32 + ExpandedPanel.headerHeight + 30))
        }
        // Référence : la même couleur pleine, rendue par le même chemin (le rendu hors écran décale le gamma).
        func reference(_ hex: String) throws -> NSColor {
            try pixel(of: (Color(hex: hex) ?? .clear).frame(maxWidth: .infinity, maxHeight: .infinity),
                      at: CGPoint(x: 10, y: 10))
        }
        func hex(_ color: NSColor) -> String? { Color(nsColor: color).hexString }
        XCTAssertEqual(hex(try expandedPixel(.black)), "000000")
        XCTAssertEqual(hex(try expandedPixel(.graphite)), hex(try reference("2A2B30")))
        XCTAssertEqual(hex(try expandedPixel(.midnight)), hex(try reference("101B33")))
        XCTAssertEqual(hex(try expandedPixel(.custom, custom: "3A1F5D")), hex(try reference("3A1F5D")))
        XCTAssertNotEqual(hex(try expandedPixel(.graphite)), hex(try expandedPixel(.midnight)))
    }

    /// Rendu hors écran de la vue dans un contexte sRGB, couleur d'un point (origine en haut à gauche).
    private func pixel<V: View>(of view: V, at point: CGPoint) throws -> NSColor {
        let size = NotchController.panelSize
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        defer { window.close() }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cg = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                         bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Le calque de NSHostingView est retourné : on remet l'origine en haut.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        try XCTUnwrap(hosting.layer).render(in: cg)
        let image = try XCTUnwrap(cg.makeImage())
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: Int(point.x), y: Int(point.y)))
        return try XCTUnwrap(color.usingColorSpace(.sRGB))
    }
}
