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
        guard isHovering != hovering else { return }
        hovering = isHovering
        guard current != nil else { return }
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
