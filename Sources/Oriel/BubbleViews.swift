import AppKit
import SwiftUI

// Vues de la notch détachée : poignée de l'angle, goutte, bulle en barillet, panneau de la bulle.

/// État des vues de la bulle, tenu par `BubbleController`.
final class BubbleModel: ObservableObject {
    /// Centre de la bulle dans sa fenêtre (y vers le bas) et taille de la fenêtre : la bulle reste au même endroit de
    /// l'écran quand la fenêtre grandit pour le panneau.
    @Published private(set) var centerInWindow = CGPoint(x: BubbleController.bubbleWindowSize.width / 2,
                                                         y: BubbleController.bubbleWindowSize.height / 2)
    @Published private(set) var windowSize = BubbleController.bubbleWindowSize
    /// Crans du barillet (voir `Revolver`).
    @Published var turn = 0
    /// Bulle aimantée par la notch : son bord s'allume.
    @Published var nearNotch = false
    /// Échelle de la bulle : 0,72 au décollage (taille de la goutte), puis rebond jusqu'à 1.
    @Published var scale: CGFloat = 1
    /// « Réduire les animations » : bulle à demi transparente qui suit la souris avant le décollage.
    @Published var ghost = false
    /// Retour aimanté en cours (fenêtre agrandie au champ de la notch) ; nil ailleurs.
    @Published var ferro: FerroState?

    func layout(center: CGPoint, window: CGSize) {
        if centerInWindow != center { centerInWindow = center }
        if windowSize != window { windowSize = window }
    }

    /// Centre de la bulle, point fixe de son apparition.
    var anchor: UnitPoint { unit(centerInWindow) }

    /// Chambre du haut (onglet actif) : le panneau en sort et s'y referme.
    var chamberAnchor: UnitPoint { unit(CGPoint(x: centerInWindow.x, y: centerInWindow.y - Revolver.ringRadius)) }

    private func unit(_ point: CGPoint) -> UnitPoint {
        UnitPoint(x: windowSize.width > 0 ? point.x / windowSize.width : 0.5,
                  y: windowSize.height > 0 ? point.y / windowSize.height : 0.5)
    }
}

/// Ce que la bulle demande au contrôleur.
struct BubbleInput {
    var open: () -> Void = {}
    var rotate: (Int) -> Void = { _ in }
    var reattach: () -> Void = {}
    var moveBegan: () -> Void = {}
    var moved: () -> Void = {}
    var moveEnded: () -> Void = {}
    var panelSized: (CGSize) -> Void = { _ in }
    /// Panneau ouvert : revenir au barillet (pincement).
    var back: () -> Void = {}
}

// MARK: - Poignée

/// Angle bas droit du panneau déplié : un arc et un point, qui s'allument au survol. Appui maintenu puis glisser : la
/// notch se décolle. VoiceOver : un bouton « Détacher la notch ».
struct DetachHandle: View {
    let begin: () -> Void
    let detach: () -> Void
    /// Rayon du coin du panneau, pour que l'arc le suive.
    var cornerRadius: CGFloat = 24
    /// Premières ouvertures du panneau : l'indice s'affiche seul quelques secondes (vrai = à montrer, déjà compté).
    var takeHint: () -> Bool = { false }

    @State private var hovering = false
    @State private var pressing = false
    @State private var hinting = false

    static let size: CGFloat = 26
    static let hintDuration: TimeInterval = 3.5

    var body: some View {
        DetachGrip(cornerRadius: cornerRadius, lit: hovering || pressing || hinting, pressed: pressing)
            .frame(width: Self.size, height: Self.size)
            // Seulement la marge du panneau (14 pt) : les contrôles d'un module dans ce coin gardent leurs clics.
            .contentShape(CornerBand(width: ExpandedPanel.bottomPadding))
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop() } }
            // Indice sous l'angle : tout de suite au survol (l'info-bulle met une seconde), et seul aux premières
            // ouvertures. Hors du panneau, sans prendre la souris.
            .overlay(alignment: .topTrailing) {
                if hovering || hinting {
                    DetachHint()
                        .fixedSize()
                        .offset(y: Self.size + 4)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: hovering || hinting)
            .onAppear {
                guard takeHint() else { return }
                hinting = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hintDuration) { hinting = false }
            }
            // Glisser tout de suite, ou appui maintenu : la goutte part au premier mouvement (l'appui long seul
            // échouait dès qu'on glissait avant 0,3 s, et rien ne se passait).
            .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 3, perform: begin,
                                onPressingChanged: { pressing = $0 })
            .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { _ in begin() })
            .help(L("Glisse pour détacher la notch", table: "Bubble"))
            .accessibilityElement()
            .accessibilityLabel(Text(L("Détacher la notch", table: "Bubble")))
            .accessibilityHint(Text(L("La notch devient une bulle à poser où tu veux.", table: "Bubble")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { detach() }
    }
}

/// « Glisse l'angle pour détacher la notch », sous l'angle du panneau.
struct DetachHint: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Palette.accent)
            Text(L("Glisse l'angle pour détacher la notch", table: "Bubble"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Palette.primary)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.55), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

/// Bandes basse et droite d'un carré : la zone de la poignée hors du contenu du panneau.
private struct CornerBand: Shape {
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(CGRect(x: rect.minX, y: rect.maxY - width, width: rect.width, height: width))
        path.addRect(CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height - width))
        return path
    }
}

/// Dessin de la poignée, seul (rendus PNG).
struct DetachGrip: View {
    var cornerRadius: CGFloat = 24
    var lit = false
    var pressed = false

    var body: some View {
        Canvas { context, size in
            // Arc concentrique au coin du panneau, à 6 pt du bord, et un point au milieu de l'arc.
            let center = CGPoint(x: size.width - cornerRadius, y: size.height - cornerRadius)
            let radius = cornerRadius - 6
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .degrees(8), endAngle: .degrees(82), clockwise: false)
            let color = lit ? Palette.accent : Color.white.opacity(0.45)
            context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: pressed ? 3 : 2.2, lineCap: .round))
            let dot = CGPoint(x: center.x + radius * cos(.pi / 4), y: center.y + radius * sin(.pi / 4))
            let dotRadius: CGFloat = pressed ? 3.4 : 2.6
            context.fill(Path(ellipseIn: CGRect(x: dot.x - dotRadius, y: dot.y - dotRadius, width: 2 * dotRadius,
                                                height: 2 * dotRadius)), with: .color(color))
        }
        .animation(.easeOut(duration: 0.12), value: lit)
        .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

// MARK: - Goutte

/// Goutte en cours (fenêtre de la goutte) ; à part de `BubbleModel` : la bulle ne se redessine pas à chaque mouvement.
final class GooModel: ObservableObject {
    /// nil = rien à dessiner.
    @Published var state: GooState?
    /// Goutte sous la souris, lue à chaque image sans être publiée : une image par rafraîchissement de l'écran, et non
    /// une de plus à chaque mouvement de souris.
    var liveDrop: CGPoint?

    func shapes(at date: Date) -> GooShapes? {
        guard var state else { return nil }
        if let liveDrop { state.drop = liveDrop }
        return state.shapes(at: date)
    }
}

/// Fenêtre de la goutte : redessinée à chaque image tant qu'une animation est en cours ; au repos, une image fixe.
struct GooView: View {
    @ObservedObject var goo: GooModel
    let color: Color

    var body: some View {
        if let state = goo.state {
            if state.mode == .rest {
                GooCanvas(shapes: state.shapes(at: Date()), color: color)
            } else {
                TimelineView(.animation) { timeline in
                    if let shapes = goo.shapes(at: timeline.date) { GooCanvas(shapes: shapes, color: color) }
                }
            }
        }
    }
}

/// Formes floutées puis seuillées : les cercles se fondent en liquide (métaballes), le col s'amincit et se rompt.
struct GooCanvas: View {
    let shapes: GooShapes
    let color: Color

    /// Col continu : une bande dont la largeur suit les cercles (des cercles seuls s'égrèneraient une fois fins).
    static func neckPath(_ neck: [GooShapes.Circle]) -> Path {
        var path = Path()
        guard let first = neck.first, let last = neck.last, neck.count > 1 else { return path }
        let length = hypot(last.center.x - first.center.x, last.center.y - first.center.y)
        guard length > 0 else { return path }
        let normal = CGPoint(x: -(last.center.y - first.center.y) / length, y: (last.center.x - first.center.x) / length)
        let left = neck.map { CGPoint(x: $0.center.x + normal.x * $0.radius, y: $0.center.y + normal.y * $0.radius) }
        let right = neck.map { CGPoint(x: $0.center.x - normal.x * $0.radius, y: $0.center.y - normal.y * $0.radius) }
        path.addLines(left + right.reversed())
        path.closeSubpath()
        return path
    }

    var body: some View {
        Canvas { context, _ in
            // Ajoutés dans cet ordre, appliqués dans l'ordre inverse : flou, puis seuil.
            context.addFilter(.alphaThreshold(min: 0.5, color: color))
            context.addFilter(.blur(radius: Goo.blur))
            context.drawLayer { layer in
                layer.fill(Path(roundedRect: shapes.body, cornerRadius: shapes.bodyRadius, style: .continuous),
                           with: .color(.black))
                layer.fill(Self.neckPath(shapes.neck), with: .color(.black))
                for circle in shapes.neck + [shapes.drop] where circle.radius > 0.5 {
                    layer.fill(Path(ellipseIn: CGRect(x: circle.center.x - circle.radius,
                                                      y: circle.center.y - circle.radius,
                                                      width: 2 * circle.radius, height: 2 * circle.radius)),
                               with: .color(.black))
                }
            }
        }
    }
}

/// Côté notch du retour aimanté : la pointe qui descend vers la bulle et le pont (dégradé de la couleur de la notch à
/// celle de la bulle), le bord bas de la notch bombé ou parcouru par l'onde. Le contour de la bulle est dessiné par
/// `RevolverBubble`, avec le barillet.
struct FerroCanvas: View {
    let shapes: FerroShapes
    /// Notch dans la fenêtre (y vers le bas).
    let notch: CGRect
    let notchColor: Color
    let fill: Color

    static func polygon(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count > 2 else { return path }
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    var body: some View {
        Canvas { context, _ in
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [notchColor, fill]), startPoint: CGPoint(x: shapes.center.x, y: notch.maxY),
                endPoint: CGPoint(x: shapes.center.x, y: max(shapes.center.y, notch.maxY + 1)))
            context.fill(Self.polygon(shapes.edge), with: .color(notchColor))
            context.fill(Self.polygon(shapes.cone), with: shading)
            context.fill(Self.polygon(shapes.bridge), with: shading)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Bulle

/// Racine de la fenêtre de la bulle : la bulle en barillet, ou le panneau qui en sort.
struct BubbleRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var bubble: BubbleModel
    @ObservedObject var store: SessionStore
    @ObservedObject var registry: ModuleRegistry
    @ObservedObject var prefs: Preferences
    let actions: NotchActions
    let input: BubbleInput

    private var motion: Animation { NotchMotion.animation(prefs.animationSpeed, reduceMotion: model.reduceMotion) }
    private var panelOpen: Bool { model.bubble == .bubblePanel }

    /// Repliée sur une vraie encoche, la notch est noire (voir `NotchRootView.fill`).
    private var notchColor: Color { prefs.tintCollapsed && !model.hasNotch ? prefs.panelColor : .black }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if panelOpen {
                panel
                    // Le contenu sort de la chambre du haut (son icône) et s'y referme.
                    .transition(model.reduceMotion ? .opacity
                                : .scale(scale: 0.08, anchor: bubble.chamberAnchor).combined(with: .opacity))
            } else {
                revolver
                    .transition(model.reduceMotion ? .opacity
                                : .scale(scale: 0.6, anchor: bubble.anchor).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .animation(motion, value: panelOpen)
        .animation(.easeOut(duration: 0.15), value: bubble.ghost)
        // Les couleurs d'accent sont lues au rendu : la vue est reconstruite quand l'accent change.
        .id(prefs.accentHex)
    }

    /// La bulle ; près de la notch, son contour de ferrofluide et la pointe de la notch, redessinés à chaque image. Même
    /// place dans la hiérarchie dans les deux cas : le glisser en cours sur la bulle n'est pas interrompu.
    private var revolver: some View {
        let tabs = registry.enabled.map { RevolverBubble.Tab($0) }
        let activity = registry.earTabs(claude: store.indicator, claudeEars: store.ears)
        let ferro = bubble.ferro
        return TimelineView(.animation(minimumInterval: nil, paused: ferro == nil)) { timeline in
            let shapes = ferro?.shapes(at: timeline.date)
            ZStack(alignment: .topLeading) {
                if let ferro, let shapes {
                    FerroCanvas(shapes: shapes, notch: ferro.notch, notchColor: notchColor, fill: prefs.panelColor)
                }
                RevolverBubble(tabs: tabs, turn: bubble.turn, activity: activity, claudeEars: store.ears,
                               fill: prefs.panelColor, nearNotch: bubble.nearNotch, reduceMotion: model.reduceMotion,
                               input: input, outline: shapes.map { Self.outline($0) },
                               contentScale: shapes?.contentScale ?? 1,
                               contentOpacity: Double(shapes?.contentOpacity ?? 1),
                               rimOpacity: Double(shapes?.rimOpacity ?? 1))
                    .scaleEffect(bubble.scale)
                    .opacity(bubble.ghost ? 0.55 : 1)
                    .position(shapes?.center ?? bubble.centerInWindow)
            }
        }
    }

    /// Contour du ferrofluide dans le repère de la bulle (coin haut gauche de son cadre).
    static func outline(_ shapes: FerroShapes) -> Path {
        let half = BubbleGeometry.radius
        return FerroCanvas.polygon(shapes.outline)
            .offsetBy(dx: half - shapes.center.x, dy: half - shapes.center.y)
    }

    /// Le panneau de la notch (onglets, menu « … », contenu, ou la barre de commande), dans une forme arrondie au lieu
    /// de la notch.
    private var panel: some View {
        Group {
            if model.isCommandBarOpen {
                CommandBarView(registry: registry, prefs: prefs, notchHeight: BubbleRootView.panelTopInset,
                               close: actions.closeCommandBar)
            } else {
                ExpandedPanel(registry: registry, prefs: prefs, selection: $model.selectedTab,
                              editingTabs: $model.isEditingTabs, compact: false,
                              notchSize: CGSize(width: 0, height: BubbleRootView.panelTopInset),
                              tabAnimation: motion, reduceMotion: model.reduceMotion, actions: actions)
            }
        }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(prefs.panelColor.opacity(prefs.backgroundOpacity)))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .background(GeometryReader { proxy in
                Color.clear.preference(key: BubblePanelSizeKey.self, value: proxy.size)
            })
            .onPreferenceChange(BubblePanelSizeKey.self) { input.panelSized($0) }
            // Pincer : retour au barillet.
            .simultaneousGesture(MagnificationGesture().onEnded { if $0 < 0.8 { input.back() } })
            .shadow(color: .black.opacity(prefs.panelShadow ? 0.45 : 0), radius: 14, y: 6)
            .animation(motion, value: model.selectedTab)
            .animation(motion, value: model.isEditingTabs)
            .animation(motion, value: model.isCommandBarOpen)
            .padding(BubbleGeometry.panelMargin)
    }

    /// Marge au-dessus de la barre d'onglets (la notch y a la bande de la barre des menus).
    static let panelTopInset: CGFloat = 8
}

/// Panneau de la bulle : retour au barillet, en tête de la barre d'onglets. Une flèche et un petit barillet, sur une
/// capsule qui s'allume au survol.
struct BackToRevolverButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 10, weight: .bold))
                RevolverGlyph()
                    .frame(width: 13, height: 13)
            }
            .foregroundColor(hovering ? .black : Palette.primary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(hovering ? Palette.accent : Color.white.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(L("Revenir au barillet", table: "Bubble"))
        .accessibilityLabel(Text(L("Revenir au barillet", table: "Bubble")))
    }
}

/// Petit barillet : six chambres autour d'un moyeu, à la couleur du texte.
struct RevolverGlyph: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let ring = min(size.width, size.height) / 2 - 2
            for index in 0..<6 {
                let angle = Double(index) * .pi / 3
                let point = CGPoint(x: center.x + ring * sin(angle), y: center.y - ring * cos(angle))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2)),
                             with: .foreground)
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8)),
                         with: .foreground)
        }
    }
}

/// `max`, comme `NotchSizeKey` : la valeur par défaut d'un voisin n'écrase pas la mesure.
private struct BubblePanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

/// Bulle ronde, onglets en barillet de revolver : une chambre par onglet, l'onglet du haut est l'onglet actif (repère
/// fixe au-dessus). Le moyeu porte son titre. Anneau et pastille : les activités des intercalaires.
///
/// Souris : clic au centre ou sur l'onglet du haut = ouvrir ; clic sur une autre chambre = la tourner en haut ; glisser
/// sur les chambres = tourner, cran par cran ; glisser ailleurs = déplacer ; double-clic sur le bord = rattacher. La
/// molette arrive par la vue AppKit (`BubbleHostingView`).
struct RevolverBubble: View {
    struct Tab: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String

        init(_ module: any NotchModule) {
            id = module.id
            title = module.title
            symbol = module.symbol
        }

        init(id: String, title: String, symbol: String) {
            self.id = id
            self.title = title
            self.symbol = symbol
        }
    }

    let tabs: [Tab]
    let turn: Int
    let activity: [EarTab]
    let claudeEars: SessionStore.EarsContent?
    let fill: Color
    var nearNotch = false
    var reduceMotion = false
    var input = BubbleInput()
    /// Retour aimanté : contour de ferrofluide (repère de la bulle, pointes comprises) à la place du cercle ; le
    /// barillet rapetisse et s'efface pendant l'aspiration.
    var outline: Path?
    var contentScale: CGFloat = 1
    var contentOpacity: Double = 1
    var rimOpacity: Double = 1

    private enum Drag {
        case pending(Revolver.Zone)
        case rotating(RevolverDrag)
        case moving
    }

    @State private var drag: Drag?

    private static let diameter = BubbleGeometry.diameter
    private var center: CGPoint { CGPoint(x: Self.diameter / 2, y: Self.diameter / 2) }
    private var revolver: Revolver { Revolver(count: tabs.count, turn: turn) }
    private var chamber: CGFloat { Revolver.chamberDiameter(count: tabs.count) }
    private var activeTab: Tab? { tabs.indices.contains(revolver.activeIndex) ? tabs[revolver.activeIndex] : nil }

    /// Activités par onglet (le « +N » rendu à chacune de ses activités).
    private var activityById: [String: EarTab] {
        var result: [String: EarTab] = [:]
        for tab in activity {
            if case .more(let hidden) = tab.kind {
                for inner in hidden { result[inner.id] = inner }
            } else {
                result[tab.id] = tab
            }
        }
        return result
    }

    private var top: EarTab? { activity.first.flatMap { tab in
        if case .more(let hidden) = tab.kind { return hidden.first }
        return tab
    } }

    private func accent(_ tab: EarTab) -> Color { tab.accentHex.flatMap { Color(hex: $0) } ?? Palette.accent }

    private var rotation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.62)
    }

    var body: some View {
        ZStack {
            if let outline { outline.fill(fill) } else { Circle().fill(fill) }
            Group {
                cylinder
                firingMark
                hub
            }
            .scaleEffect(contentScale)
            .opacity(contentOpacity)
            // Bord dans la forme, comme `strokeBorder` : deux fois plus épais, coupé par le contour.
            if let outline {
                outline.stroke(rimColor, lineWidth: 2 * rimWidth).clipShape(outline).opacity(rimOpacity)
            } else {
                Circle().strokeBorder(rimColor, lineWidth: rimWidth)
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        .overlay(alignment: .bottom) { pill.opacity(contentOpacity) }
        .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
        .gesture(gesture)
        .help(L("Centre : ouvrir. Molette ou glisser sur les onglets : tourner. Bord : déplacer ; double-clic pour "
                + "rattacher à la notch.", table: "Bubble"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("Bulle de la notch", table: "Bubble")))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint(Text(L("Balaie vers le haut ou le bas pour tourner le barillet, active pour ouvrir.",
                                  table: "Bubble")))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: input.rotate(1)
            case .decrement: input.rotate(-1)
            @unknown default: break
            }
        }
        .accessibilityAction { input.open() }
        .accessibilityAction(named: Text(L("Rattacher à la notch", table: "Bubble"))) { input.reattach() }
    }

    private var accessibilityValue: String {
        guard let activeTab else { return "" }
        var value = String(format: L("%@, onglet %d sur %d", table: "Bubble"), activeTab.title,
                           revolver.activeIndex + 1, tabs.count)
        if let top { value += ". " + String(format: L("Activité : %@", table: "Bubble"), top.label(tabs)) }
        return value
    }

    private var rimWidth: CGFloat { nearNotch ? 3 : (top == nil ? 1 : 2.5) }

    private var rimColor: Color {
        if nearNotch { return Palette.accent }
        guard let top else { return .white.opacity(0.12) }
        return accent(top)
    }

    /// Le barillet tourne d'un bloc ; chaque icône se redresse pour rester lisible.
    private var cylinder: some View {
        let byId = activityById
        let cylinderRadius = Revolver.ringRadius + chamber / 2 + 5
        return ZStack {
            Circle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 2 * cylinderRadius, height: 2 * cylinderRadius)
            // Cannelures entre les chambres, au bord du barillet.
            ForEach(tabs.indices, id: \.self) { index in
                let angle = (Double(index) + 0.5) * revolver.step
                Capsule()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: 3, height: 9)
                    .offset(y: -(cylinderRadius - 5))
                    .rotationEffect(.radians(angle))
            }
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                chamberView(tab, active: index == revolver.activeIndex, activity: byId[tab.id])
                    .rotationEffect(.radians(-revolver.rotation))
                    .position(Revolver(count: tabs.count, turn: 0).position(of: index, center: center))
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .rotationEffect(.radians(revolver.rotation))
        .animation(rotation, value: turn)
    }

    private func chamberView(_ tab: Tab, active: Bool, activity: EarTab?) -> some View {
        ZStack {
            Circle().fill(Color.black.opacity(active ? 0.2 : 0.45))
            Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            Image(systemName: tab.symbol)
                .font(.system(size: chamber * 0.45, weight: .semibold))
                .foregroundColor(active ? Palette.primary : Palette.secondary)
        }
        .frame(width: chamber, height: chamber)
        .overlay(alignment: .topTrailing) {
            if let activity {
                Circle()
                    .fill(accent(activity))
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(fill, lineWidth: 1.5))
                    .offset(x: 2, y: -2)
            }
        }
    }

    /// Repère fixe de la chambre du haut (l'onglet actif).
    private var firingMark: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.accent, lineWidth: 2)
                .frame(width: chamber + 6, height: chamber + 6)
                .position(x: center.x, y: center.y - Revolver.ringRadius)
            Triangle()
                .fill(Palette.accent)
                .frame(width: 8, height: 5)
                .position(x: center.x, y: center.y - Revolver.ringRadius - chamber / 2 - 9)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .allowsHitTesting(false)
    }

    private var hub: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.09))
            Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            if let activeTab {
                Text(verbatim: activeTab.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(width: 2 * Revolver.hubRadius - 10)
                    .id(activeTab.id)
                    .transition(.opacity)
            }
        }
        .frame(width: 2 * Revolver.hubRadius, height: 2 * Revolver.hubRadius)
        .animation(.easeOut(duration: 0.15), value: activeTab?.id)
    }

    /// Pastille de l'activité la plus prioritaire, à cheval sur le bas de la bulle (comme un intercalaire).
    @ViewBuilder private var pill: some View {
        if let top {
            let accent = accent(top)
            HStack(spacing: EarTabs.iconGap) {
                EarTabIcon(tab: top, accent: accent)
                EarTabInfo(tab: top, claudeEars: claudeEars, accent: accent)
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Color.black))
            .overlay(Capsule().strokeBorder(accent.opacity(0.6), lineWidth: 1))
            .fixedSize()
            .offset(y: 10)
            .allowsHitTesting(false)
        }
    }

    // MARK: Gestes

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                switch drag {
                case nil:
                    drag = .pending(revolver.zone(at: value.startLocation, center: center))
                case .pending(let zone):
                    guard hypot(value.translation.width, value.translation.height) > 3 else { return }
                    if case .chamber = zone {
                        var rotating = RevolverDrag(startAngle: Revolver.angle(of: value.startLocation, center: center),
                                                    step: revolver.step)
                        let steps = rotating.move(to: Revolver.angle(of: value.location, center: center))
                        drag = .rotating(rotating)
                        if steps != 0 { input.rotate(steps) }
                    } else {
                        drag = .moving
                        input.moveBegan()
                        input.moved()
                    }
                case .rotating(var rotating):
                    let steps = rotating.move(to: Revolver.angle(of: value.location, center: center))
                    drag = .rotating(rotating)
                    if steps != 0 { input.rotate(steps) }
                case .moving:
                    input.moved()
                }
            }
            .onEnded { value in
                defer { drag = nil }
                switch drag {
                case .moving:
                    input.moveEnded()
                case .pending(let zone):
                    tap(zone, clickCount: NSApp.currentEvent?.clickCount ?? 1)
                case .rotating, nil:
                    break
                }
            }
    }

    private func tap(_ zone: Revolver.Zone, clickCount: Int) {
        switch zone {
        case .hub:
            input.open()
        case .chamber(let index):
            let steps = revolver.steps(toTop: index)
            if steps == 0 { input.open() } else { input.rotate(steps) }
        case .rim where clickCount >= 2:
            input.reattach()
        case .rim, .outside:
            break
        }
    }
}

private extension EarTab {
    /// Activité dite par VoiceOver : le titre de l'onglet et son information courte.
    func label(_ tabs: [RevolverBubble.Tab]) -> String {
        let title = tabs.first { $0.id == id }?.title ?? id
        return text.isEmpty ? title : "\(title) \(text)"
    }
}

/// Petit triangle pointé vers le bas (repère de l'onglet actif).
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
