import XCTest
@testable import Oriel

/// Mode série : en plein écran rien ne descend, un seul résumé à la sortie. Logique seule, horloge injectée.
final class PopupFullScreenTests: XCTestCase {
    private func event(_ source: String = "messages", key: String, extra: Int = 0) -> PopupEvent {
        PopupEvent(source: source, symbol: "message.fill", title: "Camille", text: "Secret", key: key, extra: extra)
    }

    private func makeQueue() -> (NotificationPopups, ManualScheduler) {
        let scheduler = ManualScheduler()
        return (NotificationPopups(scheduler: scheduler.scheduler), scheduler)
    }

    func testNothingDropsInFullScreenThenOneSummaryOnExit() {
        let (queue, scheduler) = makeQueue()
        queue.setFullScreen(true)
        queue.post(event("messages", key: "a"))
        queue.post(event("messages", key: "b"))
        queue.post(event("mail", key: "c"))
        queue.post(event("claude", key: "d"))
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertTrue(scheduler.pending.isEmpty, "aucun minuteur en plein écran")
        queue.setFullScreen(false)
        XCTAssertEqual(queue.current?.text, "2 messages, 1 mail, 1 pour Claude")
        XCTAssertEqual(queue.current?.source, "messages", "un clic ouvre l'onglet le plus chargé")
        XCTAssertFalse(queue.current?.text.contains("Secret") ?? true, "ni texte ni expéditeur")
        scheduler.fire(delay: NotificationPopups.displayDuration)
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.pending.isEmpty, "un seul pop-up, pas de file")
    }

    func testNoSummaryWhenNothingArrived() {
        let (queue, scheduler) = makeQueue()
        queue.setFullScreen(true)
        queue.setFullScreen(false)
        XCTAssertNil(queue.current)
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testSameElementIsCountedOnce() {
        let (queue, _) = makeQueue()
        queue.setFullScreen(true)
        queue.post(event(key: "a"))
        queue.post(event(key: "a"))
        queue.setFullScreen(false)
        XCTAssertEqual(queue.current?.text, "1 message")
    }

    func testCountsAreBoundedInValueAndInSources() {
        let (queue, _) = makeQueue()
        queue.setFullScreen(true)
        for index in 0..<150 { queue.post(event(key: "k\(index)")) }
        for source in (0..<20).map({ "s\($0)" }) { queue.post(event(source, key: "x")) }
        queue.setFullScreen(false)
        let text = queue.current?.text ?? ""
        XCTAssertTrue(text.hasPrefix("99 messages"), text)
        XCTAssertEqual(text.split(separator: ",").count, NotificationPopups.maxHeldSources, "sources bornées")
    }

    func testEnteringKeepsWaitingEventsAndDoesNotRecountTheOneShown() {
        let (queue, _) = makeQueue()
        queue.post(event("claude", key: "shown"))
        queue.post(event("mail", key: "waiting"))
        queue.post(event("mail", key: "waiting2"))
        queue.setFullScreen(true)
        XCTAssertNil(queue.current, "plus rien à l'écran")
        queue.post(event("claude", key: "shown"))
        queue.setFullScreen(false)
        XCTAssertEqual(queue.current?.text, "2 mails", "le pop-up déjà vu n'est pas recompté")
    }

    func testExitWithAPopupAlreadyOnScreenQueuesTheSummaryBehindIt() {
        let (queue, scheduler) = makeQueue()
        queue.setFullScreen(true)
        queue.post(event(key: "a"))
        queue.setFullScreen(false)
        queue.post(event("mail", key: "m"))
        XCTAssertEqual(queue.current?.title, "Pendant le plein écran")
        XCTAssertEqual(queue.pending.map(\.source), ["mail"])
        scheduler.fire(delay: NotificationPopups.displayDuration)
        scheduler.fire(delay: NotificationPopups.gap)
        XCTAssertEqual(queue.current?.source, "mail")
    }

    func testTwoSummariesInARowAreBothShown() {
        let (queue, scheduler) = makeQueue()
        queue.setFullScreen(true)
        queue.post(event(key: "a"))
        queue.setFullScreen(false)
        scheduler.fire(delay: NotificationPopups.displayDuration)
        queue.setFullScreen(true)
        queue.post(event(key: "b"))
        queue.setFullScreen(false)
        XCTAssertEqual(queue.current?.text, "1 message")
    }

    func testDisabledOrBlockedHoldsNothing() {
        let (queue, _) = makeQueue()
        queue.isEnabled = false
        queue.setFullScreen(true)
        queue.post(event(key: "a"))
        queue.isEnabled = true
        queue.setFullScreen(false)
        XCTAssertNil(queue.current, "réglage coupé : rien n'est retenu")

        queue.isSourceEnabled = { $0 != "mail" }
        queue.setFullScreen(true)
        queue.post(event("mail", key: "m"))
        queue.post(event("messages", key: "n"))
        queue.setFullScreen(false)
        XCTAssertEqual(queue.current?.text, "1 message", "module désactivé : ignoré")
    }

    func testSettingDisabledDuringFullScreenDropsTheSummary() {
        let (queue, _) = makeQueue()
        queue.setFullScreen(true)
        queue.post(event(key: "a"))
        queue.isEnabled = false
        queue.setFullScreen(false)
        XCTAssertNil(queue.current)
    }
}
