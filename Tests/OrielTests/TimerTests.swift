import AppKit
import SwiftUI
import XCTest
@testable import Oriel

// MARK: - Doubles (partagés avec NotesTests)

/// Horloge à la main.
final class FakeClock {
    var now: Date
    /// 2027-01-15 08:00:00 UTC, seconde entière : le JSON ne garde pas les fractions.
    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    var read: () -> Date { { [self] in now } }
}

/// Planificateur à la main : les tâches attendent qu'un test les déclenche.
final class ManualScheduler {
    final class Task {
        let delay: TimeInterval
        let work: () -> Void
        var cancelled = false
        var fired = false
        init(delay: TimeInterval, work: @escaping () -> Void) {
            self.delay = delay
            self.work = work
        }
    }

    private(set) var tasks: [Task] = []

    var scheduler: ModuleScheduler {
        ModuleScheduler { [self] delay, work in
            let task = Task(delay: delay, work: work)
            tasks.append(task)
            return { task.cancelled = true }
        }
    }

    /// Tâches ni annulées ni déclenchées.
    var pending: [Task] { tasks.filter { !$0.cancelled && !$0.fired } }

    func fire(_ task: Task) {
        guard !task.cancelled, !task.fired else { return }
        task.fired = true
        task.work()
    }

    /// Déclenche les tâches en attente dont le délai est `delay`.
    func fire(delay: TimeInterval) {
        pending.filter { $0.delay == delay }.forEach(fire)
    }
}

final class FakeNotifier: TimerNotifier {
    var accessValue: NotificationAccess = .notDetermined
    var grantsRequest = true
    private(set) var accessCalls = 0
    private(set) var requestCalls = 0
    private(set) var scheduled: [String: (title: String, body: String, date: Date)] = [:]
    private(set) var scheduleLog: [String] = []
    private(set) var cancelled: [String] = []

    func access(_ completion: @escaping (NotificationAccess) -> Void) {
        accessCalls += 1
        completion(accessValue)
    }

    func request(_ completion: @escaping (Bool) -> Void) {
        requestCalls += 1
        accessValue = grantsRequest ? .granted : .denied
        completion(grantsRequest)
    }

    func schedule(id: String, title: String, body: String, at date: Date) {
        scheduled[id] = (title, body, date)
        scheduleLog.append(id)
    }

    func cancel(id: String) {
        scheduled[id] = nil
        cancelled.append(id)
    }
}

/// Un minuteur sur doubles : horloge, planificateurs, notifications, sons, dossier et réglages jetables.
final class TimerRig {
    let clock = FakeClock()
    let ticks = ManualScheduler()
    let writes = ManualScheduler()
    let notifier = FakeNotifier()
    let center = NotificationCenter()
    let directory: URL
    let defaults: UserDefaults
    private(set) var sounds: [String] = []
    func recordSound(_ name: String) { sounds.append(name) }
    func track(_ module: TimerModule) { modules.append(module) }
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var modules: [TimerModule] = []

    init(_ test: XCTestCase) throws {
        directory = try makeTemporaryDirectory(test)
        defaults = makeEphemeralDefaults(test)
        // Enregistré après la suppression du dossier, donc exécuté avant : une écriture lancée en fin de test ne
        // recrée pas le dossier supprimé.
        test.addTeardownBlock { [self] in modules.forEach { $0.saveNow() } }
    }

    var fileURL: URL { directory.appendingPathComponent("timer.json") }

    func makeModule() -> TimerModule {
        let module = TimerModule(defaults: defaults, directory: directory, clock: clock.read,
                                 scheduler: ticks.scheduler, notifier: notifier,
                                 playSound: { [self] in sounds.append($0) }, calendar: calendar, center: center,
                                 fileScheduler: writes.scheduler)
        modules.append(module)
        return module
    }

    /// Module démarré, comme par le registre.
    func startedModule() -> TimerModule {
        let module = makeModule()
        module.start()
        return module
    }
}

// MARK: - Tests

final class TimerTests: XCTestCase {
    private func ended(_ module: TimerModule, _ rig: TimerRig) {
        guard let end = module.state.endDate else { return XCTFail("rien ne tourne") }
        rig.clock.now = end
        module.tick()
    }

    // MARK: Minuteur simple

    func testSimpleTimerStartsPausesResumesAndAddsAMinute() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
        XCTAssertNil(module.ears)

        module.startSimple(minutes: 5)
        XCTAssertEqual(module.state.status, .running)
        XCTAssertTrue(module.keepsRunningWhenCollapsed)
        XCTAssertEqual(module.ears, ModuleEars(symbol: "timer", text: "5:00", priority: 5))

        rig.clock.advance(10)
        module.tick()
        XCTAssertEqual(module.ears?.text, "4:50")

        module.pause()
        XCTAssertEqual(module.ears, ModuleEars(symbol: "pause.fill", text: "4:50", priority: 5))
        XCTAssertTrue(module.keepsRunningWhenCollapsed, "en pause, les oreilles restent")
        rig.clock.advance(3600)
        XCTAssertEqual(module.ears?.text, "4:50", "le temps est figé")
        XCTAssertTrue(rig.ticks.pending.isEmpty, "aucun rendez-vous en pause")

        module.resume()
        XCTAssertEqual(module.state.endDate, rig.clock.now.addingTimeInterval(290))
        module.addMinute()
        XCTAssertEqual(module.ears?.text, "5:50")
        XCTAssertEqual(module.state.duration, 360)

        module.stopTimer()
        XCTAssertEqual(module.state.status, .idle)
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
        XCTAssertNil(module.ears)
        XCTAssertEqual(module.state.remaining, 300, "la durée choisie est gardée")
    }

    func testFinishPlaysTheSoundOnceAndKeepsTheEarsUntilThePanelOpens() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 1)
        ended(module, rig)

        XCTAssertEqual(module.state.status, .finished)
        XCTAssertEqual(rig.sounds, ["Glass"])
        XCTAssertEqual(module.ears, ModuleEars(symbol: "checkmark.circle.fill", text: "Terminé", priority: 5))
        XCTAssertTrue(module.keepsRunningWhenCollapsed)
        XCTAssertTrue(rig.ticks.pending.contains { $0.delay == TimerModule.finishedEarsDuration })
        XCTAssertFalse(rig.ticks.pending.contains { $0.delay < 2 }, "plus de décompte")

        module.panelOpened()
        XCTAssertNil(module.ears)
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
        XCTAssertEqual(module.state.status, .finished, "l'onglet montre encore « terminé »")
    }

    func testNoFinishedEarsWhenThePanelIsOpenAtTheEnd() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 1)
        module.viewAppeared()
        ended(module, rig)
        XCTAssertEqual(rig.sounds, ["Glass"], "le son est joué quand même")
        XCTAssertNil(module.ears, "le résultat est déjà à l'écran")
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
        module.viewDisappeared()

        // Panneau fermé : l'oreille s'affiche, puis l'ouverture suivante l'éteint.
        module.startTimer()
        ended(module, rig)
        XCTAssertNotNil(module.ears)
        module.viewAppeared()
        XCTAssertNil(module.ears)
    }

    func testFinishedEarsExpireAfterAMinute() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 1)
        ended(module, rig)
        XCTAssertNotNil(module.ears)
        rig.ticks.fire(delay: TimerModule.finishedEarsDuration)
        XCTAssertNil(module.ears)
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
    }

    func testNoSoundWhenNone() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.soundName = ""
        module.startSimple(minutes: 1)
        ended(module, rig)
        XCTAssertTrue(rig.sounds.isEmpty)
        XCTAssertEqual(module.state.status, .finished)
    }

    func testSoundIsSilentWhenNameIsEmptyOrUnknown() {
        TimerSound.play("")
        TimerSound.play("Pas un son")
    }

    /// Les noms proposés dans les réglages existent sur ce Mac.
    func testEverySystemSoundOfTheSettingsExists() {
        for name in TimerSound.names {
            XCTAssertNotNil(NSSound(named: NSSound.Name(name)), name)
        }
        XCTAssertTrue(TimerSound.names.contains(TimerSound.defaultName))
    }

    /// Le vrai planificateur (GCD) : un minuteur d'une minute sur une horloge accélérée ×30 se termine tout seul,
    /// avec un seul son, et ne laisse aucun rendez-vous derrière lui.
    func testRealSchedulerRunsTheTimerToItsEnd() throws {
        let rig = try TimerRig(self)
        let start = Date()
        let base = rig.clock.now
        let module = TimerModule(defaults: rig.defaults, directory: rig.directory,
                                 clock: { base.addingTimeInterval(Date().timeIntervalSince(start) * 30) },
                                 scheduler: .system, notifier: rig.notifier,
                                 playSound: { [rig] name in rig.recordSound(name) }, calendar: rig.calendar,
                                 center: rig.center, fileScheduler: rig.writes.scheduler)
        rig.track(module)
        module.start()
        addTeardownBlock { module.stop() }
        module.startSimple(minutes: 1)
        let deadline = Date().addingTimeInterval(6)
        while module.state.status == .running, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(module.state.status, .finished)
        XCTAssertEqual(rig.sounds, ["Glass"])
        XCTAssertEqual(module.ears?.text, "Terminé")
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(rig.sounds.count, 1, "un seul son, plus aucun décompte")
    }

    func testSystemSchedulerFiresOnceAndCanBeCancelled() {
        var fired = 0
        _ = ModuleScheduler.system.after(0.05) { fired += 1 }
        let cancel = ModuleScheduler.system.after(0.05) { fired += 10 }
        cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(fired, 1)
    }

    func testRestartFromFinishedRunsTheSameDuration() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 10)
        module.addMinute()
        ended(module, rig)
        module.startTimer()
        XCTAssertEqual(module.state.status, .running)
        XCTAssertEqual(module.state.duration, 600, "le « +1 min » ne se garde pas")
    }

    // MARK: Durée libre

    /// Une durée tapée sans Entrée ni perte de focus est celle de « Démarrer » (le clic ne valide pas le champ).
    func testTypedDurationIsUsedByStartWithoutAnyValidation() throws {
        _ = NSApplication.shared
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        let hosting = NSHostingController(rootView: DurationControl(module: module))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 220, height: 40))
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        hosting.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let field = try XCTUnwrap(Self.findView(NSTextField.self, in: window.contentView))
        XCTAssertEqual(field.stringValue, "10")
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "l'éditeur du champ a le focus")
        editor.insertText("37", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(field.stringValue, "37")

        // Pas d'Entrée, pas de sortie du champ : directement « Démarrer ».
        module.startTimer()
        XCTAssertEqual(module.state.status, .running)
        XCTAssertEqual(module.state.duration, 37 * 60)
    }

    func testTypedDurationIsClampedAndEmptyInputChangesNothing() throws {
        _ = NSApplication.shared
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        let hosting = NSHostingController(rootView: DurationControl(module: module))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 220, height: 40))
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        hosting.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let field = try XCTUnwrap(Self.findView(NSTextField.self, in: window.contentView))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        func type(_ text: String) {
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        type("")
        XCTAssertEqual(module.state.simpleDuration, 600, "champ vidé : la durée ne bouge pas")
        type("9999")
        XCTAssertEqual(module.state.simpleDuration, 1440 * 60, "au plus 24 h")
        type("0")
        XCTAssertEqual(module.state.simpleDuration, 60, "au moins une minute")
        type("12a")
        XCTAssertEqual(module.state.simpleDuration, 12 * 60, "seuls les chiffres comptent")
    }

    private static func findView<V: NSView>(_ type: V.Type, in view: NSView?) -> V? {
        guard let view else { return nil }
        if let found = view as? V { return found }
        for subview in view.subviews {
            if let found = findView(type, in: subview) { return found }
        }
        return nil
    }

    // MARK: Un seul rendez-vous

    func testOnlyOneAlignedTickWhileRunning() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        XCTAssertTrue(rig.ticks.pending.isEmpty, "démarré au repos : aucun rendez-vous")
        module.startSimple(minutes: 5)
        XCTAssertEqual(rig.ticks.pending.count, 1)
        for _ in 0..<5 {
            rig.clock.advance(1)
            module.tick()
            XCTAssertEqual(rig.ticks.pending.count, 1)
            let delay = try XCTUnwrap(rig.ticks.pending.first?.delay)
            XCTAssertTrue((0.05...1.1).contains(delay), "\(delay)")
        }
        module.pause()
        XCTAssertTrue(rig.ticks.pending.isEmpty)
        module.resume()
        XCTAssertEqual(rig.ticks.pending.count, 1)
        module.stop()
        XCTAssertTrue(rig.ticks.pending.isEmpty, "stop() libère le rendez-vous")
    }

    func testTickIsAlignedOnTheDisplayedSecond() throws {
        let rig = try TimerRig(self)
        rig.clock.now = Date(timeIntervalSince1970: 1_800_000_000.4)
        let module = rig.startedModule()
        module.startSimple(minutes: 1)
        rig.clock.advance(0.3)
        module.tick()
        // Reste 59,7 s : l'affichage change dans 0,7 s (plus une marge de 20 ms).
        let delay = try XCTUnwrap(rig.ticks.pending.first?.delay)
        XCTAssertEqual(delay, 0.72, accuracy: 0.011)
    }

    /// Reste 599,03 s après une reprise : l'affichage « 10:00 » doit passer à « 9:59 » dans 0,03 s, pas à « 9:58 ».
    func testResumeWithATinyFractionNeverSkipsADisplayedSecond() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 10)
        rig.clock.advance(0.97)
        module.pause()
        module.resume()
        XCTAssertEqual(TimerFormat.clock(module.state.remaining(at: rig.clock.now)), "10:00")
        let delay = try XCTUnwrap(rig.ticks.pending.first?.delay)
        XCTAssertEqual(delay, 0.05, accuracy: 0.011, "visé sur la frontière, pas une seconde plus loin")
        rig.clock.advance(delay)
        module.tick()
        XCTAssertEqual(TimerFormat.clock(module.state.remaining(at: rig.clock.now)), "9:59")
    }

    func testLastTickFollowsTheEndEvenWithATinyRemainder() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 1)
        rig.clock.advance(59.97)
        module.pause()
        module.resume()
        let delay = try XCTUnwrap(rig.ticks.pending.first?.delay)
        XCTAssertEqual(delay, 0.05, accuracy: 0.011, "la fin n'attend pas une seconde de plus")
        rig.clock.advance(delay)
        module.tick()
        XCTAssertEqual(module.state.status, .finished)
    }

    func testStartedButIdleSchedulesNothingAndStopIsClean() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.stop()
        XCTAssertTrue(rig.ticks.tasks.isEmpty)
        XCTAssertEqual(rig.notifier.accessCalls, 0)
    }

    // MARK: Pomodoro

    func testPomodoroChainsFocusAndBreaksWithALongBreakEveryFourSessions() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.setMode(.pomodoro)
        XCTAssertEqual(module.state.remaining, 25 * 60)
        module.startTimer()
        XCTAssertEqual(module.ears, ModuleEars(symbol: "brain.head.profile", text: "25:00", priority: 5))

        for session in 1...4 {
            XCTAssertEqual(module.state.phase, .focus)
            ended(module, rig)
            XCTAssertEqual(module.state.sessions(on: rig.clock.now, calendar: rig.calendar), session)
            XCTAssertEqual(module.state.cycle, session)
            let longBreak = session == 4
            XCTAssertEqual(module.state.phase, longBreak ? .longBreak : .shortBreak)
            XCTAssertEqual(module.state.status, .running, "la pause démarre seule")
            XCTAssertEqual(module.state.duration, longBreak ? 15 * 60 : 5 * 60)
            XCTAssertEqual(module.ears?.symbol, "cup.and.saucer")
            ended(module, rig)
            XCTAssertEqual(module.state.phase, .focus)
            XCTAssertEqual(module.state.status, .finished, "la concentration attend l'utilisateur")
            XCTAssertEqual(module.state.cycle, longBreak ? 0 : session)
            module.startTimer()
        }
        XCTAssertEqual(rig.sounds.count, 8)
        XCTAssertEqual(module.state.sessions(on: rig.clock.now, calendar: rig.calendar), 4)
    }

    func testBreaksStayManualWhenAutoStartIsOff() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.autoStartBreaks = false
        module.setMode(.pomodoro)
        module.startTimer()
        ended(module, rig)
        XCTAssertEqual(module.state.status, .finished)
        XCTAssertEqual(module.state.phase, .shortBreak)
        XCTAssertEqual(module.restartTitle, "Démarrer la pause")
        module.startTimer()
        XCTAssertEqual(module.state.status, .running)
        XCTAssertEqual(module.state.duration, 5 * 60)
    }

    func testSkipMovesOnWithoutCountingNorSound() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.setMode(.pomodoro)
        module.startTimer()
        module.skip()
        XCTAssertEqual(module.state.phase, .shortBreak)
        XCTAssertEqual(module.state.status, .running, "pause lancée seule")
        XCTAssertEqual(module.state.sessions(on: rig.clock.now, calendar: rig.calendar), 0)
        XCTAssertEqual(module.state.cycle, 0)
        module.skip()
        XCTAssertEqual(module.state.phase, .focus)
        XCTAssertEqual(module.state.status, .idle, "la concentration n'est jamais lancée seule")
        XCTAssertTrue(rig.sounds.isEmpty)
        XCTAssertTrue(rig.ticks.pending.isEmpty)
    }

    func testStoppingABreakGoesBackToFocus() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.sessionsBeforeLongBreak = 2
        module.setMode(.pomodoro)
        module.startTimer()
        ended(module, rig)      // concentration 1 → pause courte lancée
        ended(module, rig)      // pause → concentration prête
        module.startTimer()
        ended(module, rig)      // concentration 2 → pause longue lancée
        XCTAssertEqual(module.state.phase, .longBreak)
        XCTAssertEqual(module.state.cycle, 2)
        module.stopTimer()
        XCTAssertEqual(module.state.phase, .focus)
        XCTAssertEqual(module.state.cycle, 0)
        XCTAssertEqual(module.state.status, .idle)
    }

    func testModeCannotChangeWhileRunning() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 5)
        module.setMode(.pomodoro)
        XCTAssertEqual(module.state.mode, .simple)
        module.pause()
        module.setMode(.pomodoro)
        XCTAssertEqual(module.state.mode, .simple)
    }

    func testSessionCounterRestartsEachDay() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.autoStartBreaks = false
        module.setMode(.pomodoro)
        module.startTimer()
        ended(module, rig)
        XCTAssertEqual(module.state.sessions(on: rig.clock.now, calendar: rig.calendar), 1)
        rig.clock.advance(24 * 3600)
        XCTAssertEqual(module.state.sessions(on: rig.clock.now, calendar: rig.calendar), 0)
        module.skip()
        module.startTimer()
        ended(module, rig)
        XCTAssertEqual(module.state.sessions(on: rig.clock.now, calendar: rig.calendar), 1, "reparti de zéro")
    }

    func testSettingsAreClampedPersistedAndShownWhenIdle() throws {
        let rig = try TimerRig(self)
        rig.defaults.set(9999, forKey: "timer.focusMinutes")
        rig.defaults.set(-4, forKey: "timer.shortBreakMinutes")
        rig.defaults.set(1, forKey: "timer.sessionsBeforeLongBreak")
        let module = rig.makeModule()
        XCTAssertEqual(module.focusMinutes, 180)
        XCTAssertEqual(module.shortBreakMinutes, 1)
        XCTAssertEqual(module.sessionsBeforeLongBreak, 2)
        XCTAssertEqual(module.soundName, "Glass")
        XCTAssertTrue(module.notifyOnEnd)

        module.start()
        module.setMode(.pomodoro)
        module.focusMinutes = 50
        XCTAssertEqual(rig.defaults.integer(forKey: "timer.focusMinutes"), 50)
        XCTAssertEqual(module.state.remaining, 50 * 60, "au repos, la nouvelle durée est proposée")
        module.startTimer()
        module.focusMinutes = 30
        XCTAssertEqual(module.state.duration, 50 * 60, "un décompte en cours ne bouge pas")
    }

    // MARK: Veille, relance, expiration

    func testLateTickAfterSleepIsSilent() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.setMode(.pomodoro)
        module.startTimer()
        rig.clock.advance(3 * 3600)
        module.tick()
        XCTAssertEqual(module.state.status, .finished, "pas de pause lancée au réveil")
        XCTAssertEqual(module.state.phase, .shortBreak)
        XCTAssertTrue(rig.sounds.isEmpty)
        XCTAssertEqual(module.ears?.text, "Terminé")
        XCTAssertEqual(module.state.sessions(on: rig.clock.now, calendar: rig.calendar), 1, "la session compte quand même")
    }

    func testRemainingTimeSurvivesARelaunch() throws {
        let rig = try TimerRig(self)
        let first = rig.startedModule()
        first.startSimple(minutes: 10)
        rig.clock.advance(120)
        first.tick()
        first.stop()

        rig.clock.advance(60)
        let second = rig.makeModule()
        XCTAssertTrue(second.keepsRunningWhenCollapsed, "le registre le relance replié")
        second.start()
        XCTAssertEqual(second.state.status, .running)
        XCTAssertEqual(second.ears?.text, "7:00")
        XCTAssertEqual(rig.ticks.pending.count, 1, "le décompte repart")
    }

    func testPausedTimerSurvivesARelaunchFrozen() throws {
        let rig = try TimerRig(self)
        let first = rig.startedModule()
        first.startSimple(minutes: 10)
        rig.clock.advance(100)
        first.pause()
        first.saveNow()

        rig.clock.advance(6 * 3600)
        let second = rig.makeModule()
        XCTAssertTrue(second.keepsRunningWhenCollapsed)
        second.start()
        XCTAssertEqual(second.ears, ModuleEars(symbol: "pause.fill", text: "8:20", priority: 5))
        second.resume()
        XCTAssertEqual(second.state.endDate, rig.clock.now.addingTimeInterval(500))
    }

    func testTimerExpiredWhileTheAppWasClosedIsReportedWithoutSound() throws {
        let rig = try TimerRig(self)
        let first = rig.startedModule()
        first.startSimple(minutes: 5)
        let end = try XCTUnwrap(first.state.endDate)
        first.stop()

        let requests = rig.notifier.requestCalls
        rig.clock.advance(3600)
        let second = rig.makeModule()
        XCTAssertTrue(second.keepsRunningWhenCollapsed, "l'oreille « Terminé » doit pouvoir s'afficher")
        second.start()
        XCTAssertEqual(second.state.status, .finished)
        XCTAssertEqual(second.state.finishedAt, end)
        XCTAssertEqual(second.ears?.text, "Terminé")
        XCTAssertTrue(rig.sounds.isEmpty)
        XCTAssertEqual(rig.notifier.requestCalls, requests, "aucune demande de permission à la relance")
        XCTAssertTrue(rig.notifier.scheduled.isEmpty)
        XCTAssertEqual(second.caption, "Terminé")
        rig.ticks.fire(delay: TimerModule.finishedEarsDuration)
        XCTAssertFalse(second.keepsRunningWhenCollapsed)

        // Et l'état « terminé » est retenu pour la prochaine relance, sans oreille.
        second.stop()
        let third = rig.makeModule()
        XCTAssertFalse(third.keepsRunningWhenCollapsed)
        third.start()
        XCTAssertEqual(third.state.status, .finished)
        XCTAssertEqual(third.state.finishedAt, end)
    }

    func testPomodoroExpiredWhileClosedStartsNothingAndCountsTheSession() throws {
        let rig = try TimerRig(self)
        let first = rig.startedModule()
        first.setMode(.pomodoro)
        first.startTimer()
        first.stop()
        rig.clock.advance(2 * 3600)
        let second = rig.makeModule()
        second.start()
        XCTAssertEqual(second.state.status, .finished)
        XCTAssertEqual(second.state.phase, .shortBreak)
        XCTAssertEqual(second.state.sessions(on: rig.clock.now, calendar: rig.calendar), 1)
    }

    // MARK: Fichier

    func testStateFileIsPrivateAndWrittenAtomically() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.fileURL.path), "écriture débouncée")
        rig.writes.fire(delay: 0.3)
        module.saveNow()
        let attributes = try FileManager.default.attributesOfItem(atPath: rig.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: rig.directory.path)
        XCTAssertEqual(names, ["timer.json"], "pas de fichier temporaire oublié")
        let data = try Data(contentsOf: rig.fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let content = try decoder.decode(TimerModule.FileContent.self, from: data)
        XCTAssertEqual(content.state.status, .running)
        XCTAssertEqual(content.state.endDate, rig.clock.now.addingTimeInterval(300))
    }

    func testWritesAreDebouncedIntoOne() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 5)
        module.pause()
        module.resume()
        XCTAssertEqual(rig.writes.pending.count, 1, "un seul délai armé")
        rig.writes.fire(delay: 0.3)
        module.saveNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.fileURL.path))
    }

    func testNothingIsWrittenOnTickOrOnIdleCollapse() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.fileURL.path))
        module.start()
        module.startSimple(minutes: 5)
        module.saveNow()
        let before = try Data(contentsOf: rig.fileURL)
        rig.clock.advance(5)
        module.tick()
        XCTAssertTrue(rig.writes.pending.isEmpty, "un tick n'écrit rien")
        module.saveNow()
        XCTAssertEqual(try Data(contentsOf: rig.fileURL), before)
    }

    func testCorruptStateFileIsSetAsideAndTheTimerStartsFromScratch() throws {
        let rig = try TimerRig(self)
        try Data("{ pas du json".utf8).write(to: rig.fileURL)
        let module = rig.makeModule()
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
        module.start()
        XCTAssertEqual(module.state.status, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.fileURL.path))
        let aside = rig.fileURL.appendingPathExtension("corrupt")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ pas du json", "l'ancien fichier est gardé")

        module.startSimple(minutes: 5)
        module.saveNow()
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ pas du json")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(contentsOf: rig.fileURL)))

        // Un second fichier illisible ne remplace pas le premier .corrupt.
        try Data("encore".utf8).write(to: rig.fileURL)
        _ = rig.makeModule().keepsRunningWhenCollapsed
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ pas du json")
        XCTAssertEqual(try String(contentsOf: rig.fileURL.appendingPathExtension("corrupt-1"), encoding: .utf8), "encore")
    }

    /// Le fichier existe mais ne se lit pas (droits) : mis de côté, jamais écrasé comme s'il était absent.
    func testExistingButUnreadableStateFileIsSetAsideNotOverwritten() throws {
        let rig = try TimerRig(self)
        try Data("{ \"version\": 1 }".utf8).write(to: rig.fileURL)
        let aside = rig.fileURL.appendingPathExtension("corrupt")
        XCTAssertEqual(chmod(rig.fileURL.path, 0o000), 0)
        addTeardownBlock { chmod(aside.path, 0o600) }
        let module = rig.makeModule()
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
        module.startSimple(minutes: 5)
        module.saveNow()
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(contentsOf: rig.fileURL)))
        chmod(aside.path, 0o600)
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ \"version\": 1 }")
    }

    func testNothingIsReadWhileTheModuleIsNotUsed() throws {
        let rig = try TimerRig(self)
        try Data("illisible".utf8).write(to: rig.fileURL)
        _ = rig.makeModule()
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.fileURL.path), "ni lu ni déplacé avant le premier accès")
    }

    func testAbsurdValuesInTheFileAreSanitized() throws {
        let rig = try TimerRig(self)
        let json = """
        {"version":1,"state":{"mode":"pomodoro","status":"running","phase":"focus","duration":-5,
        "remaining":1e99,"simpleDuration":0,"cycle":-3,"sessionsToday":-1}}
        """
        try Data(json.utf8).write(to: rig.fileURL)
        let module = rig.makeModule()
        module.start()
        XCTAssertEqual(module.state.status, .idle, "en cours sans date de fin = au repos")
        XCTAssertEqual(module.state.remaining, 25 * 60)
        XCTAssertEqual(module.state.simpleDuration, 600)
        XCTAssertEqual(module.state.cycle, 0)
    }

    func testFileIsWrittenWhenTheAppTerminates() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.fileURL.path), "l'écriture est encore débouncée")
        rig.center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.fileURL.path))

        // Module arrêté : plus d'observateur.
        module.stop()
        try FileManager.default.removeItem(at: rig.fileURL)
        rig.center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.fileURL.path))
    }

    // MARK: Notifications

    func testNotificationPermissionIsAskedOnTheFirstTimerOnly() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        XCTAssertEqual(rig.notifier.accessCalls, 0)
        XCTAssertEqual(rig.notifier.requestCalls, 0, "rien au lancement ni à l'ouverture")

        module.startSimple(minutes: 5)
        XCTAssertEqual(rig.notifier.requestCalls, 1)
        XCTAssertEqual(rig.notifier.scheduled.count, 1)
        let (id, request) = try XCTUnwrap(rig.notifier.scheduled.first)
        XCTAssertEqual(request.date, rig.clock.now.addingTimeInterval(300))
        XCTAssertEqual(request.title, "Minuteur terminé")
        XCTAssertTrue(id.hasPrefix("oriel.timer."))
        XCTAssertEqual(module.notificationAccess, .granted)

        module.stopTimer()
        module.startSimple(minutes: 5)
        XCTAssertEqual(rig.notifier.requestCalls, 1, "la demande n'est faite qu'une fois")
    }

    func testNotificationFollowsPauseResumeAndExtension() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 5)
        XCTAssertEqual(rig.notifier.scheduled.count, 1)
        module.pause()
        XCTAssertTrue(rig.notifier.scheduled.isEmpty, "en pause, plus rien de programmé")
        rig.clock.advance(30)
        module.resume()
        XCTAssertEqual(rig.notifier.scheduled.values.first?.date, rig.clock.now.addingTimeInterval(300))
        module.addMinute()
        XCTAssertEqual(rig.notifier.scheduled.count, 1, "l'ancienne est remplacée")
        XCTAssertEqual(rig.notifier.scheduled.values.first?.date, rig.clock.now.addingTimeInterval(360))
        module.stopTimer()
        XCTAssertTrue(rig.notifier.scheduled.isEmpty)
    }

    func testNaturalEndLeavesTheSystemNotificationAlone() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 1)
        let id = try XCTUnwrap(rig.notifier.scheduled.keys.first)
        ended(module, rig)
        XCTAssertFalse(rig.notifier.cancelled.contains(id), "le système la remet, ne pas la retirer")
        XCTAssertNotNil(rig.notifier.scheduled[id])
    }

    func testPomodoroAutoStartSchedulesTheBreakNotification() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.setMode(.pomodoro)
        module.startTimer()
        XCTAssertEqual(rig.notifier.scheduled.values.first?.title, "Concentration terminée")
        ended(module, rig)
        XCTAssertEqual(rig.notifier.scheduled.count, 2, "la fin de la concentration part seule, celle de la pause s'ajoute")
        XCTAssertTrue(rig.notifier.scheduled.values.contains { $0.title == "Pause terminée" })
    }

    func testDeniedNotificationsStillGiveSoundAndEars() throws {
        let rig = try TimerRig(self)
        rig.notifier.accessValue = .denied
        let module = rig.startedModule()
        module.startSimple(minutes: 1)
        XCTAssertTrue(rig.notifier.scheduled.isEmpty)
        XCTAssertEqual(rig.notifier.requestCalls, 0)
        XCTAssertEqual(module.notificationAccess, .denied)
        ended(module, rig)
        XCTAssertEqual(rig.sounds, ["Glass"])
        XCTAssertEqual(module.ears?.text, "Terminé")
    }

    func testRefusedPermissionPromptIsRemembered() throws {
        let rig = try TimerRig(self)
        rig.notifier.grantsRequest = false
        let module = rig.startedModule()
        module.startSimple(minutes: 1)
        XCTAssertEqual(module.notificationAccess, .denied)
        XCTAssertTrue(rig.notifier.scheduled.isEmpty)
    }

    func testNotificationSettingOffSchedulesNothingAndCancelsPending() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 5)
        XCTAssertEqual(rig.notifier.scheduled.count, 1)
        module.notifyOnEnd = false
        XCTAssertTrue(rig.notifier.scheduled.isEmpty)
        module.pause()
        module.resume()
        XCTAssertTrue(rig.notifier.scheduled.isEmpty)
    }

    func testDisablingTheModuleCancelsTheNotification() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 5)
        module.stop()
        XCTAssertTrue(rig.notifier.scheduled.isEmpty)
    }

    func testRelaunchedRunningTimerReschedulesItsNotification() throws {
        let rig = try TimerRig(self)
        let first = rig.startedModule()
        first.startSimple(minutes: 10)
        let end = try XCTUnwrap(first.state.endDate)
        first.stop()
        XCTAssertTrue(rig.notifier.scheduled.isEmpty)
        rig.clock.advance(60)
        let second = rig.makeModule()
        second.start()
        XCTAssertEqual(rig.notifier.scheduled.values.first?.date, end)
    }

    // MARK: Contrat

    func testCompactSummaryOnlyWhenSomethingIsGoingOn() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        XCTAssertNil(module.makeCompactView())
        module.startSimple(minutes: 5)
        XCTAssertNotNil(module.makeCompactView())
        XCTAssertNotNil(module.makeSettingsView())
        XCTAssertNotNil(module.makeTabIcon())
        XCTAssertEqual(module.id, "timer")
        XCTAssertEqual(TimerModule.earsPriority, 5)
        XCTAssertGreaterThan(TimerModule.earsPriority, 1, "au-dessus du Lecteur")
        XCTAssertGreaterThan(TimerModule.earsPriority, QuickSettingsModule.earsPriority, "et de la caféine")
    }

    func testRegistryPicksTheTimerEarsOverThePlayer() {
        let timer = ModuleEars(symbol: "timer", text: "4:59", priority: TimerModule.earsPriority)
        let player = ModuleEars(symbol: "music.note", text: "", priority: 1, bars: true)
        let caffeine = ModuleEars(symbol: "cup.and.saucer.fill", text: "10 min", priority: QuickSettingsModule.earsPriority)
        XCTAssertEqual(ModuleRegistry.pickEars([player, caffeine, timer]), timer)
    }

    // MARK: Moteur et formats

    func testClockFormat() {
        XCTAssertEqual(TimerFormat.clock(1499), "24:59")
        XCTAssertEqual(TimerFormat.clock(3900), "1:05:00")
        XCTAssertEqual(TimerFormat.clock(3599.2), "1:00:00", "arrondi au-dessus")
        XCTAssertEqual(TimerFormat.clock(299.4), "5:00")
        XCTAssertEqual(TimerFormat.clock(59), "0:59")
        XCTAssertEqual(TimerFormat.clock(0.2), "0:01")
        XCTAssertEqual(TimerFormat.clock(0), "0:00")
        XCTAssertEqual(TimerFormat.clock(-5), "0:00")
        XCTAssertEqual(TimerFormat.clock(.infinity), "0:00")
        XCTAssertEqual(TimerFormat.duration(25 * 60), "25 min")
        XCTAssertEqual(TimerFormat.duration(2 * 3600), "2 h")
        XCTAssertEqual(TimerFormat.duration(90 * 60), "1 h 30")
    }

    func testEngineKeepsEveryRunningStateConsistent() {
        var state = TimerState()
        let config = PomodoroConfig()
        let t0 = Date(timeIntervalSince1970: 1_000)
        state.setSimpleDuration(5)
        XCTAssertEqual(state.simpleDuration, 60, "au moins une minute")
        state.setSimpleDuration(10 * 24 * 3600)
        XCTAssertEqual(state.simpleDuration, 24 * 3600, "au plus 24 h")
        state.setSimpleDuration(120)
        state.start(now: t0, config: config)
        XCTAssertEqual(state.remaining(at: t0.addingTimeInterval(30)), 90)
        XCTAssertEqual(state.progress(at: t0.addingTimeInterval(30)), 0.25, accuracy: 0.0001)
        state.pause(now: t0.addingTimeInterval(30))
        state.pause(now: t0.addingTimeInterval(60))
        XCTAssertEqual(state.remaining, 90, "une seconde pause ne change rien")
        state.start(now: t0, config: config)
        XCTAssertEqual(state.status, .paused, "start() ne reprend pas une pause")
        XCTAssertNil(state.advance(now: t0.addingTimeInterval(9999), config: config, calendar: .current))
        state.stop(config: config)
        XCTAssertEqual(state.status, .idle)
        state.addMinute()
        XCTAssertEqual(state.duration, 120, "+1 min ne s'applique qu'à un décompte")
    }
}
