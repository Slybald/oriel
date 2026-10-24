import AppKit
import SwiftUI

/// Onglet « Minuteur » : minuteur simple et Pomodoro. Textes dans Resources/{en,fr}.lproj/Timer.strings ;
/// réglages dans UserDefaults sous « timer.… » ; état dans `timer.json` (voir `TimerFile`).
///
/// - Le temps restant vient d'une date de fin (`TimerState.endDate`) : veille et redémarrage de l'app ne le
///   dérangent pas. Un minuteur échu pendant que l'app était fermée est signalé « terminé à HH:mm », sans son.
/// - Un seul rendez-vous à la fois, alignée sur le changement d'affichage (au plus 1 par seconde), et seulement
///   quand un minuteur tourne ; en pause ou arrêté, aucun. Le module tourne notch repliée tant qu'un minuteur
///   tourne ou est en pause (ses oreilles), ou pendant l'oreille « Terminé » (1 min, ou jusqu'à l'ouverture de la
///   notch : `panelOpened`).
/// - Le fichier n'est lu qu'au premier accès (`keepsRunningWhenCollapsed` ou `start`), donc jamais si le module
///   est désactivé. La notification de fin est programmée au départ (autorisation demandée à ce moment-là) pour
///   que le système la remette même si l'app dort.
final class TimerModule: NotchModule {
    let id = "timer"
    let symbol = "timer"
    var title: String { L("Minuteur", table: "Timer") }

    /// Au-dessus du Lecteur (1) ; Claude passe devant (règle des oreilles).
    static let earsPriority = 5
    /// Durée de l'oreille « Terminé » si la notch reste fermée.
    static let finishedEarsDuration: TimeInterval = 60

    struct FileContent: Codable {
        var version = 1
        var state: TimerState
    }

    // MARK: État

    @Published private(set) var state = TimerState()
    /// Heure du dernier tick ou de la dernière action : tout l'affichage se calcule dessus.
    @Published private(set) var now: Date
    /// Fin de l'oreille « Terminé » ; nil = pas d'oreille.
    @Published private(set) var finishedEarsUntil: Date?
    @Published private(set) var notificationAccess: NotificationAccess = .notDetermined

    // MARK: Réglages

    @Published var focusMinutes: Int { didSet { setting(Key.focus, focusMinutes) } }
    @Published var shortBreakMinutes: Int { didSet { setting(Key.shortBreak, shortBreakMinutes) } }
    @Published var longBreakMinutes: Int { didSet { setting(Key.longBreak, longBreakMinutes) } }
    @Published var sessionsBeforeLongBreak: Int { didSet { setting(Key.sessions, sessionsBeforeLongBreak) } }
    @Published var autoStartBreaks: Bool { didSet { setting(Key.autoStart, autoStartBreaks) } }
    /// Nom d'un son système ; vide = aucun.
    @Published var soundName: String { didSet { setting(Key.sound, soundName) } }
    @Published var notifyOnEnd: Bool {
        didSet {
            setting(Key.notify, notifyOnEnd)
            syncNotification()
        }
    }

    static let focusRange = 1...180
    static let shortBreakRange = 1...60
    static let longBreakRange = 1...120
    static let sessionsRange = 2...8

    private enum Key {
        static let focus = "timer.focusMinutes"
        static let shortBreak = "timer.shortBreakMinutes"
        static let longBreak = "timer.longBreakMinutes"
        static let sessions = "timer.sessionsBeforeLongBreak"
        static let autoStart = "timer.autoStartBreaks"
        static let sound = "timer.sound"
        static let notify = "timer.notify"
    }

    private let defaults: UserDefaults
    private let file: SecureJSONFile<FileContent>
    private let clock: () -> Date
    private let scheduler: ModuleScheduler
    private let notifier: TimerNotifier
    private let playSound: (String) -> Void
    let calendar: Calendar
    private let center: NotificationCenter

    private var loaded = false
    private var isStarted = false
    /// Vues du minuteur à l'écran (icône d'onglet, résumé compact) : le panneau est ouvert.
    private var openViews = 0
    private var cancelTick: (() -> Void)?
    private var cancelFinishedEars: (() -> Void)?
    private var terminateObserver: NSObjectProtocol?
    /// Notification de fin programmée pour le décompte en cours.
    private var scheduledNotification: String?

    init(defaults: UserDefaults = .standard, directory: URL = ModuleDataDirectory.standard,
         clock: @escaping () -> Date = Date.init, scheduler: ModuleScheduler = .system,
         notifier: TimerNotifier = SystemTimerNotifier(), playSound: @escaping (String) -> Void = TimerSound.play,
         calendar: Calendar = .current, center: NotificationCenter = .default,
         fileScheduler: ModuleScheduler? = nil) {
        self.defaults = defaults
        self.clock = clock
        self.scheduler = scheduler
        self.notifier = notifier
        self.playSound = playSound
        self.calendar = calendar
        self.center = center
        file = SecureJSONFile(url: directory.appendingPathComponent("timer.json"), debounce: 0.3,
                              scheduler: fileScheduler ?? scheduler)
        now = clock()
        func int(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            min(max(defaults.object(forKey: key) as? Int ?? fallback, range.lowerBound), range.upperBound)
        }
        focusMinutes = int(Key.focus, 25, Self.focusRange)
        shortBreakMinutes = int(Key.shortBreak, 5, Self.shortBreakRange)
        longBreakMinutes = int(Key.longBreak, 15, Self.longBreakRange)
        sessionsBeforeLongBreak = int(Key.sessions, 4, Self.sessionsRange)
        autoStartBreaks = defaults.object(forKey: Key.autoStart) as? Bool ?? true
        soundName = defaults.string(forKey: Key.sound) ?? TimerSound.defaultName
        notifyOnEnd = defaults.object(forKey: Key.notify) as? Bool ?? true
    }

    deinit {
        cancelTick?()
        cancelFinishedEars?()
        if let terminateObserver { center.removeObserver(terminateObserver) }
    }

    private func setting<T>(_ key: String, _ value: T) {
        defaults.set(value, forKey: key)
        // Au repos, l'état propose la nouvelle durée.
        var refreshed = state
        refreshed.refreshIdle(config)
        if refreshed != state { state = refreshed }
    }

    var config: PomodoroConfig {
        PomodoroConfig(focus: TimeInterval(focusMinutes * 60), shortBreak: TimeInterval(shortBreakMinutes * 60),
                       longBreak: TimeInterval(longBreakMinutes * 60),
                       sessionsBeforeLongBreak: sessionsBeforeLongBreak, autoStartBreaks: autoStartBreaks)
    }

    // MARK: Contrat

    /// Tourne notch repliée tant qu'un minuteur compte ou est en pause, et pendant l'oreille « Terminé ».
    var keepsRunningWhenCollapsed: Bool {
        loadIfNeeded()
        return state.isActive || finishedEarsUntil != nil
    }

    var ears: ModuleEars? {
        let priority = Self.earsPriority
        switch state.status {
        case .running:
            return ModuleEars(symbol: phaseSymbol, text: TimerFormat.clock(state.remaining(at: now)), priority: priority)
        case .paused:
            return ModuleEars(symbol: "pause.fill", text: TimerFormat.clock(state.remaining), priority: priority)
        case .finished where finishedEarsUntil != nil:
            return ModuleEars(symbol: "checkmark.circle.fill", text: L("Terminé", table: "Timer"), priority: priority)
        case .idle, .finished:
            return nil
        }
    }

    /// Symbole du décompte en cours : minuteur, concentration, pause.
    var phaseSymbol: String {
        guard state.mode == .pomodoro else { return "timer" }
        return state.phase.isBreak ? "cup.and.saucer" : "brain.head.profile"
    }

    func start() {
        loadIfNeeded()
        isStarted = true
        now = clock()
        if terminateObserver == nil {
            // Sans file : exécuté tout de suite, avant la sortie du processus.
            terminateObserver = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                   queue: nil) { [weak self] _ in self?.saveNow() }
        }
        syncTick()
        syncNotification()
    }

    func stop() {
        isStarted = false
        openViews = 0
        cancelTick?()
        cancelTick = nil
        cancelFinishedEars?()
        cancelFinishedEars = nil
        if finishedEarsUntil != nil { finishedEarsUntil = nil }
        if let terminateObserver { center.removeObserver(terminateObserver) }
        terminateObserver = nil
        // Arrêté alors qu'un décompte court encore : le module est désactivé, plus de notification.
        if state.status == .running { cancelScheduledNotification() }
        saveNow()
    }

    func makeView() -> AnyView { AnyView(TimerPanel(module: self)) }
    func makeCompactView() -> AnyView? {
        state.status == .idle ? nil : AnyView(TimerCompactView(module: self))
    }
    func makeSettingsView() -> AnyView? { AnyView(TimerSettingsView(module: self)) }
    func makeTabIcon() -> AnyView? { AnyView(TimerTabIcon(module: self)) }

    // MARK: Chargement et sauvegarde

    /// Lit `timer.json` une fois. Un décompte échu pendant l'arrêt devient « terminé à HH:mm », sans son.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        now = clock()
        guard let saved = file.load() else { return }
        var restored = saved.state.sanitized(config: config)
        let ended = restored.advance(now: now, config: config, calendar: calendar, silent: true)
        state = restored
        if ended != nil {
            showFinishedEars()
            file.save(FileContent(state: state))
        }
    }

    private func persist() {
        file.save(FileContent(state: state))
    }

    /// Écrit tout de suite ce qui attend et attend la fin : repli du panneau, désactivation, fin de l'app.
    func saveNow() {
        file.flush()
        file.wait()
    }

    // MARK: Actions

    /// Démarrer (ou recommencer, ou lancer la phase suivante du Pomodoro).
    func startTimer() {
        loadIfNeeded()
        guard state.status == .idle || state.status == .finished else { return }
        now = clock()
        state.start(now: now, config: config)
        panelOpened()
        commit()
    }

    /// Préréglage : la durée est retenue et le minuteur part tout de suite.
    func startSimple(minutes: Int) {
        loadIfNeeded()
        guard !state.isActive else { return }
        state.setMode(.simple, config: config)
        state.setSimpleDuration(TimeInterval(minutes * 60))
        startTimer()
    }

    func setSimpleMinutes(_ minutes: Int) {
        loadIfNeeded()
        state.setSimpleDuration(TimeInterval(minutes * 60))
        persist()
    }

    func setMode(_ mode: TimerMode) {
        loadIfNeeded()
        state.setMode(mode, config: config)
        commit()
    }

    func pause() {
        now = clock()
        state.pause(now: now)
        commit()
    }

    func resume() {
        now = clock()
        state.resume(now: now)
        commit()
    }

    func togglePause() {
        state.status == .running ? pause() : resume()
    }

    func addMinute() {
        now = clock()
        state.addMinute()
        commit()
    }

    /// « Arrêter » ; sur « terminé », sert aussi de « OK ».
    func stopTimer() {
        now = clock()
        state.stop(config: config)
        commit()
    }

    /// Pomodoro : passer à la phase suivante.
    func skip() {
        now = clock()
        state.skip(now: now, config: config)
        commit()
    }

    func previewSound() {
        if !soundName.isEmpty { playSound(soundName) }
    }

    /// La notch s'ouvre (icône d'onglet ou résumé compact à l'écran) : l'oreille « Terminé » a servi.
    func viewAppeared() {
        openViews += 1
        panelOpened()
    }

    func viewDisappeared() {
        openViews = max(0, openViews - 1)
    }

    func panelOpened() {
        guard finishedEarsUntil != nil else { return }
        cancelFinishedEars?()
        cancelFinishedEars = nil
        finishedEarsUntil = nil
    }

    // MARK: Moteur

    /// Après chaque changement d'état : sauvegarde, rendez-vous suivant, notification de fin.
    private func commit() {
        persist()
        syncTick()
        syncNotification()
    }

    /// Un seul rendez-vous à la fois : l'ancien est annulé, le nouveau vise le prochain changement d'affichage.
    private func syncTick() {
        cancelTick?()
        cancelTick = nil
        guard isStarted, state.status == .running, let end = state.endDate else { return }
        // Prochain changement d'affichage : le reste franchit un entier (l'affichage arrondit au-dessus). Sur un
        // entier exact, il change dans 1 s ; sinon dans la partie fractionnaire, même minuscule (jamais sautée).
        let remaining = end.timeIntervalSince(clock())
        var delay = remaining - remaining.rounded(.down)
        if delay == 0 { delay = 1 }
        cancelTick = scheduler.after(max(0.05, delay + 0.02)) { [weak self] in self?.tick() }
    }

    /// Rendez-vous du décompte. Public pour les tests, qui avancent l'horloge puis appellent `tick`.
    func tick() {
        cancelTick?()
        cancelTick = nil
        now = clock()
        guard let ended = state.advance(now: now, config: config, calendar: calendar) else {
            return syncTick()
        }
        finish(ended)
    }

    private func finish(_ ended: TimerEnded) {
        // La notification de la phase terminée est remise par le système : on la laisse partir.
        scheduledNotification = nil
        if !ended.silent, !soundName.isEmpty { playSound(soundName) }
        // Panneau ouvert : le résultat est sous les yeux, pas d'oreille « Terminé » au repli qui suit.
        if state.status == .finished, openViews == 0 { showFinishedEars() }
        commit()
    }

    private func showFinishedEars() {
        cancelFinishedEars?()
        finishedEarsUntil = now.addingTimeInterval(Self.finishedEarsDuration)
        cancelFinishedEars = scheduler.after(Self.finishedEarsDuration) { [weak self] in
            self?.cancelFinishedEars = nil
            self?.finishedEarsUntil = nil
        }
    }

    // MARK: Notification de fin

    private func notificationID(for end: Date) -> String {
        "oriel.timer.\(Int(end.timeIntervalSince1970))"
    }

    private func cancelScheduledNotification() {
        if let scheduledNotification { notifier.cancel(id: scheduledNotification) }
        scheduledNotification = nil
    }

    /// Une notification par décompte, programmée au départ ; changée si la fin bouge (« +1 min », reprise),
    /// retirée si le décompte s'arrête. L'autorisation est demandée ici, au premier minuteur.
    private func syncNotification() {
        guard notifyOnEnd, state.status == .running, let end = state.endDate else {
            return cancelScheduledNotification()
        }
        let id = notificationID(for: end)
        guard id != scheduledNotification else { return }
        cancelScheduledNotification()
        scheduledNotification = id
        let message = endMessage
        ensureAccess { [weak self] granted in
            guard granted, let self, self.scheduledNotification == id else { return }
            self.notifier.schedule(id: id, title: message.title, body: message.body, at: end)
        }
    }

    private func ensureAccess(_ then: @escaping (Bool) -> Void) {
        notifier.access { [weak self] access in
            guard let self else { return }
            notificationAccess = access
            switch access {
            case .granted: then(true)
            case .denied: then(false)
            case .notDetermined:
                notifier.request { [weak self] granted in
                    self?.notificationAccess = granted ? .granted : .denied
                    then(granted)
                }
            }
        }
    }

    /// Relit l'autorisation sans la demander (affichage des réglages).
    func refreshNotificationAccess() {
        notifier.access { [weak self] access in self?.notificationAccess = access }
    }

    /// Texte de la notification du décompte en cours.
    private var endMessage: (title: String, body: String) {
        guard state.mode == .pomodoro else {
            return (L("Minuteur terminé", table: "Timer"),
                    String(format: L("%@ écoulées.", table: "Timer"), TimerFormat.duration(state.duration)))
        }
        switch state.phase {
        case .focus:
            return (L("Concentration terminée", table: "Timer"), L("C'est l'heure de la pause.", table: "Timer"))
        case .shortBreak, .longBreak:
            return (L("Pause terminée", table: "Timer"), L("Retour à la concentration.", table: "Timer"))
        }
    }
}
