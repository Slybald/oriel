import AppKit
import SwiftUI

// Règles de la notch indépendantes de la fenêtre (visibilité, écran, géométrie), testées sans écran réel.

/// La notch doit-elle être à l'écran ?
enum NotchVisibilityRule {
    struct Inputs {
        /// Claude Desktop ouvert, un `claude` vivant ou une session vivante.
        var claudeOpen = false
        /// Une session au travail, qui attend ou qui vient de finir (`NotchIndicator` différent de `.none`).
        var claudeActive = false
        /// Un module affiche des oreilles (minuteur, lecture…).
        var moduleEars = false
        /// Montrée à la demande : glisser de fichiers vers l'Étagère, raccourci clavier.
        var onDemand = false
        /// Panneau déplié : on ne le retire pas sous la souris quand l'activité s'arrête.
        var expanded = false
        /// Plein écran avec le réglage « Notch masquée ».
        var hiddenForFullScreen = false
        /// « Masquer la notch » en cours.
        var hiddenByUser = false
    }

    static func shouldShow(_ mode: NotchVisibility, _ inputs: Inputs) -> Bool {
        if inputs.onDemand { return true }
        if inputs.hiddenForFullScreen || inputs.hiddenByUser { return false }
        if inputs.expanded { return true }
        switch mode {
        case .always: return true
        case .whenClaudeOpen: return inputs.claudeOpen || inputs.claudeActive || inputs.moduleEars
        case .duringActivity: return inputs.claudeActive || inputs.moduleEars
        }
    }
}

/// Un écran tel que la notch le voit (double de `NSScreen` dans les tests).
struct ScreenCandidate: Equatable {
    var name: String
    var frame: CGRect
    var visibleFrame: CGRect
    /// Hauteur de l'encoche (`safeAreaInsets.top`), 0 sans encoche.
    var safeAreaTop: CGFloat = 0
    /// Largeurs des zones de la barre des menus à gauche et à droite de l'encoche.
    var auxiliaryLeftWidth: CGFloat?
    var auxiliaryRightWidth: CGFloat?
    var isBuiltin = false

    var hasNotch: Bool { safeAreaTop > 0 && auxiliaryLeftWidth != nil && auxiliaryRightWidth != nil }
}

/// Notch repliée d'un écran sans encoche (`appearance.virtualNotch`) : encoche dessinée contre le haut de l'écran,
/// pilule qui flotte juste en dessous, caméléon (invisible au repos, en verre dépoli pendant une activité) ou perle
/// (une perle minuscule pendant une activité, qui devient le caméléon quand la souris s'approche).
enum VirtualNotchStyle: String {
    case notch, pill, chameleon, pearl
}

/// Style « perle » : géométrie de la perle et de sa zone de proximité, et l'état éveillé / endormi, sans vue ni fenêtre.
/// Endormie, la perle montre l'icône et le chiffre de l'activité en cours (rien sans activité) ; éveillée, c'est
/// l'encoche caméléon (`VirtualNotchStyle.chameleon`) qui prend sa place.
enum Pearl {
    static let height: CGFloat = 20
    static let minWidth: CGFloat = 44
    /// Une information longue (« 4:59 ») l'élargit, pas plus.
    static let maxWidth: CGFloat = 72
    /// Zone qui réveille la perle : la perle élargie de ces marges, jusqu'au haut de l'écran. Étroite, pour qu'un
    /// clic dans un menu voisin ne la touche pas.
    static let reachX: CGFloat = 12
    static let reachY: CGFloat = 4
    /// Intention : la souris doit rester dans la zone `wakeDelay` pour réveiller la perle (traverser la barre des
    /// menus ne la réveille pas), et en rester dehors `sleepDelay` pour l'endormir (un écart ne la rendort pas).
    static let wakeDelay: TimeInterval = 0.1
    static let sleepDelay: TimeInterval = 0.3

    /// Taille de la perle pour l'activité qu'elle montre (nil : rien à montrer, la place vide).
    static func size(for tab: EarTab?) -> CGSize {
        CGSize(width: min(max(tab?.restWidth ?? 0, minWidth), maxWidth), height: height)
    }

    /// Perle collée au haut de l'encoche virtuelle, centrée.
    static func rect(in notch: CGRect, size: CGSize) -> CGRect {
        CGRect(x: notch.midX - size.width / 2, y: notch.maxY - size.height, width: size.width, height: size.height)
    }

    /// Zone de proximité de la perle (repère de l'écran, bords inclusifs : la souris peut être pile en haut).
    static func zone(around pearl: CGRect) -> CGRect {
        CGRect(x: pearl.minX - reachX, y: pearl.minY - reachY, width: pearl.width + 2 * reachX,
               height: pearl.height + reachY + 1)
    }

    static func contains(_ zone: CGRect, _ point: CGPoint) -> Bool {
        point.x >= zone.minX && point.x <= zone.maxX && point.y >= zone.minY && point.y <= zone.maxY
    }

    /// Éveillée ou endormie. L'état ne bascule qu'après le délai d'intention, compté depuis que la souris est
    /// continûment du mauvais côté : un va-et-vient à la limite de la zone ne fait donc rien clignoter.
    struct Presence {
        private(set) var isAwake = false
        private var pendingSince: Date?

        /// `near` : la souris est dans la zone (endormie) ou sur l'encoche éveillée. Rend l'échéance à laquelle
        /// rappeler `update` si un changement est en attente.
        mutating func update(near: Bool, now: Date) -> Date? {
            guard near != isAwake else {
                pendingSince = nil
                return nil
            }
            let since = pendingSince ?? now
            pendingSince = since
            let deadline = since.addingTimeInterval(near ? Pearl.wakeDelay : Pearl.sleepDelay)
            guard now >= deadline else { return deadline }
            isAwake = near
            pendingSince = nil
            return nil
        }

        /// Éveillée d'emblée (le panneau s'ouvre sans attendre le délai).
        mutating func wake() {
            isAwake = true
            pendingSince = nil
        }

        mutating func reset() {
            isAwake = false
            pendingSince = nil
        }
    }
}

enum NotchScreenPicker {
    /// Largeur de l'encoche virtuelle des écrans sans encoche.
    static let virtualNotchWidth: CGFloat = 200
    /// Écart entre le haut de l'écran et la pilule : elle flotte, elle ne touche pas le bord.
    static let pillGap: CGFloat = 4

    /// Index de l'écran choisi (`ScreenChoice` ou nom d'écran) ; un écran nommé absent ou une souris hors de
    /// tout écran retombent sur l'écran intégré.
    static func pick(_ choice: String, among screens: [ScreenCandidate], mouse: CGPoint) -> Int? {
        guard !screens.isEmpty else { return nil }
        let builtin = screens.firstIndex { $0.hasNotch } ?? screens.firstIndex { $0.isBuiltin } ?? 0
        switch choice {
        case ScreenChoice.builtin: return builtin
        case ScreenChoice.main: return 0
        case ScreenChoice.mouse: return screens.firstIndex { contains($0.frame, mouse) } ?? builtin
        default: return labels(screens).firstIndex(of: choice) ?? builtin
        }
    }

    /// Noms proposés et mémorisés : deux écrans du même modèle deviennent « DELL U2720Q » et « DELL U2720Q (2) ».
    /// shortcut: numérotés dans l'ordre de `NSScreen.screens` ; passer à l'UUID d'affichage si cet ordre s'avère
    /// instable entre deux branchements.
    static func labels(_ screens: [ScreenCandidate]) -> [String] {
        var seen: [String: Int] = [:]
        return screens.map { screen in
            let count = (seen[screen.name] ?? 0) + 1
            seen[screen.name] = count
            return count == 1 ? screen.name : "\(screen.name) (\(count))"
        }
    }

    /// Bord haut compris (la souris peut y être pile) ; bord droit exclu (écrans voisins).
    static func contains(_ frame: CGRect, _ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }

    /// Encoche réelle, ou encoche virtuelle centrée en haut, à la hauteur de la barre des menus de l'écran (la pilule,
    /// `pillGap` plus bas).
    static func notchRect(on screen: ScreenCandidate, menuBarThickness: CGFloat,
                          style: VirtualNotchStyle = .notch) -> (rect: CGRect, hasNotch: Bool) {
        let frame = screen.frame
        if screen.hasNotch, let left = screen.auxiliaryLeftWidth, let right = screen.auxiliaryRightWidth {
            let height = screen.safeAreaTop
            return (CGRect(x: frame.minX + left, y: frame.maxY - height, width: frame.width - left - right,
                           height: height), true)
        }
        let menuBar = max(frame.maxY - screen.visibleFrame.maxY, menuBarThickness)
        let top = frame.maxY - (style == .pill ? pillGap : 0)
        return (CGRect(x: frame.midX - virtualNotchWidth / 2, y: top - menuBar, width: virtualNotchWidth,
                       height: menuBar), false)
    }
}

extension ScreenCandidate {
    init(_ screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        self.init(name: screen.localizedName, frame: screen.frame, visibleFrame: screen.visibleFrame,
                  safeAreaTop: screen.safeAreaInsets.top, auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
                  auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
                  isBuiltin: number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false)
    }
}

/// Animations de la notch : le ressort choisi, ou un simple fondu avec « Réduire les animations ».
enum NotchMotion {
    static func animation(_ speed: AnimationSpeed, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : speed.spring
    }
}

/// Texte du rappel « Notch masquée jusqu'à … » : l'heure de fin, précédée de « demain » ou de la date au besoin.
enum HiddenNotice {
    static func text(until: Date, now: Date, calendar: Calendar = .current) -> String {
        if until == .distantFuture { return L("Notch masquée jusqu'à réactivation") }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        if calendar.isDate(until, inSameDayAs: now) {
            return String(format: L("Notch masquée jusqu'à %@"), formatter.string(from: until))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(until, inSameDayAs: tomorrow) {
            return String(format: L("Notch masquée jusqu'à demain, %@"), formatter.string(from: until))
        }
        formatter.dateStyle = .short
        return String(format: L("Notch masquée jusqu'à %@"), formatter.string(from: until))
    }

    /// Comment la réafficher, en pied des menus « Masquer la notch » (sans icône, rien d'autre ne le dit).
    static func howToShowAgain(hotKey: HotKeyChoice) -> String {
        hotKey == .none ? L("Pour la réafficher : rouvrir Oriel")
            : String(format: L("Pour la réafficher : %@ ou rouvrir Oriel"), hotKey.title)
    }
}

/// Entrée de menu AppKit qui lance une closure (la cible d'un NSMenuItem est faible : l'entrée la garde).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) indisponible") }

    @objc private func runHandler() { handler() }
}
