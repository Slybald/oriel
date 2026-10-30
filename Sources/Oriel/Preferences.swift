import AppKit
import SwiftUI

/// Panneau déplié quand une app est en plein écran sur l'écran de la notch.
enum FullScreenBehavior: String, CaseIterable, Identifiable {
    /// Demi-largeur, informations primaires seulement.
    case compact
    case normal
    /// Notch retirée de l'écran tant que l'app est en plein écran.
    case hidden

    var id: String { rawValue }
}

/// Largeur du panneau déplié (mode normal) ; une largeur libre passe par `Preferences.customPanelWidth`.
enum PanelSize: String, CaseIterable, Identifiable {
    case compact
    case standard
    case large

    var id: String { rawValue }

    var width: CGFloat {
        switch self {
        case .compact: return 480
        case .standard: return 540
        case .large: return 620
        }
    }
}

/// Quand la notch est à l'écran.
enum NotchVisibility: String, CaseIterable, Identifiable {
    case always
    /// Claude Desktop ouvert, un `claude` vivant ou une session vivante (ou des oreilles de module).
    case whenClaudeOpen
    /// Une session au travail, qui attend ou qui vient de finir, ou des oreilles de module.
    case duringActivity

    var id: String { rawValue }

    /// Onglet Claude désactivé : « Quand Claude est ouvert » n'a plus de sens, il n'est plus proposé…
    static func choices(claudeEnabled: Bool) -> [NotchVisibility] {
        claudeEnabled ? allCases : allCases.filter { $0 != .whenClaudeOpen }
    }

    /// … et vaut « Toujours » (le réglage est gardé pour le jour où l'onglet revient).
    func effective(claudeEnabled: Bool) -> NotchVisibility {
        self == .whenClaudeOpen && !claudeEnabled ? .always : self
    }
}

/// Ce qui déplie le panneau.
enum OpenTrigger: String, CaseIterable, Identifiable {
    case hover
    case click

    var id: String { rawValue }
}

/// Fond du panneau déplié.
enum PanelBackground: String, CaseIterable, Identifiable {
    case black
    case graphite
    case midnight
    case custom

    var id: String { rawValue }

    /// Couleur fixe (hexadécimal sRGB) ; nil pour `custom`, lue dans les réglages.
    var hex: String? {
        switch self {
        case .black: return "000000"
        case .graphite: return "2A2B30"
        case .midnight: return "101B33"
        case .custom: return nil
        }
    }
}

/// Vitesse des ressorts d'ouverture, de fermeture et de changement d'onglet.
enum AnimationSpeed: String, CaseIterable, Identifiable {
    case fast
    case normal
    case gentle

    var id: String { rawValue }

    /// `normal` = le ressort historique de la notch (`notchSpring`).
    var spring: Animation {
        switch self {
        case .fast: return .spring(response: 0.3, dampingFraction: 0.82)
        case .normal: return notchSpring
        case .gentle: return .spring(response: 0.6, dampingFraction: 0.8)
        }
    }
}

/// Masquage temporaire de la notch.
enum HideDuration: String, CaseIterable, Identifiable {
    case oneHour
    /// Jusqu'au lendemain 8 h (minuit couperait court une soirée : masquée à 23 h 30, revenue à 0 h).
    case untilTomorrow
    case untilReactivated

    var id: String { rawValue }

    func end(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .untilTomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            return tomorrow.flatMap { calendar.date(bySettingHour: 8, minute: 0, second: 0, of: $0) }
                ?? now.addingTimeInterval(86_400)
        case .untilReactivated:
            return .distantFuture
        }
    }
}

/// Écran de la notch : un des choix ci-dessous, ou le nom d'un écran (`NSScreen.localizedName`).
enum ScreenChoice {
    /// Écran avec encoche, sinon l'écran intégré, sinon le premier.
    static let builtin = "builtin"
    /// Écran principal (celui de la barre des menus dans Réglages Système › Moniteurs).
    static let main = "main"
    static let mouse = "mouse"
}

/// Préférences de l'app, rangées dans UserDefaults et observables par les vues et le contrôleur.
/// Les valeurs lues sont bornées : un `defaults write` fantaisiste ne casse pas la notch.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// `defaultTab` : rouvrir le dernier onglet utilisé.
    static let lastTabChoice = "last"
    /// Couleurs d'accent proposées (hexadécimal sRGB) ; la première est celle de Claude, par défaut.
    static let accentPresets = ["D97757", "F5B83D", "4C8DFF", "2DD4BF", "A78BFA", "F472B6"]
    static let openDelayRange: ClosedRange<Double> = 0...0.5
    static let closeDelayRange: ClosedRange<Double> = 0.1...1.5
    static let opacityRange: ClosedRange<Double> = 0.6...1
    /// Largeur libre du panneau, par pas de 10 pt.
    static let customWidthRange: ClosedRange<Double> = 460...720
    static let customWidthStep: Double = 10
    static let defaultCustomBackground = "1C1C1E"

    private enum Key {
        /// Ancien booléen « Toujours visible », lu seulement pour la migration vers `visibility`.
        static let alwaysVisible = "alwaysVisible"
        static let visibility = "visibility.mode"
        /// Témoin de la réparation unique du défaut de visibilité enregistré par la 1.2.0.
        static let visibilityRepaired = "visibility.defaultFixed121"
        /// Fenêtre de bienvenue déjà montrée (ou inutile : hooks posés par une version précédente).
        static let welcomeShown = "onboarding.welcomeShown"
        static let hiddenUntil = "visibility.hiddenUntil"
        static let autoUpdate = "autoUpdate"
        static let openTrigger = "hover.trigger"
        static let closeOnClickOutside = "hover.closeOnClickOutside"
        static let openDelay = "hover.openDelay"
        static let closeDelay = "hover.closeDelay"
        static let haptics = "hover.haptics"
        static let toggleHotKey = "keyboard.togglePanel"
        static let hideHotKey = "keyboard.toggleHidden"
        static let commandHotKey = "keyboard.commandBar"
        static let fullScreen = "fullScreen.behavior"
        static let screen = "display.screen"
        static let tabOrder = "tabs.order"
        static let tabEnabled = "tabs.enabled"
        static let defaultTab = "tabs.default"
        static let lastTab = "tabs.last"
        static let accent = "appearance.accent"
        static let panelSize = "appearance.panelSize"
        static let customWidth = "appearance.customPanelWidth"
        static let background = "appearance.background"
        static let customBackground = "appearance.customBackground"
        static let tintCollapsed = "appearance.tintCollapsed"
        static let virtualNotch = "appearance.virtualNotch"
        static let opacity = "appearance.backgroundOpacity"
        static let shadow = "appearance.shadow"
        static let animationSpeed = "appearance.animationSpeed"
        static let showEars = "appearance.showEars"
        static let earTabs = "appearance.earTabs"
        /// Réglage de la 1.2.2 à la 1.7.0 (« Alterner Claude et les autres oreilles »), remplacé par `earTabs`.
        static let legacyAlternateEars = "appearance.alternateEars"
        static let hideFromCapture = "privacy.hideFromCapture"
        static let replyFromNotch = "claude.replyFromNotch"
        static let replyPromptDismissed = "claude.replyPromptDismissed"
        static let approveByKeyboard = "claude.approveByKeyboard"
        static let allowsDetach = "bubble.allowDetach"
        static let bubbleReturnsOnRelaunch = "bubble.returnOnRelaunch"
        /// État de la bulle (pas des réglages) : détachée, dernier écran, position par écran.
        static let bubbleDetached = "bubble.detached"
        static let bubbleScreen = "bubble.screen"
        static let bubblePositions = "bubble.positions"
        static let bubbleHandleHints = "bubble.handleHints"

        /// Réglages de la notch remis à zéro par « Rétablir les réglages par défaut » : ni les onglets, ni les
        /// réglages des modules, ni le lancement à l'ouverture de session, ni les mises à jour.
        static let notchSettings = [
            alwaysVisible, visibility, hiddenUntil, openTrigger, closeOnClickOutside, openDelay, closeDelay, haptics,
            toggleHotKey, hideHotKey, commandHotKey, fullScreen, screen, accent, panelSize, customWidth, background,
            customBackground, tintCollapsed, virtualNotch, opacity, shadow, animationSpeed, showEars, earTabs, hideFromCapture,
            allowsDetach, bubbleReturnsOnRelaunch,
        ]
    }

    private let defaults: UserDefaults

    // MARK: Général

    @Published var visibility: NotchVisibility {
        didSet { defaults.set(visibility.rawValue, forKey: Key.visibility) }
    }

    /// Notch masquée par l'utilisateur jusqu'à cette date (`distantFuture` : jusqu'à réactivation).
    @Published var hiddenUntil: Date? {
        didSet { defaults.set(hiddenUntil, forKey: Key.hiddenUntil) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            if launchAtLogin != LaunchAgent.isEnabled { LaunchAgent.setEnabled(launchAtLogin) }
        }
    }

    /// Activée par défaut ; désactivée, les nouvelles versions sont seulement signalées dans le menu.
    @Published var autoUpdate: Bool {
        didSet { defaults.set(autoUpdate, forKey: Key.autoUpdate) }
    }

    @Published var openTrigger: OpenTrigger {
        didSet { defaults.set(openTrigger.rawValue, forKey: Key.openTrigger) }
    }

    /// Le panneau reste ouvert quand la souris le quitte ; un clic ailleurs le ferme.
    @Published var closeOnClickOutside: Bool {
        didSet { defaults.set(closeOnClickOutside, forKey: Key.closeOnClickOutside) }
    }

    /// Secondes de survol avant l'ouverture du panneau.
    @Published var openDelay: Double {
        didSet { defaults.set(openDelay, forKey: Key.openDelay) }
    }

    /// Secondes hors de la zone avant la fermeture.
    @Published var closeDelay: Double {
        didSet { defaults.set(closeDelay, forKey: Key.closeDelay) }
    }

    @Published var hapticFeedback: Bool {
        didSet { defaults.set(hapticFeedback, forKey: Key.haptics) }
    }

    /// Raccourci global : ouvrir ou fermer le panneau.
    @Published var toggleHotKey: HotKeyChoice {
        didSet {
            defaults.set(toggleHotKey.rawValue, forKey: Key.toggleHotKey)
            // Une combinaison ne sert qu'à une chose.
            if toggleHotKey != .none, hideHotKey == toggleHotKey { hideHotKey = .none }
            if toggleHotKey != .none, commandHotKey == toggleHotKey { commandHotKey = .none }
        }
    }

    /// Raccourci global : masquer ou réafficher la notch.
    @Published var hideHotKey: HotKeyChoice {
        didSet {
            defaults.set(hideHotKey.rawValue, forKey: Key.hideHotKey)
            if hideHotKey != .none, toggleHotKey == hideHotKey { toggleHotKey = .none }
            if hideHotKey != .none, commandHotKey == hideHotKey { commandHotKey = .none }
        }
    }

    /// Raccourci global : ouvrir la barre de commande (aucun par défaut).
    @Published var commandHotKey: HotKeyChoice {
        didSet {
            defaults.set(commandHotKey.rawValue, forKey: Key.commandHotKey)
            if commandHotKey != .none, toggleHotKey == commandHotKey { toggleHotKey = .none }
            if commandHotKey != .none, hideHotKey == commandHotKey { hideHotKey = .none }
        }
    }

    @Published var fullScreenBehavior: FullScreenBehavior {
        didSet { defaults.set(fullScreenBehavior.rawValue, forKey: Key.fullScreen) }
    }

    /// `ScreenChoice` ou le nom d'un écran.
    @Published var screenChoice: String {
        didSet { defaults.set(screenChoice, forKey: Key.screen) }
    }

    /// Fenêtre de la notch exclue des captures et du partage d'écran (`NSWindow.sharingType = .none`).
    @Published var hideFromCapture: Bool {
        didSet { defaults.set(hideFromCapture, forKey: Key.hideFromCapture) }
    }

    /// Poignée de l'angle du panneau et « Détacher la notch » : la notch devient une bulle à poser n'importe où.
    @Published var allowsDetach: Bool {
        didSet { defaults.set(allowsDetach, forKey: Key.allowsDetach) }
    }

    /// Au lancement, la bulle revient dans la notch au lieu de reprendre sa place.
    @Published var bubbleReturnsOnRelaunch: Bool {
        didSet { defaults.set(bubbleReturnsOnRelaunch, forKey: Key.bubbleReturnsOnRelaunch) }
    }

    @Published var bubbleDetached: Bool {
        didSet { defaults.set(bubbleDetached, forKey: Key.bubbleDetached) }
    }

    /// Dernier écran de la bulle (nom de `NotchScreenPicker.labels`).
    @Published var bubbleScreen: String? {
        didSet { defaults.set(bubbleScreen, forKey: Key.bubbleScreen) }
    }

    /// Fois où l'angle du panneau a montré comment détacher la notch (pas publié : rien à redessiner).
    var bubbleHandleHints: Int {
        didSet { defaults.set(bubbleHandleHints, forKey: Key.bubbleHandleHints) }
    }

    /// L'angle montre comment détacher la notch aux premières ouvertures du panneau, puis plus jamais.
    static let handleHintCount = 3

    /// Vrai (et compté) tant que l'indice de l'angle reste à montrer.
    func takeHandleHint() -> Bool {
        guard bubbleHandleHints < Self.handleHintCount else { return false }
        bubbleHandleHints += 1
        return true
    }

    /// Position de la bulle par écran : décalage [x, y] depuis l'origine de l'écran.
    @Published var bubblePositions: [String: [Double]] {
        didSet { defaults.set(bubblePositions, forKey: Key.bubblePositions) }
    }

    // MARK: Onglets

    /// Identifiants des modules dans l'ordre choisi ; les modules absents suivent dans l'ordre par défaut.
    @Published var tabOrder: [String] {
        didSet { defaults.set(tabOrder, forKey: Key.tabOrder) }
    }

    /// Choix explicites de l'utilisateur ; un module absent garde son activation par défaut.
    @Published var tabEnabled: [String: Bool] {
        didSet { defaults.set(tabEnabled, forKey: Key.tabEnabled) }
    }

    /// `lastTabChoice` ou l'identifiant d'un module.
    @Published var defaultTab: String {
        didSet { defaults.set(defaultTab, forKey: Key.defaultTab) }
    }

    @Published var lastTab: String {
        didSet { defaults.set(lastTab, forKey: Key.lastTab) }
    }

    // MARK: Apparence

    /// Couleur d'accent en hexadécimal sRGB (« D97757 »).
    @Published var accentHex: String {
        didSet {
            accent = Color(hex: accentHex) ?? Palette.claudeOrange
            defaults.set(accentHex, forKey: Key.accent)
        }
    }

    /// Couleur d'accent prête à l'emploi (calculée une fois par changement).
    private(set) var accent: Color

    @Published var panelSize: PanelSize {
        didSet { defaults.set(panelSize.rawValue, forKey: Key.panelSize) }
    }

    /// Largeur libre (pt) ; nil = la taille prédéfinie `panelSize`. Toujours bornée et arrondie au pas.
    @Published var customPanelWidth: Double? {
        didSet {
            // Réaffecter dans son propre didSet ne relance pas l'observateur.
            if let width = customPanelWidth, width != Self.clampWidth(width) { customPanelWidth = Self.clampWidth(width) }
            defaults.set(customPanelWidth, forKey: Key.customWidth)
        }
    }

    @Published var panelBackground: PanelBackground {
        didSet { defaults.set(panelBackground.rawValue, forKey: Key.background) }
    }

    /// Fond libre (hexadécimal sRGB), utilisé avec `panelBackground == .custom`.
    @Published var customBackgroundHex: String {
        didSet { defaults.set(customBackgroundHex, forKey: Key.customBackground) }
    }

    /// Notch repliée teintée elle aussi (écrans sans encoche seulement : sur une vraie encoche elle reste noire).
    @Published var tintCollapsed: Bool {
        didSet { defaults.set(tintCollapsed, forKey: Key.tintCollapsed) }
    }

    /// Notch repliée d'un écran sans encoche : encoche, pilule ou caméléon (voir `VirtualNotchStyle`).
    @Published var virtualNotchStyle: VirtualNotchStyle {
        didSet { defaults.set(virtualNotchStyle.rawValue, forKey: Key.virtualNotch) }
    }

    /// Opacité du fond du panneau déplié ; la bande de la notch reste toujours opaque.
    @Published var backgroundOpacity: Double {
        didSet { defaults.set(backgroundOpacity, forKey: Key.opacity) }
    }

    @Published var panelShadow: Bool {
        didSet { defaults.set(panelShadow, forKey: Key.shadow) }
    }

    @Published var animationSpeed: AnimationSpeed {
        didSet { defaults.set(animationSpeed.rawValue, forKey: Key.animationSpeed) }
    }

    @Published var showEars: Bool {
        didSet { defaults.set(showEars, forKey: Key.showEars) }
    }

    /// Intercalaires de la notch repliée : languettes qui se déploient au survol, ou toujours visibles.
    @Published var earTabsMode: EarTabsMode {
        didSet { defaults.set(earTabsMode.rawValue, forKey: Key.earTabs) }
    }

    // MARK: Claude

    /// Répondre depuis la notch (permissions, questions, plans, messages).
    @Published var replyFromNotch: Bool {
        didSet { defaults.set(replyFromNotch, forKey: Key.replyFromNotch) }
    }

    /// Approuver au clavier (⌃⌥Y, ⌃⌥N) les demandes de Claude et de Codex ; éteint par défaut.
    @Published var approveByKeyboard: Bool {
        didSet { defaults.set(approveByKeyboard, forKey: Key.approveByKeyboard) }
    }

    /// « Plus tard » sur la carte qui propose d'activer les réponses : elle ne revient pas (le réglage reste dans
    /// Réglages › Claude).
    @Published var replyPromptDismissed: Bool {
        didSet { defaults.set(replyPromptDismissed, forKey: Key.replyPromptDismissed) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func double(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            let value = defaults.object(forKey: key) as? Double ?? fallback
            return value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        func choice<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init) ?? fallback
        }
        let legacyAlwaysVisible = defaults.object(forKey: Key.alwaysVisible) as? Bool
        var initialVisibility = defaults.string(forKey: Key.visibility).flatMap(NotchVisibility.init)
            ?? Self.migratedVisibility(alwaysVisible: legacyAlwaysVisible)
        // Réparation unique : la 1.2.0 a enregistré « quand Claude est ouvert » d'elle-même chez qui avait déjà les
        // hooks. Sans l'ancienne clé, ce n'était donc pas un choix : retour à « toujours ». Compromis assumé : qui
        // l'aurait choisi exprès pendant la courte vie de la 1.2.0 est remis à « toujours » une fois.
        if defaults.object(forKey: Key.visibilityRepaired) == nil {
            if initialVisibility == .whenClaudeOpen, legacyAlwaysVisible == nil {
                initialVisibility = .always
                defaults.set(initialVisibility.rawValue, forKey: Key.visibility)
            }
            defaults.set(true, forKey: Key.visibilityRepaired)
        }
        visibility = initialVisibility
        hiddenUntil = defaults.object(forKey: Key.hiddenUntil) as? Date
        autoUpdate = defaults.object(forKey: Key.autoUpdate) as? Bool ?? true
        launchAtLogin = LaunchAgent.isEnabled
        openTrigger = choice(Key.openTrigger, OpenTrigger.hover)
        closeOnClickOutside = defaults.object(forKey: Key.closeOnClickOutside) as? Bool ?? false
        openDelay = double(Key.openDelay, 0.08, Self.openDelayRange)
        closeDelay = double(Key.closeDelay, 0.25, Self.closeDelayRange)
        hapticFeedback = defaults.object(forKey: Key.haptics) as? Bool ?? true
        let toggle = choice(Key.toggleHotKey, HotKeyChoice.none)
        toggleHotKey = toggle
        let hide = choice(Key.hideHotKey, HotKeyChoice.none)
        hideHotKey = hide == toggle ? .none : hide
        let command = choice(Key.commandHotKey, HotKeyChoice.none)
        commandHotKey = command == toggle || command == hide ? .none : command
        fullScreenBehavior = choice(Key.fullScreen, FullScreenBehavior.compact)
        screenChoice = defaults.string(forKey: Key.screen).flatMap { $0.isEmpty ? nil : $0 } ?? ScreenChoice.builtin
        hideFromCapture = defaults.object(forKey: Key.hideFromCapture) as? Bool ?? false
        allowsDetach = defaults.object(forKey: Key.allowsDetach) as? Bool ?? true
        bubbleReturnsOnRelaunch = defaults.bool(forKey: Key.bubbleReturnsOnRelaunch)
        bubbleDetached = defaults.bool(forKey: Key.bubbleDetached)
        bubbleScreen = defaults.string(forKey: Key.bubbleScreen)
        bubblePositions = defaults.dictionary(forKey: Key.bubblePositions) as? [String: [Double]] ?? [:]
        bubbleHandleHints = defaults.integer(forKey: Key.bubbleHandleHints)
        tabOrder = defaults.stringArray(forKey: Key.tabOrder) ?? []
        tabEnabled = defaults.dictionary(forKey: Key.tabEnabled) as? [String: Bool] ?? [:]
        defaultTab = defaults.string(forKey: Key.defaultTab) ?? Self.lastTabChoice
        lastTab = defaults.string(forKey: Key.lastTab) ?? ModuleRegistry.claudeId
        let hex = defaults.string(forKey: Key.accent).flatMap { Color(hex: $0) != nil ? $0 : nil }
            ?? Self.accentPresets[0]
        accentHex = hex
        accent = Color(hex: hex) ?? Palette.claudeOrange
        panelSize = choice(Key.panelSize, PanelSize.standard)
        customPanelWidth = (defaults.object(forKey: Key.customWidth) as? Double)
            .flatMap { $0.isFinite ? Self.clampWidth($0) : nil }
        panelBackground = choice(Key.background, PanelBackground.black)
        customBackgroundHex = defaults.string(forKey: Key.customBackground)
            .flatMap { Color(hex: $0) != nil ? $0 : nil } ?? Self.defaultCustomBackground
        tintCollapsed = defaults.bool(forKey: Key.tintCollapsed)
        virtualNotchStyle = choice(Key.virtualNotch, VirtualNotchStyle.notch)
        backgroundOpacity = double(Key.opacity, 1, Self.opacityRange)
        panelShadow = defaults.object(forKey: Key.shadow) as? Bool ?? true
        animationSpeed = choice(Key.animationSpeed, AnimationSpeed.normal)
        showEars = defaults.object(forKey: Key.showEars) as? Bool ?? true
        let legacyAlternate = defaults.object(forKey: Key.legacyAlternateEars) as? Bool
        let tabsMode = choice(Key.earTabs, Self.migratedEarTabs(alternateEars: legacyAlternate))
        earTabsMode = tabsMode
        // Migré une fois : l'ancienne clé ne sert plus.
        if legacyAlternate != nil {
            defaults.set(tabsMode.rawValue, forKey: Key.earTabs)
            defaults.removeObject(forKey: Key.legacyAlternateEars)
        }
        replyFromNotch = defaults.bool(forKey: Key.replyFromNotch)
        replyPromptDismissed = defaults.bool(forKey: Key.replyPromptDismissed)
        approveByKeyboard = defaults.bool(forKey: Key.approveByKeyboard)
    }

    /// Ancien « Alterner Claude et les autres oreilles » : activé (ou jamais réglé) → intercalaires toujours visibles,
    /// comme les oreilles qui montraient tout ; désactivé (qui voulait Claude seul, une notch discrète) → rétractés.
    static func migratedEarTabs(alternateEars: Bool?) -> EarTabsMode {
        alternateEars == false ? .retracted : .visible
    }

    /// Ancien « Toujours visible » : vrai → toujours, faux → quand Claude est ouvert, jamais réglé → toujours (les
    /// onglets servent sans Claude).
    static func migratedVisibility(alwaysVisible: Bool?) -> NotchVisibility {
        alwaysVisible == false ? .whenClaudeOpen : .always
    }

    /// Bienvenue déjà montrée, ou rendue inutile par des hooks posés par une version précédente.
    var welcomeShown: Bool {
        get { defaults.bool(forKey: Key.welcomeShown) }
        set { defaults.set(newValue, forKey: Key.welcomeShown) }
    }

    /// Onglet Claude, décidé une fois puis enregistré : activé seulement si Claude Code est présent sur ce Mac
    /// (lu seulement s'il le faut). Ensuite, seul l'utilisateur le change (Réglages › Onglets).
    func decideClaudeTab(claudeCodePresent: () -> Bool) {
        guard tabEnabled[ModuleRegistry.claudeId] == nil else { return }
        tabEnabled[ModuleRegistry.claudeId] = claudeCodePresent()
    }

    /// Largeur du panneau déplié : demi-largeur en plein écran compact, sinon la largeur choisie.
    func expandedWidth(compact: Bool) -> CGFloat {
        if compact { return Self.compactPanelWidth }
        return customPanelWidth.map { CGFloat($0) } ?? panelSize.width
    }

    static let compactPanelWidth: CGFloat = 270

    static func clampWidth(_ width: Double) -> Double {
        let stepped = (width / customWidthStep).rounded() * customWidthStep
        return min(max(stepped, customWidthRange.lowerBound), customWidthRange.upperBound)
    }

    /// Fond du panneau déplié, opaque (l'opacité est appliquée par la vue). Un fond libre trop clair est assombri.
    var panelColor: Color {
        if let hex = panelBackground.hex { return Color(hex: hex) ?? .black }
        return Self.readable(Color(hex: customBackgroundHex) ?? .black)
    }

    /// Luminance relative maximale d'un fond libre (les fonds proposés sont sous 0,03) : le texte blanc garde un
    /// contraste ≥ 9:1, le texte atténué et l'accent restent lisibles (à 0,18, le seuil WCAG du blanc, ils ne
    /// l'étaient plus).
    static let maxBackgroundLuminance = 0.06

    /// Même teinte, assombrie jusqu'à `maxBackgroundLuminance` si besoin (le panneau est toujours en thème sombre).
    static func readable(_ color: Color) -> Color {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return color }
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func encoded(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        let rgb = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent].map(linear)
        let luminance = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
        guard luminance > maxBackgroundLuminance else { return color }
        // En lumière linéaire, multiplier les trois composantes garde la teinte et divise la luminance d'autant.
        let dark = rgb.map { encoded($0 * maxBackgroundLuminance / luminance) }
        return Color(.sRGB, red: dark[0], green: dark[1], blue: dark[2])
    }

    // MARK: Masquage temporaire

    func hide(_ duration: HideDuration, now: Date = Date(), calendar: Calendar = .current) {
        hiddenUntil = duration.end(from: now, calendar: calendar)
    }

    func showAgain() {
        if hiddenUntil != nil { hiddenUntil = nil }
    }

    func isHidden(at now: Date) -> Bool {
        hiddenUntil.map { $0 > now } ?? false
    }

    // MARK: Réinitialisation

    /// Remet les réglages de la notch à leurs valeurs d'origine (voir `Key.notchSettings`) : mêmes valeurs qu'au
    /// premier lancement, lues par un `Preferences` neuf sur les clés effacées.
    func resetNotchSettings() {
        for key in Key.notchSettings { defaults.removeObject(forKey: key) }
        let fresh = Preferences(defaults: defaults)
        visibility = fresh.visibility
        hiddenUntil = fresh.hiddenUntil
        openTrigger = fresh.openTrigger
        closeOnClickOutside = fresh.closeOnClickOutside
        openDelay = fresh.openDelay
        closeDelay = fresh.closeDelay
        hapticFeedback = fresh.hapticFeedback
        toggleHotKey = fresh.toggleHotKey
        hideHotKey = fresh.hideHotKey
        commandHotKey = fresh.commandHotKey
        fullScreenBehavior = fresh.fullScreenBehavior
        screenChoice = fresh.screenChoice
        hideFromCapture = fresh.hideFromCapture
        allowsDetach = fresh.allowsDetach
        bubbleReturnsOnRelaunch = fresh.bubbleReturnsOnRelaunch
        accentHex = fresh.accentHex
        panelSize = fresh.panelSize
        customPanelWidth = fresh.customPanelWidth
        panelBackground = fresh.panelBackground
        customBackgroundHex = fresh.customBackgroundHex
        tintCollapsed = fresh.tintCollapsed
        virtualNotchStyle = fresh.virtualNotchStyle
        backgroundOpacity = fresh.backgroundOpacity
        panelShadow = fresh.panelShadow
        animationSpeed = fresh.animationSpeed
        showEars = fresh.showEars
        earTabsMode = fresh.earTabsMode
    }
}

extension Color {
    /// « D97757 » ou « #D97757 » (sRGB) ; nil si le texte n'est pas une couleur.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// Hexadécimal sRGB (« D97757 »), pour ranger une couleur libre dans les réglages.
    var hexString: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(color.redComponent), byte(color.greenComponent),
                      byte(color.blueComponent))
    }
}
