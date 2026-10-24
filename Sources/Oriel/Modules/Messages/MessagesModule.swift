import AppKit
import SwiftUI

/// Onglet « Messages » : les conversations récentes d'iMessage / SMS, la pastille de non-lus dans les oreilles et
/// une réponse rapide. Désactivé par défaut. Textes dans Resources/{en,fr}.lproj/Messages.strings ; réglages dans
/// UserDefaults sous « messages.… ».
///
/// - Lecture seule de `~/Library/Messages/chat.db` (`MessagesDatabase`) : exige l'Accès complet au disque, que macOS
///   ne propose pas par une fenêtre. L'absence d'accès est détectée et expliquée dans l'onglet.
/// - Au repos : rien tant que l'onglet est désactivé. Activé et replié, le module ne tourne que s'il a déjà pu lire
///   la base (`armed`) et si la pastille est permise ; il ne fait alors qu'écouter les changements de `chat.db` et
///   de `chat.db-wal` (FSEvents) et relire quand ils changent. Aucun minuteur.
/// - Aucune autorisation n'est demandée avant l'ouverture de l'onglet : Contacts sur un clic de « Autoriser »,
///   Automatisation au premier envoi. Rien n'est écrit sur disque ni envoyé hors du Mac.
final class MessagesModule: NotchModule {
    let id = "messages"
    let symbol = "message"
    var title: String { L("Messages", table: "Messages") }
    var isEnabledByDefault: Bool { false }

    /// Sous le Lecteur (1) et le minuteur (5) ; Claude passe devant (règle des oreilles).
    static let earsPriority = 0
    /// `chat.db` et son journal : Messages écrit dans le second, qui ne change pas le dossier.
    static let watchedFiles: Set<String> = ["chat.db", "chat.db-wal"]
    static let appURL = URL(fileURLWithPath: "/System/Applications/Messages.app")

    enum SendState: Equatable {
        case idle
        case sending
        case sent
        case failed(AppleScriptFailure)
    }

    typealias Async = (@escaping () -> Void) -> Void

    // MARK: État

    @Published private(set) var access: MessagesAccess = .unknown
    @Published private(set) var threads: [MessageThread] = []
    @Published private(set) var unread = 0
    @Published private(set) var contactsAccess: ContactsAccess = .notDetermined
    /// Conversation ouverte pour répondre ; une seule à la fois.
    @Published private(set) var composing: String?
    @Published var draft = ""
    @Published private(set) var sendState: SendState = .idle

    // MARK: Réglages

    /// Pastille de non-lus dans les oreilles de la notch repliée.
    @Published var showBadge: Bool { didSet { defaults.set(showBadge, forKey: Key.badge) } }
    /// Texte des messages dans la liste ; coupé, seuls le nom et l'heure restent (écran partagé).
    @Published var showText: Bool {
        didSet {
            defaults.set(showText, forKey: Key.text)
            rebuild()
        }
    }
    @Published var contactsHintDismissed: Bool { didSet { defaults.set(contactsHintDismissed, forKey: Key.hint) } }

    private enum Key {
        static let badge = "messages.showBadge"
        static let text = "messages.showText"
        static let hint = "messages.contactsHintDismissed"
        static let armed = "messages.armed"
    }

    private let defaults: UserDefaults
    private let database: MessagesDatabase
    private let contacts: ContactNames
    private let watcher: ChangeWatcher
    private let sender: MessageSender
    private let scheduler: ModuleScheduler
    private let clock: () -> Date
    private let background: Async
    private let main: Async
    private let openURL: (URL) -> Void
    private let directory: String

    private var rows: [ThreadRow] = []
    private var book: ContactBook?
    private var isStarted = false
    private var watching = false
    /// Une lecture plus récente rend les précédentes caduques.
    private var generation = 0
    private var cancelSentReset: (() -> Void)?

    init(defaults: UserDefaults = .standard, database: MessagesDatabase = ModuleEnvironment.isTesting ? InertMessagesDatabase() : SQLiteMessagesDatabase(),
         contacts: ContactNames = SystemContacts(), watcher: ChangeWatcher = FSEventsWatcher(),
         sender: MessageSender = AppleScriptMessageSender(
             runner: ModuleEnvironment.isTesting ? InertAppleScriptRunner() : OsascriptRunner()), scheduler: ModuleScheduler = .system,
         clock: @escaping () -> Date = Date.init,
         background: @escaping Async = { DispatchQueue.global(qos: .utility).async(execute: $0) },
         main: @escaping Async = { DispatchQueue.main.async(execute: $0) },
         openURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
         directory: String = (SQLiteMessagesDatabase.defaultPath as NSString).deletingLastPathComponent) {
        self.defaults = defaults
        self.database = database
        self.contacts = contacts
        self.watcher = watcher
        self.sender = sender
        self.scheduler = scheduler
        self.clock = clock
        self.background = background
        self.main = main
        self.openURL = openURL
        self.directory = directory
        showBadge = defaults.object(forKey: Key.badge) as? Bool ?? true
        showText = defaults.object(forKey: Key.text) as? Bool ?? true
        contactsHintDismissed = defaults.bool(forKey: Key.hint)
    }

    deinit { watcher.stop() }

    /// La base a déjà pu être lue une fois : seulement alors le module tourne sans que l'onglet soit ouvert.
    private var armed: Bool {
        get { defaults.bool(forKey: Key.armed) }
        set { defaults.set(newValue, forKey: Key.armed) }
    }

    // MARK: Contrat

    /// Replié, tant que la pastille est permise et que l'accès a déjà fonctionné : l'écoute des fichiers suffit.
    var keepsRunningWhenCollapsed: Bool {
        guard showBadge else { return false }
        switch access {
        case .ready: return true
        case .unknown: return armed
        case .needsFullDiskAccess, .noDatabase, .unsupported: return false
        }
    }

    var ears: ModuleEars? {
        guard showBadge, access == .ready, unread > 0 else { return nil }
        return ModuleEars(symbol: "message.fill", text: unread > 99 ? "99+" : String(unread),
                          priority: Self.earsPriority)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        refresh()
    }

    func stop() {
        isStarted = false
        generation += 1
        stopWatching()
        cancelSentReset?()
        cancelSentReset = nil
        book = nil
        contacts.release()
        composing = nil
        draft = ""
        sendState = .idle
    }

    func makeView() -> AnyView { AnyView(MessagesPanel(module: self)) }
    func makeCompactView() -> AnyView? { unread > 0 ? AnyView(MessagesCompactView(module: self)) : nil }
    func makeSettingsView() -> AnyView? { AnyView(MessagesSettingsView(module: self)) }

    // MARK: Lecture

    /// Relit la base hors du main thread. Appelé au démarrage, à l'ouverture de l'onglet et quand `chat.db` change.
    func refresh() {
        guard isStarted else { return }
        generation += 1
        let current = generation
        let now = clock()
        background { [database] in
            let result = database.read(now: now)
            self.main {
                guard self.isStarted, current == self.generation else { return }
                self.apply(result)
            }
        }
    }

    private func apply(_ result: MessagesRead) {
        switch result {
        case .snapshot(let snapshot):
            rows = snapshot.rows
            unread = snapshot.unread
            armed = true
            access = .ready
            rebuild()
            startWatching()
        case .unavailable(let state):
            rows = []
            threads = []
            unread = 0
            // Accès retiré ou jamais accordé : le module ne tourne plus replié tant que l'onglet n'a pas rouvert.
            armed = false
            access = state
            stopWatching()
        }
    }

    private func startWatching() {
        guard !watching else { return }
        watching = true
        watcher.start(directory: directory, fileNames: Self.watchedFiles) { [weak self] in self?.refresh() }
    }

    private func stopWatching() {
        guard watching else { return }
        watching = false
        watcher.stop()
    }

    // MARK: Contacts

    /// Appelé quand la vue de l'onglet s'affiche : données fraîches, état de l'autorisation, noms si elle est donnée.
    func tabAppeared() {
        refreshContactsAccess()
        if contactsAccess == .granted, book == nil { loadContacts() }
        refresh()
    }

    /// Relit l'état sans rien demander (Réglages › Messages l'affiche).
    func refreshContactsAccess() {
        contactsAccess = contacts.access
    }

    /// Clic sur « Autoriser » : seul moment où macOS pose la question des contacts.
    func requestContacts() {
        contacts.requestAccess { [weak self] access in
            guard let self else { return }
            contactsAccess = access
            if access == .granted { loadContacts() }
        }
    }

    private func loadContacts() {
        contacts.load { [weak self] book in
            guard let self, isStarted else { return }
            self.book = book
            rebuild()
        }
    }

    // MARK: Liste

    private func rebuild() {
        threads = rows.map(makeThread)
    }

    private func makeThread(_ row: ThreadRow) -> MessageThread {
        MessageThread(id: row.guid, title: title(of: row), snippet: snippet(of: row), date: row.date,
                      unread: row.unread, fromMe: row.fromMe, isGroup: row.isGroup, openURL: Self.openURL(for: row))
    }

    private func name(for handle: String) -> String { book?.name(for: handle) ?? handle }

    private func title(of row: ThreadRow) -> String {
        guard row.isGroup else { return name(for: row.identifier) }
        if !row.displayName.isEmpty { return row.displayName }
        guard !row.participants.isEmpty else { return L("Groupe", table: "Messages") }
        let names = row.participants.prefix(3).map(name(for:)).joined(separator: ", ")
        return row.participants.count > 3 ? names + "…" : names
    }

    private func snippet(of row: ThreadRow) -> String {
        guard showText else { return "" }
        let text = row.text.isEmpty ? (row.hasAttachment ? L("Pièce jointe", table: "Messages") : "") : row.text
        return row.fromMe && !text.isEmpty ? String(format: L("Vous : %@", table: "Messages"), text) : text
    }

    /// Un contre un : `imessage://` (ou `sms://`) ouvre la conversation dans Messages. Un groupe n'a pas de lien.
    static func openURL(for row: ThreadRow) -> URL? {
        guard !row.isGroup, !row.identifier.isEmpty,
              let handle = row.identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "\(row.guid.hasPrefix("SMS;") ? "sms" : "imessage")://\(handle)")
    }

    // MARK: Réponse rapide

    func select(_ id: String?) {
        composing = composing == id ? nil : id
        draft = ""
        sendState = .idle
        cancelSentReset?()
    }

    func sendDraft() {
        guard let guid = composing, sendState != .sending else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sendState = .sending
        sender.send(text, toChat: guid) { [weak self] result in
            guard let self, composing == guid else { return }
            switch result {
            case .success:
                draft = ""
                sendState = .sent
                cancelSentReset = scheduler.after(3) { [weak self] in
                    if self?.sendState == .sent { self?.sendState = .idle }
                }
                _ = scheduler.after(1.5) { [weak self] in self?.refresh() }
            case .failure(let failure):
                sendState = .failed(failure)
            }
        }
    }

    // MARK: Ouvertures

    func openConversation(_ thread: MessageThread) { openURL(thread.openURL ?? Self.appURL) }
    func openMessagesApp() { openURL(Self.appURL) }
    func openPrivacy(_ pane: PrivacyPane) { openURL(pane.url) }
}
