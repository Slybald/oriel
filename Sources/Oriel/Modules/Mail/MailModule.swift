import AppKit
import SwiftUI

/// Onglet « Mail » : le nombre de messages non lus d'Apple Mail et les 3 à 5 derniers mails reçus (expéditeur, objet,
/// début du texte, heure), avec une réponse rapide. Désactivé par défaut. Textes dans Resources/{en,fr}.lproj/Mail.strings ; réglages dans UserDefaults sous
/// « mail.… ».
///
/// - Mail n'a pas d'API de lecture hors AppleScript (autorisation « Automatisation », demandée par macOS au premier
///   script). Oriel ne lance JAMAIS Mail : le script vérifie d'abord que Mail tourne, et le module ne lance
///   rien non plus quand Mail est fermé.
/// - Au repos : rien tant que l'onglet est désactivé. Activé et replié (après une première lecture réussie,
///   `armed`) : un observateur de lancement / arrêt de Mail, et seulement tant que Mail tourne un script de
///   compteur toutes les 2 minutes ; la liste n'est lue que panneau ouvert. Mail fermé : aucun minuteur.
/// - Une réponse ne part QUE sur `sendReply()`, appelé par le clic sur « Envoyer » ou Entrée dans le champ : jamais
///   à l'ouverture du champ, ni à un rafraîchissement, ni à la fermeture. Le texte tapé reste en mémoire.
/// - Aucune autorisation n'est demandée avant l'ouverture de l'onglet, et alors sur un clic de « Autoriser ».
///   Rien n'est enregistré ni envoyé hors du Mac.
final class MailModule: NotchModule {
    let id = "mail"
    let symbol = "envelope"
    var title: String { L("Mail", table: "Mail") }
    var isEnabledByDefault: Bool { false }

    /// Sous Messages (0) : une pastille de plus ne doit pas passer avant une conversation.
    static let earsPriority = -1
    static let pollInterval: TimeInterval = 120
    /// Combien de derniers mails reçus l'onglet montre (réglage, 5 par défaut).
    static let recentRange = 3...5
    static let defaultRecent = 5
    /// Assez long pour que l'utilisateur réponde à la fenêtre d'autorisation de macOS, et pour une boîte lente.
    static let replyTimeout: TimeInterval = 60
    static let sentFlash: TimeInterval = 2.5

    // MARK: État

    @Published private(set) var state: MailState = .unknown
    @Published private(set) var unread = 0
    @Published private(set) var messages: [MailMessage] = []
    /// La liste a été lue au moins une fois depuis l'ouverture de l'onglet : avant, l'onglet attend au lieu de
    /// montrer une boîte vide.
    @Published private(set) var listLoaded = false

    // MARK: Réponse en cours

    /// Le mail auquel on répond ; son champ est ouvert sous sa ligne. Gardé hors de `messages` : une relecture de la
    /// liste ne doit pas faire disparaître un message pendant qu'on lui écrit.
    @Published private(set) var replyTarget: MailMessage?
    @Published var draft = ""
    @Published private(set) var replyState: MailReplyState = .idle

    // MARK: Réglages

    @Published var showBadge: Bool { didSet { defaults.set(showBadge, forKey: Key.badge) } }
    /// Expéditeur et objet dans la liste ; coupé, seul le nombre reste (écran partagé).
    @Published var showSubjects: Bool { didSet { defaults.set(showSubjects, forKey: Key.subjects) } }
    /// 3 à 5 ; une valeur hors bornes (réglage édité à la main) est ramenée dans les bornes.
    @Published var recentCount: Int {
        didSet {
            let clamped = Self.clampedCount(recentCount)
            if clamped != recentCount { recentCount = clamped; return }
            defaults.set(recentCount, forKey: Key.count)
            if oldValue != recentCount, isStarted, openViews > 0 { refresh() }
        }
    }

    private enum Key {
        static let badge = "mail.showBadge"
        static let subjects = "mail.showSubjects"
        static let count = "mail.recentCount"
        static let armed = "mail.armed"
    }

    private let defaults: UserDefaults
    private let runner: AppleScriptRunner
    private let probe: AutomationProbe
    private let isMailRunning: () -> Bool
    private let workspace: NotificationCenter
    private let scheduler: ModuleScheduler
    private let clock: () -> Date
    private let openURL: (URL) -> Void

    private var isStarted = false
    /// Vues de l'onglet à l'écran : la liste n'est lue que si le panneau est ouvert.
    private var openViews = 0
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var cancelPoll: (() -> Void)?
    private var cancelSentFlash: (() -> Void)?

    init(defaults: UserDefaults = .standard,
         runner: AppleScriptRunner = ModuleEnvironment.isTesting ? InertAppleScriptRunner() : OsascriptRunner(),
         probe: AutomationProbe = SystemAutomationProbe(),
         isMailRunning: @escaping () -> Bool = {
             !ModuleEnvironment.isTesting
                 && !NSRunningApplication.runningApplications(withBundleIdentifier: MailScript.bundleIdentifier).isEmpty
         },
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter, scheduler: ModuleScheduler = .system,
         clock: @escaping () -> Date = Date.init, openURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.runner = runner
        self.probe = probe
        self.isMailRunning = isMailRunning
        self.workspace = workspace
        self.scheduler = scheduler
        self.clock = clock
        self.openURL = openURL
        showBadge = defaults.object(forKey: Key.badge) as? Bool ?? true
        showSubjects = defaults.object(forKey: Key.subjects) as? Bool ?? true
        recentCount = Self.clampedCount(defaults.object(forKey: Key.count) as? Int ?? Self.defaultRecent)
    }

    private static func clampedCount(_ count: Int) -> Int {
        min(max(count, recentRange.lowerBound), recentRange.upperBound)
    }

    deinit {
        cancelPoll?()
        cancelSentFlash?()
        observers.forEach(workspace.removeObserver)
    }

    /// Un script a déjà réussi : seulement alors le module tourne replié et peut interroger Mail sans demander.
    private var armed: Bool {
        get { defaults.bool(forKey: Key.armed) }
        set { defaults.set(newValue, forKey: Key.armed) }
    }

    // MARK: Contrat

    var keepsRunningWhenCollapsed: Bool { showBadge && armed }

    var ears: ModuleEars? {
        guard showBadge, state == .ready, unread > 0 else { return nil }
        return ModuleEars(symbol: "envelope.fill", text: unread > 99 ? "99+" : String(unread), priority: Self.earsPriority)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observeMail()
        refresh()
    }

    func stop() {
        isStarted = false
        generation += 1
        openViews = 0
        cancelPoll?()
        cancelPoll = nil
        observers.forEach(workspace.removeObserver)
        observers = []
        messages = []
        listLoaded = false
        resetReply()
    }

    func makeView() -> AnyView { AnyView(MailPanel(module: self)) }
    func makeCompactView() -> AnyView? { state == .ready && unread > 0 ? AnyView(MailCompactView(module: self)) : nil }
    func makeSettingsView() -> AnyView? { AnyView(MailSettingsView(module: self)) }
    func makeHeaderAccessory() -> AnyView? { AnyView(MailRefreshButton(module: self)) }

    // MARK: Lecture

    /// Mail se lance ou se ferme : on relit tout de suite (et seulement alors, hors du rythme de 2 minutes).
    private func observeMail() {
        guard observers.isEmpty else { return }
        func isMail(_ note: Notification) -> Bool {
            (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                == MailScript.bundleIdentifier
        }
        observers.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                               queue: .main) { [weak self] note in
            // Mail vient d'apparaître : on lui laisse le temps de répondre aux événements.
            if isMail(note) { _ = self?.scheduler.after(2) { self?.refresh() } }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                               queue: .main) { [weak self] note in
            if isMail(note) { self?.refresh() }
        })
    }

    /// `interactive` : un clic de l'utilisateur, la seule situation où macOS peut poser sa question d'autorisation.
    func refresh(interactive: Bool = false) {
        guard isStarted else { return }
        generation += 1
        cancelPoll?()
        cancelPoll = nil
        guard isMailRunning() else {
            unread = 0
            messages = []
            listLoaded = false
            state = .notRunning
            return
        }
        switch probe.status(of: MailScript.bundleIdentifier) {
        case .denied:
            armed = false
            state = .denied
            return
        case .notDetermined where !interactive && !armed:
            state = .needsPermission
            return
        default:
            break
        }
        // Texte masqué dans les réglages : on ne lit même pas le début des messages.
        let wantsList = openViews > 0 && showSubjects
        let current = generation
        runner.run(MailScript.source, arguments: [String(wantsList ? recentCount : 0)],
                   timeout: interactive ? 60 : 20) { [weak self] result in
            guard let self, isStarted, current == generation else { return }
            apply(result, wantsList: wantsList)
        }
    }

    private func apply(_ result: Result<String, AppleScriptFailure>, wantsList: Bool) {
        switch result {
        case .success(let output):
            switch MailScript.parse(output, now: clock()) {
            case .notRunning?:
                unread = 0
                messages = []
                listLoaded = false
                state = .notRunning
            case .reading(let reading)?:
                unread = reading.unread
                if wantsList {
                    messages = pinningReplyTarget(Array(reading.messages.prefix(recentCount)))
                    listLoaded = true
                }
                armed = true
                state = reading.accounts == 0 ? .noAccount : .ready
            case nil:
                state = .failed
            }
        case .failure(.notAuthorized):
            armed = false
            state = .denied
        case .failure:
            state = .failed
        }
        schedulePoll()
    }

    /// Le mail auquel on écrit reste dans la liste même si de nouveaux mails l'ont fait sortir des derniers reçus.
    private func pinningReplyTarget(_ list: [MailMessage]) -> [MailMessage] {
        guard let target = replyTarget, !list.contains(where: { $0.id == target.id }) else { return list }
        return (list + [target]).sorted { $0.date > $1.date }
    }

    /// Un seul rendez-vous à la fois, et seulement tant que Mail tourne et répond.
    private func schedulePoll() {
        cancelPoll?()
        cancelPoll = nil
        guard isStarted, state == .ready else { return }
        cancelPoll = scheduler.after(Self.pollInterval) { [weak self] in
            self?.cancelPoll = nil
            self?.refresh()
        }
    }

    // MARK: Vues

    func tabAppeared() {
        openViews += 1
        refresh()
    }

    func tabDisappeared() {
        openViews = max(0, openViews - 1)
    }

    // MARK: Réponse

    /// Ouvre (ou ferme, si c'est déjà lui) le champ de réponse sous un mail. N'envoie rien.
    func beginReply(_ message: MailMessage) {
        guard replyState != .sending, !message.id.isEmpty else { return }
        if replyTarget?.id == message.id { return resetReply() }
        resetReply()
        replyTarget = message
    }

    /// Échap : ferme le champ et jette le texte. Sans effet pendant un envoi (on veut voir son issue).
    func cancelReply() {
        guard replyState != .sending else { return }
        resetReply()
    }

    /// LE seul chemin d'envoi : clic sur « Envoyer » ou Entrée dans le champ. Texte vide : rien.
    func sendReply() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        runReply(text: text, send: true)
    }

    /// « Ouvrir dans Mail » : la fenêtre de réponse de Mail s'ouvre avec le texte déjà tapé, rien n'est envoyé.
    func openReplyInMail() {
        runReply(text: draft.trimmingCharacters(in: .whitespacesAndNewlines), send: false)
    }

    private func runReply(text: String, send: Bool) {
        guard let target = replyTarget, replyState != .sending else { return }
        // Mail s'est fermé depuis : le script ne s'exécute même pas, il n'y a pas de quoi le relancer par mégarde.
        guard isMailRunning() else {
            replyState = .failed(.notRunning)
            return
        }
        replyState = .sending
        cancelSentFlash?()
        cancelSentFlash = nil
        runner.run(MailScript.replySource, arguments: [target.id, text, send ? "send" : "draft"],
                   timeout: Self.replyTimeout) { [weak self] result in
            guard let self, isStarted, replyTarget?.id == target.id else { return }
            if let failure = MailScript.replyFailure(result) {
                replyState = .failed(failure)
            } else if send {
                draft = ""
                replyState = .sent
                cancelSentFlash = scheduler.after(Self.sentFlash) { [weak self] in
                    self?.cancelSentFlash = nil
                    if self?.replyState == .sent { self?.resetReply() }
                }
            } else {
                resetReply()
            }
        }
    }

    private func resetReply() {
        cancelSentFlash?()
        cancelSentFlash = nil
        replyTarget = nil
        draft = ""
        replyState = .idle
    }

    // MARK: Actions

    /// Clic sur « Autoriser » : le premier script fait poser la question par macOS.
    func authorize() { refresh(interactive: true) }
    func openMessage(_ message: MailMessage) { openURL(message.openURL ?? MailScript.appURL) }
    func openMail() { openURL(MailScript.appURL) }
    func openPrivacy(_ pane: PrivacyPane) { openURL(pane.url) }
}
