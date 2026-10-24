import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendus PNG hors écran de la barre de commande (champ, lignes, pastilles de verbes, états vides) et sa hauteur.
/// Les rendus ne font rien sans `ORIEL_SNAPSHOT_DIR` ; données fictives, aucun accès système.
final class CommandBarSnapshotTests: XCTestCase {
    private var outputDir: URL? { TimerNotesSnapshot.outputDirectory }

    /// Les cinq modules qui ont des commandes, branchés sur des doubles, dans l'ordre des onglets.
    private final class Scene {
        let prefs: Preferences
        let timer: TimerModule
        let notes: NotesModule
        let clipboard: ClipboardModule
        let quick: QuickSettingsModule
        let claude: ClaudeModule
        private let keep: [Any]

        init(_ test: XCTestCase) throws {
            _ = NSApplication.shared
            prefs = Preferences(defaults: makeEphemeralDefaults(test))
            prefs.replyFromNotch = true
            let replies = ReplyCenter(prefs: prefs)
            let store = SessionStore()
            let config = FileManager.default.temporaryDirectory.appendingPathComponent("oriel-no-config")
            claude = ClaudeModule(store: store, monitor: ClaudeMonitor(), tools: ToolsFeed(paths: LayoutTests.absentPaths),
                                  prefs: prefs, hooks: HookSetup(installer: HookInstaller(configDirectory: config,
                                                                                         bundledHook: nil)),
                                  replies: replies)
            let context = ProcessContext(source: .cli, hostName: "iTerm2", hostBundleId: "com.googlecode.iterm2")
            store.send("UserPromptSubmit", "mon-app", ["prompt": "Lance les tests"], context: context)
            store.send("PreToolUse", "mon-app", ["tool_name": "Bash", "tool_use_id": "t1",
                                                 "tool_input": ["command": "swift test"]], context: context)
            store.send("UserPromptSubmit", "api", ["prompt": "Nettoie le build"], context: context)
            store.send("Stop", "api", ["last_assistant_message": "Terminé."], context: context)

            let timerRig = try TimerRig(test)
            timer = timerRig.startedModule()
            let notesRig = try NotesRig(test)
            notes = notesRig.startedModule()
            let clipboardRig = try test.makeClipboardRig()
            clipboardRig.copy("https://github.com/exemple/barre-de-commande")
            clipboardRig.copy("Recette de crêpes : 250 g de farine, 3 œufs, 50 cl de lait")
            clipboardRig.copy("Le lien vers la doc est dans le canal #produit")
            clipboardRig.copy("lien-de-partage-v2.pdf")
            clipboard = clipboardRig.module
            let quickFixture = QuickSettingsFixture(test)
            quick = quickFixture.startAndShow()
            keep = [timerRig, notesRig, clipboardRig.pasteboard, quickFixture]
        }

        var modules: [any NotchModule] { [claude, quick, clipboard, timer, notes] }

        func bar(_ text: String) -> CommandBarModel {
            let model = CommandBarModel(modules: { [self] in modules })
            model.text = text
            return model
        }

        /// La barre dans la forme de la notch dépliée, sur un fond clair comme les autres rendus.
        func view(_ model: CommandBarModel) -> some View {
            CommandBarView(model: model, prefs: prefs, notchHeight: 32, close: {})
                .padding(.horizontal, 12)
                .background(NotchShape(topRadius: 12, bottomRadius: 24).fill(prefs.panelColor))
                .clipShape(NotchShape(topRadius: 12, bottomRadius: 24))
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    func testRenderCommandBar() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let scene = try Scene(self)
        let size = CGSize(width: 560, height: 470)
        let shots: [(String, String)] = [
            ("command-empty", ""),
            ("command-timer-25", "t 25"),
            ("command-timer-menu", "t "),
            ("command-notes", "n idée pour la barre"),
            ("command-clipboard", "c lien"),
            ("command-scene", "s pré"),
            ("command-claude", "> relance les tests du parseur"),
            ("command-nothing", "c introuvable"),
        ]
        for (name, text) in shots {
            try TimerNotesSnapshot.render(scene.view(scene.bar(text)), name, outputDir, size: size)
        }
    }

    /// Cinq lignes, la pastille de chaque verbe et le pied : le panneau reste sous ses 460 pt.
    func testFullBarFitsInPanel() throws {
        let scene = try Scene(self)
        let model = scene.bar("")
        // Cinq lignes au plus, quoi que les modules proposent.
        let many = CommandBarModel(modules: { [Spy.many] })
        many.text = "x"
        XCTAssertEqual(many.results.count, CommandBarModel.maxResults)
        XCTAssertEqual(model.verbs.count, 5)

        let hosting = NSHostingView(rootView: CommandBarView(model: many, prefs: scene.prefs, notchHeight: 32, close: {}))
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        XCTAssertGreaterThan(height, 300, "la hauteur mesurée est celle de la barre")
        XCTAssertLessThanOrEqual(height, ExpandedPanel.maxPanelHeight, "la barre tient dans la fenêtre du panneau")
    }

    /// Module de cinq lignes toujours.
    private final class Spy: NotchModule {
        static let many = Spy()
        let id = "spy"
        let symbol = "star"
        var title: String { id }
        var commandVerb: CommandVerb? { CommandVerb(key: "x", title: "spy") }
        func commands(for query: CommandQuery) -> [NotchCommand] {
            (0..<8).map { NotchCommand(id: "spy.\($0)", symbol: "star", title: "Ligne \($0)", detail: "Détail", score: 8 - $0) }
        }
        func makeView() -> AnyView { AnyView(EmptyView()) }
    }
}
