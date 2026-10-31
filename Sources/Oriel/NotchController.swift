import AppKit
import Combine
import SwiftUI

/// État partagé entre le contrôleur (AppKit) et la vue (SwiftUI).
final class NotchViewModel: ObservableObject {
    @Published var isExpanded = false {
        // Le panneau qui se replie sort du mode édition des onglets.
        didSet {
            if !isExpanded, isEditingTabs { isEditingTabs = false }
            if !isExpanded, isCommandBarOpen { isCommandBarOpen = false }
        }
    }
    /// Barre de commande ouverte : elle remplace le contenu du panneau (`CommandBarView`).
    @Published var isCommandBarOpen = false
    /// Mode édition des onglets (appui long sur la barre) : glisser, masquer, remettre. Tant qu'il dure, le survol
    /// ne change plus d'onglet et le panneau ne se replie pas.
    @Published var isEditingTabs = false
    @Published var notchSize = CGSize(width: 200, height: 32)
    @Published var hasNotch = false
    /// Écart entre le haut de l'écran et la notch : 0, sauf la pilule qui flotte (`NotchScreenPicker.pillGap`).
    @Published var notchGap: CGFloat = 0
    /// Onglet affiché (identifiant de module).
    @Published var selectedTab = ModuleRegistry.claudeId
    /// Une app est en plein écran sur l'écran de la notch.
    @Published var isFullScreen = false
    /// « Réduire les animations » (Accessibilité) : fondu simple au lieu des ressorts.
    @Published var reduceMotion = false
    /// Taille réelle de la forme noire, mesurée par la vue. Sert aux zones de survol.
    var contentSize: CGSize = .zero
    /// La fenêtre est à l'écran (le contrôleur la masque : « Masquer la notch », plein écran « masquée »).
    @Published var isShown = true

    /// Intercalaire déployé par le survol (identifiant de l'activité). Le contrôleur le décide, la vue le dessine.
    @Published var hoveredTab: String?
    /// Hauteur mesurée de l'intercalaire déployé : avec sa largeur, la zone de survol qui le garde ouvert.
    var tabCardHeight: CGFloat = 0
    /// Notch détachée en bulle (voir `BubbleController`).
    @Published var bubble = BubblePhase.attached
    /// La goutte remplace la notch dépliée pendant le décollage : la notch est cachée dessous.
    @Published var gooActive = false
}

struct NotchActions {
    var activate: (Session) -> Void = { _ in }
    var openDesktop: () -> Void = {}
    var clearEnded: () -> Void = {}
    var quit: () -> Void = {}
    /// Révèle un fichier (ou un dépôt) dans le Finder.
    var revealFile: (String) -> Void = { _ in }
    var openSettings: () -> Void = {}
    /// Ouvre le panneau sur l'onglet de cette activité (clic sur un intercalaire).
    var openTab: (String) -> Void = { _ in }
    /// Barre de commande : ouvrir (menu « … »), refermer avec le panneau (Échap, action lancée).
    var openCommandBar: () -> Void = {}
    var closeCommandBar: () -> Void = {}
    /// Appui maintenu sur la poignée de l'angle : le glisser qui suit décolle la notch.
    var beginDetach: () -> Void = {}
    /// « Détacher la notch » (menu « … », VoiceOver) ; nil = pas d'entrée.
    var detach: (() -> Void)?
    /// « Rattacher à la notch » (panneau de la bulle) ; nil = pas d'entrée.
    var reattach: (() -> Void)?
    /// Panneau de la bulle : bouton retour au barillet ; nil = pas de bouton (notch attachée).
    var backToRevolver: (() -> Void)?
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Pas de recadrage sous la barre de menus : le panneau doit coller au bord haut.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Les clics passent sans activer l'app (premier clic accepté).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Fenêtre de la notch : position, survol, ouverture/fermeture, visibilité.
final class NotchController {
    static let earWidth: CGFloat = 36
    /// Assez large pour la largeur libre maximale (720 pt), ses rayons et son ombre.
    static let panelSize = CGSize(width: 800, height: 480)
    private static let hideDelay: TimeInterval = 3
    /// Après un changement de Space, le temps que l'animation se termine.
    private static let spaceSettleDelay: TimeInterval = 0.4
    /// Au-dessus de la barre des menus (24) et de ses icônes (25).
    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    let model = NotchViewModel()
    let registry: ModuleRegistry
    let panel: NotchPanel
    /// Notch détachée en bulle.
    let bubble: BubbleController

    private let store: SessionStore
    private let monitor: ClaudeMonitor
    private let prefs: Preferences
    private let claude: ClaudeModule
    let codex: CodexModule
    private let settings: SettingsWindow

    private var screenFrame = CGRect.zero
    /// Écran de la notch, pour la détection du plein écran.
    private var displayID: CGDirectDisplayID?
    private var notchRect = CGRect.zero
    private var eventMonitors: [Any] = []
    private var pollTimer: Timer?
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    /// Déploiement ou repli d'un intercalaire en attente du délai d'intention, avec l'intercalaire visé.
    private var pendingTab: (target: String?, work: DispatchWorkItem)?
    private var suppressUntilExit = false
    private var menuTracking = false
    private var isShown = false { didSet { model.isShown = isShown } }
    private var cancellables = Set<AnyCancellable>()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Compteur du presse-papiers de glisser relevé au dernier clic dans une autre app (Étagère).
    private var fileDragBaseline: Int?
    /// Notch montrée seulement à la demande (dépôt sur l'Étagère, raccourci) : recachée au repli.
    private var shownOnDemand = false
    /// Panneau ouvert par le raccourci : il a le clavier et ne se ferme pas quand la souris est ailleurs.
    private var openedByKeyboard = false
    /// Fin du masquage temporaire (une seule échéance, jamais de scrutation).
    private var unhideTimer: Timer?
    /// Horloge du masquage temporaire.
    var now: () -> Date = Date.init
    /// Position de la souris relue après un délai d'intention ; remplaçable dans les tests.
    var mouseLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// Onglet d'avant qu'un glisser de fichiers montre l'Étagère ; nil dès qu'un dépôt a lieu.
    private var tabBeforeDrag: String?
    /// Glisser de décollage en cours (poignée de l'angle) : suit la souris jusqu'au relâchement.
    private var detachMonitor: Any?

    init(store: SessionStore, monitor: ClaudeMonitor, prefs: Preferences, tools: ToolsFeed) {
        self.store = store
        self.monitor = monitor
        self.prefs = prefs
        claude = ClaudeModule(store: store, monitor: monitor, tools: tools, prefs: prefs)
        codex = CodexModule()
        registry = ModuleRegistry(modules: ModuleRegistry.standardModules(claude: claude, codex: codex), prefs: prefs)
        settings = SettingsWindow(prefs: prefs, registry: registry)
        bubble = BubbleController(model: model, prefs: prefs, registry: registry, store: store)

        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Avant `level` : ce setter remet le niveau à `.floating` (3, mesuré), sous la barre des menus.
        panel.isFloatingPanel = true
        panel.level = Self.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        // Appliqué tout de suite et à chaque changement (le publieur donne la nouvelle valeur).
        prefs.$hideFromCapture
            .sink { [weak panel] hidden in panel?.sharingType = Self.sharingType(hiddenFromCapture: hidden) }
            .store(in: &cancellables)
        model.$isEditingTabs
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] editing in self?.editingTabsChanged(editing) }
            .store(in: &cancellables)
    }

    /// `.none` : absente des captures d'écran, enregistrements et partages (selon l'app qui capture).
    static func sharingType(hiddenFromCapture: Bool) -> NSWindow.SharingType {
        hiddenFromCapture ? .none : .readOnly
    }

    func start() {
        let actions = NotchActions(
            activate: { [weak self] session in self?.activate(session) },
            openDesktop: { [weak self] in self?.openDesktop() },
            clearEnded: { [weak self] in self?.store.clearEnded() },
            quit: { NSApp.terminate(nil) },
            revealFile: { [weak self] path in self?.reveal(path) },
            openSettings: { [weak self] in self?.openSettings() },
            openTab: { [weak self] id in self?.openTab(id) },
            openCommandBar: { [weak self] in self?.openCommandBar() },
            closeCommandBar: { [weak self] in self?.closeCommandBar() },
            beginDetach: { [weak self] in self?.beginDetach() },
            detach: { [weak self] in self?.detachFromMenu() }
        )
        claude.actions = actions
        codex.openHost = { [weak self] bundleId, link in
            if let link { Self.open(link, inAppWithBundleId: bundleId) } else if let bundleId { Self.bringToFront(bundleId: bundleId) }
            self?.suppressUntilExit = true
            self?.collapse()
        }
        codex.openSettings = { [weak self] in self?.openSettings() }
        ApprovalQueue.shared.attach([.claude(claude), .codex(codex)]) { [weak self] tab in
            self?.revealApproval(tab: tab)
        }
        let root = NotchRootView(model: model, store: store, registry: registry, prefs: prefs, actions: actions)
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]
        // Étagère : une vue AppKit sous le contenu SwiftUI reçoit les fichiers glissés sur le panneau déplié.
        let drop = ShelfDropView(frame: hosting.frame)
        drop.autoresizingMask = [.width, .height]
        drop.addSubview(hosting)
        drop.shelf = shelf
        drop.accepts = { [weak self] point in
            guard let self else { return false }
            return self.model.isExpanded && self.registry.isEnabled(ShelfModule.moduleId) && self.isInsideZone(point)
        }
        drop.showShelf = { [weak self] in
            guard let self, self.model.selectedTab != ShelfModule.moduleId else { return }
            self.tabBeforeDrag = self.model.selectedTab
            self.model.selectedTab = ShelfModule.moduleId
        }
        drop.dropped = { [weak self] in self?.tabBeforeDrag = nil }
        panel.contentView = drop

        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.isShown = isShown
        updateGeometry()
        startBubble(actions: actions)
        installMouseMonitors()
        observeChanges()
        observeShellSettings()
        updateFullScreen()
        updateVisibility()
        bubble.restore()
    }

    /// Réglages… (menu « … », ⌘,).
    func openSettings() {
        suppressUntilExit = true
        collapse()
        bubble.close()
        settings.show()
    }

    var debugInfo: [String: Any] {
        var info: [String: Any] = [
            "shown": isShown,
            "expanded": model.isExpanded,
            "hasNotch": model.hasNotch,
            "notchRect": [notchRect.minX, notchRect.minY, notchRect.width, notchRect.height],
            "panelFrame": [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height],
            "contentSize": [model.contentSize.width, model.contentSize.height],
            "ignoresMouse": panel.ignoresMouseEvents,
            "polling": pollTimer != nil,
            "level": panel.level.rawValue,
            "isOnActiveSpace": panel.isOnActiveSpace,
            "isVisible": panel.isVisible,
            "occlusionVisible": panel.occlusionState.contains(.visible),
            "fullScreen": model.isFullScreen,
            "fullScreenBehavior": prefs.fullScreenBehavior.rawValue,
            "selectedTab": model.selectedTab,
            "modules": registry.debugInfo,
            // Intercalaires de la notch repliée (identifiants seulement), de la notch vers l'extérieur.
            "earTabs": earTabsDebugInfo,
            "visibility": prefs.visibility.rawValue,
            "openTrigger": prefs.openTrigger.rawValue,
            "closeOnClickOutside": prefs.closeOnClickOutside,
            "openedByKeyboard": openedByKeyboard,
            "editingTabs": model.isEditingTabs,
            "hotKeys": [prefs.toggleHotKey.rawValue, prefs.hideHotKey.rawValue, prefs.commandHotKey.rawValue],
            "hotKeysUnavailable": HotKeyCenter.shared.unavailable.map { $0.rawValue }.sorted(),
            "approvalKeys": ApprovalQueue.shared.debugInfo,
            "panelWidth": prefs.expandedWidth(compact: false),
            "background": prefs.panelBackground.rawValue,
            "reduceMotion": model.reduceMotion,
            "sharingType": panel.sharingType == .none ? "none" : "readOnly",
            "bubble": bubble.debugInfo,
        ]
        // Choix de l'écran sans son nom (le nom de l'écran utilisé est déjà sous `screen`).
        let choices = [ScreenChoice.builtin, ScreenChoice.main, ScreenChoice.mouse]
        info["screenChoice"] = choices.contains(prefs.screenChoice) ? prefs.screenChoice : "named"
        if let until = prefs.hiddenUntil {
            info["hiddenUntil"] = until == .distantFuture ? "untilReactivated" : ISO8601DateFormatter().string(from: until)
        }
        // Niveau vu par le serveur de fenêtres : celui qui compte face à la barre des menus et au plein écran.
        info["windowServerLevel"] = Self.windowServerLevel(of: panel)
        if let screen = panel.screen {
            info["screen"] = [
                "name": screen.localizedName,
                "frame": [screen.frame.minX, screen.frame.minY, screen.frame.width, screen.frame.height],
            ]
        }
        info["frontmostApp"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return info
    }

    private var earTabsDebugInfo: [String: Any] {
        let layout = earLayout()
        var info: [String: Any] = [
            "left": layout.left.map { $0.id },
            "right": layout.right.map { $0.id },
            "mode": prefs.earTabsMode.rawValue,
        ]
        if let hovered = model.hoveredTab { info["hovered"] = hovered }
        return info
    }

    /// Couche (`kCGWindowLayer`) de la fenêtre selon CGWindowList ; nil si elle n'est pas à l'écran.
    static func windowServerLevel(of window: NSWindow) -> Int? {
        guard window.windowNumber > 0,
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber))
                as? [[String: Any]] else { return nil }
        return (list.first?[kCGWindowLayer as String] as? NSNumber)?.intValue
    }

    // MARK: - Géométrie

    /// Écran choisi dans les réglages (intégré, principal, sous la souris, ou par nom), relu à chaque appel.
    private func updateGeometry() {
        let screens = NSScreen.screens
        let candidates = screens.map(ScreenCandidate.init)
        guard let index = NotchScreenPicker.pick(prefs.screenChoice, among: candidates,
                                                 mouse: NSEvent.mouseLocation) else { return }
        let screen = screens[index]
        let frame = screen.frame
        screenFrame = frame

        let previousDisplay = displayID
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        // Écran sans encoche (externe, capot fermé) : encoche virtuelle centrée, hauteur de la barre des menus.
        let notch = NotchScreenPicker.notchRect(on: candidates[index], menuBarThickness: NSStatusBar.system.thickness,
                                                style: prefs.virtualNotchStyle)
        notchRect = notch.rect
        if model.hasNotch != notch.hasNotch { model.hasNotch = notch.hasNotch }
        if model.notchSize != notchRect.size { model.notchSize = notchRect.size }
        let gap = frame.maxY - notchRect.maxY
        if model.notchGap != gap { model.notchGap = gap }
        if previousDisplay != nil, previousDisplay != displayID { updateFullScreen() }

        let size = Self.panelSize
        let origin = CGPoint(x: (notchRect.midX - size.width / 2).rounded(), y: frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: - Survol

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        // Clic dans une autre app : arme la détection d'un glisser de fichiers vers l'Étagère (`openForFileDrag`),
        // ouvre le panneau en mode « au clic », ferme un panneau qui attend un clic à l'extérieur.
        // Clic droit sur la notch repliée : menu contextuel.
        let globalMask = mask.union([.leftMouseDown, .rightMouseDown])
        if let global = NSEvent.addGlobalMonitorForEvents(matching: globalMask, handler: { [weak self] event in
            guard let self else { return }
            switch event.type {
            case .leftMouseDown:
                self.mouseDown()
                self.armFileDrag()
            case .rightMouseDown:
                self.showContextMenu()
            case .leftMouseDragged where self.openForFileDrag():
                return
            default:
                self.mouseMoved()
            }
        }) {
            eventMonitors.append(global)
        }
        let localMask = mask.union(.leftMouseDown)
        if let local = NSEvent.addLocalMonitorForEvents(matching: localMask, handler: { [weak self] event in
            guard let self else { return event }
            if event.type != .leftMouseDown {
                self.mouseMoved()
            } else if event.window !== self.panel, event.window !== self.bubble.window {
                // Clic dans une autre fenêtre de l'app (réglages) ; ceux du panneau et de la bulle restent aux vues.
                self.mouseDown()
            }
            return event
        }) {
            eventMonitors.append(local)
        }
        // Touches du panneau quand il a le clavier (ouvert par le raccourci) ; sinon l'événement suit son cours.
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.handleKey(event) else { return event }
            return nil
        }) {
            eventMonitors.append(keys)
        }
    }

    /// Zone de survol du panneau déplié, en coordonnées écran. Replié, la zone dépend de ce qu'on survole : voir
    /// `collapsedHit`.
    private func hoverZone() -> CGRect {
        let size = model.contentSize
        let width = max(size.width, prefs.expandedWidth(compact: isCompact)) + 8
        // L'écart au-dessus de la pilule compte : la souris peut être pile sur le bord haut de l'écran.
        let height = max(size.height, notchRect.height + 40) + 8 + model.notchGap
        return CGRect(x: notchRect.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// Bords inclusifs : la souris peut être pile sur le bord haut de l'écran.
    private func isInsideZone(_ point: CGPoint) -> Bool {
        guard model.isExpanded else { return collapsedHit(point) != .none }
        let zone = hoverZone()
        return point.x >= zone.minX && point.x <= zone.maxX && point.y >= zone.minY && point.y <= zone.maxY
    }

    private func earLayout() -> EarTabsLayout {
        registry.earLayout(claude: store.indicator, claudeEars: store.ears, notch: notchRect.size)
    }

    /// Notch repliée : ce qui est sous `point`, la forme réelle de chaque intercalaire (déployé compris) ou le centre de la
    /// notch. Les zones ne se recouvrent pas : un intercalaire n'ouvre pas le panneau, et le centre n'en déploie aucun.
    private func collapsedHit(_ point: CGPoint) -> EarTabsLayout.Hit {
        // Hors de la fenêtre : rien à calculer (cette fonction tourne à chaque mouvement de souris).
        guard abs(point.x - notchRect.midX) <= Self.panelSize.width / 2,
              point.y >= screenFrame.maxY - Self.panelSize.height else { return .none }
        // Au-dessus de la pilule (bord haut de l'écran) : comme sur son haut.
        let local = CGPoint(x: point.x - notchRect.midX, y: max(0, notchRect.maxY - point.y))
        return earLayout().hit(local, hovered: model.hoveredTab, cardHeight: model.tabCardHeight)
    }

    func mouseMoved() {
        followMouseScreen()
        // Bouton relâché sans que le relâchement nous parvienne (fenêtre retirée en plein glisser) : on termine.
        if detachMonitor != nil || bubble.isMoving, NSEvent.pressedMouseButtons & 1 == 0 { endDetachDrag() }
        // Décollage ou bulle déplacée : la souris est à la bulle, la notch ne réagit pas à son passage.
        guard !bubble.isInteracting else { return }
        let point = mouseLocation()
        // Avant `isShown` : le panneau de la bulle se referme à la sortie de la souris même notch cachée.
        bubble.mouseMoved(point)
        guard isShown else { return }
        let hit = model.isExpanded ? .none : collapsedHit(point)
        let inside = model.isExpanded ? isInsideZone(point) : hit != .none
        if !inside { suppressUntilExit = false }

        if model.isExpanded {
            if inside {
                closeWork?.cancel()
                closeWork = nil
            } else if closeWork == nil, !menuTracking, !staysOpenOutside, !model.isEditingTabs {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.closeWork = nil
                    if !self.menuTracking, !self.model.isEditingTabs, !self.isInsideZone(self.mouseLocation()) {
                        self.collapse()
                    }
                }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + prefs.closeDelay, execute: work)
            }
            return
        }
        updateTabHover(hit)
        // Notch détachée : la bulle est le panneau, le survol de la notch n'en ouvre pas un second.
        if hit == .notch, !suppressUntilExit, prefs.openTrigger == .hover, !model.bubble.isDetached {
            guard openWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.openWork = nil
                if self.isShown, !self.suppressUntilExit, self.collapsedHit(self.mouseLocation()) == .notch {
                    self.expand()
                }
            }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + prefs.openDelay, execute: work)
        } else {
            openWork?.cancel()
            openWork = nil
        }
    }

    // MARK: - Intercalaires

    /// Intention de survol : un intercalaire ne se déploie qu'après ce délai (traverser la barre des menus ne déploie
    /// rien), et ne se replie qu'après le sien (un écart de souris ne le referme pas).
    private static let tabHoverDelay: TimeInterval = 0.12
    private static let tabLeaveDelay: TimeInterval = 0.2

    /// L'intercalaire que la souris vise, sauf s'il vient d'être utilisé (`suppressUntilExit`).
    private func tabTarget(_ hit: EarTabsLayout.Hit) -> String? {
        guard !suppressUntilExit, case .tab(let id) = hit else { return nil }
        return id
    }

    /// Événementiel : appelé à chaque mouvement de souris, rien ne tourne entre deux. Au centre de la notch le panneau
    /// va s'ouvrir, l'intercalaire se replie tout de suite ; ailleurs on laisse passer le délai d'intention.
    private func updateTabHover(_ hit: EarTabsLayout.Hit) {
        let target = tabTarget(hit)
        if hit == .notch {
            cancelPendingTab()
            setHoveredTab(nil)
            return
        }
        if model.hoveredTab == target {
            cancelPendingTab()
            return
        }
        if let pendingTab, pendingTab.target == target { return }
        cancelPendingTab()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingTab = nil
            // La souris est-elle toujours sur la même cible ?
            guard self.isShown, !self.model.isExpanded,
                  self.tabTarget(self.collapsedHit(self.mouseLocation())) == target else { return }
            self.setHoveredTab(target)
        }
        pendingTab = (target, work)
        let delay = target == nil ? Self.tabLeaveDelay : Self.tabHoverDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingTab() {
        pendingTab?.work.cancel()
        pendingTab = nil
    }

    /// Déploie (ou replie, `nil`) un intercalaire. Déployé, il a des boutons : la fenêtre reprend la souris tant qu'il
    /// est là, et 15 Hz de relevé de la souris le gardent honnête (rattrape un mouvement que les moniteurs ne voient pas).
    private func setHoveredTab(_ id: String?) {
        guard model.hoveredTab != id else { return }
        model.hoveredTab = id
        if id == nil { model.tabCardHeight = 0 }
        panel.ignoresMouseEvents = id == nil && !model.isExpanded
        if id != nil {
            startPolling()
        } else if !model.isExpanded {
            stopPolling()
        }
    }

    /// L'activité de l'intercalaire déployé a disparu (Claude a fini, minuteur arrêté) : on le replie.
    private func syncHoveredTab() {
        guard let id = model.hoveredTab, earLayout().item(id) == nil else { return }
        cancelPendingTab()
        setHoveredTab(nil)
    }

    /// Clic sur un intercalaire : le panneau s'ouvre sur son onglet (le « +N » et l'inconnu : l'onglet habituel).
    private func openTab(_ id: String) {
        guard isShown, !model.isExpanded else { return }
        openWork?.cancel()
        openWork = nil
        expand(tab: registry.isEnabled(id) ? id : nil)
    }

    /// Fermé par un clic à l'extérieur (réglage, ou panneau ouvert au clavier), pas par la sortie de la souris.
    private var staysOpenOutside: Bool { prefs.closeOnClickOutside || openedByKeyboard }

    /// Mode « au clic » : clic sur la notch repliée. Panneau ouvert qui attend un clic à l'extérieur : il se ferme.
    /// En mode édition des onglets, un clic à l'extérieur sort seulement du mode.
    func mouseDown(at point: CGPoint = NSEvent.mouseLocation) {
        bubble.mouseDown(at: point)
        guard isShown else { return }
        if model.isExpanded {
            let inside = isInsideZone(point)
            // Un clic dans un menu ouvert depuis le panneau (« … », « + ») n'est pas un clic à l'extérieur.
            guard !inside, !menuTracking else { return }
            if model.isEditingTabs {
                model.isEditingTabs = false
            } else if staysOpenOutside {
                collapse()
            }
        } else {
            switch collapsedHit(point) {
            case .tab(let id):
                // Le clic est arrivé avant le déploiement : même effet que sur l'intercalaire déployé.
                openTab(id)
            case .notch where prefs.openTrigger == .click && !model.bubble.isDetached:
                openWork?.cancel()
                openWork = nil
                expand()
            case .notch, .none:
                break
            }
        }
    }

    /// Écran « sous la souris » : la notch suit la souris d'un écran à l'autre, repliée seulement. Événementiel
    /// (mouvements de souris déjà reçus) ; rien n'est recalculé tant que la souris reste sur le même écran.
    private func followMouseScreen() {
        guard prefs.screenChoice == ScreenChoice.mouse, !model.isExpanded,
              !NotchScreenPicker.contains(screenFrame, NSEvent.mouseLocation) else { return }
        updateGeometry()
    }

    private var isCompact: Bool { model.isFullScreen && prefs.fullScreenBehavior == .compact }

    private func expand(tab: String? = nil) {
        // Notch détachée : un intercalaire ouvre la bulle sur son onglet.
        if model.bubble.isDetached { return bubble.open(tab: tab) }
        guard !model.isExpanded, model.bubble == .attached else { return }
        cancelPendingTab()
        if model.hoveredTab != nil {
            model.hoveredTab = nil
            model.tabCardHeight = 0
        }
        panel.ignoresMouseEvents = false
        model.selectedTab = tab ?? registry.initialTab(claudeNeedsAttention: store.indicator == .attention)
        model.isExpanded = true
        if prefs.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        startPolling()
        registry.setPanelOpen(true)
    }

    private func collapse() {
        bubble.close()
        openWork?.cancel()
        openWork = nil
        closeWork?.cancel()
        closeWork = nil
        cancelPendingTab()
        model.hoveredTab = nil
        model.tabCardHeight = 0
        stopPolling()
        // Le clavier revient à l'app de devant (panneau ouvert au raccourci, ou champ resté actif).
        if panel.isKeyWindow { NotchKeyboard.release(force: true) }
        openedByKeyboard = false
        panel.ignoresMouseEvents = true
        if model.isExpanded {
            model.isExpanded = false
            let tab = Self.tabToRemember(selected: model.selectedTab, beforeDrag: tabBeforeDrag)
            if prefs.lastTab != tab { prefs.lastTab = tab }
        }
        tabBeforeDrag = nil
        registry.setPanelOpen(false)
        shownOnDemand = false
        // Dépliée, la notch restait affichée même sans activité : on relit la règle.
        if isShown { updateVisibility() }
    }

    /// 15 Hz, seulement déplié : rattrape les mouvements que les moniteurs ne voient pas.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in self?.mouseMoved() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Glisser-déposer (Étagère)

    private var shelf: ShelfModule? { registry.module(ShelfModule.moduleId) as? ShelfModule }

    /// Pendant un glisser, plus de `mouseMoved` : seuls des `leftMouseDragged` arrivent, et la fenêtre repliée
    /// laisse passer la souris. Un nouveau contenu du presse-papiers de glisser depuis le clic = un glisser commencé.
    private func armFileDrag() {
        fileDragBaseline = registry.isEnabled(ShelfModule.moduleId) ? NSPasteboard(name: .drag).changeCount : nil
    }

    /// Glisser de fichiers au-dessus de la notch repliée : déplie tout de suite sur l'Étagère, puis `ShelfDropView`
    /// prend le relais (fenêtre qui accepte la souris). Une fois par glisser ; jamais en plein écran « masquée ».
    private func openForFileDrag() -> Bool {
        // shortcut: notch détachée, pas d'Étagère par glisser vers la notch (ni vers la bulle) ; à ajouter si demandé.
        guard let baseline = fileDragBaseline, !model.isExpanded, !model.bubble.isDetached, !hiddenForFullScreen,
              !prefs.isHidden(at: now()),
              Self.dropZone(notch: notchRect, screen: screenFrame,
                            contentWidth: max(model.contentSize.width, 2 * earLayout().reach))
                .contains(NSEvent.mouseLocation) else { return false }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != baseline else { return false }
        fileDragBaseline = nil
        guard ShelfDrop.hasFiles(pasteboard) else { return false }
        showOnDemand()
        tabBeforeDrag = prefs.lastTab
        expand(tab: ShelfModule.moduleId)
        shelf?.isDropTargeted = true
        return true
    }

    /// Notch repliée : la forme et la place des oreilles, élargies (le glisser arrive vite et de biais).
    static func dropZone(notch: CGRect, screen: CGRect, contentWidth: CGFloat) -> CGRect {
        let width = max(contentWidth, notch.width + 2 * earWidth) + 40
        let height = notch.height + 16
        // +1 : la souris peut être pile sur le bord haut de l'écran.
        return CGRect(x: notch.midX - width / 2, y: screen.maxY - height, width: width, height: height + 1)
    }

    /// Onglet mémorisé au repli : l'Étagère montrée par un glisser de fichiers resté sans dépôt ne compte pas.
    static func tabToRemember(selected: String, beforeDrag: String?) -> String {
        selected == ShelfModule.moduleId ? beforeDrag ?? selected : selected
    }

    // MARK: - Actions

    private func activate(_ session: Session) {
        if session.source == .desktop, let url = session.desktopSessionId.flatMap(Self.desktopSessionURL) {
            Self.openInDesktop(url)
        } else {
            let bundleId = session.hostBundleId ?? (session.source == .desktop ? ProcessInspector.desktopBundleId : nil)
            if let bundleId { Self.bringToFront(bundleId: bundleId) }
        }
        suppressUntilExit = true
        collapse()
    }

    /// Lien reconnu par Claude Desktop (gestionnaire `open-url`, hôte `code`, chemin `/continue`) :
    /// il ouvre la session locale dont l'identifiant est exactement `session`, sinon l'accueil de l'onglet Code.
    static func desktopSessionURL(_ sessionId: String) -> URL? {
        guard HookHeaders.isDesktopSessionId(sessionId) else { return nil }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: sessionId)]
        return components.url
    }

    /// Ouvre le lien avec Claude Desktop explicitement, pas avec une autre app qui revendiquerait `claude://`.
    private static func openInDesktop(_ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ProcessInspector.desktopBundleId) else {
            bringToFront(bundleId: ProcessInspector.desktopBundleId)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, _ in }
    }

    /// Sélectionne le fichier dans le Finder ; s'il a disparu, son plus proche dossier parent encore présent.
    private func reveal(_ path: String) {
        guard let target = Self.revealTarget(for: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
        Self.bringToFront(bundleId: "com.apple.finder")
        suppressUntilExit = true
        collapse()
    }

    static func revealTarget(for path: String, fileManager: FileManager = .default) -> URL? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while !fileManager.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return url
    }

    private func openDesktop() {
        Self.bringToFront(bundleId: ProcessInspector.desktopBundleId)
        suppressUntilExit = true
        collapse()
    }

    /// Ouvre un lien profond dans l'app qui le gère (celle de `bundleId`), sinon dans l'app par défaut du lien ; si l'app
    /// refuse le lien, elle est au moins amenée devant.
    static func open(_ url: URL, inAppWithBundleId bundleId: String?) {
        guard let bundleId, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
            if error != nil { DispatchQueue.main.async { bringToFront(bundleId: bundleId) } }
        }
    }

    /// Passe par LaunchServices : une app en arrière-plan ne peut plus toujours en activer une autre directement.
    static func bringToFront(bundleId: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        } else {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?
                .activate(options: [.activateAllWindows])
        }
    }

    // MARK: - Visibilité

    private func observeChanges() {
        Publishers.Merge4(store.objectWillChange, monitor.objectWillChange, prefs.objectWillChange,
                          registry.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibility()
                self?.syncHoveredTab()
            }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            self?.updateGeometry()
            self?.updateFullScreen()
            self?.bubble.screensChanged()
        }))
        observers.append((center, center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            self?.menuTracking = true
        }))
        observers.append((center, center.addObserver(forName: NSMenu.didEndTrackingNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            self?.menuTracking = false
            self?.mouseMoved()
        }))

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            self?.spaceDidChange()
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            self?.followMouseScreen()
            self?.updateFullScreen()
        }))
    }

    private func spaceDidChange() {
        updateFullScreen()
        if isShown {
            updateGeometry()
            panel.orderFrontRegardless()
        }
        // L'animation de changement de Space peut repasser devant, et la fenêtre plein écran n'est pas encore
        // toujours listée : on vérifie de nouveau une fois l'animation finie.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spaceSettleDelay) { [weak self] in
            guard let self else { return }
            self.updateFullScreen()
            if self.isShown { self.panel.orderFrontRegardless() }
            self.bubble.orderFront()
        }
    }

    /// Événementiel (Space, app activée, écrans) : jamais de scrutation.
    private func updateFullScreen() {
        let fullScreen = displayID.map { FullScreenDetector.frontmostAppIsFullScreen(onDisplay: $0) } ?? false
        guard fullScreen != model.isFullScreen else { return }
        model.isFullScreen = fullScreen
        updateVisibility()
    }

    /// Plein écran avec le réglage « masquée ».
    private var hiddenForFullScreen: Bool { model.isFullScreen && prefs.fullScreenBehavior == .hidden }

    /// « Masquer la notch » en cours.
    private var hiddenByUser: Bool { prefs.isHidden(at: now()) }

    /// Sans l'onglet Claude, seules les oreilles des modules comptent (« Quand Claude est ouvert » vaut « Toujours »).
    private var shouldShow: Bool {
        let claude = registry.isClaudeEnabled
        let mode = prefs.visibility.effective(claudeEnabled: claude)
        return NotchVisibilityRule.shouldShow(mode, NotchVisibilityRule.Inputs(
            claudeOpen: claude && (monitor.desktopRunning || !monitor.cliPids.isEmpty || store.hasLiveSessions),
            claudeActive: claude && store.indicator != .none,
            moduleEars: registry.moduleEars != nil,
            onDemand: shownOnDemand,
            // Le panneau de la bulle ouvert compte comme déplié : il ne se ferme pas parce que la notch se cache.
            expanded: model.isExpanded || model.bubble == .bubblePanel,
            hiddenForFullScreen: hiddenForFullScreen,
            hiddenByUser: hiddenByUser))
    }

    private func updateVisibility() {
        // Masquage temporaire échu : on l'oublie (le rappel des réglages disparaît).
        if let until = prefs.hiddenUntil, until <= now() { prefs.hiddenUntil = nil }
        bubble.setSuppressed(hiddenForFullScreen || hiddenByUser)
        if shouldShow {
            hideWork?.cancel()
            hideWork = nil
            if !isShown {
                isShown = true
                updateGeometry()
                panel.orderFrontRegardless()
            }
        } else if isShown, hiddenForFullScreen || hiddenByUser {
            hide()
        } else if isShown, hideWork == nil {
            // Délai anti-clignotement.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideWork = nil
                if !self.shouldShow { self.hide() }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
        }
    }

    private func hide() {
        hideWork?.cancel()
        hideWork = nil
        isShown = false
        collapse()
        panel.orderOut(nil)
    }

    /// Montre la notch le temps d'un usage explicite (dépôt sur l'Étagère, raccourci), même hors de sa règle de
    /// visibilité ; `collapse()` la rend à sa règle.
    private func showOnDemand() {
        if !shouldShow {
            shownOnDemand = true
            hideWork?.cancel()
            hideWork = nil
        }
        if !isShown {
            isShown = true
            updateGeometry()
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Réglages de la notch appliqués à chaud

    private func observeShellSettings() {
        // Le publieur donne la nouvelle valeur avant qu'elle ne soit rangée : on relit au tour suivant.
        Publishers.Merge(prefs.$screenChoice.dropFirst().removeDuplicates().map { _ in () },
                         prefs.$virtualNotchStyle.dropFirst().removeDuplicates().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.model.isExpanded else { return }
                self.updateGeometry()
            }
            .store(in: &cancellables)
        prefs.$hiddenUntil
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleUnhide() }
            .store(in: &cancellables)
        Publishers.Merge3(prefs.$toggleHotKey.map { _ in () }, prefs.$hideHotKey.map { _ in () },
                          prefs.$commandHotKey.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.registerHotKeys() }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }))
        // Un minuteur ne compte pas le temps de veille : au réveil, l'échéance est relue.
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            self?.updateVisibility()
        }))
    }

    /// Une seule échéance pour la fin du masquage temporaire (rien pour « jusqu'à réactivation »).
    private func scheduleUnhide() {
        unhideTimer?.invalidate()
        unhideTimer = nil
        guard let until = prefs.hiddenUntil, until != .distantFuture, until > now() else { return }
        let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            self?.unhideTimer = nil
            self?.updateVisibility()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        unhideTimer = timer
    }

    // MARK: - Clavier

    /// Tout est retiré avant d'enregistrer : une combinaison qui passe d'une action à l'autre serait refusée.
    private func registerHotKeys() {
        let center = HotKeyCenter.shared
        center.set(.none, for: .togglePanel) {}
        center.set(.none, for: .toggleHidden) {}
        center.set(.none, for: .commandBar) {}
        center.set(prefs.toggleHotKey, for: .togglePanel) { [weak self] in self?.togglePanelFromKeyboard() }
        center.set(prefs.hideHotKey, for: .toggleHidden) { [weak self] in self?.toggleHiddenFromKeyboard() }
        center.set(prefs.commandHotKey, for: .commandBar) { [weak self] in self?.toggleCommandBarFromKeyboard() }
    }

    /// Raccourci global : ouvre le panneau avec le clavier (même notch masquée), ou le ferme.
    func togglePanelFromKeyboard() {
        if model.bubble.isDetached { return bubble.togglePanel() }
        if model.isExpanded {
            suppressUntilExit = true
            collapse()
            return
        }
        showOnDemand()
        if prefs.screenChoice == ScreenChoice.mouse { updateGeometry() }
        expand()
        openedByKeyboard = true
        NotchKeyboard.take()
    }

    /// Raccourci global : ouvre la barre de commande (le panneau s'ouvre avec elle, même notch masquée), ou la ferme.
    func toggleCommandBarFromKeyboard() {
        if model.isCommandBarOpen { closeCommandBar() } else { openCommandBar() }
    }

    func openCommandBar() {
        // Notch détachée : la barre s'ouvre dans le panneau de la bulle, qui prend le clavier.
        if model.bubble.isDetached {
            bubble.open(keyboard: true)
            // Bulle encore en mouvement (décollage, retour) : pas de panneau, pas de barre.
            guard model.bubble == .bubblePanel else { return }
            model.isEditingTabs = false
            model.isCommandBarOpen = true
            return
        }
        if !model.isExpanded { togglePanelFromKeyboard() }
        // Le clavier est au champ : le panneau reste ouvert tant que la barre l'est.
        openedByKeyboard = true
        model.isEditingTabs = false
        model.isCommandBarOpen = true
    }

    /// Échap, action lancée, raccourci de nouveau : la barre et le panneau se referment ensemble.
    func closeCommandBar() {
        guard model.isCommandBarOpen else { return }
        if model.bubble.isDetached {
            model.isCommandBarOpen = false
            return bubble.close()
        }
        suppressUntilExit = true
        collapse()
    }

    /// Premier appui de « Approuver au clavier » quand la carte n'est pas à l'écran : on la montre, sans rien décider
    /// et sans prendre le clavier (la frappe en cours continue d'aller à l'app de devant). Ouvert ainsi, le panneau
    /// reste jusqu'à un clic à l'extérieur.
    private func revealApproval(tab: String) {
        // Notch détachée : la carte s'ouvre dans la bulle, qui reste ouverte comme le panneau ci-dessous.
        if model.bubble.isDetached { return bubble.open(tab: tab, staysOpen: true) }
        if model.isExpanded {
            model.selectedTab = tab
            return
        }
        showOnDemand()
        if prefs.screenChoice == ScreenChoice.mouse { updateGeometry() }
        expand(tab: tab)
        openedByKeyboard = true
    }

    /// Mode édition des onglets : le panneau prend le clavier pour qu'Échap en sorte (un champ de texte rend la main),
    /// et le rend à la sortie, sauf s'il l'avait déjà (ouvert au raccourci).
    private func editingTabsChanged(_ editing: Bool) {
        if editing {
            closeWork?.cancel()
            closeWork = nil
            NotchKeyboard.take()
            panel.makeFirstResponder(nil)
        } else if !openedByKeyboard {
            NotchKeyboard.release()
        }
    }

    /// Raccourci global : masque la notch jusqu'à réactivation, ou la réaffiche.
    func toggleHiddenFromKeyboard() {
        if prefs.isHidden(at: now()) { prefs.showAgain() } else { prefs.hide(.untilReactivated, now: now()) }
    }

    /// Panneau ouvert au raccourci : ← → et ⌘1…⌘9 changent d'onglet, Échap ferme et rend le clavier (plein écran
    /// compact compris). Ouvert au survol ou au clic, rien ne change (les champs des modules gardent leurs touches).
    func handleKey(_ event: NSEvent) -> Bool {
        if bubble.handleKey(event) { return true }
        guard model.isExpanded, panel.isKeyWindow,
              let command = NotchKeyCommand.parse(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                                  editingText: panel.firstResponder is NSText) else { return false }
        // Mode édition des onglets : Échap en sort, le panneau reste ouvert.
        if model.isEditingTabs, command == .close {
            model.isEditingTabs = false
            return true
        }
        guard openedByKeyboard else { return false }
        if command == .close {
            suppressUntilExit = true
            collapse()
            return true
        }
        // Plein écran compact : pas d'onglets.
        guard !isCompact else { return false }
        let tabs = registry.enabled.map { $0.id }
        guard let index = command.target(current: tabs.firstIndex(of: model.selectedTab) ?? 0, count: tabs.count)
        else { return false }
        model.selectedTab = tabs[index]
        return true
    }

    // MARK: - Menu contextuel

    /// Clic droit sur la notch repliée (la forme seule, pas les oreilles posées sur la barre des menus).
    private func showContextMenu() {
        let mouse = NSEvent.mouseLocation
        guard isShown, !model.isExpanded,
              NotchScreenPicker.contains(notchRect.insetBy(dx: -2, dy: -2), mouse) else { return }
        let menu = NSMenu()
        let hide = NSMenuItem(title: L("Masquer la notch"), action: nil, keyEquivalent: "")
        let durations = NSMenu()
        for duration in HideDuration.allCases {
            durations.addItem(ClosureMenuItem(Self.title(duration)) { [weak self] in
                guard let self else { return }
                self.prefs.hide(duration, now: self.now())
            })
        }
        durations.addItem(.separator())
        let hint = NSMenuItem(title: HiddenNotice.howToShowAgain(hotKey: prefs.hideHotKey), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        durations.addItem(hint)
        hide.submenu = durations
        menu.addItem(hide)
        if model.bubble.isDetached {
            menu.addItem(ClosureMenuItem(L("Rattacher à la notch", table: "Bubble")) { [weak self] in
                self?.bubble.reattach()
            })
        } else if prefs.allowsDetach {
            menu.addItem(ClosureMenuItem(L("Détacher la notch", table: "Bubble")) { [weak self] in
                self?.detachFromMenu()
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Réglages…")) { [weak self] in self?.openSettings() })
        menu.popUp(positioning: nil, at: mouse, in: nil)
    }

    // MARK: - Bulle

    private func startBubble(actions: NotchActions) {
        bubble.notchRect = { [weak self] in self?.notchRect ?? .zero }
        bubble.notchWindow = { [weak self] in self?.panel }
        bubble.collapseNotch = { [weak self] in self?.collapseForBubble() }
        bubble.didAttach = { [weak self] in
            // La souris est sous la notch : elle ne la rouvre pas avant d'en être sortie.
            self?.suppressUntilExit = true
            self?.updateVisibility()
        }
        bubble.openSettings = { [weak self] in self?.openSettings() }
        bubble.isMenuTracking = { [weak self] in self?.menuTracking ?? false }
        bubble.start(actions: actions)
    }

    /// Panneau déplié en coordonnées écran : la forme visible (sans les évasements du haut).
    private var expandedPanelRect: CGRect {
        let size = model.contentSize
        return CGRect(x: notchRect.midX - size.width / 2, y: notchRect.maxY - size.height, width: size.width,
                      height: size.height).insetBy(dx: 12, dy: 0)
    }

    /// Appui maintenu sur la poignée : les glisser et le relâchement arrivent à cette fenêtre (celle du clic) jusqu'au
    /// relâchement, même hors d'elle.
    private func beginDetach() {
        guard prefs.allowsDetach, model.isExpanded, model.bubble == .attached, detachMonitor == nil else { return }
        closeWork?.cancel()
        closeWork = nil
        bubble.beginPull(panel: expandedPanelRect)
        detachMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseUp { self.endDetachDrag() } else { self.bubble.pullMoved() }
            return event
        }
    }

    /// Fin du glisser : goutte rentrée, ou bulle posée (rangée, ou rattachée près de la notch).
    private func endDetachDrag() {
        if let monitor = detachMonitor { NSEvent.removeMonitor(monitor) }
        detachMonitor = nil
        bubble.pullEnded()
    }

    /// « Détacher la notch » (menu « … », clic droit, VoiceOver) : sans glisser.
    private func detachFromMenu() {
        guard prefs.allowsDetach, model.bubble == .attached else { return }
        closeWork?.cancel()
        closeWork = nil
        bubble.detachAutomatically(panel: model.isExpanded ? expandedPanelRect : nil)
    }

    /// La goutte a pris la place du panneau : la notch se replie dessous, sans animation.
    private func collapseForBubble() {
        suppressUntilExit = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { collapse() }
    }

    static func title(_ duration: HideDuration) -> String {
        switch duration {
        case .oneHour: return L("Pendant 1 heure")
        case .untilTomorrow: return L("Jusqu'à demain")
        case .untilReactivated: return L("Jusqu'à réactivation")
        }
    }
}
