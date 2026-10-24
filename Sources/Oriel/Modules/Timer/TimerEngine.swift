import Foundation

// Machine à états du minuteur, sans horloge ni effet de bord : chaque transition reçoit l'heure. Le temps restant
// se calcule depuis une date de fin (jamais en décrémentant) : il survit à une veille et à un redémarrage.

enum TimerMode: String, Codable {
    case simple
    case pomodoro
}

enum TimerPhase: String, Codable {
    case focus
    case shortBreak
    case longBreak

    var isBreak: Bool { self != .focus }
}

/// Réglages du Pomodoro (durées en secondes).
struct PomodoroConfig: Equatable {
    var focus: TimeInterval = 25 * 60
    var shortBreak: TimeInterval = 5 * 60
    var longBreak: TimeInterval = 15 * 60
    /// Concentrations terminées avant la pause longue.
    var sessionsBeforeLongBreak = 4
    var autoStartBreaks = true

    func duration(of phase: TimerPhase) -> TimeInterval {
        switch phase {
        case .focus: return focus
        case .shortBreak: return shortBreak
        case .longBreak: return longBreak
        }
    }
}

/// Un décompte vient de se terminer.
struct TimerEnded: Equatable {
    var mode: TimerMode
    /// Phase terminée (`focus` pour le minuteur simple).
    var phase: TimerPhase
    /// Pomodoro : phase qui suit (prête, ou déjà lancée si `autoStarted`).
    var next: TimerPhase?
    var autoStarted: Bool
    /// Durée du décompte terminé.
    var duration: TimeInterval
    /// Terminé pendant que l'app était fermée ou la machine en veille : ni son ni lancement automatique.
    var silent: Bool
    var at: Date
}

struct TimerState: Codable, Equatable {
    enum Status: String, Codable {
        case idle
        case running
        case paused
        case finished
    }

    /// Au-delà de ce retard, une fin est signalée sans son (veille prolongée, app fermée).
    static let staleAfter: TimeInterval = 60
    static let simpleRange: ClosedRange<TimeInterval> = 60...(24 * 3600)
    static let maxDuration: TimeInterval = 100 * 3600

    var mode: TimerMode = .simple
    var status: Status = .idle
    var phase: TimerPhase = .focus
    /// Durée totale du décompte en cours (l'anneau de progression), « +1 min » comprises.
    var duration: TimeInterval = 600
    /// En cours : fin du décompte.
    var endDate: Date?
    /// À l'arrêt, en pause ou terminé : temps affiché (en pause : ce qu'il reste ; sinon la durée proposée).
    var remaining: TimeInterval = 600
    var finishedAt: Date?
    /// Dernière durée du minuteur simple.
    var simpleDuration: TimeInterval = 600
    /// Concentrations terminées depuis la dernière pause longue.
    var cycle = 0
    var sessionsToday = 0
    /// Début du jour de `sessionsToday`.
    var sessionsDay: Date?

    var isActive: Bool { status == .running || status == .paused }

    func remaining(at now: Date) -> TimeInterval {
        guard status == .running, let endDate else { return remaining }
        return max(0, endDate.timeIntervalSince(now))
    }

    /// Part écoulée du décompte (0…1).
    func progress(at now: Date) -> Double {
        switch status {
        case .idle: return 0
        case .finished: return 1
        case .running, .paused:
            guard duration > 0 else { return 0 }
            return min(max(1 - remaining(at: now) / duration, 0), 1)
        }
    }

    /// Concentrations terminées aujourd'hui (le compteur repart à zéro à minuit).
    func sessions(on now: Date, calendar: Calendar) -> Int {
        sessionsDay == calendar.startOfDay(for: now) ? sessionsToday : 0
    }

    /// Durée proposée au prochain départ.
    func idleDuration(_ config: PomodoroConfig) -> TimeInterval {
        mode == .simple ? simpleDuration : config.duration(of: phase)
    }

    // MARK: Transitions

    private mutating func begin(_ seconds: TimeInterval, now: Date) {
        status = .running
        duration = seconds
        remaining = seconds
        endDate = now.addingTimeInterval(seconds)
        finishedAt = nil
    }

    /// Depuis l'arrêt ou depuis « terminé » (même durée, ou la phase suivante prête).
    mutating func start(now: Date, config: PomodoroConfig) {
        guard status == .idle || status == .finished else { return }
        begin(idleDuration(config), now: now)
    }

    mutating func pause(now: Date) {
        guard status == .running else { return }
        remaining = remaining(at: now)
        endDate = nil
        status = .paused
    }

    mutating func resume(now: Date) {
        guard status == .paused else { return }
        begin(remaining, now: now, keepingDuration: duration)
    }

    private mutating func begin(_ seconds: TimeInterval, now: Date, keepingDuration total: TimeInterval) {
        begin(seconds, now: now)
        duration = total
    }

    mutating func addMinute() {
        guard isActive else { return }
        guard duration + 60 <= Self.maxDuration else { return }
        duration += 60
        if status == .running, let endDate {
            self.endDate = endDate.addingTimeInterval(60)
        } else {
            remaining += 60
        }
    }

    /// Abandonne le décompte. Une pause abandonnée ramène à la concentration.
    mutating func stop(config: PomodoroConfig) {
        if mode == .pomodoro, phase.isBreak {
            if phase == .longBreak { cycle = 0 }
            phase = .focus
        }
        status = .idle
        endDate = nil
        finishedAt = nil
        refreshIdle(config)
    }

    /// Les réglages ont changé : l'état au repos propose la nouvelle durée.
    mutating func refreshIdle(_ config: PomodoroConfig) {
        guard status == .idle || status == .finished else { return }
        duration = idleDuration(config)
        remaining = duration
    }

    /// Changer de mode n'est possible qu'à l'arrêt ou une fois terminé.
    mutating func setMode(_ newMode: TimerMode, config: PomodoroConfig) {
        guard !isActive, newMode != mode else { return }
        mode = newMode
        phase = .focus
        status = .idle
        endDate = nil
        finishedAt = nil
        refreshIdle(config)
    }

    mutating func setSimpleDuration(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        simpleDuration = min(max(seconds, Self.simpleRange.lowerBound), Self.simpleRange.upperBound)
        if mode == .simple, status == .idle || status == .finished {
            if status == .finished { status = .idle }
            duration = simpleDuration
            remaining = simpleDuration
        }
    }

    /// « Passer » : phase suivante du Pomodoro, sans compter la session ni signaler de fin.
    mutating func skip(now: Date, config: PomodoroConfig) {
        guard mode == .pomodoro else { return }
        switch phase {
        case .focus: phase = .shortBreak
        case .shortBreak: phase = .focus
        case .longBreak:
            cycle = 0
            phase = .focus
        }
        endDate = nil
        finishedAt = nil
        status = .idle
        refreshIdle(config)
        if phase.isBreak, config.autoStartBreaks { begin(duration, now: now) }
    }

    /// Une fin est-elle échue ? Si oui, passe à l'état suivant et la décrit. `silent` force l'absence de son et de
    /// lancement automatique (reprise après relance de l'app).
    mutating func advance(now: Date, config: PomodoroConfig, calendar: Calendar, silent: Bool = false) -> TimerEnded? {
        guard status == .running, let end = endDate, end <= now else { return nil }
        let quiet = silent || now.timeIntervalSince(end) > Self.staleAfter
        let ended = TimerEnded(mode: mode, phase: phase, next: nil, autoStarted: false, duration: duration,
                               silent: quiet, at: end)
        endDate = nil
        guard mode == .pomodoro else {
            status = .finished
            finishedAt = end
            remaining = simpleDuration
            return ended
        }
        let next: TimerPhase
        switch phase {
        case .focus:
            let day = calendar.startOfDay(for: end)
            sessionsToday = (sessionsDay == day ? sessionsToday : 0) + 1
            sessionsDay = day
            cycle += 1
            next = cycle >= config.sessionsBeforeLongBreak ? .longBreak : .shortBreak
        case .shortBreak:
            next = .focus
        case .longBreak:
            cycle = 0
            next = .focus
        }
        phase = next
        duration = config.duration(of: next)
        remaining = duration
        let auto = next.isBreak && config.autoStartBreaks && !quiet
        if auto {
            begin(duration, now: now)
        } else {
            status = .finished
            finishedAt = end
        }
        var result = ended
        result.next = next
        result.autoStarted = auto
        return result
    }

    /// État lu dans un fichier : valeurs aberrantes ramenées à des valeurs sûres.
    func sanitized(config: PomodoroConfig) -> TimerState {
        var state = self
        func valid(_ value: TimeInterval) -> Bool { value.isFinite && value >= 0 && value <= Self.maxDuration }
        if !valid(state.duration) || state.duration <= 0 { state.duration = state.idleDuration(config) }
        if !valid(state.remaining) { state.remaining = state.duration }
        if !valid(state.simpleDuration) || state.simpleDuration <= 0 { state.simpleDuration = 600 }
        state.simpleDuration = min(max(state.simpleDuration, Self.simpleRange.lowerBound), Self.simpleRange.upperBound)
        state.cycle = min(max(state.cycle, 0), 100)
        state.sessionsToday = min(max(state.sessionsToday, 0), 10_000)
        if state.status == .running, state.endDate == nil { state.status = .idle }
        if state.status != .running { state.endDate = nil }
        if state.status == .idle { state.refreshIdle(config) }
        return state
    }
}

// MARK: - Formats

enum TimerFormat {
    /// « 24:59 », « 0:05 » ; au-delà d'une heure « 1:05:00 ». Arrondi au-dessus : « 0:00 » seulement à la fin.
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// « 25 min », « 2 h », « 1 h 30 ».
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return String(format: L("%d min", table: "Timer"), minutes) }
        if minutes % 60 == 0 { return String(format: L("%d h", table: "Timer"), minutes / 60) }
        return String(format: L("%d h %02d", table: "Timer"), minutes / 60, minutes % 60)
    }

    /// Heure locale courte (« 14:32 »).
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
