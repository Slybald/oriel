import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Mise en page et rendus PNG de l'onglet « Réglages rapides », sur des doubles.
/// Rendus : `ORIEL_SNAPSHOT_DIR=/dossier swift test --filter QuickSettingsSnapshotTests`.
final class QuickSettingsSnapshotTests: XCTestCase {
    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["ORIEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private struct Scene {
        let harness: NotchHarness
        let registry: ModuleRegistry
        let root: NotchRootView
    }

    private func scene(_ fixture: QuickSettingsFixture, expanded: Bool = true, fullScreen: Bool = false) -> Scene {
        let harness = NotchHarness(self)
        let registry = ModuleRegistry(modules: [harness.claude, fixture.module], prefs: harness.prefs)
        harness.model.isExpanded = expanded
        harness.model.selectedTab = "quicksettings"
        harness.model.isFullScreen = fullScreen
        let root = NotchRootView(model: harness.model, store: harness.store, registry: registry, prefs: harness.prefs,
                                 actions: NotchActions())
        return Scene(harness: harness, registry: registry, root: root)
    }

    // MARK: - États

    /// Tout éteint, un Mac portable sur batterie.
    private func idleFixture(authorization: LowPowerAuthorizationState = .none) -> QuickSettingsFixture {
        let f = QuickSettingsFixture(self)
        f.power.authorization = authorization
        f.wifi.power = true
        f.power.lowPower = false
        f.battery.iops = [QSFakeBattery.mac(percent: 78)]
        f.module.prefs.focusOnShortcut = "Concentration activer"
        f.module.prefs.focusOffShortcut = "Concentration désactiver"
        f.startAndShow()
        return f
    }

    /// Accessoires que pmset peut lister en plus des AirPods.
    private static let extraAccessories = [
        PowerSourceInfo(name: "Magic Keyboard", kind: .accessory, percent: 82, isCharging: false),
        PowerSourceInfo(name: "Magic Mouse", kind: .accessory, percent: 41, isCharging: true),
        PowerSourceInfo(name: "Magic Trackpad", kind: .accessory, percent: 95, isCharging: false),
    ]

    /// Tout actif : caféine, économie d'énergie, Concentration, en charge, AirPods (et d'autres accessoires),
    /// ventilateurs en vitesse fixe (la carte la plus haute : son curseur en plus).
    private func busyFixture(extraAccessories: Int = 0) -> QuickSettingsFixture {
        let f = QuickSettingsFixture(self)
        f.power.lowPower = true
        f.battery.iops = [QSFakeBattery.mac(percent: 64, pluggedIn: true, charging: true, minutes: 72)]
        f.battery.pmset = [FakeBatteryFixtures.pods, FakeBatteryFixtures.case]
            + Self.extraAccessories.prefix(extraAccessories)
        f.module.prefs.focusOnShortcut = "Concentration activer"
        f.module.prefs.focusOffShortcut = "Concentration désactiver"
        f.startAndShow()
        f.module.toggleFocus()
        f.module.startCaffeine(until: f.now.addingTimeInterval(72 * 60))
        f.module.applyScene(.autonomy)
        f.module.startCaffeine(until: f.now.addingTimeInterval(72 * 60))
        f.fans.status = QSFakeFans.macBookPro(actual: 4183, cpu: 88.6, gpu: 61.2)
        f.module.fans.read()
        f.module.fans.setFixed(rpm: 4200)
        return f
    }

    private func errorFixture() -> QuickSettingsFixture {
        let f = idleFixture()
        f.wifi.failure = QuickSettingsFailure(.denied)
        f.module.toggleWiFi()
        return f
    }

    private func desktopFixture() -> QuickSettingsFixture {
        let f = QuickSettingsFixture(self)
        f.wifi.power = nil
        f.bluetooth.power = nil
        f.power.supported = false
        f.battery.iops = []
        f.fans.status = nil
        f.startAndShow()
        return f
    }

    // MARK: - Mise en page (toujours exécutée)

    /// Le pire cas (toutes les tuiles, cinq accessoires, un message d'erreur avec action) tient dans le panneau, à
    /// chaque largeur.
    func testTabFitsInThePanelInTheWorstCase() {
        for size in PanelSize.allCases {
            let f = busyFixture(extraAccessories: 3)
            f.wifi.failure = QuickSettingsFailure(.failed, "Operation not permitted by the system")
            f.module.toggleWiFi()
            XCTAssertNotNil(f.module.issue)
            XCTAssertEqual(f.module.accessories.count, 5)
            let scene = scene(f)
            scene.harness.prefs.panelSize = size
            let measured = measure(scene)
            XCTAssertEqual(measured.width, size.width + 24, accuracy: 1, size.rawValue)
            XCTAssertLessThanOrEqual(measured.height, 461, size.rawValue)
            XCTAssertGreaterThan(measured.height, 200, size.rawValue)
        }
    }

    /// Plus de note de pied sur l'autorisation (la règle se pose au premier clic) : la hauteur ne dépend pas de son
    /// état, et le pire cas (cinq accessoires, une erreur) reste sous 460 pt dans les trois largeurs.
    func testNoAuthorizationFooterWhateverTheState() {
        for size in PanelSize.allCases {
            func height(_ state: LowPowerAuthorizationState) -> CGFloat {
                let f = busyFixture(extraAccessories: 3)
                f.power.authorization = state
                f.module.viewAppeared()
                f.wifi.failure = QuickSettingsFailure(.failed, "Operation not permitted by the system")
                f.module.toggleWiFi()
                let scene = scene(f)
                scene.harness.prefs.panelSize = size
                return measure(scene).height
            }
            let granted = height(.granted)
            XCTAssertLessThanOrEqual(granted, 461, size.rawValue)
            for state in [LowPowerAuthorizationState.onFirstUse, .none, .refused] {
                XCTAssertEqual(height(state), granted, "\(size.rawValue) : \(state)")
            }
        }
    }

    /// Au-delà de trois lignes, la carte ajoute une seule ligne « +N » : sa hauteur ne dépend plus du nombre
    /// d'accessoires.
    func testAccessoriesCardHasABoundedHeight() {
        let three = measure(scene(busyFixture(extraAccessories: 1))).height
        let five = measure(scene(busyFixture(extraAccessories: 3))).height
        let two = measure(scene(busyFixture())).height
        XCTAssertGreaterThan(three, two)
        XCTAssertLessThanOrEqual(five - three, 18, "une ligne « +N » de plus, pas deux lignes d'accessoires")
    }

    /// Titres de tuile et sous-titres de scène à la largeur « Compact » (480 pt), en français et en anglais (les
    /// tests n'ont pas les traductions : on lit les tables .strings). Mesuré dans le rendu : un titre de tuile
    /// dispose d'environ 82 pt (réductible à 80 %), un sous-titre de scène d'environ 100 pt (réductible à 85 %).
    func testTileAndSceneLabelsFitTheNarrowestPanel() throws {
        let url = repositoryRoot.appendingPathComponent("Resources/en.lproj/QuickSettings.strings")
        let english = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        func width(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
        }
        for translated in [false, true] {
            func shown(_ key: String) -> String { translated ? english[key, default: "?"] : key }
            for key in ["Wi-Fi", "Bluetooth", "Concentration", "Économie", "Caféine", "Secteur"] {
                XCTAssertLessThanOrEqual(width(shown(key), size: 11.5, weight: .semibold), 102, shown(key))
            }
            for scene in QuickScene.allCases {
                for flags in 0..<8 {
                    let key = QuickSettingsView.sceneSubtitle(scene, lowPowerSupported: flags & 1 != 0,
                                                              noBluetooth: flags & 2 != 0, withFocus: flags & 4 != 0,
                                                              canRestore: flags & 1 != 0)
                    XCTAssertLessThanOrEqual(width(shown(key), size: 10, weight: .regular), 110, shown(key))
                }
            }
        }
    }

    func testCompactModeFitsAndKeepsItsWidth() {
        let f = busyFixture()
        let scene = scene(f, fullScreen: true)
        let measured = measure(scene)
        XCTAssertEqual(measured.width, Preferences.compactPanelWidth + 24, accuracy: 1)
        XCTAssertLessThanOrEqual(measured.height, 461)
    }

    /// Le texte du résumé compact et celui des tuiles ne dépendent que de l'état du module.
    func testEarsOfTheCollapsedNotchShowTheCaffeine() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.startCaffeine(until: f.now.addingTimeInterval(3600))
        let scene = scene(f, expanded: false)
        scene.registry.reconcile()
        XCTAssertEqual(scene.registry.moduleEars?.text, "1h00")
    }

    // MARK: - Rendus PNG

    func testRenderStates() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        try render(scene(idleFixture()).root, name: "qs-idle", to: outputDir)
        try render(scene(busyFixture()).root, name: "qs-busy", to: outputDir)
        try render(scene(errorFixture()).root, name: "qs-error", to: outputDir)

        // Scène Autonomie appliquée : économie d'énergie, Bluetooth coupé, caféine arrêtée.
        let autonomy = idleFixture()
        autonomy.module.prefs.autonomyBluetoothOff = true
        autonomy.module.startCaffeine(until: autonomy.now.addingTimeInterval(3600))
        autonomy.module.applyScene(.autonomy)
        QuickSettingsFixture.settle()
        try render(scene(autonomy).root, name: "qs-scene-autonomy", to: outputDir)
        // Autorisation sans mot de passe : absente (cadenas + pied avec lien), en place (ni l'un ni l'autre),
        // refusée par sudo (pied « La redonner »), et le même en panneau « Compact ».
        for (name, state) in [("none", LowPowerAuthorizationState.none), ("granted", .granted), ("refused", .refused)] {
            try render(scene(idleFixture(authorization: state)).root, name: "qs-auth-\(name)", to: outputDir)
            let narrowAuth = scene(idleFixture(authorization: state))
            narrowAuth.harness.prefs.panelSize = .compact
            try render(narrowAuth.root, name: "qs-auth-\(name)-narrow", to: outputDir)
        }
        try render(scene(desktopFixture()).root, name: "qs-desktop", to: outputDir)
        try render(scene(busyFixture(), fullScreen: true).root, name: "qs-fullscreen", to: outputDir)
        try render(scene(desktopFixture(), fullScreen: true).root, name: "qs-fullscreen-desktop", to: outputDir)

        // Panneau « Compact » (480 pt), libellés les plus longs, cinq accessoires et une erreur : rien n'est tronqué.
        let narrow = idleFixture()
        narrow.battery.pmset = [FakeBatteryFixtures.pods, FakeBatteryFixtures.case] + Self.extraAccessories
        narrow.module.prefs.autonomyBluetoothOff = true
        narrow.module.prefs.presentationFocus = true
        narrow.module.viewAppeared()
        narrow.module.applyScene(.autonomy)
        narrow.wifi.failure = QuickSettingsFailure(.denied)
        narrow.module.toggleWiFi()
        let narrowScene = scene(narrow)
        narrowScene.harness.prefs.panelSize = .compact
        try render(narrowScene.root, name: "qs-narrow", to: outputDir)

        // Ventilateurs : rendus à macOS par l'outil (température), et lecture seule (Mac Intel).
        let notice = idleFixture()
        notice.module.fans.setFixed(rpm: 3000)
        notice.fans.say("auto temperature")
        try render(scene(notice).root, name: "qs-fans-notice", to: outputDir)
        let readOnly = QuickSettingsFixture(self)
        readOnly.fans.status?.supportsManual = false
        readOnly.startAndShow()
        try render(scene(readOnly).root, name: "qs-fans-readonly", to: outputDir)
        let narrowFans = scene(busyFixture())
        narrowFans.harness.prefs.panelSize = .compact
        try render(narrowFans.root, name: "qs-fans-fixed-narrow", to: outputDir)
        let fanEars = QuickSettingsFixture(self)
        fanEars.startAndShow()
        fanEars.module.fans.setFixed(rpm: 4200)
        let fanCollapsed = scene(fanEars, expanded: false)
        fanCollapsed.registry.reconcile()
        try render(fanCollapsed.root, name: "qs-collapsed-ears-fans", to: outputDir)

        // Oreilles de la notch repliée : caféine seule.
        let ears = QuickSettingsFixture(self)
        ears.startAndShow()
        ears.module.startCaffeine(until: ears.now.addingTimeInterval(72 * 60))
        let collapsed = scene(ears, expanded: false)
        collapsed.registry.reconcile()
        try render(collapsed.root, name: "qs-collapsed-ears", to: outputDir)

        // Accent clair (ambre) : le texte sur la couleur d'accent reste lisible. Réglages partagés remis en état.
        let original = Preferences.shared.accentHex
        Preferences.shared.accentHex = "F5B83D"
        defer {
            Preferences.shared.accentHex = original
            UserDefaults.standard.removeObject(forKey: "appearance.accent")
        }
        try render(scene(busyFixture()).root, name: "qs-busy-amber", to: outputDir)
        Preferences.shared.accentHex = "4C8DFF"
        try render(scene(busyFixture()).root, name: "qs-busy-blue", to: outputDir)
        Preferences.shared.accentHex = original
    }

    func testRenderSettings() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let f = busyFixture()
        let harness = NotchHarness(self)
        let registry = ModuleRegistry(modules: [harness.claude, f.module], prefs: harness.prefs)
        let view = SettingsView(prefs: harness.prefs, registry: registry, updater: Updater(),
                                selection: .module("quicksettings"))
        try render(view, name: "qs-settings", to: outputDir, size: SettingsWindow.size, background: nil)

        // Section « Ventilateurs » : outil absent, installé, d'une autre version.
        for state in [FanAuthorizationState.notInstalled, .installed, .outdated] {
            let fixture = idleFixture()
            fixture.fans.authorization = state
            fixture.module.fans.refreshAuthorization()
            try render(QuickSettingsSettingsView(module: fixture.module, prefs: fixture.module.prefs),
                       name: "qs-settings-fans-\(state)", to: outputDir,
                       size: CGSize(width: SettingsWindow.size.width - 190, height: 1350), background: nil)
        }

        // Section « Économie d'énergie » : mot de passe à chaque fois, autorisé, règle refusée.
        for (name, state) in [("none", LowPowerAuthorizationState.none), ("granted", .granted), ("refused", .refused)] {
            let fixture = idleFixture(authorization: state)
            // Le volet seul, plus haut que la fenêtre (le formulaire y défile) : on voit la section en entier.
            try render(QuickSettingsSettingsView(module: fixture.module, prefs: fixture.module.prefs),
                       name: "qs-settings-auth-\(name)", to: outputDir,
                       size: CGSize(width: SettingsWindow.size.width - 190, height: 1150), background: nil)
        }
    }

    // MARK: - Outils

    private func measure(_ scene: Scene, settle: TimeInterval = 0.5) -> CGSize {
        let hosting = FirstMouseHostingView(rootView: scene.root)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: NotchController.panelSize)
        let window = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        window.close()
        return scene.harness.model.contentSize
    }

    /// Fenêtre hors écran + rendu de l'arbre de calques (même méthode que SnapshotTests).
    private func render<V: View>(_ view: V, name: String, to dir: URL, size: CGSize = NotchController.panelSize,
                                 background: Color? = Color(white: 0.85)) throws {
        let hosting = NSHostingView(rootView: view.background(background ?? Color(nsColor: .windowBackgroundColor)))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let layer = hosting.layer,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                            pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return XCTFail("rendu impossible")
        }
        let cg = context.cgContext
        cg.translateBy(x: 0, y: size.height * scale)
        cg.scaleBy(x: scale, y: -scale)
        layer.render(in: cg)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return XCTFail("PNG") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        window.close()
    }
}
