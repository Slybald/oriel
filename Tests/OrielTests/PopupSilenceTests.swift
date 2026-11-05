import XCTest
@testable import Oriel

/// Silence automatique des pop-ups : la table `show / redact / drop`, appliquée à chaque source. Logique seule, horloge
/// injectée, aucune fenêtre.
final class PopupSilenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let sources = ["messages", "mail", "agenda", "claude", "codex", "timer"]

    private func situation(meeting: Bool = false, mirrored: Bool = false, mic: Bool = false, focus: Bool = false) -> PopupSituation {
        PopupSituation(meeting: meeting, mirrored: mirrored, microphoneBusy: mic, focus: focus)
    }

    // MARK: - Table

    func testDecisionTableCoversEveryCombination() {
        for bits in 0..<16 {
            let s = situation(meeting: bits & 1 != 0, mirrored: bits & 2 != 0, mic: bits & 4 != 0, focus: bits & 8 != 0)
            let expected: PopupDecision = s.focus ? .drop : (bits & 7 != 0 ? .redact : .show)
            XCTAssertEqual(PopupSilence.decide(s), expected, "\(s)")
        }
    }

    // MARK: - File, chaque source × chaque situation

    private func post(_ source: String, in s: PopupSituation) -> (PopupEvent?, accepted: Bool, timers: Int) {
        let scheduler = ManualScheduler()
        let queue = NotificationPopups(scheduler: scheduler.scheduler)
        queue.situation = { s }
        queue.sourceTitle = { "Onglet \($0)" }
        let accepted = queue.accepts(source)
        queue.post(PopupEvent(source: source, symbol: "bell", title: "Camille", text: "Rendez-vous secret", key: "k",
                              redactedText: source == "messages" ? "Nouveau message" : nil))
        return (queue.current, accepted, scheduler.pending.count)
    }

    func testCalmSituationShowsEverythingAsIs() {
        for source in sources {
            let (event, accepted, _) = post(source, in: situation())
            XCTAssertTrue(accepted, source)
            XCTAssertEqual(event?.title, "Camille", source)
            XCTAssertEqual(event?.text, "Rendez-vous secret", source)
        }
    }

    func testMeetingMirrorOrMicrophoneHideTheContentOfEverySource() {
        for s in [situation(meeting: true), situation(mirrored: true), situation(mic: true), situation(meeting: true, mirrored: true, mic: true)] {
            for source in sources {
                let (event, accepted, _) = post(source, in: s)
                XCTAssertTrue(accepted, "\(source) \(s)")
                XCTAssertEqual(event?.title, "Onglet \(source)", "ni expéditeur ni titre : \(source) \(s)")
                XCTAssertEqual(event?.text, source == "messages" ? "Nouveau message" : "Rendez-vous secret",
                               "la ligne neutre si la source en a une, sinon son texte à elle : \(source)")
            }
        }
    }

    func testFocusDropsEverySourceAndArmsNothing() {
        for source in sources {
            let (event, accepted, timers) = post(source, in: situation(meeting: true, mirrored: true, mic: true, focus: true))
            XCTAssertFalse(accepted, "les modules ne font aucun travail de plus : \(source)")
            XCTAssertNil(event, source)
            XCTAssertEqual(timers, 0, "aucune échéance : \(source)")
        }
    }

    func testSituationIsReadWhenAPopupArrivesNotBefore() {
        let scheduler = ManualScheduler()
        let queue = NotificationPopups(scheduler: scheduler.scheduler)
        var reads = 0
        queue.situation = { reads += 1; return PopupSituation() }
        XCTAssertEqual(reads, 0, "rien en tâche de fond")
        queue.isEnabled = false
        queue.post(PopupEvent(source: "mail", symbol: "x", title: "t", text: "t", key: "k"))
        XCTAssertEqual(reads, 0, "réglage coupé : on ne lit rien")
    }

    // MARK: - Réunion

    private func meeting(start: Date, minutes: Int = 60, link: Bool = true, allDay: Bool = false) -> MediaEvent {
        MediaEvent(id: "e", title: "Point", start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)), isAllDay: allDay,
                   color: .red, location: "", meeting: link ? MeetingLink.find(url: nil, location: nil, notes: "https://us02web.zoom.us/j/123456789") : nil)
    }

    func testOnlyARunningEventWithALinkIsAMeeting() {
        XCTAssertTrue(AgendaMath.isInMeeting([meeting(start: t0 - 600)], at: t0))
        XCTAssertFalse(AgendaMath.isInMeeting([meeting(start: t0 - 600, link: false)], at: t0), "cours de 2 h sans lien")
        XCTAssertFalse(AgendaMath.isInMeeting([meeting(start: t0 + 120)], at: t0), "pas encore commencé")
        XCTAssertFalse(AgendaMath.isInMeeting([meeting(start: t0 - 7200)], at: t0), "terminé")
        XCTAssertFalse(AgendaMath.isInMeeting([meeting(start: t0 - 600, allDay: true)], at: t0))
        XCTAssertFalse(AgendaMath.isInMeeting([], at: t0))
    }

    // MARK: - Lectures du système

    func testProbesAnswerWithoutAskingAnything() {
        // Les valeurs dépendent de ce Mac ; ce qui compte : pas de plantage, pas de dialogue (aucune demande d'autorisation).
        _ = PopupProbes.mirrored()
        _ = PopupProbes.microphoneBusy()
        _ = PopupProbes.focus()
    }
}
