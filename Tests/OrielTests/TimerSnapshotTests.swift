import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendu PNG hors écran, commun aux onglets Minuteur et Notes (même méthode que SnapshotTests).
enum TimerNotesSnapshot {
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["ORIEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func render<V: View>(_ view: V, _ name: String, _ dir: URL, size: CGSize = NotchController.panelSize,
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

    /// Notch complète dont l'onglet `tab` est remplacé par `module`.
    static func scene(_ test: XCTestCase, replacing module: any NotchModule, expanded: Bool = true,
                      fullScreen: Bool = false, store: SessionStore = SessionStore()) -> (NotchHarness, ModuleRegistry) {
        let notch = NotchHarness(test, store: store)
        let modules = ModuleRegistry.standardModules(claude: notch.claude).map { $0.id == module.id ? module : $0 }
        let registry = ModuleRegistry(modules: modules, prefs: notch.prefs)
        notch.model.isExpanded = expanded
        notch.model.isFullScreen = fullScreen
        notch.model.selectedTab = module.id
        return (notch, registry)
    }

    static func root(_ pair: (NotchHarness, ModuleRegistry)) -> NotchRootView {
        NotchRootView(model: pair.0.model, store: pair.0.store, registry: pair.1, prefs: pair.0.prefs,
                      actions: NotchActions())
    }

    static func settings(_ pair: (NotchHarness, ModuleRegistry), _ id: String) -> SettingsView {
        SettingsView(prefs: pair.0.prefs, registry: pair.1, updater: Updater(), selection: .module(id))
    }
}

extension TimerRig {
    /// Écrit un état dans `timer.json` : le module le lit au démarrage (cycle, sessions du jour, phases…).
    func preload(_ state: TimerState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TimerModule.FileContent(state: state)).write(to: fileURL)
    }
}

/// Rendus PNG de l'onglet Minuteur (états simple et Pomodoro, mode compact, oreilles, réglages) et mise en page.
/// Ne fait rien sans `ORIEL_SNAPSHOT_DIR`, sauf les mesures.
final class TimerSnapshotTests: XCTestCase {
    private func module(_ rig: TimerRig, _ prepare: (TimerModule) -> Void = { _ in }) -> TimerModule {
        let module = rig.startedModule()
        prepare(module)
        return module
    }

    private func state(_ rig: TimerRig, _ change: (inout TimerState) -> Void) throws {
        var state = TimerState()
        change(&state)
        try rig.preload(state)
    }

    func testRenderTimer() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let scene = { (module: TimerModule, expanded: Bool, fullScreen: Bool, store: SessionStore) in
            TimerNotesSnapshot.scene(self, replacing: module, expanded: expanded, fullScreen: fullScreen, store: store)
        }
        func show(_ rig: TimerRig, _ name: String, expanded: Bool = true, fullScreen: Bool = false,
                  store: SessionStore = SessionStore(), prepare: (TimerModule) -> Void = { _ in }) throws {
            let timer = self.module(rig, prepare)
            addTeardownBlock { timer.stop() }
            let pair = scene(timer, expanded, fullScreen, store)
            if !expanded { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            try TimerNotesSnapshot.render(TimerNotesSnapshot.root(pair), name, dir)
        }

        // Minuteur simple : au repos (préréglage 10 min), en cours, en pause, terminé.
        try show(try TimerRig(self), "timer-simple-idle")
        let running = try TimerRig(self)
        try show(running, "timer-simple-running") { timer in
            timer.startSimple(minutes: 10)
            running.clock.advance(328)
            timer.tick()
        }
        let paused = try TimerRig(self)
        try show(paused, "timer-simple-paused") { timer in
            timer.startSimple(minutes: 25)
            paused.clock.advance(600)
            timer.pause()
        }
        let finished = try TimerRig(self)
        try show(finished, "timer-simple-finished") { timer in
            timer.startSimple(minutes: 5)
            finished.clock.advance(300)
            timer.tick()
            timer.panelOpened()
        }
        let long = try TimerRig(self)
        try show(long, "timer-simple-hour") { timer in
            timer.setSimpleMinutes(90)
            timer.startTimer()
            long.clock.advance(1500)
            timer.tick()
        }

        // Pomodoro : au repos, concentration (série à 2/4, 5 sessions aujourd'hui), pause courte, pause longue, fin.
        let pomodoroIdle = try TimerRig(self)
        try show(pomodoroIdle, "timer-pomodoro-idle") { $0.setMode(.pomodoro) }

        let focus = try TimerRig(self)
        try state(focus) {
            $0.mode = .pomodoro
            $0.status = .running
            $0.phase = .focus
            $0.duration = 25 * 60
            $0.endDate = focus.clock.now.addingTimeInterval(18 * 60 + 12)
            $0.cycle = 2
            $0.sessionsToday = 5
            $0.sessionsDay = focus.calendar.startOfDay(for: focus.clock.now)
        }
        try show(focus, "timer-pomodoro-focus")

        let shortBreak = try TimerRig(self)
        try state(shortBreak) {
            $0.mode = .pomodoro
            $0.status = .running
            $0.phase = .shortBreak
            $0.duration = 5 * 60
            $0.endDate = shortBreak.clock.now.addingTimeInterval(3 * 60 + 41)
            $0.cycle = 3
            $0.sessionsToday = 3
            $0.sessionsDay = shortBreak.calendar.startOfDay(for: shortBreak.clock.now)
        }
        try show(shortBreak, "timer-pomodoro-break")

        let longBreak = try TimerRig(self)
        try state(longBreak) {
            $0.mode = .pomodoro
            $0.status = .paused
            $0.phase = .longBreak
            $0.duration = 15 * 60
            $0.remaining = 11 * 60 + 5
            $0.cycle = 4
            $0.sessionsToday = 4
            $0.sessionsDay = longBreak.calendar.startOfDay(for: longBreak.clock.now)
        }
        try show(longBreak, "timer-pomodoro-longbreak-paused")

        let pomodoroDone = try TimerRig(self)
        try state(pomodoroDone) {
            $0.mode = .pomodoro
            $0.status = .finished
            $0.phase = .shortBreak
            $0.duration = 5 * 60
            $0.remaining = 5 * 60
            $0.finishedAt = pomodoroDone.clock.now.addingTimeInterval(-90)
            $0.cycle = 1
            $0.sessionsToday = 1
            $0.sessionsDay = pomodoroDone.calendar.startOfDay(for: pomodoroDone.clock.now)
        }
        try show(pomodoroDone, "timer-pomodoro-finished")

        // Largeurs du panneau.
        for size in [PanelSize.compact, .large] {
            let rig = try TimerRig(self)
            let timer = self.module(rig) { $0.startSimple(minutes: 10) }
            addTeardownBlock { timer.stop() }
            let pair = scene(timer, true, false, SessionStore())
            pair.0.prefs.panelSize = size
            try TimerNotesSnapshot.render(TimerNotesSnapshot.root(pair), "timer-simple-running-\(size.rawValue)", dir)
        }

        // Plein écran compact : sessions Claude puis le résumé du minuteur.
        let compact = try TimerRig(self)
        try show(compact, "timer-fullscreen-compact", fullScreen: true, store: .working(2)) { timer in
            timer.setMode(.pomodoro)
            timer.startTimer()
            compact.clock.advance(7 * 60 + 13)
            timer.tick()
        }

        // Notch repliée : le registre démarre le module tout seul.
        let ears = try TimerRig(self)
        try show(ears, "timer-collapsed-ears", expanded: false) { timer in
            timer.startSimple(minutes: 25)
            ears.clock.advance(1)
            timer.tick()
        }
        let hour = try TimerRig(self)
        try show(hour, "timer-collapsed-ears-hour", expanded: false) { timer in
            timer.setSimpleMinutes(90)
            timer.startTimer()
            hour.clock.advance(1500)
            timer.tick()
        }
        let earsPaused = try TimerRig(self)
        try show(earsPaused, "timer-collapsed-ears-paused", expanded: false) { timer in
            timer.setMode(.pomodoro)
            timer.startTimer()
            earsPaused.clock.advance(5 * 60 + 1)
            timer.pause()
        }
        let earsDone = try TimerRig(self)
        try show(earsDone, "timer-collapsed-ears-done", expanded: false) { timer in
            timer.startSimple(minutes: 1)
            earsDone.clock.advance(60)
            timer.tick()
        }

        // Réglages › Minuteur.
        let rig = try TimerRig(self)
        let timer = module(rig)
        addTeardownBlock { timer.stop() }
        let pair = scene(timer, true, false, SessionStore())
        try TimerNotesSnapshot.render(TimerNotesSnapshot.settings(pair, "timer"), "settings-timer", dir,
                                      size: SettingsWindow.size, background: nil)
        rig.notifier.accessValue = .denied
        timer.refreshNotificationAccess()
        try TimerNotesSnapshot.render(TimerNotesSnapshot.settings(pair, "timer"), "settings-timer-denied", dir,
                                      size: SettingsWindow.size, background: nil)
    }

    // MARK: Mise en page

    /// Le panneau ne dépasse jamais sa fenêtre, dans tous les états et à toutes les largeurs.
    func testTimerPanelStaysUnderTheMaximumHeight() throws {
        for size in PanelSize.allCases {
            for status in [TimerState.Status.idle, .running, .paused, .finished] {
                for mode in [TimerMode.simple, .pomodoro] {
                    let rig = try TimerRig(self)
                    try state(rig) {
                        $0.mode = mode
                        $0.status = status
                        $0.phase = .shortBreak
                        $0.endDate = status == .running ? rig.clock.now.addingTimeInterval(4000) : nil
                        $0.finishedAt = status == .finished ? rig.clock.now : nil
                        $0.duration = 4000
                        $0.remaining = 4000
                        $0.sessionsToday = 8
                        $0.sessionsDay = rig.calendar.startOfDay(for: rig.clock.now)
                    }
                    let timer = module(rig)
                    addTeardownBlock { timer.stop() }
                    let pair = TimerNotesSnapshot.scene(self, replacing: timer)
                    pair.0.prefs.panelSize = size
                    let height = measure(TimerNotesSnapshot.root(pair), pair.0)
                    XCTAssertLessThanOrEqual(height, ExpandedPanel.maxPanelHeight, "\(size) \(status) \(mode)")
                    XCTAssertGreaterThan(height, 100)
                }
            }
        }
    }

    private func measure(_ root: NotchRootView, _ harness: NotchHarness) -> CGFloat {
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: NotchController.panelSize)
        let window = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        window.close()
        return harness.model.contentSize.height
    }
}
