import AppKit
import EventKit
import SwiftUI
import XCTest
@testable import Oriel

/// Calendrier dont les lectures n'aboutissent que quand le test le décide.
final class DeferredCalendar: CalendarSource {
    var access: CalendarAccess = .granted
    private(set) var pending: [([MediaEvent]) -> Void] = []
    private(set) var fetches = 0

    func requestAccess(_ done: @escaping (CalendarAccess) -> Void) { done(access) }
    func calendars(_ done: @escaping ([MediaCalendarInfo]) -> Void) { done([]) }
    func events(from start: Date, to end: Date, hidden: Set<String>, _ done: @escaping ([MediaEvent]) -> Void) {
        fetches += 1
        pending.append(done)
    }
    func release() {}

    func complete(_ events: [MediaEvent] = []) {
        guard !pending.isEmpty else { return }
        pending.removeFirst()(events)
    }
}

/// Logique pure de l'Agenda (lien de réunion, rendez-vous en vue, échéances) puis le module avec un calendrier factice,
/// une horloge et un planificateur à la main : aucun accès au vrai calendrier, aucune attente réelle.
final class AgendaTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let zoom = "https://us02web.zoom.us/j/123456789?pwd=abc"

    private func link(_ notes: String?, location: String? = nil, url: String? = nil) -> MeetingLink? {
        MeetingLink.find(url: url.flatMap(URL.init(string:)), location: location, notes: notes)
    }

    private func event(_ id: String = "e", at start: Date, minutes: Int = 30, allDay: Bool = false, notes: String? = nil,
                       title: String = "Point produit") -> MediaEvent {
        MediaEvent(id: id, title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                   isAllDay: allDay, color: .red, location: "", meeting: link(notes))
    }

    private func wait(_ timeout: TimeInterval = 3, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: - Lien de réunion

    func testMeetingLinksOfTheKnownServices() throws {
        let cases: [(String, MeetingLink.Provider)] = [
            ("Rejoindre : \(zoom).", .zoom),
            ("https://zoom.us/j/9876543210", .zoom),
            ("https://zoom.us/my/salle-equipe", .zoom),
            ("Lien (https://meet.google.com/abc-defg-hij)", .meet),
            ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d", .teams),
            ("https://teams.microsoft.com/meet/123456789?p=x", .teams),
            ("https://teams.live.com/meet/9301234567", .teams),
            ("<a href=\"https://acme.webex.com/meet/jean\">Webex</a>", .webex),
            ("https://facetime.apple.com/join#v=1&p=abcdef&k=xyz", .facetime),
        ]
        for (text, provider) in cases {
            let found = try XCTUnwrap(link(text), text)
            XCTAssertEqual(found.provider, provider, text)
            XCTAssertEqual(found.url.scheme, "https")
            XCTAssertFalse(found.url.absoluteString.hasSuffix("."), "ponctuation de fin retirée : \(found.url)")
            XCTAssertFalse(found.url.absoluteString.hasSuffix(")"), found.url.absoluteString)
        }
        XCTAssertEqual(link("Salle B\n\(zoom)\nMot de passe : 1234")?.url.absoluteString, zoom, "au milieu du texte")
    }

    func testMeetingLinkSourcesAndOrder() {
        XCTAssertEqual(link(nil, location: zoom)?.provider, .zoom, "dans le lieu")
        XCTAssertEqual(link("https://meet.google.com/abc-defg-hij", url: zoom)?.provider, .zoom, "le champ URL d'abord")
        XCTAssertEqual(link("Notes : https://example.com/page puis https://meet.google.com/abc-defg-hij")?.provider, .meet,
                       "le premier lien reconnu, pas le premier lien")
        XCTAssertEqual(link(nil, url: "facetime://jean@example.com")?.provider, .facetime, "facetime: du champ URL")
        XCTAssertNil(link("facetime://jean@example.com"), "facetime: n'est lu que dans le champ URL, pas dans un texte")
        XCTAssertNil(link(nil))
        XCTAssertNil(link(""))
        XCTAssertNil(link("Réunion en salle B, apportez vos ordinateurs."))
    }

    func testMeetingLinkRefusesLookalikesAndOtherSchemes() {
        let refused = [
            "https://zoom.us.evil.example/j/123456789",
            "https://evilzoom.us/j/123456789",
            "https://zoom.us@evil.example/j/123456789",
            "https://user:pass@zoom.us/j/123456789",
            "https://zoom.us:8443/j/123456789",
            "http://zoom.us/j/123456789",
            "https://evil.example/?next=https://zoom.us/j/123456789",
            "https://zoom.us/signin",
            "https://meet.google.com/landing",
            "https://meet.google.com/new",
            "https://teams.microsoft.com/",
            "https://webex.com/",
            "https://facetime.apple.com/",
            "https://fakefacetime.apple.com.evil.example/join",
            // Hôte déguisé : caractère codé, antislash, octet nul, lettre cyrillique.
            "https://evil.example%2f.zoom.us/j/123456789",
            "https://evil.example%252f.zoom.us/j/123456789",
            "https://zoom.us%2eevil.example/j/123456789",
            "https://evil.example\\.zoom.us/j/123456789",
            "https://zoom.us%00.evil.example/j/123456789",
            "https://zооm.us/j/123456789",
        ]
        for text in refused { XCTAssertNil(link(text), text) }
        for text in ["javascript:alert(1)", "file:///Applications/Calculator.app", "ssh://evil.example",
                     "tel:+33123456789", "x-apple.systempreferences:com.apple.preference.security"] {
            XCTAssertNil(link(nil, url: text), "schéma refusé : \(text)")
            XCTAssertNil(link(text), text)
        }
        // Texte énorme : lu sur un début borné, sans planter.
        XCTAssertNil(link(String(repeating: "x https://exemple.org ", count: 20_000)))
        XCTAssertNil(link(nil, url: "https://zoom.us/j/" + String(repeating: "1", count: 5_000)), "lien trop long")
    }

    func testOnlyAKnownLinkIsOpenable() throws {
        XCTAssertTrue(MeetingLink.isOpenable(try XCTUnwrap(URL(string: zoom))))
        XCTAssertTrue(MeetingLink.isOpenable(try XCTUnwrap(URL(string: "facetime://jean@example.com"))))
        for text in ["https://evil.example/j/1", "http://zoom.us/j/1", "file:///etc/passwd", "javascript:alert(1)"] {
            XCTAssertFalse(MeetingLink.isOpenable(try XCTUnwrap(URL(string: text))), text)
        }
    }

    // MARK: - Rendez-vous en vue

    func testPhaseBoundaries() {
        let e = event(at: t0, minutes: 30)
        func phase(_ offset: TimeInterval) -> AgendaPhase? { AgendaMath.phase(of: e, at: t0.addingTimeInterval(offset)) }
        XCTAssertNil(phase(-16 * 60), "trop tôt")
        XCTAssertNil(phase(-15 * 60 - 1))
        XCTAssertEqual(phase(-15 * 60), .soon, "15 min pile : l'intercalaire apparaît")
        XCTAssertEqual(phase(-5 * 60 - 1), .soon)
        XCTAssertEqual(phase(-5 * 60), .imminent, "5 min pile : ambre")
        XCTAssertEqual(phase(-1), .imminent)
        XCTAssertEqual(phase(0), .running, "à l'heure : en cours")
        XCTAssertEqual(phase(30 * 60 - 1), .running)
        XCTAssertNil(phase(30 * 60), "fini : l'intercalaire disparaît")
    }

    func testEventsThatAreNotAppointmentsNeverShow() {
        XCTAssertNil(AgendaMath.phase(of: event(at: t0, allDay: true), at: t0), "journée entière")
        XCTAssertNil(AgendaMath.phase(of: event(at: t0, minutes: 13 * 60), at: t0), "plus de 12 h : un voyage, pas un rendez-vous")
        XCTAssertEqual(AgendaMath.phase(of: event(at: t0, minutes: 12 * 60), at: t0), .running)
        let instant = event(at: t0, minutes: 0)
        XCTAssertEqual(AgendaMath.phase(of: instant, at: t0.addingTimeInterval(-60)), .imminent, "sans durée : décompte")
        XCTAssertNil(AgendaMath.phase(of: instant, at: t0), "sans durée : fini dès l'heure")
    }

    func testMinutesRoundUp() {
        func minutes(_ seconds: TimeInterval) -> Int { AgendaMath.minutes(until: t0, from: t0.addingTimeInterval(-seconds)) }
        XCTAssertEqual(minutes(900), 15)
        XCTAssertEqual(minutes(899), 15)
        XCTAssertEqual(minutes(840), 14)
        XCTAssertEqual(minutes(61), 2)
        XCTAssertEqual(minutes(60), 1)
        XCTAssertEqual(minutes(1), 1)
        XCTAssertEqual(minutes(0), 0)
        XCTAssertEqual(minutes(-30), 0, "déjà commencé")
    }

    func testFocusPicksTheImminentThenTheRunningThenTheSoon() {
        let running = event("run", at: t0.addingTimeInterval(-600), minutes: 60)
        let soon = event("soon", at: t0.addingTimeInterval(12 * 60))
        let imminent = event("imm", at: t0.addingTimeInterval(4 * 60))
        let later = event("later", at: t0.addingTimeInterval(3600))
        XCTAssertNil(AgendaMath.focus([], at: t0))
        XCTAssertNil(AgendaMath.focus([later], at: t0))
        XCTAssertEqual(AgendaMath.focus([later, soon], at: t0)?.event.id, "soon")
        XCTAssertEqual(AgendaMath.focus([soon, running], at: t0)?.event.id, "run", "en cours avant celui qui approche")
        let both = AgendaMath.focus([running, soon, imminent], at: t0)
        XCTAssertEqual(both?.event.id, "imm", "celui qui va commencer passe avant celui en cours")
        XCTAssertEqual(both?.phase, .imminent)
        XCTAssertEqual(both?.minutes, 4)
        let twoSoon = [event("b", at: t0.addingTimeInterval(14 * 60)), event("a", at: t0.addingTimeInterval(10 * 60))]
        XCTAssertEqual(AgendaMath.focus(twoSoon, at: t0)?.event.id, "a", "le plus tôt")
        XCTAssertEqual(AgendaMath.focus([running], at: t0)?.minutes, 0)
    }

    // MARK: - Échéances

    /// Toutes les échéances, de loin à la fin : une par minute dans les 15 dernières, puis le début et la fin. Rien avant.
    func testWakeSequenceCoversTheWholeCountdown() {
        let e = event(at: t0.addingTimeInterval(3600), minutes: 45)
        let start = e.start
        var now = t0
        var wakes: [TimeInterval] = []
        while let next = AgendaMath.nextWake([e], after: now), wakes.count < 100 {
            XCTAssertGreaterThan(next, now, "une échéance est toujours dans le futur")
            wakes.append(next.timeIntervalSince(start))
            now = next
        }
        let expected: [TimeInterval] = (1...15).reversed().map { -TimeInterval($0 * 60) } + [0, TimeInterval(45 * 60)]
        XCTAssertEqual(wakes, expected)
        XCTAssertNil(AgendaMath.nextWake([e], after: start.addingTimeInterval(45 * 60)), "terminé : rien à attendre")
        XCTAssertNil(AgendaMath.nextWake([], after: t0))
        XCTAssertNil(AgendaMath.nextWake([event(at: t0.addingTimeInterval(60), allDay: true)], after: t0), "journée entière")
    }

    func testWakeIsTheNearestThresholdOfAnyEvent() {
        let far = event("far", at: t0.addingTimeInterval(2 * 3600))
        let near = event("near", at: t0.addingTimeInterval(40 * 60))
        XCTAssertEqual(AgendaMath.nextWake([far, near], after: t0), near.start.addingTimeInterval(-15 * 60))
        // Un rendez-vous en cours qui finit avant que le suivant approche.
        let running = event("run", at: t0.addingTimeInterval(-600), minutes: 20)
        XCTAssertEqual(AgendaMath.nextWake([running, far], after: t0), running.end)
        // En fin de seconde : la minute change à l'échéance suivante, pas avant.
        let soon = event("soon", at: t0.addingTimeInterval(10 * 60 + 30))
        XCTAssertEqual(AgendaMath.nextWake([soon], after: t0), soon.start.addingTimeInterval(-10 * 60))
    }

    func testEarsAndRelativeTexts() throws {
        let focus = try XCTUnwrap(AgendaMath.focus([event(at: t0.addingTimeInterval(14 * 60))], at: t0))
        XCTAssertEqual(AgendaFormat.ears(focus), String(format: L("%d min", table: "Agenda"), 14))
        let running = try XCTUnwrap(AgendaMath.focus([event(at: t0.addingTimeInterval(-60))], at: t0))
        XCTAssertEqual(AgendaFormat.ears(running), L("en cours", table: "Agenda"))
        let at = { (seconds: TimeInterval) in AgendaFormat.until(self.t0.addingTimeInterval(seconds), from: self.t0) }
        XCTAssertEqual(at(4 * 60), String(format: L("dans %d min", table: "Agenda"), 4))
        XCTAssertEqual(at(2 * 3600), String(format: L("dans %d h", table: "Agenda"), 2))
        XCTAssertEqual(at(75 * 60), String(format: L("dans %d h %02d", table: "Agenda"), 1, 15))
        XCTAssertEqual(at(8 * 3600), MediaFormat.time(t0.addingTimeInterval(8 * 3600)), "plus tard : l'heure")
    }

    // MARK: - Module

    private final class Opened {
        var urls: [URL] = []
    }

    private struct Rig {
        let module: AgendaModule
        let calendar: FakeCalendar
        let clock: FakeClock
        let scheduler: ManualScheduler
        let center: NotificationCenter
        let opened: Opened
    }

    private func rig(_ access: CalendarAccess = .granted, events: [MediaEvent] = [],
                     defaults: UserDefaults? = nil) -> Rig {
        let calendar = FakeCalendar(access, events: events)
        let clock = FakeClock(t0)
        let scheduler = ManualScheduler()
        let center = NotificationCenter()
        let opened = Opened()
        let module = AgendaModule(defaults: defaults ?? makeEphemeralDefaults(self), calendar: calendar, clock: clock.read,
                                  scheduler: scheduler.scheduler, center: center, workspaceCenter: NotificationCenter(),
                                  opener: { opened.urls.append($0) })
        addTeardownBlock { module.stop() }
        return Rig(module: module, calendar: calendar, clock: clock, scheduler: scheduler, center: center, opened: opened)
    }

    /// Le temps passe jusqu'à l'échéance planifiée, qui se déclenche.
    private func advanceToWake(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        guard let task = rig.scheduler.pending.first else { return XCTFail("aucune échéance planifiée", file: file, line: line) }
        rig.clock.advance(task.delay)
        rig.scheduler.fire(task)
    }

    private func storeChanged(_ center: NotificationCenter) {
        center.post(name: .EKEventStoreChanged, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testNothingRunsWithoutAccessAndNothingIsAsked() {
        let r = rig(.notDetermined, events: [event(at: t0.addingTimeInterval(600))])
        XCTAssertFalse(r.module.keepsRunningWhenCollapsed)
        XCTAssertNil(r.module.ears)
        r.module.start()
        XCTAssertEqual(r.calendar.requests, 0, "jamais de demande d'accès sans geste de l'utilisateur")
        XCTAssertTrue(r.calendar.fetches.isEmpty)
        XCTAssertTrue(r.scheduler.pending.isEmpty)

        r.module.requestAccess()
        XCTAssertEqual(r.calendar.requests, 1)
        XCTAssertEqual(r.module.access, .granted)
        XCTAssertTrue(r.module.keepsRunningWhenCollapsed, "accès accordé : il tourne aussi replié")
        XCTAssertEqual(r.module.events.map { $0.id }, ["e"], "lu dès l'accord")
        XCTAssertEqual(r.scheduler.pending.count, 1)

        let denied = rig(.denied)
        denied.module.start()
        XCTAssertFalse(denied.module.keepsRunningWhenCollapsed)
        XCTAssertTrue(denied.calendar.fetches.isEmpty)
        denied.module.requestAccess()
        XCTAssertEqual(denied.calendar.requests, 0, "refusé : seul Réglages Système peut le changer")
    }

    func testOneWakeAtATimeAndTheCountdownFollowsThem() throws {
        let meeting = event(at: t0.addingTimeInterval(20 * 60), minutes: 30, notes: zoom)
        let r = rig(events: [meeting])
        r.module.start()
        XCTAssertEqual(r.scheduler.pending.count, 1)
        XCTAssertEqual(try XCTUnwrap(r.scheduler.pending.first).delay, 5 * 60, accuracy: 0.001, "début − 15 min")
        XCTAssertNil(r.module.ears, "20 min avant : rien")

        advanceToWake(r)
        var ears = try XCTUnwrap(r.module.ears)
        XCTAssertEqual(ears.text, String(format: L("%d min", table: "Agenda"), 15))
        XCTAssertEqual(ears.symbol, "calendar")
        XCTAssertEqual(ears.accentHex, AgendaModule.softHex)
        XCTAssertFalse(ears.alert)
        XCTAssertEqual(ears.priority, AgendaModule.earsPriority)
        XCTAssertEqual(r.scheduler.pending.count, 1, "une seule échéance à la fois")
        XCTAssertEqual(try XCTUnwrap(r.scheduler.pending.first).delay, 60, accuracy: 0.001, "la minute suivante")

        for minutes in (6...14).reversed() {
            advanceToWake(r)
            XCTAssertEqual(try XCTUnwrap(r.module.ears).text, String(format: L("%d min", table: "Agenda"), minutes))
            XCTAssertEqual(r.scheduler.pending.count, 1)
        }
        advanceToWake(r)
        ears = try XCTUnwrap(r.module.ears)
        XCTAssertEqual(ears.text, String(format: L("%d min", table: "Agenda"), 5))
        XCTAssertEqual(ears.symbol, "video.fill", "un lien de réunion : la caméra")
        XCTAssertEqual(ears.accentHex, AgendaModule.imminentHex, "à 5 min : ambre")
        XCTAssertTrue(ears.alert, "reste déployé même en mode Rétractés")
        XCTAssertGreaterThan(ears.priority, TimerModule.earsPriority, "au-dessus du minuteur")

        for _ in 0..<5 { advanceToWake(r) }
        ears = try XCTUnwrap(r.module.ears)
        XCTAssertEqual(ears.text, L("en cours", table: "Agenda"))
        XCTAssertEqual(ears.accentHex, AgendaModule.runningHex)
        XCTAssertFalse(ears.alert)
        XCTAssertEqual(try XCTUnwrap(r.scheduler.pending.first).delay, 30 * 60, accuracy: 0.001, "rien avant la fin")
        XCTAssertEqual(r.scheduler.pending.count, 1)

        advanceToWake(r)
        XCTAssertNil(r.module.ears, "fini : l'intercalaire disparaît")
        XCTAssertTrue(r.scheduler.pending.isEmpty, "plus rien à attendre : aucune échéance")
        XCTAssertNil(r.module.nextWake)
        XCTAssertTrue(r.module.keepsRunningWhenCollapsed, "il reste à l'écoute de la base (un événement peut être ajouté)")
    }

    func testAnEventWithoutLinkKeepsTheCalendarIcon() throws {
        let r = rig(events: [event(at: t0.addingTimeInterval(4 * 60))])
        r.module.start()
        XCTAssertEqual(try XCTUnwrap(r.module.ears).symbol, "calendar")
    }

    func testStoreChangesReplanAndDropDeletedEvents() throws {
        let r = rig(events: [event("a", at: t0.addingTimeInterval(30 * 60))])
        r.module.start()
        XCTAssertEqual(r.scheduler.pending.count, 1)
        XCTAssertEqual(try XCTUnwrap(r.scheduler.pending.first).delay, 15 * 60, accuracy: 0.001)
        let fetches = r.calendar.fetches.count

        // Un événement plus proche est ajouté dans Calendrier.
        r.calendar.all.append(event("b", at: t0.addingTimeInterval(10 * 60)))
        storeChanged(r.center)
        XCTAssertEqual(r.calendar.fetches.count, fetches + 1)
        XCTAssertEqual(r.module.events.map { $0.id }, ["b", "a"])
        XCTAssertEqual(try XCTUnwrap(r.module.ears).text, String(format: L("%d min", table: "Agenda"), 10))
        XCTAssertEqual(r.scheduler.pending.count, 1, "l'ancienne échéance est annulée")
        XCTAssertEqual(try XCTUnwrap(r.scheduler.pending.first).delay, 60, accuracy: 0.001)

        // Il est déplacé de 20 minutes : l'intercalaire disparaît avec son ancien horaire.
        r.calendar.all = [event("b", at: t0.addingTimeInterval(30 * 60)), event("a", at: t0.addingTimeInterval(30 * 60))]
        storeChanged(r.center)
        XCTAssertNil(r.module.ears)
        XCTAssertEqual(try XCTUnwrap(r.scheduler.pending.first).delay, 15 * 60, accuracy: 0.001)

        // Supprimés : plus rien à attendre.
        r.calendar.all = []
        storeChanged(r.center)
        XCTAssertNil(r.module.ears)
        XCTAssertTrue(r.module.events.isEmpty)
        XCTAssertTrue(r.scheduler.pending.isEmpty)
    }

    func testOnlyTheLastReadCountsWhenChangesPileUp() {
        let calendar = DeferredCalendar()
        let center = NotificationCenter()
        let module = AgendaModule(defaults: makeEphemeralDefaults(self), calendar: calendar, clock: FakeClock(t0).read,
                                  scheduler: ManualScheduler().scheduler, center: center, workspaceCenter: NotificationCenter())
        addTeardownBlock { module.stop() }
        module.start()
        XCTAssertEqual(calendar.fetches, 1)
        for _ in 0..<20 { storeChanged(center) }
        XCTAssertEqual(calendar.fetches, 1, "une lecture est en cours : les changements suivants attendent")
        calendar.complete([event(at: t0.addingTimeInterval(60))])
        XCTAssertEqual(calendar.fetches, 2, "une seule relecture pour tous ces changements")
        calendar.complete()
        XCTAssertEqual(calendar.fetches, 2)
        XCTAssertTrue(module.events.isEmpty, "la dernière lecture l'emporte")
    }

    func testStopReleasesEverything() {
        let r = rig(events: [event(at: t0.addingTimeInterval(30 * 60))])
        r.module.start()
        XCTAssertEqual(r.scheduler.pending.count, 1)
        r.module.stop()
        XCTAssertTrue(r.scheduler.pending.isEmpty, "échéance annulée")
        XCTAssertTrue(r.module.events.isEmpty)
        XCTAssertEqual(r.calendar.releases, 1, "base libérée")
        let fetches = r.calendar.fetches.count
        storeChanged(r.center)
        XCTAssertEqual(r.calendar.fetches.count, fetches, "plus d'observateur")
        XCTAssertTrue(r.scheduler.pending.isEmpty)
        // Redémarrage : tout repart.
        r.module.start()
        XCTAssertEqual(r.scheduler.pending.count, 1)
    }

    func testDayChangeClockAndWakeReloadTheBase() {
        let workspace = NotificationCenter()
        let calendar = FakeCalendar(.granted)
        let center = NotificationCenter()
        let module = AgendaModule(defaults: makeEphemeralDefaults(self), calendar: calendar, clock: FakeClock(t0).read,
                                  scheduler: ManualScheduler().scheduler, center: center, workspaceCenter: workspace)
        addTeardownBlock { module.stop() }
        module.start()
        let today = Calendar.current.startOfDay(for: t0)
        module.selectedDay = Calendar.current.date(byAdding: .day, value: 14, to: today)!
        var count = calendar.fetches.count
        for (target, name) in [(center, Notification.Name.NSSystemClockDidChange),
                               (workspace, NSWorkspace.didWakeNotification)] {
            target.post(name: name, object: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(calendar.fetches.count, count + 1, name.rawValue)
            count += 1
        }
        center.post(name: .NSCalendarDayChanged, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertGreaterThan(calendar.fetches.count, count)
        XCTAssertEqual(module.selectedDay, today, "le changement de jour ramène à aujourd'hui")
    }

    func testPanelOpensOnToday() {
        let r = rig()
        r.module.start()
        let today = Calendar.current.startOfDay(for: t0)
        r.module.selectedDay = Calendar.current.date(byAdding: .day, value: 21, to: today)!
        let fetches = r.calendar.fetches.count
        r.module.panelAppeared()
        XCTAssertEqual(r.module.selectedDay, today)
        XCTAssertGreaterThan(r.calendar.fetches.count, fetches)
    }

    func testJoinOpensOnlyAKnownLinkOnRequest() throws {
        let withLink = event("l", at: t0.addingTimeInterval(240), notes: zoom)
        let r = rig(events: [withLink])
        r.module.start()
        XCTAssertTrue(r.opened.urls.isEmpty, "jamais d'ouverture sans clic")
        r.module.join(withLink)
        XCTAssertEqual(r.opened.urls.map { $0.absoluteString }, [zoom])

        r.module.join(event("n", at: t0))
        XCTAssertEqual(r.opened.urls.count, 1, "pas de lien : pas de bouton, rien à ouvrir")

        // Même un lien déjà dans l'événement est revérifié avant l'ouverture.
        for text in ["https://evil.example/j/1", "file:///Applications/Calculator.app", "javascript:alert(1)"] {
            var forged = event("f", at: t0)
            forged.meeting = MeetingLink(provider: .zoom, url: try XCTUnwrap(URL(string: text)))
            r.module.join(forged)
        }
        XCTAssertEqual(r.opened.urls.count, 1, "liens refusés : \(r.opened.urls)")
    }

    func testSettingsPersistAndHiddenCalendarsAreHonoured() {
        let defaults = makeEphemeralDefaults(self)
        let r = rig(events: [event(at: t0.addingTimeInterval(240))], defaults: defaults)
        XCTAssertTrue(r.module.showEars)
        r.module.start()
        XCTAssertNotNil(r.module.ears)

        r.module.hiddenCalendars = ["perso"]
        XCTAssertEqual(r.calendar.fetches.last, ["perso"])
        r.module.showEars = false
        XCTAssertNil(r.module.ears, "intercalaire désactivé")
        XCTAssertFalse(r.module.keepsRunningWhenCollapsed, "et plus de travail replié")

        let reloaded = rig(defaults: defaults)
        XCTAssertFalse(reloaded.module.showEars)
        XCTAssertEqual(reloaded.module.hiddenCalendars, ["perso"])
    }

    func testRegistryStartsItCollapsedAndShowsTheEarTab() throws {
        let r = rig(events: [event(at: t0.addingTimeInterval(240), notes: zoom)])
        let registry = ModuleRegistry(modules: [FakeModule(id: "claude"), r.module],
                                      prefs: Preferences(defaults: makeEphemeralDefaults(self)))
        XCTAssertEqual(registry.running, ["agenda"], "replié au lancement : démarré parce que l'accès est accordé")
        wait { registry.moduleEars != nil }
        let tabs = registry.earTabs(claude: .none, claudeEars: nil)
        XCTAssertEqual(tabs.map { $0.id }, ["agenda"])
        let tab = try XCTUnwrap(tabs.first)
        XCTAssertEqual(tab.accentHex, AgendaModule.imminentHex, "la couleur de l'état, pas celle du module")
        XCTAssertTrue(tab.isAlert)
        XCTAssertEqual(tab.text, String(format: L("%d min", table: "Agenda"), 4))

        // Sans accès : rien ne tourne replié.
        let asking = rig(.notDetermined)
        let quiet = ModuleRegistry(modules: [FakeModule(id: "claude"), asking.module],
                                   prefs: Preferences(defaults: makeEphemeralDefaults(self)))
        XCTAssertEqual(quiet.running, [])
        XCTAssertTrue(asking.calendar.fetches.isEmpty)
        XCTAssertEqual(EarTabs.accentHex(forId: "agenda"), AgendaModule.softHex)
    }

    func testContractAndViews() {
        let module = rig().module
        XCTAssertEqual(module.id, "agenda")
        XCTAssertTrue(module.isEnabledByDefault)
        XCTAssertFalse(module.title.isEmpty)
        XCTAssertNotNil(NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil))
        XCTAssertNotNil(module.makeCompactView())
        XCTAssertNotNil(module.makeTabDetailView())
        XCTAssertNotNil(module.makeSettingsView())
        XCTAssertNotNil(module.makeHeaderAccessory())
        _ = module.makeView()
    }

    // MARK: - Barre de commande

    /// « a » liste les prochains rendez-vous (finis et journées entières exclus) ; ⏎ rejoint par `join`, rien avant.
    func testCommandBarListsUpcomingEventsAndJoinsOnlyOnRun() throws {
        let meeting = event("l", at: t0.addingTimeInterval(240), notes: zoom, title: "Point équipe")
        let later = event("p", at: t0.addingTimeInterval(7200), title: "Dentiste")
        let past = event("x", at: t0.addingTimeInterval(-7200), title: "Point passé")
        let allDay = event("d", at: t0, minutes: 24 * 60, allDay: true, title: "Congés")
        let r = rig(events: [later, past, meeting, allDay])
        r.module.start()
        func ids(_ verb: String?, _ argument: String) -> [String] {
            r.module.commands(for: CommandQuery(verb: verb, argument: argument)).map(\.id)
        }
        XCTAssertEqual(ids("a", ""), ["agenda.join.l", "agenda.open.p"])
        XCTAssertEqual(ids("a", "dent"), ["agenda.open.p"])
        XCTAssertEqual(ids(nil, "po"), [], "sans verbe, trois lettres au moins")
        XCTAssertEqual(ids(nil, "point"), ["agenda.join.l"])
        let join = try XCTUnwrap(r.module.commands(for: CommandQuery(verb: "a", argument: "équipe")).first)
        XCTAssertTrue(r.opened.urls.isEmpty, "rien ne s'ouvre avant ⏎")
        XCTAssertNil(join.run())
        XCTAssertEqual(r.opened.urls.map(\.absoluteString), [zoom])
    }
}
