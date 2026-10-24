import Combine
import SwiftUI

/// Ce que `HookServer` demande au suivi Codex (routes `/codex/hook` et `/codex/permission`). Défini ici pour que le
/// serveur n'ait aucune dépendance sur le module.
protocol CodexRelay: AnyObject {
    /// Événement asynchrone (`/codex/hook`), contexte déjà résolu pendant que le hook était vivant. Tout thread.
    func codexEvent(_ event: HookEvent, context: CodexContext)
    /// Hook `PermissionRequest` synchrone : `reply` reçoit la sortie du hook (JSON) ou nil (204). Tout thread.
    func codexHold(_ event: HookEvent, context: CodexContext, id: UUID, reply: @escaping (Data?) -> Void)
    /// Le hook a fermé sa connexion (réponse donnée au terminal, hook tué). Tout thread.
    func codexConnectionClosed(_ id: UUID)
}

/// État des hooks Codex pour les réglages et l'onglet : posés dans hooks.json ? approuvés dans Codex ? Rien n'est lu avant
/// `refresh()`. Lecture seule, sauf `install()`, `uninstall()` et `approve()`, qui ne partent que d'un clic.
final class CodexHookSetup: ObservableObject {
    static let shared = CodexHookSetup()

    /// Où en est l'utilisateur, dans l'ordre : poser les hooks, les approuver dans Codex, ouvrir une conversation.
    enum Flow: Equatable {
        case notInstalled
        /// hooks.json ou le script diffèrent de ceux de l'app : Codex les considérerait comme modifiés.
        case needsUpdate
        /// `[features] hooks = false` dans config.toml.
        case disabled
        case unreadable(String)
        /// Posés, mais Codex les ignore tant qu'ils ne sont pas approuvés (nombre de hooks concernés).
        case pendingApproval(Int)
        case active
    }

    /// Vérification automatique : au plus toutes les 30 s, et seulement tant que l'approbation est attendue.
    static let checkInterval: TimeInterval = 30

    @Published private(set) var status: CodexHookInstaller.Status = .notInstalled
    @Published private(set) var notes = CodexHookInstaller.ConfigNotes()
    /// Nos hooks que Codex n'exécute pas encore : estimé d'après config.toml, puis confirmé par Codex (`verify`).
    @Published private(set) var unapproved = CodexHookInstaller.events.count
    /// Une demande à Codex est en cours (vérification ou approbation).
    @Published private(set) var isWorking = false
    /// Résultat de la dernière action : succès (sauvegarde comprise) ou raison de l'échec.
    @Published private(set) var message: String?
    @Published private(set) var messageIsError = false

    private let makeInstaller: () -> CodexHookInstaller
    private let makeService: (CodexHookInstaller) -> CodexHooksService?
    private let watchInterval: TimeInterval
    /// Un événement de hook est arrivé : preuve que Codex exécute nos hooks.
    private var provenActive = false
    private var lastCheck: Date?
    private var signature = ""
    private var watchers = 0
    private var timer: Timer?

    init(installer: @escaping () -> CodexHookInstaller = { .standard },
         service: @escaping (CodexHookInstaller) -> CodexHooksService? = CodexHookSetup.standardService,
         watchInterval: TimeInterval = 2.5) {
        makeInstaller = installer
        makeService = service
        self.watchInterval = watchInterval
    }

    /// L'app Codex (ChatGPT) ou la commande `codex` du Mac, jamais sous XCTest : un test ne lance pas le vrai Codex.
    static func standardService(_ installer: CodexHookInstaller) -> CodexHooksService? {
        guard NSClassFromString("XCTestCase") == nil, let executable = CodexBinary.find() else { return nil }
        return CodexAppServer(executable: executable, home: installer.configDirectory)
    }

    var flow: Flow {
        switch status {
        case .notInstalled: return .notInstalled
        case .outdated, .scriptOutdated: return .needsUpdate
        case .unreadable(let detail): return .unreadable(detail)
        case .installed:
            if notes.hooksDisabled { return .disabled }
            return provenActive || unapproved == 0 ? .active : .pendingApproval(unapproved)
        }
    }

    /// Le bouton « Approuver » a un sens : hooks à jour, Codex ne les exécute pas encore.
    var canApprove: Bool {
        if case .pendingApproval = flow { return !isWorking }
        return false
    }

    // MARK: - Lecture (rien n'est modifié)

    func refresh() {
        let installer = makeInstaller()
        status = installer.status()
        notes = installer.configNotes()
        unapproved = installer.unapprovedCount()
        signature = Self.signature(installer)
        updateTimer()
    }

    /// Mise à jour silencieuse du script au lancement (hooks déjà approuvés), onglet Codex activé. hooks.json n'est
    /// pas touché : sa définition fixe le hash de confiance de Codex.
    func updateScriptIfNeeded() {
        refresh()
        guard status == .scriptOutdated else { return }
        try? makeInstaller().updateScript()
        refresh()
    }

    /// Demande à Codex (`hooks/list`) ce qu'il pense de nos hooks. Sans `force` (bouton « Vérifier »), seulement quand
    /// l'approbation est attendue : une fois les hooks actifs, plus aucun processus Codex n'est lancé tout seul.
    func verify(force: Bool = false) {
        guard !isWorking, !provenActive || force, status == .installed else { return }
        if !force {
            guard case .pendingApproval = flow else { return }
            if let last = lastCheck, Date().timeIntervalSince(last) < Self.checkInterval { return }
        }
        let installer = makeInstaller()
        guard let service = makeService(installer) else {
            if force { report(CodexServiceError.noCodex) }
            return
        }
        run(service, installer: installer, approving: false)
    }

    /// Clic explicite sur « Approuver » : Codex marque nos hooks, et seulement les nôtres, comme approuvés
    /// (`config/batchWrite`, la requête du bouton « Review hooks » de l'app). Rien d'autre n'est écrit.
    func approve() {
        guard canApprove, status == .installed else { return }
        let installer = makeInstaller()
        guard let service = makeService(installer) else { return report(CodexServiceError.noCodex) }
        run(service, installer: installer, approving: true)
    }

    private func run(_ service: CodexHooksService, installer: CodexHookInstaller, approving: Bool) {
        isWorking = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try service.hooks(approving: approving ? { installer.isOurs($0) } : nil) }
            DispatchQueue.main.async { [self] in
                isWorking = false
                lastCheck = Date()
                switch result {
                case .failure(let error): report(error)
                case .success(let hooks): apply(hooks, installer: installer, approved: approving)
                }
            }
        }
    }

    /// Ce que Codex dit de nos hooks. S'il n'en voit aucun, hooks.json n'est pas chargé (réglage coupé, fichier refusé) :
    /// on garde l'estimation de config.toml.
    private func apply(_ hooks: [CodexListedHook], installer: CodexHookInstaller, approved: Bool) {
        let ours = hooks.filter(installer.isOurs)
        if ours.isEmpty {
            message = L("Codex ne voit pas les hooks d'Oriel (hooks.json non chargé).", table: "Codex")
            messageIsError = true
            return
        }
        unapproved = max(0, CodexHookInstaller.events.count - ours.filter(\.isTrusted).count)
        if approved {
            let done = unapproved == 0
            message = done ? L("Hooks approuvés. Ouvre une nouvelle conversation Codex pour les voir à l'œuvre.", table: "Codex")
                : String(format: L("Codex n'a pas approuvé %d hooks.", table: "Codex"), unapproved)
            messageIsError = !done
        }
        updateTimer()
    }

    private func report(_ error: Error) {
        message = error.localizedDescription
        messageIsError = true
    }

    /// Un événement de hook vient d'arriver : Codex exécute nos hooks, quoi qu'en dise l'estimation.
    func markActive() {
        guard !provenActive else { return }
        provenActive = true
        unapproved = 0
        updateTimer()
    }

    func forgetProof() {
        provenActive = false
    }

    // MARK: - Veille de l'approbation

    /// Tant qu'une vue est visible et que l'approbation est attendue, config.toml est relu (deux `stat`) toutes les
    /// 2,5 s : l'onglet se met à jour tout seul quand l'utilisateur approuve ailleurs (`/hooks`, app). Rien au repos.
    func watch(_ on: Bool) {
        watchers = max(0, watchers + (on ? 1 : -1))
        updateTimer()
    }

    private func updateTimer() {
        let wanted: Bool
        if watchers > 0, case .pendingApproval = flow { wanted = true } else { wanted = false }
        if wanted, timer == nil {
            let timer = Timer(timeInterval: watchInterval, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = watchInterval / 2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    var isWatching: Bool { timer != nil }

    private func tick() {
        let installer = makeInstaller()
        guard Self.signature(installer) != signature else { return }
        refresh()
        verify()
    }

    /// Taille et date de hooks.json et config.toml.
    private static func signature(_ installer: CodexHookInstaller) -> String {
        [installer.hooksURL, installer.configURL].map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return "\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)/\(attributes?[.size] as? Int ?? 0)"
        }.joined(separator: "|")
    }

    // MARK: - Actions de l'utilisateur

    func install() {
        perform { installer in
            let outcome = try installer.install()
            forgetProof()
            return outcome.backup.map { String(format: L("Hooks posés. Sauvegarde : %@", table: "Codex"), $0.lastPathComponent) }
                ?? L("Hooks posés.", table: "Codex")
        }
        lastCheck = nil
        verify()
    }

    func uninstall() {
        perform { installer in
            let outcome = try installer.uninstall()
            forgetProof()
            return outcome.fileChanged ? L("Hooks retirés.", table: "Codex") : L("Rien à retirer.", table: "Codex")
        }
    }

    private func perform(_ action: (CodexHookInstaller) throws -> String) {
        do {
            message = try action(makeInstaller())
            messageIsError = false
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
        refresh()
    }
}

extension Preferences {
    /// Premier lancement avec cet onglet : activé seulement si Codex est sur ce Mac, puis jamais modifié tout seul
    /// (même règle que l'onglet Claude).
    func decideCodexTab(codexPresent: () -> Bool) {
        guard tabEnabled[ModuleRegistry.codexId] == nil else { return }
        tabEnabled[ModuleRegistry.codexId] = codexPresent()
    }
}

/// Onglet « Codex » : les sessions de l'agent de code d'OpenAI, suivies grâce aux hooks de Codex (`~/.codex/hooks.json`),
/// et ses demandes d'approbation, auxquelles on peut répondre depuis la notch. Optionnel comme l'onglet Claude : activé
/// d'office seulement si Codex est détecté, aucun travail de fond une fois désactivé.
final class CodexModule: NotchModule {
    static let replyKey = "codex.replyFromNotch"
    static let quotaKey = "codex.showQuota"

    let id = ModuleRegistry.codexId
    let title = "Codex"
    let symbol = "chevron.left.forwardslash.chevron.right"

    let store: CodexStore
    let approvals: CodexApprovals
    let setup: CodexHookSetup
    /// Quota du compte ChatGPT : lu par Codex, seulement panneau ouvert (voir `CodexUsageStore`).
    let usage: CodexUsageStore
    private let defaults: UserDefaults

    /// « Approuver depuis la notch » : coupé par défaut ; coupé, les demandes sont rendues tout de suite à Codex.
    @Published var replyFromNotch: Bool {
        didSet {
            defaults.set(replyFromNotch, forKey: Self.replyKey)
            if !replyFromNotch { approvals.releaseAll() }
        }
    }

    /// Jauge de quota dans l'onglet : allumée par défaut (rien à installer, une lecture par Codex lui-même) ; éteinte, aucun
    /// processus Codex n'est lancé pour elle.
    @Published var showsQuota: Bool {
        didSet {
            defaults.set(showsQuota, forKey: Self.quotaKey)
            if !showsQuota { usage.forget() } else if isStarted { usage.start() }
        }
    }

    /// Dernier événement de hook reçu (preuve que les hooks sont validés dans Codex).
    @Published private(set) var lastEventAt: Date?

    /// Posées par `NotchController` : ramener l'app hôte devant (ou ouvrir le lien profond de la session) et refermer le
    /// panneau, ouvrir les réglages.
    var openHost: (String?, URL?) -> Void = { _, _ in }
    var openSettings: () -> Void = {}

    private var cancellables = Set<AnyCancellable>()
    /// Entre `start()` et `stop()` : le panneau est ouvert.
    private var isStarted = false

    init(store: CodexStore = CodexStore(), approvals: CodexApprovals = CodexApprovals(), setup: CodexHookSetup = .shared,
         usage: CodexUsageStore = CodexUsageStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.approvals = approvals
        self.setup = setup
        self.usage = usage
        self.defaults = defaults
        replyFromNotch = defaults.bool(forKey: Self.replyKey)
        showsQuota = defaults.object(forKey: Self.quotaKey) as? Bool ?? true
        approvals.isEnabled = { [weak self] in self?.replyFromNotch ?? false }
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        approvals.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    // MARK: - Contrat du module

    /// Décidé au premier lancement (`Preferences.decideCodexTab`) : activé seulement si Codex est détecté.
    var isEnabledByDefault: Bool { false }

    /// Sans activité, rien ne tourne panneau replié : seul le serveur de hooks écoute (port déjà ouvert).
    var keepsRunningWhenCollapsed: Bool { store.hasActivity }

    /// Alerte (approbation attendue) > travail en cours > « terminé » (5 s). Seul le module qui tourne en a.
    var ears: ModuleEars? {
        switch store.indicator {
        case .attention:
            let waiting = store.liveSessions.filter { $0.phase == .waitingApproval }.count
            return ModuleEars(symbol: "hand.raised.fill", text: "\(waiting)", priority: 9, alert: true)
        case .working:
            return ModuleEars(symbol: symbol, text: "\(store.activeCount)", priority: 6)
        case .done:
            return ModuleEars(symbol: "checkmark.circle.fill", text: "✓", priority: 6)
        case .none:
            return nil
        }
    }

    /// Une approbation attend l'utilisateur : le panneau s'ouvre sur cet onglet (si Claude n'a rien à dire).
    var needsAttention: Bool { store.indicator == .attention }

    func start() {
        isStarted = true
        // hooks.json et config.toml ont pu changer depuis (Codex, l'utilisateur).
        setup.refresh()
        setup.watch(true)
        setup.verify()
        if showsQuota { usage.start() }
    }

    func stop() {
        isStarted = false
        setup.watch(false)
        usage.stop()
    }

    func makeView() -> AnyView {
        AnyView(CodexPanel(module: self, store: store, approvals: approvals, setup: setup, usage: usage))
    }

    func makeCompactView() -> AnyView? {
        AnyView(CodexCompactView(module: self, store: store, approvals: approvals, usage: usage))
    }

    func makeSettingsView() -> AnyView? {
        AnyView(CodexSettingsView(module: self, setup: setup))
    }

    func makeTabIcon() -> AnyView? {
        AnyView(CodexTabIcon(store: store))
    }

    // MARK: - Suivi (onglet activé ou non)

    /// Onglet activé : les événements sont suivis. Désactivé : sessions oubliées, minuterie et surveillance des
    /// processus arrêtées, demandes tenues rendues à Codex (le terminal pose sa question).
    func setTracking(_ isOn: Bool) {
        if isOn {
            store.start()
        } else {
            approvals.releaseAll()
            store.stop()
            usage.forget()
            lastEventAt = nil
            setup.forgetProof()
        }
    }

    /// Clic dans une carte d'approbation : la décision part au hook.
    func decide(_ request: CodexApprovals.Request, _ decision: CodexApprovals.Decision) {
        guard approvals.decide(request, decision) else { return }
        if decision != .terminal { store.resolveApproval(request.sessionId) }
    }

    func activate(_ session: CodexSession) {
        openHost(session.hostBundleId, Self.deepLink(for: session))
    }

    /// L'app Codex (ChatGPT) ouvre une conversation par `codex://threads/<id>` ; l'id de session des hooks est celui du
    /// fil. Ailleurs (terminal, éditeur), pas de lien : on ramène l'app hôte devant.
    static func deepLink(for session: CodexSession) -> URL? {
        guard session.hostBundleId == CodexBinary.appBundleId, UUID(uuidString: session.id) != nil else { return nil }
        return URL(string: "codex://threads/\(session.id.lowercased())")
    }

    var debugInfo: [String: Any] {
        let sessions: [[String: Any]] = store.sortedSessions.map { session in
            var item: [String: Any] = [
                "id": session.id,
                "project": session.projectName,
                "phase": String(describing: session.phase),
                "inTurn": session.inTurn,
                "toolCount": session.toolCount,
            ]
            item["host"] = session.hostName
            item["model"] = session.model
            item["pid"] = session.pid.map { Int($0) }
            return item
        }
        var info: [String: Any] = [
            "sessions": sessions,
            "indicator": String(describing: store.indicator),
            "timer": store.isTicking,
            "replyFromNotch": replyFromNotch,
            "approvals": approvals.debugInfo,
            "showsQuota": showsQuota,
        ]
        info["quota"] = usage.snapshot.map { snapshot in
            snapshot.windows.map { ["percent": $0.usedPercent, "minutes": $0.minutes ?? 0] }
        }
        info["lastEventAt"] = lastEventAt.map { ISO8601DateFormatter().string(from: $0) }
        return info
    }
}

extension CodexModule: CodexRelay {
    func codexEvent(_ event: HookEvent, context: CodexContext) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            store.handle(event, context: context)
            approvals.observe(event)
            lastEventAt = Date()
            setup.markActive()
        }
    }

    func codexHold(_ event: HookEvent, context: CodexContext, id: UUID, reply: @escaping (Data?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let sessionId = event.sessionId, let name = event.toolName else { return reply(nil) }
            // La session attend une décision, dans la notch ou, sinon, dans le terminal.
            store.markWaiting(sessionId: sessionId, tool: CodexTools.describe(name: name, input: event.toolInput),
                              context: context, cwd: event.cwd)
            lastEventAt = Date()
            setup.markActive()
            approvals.hold(event, id: id, reply: reply)
        }
    }

    func codexConnectionClosed(_ id: UUID) {
        DispatchQueue.main.async { [weak self] in self?.approvals.connectionClosed(id) }
    }
}
