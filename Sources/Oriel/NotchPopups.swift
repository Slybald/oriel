import Combine
import CoreGraphics
import Foundation

/// Ce que dit un pop-up : une icône, un titre (expéditeur, session…) et une ligne. Le texte reste en mémoire, le temps
/// d'être affiché : il n'est ni écrit sur disque, ni journalisé, ni envoyé.
struct PopupEvent: Equatable {
    /// Identifiant du module (onglet ouvert au clic).
    var source: String
    /// SF Symbol.
    var symbol: String
    var title: String
    var text: String
    /// Identifie l'élément (conversation + date, mail, rendez-vous) : le même élément ne s'affiche pas deux fois de suite.
    var key: String
    /// Événements de la même source regroupés dans celui-ci (« +2 »).
    var extra = 0
    /// Couleur d'accent (hex) ; nil = celle de l'app.
    var accentHex: String?
}

/// File des pop-ups de la notch repliée : un seul à l'écran, les suivants attendent (regroupés par source), jamais
/// d'empilement. Pur : l'horloge est un `ModuleScheduler`, le contrôleur ne fait que lui dire où est la souris.
///
/// - Rien n'est retenu si le réglage est coupé, si le module source est désactivé ou si la notch ne peut pas en montrer
///   (panneau ouvert, plein écran « masquée », notch masquée, bulle détachée : `isBlocked`).
/// - Le survol suspend la fermeture ; à la sortie, `hoverGrace` secondes de plus.
final class NotificationPopups: ObservableObject {
    static let shared = NotificationPopups()

    /// Temps d'affichage d'un pop-up.
    static let displayDuration: TimeInterval = 5
    /// Après un survol : le temps de lire la fin avant la fermeture.
    static let hoverGrace: TimeInterval = 1.5
    /// Pause entre deux pop-ups : le premier se referme avant que le suivant ne descende.
    static let gap: TimeInterval = 0.4
    /// Sources différentes en attente ; au-delà, la plus ancienne est abandonnée.
    static let maxPending = 4

    @Published private(set) var current: PopupEvent?
    private(set) var pending: [PopupEvent] = []

    /// Réglage « Pop-ups » (Réglages › Général).
    var isEnabled = true
    /// Le module est-il activé ? (le contrôleur branche `ModuleRegistry.isEnabled`)
    var isSourceEnabled: (String) -> Bool = { _ in true }
    /// La notch ne peut pas montrer de pop-up maintenant.
    var isBlocked: () -> Bool = { false }

    private let scheduler: ModuleScheduler
    private var hovering = false
    /// Plein écran sur l'écran de la notch : rien ne descend, les événements sont comptés (voir `setFullScreen`).
    private(set) var isFullScreen = false
    private var held: [String: HeldCount] = [:]
    private var summaries = 0
    private var cancelTimer: (() -> Void)?
    private var cancelGap: (() -> Void)?

    init(scheduler: ModuleScheduler = .system) {
        self.scheduler = scheduler
    }

    /// Les modules testent ceci avant tout travail ajouté pour un pop-up.
    func accepts(_ source: String) -> Bool {
        isEnabled && isSourceEnabled(source) && !isBlocked()
    }

    func post(_ event: PopupEvent) {
        guard accepts(event.source) else { return }
        if isFullScreen { return hold(event) }
        if current?.source == event.source, current?.key == event.key { return }
        if let index = pending.firstIndex(where: { $0.source == event.source }) {
            // Même source déjà en attente : regroupé, le plus récent donne le texte.
            if pending[index].key == event.key { return }
            var merged = event
            merged.extra = pending[index].extra + event.extra + 1
            pending[index] = merged
            return
        }
        if current == nil, cancelGap == nil {
            show(event)
        } else {
            pending.append(event)
            if pending.count > Self.maxPending { pending.removeFirst() }
        }
    }

    /// Souris sur le pop-up : il reste ouvert.
    func setHovering(_ isHovering: Bool) {
        // Sans pop-up à l'écran, la souris ne compte pas : le suivant ne doit pas démarrer « survolé » à tort.
        guard current != nil else { hovering = false; return }
        guard isHovering != hovering else { return }
        hovering = isHovering
        cancelTimer?()
        cancelTimer = nil
        if !isHovering { arm(Self.hoverGrace) }
    }

    /// Tout est oublié : panneau ouvert, notch masquée, réglage coupé.
    func clear() {
        cancelTimer?()
        cancelTimer = nil
        cancelGap?()
        cancelGap = nil
        pending = []
        hovering = false
        if current != nil { current = nil }
    }

    /// Clic sur le pop-up : il se referme (le contrôleur ouvre l'onglet), les suivants sont abandonnés.
    func dismiss() { clear() }

    private func show(_ event: PopupEvent) {
        current = event
        arm(Self.displayDuration)
    }

    private func arm(_ delay: TimeInterval) {
        cancelTimer?()
        cancelTimer = scheduler.after(delay) { [weak self] in self?.expire() }
    }

    private func expire() {
        cancelTimer = nil
        current = nil
        hovering = false
        guard !pending.isEmpty else { return }
        cancelGap = scheduler.after(Self.gap) { [weak self] in
            guard let self else { return }
            cancelGap = nil
            guard !pending.isEmpty else { return }
            show(pending.removeFirst())
        }
    }
}

/// Mode série : en plein écran rien ne descend ; à la sortie, un seul pop-up résume. Pas de minuteur : tout se joue aux
/// deux changements d'état. Seuls des compteurs par source sont gardés, jamais le texte ni l'expéditeur.
extension NotificationPopups {
    /// Sources différentes comptées pendant un plein écran, et plafond de chaque compteur : la mémoire reste bornée.
    static let maxHeldSources = 8
    static let maxHeldCount = 99

    struct HeldCount {
        var count = 0
        /// Empreinte de la clé du dernier élément vu : le même élément n'est pas compté deux fois.
        var lastKey: Int?
    }

    func setFullScreen(_ on: Bool) {
        guard on != isFullScreen else { return }
        isFullScreen = on
        if on {
            // Ce qui attendait en file est gardé ; ce qui est à l'écran a déjà été vu (mais ne sera pas recompté).
            if let current { held[current.source] = HeldCount(lastKey: current.key.hashValue) }
            for event in pending { hold(event) }
            clear()
        } else if let summary = takeSummary() {
            post(summary)
        }
    }

    fileprivate func hold(_ event: PopupEvent) {
        var entry = held[event.source] ?? HeldCount()
        guard entry.lastKey != event.key.hashValue else { return }
        guard held[event.source] != nil || held.count < Self.maxHeldSources else { return }
        entry.count = min(Self.maxHeldCount, entry.count + 1 + event.extra)
        entry.lastKey = event.key.hashValue
        held[event.source] = entry
    }

    private func takeSummary() -> PopupEvent? {
        let counts = held.compactMapValues { $0.count > 0 ? $0.count : nil }.filter { isSourceEnabled($0.key) }
        held = [:]
        guard isEnabled, !counts.isEmpty else { return nil }
        let order = ["messages", "mail", "claude", "codex", "timer", "agenda"]
        let ranked = counts.sorted { (order.firstIndex(of: $0.key) ?? order.count, $0.key)
                                    < (order.firstIndex(of: $1.key) ?? order.count, $1.key) }
        summaries += 1
        // Un clic ouvre l'onglet qui a le plus d'événements (à égalité, le premier de l'ordre ci-dessus).
        let top = ranked.first { $0.value == counts.values.max() }?.key ?? ranked[0].key
        return PopupEvent(source: top, symbol: "tray.full.fill",
                          title: L("Pendant le plein écran", table: "Popup"),
                          text: ranked.map { Self.phrase($0.key, $0.value) }.joined(separator: ", "),
                          key: "fullscreen-summary|\(summaries)")
    }

    private static func phrase(_ source: String, _ count: Int) -> String {
        let format: String
        switch source {
        case "messages": format = L(count, one: "%d message", other: "%d messages", table: "Popup")
        case "mail": format = L(count, one: "%d mail", other: "%d mails", table: "Popup")
        case "claude": format = L("%d pour Claude", table: "Popup")
        case "codex": format = L("%d pour Codex", table: "Popup")
        case "timer": format = L(count, one: "%d minuteur", other: "%d minuteurs", table: "Popup")
        case "agenda": format = L(count, one: "%d rendez-vous", other: "%d rendez-vous", table: "Popup")
        default: format = L(count, one: "%d autre", other: "%d autres", table: "Popup")
        }
        return String(format: format, count)
    }
}

/// Géométrie du pop-up sous la notch (la vue et la zone de survol s'en servent).
enum PopupLayout {
    static let width: CGFloat = 288
    static let height: CGFloat = 50
    /// Écart entre le bas de la notch et le haut du pop-up.
    static let gap: CGFloat = 6
    static let cornerRadius: CGFloat = 18

    /// Zone du pop-up en coordonnées écran (origine en bas à gauche) : `notch` est le rectangle de la notch, `band` la
    /// hauteur de sa bande (perle comprise).
    static func rect(notch: CGRect, band: CGFloat) -> CGRect {
        CGRect(x: notch.midX - width / 2, y: notch.maxY - band - gap - height, width: width, height: height)
    }
}

/// Moments d'une session qui méritent un pop-up : seulement les changements, jamais l'état au lancement.
enum PopupMoment: Equatable {
    case attention
    case done

    static func claude(old: Session?, new: Session) -> PopupMoment? {
        moment(oldAttention: old?.phase.needsAttention ?? false, newAttention: new.phase.needsAttention,
               oldDone: old?.phase == .done, newDone: new.phase == .done)
    }

    static func codex(old: CodexSession?, new: CodexSession) -> PopupMoment? {
        moment(oldAttention: old?.phase.needsAttention ?? false, newAttention: new.phase.needsAttention,
               oldDone: old?.phase == .done, newDone: new.phase == .done)
    }

    private static func moment(oldAttention: Bool, newAttention: Bool, oldDone: Bool, newDone: Bool) -> PopupMoment? {
        if newAttention, !oldAttention { return .attention }
        if newDone, !oldDone { return .done }
        return nil
    }

    var symbol: String { self == .attention ? "hand.raised.fill" : "checkmark.circle.fill" }
}
