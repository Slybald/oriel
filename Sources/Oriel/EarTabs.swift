import CoreGraphics
import Foundation

/// Réglage « Intercalaires » (Réglages › Apparence › Notch repliée).
enum EarTabsMode: String, CaseIterable, Identifiable {
    /// Éventail serré : une fine languette par intercalaire au repos ; il s'ouvre au survol.
    case retracted
    /// Éventail à moitié fermé : chaque intercalaire montre son icône (le premier aussi son information courte) ;
    /// il s'ouvre au survol.
    case visible

    var id: String { rawValue }
}

/// Un intercalaire de la notch repliée : une activité (Claude, lecture en cours, minuteur…).
struct EarTab: Equatable, Identifiable {
    enum Kind: Equatable {
        case claude(NotchIndicator)
        case module(ModuleEars)
        /// « +N » : les activités qui ne tiennent pas dans les six places.
        case more([EarTab])
    }

    /// « claude », l'identifiant du module, ou `moreId`. Ne dit rien de personnel.
    let id: String
    let kind: Kind
    /// Plus grand = plus près de la notch.
    let priority: Int
    /// Information très courte à côté de l'icône (« 4:59 », « 1·6 », « 3 ») ; vide = icône seule.
    let text: String
    /// Barres d'égaliseur à la place du texte.
    let bars: Bool
    /// Une alerte (Claude ou Codex attend l'utilisateur) reste déployée, même en mode « Rétractés ».
    let isAlert: Bool

    static let moreId = "more"

    /// Largeur au repos, icône et information comprises.
    var restWidth: CGFloat {
        let info: CGFloat
        if bars {
            info = EarTabs.barsWidth
        } else if text.isEmpty {
            info = 0
        } else {
            info = min(CGFloat(text.count) * EarTabs.characterWidth, EarTabs.maxTextWidth)
        }
        return 2 * EarTabs.padding + EarTabs.iconWidth + (info > 0 ? EarTabs.iconGap + info : 0)
    }

    /// Couleur d'accent de l'activité (hex) ; nil = l'accent choisi dans les réglages (Claude).
    var accentHex: String? {
        if case .module(let ears) = kind, let hex = ears.accentHex { return hex }
        return EarTabs.accentHex(forId: id)
    }
}

extension SessionStore.EarsContent {
    /// Texte court des oreilles de Claude : « 3/7 » (tâches), « 1 » (sessions) ou « 1·6 » avec les agents.
    var label: String {
        if let tasks { return tasks }
        return agents > 0 ? "\(sessions)·\(agents)" : "\(sessions)"
    }
}

enum EarTabs {
    /// Intercalaires par côté ; au-delà, le dernier devient « +N ».
    static let maxPerSide = 3
    /// Marge intérieure, icône, écart et approximation de la largeur d'un caractère (chiffres à chasse fixe, 11 pt).
    static let padding: CGFloat = 7
    static let iconWidth: CGFloat = 14
    static let iconGap: CGFloat = 4
    static let characterWidth: CGFloat = 6.5
    static let maxTextWidth: CGFloat = 38
    static let barsWidth: CGFloat = 16
    /// Largeur de la languette « Rétractés ».
    static let sliverWidth: CGFloat = 8
    /// Ce que montre de lui un intercalaire glissé sous le précédent : son icône, entre deux marges.
    static let sliceWidth: CGFloat = 2 * padding + iconWidth
    /// Rayon du coin extérieur bas d'un intercalaire au repos (celui de la notch repliée), et déployé.
    static let restRadius: CGFloat = NotchShape.collapsedBottomRadius
    static let cardRadius: CGFloat = 14
    /// Évasement concave du bord extérieur, en haut : le raccord de la notch avec le haut de l'écran. Il dépasse de la
    /// tranche (vers l'extérieur) de ce rayon, d'où la marge de la fenêtre.
    static let flareRadius: CGFloat = NotchShape.collapsedTopRadius
    /// Largeur d'un intercalaire déployé (réduite pour rester dans la fenêtre).
    static let cardWidth: CGFloat = 236
    /// Dépassement sous la notch (derrière elle) ou sous l'intercalaire précédent de la pile, pour qu'aucun jour ne
    /// reste dans leur coin arrondi.
    static let overlap: CGFloat = 12
    /// Marge gardée entre un intercalaire déployé et le bord de la fenêtre (au moins l'évasement, qui dépasse).
    static let windowMargin: CGFloat = max(6, flareRadius)

    // MARK: Choix des activités

    /// Claude qui attend > Claude qui travaille ou vient de finir (5 s) > modules par priorité décroissante (minuteur 5,
    /// lecture 1, caféine −10 ; à égalité, l'ordre des onglets). Chaque activité a son intercalaire.
    static func tabs(claude: NotchIndicator, claudeEars: SessionStore.EarsContent?, modules: [ModuleEarsEntry],
                     showEars: Bool) -> [EarTab] {
        guard showEars else { return [] }
        var result: [EarTab] = []
        if claude != .none {
            result.append(EarTab(id: ModuleRegistry.claudeId, kind: .claude(claude),
                                 priority: claude == .attention ? 1000 : 100, text: claudeEars?.label ?? "",
                                 bars: false, isAlert: claude == .attention))
        }
        // Tri stable : à priorité égale, l'ordre des onglets.
        let byPriority = modules.enumerated().sorted {
            $0.element.ears.priority != $1.element.ears.priority
                ? $0.element.ears.priority > $1.element.ears.priority : $0.offset < $1.offset
        }
        for (_, entry) in byPriority {
            result.append(EarTab(id: entry.id, kind: .module(entry.ears), priority: entry.ears.priority,
                                 text: entry.ears.bars ? "" : entry.ears.text, bars: entry.ears.bars,
                                 isAlert: entry.ears.alert))
        }
        return result
    }

    /// Réparti de part et d'autre de la notch, le plus prioritaire à gauche contre elle, le suivant à droite contre elle,
    /// puis l'un et l'autre un cran plus loin. Au plus `maxPerSide` par côté : au-delà, la sixième place devient « +N ».
    static func distribute(_ tabs: [EarTab]) -> (left: [EarTab], right: [EarTab]) {
        let capacity = 2 * maxPerSide
        var placed = tabs
        if tabs.count > capacity {
            let hidden = Array(tabs[(capacity - 1)...])
            placed = Array(tabs[..<(capacity - 1)])
            placed.append(EarTab(id: EarTab.moreId, kind: .more(hidden), priority: Int.min, text: "+\(hidden.count)",
                                 bars: false, isAlert: false))
        }
        var left: [EarTab] = []
        var right: [EarTab] = []
        for (index, tab) in placed.enumerated() {
            if index.isMultiple(of: 2) { left.append(tab) } else { right.append(tab) }
        }
        return (left, right)
    }

    // MARK: Style

    /// Une couleur discrète par activité (hors Claude, qui prend l'accent des réglages).
    static func accentHex(forId id: String) -> String? {
        switch id {
        case ModuleRegistry.claudeId: return nil
        case "media": return "FB7185"
        case "timer": return "F5B83D"
        case "codex": return "2DD4BF"
        case "messages": return "4ADE80"
        case "mail": return "60A5FA"
        case "quicksettings": return "C084FC"
        case "agenda": return "D4D4D8"
        case EarTab.moreId: return "A1A1AA"
        default: return "A1A1AA"
        }
    }

    /// Ce qu'un intercalaire montre de lui au repos : une languette (« Rétractés »), son icône et son information (le
    /// premier de la pile, ou une alerte, qui reste déployée), ou son icône seule (les suivants, glissés sous lui).
    static func slice(of tab: EarTab, rank: Int, mode: EarTabsMode) -> CGFloat {
        if mode == .retracted && !tab.isAlert { return sliverWidth }
        return rank == 0 || tab.isAlert ? tab.restWidth : min(tab.restWidth, sliceWidth)
    }
}

/// Géométrie des intercalaires de la notch repliée, sans vue ni fenêtre : la vue la dessine, le contrôleur en tire
/// les zones de survol. Repère : origine au centre haut de la notch, x vers la droite, y vers le bas.
struct EarTabsLayout: Equatable {
    enum Side: Equatable { case left, right }

    enum Hit: Equatable {
        case notch
        case tab(String)
        case none
    }

    struct Item: Equatable, Identifiable {
        let tab: EarTab
        let side: Side
        /// 0 = contre la notch, au-dessus de la pile.
        let rank: Int
        /// Distance du centre au bord intérieur de la tranche visible (là où finit celui qui le précède).
        let inner: CGFloat
        /// Largeur de la tranche visible : le reste de l'intercalaire glisse sous celui qui le précède.
        let width: CGFloat
        /// Toujours la hauteur de la notch : tous alignés avec elle, même haut, même bas, base continue.
        let height: CGFloat

        var id: String { tab.id }
        /// Sens du bord extérieur : −1 à gauche, +1 à droite.
        var outward: CGFloat { side == .left ? -1 : 1 }
        /// La tranche montre-t-elle aussi l'information courte (sinon l'icône seule ou la languette) ?
        var showsInfo: Bool { width >= tab.restWidth }

        /// Tranche visible au repos.
        var frame: CGRect {
            let edge = outward * inner
            return CGRect(x: side == .left ? edge - width : edge, y: 0, width: width, height: height)
        }

        /// Tout l'intercalaire au repos : la tranche et le bout glissé sous le précédent.
        var bodyFrame: CGRect {
            let edge = outward * inner
            return CGRect(x: side == .left ? edge - width : edge - EarTabs.overlap, y: 0,
                          width: width + EarTabs.overlap, height: height)
        }
    }

    let notch: CGSize
    let mode: EarTabsMode
    let left: [Item]
    let right: [Item]

    var items: [Item] { left + right }
    var isEmpty: Bool { left.isEmpty && right.isEmpty }

    /// Ce qui change la place ou la forme des intercalaires (pas leur texte) : la vue n'anime que ces changements.
    var signature: [String] { items.map { "\($0.id):\($0.width):\($0.height)" } }

    init(tabs: [EarTab], notch: CGSize, mode: EarTabsMode) {
        self.notch = notch
        self.mode = mode
        let placed = EarTabs.distribute(tabs)
        func build(_ tabs: [EarTab], _ side: Side) -> [Item] {
            var inner = notch.width / 2
            return tabs.enumerated().map { rank, tab in
                let width = EarTabs.slice(of: tab, rank: rank, mode: mode)
                defer { inner += width }
                return Item(tab: tab, side: side, rank: rank, inner: inner, width: width, height: notch.height)
            }
        }
        left = build(placed.left, .left)
        right = build(placed.right, .right)
    }

    func item(_ id: String) -> Item? { items.first { $0.id == id } }

    /// Demi-largeur de ce que la notch et ses intercalaires occupent au repos.
    var reach: CGFloat {
        max(reach(of: left), reach(of: right))
    }

    private func reach(of items: [Item]) -> CGFloat {
        items.last.map { $0.inner + $0.width } ?? notch.width / 2
    }

    // MARK: Intercalaire déployé

    /// Largeur de l'intercalaire déployé : celle des réglages, réduite pour tenir dans la fenêtre.
    func cardWidth(_ item: Item) -> CGFloat {
        let room = NotchController.panelSize.width / 2 - EarTabs.windowMargin - item.inner
        return max(item.width, min(EarTabs.cardWidth, room))
    }

    /// Rectangle de l'intercalaire déployé : son bord intérieur ne bouge pas, il grandit vers l'extérieur et vers le bas.
    /// `height` est la hauteur mesurée par la vue (au moins celle de la notch).
    func cardFrame(_ item: Item, height: CGFloat) -> CGRect {
        let width = cardWidth(item)
        let edge = item.outward * item.inner
        return CGRect(x: item.side == .left ? edge - width : edge, y: 0, width: width,
                      height: max(height, notch.height))
    }

    // MARK: Survol

    /// Ce qui est sous `point` (repère de la notch) : un intercalaire (la forme réelle, coin arrondi compris), le centre
    /// de la notch, ou rien. Du dessus vers le dessous de la pile : le rang 0 recouvre les suivants, un intercalaire
    /// déployé recouvre ceux qui sont plus loin que lui ; les zones ne se recouvrent pas. Déployé, sa zone contient
    /// toujours celle qu'il avait au repos (rien ne change de cible sous une souris immobile).
    func hit(_ point: CGPoint, hovered: String?, cardHeight: CGFloat) -> Hit {
        // La notch d'abord : sur le bord qu'elle partage avec un intercalaire, c'est elle. Elle garde sa marge de 2 pt sous
        // la bande, comme avant les intercalaires ; bords inclusifs (la souris peut être pile sur le bord haut de l'écran).
        if abs(point.x) <= notch.width / 2, point.y >= 0, point.y <= notch.height + 2 { return .notch }
        for item in items {
            if item.id == hovered,
               Self.contains(cardFrame(item, height: cardHeight), point, side: item.side, outerRadius: EarTabs.cardRadius,
                             innerRadius: cardInnerRadius(height: cardHeight)) {
                return .tab(item.id)
            }
            if Self.contains(item.bodyFrame, point, side: item.side, outerRadius: EarTabs.restRadius, innerRadius: 0) {
                return .tab(item.id)
            }
        }
        return .none
    }

    /// Rayon du coin intérieur bas d'un intercalaire déployé : pas plus haut que ce qui dépasse sous la notch et les
    /// intercalaires, qui ont sa hauteur, sinon il laisse un jour contre eux.
    func cardInnerRadius(height: CGFloat) -> CGFloat {
        min(EarTabs.cardRadius, max(0, height - notch.height))
    }

    /// Dans `rect` (bords inclusifs), sans les coins bas arrondis (rayon 0 : coin droit).
    static func contains(_ rect: CGRect, _ point: CGPoint, side: Side, outerRadius: CGFloat,
                         innerRadius: CGFloat) -> Bool {
        guard point.x >= rect.minX, point.x <= rect.maxX, point.y >= rect.minY, point.y <= rect.maxY else { return false }
        func inCorner(centerX: CGFloat, radius r: CGFloat) -> Bool {
            let dx = point.x - centerX
            let dy = point.y - (rect.maxY - r)
            return dy <= 0 || dx * dx + dy * dy <= r * r
        }
        let outer = max(0, min(outerRadius, rect.width / 2, rect.height))
        let inner = max(0, min(innerRadius, rect.width / 2, rect.height))
        let outerX = side == .left ? rect.minX + outer : rect.maxX - outer
        let innerX = side == .left ? rect.maxX - inner : rect.minX + inner
        let outerSide = side == .left ? point.x < outerX : point.x > outerX
        let innerSide = side == .left ? point.x > innerX : point.x < innerX
        if outerSide, !inCorner(centerX: outerX, radius: outer) { return false }
        if inner > 0, innerSide, !inCorner(centerX: innerX, radius: inner) { return false }
        return true
    }
}
