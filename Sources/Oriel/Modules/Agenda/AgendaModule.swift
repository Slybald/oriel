import AppKit
import EventKit
import SwiftUI

/// Onglet « Agenda » : le prochain rendez-vous (compte à rebours, bouton « Rejoindre ») et la journée. Textes dans
/// Resources/{en,fr}.lproj/Agenda.strings ; réglages dans UserDefaults sous « agenda.… ».
///
/// - Notch repliée, le module tourne dès que l'accès au calendrier est accordé : un observateur de la base
///   (`EKEventStoreChanged`), un du changement de jour, de l'horloge et du réveil du Mac, et UNE échéance planifiée
///   (`AgendaMath.nextWake`). Aucun sondage : entre deux échéances, le CPU est à zéro.
/// - L'intercalaire apparaît 15 minutes avant (discret), passe à l'ambre à 5 minutes, dit « en cours » pendant le
///   rendez-vous puis disparaît. Le compte à rebours change de minute à chaque échéance.
/// - L'accès au calendrier n'est demandé que sur un clic (« Autoriser » dans l'onglet ou les réglages).
/// - Le lien de réunion vient du texte d'un tiers : il n'est ouvert que sur un clic de « Rejoindre », après un
///   dernier contrôle (`MeetingLink.isOpenable`).
final class AgendaModule: NotchModule {
    let id = "agenda"
    let symbol = "calendar"
    var title: String { L("Agenda", table: "Agenda") }

    /// Au-dessus du minuteur (5) quand le rendez-vous est imminent, au-dessus de la lecture (1) sinon.
    static let earsPriority = 2
    static let imminentPriority = 6
    static let softHex = "D4D4D8"
    static let imminentHex = "F5B83D"
    static let runningHex = "4ADE80"

    // MARK: État

    @Published private(set) var access: CalendarAccess
    /// Semaine affichée et deux jours à partir d'aujourd'hui (de quoi planifier les échéances).
    @Published private(set) var events: [MediaEvent] = []
    /// Horloge du module : relue à chaque échéance et à chaque lecture de la base.
    @Published private(set) var now: Date
    /// Début du jour choisi dans la bande de la semaine ; aujourd'hui à chaque ouverture de l'onglet.
    @Published var selectedDay: Date {
        didSet {
            let week = { MediaCalendarMath.week(containing: $0).first }
            if week(selectedDay) != week(oldValue) { reload() }
        }
    }

    /// Prochaine échéance planifiée (nil : rien à attendre).
    private(set) var nextWake: Date?

    // MARK: Réglages

    /// Intercalaire de la notch repliée avant un rendez-vous.
    @Published var showEars: Bool {
        didSet { defaults.set(showEars, forKey: Key.ears) }
    }

    /// Calendriers décochés dans les réglages (un nouveau calendrier est affiché d'office).
    @Published var hiddenCalendars: Set<String> {
        didSet {
            defaults.set(hiddenCalendars.sorted(), forKey: Key.hiddenCalendars)
            reload()
        }
    }

    private enum Key {
        static let ears = "agenda.ears"
        static let hiddenCalendars = "agenda.hiddenCalendars"
    }

    private let defaults: UserDefaults
    let calendar: CalendarSource
    let clock: () -> Date
    private let scheduler: ModuleScheduler
    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let opener: (URL) -> Void
    private var isRunning = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancelWake: (() -> Void)?
    private var loading = false
    private var reloadAgain = false

    init(defaults: UserDefaults = .standard, calendar: CalendarSource = EventKitCalendar(),
         clock: @escaping () -> Date = Date.init, scheduler: ModuleScheduler = .system,
         center: NotificationCenter = .default,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         opener: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.calendar = calendar
        self.clock = clock
        self.scheduler = scheduler
        self.center = center
        self.workspaceCenter = workspaceCenter
        self.opener = opener
        access = calendar.access
        now = clock()
        selectedDay = Calendar.current.startOfDay(for: clock())
        showEars = defaults.object(forKey: Key.ears) as? Bool ?? true
        hiddenCalendars = Set(defaults.stringArray(forKey: Key.hiddenCalendars) ?? [])
    }

    // MARK: Contrat

    var keepsRunningWhenCollapsed: Bool { showEars && access == .granted }

    var ears: ModuleEars? {
        guard showEars, access == .granted, let focus = AgendaMath.focus(events, at: now) else { return nil }
        let text = AgendaFormat.ears(focus)
        let symbol = focus.event.meeting == nil ? "calendar" : "video.fill"
        switch focus.phase {
        case .soon:
            return ModuleEars(symbol: "calendar", text: text, priority: Self.earsPriority, accentHex: Self.softHex)
        case .imminent:
            return ModuleEars(symbol: symbol, text: text, priority: Self.imminentPriority, alert: true,
                              accentHex: Self.imminentHex)
        case .running:
            return ModuleEars(symbol: symbol, text: text, priority: Self.earsPriority, accentHex: Self.runningHex)
        }
    }

    func start() {
        isRunning = true
        refreshAccess()
        guard access == .granted else { return }
        observe()
        reload()
    }

    func stop() {
        isRunning = false
        unobserve()
        cancelWake?()
        cancelWake = nil
        nextWake = nil
        events = []
        calendar.release()
    }

    func makeView() -> AnyView { AnyView(AgendaPanel(module: self)) }
    func makeCompactView() -> AnyView? { AnyView(AgendaCompactView(module: self)) }
    func makeTabDetailView() -> AnyView? { AnyView(AgendaCardView(module: self)) }
    func makeSettingsView() -> AnyView? { AnyView(AgendaSettingsView(module: self)) }
    func makeHeaderAccessory() -> AnyView? { AnyView(AgendaTodayButton(module: self)) }

    // MARK: Accès

    /// L'autorisation a pu changer dans Réglages Système depuis la dernière lecture.
    func refreshAccess() {
        let current = calendar.access
        if current != access { access = current }
    }

    /// Bouton « Autoriser l'accès au calendrier » ou interrupteur des réglages : jamais au lancement.
    func requestAccess() {
        refreshAccess()
        guard access == .notDetermined else { return }
        calendar.requestAccess { [weak self] access in
            guard let self else { return }
            self.access = access
            if isRunning, access == .granted {
                observe()
                reload()
            }
        }
    }

    func openPrivacySettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        URL(string: url).map { _ = NSWorkspace.shared.open($0) }
    }

    /// Réglages fermés, module à l'arrêt : la base ouverte pour lister les calendriers est libérée.
    func releaseCalendarIfIdle() {
        if !isRunning { calendar.release() }
    }

    // MARK: Lecture

    /// L'onglet s'ouvre : aujourd'hui, et une lecture fraîche.
    func panelAppeared() {
        selectedDay = Calendar.current.startOfDay(for: clock())
        refreshAccess()
        reload()
    }

    private func observe() {
        guard observers.isEmpty else { return }
        func add(_ target: NotificationCenter, _ name: Notification.Name, today: Bool = false) {
            let token = target.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if today { selectedDay = Calendar.current.startOfDay(for: clock()) }
                reload()
            }
            observers.append((target, token))
        }
        add(center, .EKEventStoreChanged)
        add(center, .NSCalendarDayChanged, today: true)
        add(center, .NSSystemClockDidChange)
        add(workspaceCenter, NSWorkspace.didWakeNotification)
    }

    private func unobserve() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
    }

    /// Relit la base, puis recale l'horloge et l'échéance. Les demandes qui arrivent pendant une lecture (une
    /// synchronisation iCloud en envoie des dizaines) n'en déclenchent qu'une de plus.
    func reload() {
        guard isRunning, access == .granted else { return }
        if loading {
            reloadAgain = true
            return
        }
        loading = true
        let cal = Calendar.current
        let today = cal.startOfDay(for: clock())
        let week = MediaCalendarMath.week(containing: selectedDay)
        let start = min(week[0], today)
        let end = max(cal.date(byAdding: .day, value: 7, to: week[0]) ?? today,
                      cal.date(byAdding: .day, value: 2, to: today) ?? today)
        calendar.events(from: start, to: end, hidden: hiddenCalendars) { [weak self] events in
            guard let self else { return }
            loading = false
            if isRunning, access == .granted {
                if events != self.events { self.events = events }
                wake()
            }
            if reloadAgain {
                reloadAgain = false
                reload()
            }
        }
    }

    /// Échéance atteinte (ou base relue) : l'heure est relue, la suivante planifiée.
    func wake() {
        now = clock()
        cancelWake?()
        cancelWake = nil
        nextWake = AgendaMath.nextWake(events, after: now)
        guard isRunning, let nextWake else { return }
        cancelWake = scheduler.after(nextWake.timeIntervalSince(now)) { [weak self] in self?.wake() }
    }

    // MARK: Actions

    /// « Rejoindre » : le seul chemin qui ouvre un lien d'événement.
    func join(_ event: MediaEvent) {
        guard let link = event.meeting, MeetingLink.isOpenable(link.url) else { return }
        opener(link.url)
    }

    /// « Voir dans Calendrier » : Calendrier à ce jour.
    func openCalendar(at date: Date) {
        CalendarOpener.open(at: date)
    }
}
