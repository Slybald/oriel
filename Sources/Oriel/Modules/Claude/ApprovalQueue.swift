import Combine
import Foundation

/// Une demande de permission que le clavier peut régler : un outil, à autoriser ou à refuser. Les questions et les
/// plans demandent un choix ou un texte : ils restent à la souris.
struct ApprovalEntry: Equatable {
    let id: UUID
    let received: Date
}

/// Une file de demandes (Claude, Codex) et la façon de les régler.
struct ApprovalSource {
    /// Onglet de la notch qui montre ses cartes.
    let tab: String
    /// Demandes en attente dans l'ordre d'arrivée ; émet la nouvelle liste à chaque changement.
    let entries: AnyPublisher<[ApprovalEntry], Never>
    /// Règle la demande : passe par le `decide` du module, comme un clic sur le bouton.
    let decide: (UUID, _ allow: Bool) -> Void
}

extension ApprovalSource {
    static func claude(_ module: ClaudeModule) -> ApprovalSource {
        ApprovalSource(
            tab: ModuleRegistry.claudeId,
            entries: module.replies.$requests.map { requests in
                requests.compactMap { request in
                    guard case .permission = request.kind else { return nil }
                    return ApprovalEntry(id: request.id, received: request.received)
                }
            }.eraseToAnyPublisher(),
            decide: { [weak module] id, allow in
                guard let module, let request = module.replies.requests.first(where: { $0.id == id }) else { return }
                module.decide(request, allow ? .allow : .deny(""))
            })
    }

    static func codex(_ module: CodexModule) -> ApprovalSource {
        ApprovalSource(
            tab: ModuleRegistry.codexId,
            entries: module.approvals.$requests.map { requests in
                requests.map { ApprovalEntry(id: $0.id, received: $0.received) }
            }.eraseToAnyPublisher(),
            decide: { [weak module] id, allow in
                guard let module, let request = module.approvals.requests.first(where: { $0.id == id }) else { return }
                module.decide(request, allow ? .allow : .deny)
            })
    }
}

/// « Approuver au clavier » : ⌃⌥Y autorise et ⌃⌥N refuse la demande la plus ancienne, tous agents confondus.
///
/// Une touche ne décide que si la carte est à l'écran, a les touches (c'est la plus ancienne) et y est depuis au
/// moins `guardDelay` : un réflexe ou un appui répété ne règle jamais une demande qu'on n'a pas lue.
/// - Carte pas à l'écran (panneau fermé, autre onglet) : le premier appui la montre (`reveal`), il ne décide rien.
/// - Dès qu'une demande est réglée, la suivante reprend sa garde à zéro : jamais deux décisions d'un coup.
/// - Les deux combinaisons ne sont prises à personne qu'en présence d'une demande ; réglage éteint par défaut.
/// Les décisions passent par `ClaudeModule.decide` et `CodexModule.decide`, comme un clic : rien ne part sans appui,
/// jamais de « toujours autoriser », les échéances et « la première réponse gagne » ne changent pas. Main thread.
final class ApprovalQueue: ObservableObject {
    static let shared = ApprovalQueue(prefs: .shared)
    /// Temps minimal pendant lequel la carte qui a les touches est à l'écran avant qu'une touche décide.
    static let guardDelay: TimeInterval = 1

    /// La demande qui a les touches ; sa carte les affiche.
    @Published private(set) var keyedId: UUID?
    /// Demandes en file : « 1 sur 3 ».
    @Published private(set) var count = 0
    /// Combinaison réellement prise (macOS la refuse si une autre app l'a déjà) : sinon la carte n'affiche pas la touche.
    @Published private(set) var approveLive = false
    @Published private(set) var denyLive = false

    /// Montre la carte de l'onglet (ouvre le panneau sans prendre le clavier) ; posée par `NotchController`.
    private var reveal: (String) -> Void = { _ in }
    /// Horloge de la garde (injectable pour les tests).
    var clock: () -> Date = Date.init

    private let keys: HotKeyRegistering
    private var enabled = false
    private var sources: [ApprovalSource] = []
    private var latest: [[ApprovalEntry]] = []
    private var queue: [(entry: ApprovalEntry, source: Int)] = []
    private var visible: Set<UUID> = []
    private var armed: (id: UUID, since: Date)?
    private var registered = false
    private var sourceSubscriptions = Set<AnyCancellable>()
    private var prefSubscription: AnyCancellable?

    init(prefs: Preferences, keys: HotKeyRegistering = HotKeyCenter.shared) {
        self.keys = keys
        prefSubscription = prefs.$approveByKeyboard.sink { [weak self] isOn in
            self?.enabled = isOn
            self?.refresh()
        }
    }

    /// Branche les files (Claude, Codex) ; remplace les précédentes.
    func attach(_ sources: [ApprovalSource], reveal: @escaping (String) -> Void) {
        sourceSubscriptions.removeAll()
        self.sources = sources
        self.reveal = reveal
        latest = Array(repeating: [], count: sources.count)
        for (index, source) in sources.enumerated() {
            source.entries.sink { [weak self] entries in
                guard let self, index < self.latest.count else { return }
                self.latest[index] = entries
                self.refresh()
            }.store(in: &sourceSubscriptions)
        }
    }

    /// La carte d'une demande vient d'apparaître dans la notch ouverte.
    func cardAppeared(_ id: UUID) {
        visible.insert(id)
        rearm()
    }

    /// Sa carte a disparu (panneau fermé, autre onglet, demande réglée).
    func cardDisappeared(_ id: UUID) {
        visible.remove(id)
        rearm()
    }

    /// ⌃⌥Y (`allow`) ou ⌃⌥N.
    func press(allow: Bool) {
        guard enabled, let head = queue.first else { return }
        // Une carte qu'on n'a pas sous les yeux ne se règle pas à l'aveugle : le premier appui la montre.
        guard let armed, armed.id == head.entry.id else {
            reveal(sources[head.source].tab)
            return
        }
        guard clock().timeIntervalSince(armed.since) >= Self.guardDelay else { return }
        // La suivante reprend sa garde quand celle-ci sort de la file.
        self.armed = nil
        sources[head.source].decide(head.entry.id, allow)
    }

    // MARK: - État

    /// File fusionnée dans l'ordre d'arrivée, touches posées ou retirées selon qu'il y a quelque chose à régler.
    private func refresh() {
        var merged: [(entry: ApprovalEntry, source: Int, position: Int)] = []
        for (source, entries) in latest.enumerated() {
            for (position, entry) in entries.enumerated() { merged.append((entry, source, position)) }
        }
        merged.sort { ($0.entry.received, $0.source, $0.position) < ($1.entry.received, $1.source, $1.position) }
        queue = enabled ? merged.map { ($0.entry, $0.source) } : []
        visible.formIntersection(merged.map(\.entry.id))
        if keyedId != queue.first?.entry.id { keyedId = queue.first?.entry.id }
        if count != queue.count { count = queue.count }
        rearm()
        setRegistered(!queue.isEmpty)
    }

    /// La garde compte depuis le moment où la demande qui a les touches est à l'écran.
    private func rearm() {
        guard let head = queue.first?.entry, visible.contains(head.id) else {
            armed = nil
            return
        }
        if armed?.id != head.id { armed = (head.id, clock()) }
    }

    private func setRegistered(_ on: Bool) {
        guard on != registered else { return }
        registered = on
        if on {
            approveLive = keys.set(.controlOptionY, for: .approve) { [weak self] in self?.press(allow: true) }
            denyLive = keys.set(.controlOptionN, for: .deny) { [weak self] in self?.press(allow: false) }
        } else {
            keys.set(.none, for: .approve) {}
            keys.set(.none, for: .deny) {}
            approveLive = false
            denyLive = false
        }
    }

    var debugInfo: [String: Any] {
        ["enabled": enabled, "queued": queue.count, "keysRegistered": registered, "armed": armed != nil]
    }
}
