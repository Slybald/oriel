import AppKit
import EventKit
import SwiftUI

/// Onglet « Lecteur » : lecture en cours (mediaremote-adapter, voir `MediaRemoteAdapter`) et calendrier (EventKit).
/// Textes dans Resources/{en,fr}.lproj/Media.strings ; réglages dans UserDefaults sous « media.… ».
///
/// - Lecture : `test` au premier démarrage, puis `stream` tant que le module tourne et que le lecteur est affiché.
///   Avec les oreilles de lecture, le module tourne aussi notch repliée (le flux sert alors aux oreilles).
/// - Calendrier : lu seulement quand une vue du calendrier est à l'écran (onglet, mode compact) ; l'accès n'est
///   demandé que sur un geste de l'utilisateur (bouton de l'onglet, interrupteur des réglages).
final class MediaModule: NotchModule {
    let id = "media"
    let symbol = "play.circle"
    var title: String { L("Lecteur", table: "Media") }

    enum PlayerStatus: Equatable {
        /// Pas encore vérifié, ou `test` en cours.
        case checking
        case ready
        case unavailable
    }

    /// Délai avant de relancer `test` après un échec (à l'ouverture suivante du panneau).
    static let retestDelay: TimeInterval = 300

    // MARK: État

    @Published private(set) var playerStatus: PlayerStatus
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var calendarAccess: CalendarAccess
    /// Début du jour choisi dans la bande de la semaine ; aujourd'hui à chaque apparition du calendrier.
    @Published var selectedDay: Date {
        didSet {
            let week = { MediaCalendarMath.week(containing: $0).first }
            if week(selectedDay) != week(oldValue) { reloadEvents() }
        }
    }
    /// Semaine affichée et sept jours à venir (prochain événement du mode compact).
    @Published private(set) var events: [MediaEvent] = []

    // MARK: Réglages

    @Published var showPlayer: Bool {
        didSet {
            defaults.set(showPlayer, forKey: Key.showPlayer)
            syncPlayer()
        }
    }

    @Published var showCalendar: Bool {
        didSet {
            defaults.set(showCalendar, forKey: Key.showCalendar)
            syncCalendar()
        }
    }

    /// Oreilles pendant la lecture (notch repliée, quand Claude n'a rien à montrer).
    @Published var playerEars: Bool {
        didSet { defaults.set(playerEars, forKey: Key.playerEars) }
    }

    /// Calendriers décochés dans les réglages (un nouveau calendrier est affiché d'office).
    @Published var hiddenCalendars: Set<String> {
        didSet {
            defaults.set(hiddenCalendars.sorted(), forKey: Key.hiddenCalendars)
            reloadEvents()
        }
    }

    private enum Key {
        static let showPlayer = "media.showPlayer"
        static let showCalendar = "media.showCalendar"
        static let playerEars = "media.playerEars"
        static let hiddenCalendars = "media.hiddenCalendars"
    }

    private let defaults: UserDefaults
    private let adapter: MediaRemoteAdapter?
    let calendar: CalendarSource
    /// Lignes du flux analysées ici, dans l'ordre (la pochette se décode hors du main thread).
    private let parseQueue = DispatchQueue(label: "oriel.media.nowplaying")
    private var state = NowPlayingState()
    private var isRunning = false
    private var testing = false
    private var lastTest: Date?
    private var calendarViewers = 0
    private var calendarObservers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, adapter: MediaRemoteAdapter? = .bundled(),
         calendar: CalendarSource = EventKitCalendar()) {
        self.defaults = defaults
        self.adapter = adapter
        self.calendar = calendar
        playerStatus = adapter == nil ? .unavailable : .checking
        calendarAccess = calendar.access
        selectedDay = Calendar.current.startOfDay(for: Date())
        showPlayer = defaults.object(forKey: Key.showPlayer) as? Bool ?? true
        showCalendar = defaults.object(forKey: Key.showCalendar) as? Bool ?? true
        playerEars = defaults.object(forKey: Key.playerEars) as? Bool ?? true
        hiddenCalendars = Set(defaults.stringArray(forKey: Key.hiddenCalendars) ?? [])
    }

    // MARK: Contrat

    var keepsRunningWhenCollapsed: Bool { showPlayer && playerEars && playerStatus != .unavailable }

    /// Pochette à gauche de la notch, égaliseur à droite, tant qu'un morceau joue ; priorité sous Claude.
    var ears: ModuleEars? {
        guard showPlayer, playerEars, nowPlaying?.isPlaying == true else { return nil }
        return ModuleEars(symbol: "music.note", text: "", priority: 1, image: artwork, bars: true)
    }

    var licenseNotices: [LicenseNotice] {
        [LicenseNotice(name: "mediaremote-adapter", text: Self.adapterLicense)]
    }

    func start() {
        isRunning = true
        refreshCalendarAccess()
        syncPlayer()
        syncCalendar()
    }

    func stop() {
        isRunning = false
        syncPlayer()
        syncCalendar()
        calendar.release()
    }

    func makeView() -> AnyView { AnyView(MediaPanel(module: self)) }
    func makeCompactView() -> AnyView? { AnyView(MediaCompactView(module: self)) }
    func makeTabDetailView() -> AnyView? { AnyView(MediaTabDetailView(module: self)) }
    func makeSettingsView() -> AnyView? { AnyView(MediaSettingsView(module: self)) }

    // MARK: Lecture

    private func syncPlayer() {
        guard let adapter else { return }
        guard isRunning, showPlayer else { return adapter.stopStream() }
        if playerStatus == .ready {
            startStream(adapter)
        } else {
            runTest(adapter)
        }
    }

    private func runTest(_ adapter: MediaRemoteAdapter) {
        guard !testing else { return }
        if playerStatus == .unavailable, let lastTest, Date().timeIntervalSince(lastTest) < Self.retestDelay { return }
        testing = true
        playerStatus = .checking
        adapter.test { [weak self] ok in
            guard let self else { return }
            testing = false
            lastTest = Date()
            playerStatus = ok ? .ready : .unavailable
            if ok { syncPlayer() }
        }
    }

    /// Bouton « Réessayer » de l'état indisponible.
    func retryPlayer() {
        lastTest = nil
        syncPlayer()
    }

    private func startStream(_ adapter: MediaRemoteAdapter) {
        adapter.startStream(onFailure: { [weak self] in self?.streamFailed(adapter) }) { [weak self] line in
            self?.parseQueue.async {
                guard let self, self.state.apply(line) else { return }
                let info = self.state.info
                let artwork = self.state.artwork
                DispatchQueue.main.async { self.publish(info, artwork) }
            }
        }
    }

    /// Le flux meurt en boucle : l'adaptateur est revérifié ; s'il ne répond plus, état indisponible (le module
    /// cesse alors de tourner replié), sinon le flux repart.
    private func streamFailed(_ adapter: MediaRemoteAdapter) {
        nowPlaying = nil
        artwork = nil
        runTest(adapter)
    }

    /// Lignes en retard d'un flux arrêté ou en échec : ignorées.
    private func publish(_ info: NowPlaying?, _ newArtwork: NSImage?) {
        guard isRunning, playerStatus == .ready else { return }
        if info != nowPlaying { nowPlaying = info }
        if newArtwork !== artwork { artwork = newArtwork }
    }

    func send(_ command: MediaCommand) {
        adapter?.run(["send", String(command.rawValue)])
    }

    /// Avance à `seconds` ; la barre y reste jusqu'à la confirmation du flux.
    func seek(to seconds: TimeInterval) {
        guard var info = nowPlaying, let duration = info.duration, info.canSeek else { return }
        let seconds = min(max(0, seconds), duration)
        adapter?.run(["seek", String(Int((seconds * 1_000_000).rounded()))])
        info.elapsed = seconds
        info.timestamp = Date()
        nowPlaying = info
    }

    /// Clic sur la pochette : l'app qui joue passe devant.
    func openSourceApp() {
        guard let id = nowPlaying?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Calendrier

    private var calendarActive: Bool {
        isRunning && showCalendar && calendarViewers > 0 && calendarAccess == .granted
    }

    /// L'autorisation a pu changer dans Réglages Système depuis la dernière lecture.
    func refreshCalendarAccess() {
        let access = calendar.access
        if access != calendarAccess { calendarAccess = access }
    }

    /// Une vue du calendrier arrive à l'écran.
    func calendarAppeared() {
        if calendarViewers == 0 { selectedDay = Calendar.current.startOfDay(for: Date()) }
        calendarViewers += 1
        refreshCalendarAccess()
        syncCalendar()
    }

    func calendarDisappeared() {
        calendarViewers = max(0, calendarViewers - 1)
        syncCalendar()
    }

    /// Réglages fermés, module à l'arrêt : la base ouverte pour lister les calendriers est libérée.
    func releaseCalendarIfIdle() {
        if !isRunning { calendar.release() }
    }

    /// Bouton « Autoriser l'accès au calendrier » ou interrupteur des réglages : jamais au lancement.
    func requestCalendarAccess() {
        refreshCalendarAccess()
        guard calendarAccess == .notDetermined else { return }
        calendar.requestAccess { [weak self] access in
            self?.calendarAccess = access
            self?.syncCalendar()
        }
    }

    private func syncCalendar() {
        if calendarActive, calendarObservers.isEmpty {
            let center = NotificationCenter.default
            calendarObservers = [Notification.Name.EKEventStoreChanged, .NSCalendarDayChanged].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let self else { return }
                    if note.name == .NSCalendarDayChanged {
                        selectedDay = Calendar.current.startOfDay(for: Date())
                    }
                    reloadEvents()
                }
            }
            reloadEvents()
        } else if !calendarActive, !calendarObservers.isEmpty {
            calendarObservers.forEach(NotificationCenter.default.removeObserver)
            calendarObservers = []
        }
    }

    func reloadEvents() {
        guard calendarActive else { return }
        let cal = Calendar.current
        let week = MediaCalendarMath.week(containing: selectedDay)
        let now = Date()
        let start = min(week[0], cal.startOfDay(for: now))
        let end = max(cal.date(byAdding: .day, value: 7, to: week[0]) ?? now,
                      cal.date(byAdding: .day, value: 7, to: now) ?? now)
        calendar.events(from: start, to: end, hidden: hiddenCalendars) { [weak self] events in
            guard let self, calendarActive, events != self.events else { return }
            self.events = events
        }
    }

    /// Clic sur un événement : Calendrier à cette date.
    func openCalendar(at date: Date) {
        CalendarOpener.open(at: date)
    }

    func openCalendarPrivacySettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        URL(string: url).map { _ = NSWorkspace.shared.open($0) }
    }

    // MARK: Licence

    /// Vendor/mediaremote-adapter/LICENSE.
    static let adapterLicense = """
    BSD 3-Clause License

    Copyright (c) 2025, Jonas van den Berg and contributors

    Redistribution and use in source and binary forms, with or without modification, are permitted provided \
    that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, this list of conditions and the \
    following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the \
    following disclaimer in the documentation and/or other materials provided with the distribution.

    3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or \
    promote products derived from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED \
    WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A \
    PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY \
    DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, \
    PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER \
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE \
    OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH \
    DAMAGE.
    """
}
