import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendus PNG de la notch repliée avec ses intercalaires : rétractés, toujours visibles, 1 à 7 activités, un intercalaire
/// déployé (lecture, minuteur, Claude, « +N »), plein écran compact, encoche virtuelle. Ne fait rien sans
/// `ORIEL_SNAPSHOT_DIR`.
final class EarTabsSnapshotTests: XCTestCase {
    private static let wallpaper = Color(red: 0.36, green: 0.52, blue: 0.74)
    private static let band = CGSize(width: 800, height: 70)
    private static let deployed = CGSize(width: 800, height: 190)

    private func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func fake(_ id: String, _ symbol: String, _ text: String, priority: Int, bars: Bool = false,
                      alert: Bool = false) -> FakeModule {
        FakeModule(id: id, ears: ModuleEars(symbol: symbol, text: text, priority: priority, bars: bars, alert: alert),
                   keepsRunning: true)
    }

    private struct Scene {
        let harness: NotchHarness
        let registry: ModuleRegistry
        var root: NotchRootView {
            NotchRootView(model: harness.model, store: harness.store, registry: registry, prefs: harness.prefs,
                          actions: NotchActions())
        }
    }

    private func scene(_ modules: [any NotchModule], store: SessionStore = SessionStore(),
                       mode: EarTabsMode = .visible, hovered: String? = nil, fullScreen: Bool = false,
                       virtualNotch: Bool = false) -> Scene {
        let harness = NotchHarness(self, store: store)
        harness.prefs.earTabsMode = mode
        harness.model.hoveredTab = hovered
        harness.model.isFullScreen = fullScreen
        if virtualNotch {
            harness.model.hasNotch = false
            harness.model.notchSize = CGSize(width: 200, height: 24)
            harness.prefs.virtualNotchStyle = .notch
        }
        let registry = ModuleRegistry(modules: [harness.claude] + modules, prefs: harness.prefs)
        registry.reconcile()
        return Scene(harness: harness, registry: registry)
    }

    /// Les six activités de la galerie, de la plus à la moins prioritaire (Claude d'abord).
    private func six() -> [FakeModule] {
        [fake("timer", "timer", "24:59", priority: 5),
         fake("media", "music.note", "", priority: 1, bars: true),
         fake("messages", "message.fill", "3", priority: 0),
         fake("mail", "envelope.fill", "12", priority: -1),
         fake("quicksettings", "cup.and.saucer.fill", "1h00", priority: -10)]
    }

    func testRenderTabs() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        func render(_ scene: Scene, _ name: String, size: CGSize = Self.band) throws {
            try TimerNotesSnapshot.render(scene.root, name, dir, size: size, background: Self.wallpaper)
        }

        // 1 à 6 activités, toujours visibles (Claude au travail d'abord).
        let activities = six()
        for count in 1...6 {
            try render(scene(Array(activities.prefix(count - 1)), store: .working(2)), "ear-tabs-visible-\(count)")
        }
        // Sept : la sixième place devient « +2 ».
        let seventh = fake("notes", "note.text", "!", priority: -20)
        try render(scene(activities + [seventh], store: .working(2)), "ear-tabs-visible-7-plus")

        // Rétractés : languettes au repos, sauf l'alerte (Claude attend ta réponse).
        try render(scene(Array(activities.prefix(4)), store: .working(2), mode: .retracted), "ear-tabs-retracted-5")
        let waiting = SessionStore()
        waiting.send("UserPromptSubmit", "s0", ["prompt": "x"])
        waiting.send("PermissionRequest", "s0", ["tool_name": "Bash", "tool_input": ["command": "npm test"]])
        XCTAssertEqual(waiting.indicator, .attention)
        try render(scene(Array(activities.prefix(2)), store: waiting, mode: .retracted), "ear-tabs-retracted-alert")
        try render(scene(Array(activities.prefix(2)), store: waiting, mode: .visible), "ear-tabs-visible-alert")

        // Encoche virtuelle (écran sans encoche) et plein écran compact : mêmes intercalaires.
        try render(scene(Array(activities.prefix(3)), store: .working(1), virtualNotch: true), "ear-tabs-virtual-notch")
        try render(scene(Array(activities.prefix(2)), store: .working(1), fullScreen: true), "ear-tabs-fullscreen-compact")

        // Rien : la notch seule.
        try render(scene([], store: SessionStore()), "ear-tabs-none")

        // Réglages › Apparence, défilé jusqu'à « Notch repliée » : le choix Rétractés / Toujours visibles.
        let settings = scene(Array(activities.prefix(2)))
        try Self.renderScrolledToBottom(SettingsView(prefs: settings.harness.prefs, registry: settings.registry,
                                                updater: Updater(), selection: .appearance),
                                   "ear-tabs-settings-appearance", dir)
    }

    /// Rendu d'une fenêtre dont la liste défilante est descendue tout en bas.
    static func renderScrolledToBottom<V: View>(_ view: V, _ name: String, _ dir: URL) throws {
        let size = SettingsWindow.size
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        for scroll in scrollViews(hosting) {
            if let document = scroll.documentView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentSize.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let scale: CGFloat = 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        try XCTUnwrap(hosting.layer).render(in: context)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        window.close()
    }

    func testRenderDeployedTabs() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        func render(_ scene: Scene, _ name: String) throws {
            try TimerNotesSnapshot.render(scene.root, name, dir, size: Self.deployed, background: Self.wallpaper)
        }
        let adapter = try FakeAdapter(self, lines: [StreamLines.full(title: "Lumières de la ville", artist: "Les Fictifs",
                                                                       artwork: StreamLines.artwork())])
        let media = MediaModule(defaults: makeEphemeralDefaults(self), adapter: adapter.adapter,
                                calendar: FakeCalendar(.notDetermined))
        let rig = try TimerRig(self)
        let timer = rig.startedModule()
        timer.startSimple(minutes: 25)
        rig.clock.advance(61)
        timer.tick()
        addTeardownBlock {
            media.stop()
            timer.stop()
        }
        let others = [fake("messages", "message.fill", "3", priority: 0), fake("mail", "envelope.fill", "12", priority: -1)]
        let sessions = SessionStore.working(2)

        let tabs: [any NotchModule] = [timer, media] + others
        let base = scene(tabs, store: sessions)
        wait { base.registry.earsEntries.contains { $0.id == "media" && $0.ears.image != nil } }
        XCTAssertEqual(base.registry.earTabs(claude: sessions.indicator, claudeEars: sessions.ears).map { $0.id },
                       ["claude", "timer", "media", "messages", "mail"])

        for (id, name) in [("media", "lecture"), ("timer", "minuteur"), ("claude", "claude"), ("messages", "autre")] {
            let deployed = scene(tabs, store: sessions, hovered: id)
            try render(deployed, "ear-tabs-deployed-\(name)")
        }
        // Rétractés : le déploiement est le même.
        try render(scene(tabs, store: sessions, mode: .retracted, hovered: "media"),
                   "ear-tabs-deployed-retracted-lecture")
        // « +N » déployé : les activités qui n'ont pas de place.
        let crowded: [any NotchModule] = tabs + [fake("quicksettings", "cup.and.saucer.fill", "1h00", priority: -10),
                                                 fake("notes", "note.text", "!", priority: -20),
                                                 fake("codex", "sparkles", "1", priority: -30)]
        try render(scene(crowded, store: sessions, hovered: EarTab.moreId), "ear-tabs-deployed-plus")
    }
}
