import AppKit
import SwiftUI

enum Palette {
    static let claudeOrange = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    /// Couleur d'accent choisie dans les réglages (orange Claude par défaut).
    static var accent: Color { Preferences.shared.accent }
    static let amber = Color(red: 0xF5 / 255, green: 0xB8 / 255, blue: 0x3D / 255)
    static let green = Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255)
    static let red = Color(red: 0xF8 / 255, green: 0x71 / 255, blue: 0x71 / 255)
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.6)
    static let card = Color.white.opacity(0.05)
}

let notchSpring = Animation.spring(response: 0.42, dampingFraction: 0.78)

// MARK: - Forme

/// Bas arrondi et petits évasements concaves en haut, pour se fondre dans la vraie notch.
struct NotchShape: Shape {
    /// Rayons de la notch repliée : évasement concave du haut (l'encoche virtuelle ; une vraie encoche a le sien) et coins
    /// du bas. Les intercalaires les reprennent tels quels à leur bord extérieur (`EarTabShape`) : même courbe, même rayon.
    static let collapsedTopRadius: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 9

    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let bottom = max(0, min(bottomRadius, (rect.width - 2 * top) / 2, rect.height - top))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                          control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// `max` et non `value = nextValue()` : la valeur par défaut d'un voisin écraserait la mesure.
private struct NotchSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

// MARK: - Racine

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var store: SessionStore
    @ObservedObject var registry: ModuleRegistry
    @ObservedObject var prefs: Preferences
    let actions: NotchActions

    private var expanded: Bool { model.isExpanded }
    private var compact: Bool { model.isFullScreen && prefs.fullScreenBehavior == .compact }
    /// Intercalaires de la notch repliée : un par activité, de part et d'autre de la notch (voir `EarTabs`).
    private var layout: EarTabsLayout {
        EarTabsLayout(tabs: registry.earTabs(claude: store.indicator, claudeEars: store.ears),
                      notch: model.notchSize, mode: prefs.earTabsMode)
    }
    private var showsEars: Bool { !layout.isEmpty }
    /// Ressort choisi dans les réglages, ou fondu simple avec « Réduire les animations ».
    private var motion: Animation { NotchMotion.animation(prefs.animationSpeed, reduceMotion: model.reduceMotion) }
    /// Repliée sur une vraie encoche : noir pur pour s'y fondre. Teintée seulement sur demande, sans encoche.
    private var fill: Color {
        expanded || (prefs.tintCollapsed && !model.hasNotch) ? prefs.panelColor : .black
    }
    /// Replié sur une vraie encoche : aucun évasement, la forme est exactement l'encoche (sinon 6 pt de noir de plus de
    /// chaque côté, visibles du côté sans intercalaire, et une forme mesurée 12 pt plus large que l'encoche).
    private var topRadius: CGFloat { expanded ? 12 : (model.hasNotch ? 0 : NotchShape.collapsedTopRadius) }
    private var bottomRadius: CGFloat { expanded ? (compact ? 18 : 24) : NotchShape.collapsedBottomRadius }
    /// Repliée : la notch seule ; les intercalaires se posent contre elle (`EarTabsView`).
    private var bodyWidth: CGFloat {
        expanded ? prefs.expandedWidth(compact: compact && !model.isCommandBarOpen) : model.notchSize.width
    }

    /// Poignée de l'angle bas droit : panneau déplié (pas en plein écran compact ni en mode édition).
    private var showsHandle: Bool {
        expanded && !compact && prefs.allowsDetach && !model.isEditingTabs && model.bubble == .attached
    }

    var body: some View {
        VStack(spacing: 0) {
            notch
                // Les couleurs d'accent sont lues au rendu : la vue est reconstruite quand l'accent change.
                .id(prefs.accentHex)
            Spacer(minLength: 0)
        }
        // Décollage : la goutte (autre fenêtre, dessous) prend la place de la notch.
        .opacity(model.gooActive ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: model.gooActive)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        // Plein écran compact : pas de barre d'onglets, donc pas de mode édition.
        .onChange(of: compact) { if $0 { model.isEditingTabs = false } }
    }

    private var notch: some View {
        ZStack(alignment: .top) {
            if expanded, model.isCommandBarOpen {
                CommandBarView(registry: registry, prefs: prefs, notchHeight: model.notchSize.height,
                               close: actions.closeCommandBar)
                    .transition(.opacity)
            } else if expanded {
                ExpandedPanel(registry: registry, prefs: prefs, selection: $model.selectedTab,
                              editingTabs: $model.isEditingTabs, compact: compact, notchSize: model.notchSize,
                              tabAnimation: motion, reduceMotion: model.reduceMotion, actions: actions)
                    .transition(.asymmetric(
                        insertion: (model.reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                            .animation(motion.delay(0.06)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))
                    ))
            }
        }
        .frame(width: bodyWidth, alignment: .top)
        .frame(minHeight: model.notchSize.height, alignment: .top)
        .padding(.horizontal, topRadius)
        .background(background)
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
        .overlay(alignment: .bottomTrailing) {
            if showsHandle {
                DetachHandle(begin: actions.beginDetach, detach: { actions.detach?() }, cornerRadius: bottomRadius,
                             takeHint: prefs.takeHandleHint)
                    .padding(.trailing, topRadius)
                    .transition(.opacity)
            }
        }
        .shadow(color: .black.opacity(expanded && prefs.panelShadow ? 0.45 : 0), radius: 14, y: 6)
        // Replié et sans activité sur une vraie encoche : exactement l'encoche, donc invisible. Sans encoche,
        // la forme reste dessinée : c'est l'encoche virtuelle.
        .opacity(expanded || showsEars || !model.hasNotch ? 1 : 0)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: NotchSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(NotchSizeKey.self) { size in model.contentSize = size }
        .animation(motion, value: expanded)
        .animation(motion, value: showsEars)
        .animation(motion, value: compact)
        .animation(motion, value: model.selectedTab)
        .animation(motion, value: model.isEditingTabs)
        .animation(motion, value: model.isCommandBarOpen)
        // Hors de la forme de la notch (qui rogne) : les intercalaires dépassent de chaque côté.
        .overlay(alignment: .top) {
            if !expanded, showsEars {
                EarTabsView(layout: layout, hovered: model.hoveredTab, claudeEars: store.ears, fill: fill,
                            animation: motion, registry: registry, openTab: actions.openTab,
                            cardHeightChanged: { model.tabCardHeight = $0 })
                    .transition(.opacity)
            }
        }
    }

    /// Fond choisi, translucide une fois déplié si les réglages le demandent ; la bande de la notch reste opaque.
    private var background: some View {
        ZStack(alignment: .top) {
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                .fill(fill.opacity(expanded ? prefs.backgroundOpacity : 1))
            fill.frame(height: model.notchSize.height)
        }
    }
}

// MARK: - Replié

/// Barres d'égaliseur d'un intercalaire, animées par Core Animation comme `AnimatedGlyphView` (rien par image côté app).
struct EqualizerBars: NSViewRepresentable {
    /// Couleur des barres ; l'accent des réglages par défaut.
    var color: Color?

    func makeNSView(context: Context) -> EqualizerView { EqualizerView(color: color.map { NSColor($0) }) }
    func updateNSView(_ view: EqualizerView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EqualizerView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

final class EqualizerView: NSView {
    private static let barWidth: CGFloat = 2.5
    private static let gap: CGFloat = 2
    private static let height: CGFloat = 12
    /// Hauteur au repos (rendus hors écran) et durée d'un aller, différentes par barre pour un mouvement irrégulier.
    private static let rest: [CGFloat] = [0.55, 0.9, 0.4, 0.75]
    private static let periods: [CFTimeInterval] = [0.42, 0.31, 0.47, 0.36]

    private let bars = rest.map { _ in CALayer() }
    private let color: NSColor?

    init(color: NSColor? = nil) {
        self.color = color
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        bars.forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) { nil }

    private static var size: NSSize {
        NSSize(width: CGFloat(rest.count) * (barWidth + gap) - gap, height: height)
    }

    override var intrinsicContentSize: NSSize { Self.size }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            bar.backgroundColor = (color ?? NSColor(Palette.accent)).cgColor
            bar.cornerRadius = Self.barWidth / 2
            bar.frame = NSRect(x: CGFloat(index) * (Self.barWidth + Self.gap), y: 0, width: Self.barWidth,
                               height: Self.height)
            bar.transform = CATransform3DMakeScale(1, Self.rest[index], 1)
            guard window != nil else { continue }
            let level = CABasicAnimation(keyPath: "transform.scale.y")
            level.fromValue = 0.25
            level.toValue = 1
            level.duration = Self.periods[index]
            level.autoreverses = true
            level.repeatCount = .infinity
            level.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            level.isRemovedOnCompletion = false
            bar.add(level, forKey: "level")
        }
        CATransaction.commit()
    }
}

struct IndicatorGlyph: View {
    let indicator: NotchIndicator

    var body: some View {
        switch indicator {
        case .working:
            GlyphSpinner(size: 14)
        case .attention:
            PulsingHand()
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Palette.green)
        case .none:
            EmptyView()
        }
    }
}

/// Spinner à glyphes façon Claude Code (· ✢ ✳ ✶ ✻ ✽).
struct GlyphSpinner: NSViewRepresentable {
    var size: CGFloat = 13

    func makeNSView(context: Context) -> AnimatedGlyphView { AnimatedGlyphView(style: .spinner, size: size) }
    func updateNSView(_ view: AnimatedGlyphView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnimatedGlyphView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// Main ambre qui pulse : une permission ou une réponse est attendue.
struct PulsingHand: NSViewRepresentable {
    var size: CGFloat = 13

    func makeNSView(context: Context) -> AnimatedGlyphView { AnimatedGlyphView(style: .pulsingHand, size: size) }
    func updateNSView(_ view: AnimatedGlyphView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnimatedGlyphView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// Animation confiée à Core Animation : images pré-rendues, animées par le serveur de rendu.
/// Un TimelineView SwiftUI relançait tout le layout du NSHostingView à chaque image (~8 % de CPU).
final class AnimatedGlyphView: NSView {
    enum Style {
        case spinner
        case pulsingHand
    }

    private static let glyphs = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    private static let glyphInterval: CFTimeInterval = 0.12

    private let style: Style
    private let size: CGFloat
    private let content = CALayer()

    init(style: Style, size: CGFloat) {
        self.style = style
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size + 4, height: size + 4))
        wantsLayer = true
        content.contentsGravity = .center
        layer?.addSublayer(content)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: size + 4, height: size + 4) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restart()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        restart()
    }

    private func restart() {
        guard let window else {
            content.removeAllAnimations()
            return
        }
        let scale = window.backingScaleFactor
        content.contentsScale = scale
        content.removeAllAnimations()

        switch style {
        case .spinner:
            let font = NSFont.systemFont(ofSize: size, weight: .bold)
            let color = NSColor(Palette.accent)
            let images = Self.glyphs.compactMap { glyph in
                Self.render(scale: scale, box: bounds.size) { rect in
                    let text = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: color])
                    let textSize = text.size()
                    text.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2))
                }
            }
            content.contents = images.first
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = images
            animation.calculationMode = .discrete
            animation.duration = Self.glyphInterval * Double(images.count)
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            content.add(animation, forKey: "glyphs")

        case .pulsingHand:
            let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(Palette.amber)]))
            guard let symbol = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            content.contents = Self.render(scale: scale, box: bounds.size) { rect in
                let symbolSize = symbol.size
                symbol.draw(in: NSRect(x: (rect.width - symbolSize.width) / 2, y: (rect.height - symbolSize.height) / 2,
                                       width: symbolSize.width, height: symbolSize.height))
            }
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.35
            opacity.toValue = 1
            let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
            scaleAnimation.fromValue = 0.9
            scaleAnimation.toValue = 1.06
            let group = CAAnimationGroup()
            group.animations = [opacity, scaleAnimation]
            group.duration = 0.7
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.isRemovedOnCompletion = false
            content.add(group, forKey: "pulse")
        }
    }

    /// Image bitmap à la bonne densité d'écran.
    private static func render(scale: CGFloat, box: CGSize, draw: (NSRect) -> Void) -> CGImage? {
        guard box.width > 0, box.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.width * scale),
                                            pixelsHigh: Int(box.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = box
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        draw(NSRect(origin: .zero, size: box))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }
}

// MARK: - Déplié

/// Panneau déplié : bande de la notch, en-tête (onglets, accessoire de l'onglet actif, menu « … »), puis le
/// contenu de l'onglet actif. En plein écran compact : le résumé de chaque module, sans onglets.
struct ExpandedPanel: View {
    @ObservedObject var registry: ModuleRegistry
    @ObservedObject var prefs: Preferences
    @Binding var selection: String
    @Binding var editingTabs: Bool
    let compact: Bool
    let notchSize: CGSize
    /// Ressort du changement d'onglet (vitesse des réglages, ou fondu).
    var tabAnimation: Animation = notchSpring
    var reduceMotion = false
    let actions: NotchActions

    static let spacing: CGFloat = 10
    static let bottomPadding: CGFloat = 14
    static let horizontalPadding: CGFloat = 14
    /// Ligne des onglets, sous la bande de la barre des menus.
    static let headerHeight: CGFloat = 24
    /// Fenêtre de 480 pt moins la place de l'ombre.
    static let maxPanelHeight: CGFloat = 460

    private var width: CGFloat { prefs.expandedWidth(compact: compact) }

    /// Place laissée au contenu sous l'en-tête pour que le panneau tienne dans sa fenêtre.
    private var contentMaxHeight: CGFloat {
        Self.maxPanelHeight - notchSize.height - Self.headerHeight - Self.spacing - Self.bottomPadding
    }

    private var selected: (any NotchModule)? {
        registry.enabled.first { $0.id == selection } ?? registry.enabled.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            header
            if compact {
                compactContent
            } else if let module = selected {
                module.makeView()
                    .id(module.id)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
                    // Mode édition : le contenu s'efface et ne prend plus les clics (un clic dessus sort du mode).
                    .opacity(editingTabs ? 0.35 : 1)
                    .allowsHitTesting(!editingTabs)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.bottom, Self.bottomPadding)
        .frame(width: width, alignment: .top)
        .background {
            // Clic hors de la barre (la barre garde les siens) : sortie du mode édition.
            if editingTabs {
                Color.clear.contentShape(Rectangle()).onTapGesture { editingTabs = false }
            }
        }
        .environment(\.notchContentWidth, width - 2 * Self.horizontalPadding)
        .environment(\.notchContentMaxHeight, contentMaxHeight)
    }

    /// La bande à hauteur de barre des menus reste vide : son milieu est la notch physique. L'en-tête vient dessous.
    private var header: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchSize.height)
            headerRow.frame(height: Self.headerHeight)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            if compact {
                if registry.isClaudeEnabled { registry.module(ModuleRegistry.claudeId)?.makeTabIcon() }
                Spacer(minLength: 8)
            } else {
                if let back = actions.backToRevolver { BackToRevolverButton(action: back) }
                NotchTabBar(registry: registry, selection: $selection, editing: $editingTabs, animation: tabAnimation,
                            reduceMotion: reduceMotion)
                if editingTabs {
                    Spacer(minLength: 8)
                    doneButton
                } else {
                    // Titre après la rangée d'onglets, pas dedans : sa largeur ne déplace aucun onglet.
                    if let selected {
                        Text(selected.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Palette.primary)
                            .lineLimit(1)
                            .fixedSize()
                            .id(selected.id)
                            .transition(.opacity)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 8)
                    selected?.makeHeaderAccessory()
                }
            }
            // En mode édition, « OK » prend la place du menu « … ».
            if !editingTabs {
                NotchMoreMenu(prefs: prefs, claudeEnabled: registry.isClaudeEnabled, actions: actions)
            }
        }
    }

    private var doneButton: some View {
        Button { editingTabs = false } label: {
            Text("OK")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .frame(height: 20)
                .background(Capsule().fill(Palette.accent))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    /// Résumé de chaque module activé qui en fournit un, dans l'ordre des onglets.
    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(registry.enabled.map { $0.id }, id: \.self) { id in
                registry.module(id)?.makeCompactView()
            }
        }
    }
}

/// Barre d'onglets en icônes, de largeur fixe : l'onglet actif est marqué par une capsule qui glisse d'un onglet à
/// l'autre, son titre est affiché à côté de la barre. Clic, ou survol de 0,2 s, pour changer d'onglet (en passant
/// dessus, rien ne change). Un onglet ne change jamais de taille : sinon les autres glisseraient sous la souris et
/// le survol en ouvrirait un autre.
///
/// Appui long : mode édition, comme les apps sur iPhone. Les icônes tremblent (pas avec « Réduire les animations »)
/// et se glissent, les autres s'écartant ; « − » masque un onglet, « + » en bout de barre en remet un ; le survol ne
/// change plus d'onglet. Hors du glisser, aucun onglet ne bouge : « − » est posé dessus, « + » après le dernier.
struct NotchTabBar: View {
    @ObservedObject var registry: ModuleRegistry
    @Binding var selection: String
    @Binding var editing: Bool
    var animation: Animation = notchSpring
    var reduceMotion = false

    @Namespace private var namespace
    @State private var hovered: String?
    /// Glisser en cours : l'onglet, son déplacement et la place visée.
    @State private var dragged: String?
    @State private var dragOffset: CGFloat = 0
    @State private var dropTarget: Int?
    /// Ordre posé au lâcher, montré jusqu'à ce que le registre le relise (au tour de boucle suivant).
    @State private var droppedOrder: [String]?

    static let hoverDelay: TimeInterval = 0.2
    static let spacing: CGFloat = 2
    /// Icône de 17 pt et 5 pt de chaque côté.
    static let tabWidth: CGFloat = 27
    private static let space = "notch-tab-bar"

    private var enabledIds: [String] { registry.enabled.map { $0.id } }
    private var ids: [String] { droppedOrder ?? enabledIds }

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                if let module = registry.module(id) { tab(module, index: index) }
            }
            if editing { addMenu }
        }
        .coordinateSpace(name: Self.space)
        .contentShape(Rectangle())
        .animation(animation, value: selection)
        // Simultané : le clic de l'onglet reste possible.
        .simultaneousGesture(LongPressGesture(minimumDuration: TabEditing.pressDuration).onEnded { _ in startEditing() },
                             including: editing ? .subviews : .all)
        // Mode édition : un clic sur la barre (hors « − » et « + ») n'en sort pas.
        .gesture(TapGesture(), including: editing ? .all : .subviews)
        .onChange(of: enabledIds) { _ in droppedOrder = nil }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Modifier les onglets")) { startEditing() }
    }

    private func startEditing() {
        hovered = nil
        editing = true
    }

    /// Une seule vue par onglet dans les deux modes (la capsule de l'onglet actif n'existe jamais deux fois).
    /// Rotation, échelle et décalage du mode édition ne changent pas la mise en page.
    private func tab(_ module: any NotchModule, index: Int) -> some View {
        let id = module.id
        let active = id == selection
        let isDragged = dragged == id
        let shift = dropTarget.flatMap { target in
            ids.firstIndex { $0 == dragged }.map { TabEditing.shift(index, from: $0, to: target) }
        } ?? 0
        return tabShape(active: active) {
            if editing {
                WiggleIcon(content: glyph(module, active: active), clockwise: index.isMultiple(of: 2),
                           isOn: !reduceMotion)
                    .frame(width: 17, height: 17)
                    .accessibilityHidden(true)
            } else {
                glyph(module, active: active)
            }
        }
        .overlay(alignment: .topLeading) {
            if editing, TabEditing.canHide(id, enabled: ids) { hideButton(module) }
        }
        .scaleEffect(isDragged ? 1.15 : 1)
        .offset(x: isDragged ? dragOffset : CGFloat(shift) * (Self.tabWidth + Self.spacing))
        .zIndex(isDragged ? 1 : 0)
        // En mode édition, le clic sur l'onglet ne change rien (et ne sort pas du mode).
        .onTapGesture { if !editing { selection = id } }
        .gesture(drag(id, from: index), including: editing ? .all : .subviews)
        .onHover { inside in hover(id, inside) }
        .help(module.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(module.title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selection = id }
        .accessibilityAction(named: Text("Déplacer à gauche")) { registry.moveTab(id, to: index - 1) }
        .accessibilityAction(named: Text("Déplacer à droite")) { registry.moveTab(id, to: index + 1) }
    }

    private func glyph(_ module: any NotchModule, active: Bool) -> AnyView {
        AnyView(Group {
            if let icon = module.makeTabIcon() {
                icon
            } else {
                Image(systemName: module.symbol)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .frame(width: 17, height: 17)
        .foregroundColor(active ? Palette.primary
                         : .white.opacity(editing ? 0.75 : hovered == module.id ? 0.85 : 0.5))
        .environment(\.colorScheme, .dark))
    }

    /// Même forme, même taille dans les deux modes : capsule de l'onglet actif, zone de clic.
    private func tabShape<Glyph: View>(active: Bool, @ViewBuilder glyph: () -> Glyph) -> some View {
        glyph()
            .padding(.horizontal, 5)
            .frame(height: 22)
            .background {
                if active {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .matchedGeometryEffect(id: "active-tab", in: namespace)
                }
            }
            .contentShape(Capsule())
    }

    /// L'onglet suit la souris, les autres s'écartent ; au lâcher, l'ordre est enregistré comme dans les réglages.
    private func drag(_ id: String, from index: Int) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                dragged = id
                dragOffset = value.translation.width
                let target = TabEditing.dropIndex(from: index, translation: value.translation.width,
                                                  slot: Self.tabWidth + Self.spacing, count: ids.count)
                if target != dropTarget { withAnimation(animation) { dropTarget = target } }
            }
            .onEnded { _ in
                let target = dropTarget ?? index
                withAnimation(animation) {
                    // Nouvel ordre et décalages remis à zéro ensemble : les onglets écartés restent où ils sont.
                    if target != index { droppedOrder = TabEditing.move(id, to: target, order: ids, enabled: ids) }
                    dragged = nil
                    dragOffset = 0
                    dropTarget = nil
                }
                if target != index { registry.moveTab(id, to: target) }
            }
    }

    private func hideButton(_ module: any NotchModule) -> some View {
        let id = module.id
        let label = String(format: L("Masquer « %@ »"), module.title)
        return Button {
            guard registry.hideTab(id) else { return }
            // L'onglet affiché disparaît : le premier qui reste prend sa place (règle des réglages).
            if selection == id, let first = ids.first(where: { $0 != id }) { selection = first }
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 7, weight: .black))
                .foregroundColor(.black)
                .frame(width: 12, height: 12)
                .background(Circle().fill(Color.white.opacity(0.9)))
                .contentShape(Circle().inset(by: -3))
        }
        .buttonStyle(.plain)
        .offset(x: -3, y: -4)
        .help(label)
        .accessibilityLabel(label)
        .transition(.scale.combined(with: .opacity))
    }

    /// « + » en bout de barre : les onglets masqués, pour en remettre un.
    private var addMenu: some View {
        let hidden = registry.hidden
        return Menu {
            ForEach(hidden.map { $0.id }, id: \.self) { id in
                if let module = registry.module(id) {
                    Button { registry.showTab(id) } label: { Label(module.title, systemImage: module.symbol) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(hidden.isEmpty ? 0.3 : 0.85))
                .frame(width: Self.tabWidth, height: 22)
                .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Le menu ignore la largeur de son étiquette : une case d'onglet, posée de l'extérieur.
        .frame(width: Self.tabWidth, height: 22)
        .disabled(hidden.isEmpty)
        .help(hidden.isEmpty ? L("Aucun onglet masqué") : L("Remettre un onglet"))
        .accessibilityLabel(L("Remettre un onglet"))
        .transition(.opacity)
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside {
            hovered = id
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay) {
                if hovered == id, selection != id, !editing { selection = id }
            }
        } else if hovered == id {
            hovered = nil
        }
    }
}

/// Tremblement du mode édition, confié à Core Animation comme `AnimatedGlyphView` : l'icône est posée dans sa
/// propre vue, que le serveur de rendu fait pivoter. Une animation SwiftUI répétée prenait un cœur entier (mesuré,
/// `TabEditingGestureTests.testEditModeCPU`). La vue n'existe qu'en mode édition, panneau ouvert.
struct WiggleIcon: NSViewRepresentable {
    let content: AnyView
    /// Sens de départ, alterné d'un onglet à l'autre.
    let clockwise: Bool
    /// Éteint avec « Réduire les animations ».
    let isOn: Bool

    func makeNSView(context: Context) -> WiggleView { WiggleView(content) }

    func updateNSView(_ view: WiggleView, context: Context) {
        view.hosting.rootView = content
        view.set(isOn: isOn, clockwise: clockwise)
    }
}

final class WiggleView: NSView {
    static let angle: CGFloat = 2.5
    static let period: CFTimeInterval = 0.13

    let hosting: NSHostingView<AnyView>
    private var isOn = false
    private var clockwise = true
    private var animatedSize = CGSize.zero

    init(_ content: AnyView) {
        hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        hosting.wantsLayer = true
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { nil }

    /// Les clics vont aux gestes SwiftUI de l'onglet (glisser, « − »), pas à l'icône.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isWiggling: Bool { hosting.layer?.animation(forKey: "wiggle") != nil }

    func set(isOn: Bool, clockwise: Bool) {
        guard isOn != self.isOn || clockwise != self.clockwise else { return }
        self.isOn = isOn
        self.clockwise = clockwise
        restart()
    }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        // Seulement si la taille change : un glisser déplace la vue sans la redimensionner.
        if bounds.size != animatedSize { restart() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restart()
    }

    private func restart() {
        guard let layer = hosting.layer else { return }
        layer.removeAnimation(forKey: "wiggle")
        animatedSize = bounds.size
        guard isOn, window != nil, bounds.width > 0 else { return }
        // Pivot au centre, quel que soit le point d'ancrage choisi par AppKit pour le calque de la vue.
        let size = layer.bounds.size
        let dx = size.width * (0.5 - layer.anchorPoint.x)
        let dy = size.height * (0.5 - layer.anchorPoint.y)
        func tilt(_ degrees: CGFloat) -> CATransform3D {
            let rotated = CATransform3DRotate(CATransform3DMakeTranslation(dx, dy, 0), degrees * .pi / 180, 0, 0, 1)
            return CATransform3DTranslate(rotated, -dx, -dy, 0)
        }
        let angle = clockwise ? Self.angle : -Self.angle
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = tilt(-angle)
        animation.toValue = tilt(angle)
        animation.duration = Self.period
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "wiggle")
    }
}

/// Menu « … » de l'en-tête. Sans l'onglet Claude, rien de Claude : ni sessions, ni état des hooks.
struct NotchMoreMenu: View {
    @ObservedObject var prefs: Preferences
    let claudeEnabled: Bool
    let actions: NotchActions

    var body: some View {
        Menu {
            Button("Réglages…", action: actions.openSettings)
                .keyboardShortcut(",", modifiers: .command)
            Button("Barre de commande…", action: actions.openCommandBar)
            Divider()
            if let reattach = actions.reattach {
                Button(L("Rattacher à la notch", table: "Bubble"), action: reattach)
                Divider()
            } else if prefs.allowsDetach, let detach = actions.detach {
                Button(L("Détacher la notch", table: "Bubble"), action: detach)
                Divider()
            }
            Picker("Afficher la notch", selection: Self.visibility(prefs, claudeEnabled: claudeEnabled)) {
                ForEach(NotchVisibility.choices(claudeEnabled: claudeEnabled)) { mode in
                    Text(NotchMoreMenu.title(mode)).tag(mode)
                }
            }
            Menu("Masquer la notch") {
                ForEach(HideDuration.allCases) { duration in
                    Button(NotchController.title(duration)) { prefs.hide(duration) }
                }
                Divider()
                Text(HiddenNotice.howToShowAgain(hotKey: prefs.hideHotKey))
            }
            Toggle("Lancer à l'ouverture de session", isOn: $prefs.launchAtLogin)
            Divider()
            if claudeEnabled {
                Button("Effacer les sessions terminées", action: actions.clearEnded)
                Divider()
            }
            HookMenuItems(setup: .shared, claudeEnabled: claudeEnabled)
            Divider()
            UpdateMenuItems(updater: .shared, prefs: prefs)
            Divider()
            Button("Quitter Oriel", action: actions.quit)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Sélecteur de visibilité : sans l'onglet Claude, « Quand Claude est ouvert » s'affiche comme « Toujours ».
    static func visibility(_ prefs: Preferences, claudeEnabled: Bool) -> Binding<NotchVisibility> {
        Binding(get: { prefs.visibility.effective(claudeEnabled: claudeEnabled) }, set: { prefs.visibility = $0 })
    }

    static func title(_ mode: NotchVisibility) -> String {
        switch mode {
        case .always: return L("Toujours")
        case .whenClaudeOpen: return L("Quand Claude est ouvert")
        case .duringActivity: return L("Pendant une activité")
        }
    }
}

struct StatusPill: View {
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            Circle()
                .fill(active ? Palette.green : Color.white.opacity(0.25))
                .frame(width: 6, height: 6)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundColor(active ? .white.opacity(0.85) : Palette.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 5) {
            Text("Aucune session en cours")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Palette.primary)
            Text("Lance `claude` dans un terminal ou ouvre l'onglet Code de Claude Desktop.")
                .font(.system(size: 11))
                .foregroundColor(Palette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

struct DesktopRow: View {
    let frontmost: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow")
                .font(.system(size: 12))
                .foregroundColor(Palette.secondary)
            Text(verbatim: "Claude Desktop")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.primary)
            Text(frontmost ? L("Au premier plan") : L("Ouvert"))
                .font(.system(size: 11))
                .foregroundColor(Palette.secondary)
            Spacer()
            // Déjà devant : rien à ouvrir, un bouton sans effet visible laisserait croire à une panne.
            if !frontmost {
                Text("Ouvrir")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.03)))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { if !frontmost { open() } }
    }
}

// MARK: - Carte de session

struct SessionCard: View {
    let session: Session
    let now: Date
    @Binding var showTasks: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PhaseIcon(phase: session.phase)
                    .frame(width: 16, height: 16)
                Text(session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .lineLimit(1)
                SourcePill(text: session.sourceLabel)
                if let title = session.title {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                if !session.activeAgents.isEmpty {
                    let count = session.activeAgents.count
                    Text(String(format: L(count, one: "%d agent", other: "%d agents"), count))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Palette.accent.opacity(0.15)))
                }
                Spacer(minLength: 8)
                Text(timeText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Palette.secondary)
            }
            activityLine
            if !session.tasks.isEmpty {
                taskRow
                if showTasks { checklist }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.amber.opacity(session.phase.needsAttention ? 0.9 : 0), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .help(session.title ?? session.cwd ?? "")
    }

    // MARK: Lignes

    private var activityLine: some View {
        let status = session.status
        return HStack(spacing: 6) {
            Text(status.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(status.color)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = status.detail {
                Text(detail)
                    .font(.system(size: 11, design: status.isCode ? .monospaced : .default))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var taskRow: some View {
        let done = session.completedTaskCount
        let total = session.tasks.count
        return HStack(spacing: 8) {
            ProgressBar(fraction: total > 0 ? CGFloat(done) / CGFloat(total) : 0)
                .frame(width: 72, height: 4)
            Text(verbatim: "\(done)/\(total)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(.white.opacity(0.8))
            if let current = session.currentTask {
                Text(current.activeForm ?? current.subject)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                withAnimation(notchSpring) { showTasks.toggle() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                    .rotationEffect(.degrees(showTasks ? 180 : 0))
                    .frame(width: 20, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(session.tasks) { task in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(task.status.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(task.status.color)
                        .frame(width: 12)
                    Text(task.subject)
                        .font(.system(size: 11))
                        .foregroundColor(task.status == .completed ? Palette.secondary : .white.opacity(0.85))
                        .strikethrough(task.status == .completed, color: Palette.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.leading, 2)
        .padding(.top, 2)
    }

    private var timeText: String {
        if session.inTurn, let start = session.turnStart {
            return Self.duration(now.timeIntervalSince(start))
        }
        return Self.relative(now.timeIntervalSince(session.endedAt ?? session.lastActivity))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return String(format: L("%d s"), total) }
        if total < 3600 { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func relative(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 10 { return L("à l'instant") }
        if total < 60 { return String(format: L("il y a %d s"), total) }
        if total < 3600 { return String(format: L("il y a %d min"), total / 60) }
        if total < 86_400 { return String(format: L("il y a %d h"), total / 3600) }
        return String(format: L("il y a %d j"), total / 86_400)
    }
}

struct SourcePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.7))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

struct ProgressBar: View {
    let fraction: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(Palette.green)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
    }
}

struct PhaseIcon: View {
    let phase: Phase

    var body: some View {
        switch phase {
        case .thinking, .tool, .compacting:
            GlyphSpinner(size: 12)
        case .waitingPermission:
            PulsingHand(size: 12)
        case .waitingAnswer:
            symbol("questionmark.bubble.fill", Palette.amber)
        case .planReview:
            symbol("checklist", Palette.amber)
        case .done:
            symbol("checkmark.circle.fill", Palette.green)
        case .error:
            symbol("exclamationmark.triangle.fill", Palette.red)
        case .ready:
            symbol("circle.fill", Color.white.opacity(0.35), size: 7)
        case .ended:
            symbol("xmark.circle", Palette.secondary)
        }
    }

    private func symbol(_ name: String, _ color: Color, size: CGFloat = 12) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(color)
    }
}

// MARK: - Présentation

struct SessionStatus {
    let label: String
    let detail: String?
    let isCode: Bool
    let color: Color
}

extension Session {
    var status: SessionStatus {
        switch phase {
        case .ready:
            return SessionStatus(label: L("Prête"), detail: lastMessage, isCode: false, color: Palette.secondary)
        case .thinking:
            return SessionStatus(label: L("Réfléchit…"), detail: lastPrompt.map { String(format: L("« %@ »"), $0) },
                                 isCode: false, color: Palette.accent)
        case .tool:
            let tool = currentTool
            return SessionStatus(label: tool?.label ?? L("Outil"), detail: tool?.detail, isCode: tool?.isCode ?? false,
                                 color: Palette.accent)
        case .waitingPermission:
            return SessionStatus(label: L("Attend ta permission"), detail: attentionText, isCode: true,
                                 color: Palette.amber)
        case .waitingAnswer:
            return SessionStatus(label: L("Attend ta réponse"), detail: attentionText, isCode: false,
                                 color: Palette.amber)
        case .planReview:
            return SessionStatus(label: L("Plan à valider"), detail: attentionText, isCode: false, color: Palette.amber)
        case .done:
            return SessionStatus(label: L("Terminé"), detail: lastMessage, isCode: false, color: Palette.green)
        case .error:
            return SessionStatus(label: L("Erreur"), detail: errorText, isCode: false, color: Palette.red)
        case .compacting:
            return SessionStatus(label: L("Compacte le contexte"), detail: nil, isCode: false,
                                 color: Palette.accent)
        case .ended:
            return SessionStatus(label: L("Session terminée"), detail: nil, isCode: false,
                                 color: Palette.secondary)
        }
    }
}

extension TaskItem.Status {
    var symbol: String {
        switch self {
        case .completed: return "✓"
        case .inProgress: return "◐"
        case .pending: return "○"
        }
    }

    var color: Color {
        switch self {
        case .completed: return Palette.green
        case .inProgress: return Palette.accent
        case .pending: return Palette.secondary
        }
    }
}
