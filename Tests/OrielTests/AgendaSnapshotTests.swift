import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendus PNG de l'onglet Agenda : le rendez-vous qui approche (loin, 5 minutes, en cours, sans lien), les états sans
/// accès, l'intercalaire de la notch repliée et déployé, le plein écran compact, les réglages. Faux calendrier : aucun
/// accès au vrai. Ne fait rien sans `ORIEL_SNAPSHOT_DIR`.
final class AgendaSnapshotTests: XCTestCase {
    private static let wallpaper = Color(red: 0.36, green: 0.52, blue: 0.74)
    private let zoom = "https://us02web.zoom.us/j/123456789?pwd=abc"

    private func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Les rendez-vous d'aujourd'hui autour de `now` : un fini (estompé), `focus` (à venir ou en cours), puis la suite.
    private func events(focus: MediaEvent) -> [MediaEvent] {
        let today = Calendar.current.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int = 0) -> Date { today.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60)) }
        func plain(_ id: String, _ title: String, _ place: String, _ start: Date, _ color: Color) -> MediaEvent {
            MediaEvent(id: id, title: title, start: start, end: start.addingTimeInterval(5400), isAllDay: false,
                       color: color, location: place)
        }
        let done = Date().addingTimeInterval(-3 * 3600)
        let later = Date().addingTimeInterval(2 * 3600)
        return MediaCalendarMath.sorted([
            plain("past", "Cours : Algorithmique", "Amphi 3", min(done, at(9)), Color(red: 0.25, green: 0.35, blue: 0.75)),
            focus,
            plain("code", "Revue de code", "Salle B", later, Color(red: 0.3, green: 0.8, blue: 0.5)),
            plain("atelier", "Atelier maquettes", "Studio", later.addingTimeInterval(7200), Palette.claudeOrange),
            plain("yoga", "Yoga", "Club", later.addingTimeInterval(14400), Palette.amber),
        ])
    }

    private func meeting(minutes: Double, link: Bool = true, length: Double = 30) -> MediaEvent {
        let start = Date().addingTimeInterval(minutes * 60)
        return MediaEvent(id: "focus", title: "Point produit", start: start,
                          end: start.addingTimeInterval(length * 60), isAllDay: false, color: Palette.claudeOrange,
                          location: link ? "" : "Salle B",
                          meeting: link ? MeetingLink.find(url: nil, location: nil, notes: zoom) : nil)
    }

    private func agenda(_ access: CalendarAccess = .granted, events: [MediaEvent] = []) -> AgendaModule {
        let calendar = FakeCalendar(access, events: events)
        calendar.list = [
            MediaCalendarInfo(id: "travail", title: "Travail", source: "iCloud", color: Palette.claudeOrange),
            MediaCalendarInfo(id: "perso", title: "Perso", source: "iCloud", color: Color(red: 0.3, green: 0.55, blue: 1)),
        ]
        let module = AgendaModule(defaults: makeEphemeralDefaults(self), calendar: calendar,
                                  center: NotificationCenter(), workspaceCenter: NotificationCenter())
        addTeardownBlock { module.stop() }
        return module
    }

    private struct Scene {
        let harness: NotchHarness
        let registry: ModuleRegistry
        var root: NotchRootView {
            NotchRootView(model: harness.model, store: harness.store, registry: registry, prefs: harness.prefs,
                          actions: NotchActions())
        }
    }

    /// Notch dépliée sur l'onglet Agenda, avec tous les onglets standard (le module d'agenda est celui du test).
    private func panel(_ module: AgendaModule, fullScreen: Bool = false, store: SessionStore = SessionStore()) -> Scene {
        let harness = NotchHarness(self, store: store)
        let modules = ModuleRegistry.standardModules(claude: harness.claude).map { $0.id == "agenda" ? module : $0 }
        let registry = ModuleRegistry(modules: modules, prefs: harness.prefs)
        harness.model.isExpanded = true
        harness.model.isFullScreen = fullScreen
        harness.model.selectedTab = "agenda"
        registry.setPanelOpen(true)
        return Scene(harness: harness, registry: registry)
    }

    /// Notch repliée : l'intercalaire de l'agenda seul.
    private func collapsed(_ module: AgendaModule, mode: EarTabsMode = .visible, hovered: String? = nil) -> Scene {
        let harness = NotchHarness(self)
        harness.prefs.earTabsMode = mode
        harness.model.hoveredTab = hovered
        let registry = ModuleRegistry(modules: [harness.claude, module], prefs: harness.prefs)
        registry.reconcile()
        wait { registry.earsEntries.contains { $0.id == "agenda" } }
        return Scene(harness: harness, registry: registry)
    }

    func testRenderAgenda() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        func render(_ scene: Scene, _ name: String, size: CGSize = NotchController.panelSize) throws {
            try TimerNotesSnapshot.render(scene.root, name, dir, size: size, background: Color(white: 0.85))
        }
        func started(_ module: AgendaModule) -> AgendaModule {
            module.start()
            wait { !module.events.isEmpty || module.access != .granted }
            return module
        }

        // L'onglet : loin, à 5 minutes (ambre, « Rejoindre »), en cours (vert), sans lien (lieu à la place).
        for (name, event) in [("far", meeting(minutes: 95)), ("imminent", meeting(minutes: 4)),
                              ("running", meeting(minutes: -12, length: 45)),
                              ("nolink", meeting(minutes: 25, link: false))] {
            let module = started(agenda(events: events(focus: event)))
            try render(panel(module), "agenda-tab-\(name)")
        }

        // Une journée vide, l'accès à demander ou refusé.
        try render(panel(started(agenda())), "agenda-tab-empty")
        try render(panel(started(agenda(.notDetermined))), "agenda-tab-ask")
        try render(panel(started(agenda(.denied))), "agenda-tab-denied")

        // Plein écran compact : la ligne du prochain rendez-vous.
        try render(panel(started(agenda(events: events(focus: meeting(minutes: 4)))), fullScreen: true,
                         store: .working(2)), "agenda-fullscreen-compact")

        // « Aujourd'hui », à droite de la barre d'onglets, quand un autre jour est choisi.
        let away = started(agenda())
        away.selectedDay = Calendar.current.date(byAdding: .day, value: 9, to: away.selectedDay)!
        try TimerNotesSnapshot.render(AgendaTodayButton(module: away).padding(20), "agenda-today-button", dir,
                                      size: CGSize(width: 160, height: 60), background: .black)

        // Notch repliée : discret, ambre, en cours ; rétracté ; déployé.
        let band = CGSize(width: 800, height: 70)
        let deployed = CGSize(width: 800, height: 190)
        for (name, minutes, length) in [("far", 14.0, 30.0), ("imminent", 4.0, 30.0), ("running", -12.0, 45.0)] {
            let module = agenda(events: [meeting(minutes: minutes, length: length)])
            let scene = collapsed(module)
            XCTAssertNotNil(scene.registry.moduleEars, name)
            try TimerNotesSnapshot.render(scene.root, "agenda-ears-\(name)", dir, size: band, background: Self.wallpaper)
        }
        let retracted = collapsed(agenda(events: [meeting(minutes: 4)]), mode: .retracted)
        try TimerNotesSnapshot.render(retracted.root, "agenda-ears-retracted-alert", dir, size: band, background: Self.wallpaper)
        for (name, event) in [("imminent", meeting(minutes: 4)), ("running", meeting(minutes: -12, length: 45)),
                              ("nolink", meeting(minutes: 4, link: false))] {
            let scene = collapsed(agenda(events: [event]), hovered: "agenda")
            try TimerNotesSnapshot.render(scene.root, "agenda-ears-deployed-\(name)", dir, size: deployed,
                                          background: Self.wallpaper)
        }

        // Réglages › Agenda.
        let settings = panel(started(agenda(events: events(focus: meeting(minutes: 4)))))
        try TimerNotesSnapshot.render(SettingsView(prefs: settings.harness.prefs, registry: settings.registry,
                                                   updater: Updater(), selection: .module("agenda")),
                                      "settings-agenda", dir, size: SettingsWindow.size, background: nil)
    }
}
