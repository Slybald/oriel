import AppKit
import Combine
import SwiftUI

/// Onglet « Réglages rapides » : Wi-Fi, Bluetooth, Concentration, économie d'énergie, caféine, batterie,
/// ventilateurs (`FanController`) et trois scènes. Textes dans Resources/{en,fr}.lproj/QuickSettings.strings.
///
/// - Arrêté, le module ne fait rien. Démarré, il n'écoute que des notifications du système (batterie IOPS,
///   économie d'énergie, Wi-Fi) : aucun polling. Seule la caféine à durée limitée arme un minuteur, une fois par
///   minute au plus.
/// - Il tourne panneau replié seulement tant que la caféine est active (oreilles) ou que le passage automatique
///   en Autonomie est réglé.
/// - Toutes les actions sont optimistes (la tuile bascule tout de suite), puis corrigées par l'état réel.
/// - Le système n'est atteint que par `QuickSettingsBackends` : les tests y mettent des doubles.
final class QuickSettingsModule: NotchModule {
    let id = "quicksettings"
    let symbol = "switch.2"
    var title: String { L("Réglages rapides", table: "QuickSettings") }

    let prefs: QuickSettingsPrefs
    let fans: FanController

    /// nil : ce Mac n'a pas de Wi-Fi (ou pas encore lu).
    @Published private(set) var wifi: Bool?
    @Published private(set) var wifiConnected = false
    /// nil : Bluetooth inutilisable (API absente ou pas encore lu).
    @Published private(set) var bluetooth: Bool?
    @Published private(set) var lowPower = false
    @Published private(set) var lowPowerSupported = false
    /// Règle sudoers qui évite le mot de passe à chaque bascule de l'économie d'énergie.
    @Published private(set) var authorization = LowPowerAuthorizationState.none
    /// Dernier état demandé : macOS ne permet pas de lire la Concentration.
    @Published private(set) var focus: Bool
    @Published private(set) var caffeine: CaffeineSession?
    /// Batterie du Mac ; nil : pas de batterie (Mac de bureau) ou pas encore lue.
    @Published private(set) var mac: PowerSourceInfo?
    @Published private(set) var accessories: [PowerSourceInfo] = []
    @Published private(set) var busy: Set<QuickTile> = []
    @Published private(set) var issue: QuickSettingsIssue?
    @Published private(set) var snapshot: SceneSnapshot? {
        didSet { prefs.snapshot = snapshot }
    }
    /// Heure de la dernière mise à jour (le temps restant de la caféine se calcule dessus).
    @Published private(set) var now: Date

    private let backends: QuickSettingsBackends
    private let clock: () -> Date
    private let settleDelay: TimeInterval
    private let open: (URL) -> Void

    private var started = false
    private var visibleViews = 0
    private var supportChecked = false
    private var tickTimer: Timer?
    private var verifyWork: DispatchWorkItem?
    private var lowPowerWork: DispatchWorkItem?
    private var pmsetInFlight = false
    private var lastPmsetRead = Date.distantPast
    private var autoArmed = false
    private var cancellables = Set<AnyCancellable>()

    /// `settleDelay` : attente avant de relire le Bluetooth après une bascule (le contrôleur met du temps).
    init(backends: QuickSettingsBackends = .system(), defaults: UserDefaults = .standard,
         clock: @escaping () -> Date = Date.init, settleDelay: TimeInterval = 1,
         open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.backends = backends
        self.clock = clock
        self.settleDelay = settleDelay
        self.open = open
        prefs = QuickSettingsPrefs(defaults: defaults)
        fans = FanController(backend: backends.fans, defaults: defaults)
        focus = prefs.focusState
        now = clock()
        snapshot = prefs.snapshot
        // Un réglage change : les vues se rafraîchissent et le registre relit `keepsRunningWhenCollapsed`.
        prefs.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Vitesse fixe : le registre relit `keepsRunningWhenCollapsed` et les oreilles.
        fans.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        fans.report = { [weak self] issue in self?.issue = issue }
        // `$x` émet avant l'affectation : on passe la nouvelle valeur.
        prefs.$caffeineKeepsDisplayOn.dropFirst().removeDuplicates()
            .sink { [weak self] keepsDisplayOn in self?.reacquireCaffeine(keepDisplayOn: keepsDisplayOn) }
            .store(in: &cancellables)
        Publishers.CombineLatest(prefs.$autoAutonomy, prefs.$autoThreshold).dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.autoArmed = false
                self?.evaluateAutoSwitch()
            }
            .store(in: &cancellables)
    }

    deinit { tickTimer?.invalidate() }

    // MARK: - Contrat

    /// La vitesse fixe tourne panneau replié : l'outil attend des nouvelles de l'app (sinon il rend la main).
    var keepsRunningWhenCollapsed: Bool { caffeine != nil || prefs.autoAutonomy || fans.isFixed }

    /// Vitesse fixe : un ventilateur et la vitesse demandée (rien n'est lu panneau replié), avant la caféine. Sinon
    /// caféine active : une tasse et le temps restant, en dernier recours (priorité basse).
    var ears: ModuleEars? {
        if case .fixed(let rpm) = fans.mode {
            return ModuleEars(symbol: "fanblades.fill", text: QuickSettingsFormat.earsRPM(rpm), priority: Self.earsPriority)
        }
        guard let caffeine else { return nil }
        let text = QuickSettingsFormat.earsDuration(minutes: QuickSettingsFormat.remainingMinutes(of: caffeine, now: now))
        return ModuleEars(symbol: "cup.and.saucer.fill", text: text, priority: Self.earsPriority)
    }

    static let earsPriority = -10

    func makeView() -> AnyView { AnyView(QuickSettingsView(module: self)) }
    func makeCompactView() -> AnyView? { AnyView(QuickSettingsCompactView(module: self)) }
    func makeSettingsView() -> AnyView? { AnyView(QuickSettingsSettingsView(module: self, prefs: prefs)) }

    // MARK: - Cycle de vie

    func start() {
        guard !started else { return }
        started = true
        now = clock()
        backends.power.startMonitoring { [weak self] in self?.lowPowerChanged() }
        backends.battery.startMonitoring { [weak self] in self?.refreshBattery(forceAccessories: false) }
        lowPower = backends.power.isLowPowerEnabled
        refreshAuthorization()
        if !supportChecked {
            supportChecked = true
            backends.power.checkSupport { [weak self] supported in self?.lowPowerSupported = supported }
        }
        refreshBattery(forceAccessories: false)
        fans.start()
    }

    /// Libère tout, caféine comprise : un module arrêté ne tient plus rien. (Tant que la caféine est active, le
    /// module demande à tourner replié : il n'est arrêté que s'il est désactivé.)
    func stop() {
        guard started else { return }
        started = false
        backends.power.stopMonitoring()
        backends.battery.stopMonitoring()
        backends.wifi.stopMonitoring()
        verifyWork?.cancel()
        verifyWork = nil
        // La relecture annulée était la seule à retirer cette marque : sans cela la tuile resterait occupée.
        // L'état réel est relu quand l'onglet réapparaît.
        busy.remove(.bluetooth)
        lowPowerWork?.cancel()
        lowPowerWork = nil
        stopCaffeine()
        fans.stop()
        visibleViews = 0
        if issue != nil { issue = nil }
    }

    /// L'onglet s'affiche : relit ce qui n'a pas de notification (Bluetooth) et rafraîchit le reste. Le Wi-Fi n'est
    /// écouté que pendant l'affichage de l'onglet. Le premier accès au Bluetooth peut afficher la demande
    /// d'autorisation du système.
    func viewAppeared() {
        guard started else { return }
        visibleViews += 1
        backends.wifi.startMonitoring { [weak self] in self?.refreshWiFi() }
        refreshWiFi()
        refreshBluetooth()
        lowPower = backends.power.isLowPowerEnabled
        refreshAuthorization()
        refreshBattery(forceAccessories: true)
        fans.viewAppeared()
    }

    /// L'onglet disparaît (autre onglet, panneau replié). Un compteur plutôt qu'un booléen : en changeant d'onglet
    /// deux fois vite, la nouvelle vue apparaît avant que l'ancienne ne disparaisse.
    func viewDisappeared() {
        visibleViews = max(0, visibleViews - 1)
        if visibleViews == 0 { backends.wifi.stopMonitoring() }
        fans.viewDisappeared()
    }

    // MARK: - Lectures

    private func refreshWiFi() {
        let on = backends.wifi.isPoweredOn()
        let connected = on == true && backends.wifi.isAssociated()
        if wifi != on { wifi = on }
        if wifiConnected != connected { wifiConnected = connected }
    }

    private func refreshBluetooth() {
        let on = backends.bluetooth.isPoweredOn()
        if bluetooth != on { bluetooth = on }
    }

    private func lowPowerChanged() {
        let value = backends.power.isLowPowerEnabled
        if lowPower != value { lowPower = value }
    }

    /// Relit si la règle sudoers est en place (un simple test d'existence du fichier : il peut être retiré hors de
    /// l'app, par le script de désinstallation par exemple). Appelé aussi par le volet de réglages.
    func refreshAuthorization() {
        let value = backends.power.authorization
        if authorization != value { authorization = value }
    }

    /// IOPS donne la batterie du Mac (et ses accessoires s'il en liste). Sur certains Mac il ne liste ni AirPods
    /// ni boîtier alors que `pmset -g accps` les donne : dans ce cas pmset est lu hors du fil principal, à
    /// l'affichage de l'onglet et au plus une fois par minute ensuite. Les accessoires n'apparaissent ni dans les
    /// oreilles ni dans le résumé compact : sans onglet affiché, pmset n'est jamais lancé (et si IOPS ne donne
    /// rien du tout, la batterie du Mac vient de pmset seulement une fois l'onglet affiché).
    private func refreshBattery(forceAccessories: Bool) {
        let iops = backends.battery.readIOPS()
        let iopsMac = iops.first { $0.kind == .mac }
        let iopsAccessories = iops.filter { $0.kind != .mac }
        if let iopsMac, mac != iopsMac { mac = iopsMac }
        if !iopsAccessories.isEmpty {
            if accessories != iopsAccessories { accessories = iopsAccessories }
        } else if visibleViews > 0, forceAccessories || clock().timeIntervalSince(lastPmsetRead) > 60 {
            readPmset(iopsWasEmpty: iops.isEmpty)
        }
        evaluateAutoSwitch()
    }

    private func readPmset(iopsWasEmpty: Bool) {
        guard !pmsetInFlight else { return }
        pmsetInFlight = true
        backends.battery.readPmset { [weak self] sources in
            guard let self else { return }
            self.pmsetInFlight = false
            guard self.started else { return }
            self.lastPmsetRead = self.clock()
            if iopsWasEmpty, let pmsetMac = sources.first(where: { $0.kind == .mac }), self.mac != pmsetMac {
                self.mac = pmsetMac
            }
            let others = sources.filter { $0.kind != .mac }
            if self.accessories != others { self.accessories = others }
            self.evaluateAutoSwitch()
        }
    }

    // MARK: - Bascules

    func toggleWiFi() {
        guard let current = wifi else { return }
        setWiFi(!current)
    }

    private func setWiFi(_ target: Bool) {
        guard wifi != nil, wifi != target, !busy.contains(.wifi) else { return }
        wifi = target
        busy.insert(.wifi)
        issue = nil
        backends.wifi.setPower(target) { [weak self] result in
            guard let self else { return }
            self.busy.remove(.wifi)
            switch result {
            case .success:
                self.refreshWiFi()
            case .failure(let failure):
                self.refreshWiFi()
                self.report(failure, about: .wifi)
            }
        }
    }

    func toggleBluetooth() {
        guard let current = bluetooth else { return }
        setBluetooth(!current)
    }

    private func setBluetooth(_ target: Bool) {
        guard bluetooth != nil, bluetooth != target, !busy.contains(.bluetooth) else { return }
        bluetooth = target
        busy.insert(.bluetooth)
        issue = nil
        guard backends.bluetooth.setPower(target) else {
            busy.remove(.bluetooth)
            refreshBluetooth()
            report(QuickSettingsFailure(.failed), about: .bluetooth)
            return
        }
        verifyBluetooth(target, attemptsLeft: 3)
    }

    /// Le contrôleur Bluetooth change d'état avec un délai : on relit jusqu'à trois fois, une fois par seconde.
    private func verifyBluetooth(_ target: Bool, attemptsLeft: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let actual = self.backends.bluetooth.isPoweredOn()
            if actual == target || attemptsLeft <= 1 {
                self.busy.remove(.bluetooth)
                if self.bluetooth != actual { self.bluetooth = actual }
                if actual != target { self.report(QuickSettingsFailure(.failed), about: .bluetooth) }
            } else {
                self.verifyBluetooth(target, attemptsLeft: attemptsLeft - 1)
            }
        }
        verifyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }

    func toggleLowPower() {
        guard lowPowerSupported else { return }
        setLowPower(!lowPower) { _ in }
    }

    /// `completion(true)` : l'écriture a réussi. Une fenêtre d'autorisation fermée n'est pas une erreur.
    private func setLowPower(_ target: Bool, completion: @escaping (Bool) -> Void) {
        guard !busy.contains(.lowPower), !busy.contains(.authorization) else { return completion(false) }
        lowPower = target
        busy.insert(.lowPower)
        issue = nil
        backends.power.setLowPower(target) { [weak self] result in
            guard let self else { return }
            self.busy.remove(.lowPower)
            // Si la règle sudoers a échoué, le mot de passe a été demandé : l'état passe à « refusée ».
            self.refreshAuthorization()
            switch result {
            case .success:
                // L'état réel arrive par la notification du système ; d'ici là on garde la valeur demandée,
                // puis une relecture unique confirme (ou corrige).
                self.confirmLowPower(target)
                completion(true)
            case .failure(let failure):
                self.lowPower = self.backends.power.isLowPowerEnabled
                if failure.kind != .cancelled { self.report(failure, about: .lowPower) }
                completion(false)
            }
        }
    }

    private func confirmLowPower(_ target: Bool) {
        lowPowerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let actual = self.backends.power.isLowPowerEnabled
            if self.lowPower != actual { self.lowPower = actual }
            if actual != target { self.report(QuickSettingsFailure(.unchanged), about: .lowPower) }
        }
        lowPowerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay * 2, execute: work)
    }

    // MARK: - Autorisation sans mot de passe

    /// Pose la règle sudoers (un mot de passe administrateur, une seule fois).
    func grantLowPowerAuthorization() {
        changeAuthorization(about: .grantAuthorization, backends.power.authorize)
    }

    /// Retire la règle sudoers : le mot de passe est de nouveau demandé à chaque bascule.
    func revokeLowPowerAuthorization() {
        changeAuthorization(about: .revokeAuthorization, backends.power.revokeAuthorization)
    }

    private func changeAuthorization(about subject: Subject,
                                     _ action: (@escaping (Result<Void, QuickSettingsFailure>) -> Void) -> Void) {
        guard !busy.contains(.authorization), !busy.contains(.lowPower) else { return }
        busy.insert(.authorization)
        issue = nil
        action { [weak self] result in
            guard let self else { return }
            self.busy.remove(.authorization)
            self.refreshAuthorization()
            if case .failure(let failure) = result, failure.kind != .cancelled { self.report(failure, about: subject) }
        }
    }

    func toggleFocus() {
        guard !busy.contains(.focus) else { return }
        let target = !focus
        guard prefs.shortcut(turningOn: target) != nil else {
            let message = target
                ? L("Concentration : choisis le raccourci « activer » dans Réglages › Réglages rapides.", table: "QuickSettings")
                : L("Concentration : choisis le raccourci « désactiver » dans Réglages › Réglages rapides.", table: "QuickSettings")
            issue = QuickSettingsIssue(message: message)
            return
        }
        setFocus(target)
    }

    private func setFocus(_ target: Bool) {
        guard let name = prefs.shortcut(turningOn: target), !busy.contains(.focus) else { return }
        setFocusState(target)
        busy.insert(.focus)
        issue = nil
        backends.shortcuts.run(name) { [weak self] result in
            guard let self else { return }
            self.busy.remove(.focus)
            if case .failure(let failure) = result {
                self.setFocusState(!target)
                self.report(failure, about: .focus(name))
            }
        }
    }

    private func setFocusState(_ value: Bool) {
        focus = value
        prefs.focusState = value
    }

    // MARK: - Caféine

    func toggleCaffeine() {
        if caffeine == nil { startCaffeine(prefs.caffeineDuration) } else { stopCaffeine() }
    }

    /// Choisit la durée proposée ; si la caféine tourne, elle repart avec cette durée.
    func selectCaffeineDuration(_ duration: CaffeineDuration) {
        prefs.caffeineDuration = duration
        if caffeine != nil { startCaffeine(duration) }
    }

    func startCaffeine(_ duration: CaffeineDuration) {
        startCaffeine(until: duration.seconds.map { clock().addingTimeInterval($0) })
    }

    func startCaffeine(until end: Date?) {
        issue = nil
        guard backends.caffeine.acquire(keepDisplayOn: prefs.caffeineKeepsDisplayOn) else {
            stopCaffeine()
            issue = QuickSettingsIssue(message: L("Caféine : impossible d'empêcher la veille.", table: "QuickSettings"))
            return
        }
        now = clock()
        caffeine = CaffeineSession(start: now, end: end)
        scheduleTick()
    }

    func stopCaffeine() {
        backends.caffeine.release()
        tickTimer?.invalidate()
        tickTimer = nil
        if caffeine != nil { caffeine = nil }
    }

    private func reacquireCaffeine(keepDisplayOn: Bool) {
        guard caffeine != nil else { return }
        if !backends.caffeine.acquire(keepDisplayOn: keepDisplayOn) { stopCaffeine() }
    }

    /// Prochain réveil : la minute suivante (le texte du temps restant change), ou la fin si elle vient avant.
    private func scheduleTick() {
        tickTimer?.invalidate()
        tickTimer = nil
        guard let end = caffeine?.end else { return }
        let current = clock()
        let next = min(end, current.addingTimeInterval(60))
        let timer = Timer(timeInterval: max(0.1, next.timeIntervalSince(current)), repeats: false) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = next == end ? 0.5 : 5
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// Réveil du minuteur (interne, appelé aussi par les tests).
    func tick() {
        now = clock()
        guard let session = caffeine else { return }
        if let end = session.end, now >= end {
            stopCaffeine()
        } else {
            scheduleTick()
        }
    }

    // MARK: - Scènes

    func sceneTargets(for scene: QuickScene) -> SceneTargets {
        switch scene {
        case .autonomy:
            return SceneTargets(lowPower: lowPowerSupported ? true : nil,
                                bluetooth: prefs.autonomyBluetoothOff ? false : nil, caffeine: .off, focus: nil)
        case .presentation:
            let focusOn = prefs.presentationFocus && prefs.shortcut(turningOn: true) != nil
            return SceneTargets(lowPower: lowPowerSupported ? false : nil, bluetooth: nil,
                                caffeine: .on(until: nil), focus: focusOn ? true : nil)
        case .normal:
            guard let snapshot else { return SceneTargets() }
            var caffeine = SceneTargets.Caffeine.off
            if snapshot.caffeine, snapshot.caffeineEnd.map({ $0 > clock() }) ?? true {
                caffeine = .on(until: snapshot.caffeineEnd)
            }
            return SceneTargets(lowPower: lowPowerSupported ? snapshot.lowPower : nil, bluetooth: snapshot.bluetooth,
                                caffeine: caffeine, focus: snapshot.focus)
        }
    }

    /// La scène correspond-elle à l'état réel du Mac ? (Mise en avant de la tuile.)
    func isSceneActive(_ scene: QuickScene) -> Bool {
        guard scene != .normal, let snapshot, snapshot.scene == scene else { return false }
        let targets = sceneTargets(for: scene)
        if let wanted = targets.lowPower, wanted != lowPower { return false }
        if let wanted = targets.bluetooth, let actual = bluetooth, wanted != actual { return false }
        switch targets.caffeine {
        case .off?: if caffeine != nil { return false }
        case .on?: if caffeine == nil { return false }
        case nil: break
        }
        if let wanted = targets.focus, wanted != focus { return false }
        return true
    }

    /// « Normal » ne sert à rien tant qu'aucune scène n'a été appliquée.
    var canRestoreNormal: Bool { snapshot != nil }

    func applyScene(_ scene: QuickScene) {
        guard !busy.contains(.scene) else { return }
        let targets = sceneTargets(for: scene)
        // Le premier accès au Bluetooth peut afficher la demande d'autorisation du système : seulement si la
        // scène y touche (le passage automatique ne doit pas la faire surgir pour rien).
        let touchesBluetooth = scene != .normal && targets.bluetooth != nil
        if touchesBluetooth, bluetooth == nil { refreshBluetooth() }
        var kept = snapshot
        if scene == .normal {
            guard kept != nil else { return }
        } else if let current = kept, isSceneActive(current.scene) {
            // L'état est celui de la dernière scène : on garde l'instantané d'avant la première.
            kept?.scene = scene
            if touchesBluetooth, current.bluetooth == nil { kept?.bluetooth = bluetooth }
        } else {
            // Premier passage, ou réglages changés à la main depuis la dernière scène : « Normal » doit revenir à
            // l'état d'avant cette scène-ci, pas à un instantané ancien. shortcut: un réglage que la scène
            // précédente avait modifié et que l'utilisateur n'a pas touché est repris tel quel.
            kept = SceneSnapshot(scene: scene, lowPower: lowPower, bluetooth: touchesBluetooth ? bluetooth : nil,
                                 caffeine: caffeine != nil, caffeineEnd: caffeine?.end, focus: focus)
        }
        busy.insert(.scene)
        issue = nil
        apply(targets) { [weak self] ok in
            guard let self else { return }
            self.busy.remove(.scene)
            // Autorisation refusée ou fermée : rien n'a changé, l'instantané n'est ni pris ni effacé.
            if ok { self.snapshot = scene == .normal ? nil : kept }
        }
    }

    /// L'écriture qui exige les droits administrateur passe d'abord : si elle échoue, le reste ne bouge pas (pas de
    /// scène à moitié appliquée).
    private func apply(_ targets: SceneTargets, finish: @escaping (Bool) -> Void) {
        func applyRest() {
            if let wanted = targets.bluetooth { setBluetooth(wanted) }
            switch targets.caffeine {
            case .off?: if caffeine != nil { stopCaffeine() }
            case .on(let end)?: if caffeine == nil || caffeine?.end != end { startCaffeine(until: end) }
            case nil: break
            }
            if let wanted = targets.focus, wanted != focus, prefs.shortcut(turningOn: wanted) != nil {
                setFocus(wanted)
            }
            finish(true)
        }
        if let wanted = targets.lowPower, wanted != lowPower {
            setLowPower(wanted) { ok in ok ? applyRest() : finish(false) }
        } else {
            applyRest()
        }
    }

    // MARK: - Autonomie automatique

    /// Une fois par descente : se déclenche quand la batterie passe sous le seuil, sur batterie, hors scène. Il se
    /// réarme quand elle remonte au-dessus du seuil ou que le Mac est branché. Au démarrage sous le seuil, rien :
    /// pas de demande d'autorisation surprise à l'ouverture de la notch.
    private func evaluateAutoSwitch() {
        guard prefs.autoAutonomy, let mac else { return }
        if mac.isPluggedIn || mac.percent > prefs.autoThreshold {
            autoArmed = true
            return
        }
        guard autoArmed else { return }
        autoArmed = false
        guard snapshot == nil, !busy.contains(.scene) else { return }
        applyScene(.autonomy)
    }

    // MARK: - Erreurs

    private enum Subject {
        case wifi, bluetooth, lowPower, grantAuthorization, revokeAuthorization
        case focus(String)
    }

    private func report(_ failure: QuickSettingsFailure, about subject: Subject) {
        let systemSettings = L("Ouvrir Réglages Système", table: "QuickSettings")
        switch subject {
        case .wifi:
            let message: String
            if failure.kind == .denied {
                message = L("Wi-Fi : autorisation refusée.", table: "QuickSettings")
            } else if let detail = failure.detail {
                message = String(format: L("Wi-Fi : %@", table: "QuickSettings"), detail)
            } else {
                message = L("Wi-Fi : changement impossible.", table: "QuickSettings")
            }
            issue = QuickSettingsIssue(message: message, actionTitle: systemSettings, actionURL: SystemPane.wifi)
        case .bluetooth:
            issue = QuickSettingsIssue(
                message: L("Bluetooth : le changement n'a pas eu lieu. Vérifie l'autorisation Bluetooth.",
                           table: "QuickSettings"),
                actionTitle: systemSettings, actionURL: SystemPane.bluetoothPrivacy)
        case .lowPower:
            let message: String
            if failure.kind == .denied {
                message = L("Économie d'énergie : identifiants administrateur refusés.", table: "QuickSettings")
            } else if failure.kind == .timeout {
                message = L("Économie d'énergie : pas de réponse à la demande d'autorisation.", table: "QuickSettings")
            } else if failure.kind == .unchanged {
                message = L("Économie d'énergie : le système n'a pas changé d'état.", table: "QuickSettings")
            } else if let detail = failure.detail {
                message = String(format: L("Économie d'énergie : %@", table: "QuickSettings"), detail)
            } else {
                message = L("Économie d'énergie : changement impossible.", table: "QuickSettings")
            }
            issue = QuickSettingsIssue(message: message, actionTitle: systemSettings, actionURL: SystemPane.battery)
        case .grantAuthorization, .revokeAuthorization:
            let message: String
            if failure.kind == .denied {
                message = L("Autorisation : identifiants administrateur refusés.", table: "QuickSettings")
            } else if failure.kind == .timeout {
                message = L("Autorisation : pas de réponse à la demande d'autorisation.", table: "QuickSettings")
            } else if failure.kind == .invalidUser {
                message = L("Autorisation : nom d'utilisateur non pris en charge.", table: "QuickSettings")
            } else if let detail = failure.detail {
                message = String(format: L("Autorisation : %@", table: "QuickSettings"), detail)
            } else if case .grantAuthorization = subject {
                message = L("Autorisation : installation impossible.", table: "QuickSettings")
            } else {
                message = L("Autorisation : retrait impossible.", table: "QuickSettings")
            }
            issue = QuickSettingsIssue(message: message)
        case .focus(let name):
            let message: String
            if let detail = failure.detail {
                message = String(format: L("Raccourci « %@ » : %@", table: "QuickSettings"), name, detail)
            } else {
                message = String(format: L("Raccourci « %@ » introuvable ou en erreur.", table: "QuickSettings"), name)
            }
            issue = QuickSettingsIssue(message: message, actionTitle: L("Ouvrir Raccourcis", table: "QuickSettings"),
                                       actionURL: SystemPane.shortcuts)
        }
    }

    func dismissIssue() {
        if issue != nil { issue = nil }
    }

    func perform(_ issue: QuickSettingsIssue) {
        if let url = issue.actionURL { open(url) }
    }

    func openURL(_ url: URL) { open(url) }
}
