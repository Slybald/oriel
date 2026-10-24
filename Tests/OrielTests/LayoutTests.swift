import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// La vue doit remonter la taille réelle de la forme : le contrôleur s'en sert pour les zones de survol.
final class LayoutTests: XCTestCase {
    /// Panneau standard + 2 × 12 de rayon haut.
    private static let standardWidth = PanelSize.standard.width + 24

    func testContentSizeIsReported() {
        let notch = NotchHarness(self, store: .working(1))
        let model = notch.model
        let hosting = FirstMouseHostingView(rootView: notch.root)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: NotchController.panelSize)
        let window = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // Replié : exactement la notch (sans évasement sur une vraie encoche) ; les intercalaires se posent à côté (`EarTabsLayout`).
        XCTAssertEqual(model.contentSize.width, 185, accuracy: 1)
        XCTAssertEqual(model.contentSize.height, 32, accuracy: 1)

        model.isExpanded = true
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(model.contentSize.width, Self.standardWidth, accuracy: 1)
        XCTAssertGreaterThan(model.contentSize.height, 80)

        // Plein écran, réglage compact : demi-largeur.
        model.isFullScreen = true
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(model.contentSize.width, Preferences.compactPanelWidth + 24, accuracy: 1)

        model.isExpanded = false
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(model.contentSize.width, 185, accuracy: 1, "replié : la notch seule")
        XCTAssertEqual(model.contentSize.height, 32, accuracy: 1)
        window.close()
    }

    /// Survoler un onglet l'ouvre : les onglets ne doivent pas bouger, sinon un autre glisse sous la souris et
    /// s'ouvre à son tour sans que l'utilisateur ait bougé. Le mode édition n'y change rien : « + » vient après.
    func testTabPositionsDoNotDependOnSelection() {
        let modules: [any NotchModule] = [FakeModule(id: "a"), FakeModule(id: "un titre assez long"), FakeModule(id: "c")]
        let registry = ModuleRegistry(modules: modules, prefs: Preferences(defaults: makeEphemeralDefaults(self)))
        func width(_ selection: String, editing: Bool) -> CGFloat {
            NSHostingView(rootView: NotchTabBar(registry: registry, selection: .constant(selection),
                                                editing: .constant(editing))).fittingSize.width
        }
        let widths = modules.map { width($0.id, editing: false) }
        XCTAssertEqual(Set(widths).count, 1, "largeur de la barre selon l'onglet actif : \(widths)")
        XCTAssertEqual(width("a", editing: true), widths[0] + NotchTabBar.spacing + NotchTabBar.tabWidth,
                       "mode édition : mêmes onglets, « + » en bout de barre")
    }

    /// Taille du panneau choisie dans les réglages, et plein écran « normal » qui la garde.
    func testPanelSizeFollowsPreferences() {
        for size in PanelSize.allCases {
            let notch = NotchHarness(self, store: .working(1))
            notch.prefs.panelSize = size
            notch.model.isExpanded = true
            XCTAssertEqual(notch.measure().width, size.width + 24, accuracy: 1, size.rawValue)
        }
        let notch = NotchHarness(self, store: .working(1))
        notch.prefs.fullScreenBehavior = .normal
        notch.model.isFullScreen = true
        notch.model.isExpanded = true
        XCTAssertEqual(notch.measure().width, Self.standardWidth, accuracy: 1)
    }

    /// Replié, la forme mesurée est toujours la notch ; les oreilles (un intercalaire chacune) s'ajoutent de chaque côté.
    func testEarsFollowPreferencesAndModules() {
        let notch = NotchHarness(self, store: .working(1))
        notch.prefs.showEars = false
        XCTAssertEqual(notch.measure().width, 185, accuracy: 1)

        let idle = NotchHarness(self)
        let timer = FakeModule(id: "fake", ears: ModuleEars(symbol: "timer", text: "4:59"), keepsRunning: true)
        let registry = ModuleRegistry(modules: [idle.claude, timer], prefs: idle.prefs)
        registry.reconcile()
        let root = NotchRootView(model: idle.model, store: idle.store, registry: registry, prefs: idle.prefs,
                                 actions: NotchActions())
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: NotchController.panelSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(idle.model.contentSize.width, 185, accuracy: 1, "la notch ne s'élargit plus")
        let layout = registry.earLayout(claude: .none, claudeEars: nil, notch: idle.model.notchSize)
        XCTAssertEqual(layout.left.map { $0.id }, ["fake"], "l'intercalaire du module est posé à gauche")
        window.close()
    }

    static let absentPaths: ToolsFeed.Paths = {
        let missing = URL(fileURLWithPath: "/nonexistent/oriel")
        return ToolsFeed.Paths(files: missing.appendingPathComponent("files.jsonl"),
                               gitState: missing.appendingPathComponent("state.json"),
                               usage: missing.appendingPathComponent("today.json"))
    }()

    /// Section outils : comptée dans la taille remontée (zone de survol) et jamais plus haute que le panneau.
    func testToolsSectionFitsInPanel() throws {
        _ = NSApplication.shared
        let fixtures = try ToolsFixtures()
        defer { fixtures.remove() }
        try fixtures.writeSample(now: Date())
        let tools = ToolsFeed(paths: fixtures.paths) { _ in true }
        tools.refreshNow()
        XCTAssertTrue(tools.hasContent)

        // Une session : la section ouverte agrandit la forme, donc la zone de survol.
        let few = SessionStore.working(1)
        let base = measure(few, ToolsFeed(paths: Self.absentPaths), pane: nil)
        let closed = measure(few, tools, pane: nil)
        let files = measure(few, tools, pane: .files)
        let git = measure(few, tools, pane: .git)
        XCTAssertEqual(closed.width, Self.standardWidth, accuracy: 1)
        XCTAssertGreaterThan(closed.height, base.height + 40)
        XCTAssertGreaterThan(files.height, closed.height + 80)
        XCTAssertGreaterThan(git.height, closed.height + 30)

        // Beaucoup de sessions : la liste cède la place, le tout reste sous 460 pt (fenêtre de 480 moins l'ombre).
        let many = SessionStore.working(8)
        let crowdedBase = measure(many, ToolsFeed(paths: Self.absentPaths), pane: nil)
        XCTAssertEqual(crowdedBase.height, 32 + ExpandedPanel.headerHeight + 10 + ClaudePanel.maxListHeight + 14,
                       accuracy: 1, "sans outils : bande de la barre des menus, onglets dessous, liste à 296")
        for pane in [nil, ToolsPane.files, ToolsPane.git] {
            let size = measure(many, tools, pane: pane)
            XCTAssertLessThanOrEqual(size.height, 461, "volet \(String(describing: pane))")
            XCTAssertGreaterThan(size.height, crowdedBase.height)
        }
    }

    /// La carte qui propose les réponses (volets fermés) et une conversation ouverte ne font pas déborder le panneau.
    func testRepliesPromptAndConversationFitInPanel() {
        let notch = NotchHarness(self, store: .working(8))
        notch.model.isExpanded = true
        notch.prefs.replyPromptDismissed = false
        XCTAssertLessThanOrEqual(notch.measure().height, 461, "carte + 8 sessions")

        notch.prefs.replyFromNotch = true
        notch.claude.drafts.composing = "s0"
        notch.claude.drafts.messages["s0"] = "Bonjour"
        XCTAssertLessThanOrEqual(notch.measure().height, 461, "conversation ouverte")
    }

    /// Les onglets vides ne débordent pas, quelle que soit la taille du panneau.
    func testEveryTabFitsInPanel() {
        for size in PanelSize.allCases {
            let notch = NotchHarness(self, store: .working(8))
            notch.prefs.panelSize = size
            notch.model.isExpanded = true
            for module in notch.registry.enabled {
                notch.model.selectedTab = module.id
                let measured = notch.measure(settle: 0.4)
                XCTAssertEqual(measured.width, size.width + 24, accuracy: 1, "\(module.id) \(size.rawValue)")
                XCTAssertLessThanOrEqual(measured.height, 461, "\(module.id) \(size.rawValue)")
            }
        }
    }

    private func measure(_ store: SessionStore, _ tools: ToolsFeed, pane: ToolsPane?) -> CGSize {
        let notch = NotchHarness(self, store: store, tools: tools)
        notch.model.isExpanded = true
        notch.claude.toolsPane = pane
        return notch.measure()
    }

    /// Diagnostic : contexte résolu pour un vrai processus (`ORIEL_PROBE_PID`).
    func testProbeRealProcess() throws {
        guard let raw = ProcessInfo.processInfo.environment["ORIEL_PROBE_PID"] else {
            throw XCTSkip("ORIEL_PROBE_PID non défini")
        }
        let context = ProcessInspector.context(for: HookHeaders(["x-claude-ppid": raw]))
        print("PROBE pid=\(context.claudePid.map(String.init) ?? "-") source=\(context.source) "
              + "host=\(context.hostName ?? "-") bundle=\(context.hostBundleId ?? "-")")
        let chain = ProcessInspector.ancestors(of: pid_t(raw) ?? 0)
        print("PROBE chain: " + chain.map { "\($0.pid) \($0.name)" }.joined(separator: " / "))
    }
}
