import XCTest
@testable import Oriel

/// Pop-ups de la notch : file, durée, survol, et ce que chaque source déclenche. Logique seule, horloge injectée :
/// aucune fenêtre ni panneau, aucun délai réel.
final class PopupTests: XCTestCase {
    private func event(_ source: String = "messages", key: String = "a", title: String = "Camille", text: String = "Salut",
                       extra: Int = 0) -> PopupEvent {
        PopupEvent(source: source, symbol: "message.fill", title: title, text: text, key: key, extra: extra)
    }

    private func makeQueue() -> (NotificationPopups, ManualScheduler) {
        let scheduler = ManualScheduler()
        return (NotificationPopups(scheduler: scheduler.scheduler), scheduler)
    }

    // MARK: - File

    func testPopupShowsThenClosesAfterTheDuration() {
        let (queue, scheduler) = makeQueue()
        queue.post(event())
        XCTAssertEqual(queue.current?.title, "Camille")
        XCTAssertEqual(scheduler.pending.map(\.delay), [NotificationPopups.displayDuration])
        scheduler.fire(delay: NotificationPopups.displayDuration)
        XCTAssertNil(queue.current)
        XCTAssertTrue(scheduler.pending.isEmpty, "plus aucune échéance")
    }

    func testSecondPopupWaitsThenComesAfterAGap() {
        let (queue, scheduler) = makeQueue()
        queue.post(event("messages", key: "a"))
        queue.post(event("mail", key: "b", title: "Alex"))
        XCTAssertEqual(queue.current?.source, "messages", "jamais d'empilement")
        scheduler.fire(delay: NotificationPopups.displayDuration)
        XCTAssertNil(queue.current, "le premier se referme avant que le suivant ne descende")
        scheduler.fire(delay: NotificationPopups.gap)
        XCTAssertEqual(queue.current?.source, "mail")
    }

    func testEventDuringTheGapWaitsInLine() {
        let (queue, scheduler) = makeQueue()
        queue.post(event("messages", key: "a"))
        queue.post(event("mail", key: "b"))
        scheduler.fire(delay: NotificationPopups.displayDuration)
        queue.post(event("codex", key: "c"))
        XCTAssertNil(queue.current, "pas de clignotement : on attend la fin de la pause")
        scheduler.fire(delay: NotificationPopups.gap)
        XCTAssertEqual(queue.current?.source, "mail")
        XCTAssertEqual(queue.pending.map(\.source), ["codex"])
    }

    func testSameSourceEventsAreGroupedInOne() {
        let (queue, scheduler) = makeQueue()
        queue.post(event("claude", key: "a"))
        for key in ["b", "c", "d"] { queue.post(event("messages", key: key, title: "Titre \(key)")) }
        XCTAssertEqual(queue.pending.count, 1)
        XCTAssertEqual(queue.pending[0].title, "Titre d", "le plus récent donne le texte")
        XCTAssertEqual(queue.pending[0].extra, 2)
        scheduler.fire(delay: NotificationPopups.displayDuration)
        scheduler.fire(delay: NotificationPopups.gap)
        XCTAssertEqual(queue.current?.extra, 2)
    }

    func testSameElementIsNotShownTwice() {
        let (queue, scheduler) = makeQueue()
        queue.post(event(key: "a"))
        queue.post(event(key: "a"))
        XCTAssertTrue(queue.pending.isEmpty)
        queue.post(event("mail", key: "m"))
        queue.post(event("mail", key: "m"))
        XCTAssertEqual(queue.pending.map(\.extra), [0])
        scheduler.fire(delay: NotificationPopups.displayDuration)
        scheduler.fire(delay: NotificationPopups.gap)
        scheduler.fire(delay: NotificationPopups.displayDuration)
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testQueueIsBounded() {
        let (queue, _) = makeQueue()
        queue.post(event("claude"))
        for source in ["messages", "mail", "codex", "timer", "agenda"] { queue.post(event(source)) }
        XCTAssertEqual(queue.pending.count, NotificationPopups.maxPending)
        XCTAssertEqual(queue.pending.first?.source, "mail", "la plus ancienne est abandonnée")
    }

    // MARK: - Survol

    func testHoverKeepsItOpenAndLeavingGivesAShortGrace() {
        let (queue, scheduler) = makeQueue()
        queue.post(event())
        queue.setHovering(true)
        XCTAssertTrue(scheduler.pending.isEmpty, "la fermeture est suspendue")
        XCTAssertNotNil(queue.current)
        queue.setHovering(false)
        XCTAssertEqual(scheduler.pending.map(\.delay), [NotificationPopups.hoverGrace])
        scheduler.fire(delay: NotificationPopups.hoverGrace)
        XCTAssertNil(queue.current)
    }

    func testStaleHoverAfterTheCloseDoesNotShortenTheNextPopup() {
        let (queue, scheduler) = makeQueue()
        queue.post(event("claude", key: "a"))
        queue.post(event("mail", key: "b"))
        scheduler.fire(delay: NotificationPopups.displayDuration)
        queue.setHovering(true)
        scheduler.fire(delay: NotificationPopups.gap)
        XCTAssertEqual(queue.current?.source, "mail")
        queue.setHovering(false)
        XCTAssertEqual(scheduler.pending.map(\.delay), [NotificationPopups.displayDuration], "durée pleine, pas la grâce")
    }

    func testHoverBeforeAnyPopupIsIgnored() {
        let (queue, scheduler) = makeQueue()
        queue.setHovering(true)
        queue.post(event())
        queue.setHovering(false)
        XCTAssertEqual(scheduler.pending.map(\.delay), [NotificationPopups.displayDuration])
    }

    // MARK: - Quand rien ne s'affiche

    func testDisabledSettingSourceOrBlockedNotchDropsTheEvent() {
        let (queue, _) = makeQueue()
        queue.isEnabled = false
        queue.post(event())
        XCTAssertNil(queue.current)
        queue.isEnabled = true
        queue.isSourceEnabled = { $0 != "messages" }
        queue.post(event("messages"))
        XCTAssertNil(queue.current, "module désactivé")
        var blocked = true
        queue.isBlocked = { blocked }
        queue.post(event("mail"))
        XCTAssertNil(queue.current, "panneau ouvert, plein écran masqué…")
        blocked = false
        queue.post(event("mail"))
        XCTAssertEqual(queue.current?.source, "mail")
    }

    func testClearForgetsEverythingAndItsTimers() {
        let (queue, scheduler) = makeQueue()
        queue.post(event("claude"))
        queue.post(event("mail"))
        queue.clear()
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testClickDismissesAll() {
        let (queue, scheduler) = makeQueue()
        queue.post(event("claude"))
        queue.post(event("mail"))
        queue.dismiss()
        XCTAssertNil(queue.current)
        XCTAssertTrue(scheduler.pending.isEmpty, "les suivants n'arrivent pas après l'ouverture de l'onglet")
    }

    func testPopupIsOnByDefaultAndSurvivesNoSettingFile() {
        XCTAssertTrue(Preferences(defaults: makeEphemeralDefaults(self)).popupsEnabled)
    }

    // MARK: - Messages

    func testMessagesFirstReadIsTheBaselineThenOnlyNewReceivedMessagesPop() {
        let rig = MessagesRig(self)
        rig.popups.isEnabled = true
        let module = rig.startedModule()
        XCTAssertNil(rig.popups.current, "ce qui existe au lancement n'est pas nouveau")
        var rows = MessagesFixtures.sample.rows
        // Réponse de l'utilisateur, plus récente : pas de pop-up.
        rows.insert(MessagesFixtures.row("iMessage;-;alex@example.com", "alex@example.com", text: "ok", minutesAgo: 0.5,
                                         fromMe: true), at: 0)
        rig.database.result = .snapshot(MessagesSnapshot(rows: rows, unread: 3))
        module.refresh()
        XCTAssertNil(rig.popups.current)
        rows.insert(MessagesFixtures.row("iMessage;-;+15550100", "+15550100", text: "Tu viens ?", minutesAgo: 0.1, unread: 1),
                    at: 0)
        rig.database.result = .snapshot(MessagesSnapshot(rows: rows, unread: 4))
        module.refresh()
        XCTAssertEqual(rig.popups.current?.title, "+15550100")
        XCTAssertEqual(rig.popups.current?.text, "Tu viens ?")
        XCTAssertEqual(rig.popups.current?.source, "messages")
        module.refresh()
        XCTAssertNil(rig.popups.pending.first, "la même lecture ne redéclenche rien")
    }

    func testMessagesHiddenTextNeverReachesThePopup() {
        let rig = MessagesRig(self)
        rig.popups.isEnabled = true
        let module = rig.startedModule()
        module.showText = false
        var rows = MessagesFixtures.sample.rows
        rows.insert(MessagesFixtures.row("iMessage;-;+15550100", "+15550100", text: "secret", minutesAgo: 0.1, unread: 1), at: 0)
        rig.database.result = .snapshot(MessagesSnapshot(rows: rows, unread: 4))
        module.refresh()
        XCTAssertNotNil(rig.popups.current)
        XCTAssertFalse(rig.popups.current?.text.contains("secret") ?? true)
    }

    func testMessagesNoPopupWhenSettingOffAndAfterAStopTheBaselineIsReset() {
        let rig = MessagesRig(self)
        rig.popups.isEnabled = true
        let module = rig.startedModule()
        rig.popups.isEnabled = false
        var rows = MessagesFixtures.sample.rows
        rows.insert(MessagesFixtures.row("g", "+1", text: "x", minutesAgo: 0.1, unread: 1), at: 0)
        rig.database.result = .snapshot(MessagesSnapshot(rows: rows, unread: 4))
        module.refresh()
        XCTAssertNil(rig.popups.current, "réglage coupé")
        rig.popups.isEnabled = true
        module.stop()
        module.start()
        XCTAssertNil(rig.popups.current, "redémarré : ce qui est déjà là est la nouvelle référence")
    }

    func testMessagesKeepsRunningForPopupsEvenWithoutBadge() {
        let rig = MessagesRig(self)
        rig.popups.isEnabled = true
        let module = rig.startedModule()
        module.showBadge = false
        XCTAssertTrue(module.keepsRunningWhenCollapsed)
        rig.popups.isEnabled = false
        XCTAssertFalse(module.keepsRunningWhenCollapsed, "ni badge ni pop-up : rien ne tourne replié")
    }

    // MARK: - Mail

    func testMailFirstCountIsTheBaselineThenARiseReadsTheListOnceAndPops() {
        let rig = MailRig(self)
        rig.popups.isEnabled = true
        rig.runner.answers = [.success(MailRig.answer(unread: 2, messages: []))]
        let module = rig.makeModule()
        module.start()
        XCTAssertNil(rig.popups.current)
        XCTAssertEqual(rig.runner.calls.count, 1)
        XCTAssertEqual(rig.runner.calls[0].arguments, ["0"], "replié : le compteur seul")

        let mails = [FakeMail(sender: "Alex Durand", subject: "Devis", age: 30, id: "m1"),
                     FakeMail(sender: "Ancien", subject: "Vieux", age: 9_000, id: "m0", unread: false)]
        rig.runner.answers = [.success(MailRig.answer(unread: 3)), .success(MailRig.answer(unread: 3, messages: mails))]
        rig.schedule.runPending()
        XCTAssertEqual(rig.runner.calls.count, 3, "une lecture de liste de plus, une seule")
        XCTAssertEqual(rig.runner.calls[2].arguments, [String(module.recentCount)])
        XCTAssertEqual(rig.popups.current?.title, "Alex Durand")
        XCTAssertEqual(rig.popups.current?.text, "Devis")
    }

    func testMailWithSubjectsHiddenSaysOnlyHowManyAndReadsNoList() {
        let rig = MailRig(self)
        rig.popups.isEnabled = true
        rig.runner.answers = [.success(MailRig.answer(unread: 1))]
        let module = rig.makeModule()
        module.showSubjects = false
        module.start()
        rig.runner.answers = [.success(MailRig.answer(unread: 3))]
        rig.schedule.runPending()
        XCTAssertEqual(rig.runner.calls.count, 2)
        XCTAssertEqual(rig.popups.current?.title, "Mail")
        XCTAssertEqual(rig.popups.current?.text, "2 nouveaux mails")
    }

    func testMailLeavingBeforeTheListReadDoesNotAnnounceAnOldMailAtRelaunch() {
        let rig = MailRig(self)
        rig.popups.isEnabled = true
        rig.runner.answers = [.success(MailRig.answer(unread: 2))]
        let module = rig.makeModule()
        module.start()
        rig.runner.hold = true
        rig.runner.answers = [.success(MailRig.answer(unread: 3))]
        rig.schedule.runPending()
        rig.runner.complete(.success(MailRig.answer(unread: 3)))
        rig.running = false
        module.refresh()
        rig.runner.hold = false
        rig.running = true
        rig.runner.answers = [.success(MailRig.answer(unread: 3, messages: [FakeMail(sender: "Ancien", subject: "Vieux", age: 9_000, id: "m0")]))]
        module.refresh()
        XCTAssertNil(rig.popups.current)
    }

    func testMailDoesNotPopWhenTheCountFalls() {
        let rig = MailRig(self)
        rig.popups.isEnabled = true
        rig.runner.answers = [.success(MailRig.answer(unread: 3))]
        let module = rig.makeModule()
        module.start()
        rig.runner.answers = [.success(MailRig.answer(unread: 1))]
        rig.schedule.runPending()
        XCTAssertNil(rig.popups.current)
        XCTAssertEqual(rig.runner.calls.count, 2)
    }

    // MARK: - Claude et Codex

    func testClaudeMomentsAreTransitionsNotStates() {
        var session = Session(id: "s", cwd: "/tmp/projet")
        session.phase = .tool
        var waiting = session
        waiting.phase = .waitingPermission
        var done = session
        done.phase = .done
        XCTAssertEqual(PopupMoment.claude(old: session, new: waiting), .attention)
        XCTAssertEqual(PopupMoment.claude(old: nil, new: waiting), .attention, "session apparue en attente")
        XCTAssertNil(PopupMoment.claude(old: waiting, new: waiting), "toujours en attente : rien")
        var planning = waiting
        planning.phase = .planReview
        XCTAssertNil(PopupMoment.claude(old: waiting, new: planning), "de l'attente à l'attente")
        XCTAssertEqual(PopupMoment.claude(old: session, new: done), .done)
        XCTAssertNil(PopupMoment.claude(old: done, new: done))
        XCTAssertNil(PopupMoment.claude(old: waiting, new: session))
    }

    func testCodexMoments() {
        var session = CodexSession(id: "c", cwd: "/tmp/projet")
        session.phase = .working
        var waiting = session
        waiting.phase = .waitingApproval
        var done = session
        done.phase = .done
        XCTAssertEqual(PopupMoment.codex(old: session, new: waiting), .attention)
        XCTAssertEqual(PopupMoment.codex(old: session, new: done), .done)
        XCTAssertNil(PopupMoment.codex(old: done, new: done))
        XCTAssertNil(PopupMoment.codex(old: nil, new: session))
    }

    func testClaudeStorePopsOnceWithTheSessionNameAndNoConversation() {
        let (queue, _) = makeQueue()
        let store = SessionStore()
        store.popups = queue
        let context = ProcessContext()
        store.handle(HookEvent(raw: ["hook_event_name": "SessionStart", "session_id": "s1", "cwd": "/tmp/mon-projet"]),
                     context: context)
        XCTAssertNil(queue.current, "une session qui démarre n'est pas un événement")
        store.handle(HookEvent(raw: ["hook_event_name": "Stop", "session_id": "s1", "cwd": "/tmp/mon-projet",
                                     "last_assistant_message": "Très secret"]), context: context)
        XCTAssertEqual(queue.current?.title, "mon-projet")
        XCTAssertEqual(queue.current?.text, "Terminé")
        XCTAssertEqual(queue.current?.source, "claude")
        XCTAssertFalse(queue.current?.text.contains("secret") ?? true)
    }

    // MARK: - Minuteur et agenda

    func testTimerFinishPopsUnlessItEndedWhileAsleep() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 1)
        rig.clock.now = try XCTUnwrap(module.state.endDate)
        module.tick()
        XCTAssertEqual(rig.popups.current?.source, "timer")
        XCTAssertEqual(rig.popups.current?.title, "Minuteur terminé")
    }

    func testAgendaPopsWhenAMeetingBecomesImminentButNotIfItAlreadyWasAtLaunch() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func meeting(_ id: String, in seconds: TimeInterval) -> MediaEvent {
            MediaEvent(id: id, title: "Point \(id)", start: t0.addingTimeInterval(seconds),
                       end: t0.addingTimeInterval(seconds + 1_800), isAllDay: false, color: .red)
        }
        let queue = NotificationPopups(scheduler: ManualScheduler().scheduler)
        let scheduler = ManualScheduler()
        let clock = FakeClock(t0)
        let calendar = FakeCalendar(.granted, events: [meeting("deja", in: 120), meeting("plus-tard", in: 1_200)])
        let module = AgendaModule(defaults: makeEphemeralDefaults(self), calendar: calendar, clock: clock.read,
                                  scheduler: scheduler.scheduler, center: NotificationCenter(),
                                  workspaceCenter: NotificationCenter(), popups: queue)
        addTeardownBlock { module.stop() }
        module.start()
        XCTAssertNil(queue.current, "déjà imminent au lancement : visible dans les oreilles, pas annoncé")
        module.wake()
        XCTAssertNil(queue.current, "relu : toujours pas")
        clock.advance(120 + 31 * 60)
        module.wake()
        XCTAssertNil(queue.current, "le premier est fini, le second est dans 5 min ou plus")
        calendar.all = [meeting("plus-tard", in: 1_200 + 0)]
        clock.now = t0.addingTimeInterval(1_200 - 240)
        module.wake()
        XCTAssertEqual(queue.current?.title, "Point plus-tard")
        XCTAssertEqual(queue.current?.text, "Dans 4 min")
    }

    // MARK: - Géométrie

    func testPopupRectSitsUnderTheNotchBand() {
        let notch = CGRect(x: 600, y: 868, width: 200, height: 32)
        let rect = PopupLayout.rect(notch: notch, band: 32)
        XCTAssertEqual(rect.midX, notch.midX)
        XCTAssertEqual(rect.maxY, notch.maxY - 32 - PopupLayout.gap, "juste sous la bande")
        XCTAssertEqual(PopupLayout.rect(notch: notch, band: 20).maxY, notch.maxY - 20 - PopupLayout.gap, "perle : bande plus basse")
    }

    func testVisibilityRuleShowsTheNotchWhileAPopupIsUp() {
        var inputs = NotchVisibilityRule.Inputs()
        XCTAssertFalse(NotchVisibilityRule.shouldShow(.duringActivity, inputs))
        inputs.popup = true
        XCTAssertTrue(NotchVisibilityRule.shouldShow(.duringActivity, inputs))
        XCTAssertTrue(NotchVisibilityRule.shouldShow(.whenClaudeOpen, inputs))
        inputs.hiddenForFullScreen = true
        XCTAssertFalse(NotchVisibilityRule.shouldShow(.always, inputs), "plein écran « masquée » prime")
    }
}
