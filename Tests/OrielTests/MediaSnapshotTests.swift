import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendus PNG de l'onglet Lecteur (états du lecteur et du calendrier, mode compact, oreilles, réglages).
/// Faux adaptateur et faux calendrier : aucune lecture réelle, aucun accès au vrai calendrier.
/// Ne fait rien sans `ORIEL_SNAPSHOT_DIR`.
final class MediaSnapshotTests: XCTestCase {
    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["ORIEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private static func todayEvents() -> [MediaEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ days: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(day: days, hour: hour, minute: minute), to: today)!
        }
        return MediaCalendarMath.sorted([
            MediaEvent(id: "1", title: "Point d'équipe", start: at(0, 9), end: at(0, 9, 30), isAllDay: false,
                       color: Color(red: 0.3, green: 0.55, blue: 1)),
            MediaEvent(id: "2", title: "Revue de design", start: at(0, 14, 30), end: at(0, 15, 30), isAllDay: false,
                       color: Palette.claudeOrange),
            MediaEvent(id: "3", title: "Formation", start: at(0, 0), end: at(1, 0), isAllDay: true,
                       color: Color(red: 0.3, green: 0.8, blue: 0.5)),
            MediaEvent(id: "4", title: "Sport", start: at(0, 18), end: at(0, 19), isAllDay: false,
                       color: Color(red: 0.7, green: 0.5, blue: 1)),
            MediaEvent(id: "5", title: "Dentiste", start: at(2, 10), end: at(2, 11), isAllDay: false,
                       color: Color(red: 0.95, green: 0.4, blue: 0.5)),
        ])
    }

    /// Module démarré avec un faux flux ; `lines` vide = adaptateur absent (indisponible).
    private func media(lines: [String]?, access: CalendarAccess, events: [MediaEvent] = []) throws -> MediaModule {
        let calendar = FakeCalendar(access, events: events)
        calendar.list = [
            MediaCalendarInfo(id: "travail", title: "Travail", source: "iCloud", color: Palette.claudeOrange),
            MediaCalendarInfo(id: "perso", title: "Perso", source: "iCloud", color: Color(red: 0.3, green: 0.55, blue: 1)),
        ]
        let adapter = try lines.map { try FakeAdapter(self, lines: $0).adapter }
        let module = MediaModule(defaults: makeEphemeralDefaults(self), adapter: adapter, calendar: calendar)
        module.start()
        if let lines {
            wait { module.playerStatus == .ready && (lines.isEmpty || module.nowPlaying != nil) }
        }
        addTeardownBlock { module.stop() }
        return module
    }

    private func notch(_ media: MediaModule, expanded: Bool = true, fullScreen: Bool = false,
                       store: SessionStore = SessionStore()) -> (NotchHarness, ModuleRegistry) {
        let notch = NotchHarness(self, store: store)
        let modules = ModuleRegistry.standardModules(claude: notch.claude).map { $0.id == "media" ? media : $0 }
        let registry = ModuleRegistry(modules: modules, prefs: notch.prefs)
        notch.model.isExpanded = expanded
        notch.model.isFullScreen = fullScreen
        notch.model.selectedTab = "media"
        return (notch, registry)
    }

    private func root(_ pair: (NotchHarness, ModuleRegistry)) -> NotchRootView {
        NotchRootView(model: pair.0.model, store: pair.0.store, registry: pair.1, prefs: pair.0.prefs,
                      actions: NotchActions())
    }

    func testRenderMedia() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let events = Self.todayEvents()
        let playing = StreamLines.full(title: "Lumières de la ville", artist: "Les Fictifs", elapsed: 74,
                                       duration: 231, artwork: StreamLines.artwork())

        let full = try media(lines: [playing], access: .granted, events: events)
        try render(root(notch(full)), "media-playing", outputDir)
        for size in [PanelSize.compact, .large] {
            let sized = notch(full)
            sized.0.prefs.panelSize = size
            try render(root(sized), "media-playing-\(size.rawValue)", outputDir)
        }

        let paused = try media(lines: [StreamLines.full(title: "Une très longue piste dont le titre déborde",
                                                        artist: "Quelqu'un", playing: false)],
                               access: .granted)
        try render(root(notch(paused)), "media-paused-nothing-today", outputDir)

        let idle = try media(lines: [], access: .notDetermined)
        try render(root(notch(idle)), "media-idle-calendar-ask", outputDir)

        let unavailable = try media(lines: nil, access: .denied)
        try render(root(notch(unavailable)), "media-unavailable-denied", outputDir)

        let calendarOnly = try media(lines: [playing], access: .granted, events: events)
        calendarOnly.showPlayer = false
        try render(root(notch(calendarOnly)), "media-calendar-only", outputDir)
        let playerOnly = try media(lines: [playing], access: .granted, events: events)
        playerOnly.showCalendar = false
        try render(root(notch(playerOnly)), "media-player-only", outputDir)

        // Plein écran compact : sessions Claude puis le résumé du lecteur.
        try render(root(notch(full, fullScreen: true, store: .working(2))), "media-fullscreen-compact", outputDir)

        // Notch repliée : pochette et égaliseur quand Claude ne fait rien (le registre démarre le module seul).
        let collapsed = notch(full, expanded: false)
        wait { collapsed.1.moduleEars != nil }
        XCTAssertTrue(collapsed.1.moduleEars?.bars == true && collapsed.1.moduleEars?.image != nil)
        try render(root(collapsed), "media-collapsed-ears", outputDir)

        // Réglages › Lecteur et licence dans À propos.
        for (section, name) in [(SettingsSection.module("media"), "settings-media"), (.about, "settings-about-media")] {
            let view = SettingsView(prefs: collapsed.0.prefs, registry: collapsed.1, updater: Updater(),
                                    selection: section)
            try render(view, name, outputDir, size: SettingsWindow.size, background: nil)
        }
        let askSettings = notch(idle)
        try render(SettingsView(prefs: askSettings.0.prefs, registry: askSettings.1, updater: Updater(),
                                selection: .module("media")), "settings-media-ask", outputDir,
                   size: SettingsWindow.size, background: nil)
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
