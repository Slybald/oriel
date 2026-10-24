import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendus PNG de l'onglet Presse-papiers (vide, rempli, survol, copié, recherche, suspendu, réglages) sur un faux
/// presse-papiers : jamais celui de l'utilisateur. Ne fait rien sans `ORIEL_SNAPSHOT_DIR`.
/// `ORIEL_SNAPSHOT_DIR=/dossier swift test --filter ClipboardSnapshotTests`
final class ClipboardSnapshotTests: XCTestCase {
    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["ORIEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static let finder = ClipboardSource(bundleID: "com.apple.finder", name: "Finder")
    private static let terminal = ClipboardSource(bundleID: "com.apple.Terminal", name: "Terminal")
    private static let preview = ClipboardSource(bundleID: "com.apple.Preview", name: "Aperçu")

    /// Historique varié : un lien, du code, une image, des fichiers, une couleur, un long texte, un texte coupé.
    private func filledRig() throws -> ClipboardRig {
        let rig = try makeClipboardRig()
        /// La copie suivante a lieu « il y a `seconds` secondes » (le tic avance l'horloge d'une seconde).
        func ago(_ seconds: TimeInterval) { rig.clock.now = Date().addingTimeInterval(-seconds - 1) }
        ago(2 * 86_400)
        rig.copy("Rendez-vous jeudi 14 h avec l'équipe produit pour la revue du lancement, salle Horizon.", from: .textEdit)
        rig.module.togglePin(rig.items[0].id)
        ago(3 * 3600)
        rig.copy("swift test --filter ClipboardSnapshotTests", from: Self.terminal)
        ago(25 * 60)
        rig.copy(.color("D97757"), from: .safari)
        ago(7 * 60)
        rig.copy(.files([URL(fileURLWithPath: "/tmp/Rapport trimestriel.pdf"), URL(fileURLWithPath: "/tmp/Budget.xlsx"),
                         URL(fileURLWithPath: "/tmp/Notes")]), from: Self.finder)
        ago(90)
        rig.copy(.image(makeTestImage(width: 640, height: 400)), from: Self.preview)
        ago(20)
        rig.copy(String(repeating: "Un très long paragraphe qui dépasse largement deux lignes de la liste compacte. ",
                        count: 400), from: .textEdit)
        ago(3)
        rig.copy("https://www.swift.org/documentation/api-design-guidelines/#fundamentals", from: .safari)
        return rig
    }

    private struct Scene {
        let harness: NotchHarness
        let registry: ModuleRegistry
        let root: NotchRootView
    }

    private func notch(_ rig: ClipboardRig, fullScreen: Bool = false) -> Scene {
        let harness = NotchHarness(self)
        let registry = ModuleRegistry(modules: [harness.claude, rig.module], prefs: harness.prefs)
        harness.model.isExpanded = true
        harness.model.isFullScreen = fullScreen
        harness.model.selectedTab = "clipboard"
        let root = NotchRootView(model: harness.model, store: harness.store, registry: registry, prefs: harness.prefs,
                                 actions: NotchActions())
        return Scene(harness: harness, registry: registry, root: root)
    }

    /// Le panneau seul, avec survol, sélection ou recherche simulés, sur le fond de la notch.
    private func panel(_ rig: ClipboardRig, query: String = "", selection: UUID? = nil, focused: Bool = false,
                       hovered: UUID? = nil) -> some View {
        ClipboardPanel(module: rig.module, query: query, selection: selection, searchFocused: focused, hovered: hovered)
            .padding(14)
            .frame(width: 540, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
    }

    func testRenderClipboard() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let size = CGSize(width: 540, height: 420)

        // Vide.
        let empty = try makeClipboardRig()
        try render(notch(empty).root, "clipboard-empty", outputDir)

        // Rempli (épinglé en tête, lien, image, fichiers, couleur, long texte coupé).
        let rig = try filledRig()
        try render(notch(rig).root, "clipboard-filled", outputDir)
        for panelSize in [PanelSize.compact, .large] {
            let sized = notch(rig)
            sized.harness.prefs.panelSize = panelSize
            try render(sized.root, "clipboard-filled-\(panelSize.rawValue)", outputDir)
        }

        // Survol d'une ligne (épingle et corbeille), une autre qui vient d'être copiée, une ligne choisie au clavier.
        let ordered = rig.module.history.ordered
        rig.module.copy(ordered[3].id)
        try render(panel(rig, selection: ordered[2].id, hovered: ordered[1].id), "clipboard-hover-copied-selected",
                   outputDir, size: size, background: nil)

        // Recherche avec le focus, résultats filtrés, première ligne choisie.
        let results = ClipboardHistory.filter(rig.module.history.ordered, query: "swift")
        XCTAssertEqual(results.count, 2)
        try render(panel(rig, query: "swift", selection: results[0].id, focused: true), "clipboard-search", outputDir,
                   size: size, background: nil)
        try render(panel(rig, query: "zzz", focused: true), "clipboard-no-results", outputDir, size: size,
                   background: nil)

        // macOS refuse ou soumet à une alerte la lecture du presse-papiers : la ligne d'explication, sans et avec
        // historique (l'alerte seule disparaît dès qu'une copie a été gardée).
        let denied = try makeClipboardRig()
        denied.pasteboard.access = .denied
        denied.module.refreshAccess()
        try render(notch(denied).root, "clipboard-access-denied-empty", outputDir)
        let asking = try makeClipboardRig()
        asking.pasteboard.access = .ask
        asking.module.refreshAccess()
        try render(notch(asking).root, "clipboard-access-ask-empty", outputDir)
        let deniedFilled = try filledRig()
        deniedFilled.pasteboard.access = .denied
        deniedFilled.module.refreshAccess()
        try render(notch(deniedFilled).root, "clipboard-access-denied-filled", outputDir)

        // Une image de plus de 5 Mo n'est pas gardée : la ligne le dit jusqu'à la copie suivante.
        rig.apps.current = .safari
        rig.pasteboard.copyTooLargeImage()
        rig.module.poll()
        XCTAssertEqual(rig.module.notice, .imageTooLarge)
        try render(notch(rig).root, "clipboard-image-too-large", outputDir)
        rig.module.dismissNotice()

        // Capture suspendue : bandeau et bouton « Reprendre » dans l'en-tête, avec et sans historique.
        rig.module.suspended = true
        try render(notch(rig).root, "clipboard-suspended", outputDir)
        let emptySuspended = try makeClipboardRig()
        emptySuspended.module.suspended = true
        try render(notch(emptySuspended).root, "clipboard-suspended-empty", outputDir)

        // Plein écran compact : l'onglet n'a pas de résumé, rien de plus à montrer.
        XCTAssertNil(rig.module.makeCompactView())
        try render(notch(rig, fullScreen: true).root, "clipboard-fullscreen-compact", outputDir)

        // Réglages (la fenêtre complète, puis avec une app ajoutée à la liste).
        rig.module.suspended = false
        let settings = notch(rig)
        let window = SettingsView(prefs: settings.harness.prefs, registry: settings.registry, updater: Updater(),
                                  selection: .module("clipboard"))
        try render(window, "settings-clipboard", outputDir, size: SettingsWindow.size, background: nil)
        rig.module.exclude("com.apple.Safari")
        rig.module.keepsHistory = true
        try render(window, "settings-clipboard-persist-on", outputDir, size: SettingsWindow.size, background: nil)
        rig.module.keepsHistory = false
        let warned = notch(denied)
        let warnedWindow = SettingsView(prefs: warned.harness.prefs, registry: warned.registry, updater: Updater(),
                                        selection: .module("clipboard"))
        try render(warnedWindow, "settings-clipboard-access-denied", outputDir, size: SettingsWindow.size,
                   background: nil)
    }

    /// Fenêtre hors écran + rendu de l'arbre de calques (même méthode que MediaSnapshotTests).
    private func render<V: View>(_ view: V, _ name: String, _ dir: URL, size: CGSize = NotchController.panelSize,
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
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return XCTFail("rendu impossible") }
        context.cgContext.translateBy(x: 0, y: size.height * scale)
        context.cgContext.scaleBy(x: scale, y: -scale)
        layer.render(in: context.cgContext)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return XCTFail("PNG") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        window.close()
    }
}
