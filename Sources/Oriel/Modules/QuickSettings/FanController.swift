import AppKit
import Combine
import FanControl

/// Ventilateurs des Réglages rapides : lecture (vitesses, températures) et vitesse fixe par l'outil `fanctl`.
///
/// - Lecture seulement quand l'onglet est affiché, toutes les 2 s, hors du fil principal ; rien panneau replié.
/// - Vitesse fixe : `sudo -n fanctl hold`, qui tient la vitesse tant que l'app lui écrit (toutes les 10 s). L'outil
///   remet l'automatique si l'app quitte ou plante (fin de son entrée), se fige (bail de 30 s), si la température
///   passe le seuil, si macOS reprend la main, ou sur un signal. L'app rend elle-même la main à la mise en veille,
///   au changement de session et à l'arrêt du module.
/// - Jamais sous le minimum ni au-dessus du maximum lus dans le SMC : la vitesse est bornée ici et revérifiée par
///   l'outil.
final class FanController: ObservableObject {
    enum Mode: Equatable {
        case automatic
        case fixed(rpm: Int)
    }

    /// nil : pas encore lu, pas de SMC ou pas de ventilateur (tuile absente).
    @Published private(set) var status: FanStatus?
    @Published private(set) var mode = Mode.automatic
    @Published private(set) var authorization = FanAuthorizationState.notInstalled
    @Published private(set) var busy = false
    /// Pourquoi l'automatique est revenu sans qu'on le demande ; effacé au prochain passage en manuel.
    @Published private(set) var notice: String?

    /// Erreurs à afficher sous la grille (branché par le module).
    var report: (QuickSettingsIssue) -> Void = { _ in }

    static let manualFlagKey = "quicksettings.fans.manual"

    private let backend: FanBackend
    private let defaults: UserDefaults
    private let readInterval: TimeInterval
    private let heartbeatInterval: TimeInterval
    private let workspace: NotificationCenter
    private let makeTimer: RepeatingTimer
    private var visibleViews = 0
    private var readTimer: Timer?
    private var heartbeat: Timer?
    private var reading = false
    private var observers: [NSObjectProtocol] = []
    /// Empêche App Nap de retarder les nouvelles à l'outil (bail de 30 s) ; la veille reste permise.
    private var activity: NSObjectProtocol?

    /// Minuteur répétitif (intervalle, tolérance, action) ; les tests en fournissent un qu'ils déclenchent à la main.
    typealias RepeatingTimer = (TimeInterval, TimeInterval, @escaping () -> Void) -> Timer

    static let systemTimer: RepeatingTimer = { interval, tolerance, fire in
        let timer = Timer(timeInterval: interval, repeats: true) { _ in fire() }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    init(backend: FanBackend, defaults: UserDefaults, readInterval: TimeInterval = 2, heartbeatInterval: TimeInterval = 10,
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         makeTimer: @escaping RepeatingTimer = FanController.systemTimer) {
        self.backend = backend
        self.defaults = defaults
        self.readInterval = readInterval
        self.heartbeatInterval = heartbeatInterval
        self.workspace = workspace
        self.makeTimer = makeTimer
    }

    deinit {
        readTimer?.invalidate()
        heartbeat?.invalidate()
        observers.forEach(workspace.removeObserver)
    }

    var isFixed: Bool { mode != .automatic }

    /// Vitesse permise pour tous les ventilateurs à la fois : le plus haut des minimums, le plus bas des maximums.
    var range: ClosedRange<Int>? {
        guard let fans = status?.fans, !fans.isEmpty else { return nil }
        let low = Int(fans.map(\.minimum).max()!.rounded(.up))
        let high = Int(fans.map(\.maximum).min()!.rounded(.down))
        return low <= high ? low...high : nil
    }

    /// La vitesse fixe est proposée : Mac Apple Silicon et outil livré avec l'app.
    var canFix: Bool { status?.supportsManual == true && range != nil && backend.canInstall }

    // MARK: - Cycle de vie

    /// Démarrage du module : si l'app s'est arrêtée en vitesse fixe sans que l'outil confirme l'automatique (outil
    /// tué avec l'app, par exemple), on le redemande une fois.
    func start() {
        refreshAuthorization()
        guard defaults.bool(forKey: Self.manualFlagKey), hold == nil else { return }
        guard authorization != .notInstalled else { return defaults.removeObject(forKey: Self.manualFlagKey) }
        backend.resetToAutomatic { [weak self] ok in
            if ok { self?.defaults.removeObject(forKey: Self.manualFlagKey) }
        }
    }

    /// Arrêt du module : rend la main à macOS et cesse toute lecture.
    func stop() {
        returnToAutomatic()
        visibleViews = 0
        stopReading()
        if notice != nil { notice = nil }
    }

    func viewAppeared() {
        visibleViews += 1
        refreshAuthorization()
        guard readTimer == nil else { return }
        read()
        readTimer = makeTimer(readInterval, readInterval / 4) { [weak self] in self?.read() }
    }

    func viewDisappeared() {
        visibleViews = max(0, visibleViews - 1)
        if visibleViews == 0 { stopReading() }
    }

    private func stopReading() {
        readTimer?.invalidate()
        readTimer = nil
    }

    func refreshAuthorization() {
        let value = backend.authorization
        if authorization != value { authorization = value }
    }

    /// Une lecture à la fois (le SMC est lent) ; utilisé aussi par le volet de réglages.
    func read() {
        guard !reading else { return }
        reading = true
        backend.read { [weak self] status in
            guard let self else { return }
            self.reading = false
            if self.status != status { self.status = status }
        }
    }

    // MARK: - Vitesse fixe

    /// Passe en vitesse fixe à la vitesse actuelle (rien ne change à l'oreille) ; pose l'outil d'abord s'il manque.
    func enableFixed() {
        guard let fans = status?.fans, !fans.isEmpty else { return }
        let average = fans.map(\.actual).reduce(0, +) / Double(fans.count)
        setFixed(rpm: Int((average / 100).rounded()) * 100)
    }

    /// Vitesse demandée par le curseur, bornée au minimum et au maximum du Mac.
    func setFixed(rpm requested: Int) {
        guard canFix, let range, !busy else { return }
        let rpm = min(max(requested, range.lowerBound), range.upperBound)
        notice = nil
        if hold != nil {
            send(rpm)
        } else if authorization == .installed {
            beginHold(rpm)
        } else {
            busy = true
            backend.install { [weak self] result in
                guard let self else { return }
                self.busy = false
                self.refreshAuthorization()
                switch result {
                case .success:
                    self.beginHold(rpm)
                case .failure(let failure):
                    if failure.kind != .cancelled { self.report(Self.issue(installing: failure)) }
                }
            }
        }
    }

    /// « Rendre la main à macOS ». L'outil confirme par `auto requested` puis s'arrête.
    func returnToAutomatic() {
        guard hold != nil else { return }
        backend.send("auto")
        finishHold()
    }

    /// Une tenue : ses messages arrivent après coup, parfois quand une autre a déjà commencé.
    private final class Hold {
        /// L'outil a écrit `auto <raison>` : les ventilateurs sont rendus à macOS.
        var confirmed = false
    }

    private var hold: Hold?

    private func beginHold(_ rpm: Int) {
        let current = Hold()
        let started = backend.startHold(onMessage: { [weak self] in self?.received($0, from: current) },
                                        onEnd: { [weak self] in self?.holdEnded(current, error: $1) })
        guard started else {
            return report(QuickSettingsIssue(message: L("Ventilateurs : impossible de lancer l'outil.", table: "QuickSettings")))
        }
        hold = current
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Ventilateurs en vitesse fixe")
        defaults.set(true, forKey: Self.manualFlagKey)
        send(rpm)
        startHeartbeat()
        observeSessionChanges()
    }

    private func send(_ rpm: Int) {
        for fan in status?.fans ?? [] {
            backend.send("fan \(fan.index) \(rpm)")
        }
        mode = .fixed(rpm: rpm)
    }

    private func received(_ line: String, from source: Hold) {
        if line.hasPrefix("auto ") {
            source.confirmed = true
            if hold == nil { defaults.removeObject(forKey: Self.manualFlagKey) }
            guard source === hold else { return }
            notice = Self.notice(forEnding: String(line.dropFirst(5)))
            finishHold()
            defaults.removeObject(forKey: Self.manualFlagKey)
        } else if line.hasPrefix("refused "), source === hold {
            // L'app borne déjà la vitesse : un refus est un défaut, on rend la main plutôt que d'insister.
            report(QuickSettingsIssue(message: L("Ventilateurs : vitesse refusée par l'outil, retour en automatique.",
                                                 table: "QuickSettings")))
            returnToAutomatic()
        }
    }

    /// Fin du processus. Sans `auto <raison>` avant, l'outil n'a pas rendu la main : on la redemande.
    private func holdEnded(_ source: Hold, error: String?) {
        let active = source === hold
        if active { finishHold() }
        guard !source.confirmed else { return }
        if error?.hasPrefix("sudo:") == true {
            // La règle ne s'applique plus (fichier retiré, autre utilisateur…) : l'outil n'a pas tourné.
            if hold == nil { defaults.removeObject(forKey: Self.manualFlagKey) }
            refreshAuthorization()
            return report(QuickSettingsIssue(
                message: L("Ventilateurs : autorisation refusée. Redonne-la dans Réglages › Réglages rapides.",
                           table: "QuickSettings")))
        }
        if active {
            report(QuickSettingsIssue(message: L("Ventilateurs : l'outil s'est arrêté, retour en automatique.",
                                                 table: "QuickSettings")))
        }
        backend.resetToAutomatic { [weak self] ok in
            guard let self, ok, self.hold == nil else { return }
            self.defaults.removeObject(forKey: Self.manualFlagKey)
        }
    }

    private func finishHold() {
        hold = nil
        backend.endHold()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        heartbeat?.invalidate()
        heartbeat = nil
        observers.forEach(workspace.removeObserver)
        observers = []
        if mode != .automatic { mode = .automatic }
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = makeTimer(heartbeatInterval, 1) { [weak self] in self?.backend.send("ping") }
    }

    /// Veille et changement de session (fermeture, autre utilisateur) : la main revient à macOS.
    private func observeSessionChanges() {
        observers.forEach(workspace.removeObserver)
        observers = [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification].map {
            workspace.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.returnToAutomatic() }
        }
    }

    // MARK: - Autorisation (volet de réglages)

    func install() {
        guard !busy else { return }
        busy = true
        backend.install { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.refreshAuthorization()
            if case .failure(let failure) = result, failure.kind != .cancelled { self.report(Self.issue(installing: failure)) }
        }
    }

    /// « Retirer l'autorisation » : rend la main à macOS, retire l'outil et la règle.
    func uninstall() {
        guard !busy else { return }
        returnToAutomatic()
        busy = true
        backend.uninstall { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.refreshAuthorization()
            if case .failure(let failure) = result, failure.kind != .cancelled {
                self.report(QuickSettingsIssue(message: failure.kind == .denied
                    ? L("Autorisation : identifiants administrateur refusés.", table: "QuickSettings")
                    : L("Ventilateurs : retrait impossible.", table: "QuickSettings")))
            }
        }
    }

    // MARK: - Textes

    static func issue(installing failure: QuickSettingsFailure) -> QuickSettingsIssue {
        switch failure.kind {
        case .denied: return QuickSettingsIssue(message: L("Autorisation : identifiants administrateur refusés.", table: "QuickSettings"))
        case .invalidUser: return QuickSettingsIssue(message: L("Autorisation : nom d'utilisateur non pris en charge.", table: "QuickSettings"))
        case .timeout: return QuickSettingsIssue(message: L("Autorisation : pas de réponse à la demande d'autorisation.", table: "QuickSettings"))
        default: return QuickSettingsIssue(message: L("Ventilateurs : installation de l'outil impossible.", table: "QuickSettings"))
        }
    }

    /// Raison donnée par l'outil (`FanHold.Ending`) → texte de la tuile ; nil quand c'est l'app qui a demandé.
    static func notice(forEnding reason: String) -> String? {
        switch FanHold.Ending(rawValue: reason) {
        case .temperature?: return L("Rendu à macOS : température élevée", table: "QuickSettings")
        case .lease?: return L("Rendu à macOS : l'app ne répondait plus", table: "QuickSettings")
        case .system?: return L("macOS a repris la main", table: "QuickSettings")
        case .write?: return L("Rendu à macOS : vitesse refusée par le Mac", table: "QuickSettings")
        case .signal?: return L("Rendu à macOS", table: "QuickSettings")
        case .requested?, .closed?, nil: return nil
        }
    }
}
