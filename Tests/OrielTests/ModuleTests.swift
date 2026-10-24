import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Module factice : compte ses démarrages et arrêts.
final class FakeModule: NotchModule {
    let id: String
    let symbol = "circle"
    var title: String { id }
    let isEnabledByDefault: Bool
    @Published var keepsRunningWhenCollapsed: Bool
    @Published var ears: ModuleEars?
    private(set) var starts = 0
    private(set) var stops = 0

    init(id: String, enabledByDefault: Bool = true, ears: ModuleEars? = nil, keepsRunning: Bool = false) {
        self.id = id
        isEnabledByDefault = enabledByDefault
        self.ears = ears
        keepsRunningWhenCollapsed = keepsRunning
    }

    var isRunning: Bool { starts > stops }
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func makeView() -> AnyView { AnyView(EmptyView()) }
}

final class ModuleTests: XCTestCase {
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: - Registre

    func testStandardModulesHaveStableIdsAndClaudeFirst() {
        let notch = NotchHarness(self)
        XCTAssertEqual(notch.registry.modules.map { $0.id },
                       ["claude", "codex", "media", "agenda", "quicksettings", "shelf", "clipboard", "timer", "notes", "messages", "mail"])
        // Codex n'est activé d'office que s'il est détecté (décidé au premier lancement, jamais sous test) ; Messages et
        // Mail restent désactivés tant que l'utilisateur ne les choisit pas.
        XCTAssertEqual(notch.registry.enabled.map { $0.id }, ["claude", "media", "agenda", "quicksettings", "shelf", "clipboard", "timer", "notes"],
                       "Codex, Messages et Mail restent désactivés tant que l'utilisateur ne les choisit pas")
        XCTAssertEqual(notch.registry.hidden.map { $0.id }, ["codex", "messages", "mail"])
        for module in notch.registry.modules {
            XCTAssertNotNil(NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil), module.symbol)
            XCTAssertFalse(module.title.isEmpty)
        }
    }

    func testOrderAndActivationComeFromPreferences() {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let modules = [FakeModule(id: "claude"), FakeModule(id: "a"), FakeModule(id: "b"),
                       FakeModule(id: "c", enabledByDefault: false)]
        let registry = ModuleRegistry(modules: modules, prefs: prefs)
        XCTAssertEqual(registry.enabled.map { $0.id }, ["claude", "a", "b"])

        // Ordre enregistré : identifiants inconnus ignorés, doublons retirés, modules absents à la fin.
        prefs.tabOrder = ["b", "inconnu", "claude", "b"]
        prefs.tabEnabled = ["c": true, "a": false, "claude": false]
        settle()
        XCTAssertEqual(registry.ordered.map { $0.id }, ["b", "claude", "a", "c"])
        XCTAssertEqual(registry.enabled.map { $0.id }, ["b", "c"], "Claude se désactive comme les autres")
        XCTAssertFalse(registry.isClaudeEnabled)

        registry.move(from: IndexSet(integer: 3), to: 0)
        settle()
        XCTAssertEqual(prefs.tabOrder, ["c", "b", "claude", "a"])
        registry.setEnabled("claude", true)
        settle()
        XCTAssertTrue(registry.isClaudeEnabled)
        XCTAssertEqual(registry.enabled.map { $0.id }, ["c", "b", "claude"])
    }

    /// Onglet Claude décidé une fois, selon la présence de Claude Code, puis jamais redécidé.
    func testClaudeTabDecidedOnceFromDetection() {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.decideClaudeTab(claudeCodePresent: { false })
        XCTAssertEqual(prefs.tabEnabled["claude"], false, "pas de Claude Code : onglet désactivé")
        prefs.decideClaudeTab(claudeCodePresent: { XCTFail("déjà décidé : pas de nouvelle détection"); return true })
        XCTAssertEqual(prefs.tabEnabled["claude"], false)

        let withClaude = Preferences(defaults: makeEphemeralDefaults(self))
        withClaude.decideClaudeTab(claudeCodePresent: { true })
        XCTAssertEqual(withClaude.tabEnabled["claude"], true)

        // Mise à jour depuis la 1.2.0 : les autres onglets choisis sont gardés.
        let update = Preferences(defaults: makeEphemeralDefaults(self))
        update.tabEnabled = ["media": false]
        update.decideClaudeTab(claudeCodePresent: { true })
        XCTAssertEqual(update.tabEnabled, ["media": false, "claude": true])
    }

    /// Détection : `~/.claude` ou `$CLAUDE_CONFIG_DIR` (dossier), rien d'autre ; jamais réelle sous XCTest.
    func testClaudeCodeDetection() throws {
        let home = try makeTemporaryDirectory(self)
        XCTAssertFalse(HookInstaller.claudeCodePresent(home: home, environment: [:]))
        let custom = home.appendingPathComponent("config-claude")
        XCTAssertFalse(HookInstaller.claudeCodePresent(home: home, environment: ["CLAUDE_CONFIG_DIR": custom.path]))
        try Data().write(to: custom)
        XCTAssertFalse(HookInstaller.claudeCodePresent(home: home, environment: ["CLAUDE_CONFIG_DIR": custom.path]),
                       "un fichier n'est pas un dossier de configuration")
        try FileManager.default.removeItem(at: custom)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        XCTAssertTrue(HookInstaller.claudeCodePresent(home: home, environment: ["CLAUDE_CONFIG_DIR": custom.path]))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(HookInstaller.claudeCodePresent(home: home, environment: [:]))
        XCTAssertFalse(HookInstaller.claudeCodeOnThisMac, "jamais le vrai Mac sous XCTest")
    }

    /// Rien ne tourne panneau replié, sauf un module qui le demande ; un module désactivé s'arrête.
    func testModulesRunOnlyWhenEnabledAndUseful() {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let claude = FakeModule(id: "claude")
        let media = FakeModule(id: "media")
        let timer = FakeModule(id: "timer")
        let registry = ModuleRegistry(modules: [claude, media, timer], prefs: prefs)
        registry.reconcile()
        XCTAssertFalse(claude.isRunning || media.isRunning || timer.isRunning, "replié : rien ne tourne")

        registry.setPanelOpen(true)
        XCTAssertTrue(claude.isRunning && media.isRunning && timer.isRunning)

        prefs.tabEnabled["media"] = false
        settle()
        XCTAssertFalse(media.isRunning, "désactivé : arrêté même panneau ouvert")

        registry.setPanelOpen(false)
        XCTAssertFalse(claude.isRunning || timer.isRunning)

        // Un minuteur démarre : le module demande à tourner replié.
        timer.keepsRunningWhenCollapsed = true
        settle()
        XCTAssertTrue(timer.isRunning)
        XCTAssertFalse(claude.isRunning)
        timer.keepsRunningWhenCollapsed = false
        settle()
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(media.starts, 1)
        XCTAssertEqual(media.stops, 1)
    }

    func testModuleEarsPriority() {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let media = FakeModule(id: "media", ears: ModuleEars(symbol: "music.note", text: "♪", priority: 1),
                               keepsRunning: true)
        let timer = FakeModule(id: "timer", ears: ModuleEars(symbol: "timer", text: "4:59", priority: 2),
                               keepsRunning: true)
        let idle = FakeModule(id: "notes", ears: ModuleEars(symbol: "note", text: "!", priority: 9))
        let registry = ModuleRegistry(modules: [FakeModule(id: "claude"), media, timer, idle], prefs: prefs)
        registry.reconcile()
        XCTAssertEqual(registry.moduleEars?.text, "4:59", "priorité la plus haute parmi les modules qui tournent")

        timer.ears = nil
        settle()
        XCTAssertEqual(registry.moduleEars?.text, "♪")

        // À égalité, l'ordre des onglets.
        XCTAssertEqual(ModuleRegistry.pickEars([ModuleEars(symbol: "a", text: "1"),
                                                ModuleEars(symbol: "b", text: "2")])?.text, "1")
    }

    /// Claude d'abord (attend, travaille, vient de finir), puis chaque module qui a des oreilles
    /// (la table complète, répartition comprise, est dans `EarTabsTests`).
    func testEarsChoice() {
        let timer = ModuleEarsEntry(id: "timer", ears: ModuleEars(symbol: "timer", text: "4:59"))
        func ids(_ claude: NotchIndicator, _ modules: [ModuleEarsEntry], showEars: Bool = true) -> [String] {
            EarTabs.tabs(claude: claude, claudeEars: nil, modules: modules, showEars: showEars).map { $0.id }
        }
        XCTAssertEqual(ids(.attention, [timer]), ["claude", "timer"])
        XCTAssertEqual(ids(.working, [timer]), ["claude", "timer"])
        XCTAssertEqual(ids(.done, [timer]), ["claude", "timer"])
        XCTAssertEqual(ids(.none, [timer]), ["timer"])
        XCTAssertEqual(ids(.none, []), [])
        XCTAssertEqual(ids(.attention, [timer], showEars: false), [])
    }

    func testInitialTab() {
        let notch = NotchHarness(self)
        let registry = notch.registry
        let prefs = notch.prefs
        XCTAssertEqual(registry.initialTab(claudeNeedsAttention: false), "claude")

        prefs.lastTab = "timer"
        XCTAssertEqual(registry.initialTab(claudeNeedsAttention: false), "timer", "dernier onglet utilisé")
        XCTAssertEqual(registry.initialTab(claudeNeedsAttention: true), "claude", "Claude attend : Claude")

        prefs.defaultTab = "media"
        XCTAssertEqual(registry.initialTab(claudeNeedsAttention: false), "media", "onglet par défaut")

        prefs.tabEnabled["media"] = false
        settle()
        XCTAssertEqual(registry.initialTab(claudeNeedsAttention: false), "claude", "onglet désactivé : le premier")

        // Onglet Claude désactivé : jamais de bascule vers lui, le premier onglet activé par défaut.
        prefs.tabEnabled["claude"] = false
        prefs.lastTab = "claude"
        prefs.defaultTab = Preferences.lastTabChoice
        settle()
        XCTAssertEqual(registry.initialTab(claudeNeedsAttention: true), "agenda", "Claude désactivé")
        XCTAssertEqual(registry.initialTab(claudeNeedsAttention: false), "agenda")
    }

    /// Le module Claude n'active la section outils que panneau ouvert, et oublie ses volets à la fermeture.
    func testClaudeModuleLifecycle() {
        let tools = ToolsFeed(paths: LayoutTests.absentPaths)
        let notch = NotchHarness(self, tools: tools)
        notch.registry.reconcile()
        XCTAssertFalse(tools.isActive)
        notch.registry.setPanelOpen(true)
        XCTAssertTrue(tools.isActive)
        notch.claude.toolsPane = .git
        notch.claude.openChecklists = ["s"]
        notch.registry.setPanelOpen(false)
        XCTAssertFalse(tools.isActive)
        XCTAssertNil(notch.claude.toolsPane)
        XCTAssertEqual(notch.claude.openChecklists, [])
    }

    // MARK: - Plein écran

    func testFullScreenDetection() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        func window(_ pid: Int32, _ rect: CGRect, layer: Int = 0) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowBounds as String: rect.dictionaryRepresentation]
        }
        let full = window(42, display)
        let zoomed = window(42, CGRect(x: 0, y: 33, width: 1512, height: 949))
        XCTAssertTrue(FullScreenDetector.isFullScreen(windows: [zoomed, full], pid: 42, displayBounds: display))
        XCTAssertFalse(FullScreenDetector.isFullScreen(windows: [zoomed], pid: 42, displayBounds: display),
                       "agrandie : la barre des menus reste visible")
        XCTAssertFalse(FullScreenDetector.isFullScreen(windows: [full], pid: 7, displayBounds: display),
                       "plein écran d'une autre app que celle au premier plan")
        XCTAssertFalse(FullScreenDetector.isFullScreen(windows: [window(42, display, layer: 25)], pid: 42,
                                                       displayBounds: display), "couche système, pas une fenêtre")
        // Second écran à droite : coordonnées globales.
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        XCTAssertTrue(FullScreenDetector.isFullScreen(windows: [window(42, external)], pid: 42,
                                                      displayBounds: external))
        XCTAssertFalse(FullScreenDetector.isFullScreen(windows: [window(42, external)], pid: 42,
                                                       displayBounds: display))
    }

    // MARK: - Réglages

    func testPreferencesPersistAndClamp() {
        let defaults = makeEphemeralDefaults(self)
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.fullScreenBehavior, .compact)
        XCTAssertEqual(prefs.panelSize, .standard)
        XCTAssertEqual(prefs.accentHex, "D97757")
        XCTAssertTrue(prefs.showEars)
        XCTAssertTrue(prefs.hapticFeedback)
        XCTAssertEqual(prefs.defaultTab, Preferences.lastTabChoice)

        prefs.fullScreenBehavior = .hidden
        prefs.panelSize = .large
        prefs.accentHex = "4C8DFF"
        prefs.openDelay = 0.2
        prefs.tabOrder = ["timer", "claude"]
        prefs.tabEnabled = ["notes": false]
        prefs.backgroundOpacity = 0.8
        prefs.replyFromNotch = true

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.fullScreenBehavior, .hidden)
        XCTAssertEqual(reloaded.panelSize, .large)
        XCTAssertEqual(reloaded.accentHex, "4C8DFF")
        XCTAssertEqual(reloaded.openDelay, 0.2, accuracy: 0.001)
        XCTAssertEqual(reloaded.tabOrder, ["timer", "claude"])
        XCTAssertEqual(reloaded.tabEnabled, ["notes": false])
        XCTAssertEqual(reloaded.backgroundOpacity, 0.8, accuracy: 0.001)
        XCTAssertTrue(reloaded.replyFromNotch)

        // Valeurs hors bornes ou illisibles (defaults write) : bornées ou remplacées.
        defaults.set(-3.0, forKey: "hover.openDelay")
        defaults.set(99.0, forKey: "hover.closeDelay")
        defaults.set(0.0, forKey: "appearance.backgroundOpacity")
        defaults.set("violet", forKey: "appearance.accent")
        defaults.set("géant", forKey: "appearance.panelSize")
        let clamped = Preferences(defaults: defaults)
        XCTAssertEqual(clamped.openDelay, Preferences.openDelayRange.lowerBound)
        XCTAssertEqual(clamped.closeDelay, Preferences.closeDelayRange.upperBound)
        XCTAssertEqual(clamped.backgroundOpacity, Preferences.opacityRange.lowerBound)
        XCTAssertEqual(clamped.accentHex, "D97757")
        XCTAssertEqual(clamped.panelSize, .standard)
    }

    func testAccentColorRoundTrip() {
        for hex in Preferences.accentPresets {
            XCTAssertEqual(Color(hex: hex)?.hexString, hex)
        }
        XCTAssertEqual(Color(hex: "#4c8dff")?.hexString, "4C8DFF")
        XCTAssertNil(Color(hex: "12345"))
        XCTAssertNil(Color(hex: "GGGGGG"))
    }
}
