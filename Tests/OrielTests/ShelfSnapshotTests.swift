import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Mise en page et rendus PNG de l'onglet « Étagère » : vide, rempli, sélection et survol, introuvable, zone de
/// dépôt, « Annuler », plein écran compact, réglages. Fichiers vides dans un dossier temporaire, fausses vignettes.
/// Rendus : `ORIEL_SNAPSHOT_DIR=/dossier swift test --filter ShelfSnapshotTests`.
final class ShelfSnapshotTests: XCTestCase {
    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["ORIEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static let names = ["Rapport annuel 2026 - version finale relue.pdf", "Maquette accueil.png",
                                "Photo plage.jpg", "notes-reunion.md", "Projet Notch/", "Archive.zip",
                                "Budget.numbers", "script.swift", "Présentation.key"]

    private struct Scene {
        let harness: NotchHarness
        let registry: ModuleRegistry
        let shelf: ShelfModule
        let dir: URL

        var root: NotchRootView {
            NotchRootView(model: harness.model, store: harness.store, registry: registry, prefs: harness.prefs,
                          actions: NotchActions())
        }
    }

    /// Étagère démarrée avec `names` (un nom finissant par « / » = dossier) ; images : fausse vignette colorée.
    private func scene(_ names: [String] = names, expanded: Bool = true, fullScreen: Bool = false) throws -> Scene {
        let dir = try makeTemporaryDirectory(self)
        let shelf = ShelfModule(defaults: makeEphemeralDefaults(self),
                                store: ShelfStore(file: dir.appendingPathComponent("support/shelf.json")),
                                thumbnailer: Self.fakeThumbnail, saveDelay: 0)
        addTeardownBlock { shelf.stop() }
        let harness = NotchHarness(self)
        let modules = ModuleRegistry.standardModules(claude: harness.claude).map { $0.id == "shelf" ? shelf : $0 }
        let registry = ModuleRegistry(modules: modules, prefs: harness.prefs)
        harness.model.isExpanded = expanded
        harness.model.isFullScreen = fullScreen
        harness.model.selectedTab = "shelf"
        shelf.start()
        let urls = try names.map { name -> URL in
            let url = dir.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: url)
            }
            return url
        }
        // Un dépôt par fichier, à l'envers : le premier nom finit en tête.
        for url in urls.reversed() {
            let count = shelf.items.count
            shelf.add([url])
            wait { shelf.items.count == count + 1 }
        }
        return Scene(harness: harness, registry: registry, shelf: shelf, dir: dir)
    }

    private static func fakeThumbnail(_ url: URL, _ done: @escaping (NSImage?) -> Void) {
        guard ["png", "jpg"].contains(url.pathExtension) else { return done(nil) }
        let warm = url.pathExtension == "jpg"
        let image = NSImage(size: NSSize(width: 64, height: 48), flipped: false) { rect in
            let colors = warm ? [NSColor.systemOrange, .systemPink] : [NSColor.systemTeal, .systemIndigo]
            NSGradient(colors: colors)?.draw(in: NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4), angle: 60)
            return true
        }
        done(image)
    }

    private func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: - Mise en page

    /// 50 éléments et un bandeau : la grille défile, le panneau reste sous 460 pt, à chaque largeur.
    func testFullShelfFitsInThePanel() throws {
        let many = (1...ShelfList.maxCount).map { "Fichier \($0).txt" }
        let full = try scene(many)
        XCTAssertEqual(full.shelf.items.count, ShelfList.maxCount)
        full.shelf.limit = 10
        let extra = full.dir.appendingPathComponent("Un de trop.txt")
        try Data().write(to: extra)
        full.shelf.add([extra])
        wait { full.shelf.notice != nil }
        for size in PanelSize.allCases {
            full.harness.prefs.panelSize = size
            let measured = measure(full)
            XCTAssertEqual(measured.width, size.width + 24, accuracy: 1, size.rawValue)
            XCTAssertLessThanOrEqual(measured.height, 461, size.rawValue)
            XCTAssertGreaterThan(measured.height, 380, size.rawValue)
        }
    }

    /// Plein écran compact : une ligne quand l'étagère a quelque chose, rien du tout quand elle est vide.
    func testCompactSummaryOnlyWhenThereIsSomething() throws {
        let empty = try scene([], fullScreen: true)
        let emptyHeight = measure(empty).height
        let filled = try scene(["a.txt"], fullScreen: true)
        let filledHeight = measure(filled).height
        XCTAssertGreaterThan(filledHeight - emptyHeight, 25, "une ligne de résumé")
        XCTAssertLessThan(filledHeight - emptyHeight, 50)
        filled.shelf.isDropTargeted = true
        XCTAssertEqual(measure(filled).height, filledHeight, accuracy: 1, "même ligne pendant un glisser")
    }

    // MARK: - Rendus

    func testRenderStates() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }

        let empty = try scene([])
        try render(empty.root, "shelf-empty", outputDir)
        empty.shelf.isDropTargeted = true
        try render(empty.root, "shelf-empty-drop", outputDir)

        let filled = try scene()
        try render(filled.root, "shelf-filled", outputDir)
        for size in [PanelSize.compact, .large] {
            filled.harness.prefs.panelSize = size
            try render(filled.root, "shelf-filled-\(size.rawValue)", outputDir)
        }
        filled.harness.prefs.panelSize = .standard

        let ids = filled.shelf.items.map { $0.id }
        filled.shelf.click(ids[1])
        filled.shelf.click(ids[2], command: true)
        filled.shelf.hovered = ids[4]
        try render(filled.root, "shelf-selected-hover", outputDir)
        filled.shelf.hovered = nil
        filled.shelf.clearSelection()

        filled.shelf.isDropTargeted = true
        try render(filled.root, "shelf-drop-over-items", outputDir)
        filled.shelf.isDropTargeted = false

        // Fichier supprimé dans le dos de l'étagère : grisé, « Introuvable » (vu à l'affichage de l'onglet).
        try FileManager.default.removeItem(at: filled.dir.appendingPathComponent("notes-reunion.md"))
        filled.shelf.viewAppeared()
        wait { !filled.shelf.missing.isEmpty }
        filled.shelf.viewDisappeared()
        try render(filled.root, "shelf-missing", outputDir)

        filled.shelf.clearAll()
        try render(filled.root, "shelf-cleared-undo", outputDir)

        let many = try scene((1...ShelfList.maxCount).map { "Capture \($0).png" })
        try render(many.root, "shelf-full-scroll", outputDir)

        // Plein écran compact : sessions Claude, puis le résumé de l'étagère (et pendant un glisser).
        let compact = try scene(fullScreen: true)
        try render(compact.root, "shelf-fullscreen-compact", outputDir)
        compact.shelf.isDropTargeted = true
        try render(compact.root, "shelf-fullscreen-compact-drop", outputDir)
    }

    func testRenderSettings() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let scene = try scene([])
        let view = SettingsView(prefs: scene.harness.prefs, registry: scene.registry, updater: Updater(),
                                selection: .module("shelf"))
        try render(view, "settings-shelf", outputDir, size: SettingsWindow.size, background: nil)
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
