import XCTest
@testable import Oriel

/// Croisement silence automatique × mode série : `decision(for:)` reste la seule porte, le plein écran ne compte que ce qui
/// l'a franchie, et le résumé de sortie repasse par cette porte. Logique seule, horloge injectée, aucune fenêtre.
final class PopupSilenceFullScreenTests: XCTestCase {
    private var situation = PopupSituation()

    private func makeQueue() -> NotificationPopups {
        let queue = NotificationPopups(scheduler: ManualScheduler().scheduler)
        queue.situation = { [unowned self] in situation }
        queue.sourceTitle = { "Onglet \($0)" }
        return queue
    }

    private func event(_ source: String = "messages", key: String) -> PopupEvent {
        PopupEvent(source: source, symbol: "message.fill", title: "Camille", text: "Rendez-vous secret", key: key,
                   redactedText: "Nouveau message")
    }

    func testFocusDuringFullScreenCountsNothingAndLeavesNoSummary() {
        let queue = makeQueue()
        situation.focus = true
        queue.setFullScreen(true)
        queue.post(event(key: "a"))
        queue.post(event("mail", key: "b"))
        situation.focus = false
        queue.setFullScreen(false)
        XCTAssertNil(queue.current, "un événement refusé par Concentration n'est jamais retenu pour un résumé")
    }

    func testFocusAtExitDropsTheSummary() {
        let queue = makeQueue()
        queue.setFullScreen(true)
        queue.post(event(key: "a"))
        situation.focus = true
        queue.setFullScreen(false)
        XCTAssertNil(queue.current, "le résumé repasse par la porte : Concentration le supprime aussi")
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testHeldEventsNeverRevealTextAndSummaryStaysMaskedWhileMicIsBusy() {
        let queue = makeQueue()
        situation.microphoneBusy = true
        queue.setFullScreen(true)
        queue.post(event(key: "a"))
        queue.post(event(key: "b"))
        XCTAssertNil(queue.current)
        queue.setFullScreen(false)
        let shown = queue.current
        XCTAssertEqual(shown?.text, "Pendant le plein écran", "même les compteurs restent cachés")
        for text in [shown?.title, shown?.text, shown?.redactedText].compactMap({ $0 }) {
            XCTAssertFalse(text.contains("Camille") || text.contains("secret"), text)
        }
        XCTAssertEqual(shown?.title, "Onglet messages", "le masquage s'applique aussi au résumé")
    }

    func testBlockedNotchAtExitDropsTheSummaryToo() {
        let queue = makeQueue()
        queue.setFullScreen(true)
        queue.post(event(key: "a"))
        queue.isBlocked = { true }
        queue.setFullScreen(false)
        XCTAssertNil(queue.current)
    }

    func testCalmExitShowsTheCountsSummary() {
        let queue = makeQueue()
        queue.setFullScreen(true)
        queue.post(event(key: "a"))
        queue.setFullScreen(false)
        XCTAssertEqual(queue.current?.text, "1 message")
        XCTAssertEqual(queue.current?.title, "Pendant le plein écran")
    }

    func testPendingEventIsDecidedAgainWhenItsTurnComes() {
        let scheduler = ManualScheduler()
        let queue = NotificationPopups(scheduler: scheduler.scheduler)
        queue.situation = { [unowned self] in situation }
        queue.sourceTitle = { "Onglet \($0)" }
        queue.post(event("mail", key: "a"))
        queue.post(event(key: "b"))
        queue.post(event("claude", key: "c"))
        XCTAssertEqual(queue.pending.count, 2)
        situation.microphoneBusy = true
        scheduler.fire(delay: NotificationPopups.displayDuration)
        scheduler.fire(delay: NotificationPopups.gap)
        XCTAssertEqual(queue.current?.title, "Onglet messages", "une visio démarrée pendant l'attente masque le pop-up en file")
        XCTAssertEqual(queue.current?.text, "Nouveau message")
        situation.focus = true
        scheduler.fire(delay: NotificationPopups.displayDuration)
        scheduler.fire(delay: NotificationPopups.gap)
        XCTAssertNil(queue.current, "Concentration activé pendant l'attente : le pop-up en file est supprimé")
    }
}
