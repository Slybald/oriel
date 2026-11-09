import XCTest
@testable import Oriel

/// La file des pop-ups est utilisée par plusieurs modules (Claude, Codex, Mail, Messages, Minuteur, Agenda). Aujourd'hui
/// chacun arrive sur le fil principal ; ces tests garantissent que la file le reste même si un appel part d'ailleurs :
/// ses réglages-fonctions (situation, notch bloquée…) ne tournent que sur le fil principal et l'ordre est gardé.
/// Logique seule, horloge injectée, aucune fenêtre.
final class PopupThreadTests: XCTestCase {
    private let lock = NSLock()
    private var offMainCalls: [String] = []
    private var situation = PopupSituation()

    private func record(_ name: String) {
        if !Thread.isMainThread { lock.lock(); offMainCalls.append(name); lock.unlock() }
    }

    private func makeQueue() -> (NotificationPopups, ManualScheduler) {
        let scheduler = ManualScheduler()
        let queue = NotificationPopups(scheduler: scheduler.scheduler)
        queue.isSourceEnabled = { [unowned self] _ in record("isSourceEnabled"); return true }
        queue.isBlocked = { [unowned self] in record("isBlocked"); return false }
        queue.situation = { [unowned self] in record("situation"); return situation }
        queue.sourceTitle = { [unowned self] in record("sourceTitle"); return "Onglet \($0)" }
        return (queue, scheduler)
    }

    private func event(_ source: String, key: String) -> PopupEvent {
        PopupEvent(source: source, symbol: "bell", title: "Camille", text: "Secret", key: key, redactedText: "Nouveau")
    }

    /// Exécute `work` sur un autre fil, dans l'ordre, puis laisse le fil principal vider ce qu'il a reçu.
    private func fromAnotherThread(_ work: @escaping () -> Void) {
        let done = expectation(description: "autre fil")
        DispatchQueue.global().async { work(); done.fulfill() }
        wait(for: [done], timeout: 5)
        let drained = expectation(description: "fil principal vidé")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    func testEventsPostedFromAnotherThreadKeepTheirOrderAndRunEverythingOnMain() {
        let (queue, _) = makeQueue()
        fromAnotherThread { [self] in
            for (source, key) in [("messages", "1"), ("mail", "2"), ("claude", "3")] where queue.accepts(source) {
                queue.post(event(source, key: key))
            }
        }
        XCTAssertEqual(queue.current?.source, "messages")
        XCTAssertEqual(queue.pending.map(\.source), ["mail", "claude"])
        XCTAssertEqual(offMainCalls, [], "aucun réglage-fonction ne doit tourner hors du fil principal")
    }

    func testSilenceAndGroupingHoldWhenEventsComeFromAnotherThread() {
        let (queue, _) = makeQueue()
        situation.microphoneBusy = true
        fromAnotherThread { [self] in
            queue.post(event("messages", key: "1"))
            queue.post(event("mail", key: "2"))
            queue.post(event("mail", key: "3"))
        }
        XCTAssertEqual(queue.current?.title, "Onglet messages")
        XCTAssertEqual(queue.current?.text, "Nouveau")
        XCTAssertEqual(queue.pending.first?.extra, 1, "deux mails regroupés « +1 »")
        XCTAssertEqual(offMainCalls, [])
    }

    func testFullScreenSummaryFromAnotherThread() {
        let (queue, _) = makeQueue()
        fromAnotherThread { [self] in
            queue.setFullScreen(true)
            queue.post(event("messages", key: "1"))
            queue.post(event("messages", key: "2"))
            queue.post(event("claude", key: "3"))
            queue.setFullScreen(false)
        }
        XCTAssertEqual(queue.current?.text, "2 messages, 1 pour Claude")
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertEqual(offMainCalls, [])
    }

    func testClearFromAnotherThreadEmptiesTheQueueOnMain() {
        let (queue, _) = makeQueue()
        queue.post(event("messages", key: "1"))
        queue.post(event("mail", key: "2"))
        fromAnotherThread { queue.clear() }
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    // MARK: Résumé qui attend la fermeture du panneau

    func testSummaryWaitsForThePanelToCloseThenAppearsOnce() {
        let (queue, scheduler) = makeQueue()
        var blocked = false
        queue.isBlocked = { blocked }
        queue.setFullScreen(true)
        queue.post(event("messages", key: "1"))
        blocked = true
        queue.setFullScreen(false)
        XCTAssertNil(queue.current, "panneau ouvert : le résumé attend")
        XCTAssertTrue(scheduler.pending.isEmpty, "aucun minuteur pour attendre")
        queue.flushSummary()
        XCTAssertNil(queue.current, "toujours ouvert")
        blocked = false
        queue.flushSummary()
        XCTAssertEqual(queue.current?.text, "1 message")
        queue.dismiss()
        queue.flushSummary()
        XCTAssertNil(queue.current, "un résumé n'apparaît qu'une fois")
    }

    func testWaitingSummaryStillGoesThroughTheSilenceDoor() {
        let (queue, _) = makeQueue()
        var blocked = true
        queue.isBlocked = { blocked }
        queue.setFullScreen(true)
        queue.post(event("messages", key: "1")) // bloqué : refusé dès l'arrivée
        blocked = false
        queue.post(event("messages", key: "1"))
        blocked = true
        queue.setFullScreen(false)
        situation.focus = true
        blocked = false
        queue.flushSummary()
        XCTAssertNil(queue.current, "Concentration supprime aussi le résumé qui a attendu")
    }

    func testAFullScreenStartedWhileWaitingKeepsTheCountsForTheNextExit() {
        let (queue, _) = makeQueue()
        var blocked = true
        queue.isBlocked = { blocked }
        queue.setFullScreen(true)
        blocked = false
        queue.post(event("messages", key: "1"))
        blocked = true
        queue.setFullScreen(false)
        queue.setFullScreen(true)
        blocked = false
        queue.post(event("messages", key: "2"))
        queue.flushSummary()
        XCTAssertNil(queue.current, "en plein écran, rien ne descend")
        queue.setFullScreen(false)
        XCTAssertEqual(queue.current?.text, "2 messages")
    }
}
