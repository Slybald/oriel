import SwiftUI
import XCTest
@testable import Oriel

/// Barre de commande : analyse de la saisie, recherche floue, classement, routage vers les modules, exécution par
/// module sur doubles. Aucune fenêtre.
final class CommandBarTests: XCTestCase {
    // MARK: - Analyse

    func testLeadingVerbTable() {
        let keys = ["t", "n", "c", "s", ">"]
        let table: [(String, key: String?, rest: String?)] = [
            ("t 25", "t", "25"),
            ("T 25", "t", "25"),
            ("  c   lien", "c", "lien"),
            ("n idée", "n", "idée"),
            ("t ", "t", ""),
            ("> relance les tests", ">", "relance les tests"),
            (">relance", ">", "relance"),
            ("s présentation", "s", "présentation"),
            // Une lettre n'est un verbe que suivie d'une espace : le texte libre reste libre.
            ("t", nil, nil),
            ("tomate", nil, nil),
            ("25 min", nil, nil),
            ("x 25", nil, nil),
            ("", nil, nil),
        ]
        for (input, key, rest) in table {
            let found = CommandParser.leadingVerb(in: input, keys: keys)
            XCTAssertEqual(found?.key, key, input)
            XCTAssertEqual(found?.rest, rest, input)
        }
        XCTAssertNil(CommandParser.leadingVerb(in: "n idée", keys: ["t"]), "verbe d'un module absent")
    }

    func testDurationTable() {
        let table: [(String, bare: Bool, Int?)] = [
            ("25", true, 25), ("25", false, nil), ("25 min", false, 25), ("25m", false, 25), ("25 minutes", true, 25),
            ("1h", false, 60), ("1h30", false, 90), ("1 h 30 min", false, 90), ("2 heures", false, 120),
            ("24h", false, 1440), ("1500 min", true, nil), ("0", true, nil), ("0 min", false, nil),
            ("1h75", false, nil), ("abc", true, nil), ("", true, nil), ("25 minutes de café", true, nil),
        ]
        for (input, bare, minutes) in table {
            XCTAssertEqual(CommandDuration.minutes(from: input, allowBare: bare), minutes, "« \(input) »")
        }
    }

    // MARK: - Recherche floue

    func testFuzzyIgnoresCaseAndAccentsAndNeedsEveryWord() {
        XCTAssertNotNil(FuzzyMatch.score("PRES", in: "Présentation"))
        XCTAssertNotNil(FuzzyMatch.score("présen", in: "presentation"))
        XCTAssertNotNil(FuzzyMatch.score("lien doc", in: "le lien vers la doc"))
        XCTAssertNil(FuzzyMatch.score("lien docs", in: "le lien vers la doc"), "chaque mot compte")
        XCTAssertEqual(FuzzyMatch.score("", in: "n'importe quoi"), 0, "saisie vide : tout passe")
        XCTAssertNil(FuzzyMatch.score("zzz", in: "Autonomie"))
    }

    func testFuzzyRanksPrefixThenWordStartThenInside() throws {
        let prefix = try XCTUnwrap(FuzzyMatch.score("aut", in: "Autonomie"))
        let wordStart = try XCTUnwrap(FuzzyMatch.score("aut", in: "Mode autonomie"))
        let inside = try XCTUnwrap(FuzzyMatch.score("aut", in: "Défaut"))
        XCTAssertGreaterThan(prefix, wordStart)
        XCTAssertGreaterThan(wordStart, inside)
        let subsequence = try XCTUnwrap(FuzzyMatch.score("prsnt", in: "Présentation"))
        XCTAssertLessThan(subsequence, inside, "des lettres éparses valent moins qu'une inclusion")
    }

    func testFuzzySubsequenceOnlyInShortTextsAndNotForOneLetter() {
        XCTAssertNotNil(FuzzyMatch.score("prsnt", in: "Présentation"))
        XCTAssertNil(FuzzyMatch.score("q", in: "Présentation"), "une lettre seule : inclusion uniquement")
        let long = String(repeating: "lorem ipsum dolor ", count: 6)
        XCTAssertGreaterThan(long.count, FuzzyMatch.maxSubsequenceLength)
        XCTAssertNil(FuzzyMatch.score("lpd", in: long), "dans un long texte, seule l'inclusion compte")
        XCTAssertNotNil(FuzzyMatch.score("ipsum", in: long))
        XCTAssertNil(FuzzyMatch.score("ptn", in: "Présentation"), "lettres trop éloignées")
    }

    // MARK: - Modèle, sur des modules espions

    private final class Spy: NotchModule {
        let id: String
        let symbol = "star"
        var title: String { id }
        let verb: CommandVerb?
        /// Produit les commandes d'une saisie.
        var produce: (CommandQuery) -> [NotchCommand] = { _ in [] }
        private(set) var queries: [CommandQuery] = []
        private(set) var starts = 0
        private(set) var runs = 0

        init(_ id: String, key: String? = nil) {
            self.id = id
            verb = key.map { CommandVerb(key: $0, title: id) }
        }

        var commandVerb: CommandVerb? { verb }
        func commands(for query: CommandQuery) -> [NotchCommand] {
            queries.append(query)
            return produce(query)
        }
        func start() { starts += 1 }
        func makeView() -> AnyView { AnyView(EmptyView()) }

        func command(_ id: String, score: Int = 0, failing: String? = nil, enabled: Bool = true) -> NotchCommand {
            NotchCommand(id: id, symbol: "star", title: id, detail: "", score: score, isEnabled: enabled,
                         run: { [unowned self] in
                             runs += 1
                             return failing
                         })
        }
    }

    private func model(_ spies: [Spy]) -> CommandBarModel {
        CommandBarModel(modules: { spies })
    }

    func testNothingRunsBeforeReturn() {
        let spy = Spy("timer", key: "t")
        spy.produce = { [unowned spy] _ in [spy.command("a"), spy.command("b")] }
        let bar = model([spy])
        var finished = 0
        bar.onFinish = { finished += 1 }

        bar.text = "t 25"
        bar.move(1)
        bar.pick(CommandVerb(key: "t", title: "timer"))
        XCTAssertEqual(spy.runs, 0, "chercher, parcourir et choisir ne lancent rien")
        XCTAssertEqual(finished, 0)

        bar.runSelected()
        XCTAssertEqual(spy.runs, 1)
        XCTAssertEqual(finished, 1)
    }

    func testVerbIsRecognizedAndRoutedOnlyToItsModule() {
        let timer = Spy("timer", key: "t"), notes = Spy("notes", key: "n")
        timer.produce = { [unowned timer] _ in [timer.command("t.25")] }
        let bar = model([timer, notes])

        bar.text = "t 25"
        XCTAssertEqual(bar.verb?.key, "t")
        XCTAssertEqual(bar.text, "25", "le verbe quitte le champ")
        XCTAssertEqual(timer.queries.last, CommandQuery(verb: "t", argument: "25"))
        XCTAssertTrue(notes.queries.isEmpty, "le verbe d'un autre module n'interroge pas celui-ci")
        XCTAssertEqual(bar.results.map(\.id), ["t.25"])
    }

    func testFreeTextIsAskedToEveryModuleAndEmptyInputToNone() {
        let timer = Spy("timer", key: "t"), notes = Spy("notes", key: "n")
        let bar = model([timer, notes])
        bar.text = "25 min"
        XCTAssertNil(bar.verb)
        XCTAssertEqual(timer.queries.last, CommandQuery(verb: nil, argument: "25 min"))
        XCTAssertEqual(notes.queries.last, CommandQuery(verb: nil, argument: "25 min"))

        let asked = timer.queries.count
        bar.text = "   "
        XCTAssertEqual(timer.queries.count, asked, "champ vide sans verbe : personne n'est interrogé")
        XCTAssertTrue(bar.results.isEmpty)
    }

    func testRankingByScoreThenTabOrderAndCap() {
        let first = Spy("a", key: "a"), second = Spy("b", key: "b")
        first.produce = { [unowned first] _ in [first.command("a.low", score: 10), first.command("a.mid", score: 50)] }
        second.produce = { [unowned second] _ in
            [second.command("b.high", score: 90), second.command("b.mid", score: 50)]
                + (0..<10).map { second.command("b.extra\($0)", score: 1) }
        }
        let bar = model([first, second])
        bar.text = "x"
        XCTAssertEqual(bar.results.map(\.id), ["b.high", "a.mid", "b.mid", "a.low", "b.extra0"],
                       "score décroissant, puis ordre des onglets, plafonné à \(CommandBarModel.maxResults)")
        XCTAssertEqual(bar.selection, 0)
        bar.move(-1)
        XCTAssertEqual(bar.selection, 4, "la sélection boucle")
        bar.text = "xy"
        XCTAssertEqual(bar.selection, 0, "la saisie remet la sélection en tête")
    }

    func testBackspaceOnEmptyFieldBringsTheVerbBackAndChipsToggle() {
        let timer = Spy("timer", key: "t"), claude = Spy("claude", key: ">")
        let bar = model([timer, claude])
        bar.text = "t "
        XCTAssertEqual(bar.verb?.key, "t")
        bar.backspaceOnEmptyField()
        XCTAssertNil(bar.verb)
        XCTAssertEqual(bar.text, "t", "la lettre revient, sans redevenir un verbe")
        XCTAssertNil(bar.verb)

        bar.text = ">"
        XCTAssertEqual(bar.verb?.key, ">", "un symbole est un verbe tout de suite")
        bar.backspaceOnEmptyField()
        XCTAssertNil(bar.verb)
        XCTAssertEqual(bar.text, "")

        let chip = bar.verbs[0]
        bar.pick(chip)
        XCTAssertEqual(bar.verb, chip)
        bar.pick(chip)
        XCTAssertNil(bar.verb)
    }

    func testFailureKeepsTheBarOpenAndDisabledRowsDoNothing() {
        let spy = Spy("claude", key: ">")
        spy.produce = { [unowned spy] _ in [spy.command("a", score: 2, failing: "File pleine"), spy.command("b", enabled: false)] }
        let bar = model([spy])
        var finished = 0
        bar.onFinish = { finished += 1 }
        bar.text = "> salut"
        bar.runSelected()
        XCTAssertEqual(bar.failure, "File pleine")
        XCTAssertEqual(finished, 0, "l'échec laisse la barre ouverte")
        bar.move(1)
        XCTAssertNil(bar.failure, "effacé au geste suivant")

        bar.runSelected()
        XCTAssertEqual(spy.runs, 1, "une ligne grisée ne lance rien")
        XCTAssertEqual(finished, 0)
    }

    func testStoppedOrDisabledModulesAreNeverWokenBySearching() {
        let timer = Spy("timer", key: "t"), notes = Spy("notes", key: "n")
        let registry = ModuleRegistry(modules: [timer, notes], prefs: Preferences(defaults: makeEphemeralDefaults(self)))
        let bar = CommandBarModel(modules: { registry.commandModules })

        bar.text = "25"
        XCTAssertTrue(timer.queries.isEmpty, "panneau replié : aucun module ne tourne, personne n'est interrogé")
        XCTAssertEqual(timer.starts + notes.starts, 0, "la recherche ne démarre rien")

        registry.setPanelOpen(true)
        XCTAssertEqual(registry.commandModules.map(\.id), ["timer", "notes"])
        bar.text = "26"
        XCTAssertEqual(timer.queries.last?.argument, "26")

        registry.setEnabled("notes", false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(registry.commandModules.map(\.id), ["timer"], "onglet masqué : module écarté")
        let before = notes.queries.count
        bar.text = "27"
        XCTAssertEqual(notes.queries.count, before)
        XCTAssertEqual(notes.starts, 1, "jamais redémarré par la recherche")
    }

    /// Tous les verbes de l'application sont distincts, et aucun n'est une touche déjà prise par le champ.
    func testStandardModulesHaveDistinctVerbs() {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.replyFromNotch = true
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("oriel-no-config")
        let claude = ClaudeModule(store: SessionStore(), monitor: ClaudeMonitor(),
                                  tools: ToolsFeed(paths: LayoutTests.absentPaths), prefs: prefs,
                                  hooks: HookSetup(installer: HookInstaller(configDirectory: config, bundledHook: nil)),
                                  replies: ReplyCenter(prefs: prefs))
        let verbs = ModuleRegistry.standardModules(claude: claude).compactMap { $0.commandVerb }
        XCTAssertEqual(Set(verbs.map(\.key)), ["t", "n", "c", "s", ">", "m", "a"])
        XCTAssertEqual(verbs.count, 7)
        XCTAssertEqual(Set(verbs.map(\.key)).count, verbs.count)
        XCTAssertFalse(verbs.map(\.key).contains("i"), "« i » est celui des intercalaires des scripts")
    }

    // MARK: - Raccourci et état

    /// Une combinaison ne sert qu'à une action ; le choix est gardé et remis à zéro avec les réglages de la notch.
    func testCommandHotKeyIsExclusiveAndPersists() {
        let defaults = makeEphemeralDefaults(self)
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.commandHotKey, .none, "aucun raccourci par défaut")

        prefs.toggleHotKey = .controlOptionSpace
        prefs.hideHotKey = .optionCommandJ
        prefs.commandHotKey = .controlOptionSpace
        XCTAssertEqual(prefs.toggleHotKey, .none, "la combinaison passe à la barre")
        XCTAssertEqual(prefs.hideHotKey, .optionCommandJ)

        prefs.toggleHotKey = .optionCommandK
        prefs.commandHotKey = .optionCommandK
        XCTAssertEqual(prefs.toggleHotKey, .none)
        prefs.hideHotKey = .optionCommandK
        XCTAssertEqual(prefs.commandHotKey, .none, "et elle repart quand une autre action la reprend")

        prefs.commandHotKey = .optionCommandK
        prefs.hideHotKey = .none
        XCTAssertEqual(Preferences(defaults: defaults).commandHotKey, .optionCommandK, "relu au lancement")
        prefs.resetNotchSettings()
        XCTAssertEqual(prefs.commandHotKey, .none)
        XCTAssertNotNil(HotKeyChoice.optionCommandK.carbon)
    }

    /// La barre ne survit pas au panneau : repliée, elle est fermée (le panneau rouvre sur ses onglets).
    func testBarClosesWithThePanel() {
        let model = NotchViewModel()
        model.isExpanded = true
        model.isCommandBarOpen = true
        model.isExpanded = false
        XCTAssertFalse(model.isCommandBarOpen)
    }

    // MARK: - Minuteur

    func testTimerCommandsStartOnlyOnRun() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()

        let commands = module.commands(for: CommandQuery(verb: "t", argument: "25"))
        XCTAssertEqual(commands.map(\.id), ["timer.start.25"])
        XCTAssertEqual(module.state.status, .idle, "proposer ne démarre rien")

        XCTAssertNil(commands[0].run())
        XCTAssertEqual(module.state.status, .running)
        XCTAssertEqual(module.state.duration, 25 * 60)
    }

    func testTimerSuggestionsByInput() throws {
        let module = try TimerRig(self).startedModule()
        func ids(_ verb: String?, _ argument: String) -> [String] {
            module.commands(for: CommandQuery(verb: verb, argument: argument)).map(\.id)
        }
        XCTAssertEqual(ids("t", ""), ["timer.start.25", "timer.start.5", "timer.start.10", "timer.pomodoro"])
        XCTAssertEqual(ids("t", "1h30"), ["timer.start.90"])
        XCTAssertEqual(ids("t", "pomo"), ["timer.pomodoro"])
        XCTAssertEqual(ids("t", "zzz"), [])
        XCTAssertEqual(ids(nil, "25 min"), ["timer.start.25"], "sans verbe : une durée avec son unité")
        XCTAssertEqual(ids(nil, "25"), [], "sans verbe, un nombre seul n'est pas un minuteur")
        XCTAssertEqual(ids(nil, "pomodoro"), [], "sans verbe, pas de Pomodoro")
    }

    func testTimerReplacesARunningTimerAndStartsPomodoro() throws {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        module.startSimple(minutes: 10)
        XCTAssertEqual(module.state.status, .running)

        let command = try XCTUnwrap(module.commands(for: CommandQuery(verb: "t", argument: "5")).first)
        XCTAssertTrue(command.title.contains("Remplacer"), command.title)
        XCTAssertEqual(module.state.duration, 10 * 60, "rien n'a changé avant ⏎")
        _ = command.run()
        XCTAssertEqual(module.state.duration, 5 * 60)
        XCTAssertEqual(module.state.status, .running)

        let pomodoro = try XCTUnwrap(module.commands(for: CommandQuery(verb: "t", argument: "pomodoro")).first)
        _ = pomodoro.run()
        XCTAssertEqual(module.state.mode, .pomodoro)
        XCTAssertEqual(module.state.status, .running)
    }

    // MARK: - Notes

    func testNotesCommandCreatesANoteOnlyOnRun() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let before = module.notes.count

        let command = try XCTUnwrap(module.commands(for: CommandQuery(verb: "n", argument: "idée de la barre")).first)
        XCTAssertTrue(command.isEnabled)
        XCTAssertEqual(module.notes.count, before)
        XCTAssertNil(command.run())

        XCTAssertEqual(module.notes.filter { !$0.text.isEmpty }.map(\.text), ["idée de la barre"])
        XCTAssertEqual(module.selectedNote?.text, "idée de la barre")
        XCTAssertEqual(module.notes.filter { $0.text.isEmpty }.count, 0, "la note vide qui attendait disparaît")
    }

    func testNotesCommandNeedsTextAndRespectsTheLimit() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let empty = try XCTUnwrap(module.commands(for: CommandQuery(verb: "n", argument: "")).first)
        XCTAssertFalse(empty.isEnabled)
        XCTAssertEqual(module.commands(for: CommandQuery(verb: nil, argument: "idée")).count, 0, "pas de verbe : rien")

        for index in 0..<NotesModule.maxNotes { rig.write(module, "note \(index)", after: 1) }
        XCTAssertEqual(module.notes.count, NotesModule.maxNotes)
        let full = try XCTUnwrap(module.commands(for: CommandQuery(verb: "n", argument: "encore")).first)
        XCTAssertFalse(full.isEnabled, "plafond de notes atteint")
        XCTAssertFalse(module.addNote("encore"))
        XCTAssertEqual(module.notes.count, NotesModule.maxNotes)
    }

    // MARK: - Presse-papiers

    func testClipboardCommandsSearchHistoryAndRecopyOnRun() throws {
        let rig = try makeClipboardRig()
        rig.copy("https://github.com/exemple/projet")
        rig.copy("recette de crêpes")
        rig.copy("le lien vers la doc")
        rig.copy("secret-mot-de-passe", types: ["org.nspasteboard.concealedtype"])

        func titles(_ argument: String, verb: String? = "c") -> [String] {
            rig.module.commands(for: CommandQuery(verb: verb, argument: argument)).map(\.title)
        }
        XCTAssertEqual(titles(""), ["le lien vers la doc", "recette de crêpes", "https://github.com/exemple/projet"],
                       "du plus récent au plus ancien, sans l'élément confidentiel")
        XCTAssertEqual(titles("lien"), ["le lien vers la doc"])
        XCTAssertEqual(titles("CREPES"), ["recette de crêpes"], "casse et accents ignorés")
        XCTAssertEqual(titles("secret"), [])
        XCTAssertEqual(titles("lien", verb: nil), [], "sans verbe, le presse-papiers n'apparaît pas dans les résultats")

        let command = try XCTUnwrap(rig.module.commands(for: CommandQuery(verb: "c", argument: "crêpes")).first)
        XCTAssertTrue(rig.pasteboard.written.isEmpty, "rien n'est écrit avant ⏎")
        XCTAssertNil(command.run())
        guard case .text(let copied)? = rig.pasteboard.written.last?.content else { return XCTFail("rien recopié") }
        XCTAssertEqual(copied, "recette de crêpes")
    }

    // MARK: - Réglages rapides

    func testQuickSettingsScenesByNameAndApplyOnRun() throws {
        let f = QuickSettingsFixture(self)
        let module = f.startAndShow()
        func ids(_ verb: String?, _ argument: String) -> [String] {
            module.commands(for: CommandQuery(verb: verb, argument: argument)).map(\.id)
        }
        XCTAssertEqual(ids("s", ""), ["quicksettings.scene.autonomy", "quicksettings.scene.presentation"],
                       "« Normal » n'a rien à restaurer au départ")
        XCTAssertEqual(ids("s", "prés"), ["quicksettings.scene.presentation"])
        XCTAssertEqual(ids("s", "prsnt"), ["quicksettings.scene.presentation"], "recherche floue")
        XCTAssertEqual(ids(nil, "pr"), [], "sans verbe, trois lettres au moins")
        XCTAssertEqual(ids(nil, "prés"), ["quicksettings.scene.presentation"])

        let command = try XCTUnwrap(module.commands(for: CommandQuery(verb: "s", argument: "autonomie")).first)
        XCTAssertTrue(f.power.setCalls.isEmpty, "rien n'est changé avant ⏎")
        XCTAssertNil(command.run())
        QuickSettingsFixture.settle()
        XCTAssertTrue(module.isSceneActive(.autonomy))
        XCTAssertEqual(ids("s", "norm"), ["quicksettings.scene.normal"], "Normal apparaît une fois une scène appliquée")
    }

    /// Vitesse fixe active : « s ventil » la rend à macOS, seulement à ⏎ ; sans vitesse fixe, rien à proposer.
    func testQuickSettingsGivesTheFansBackToMacOSOnlyOnRun() throws {
        let f = QuickSettingsFixture(self)
        let module = f.startAndShow()
        let query = CommandQuery(verb: "s", argument: "ventil")
        XCTAssertTrue(module.commands(for: query).isEmpty)
        module.fans.setFixed(rpm: 4000)
        XCTAssertTrue(module.fans.isFixed)
        let command = try XCTUnwrap(module.commands(for: query).first)
        XCTAssertEqual(command.id, "quicksettings.fans.automatic")
        XCTAssertTrue(module.fans.isFixed, "rien n'est changé avant ⏎")
        XCTAssertNil(command.run())
        XCTAssertEqual(f.fans.sent.last, "auto")
        XCTAssertFalse(module.fans.isFixed)
    }

    // MARK: - Claude

    private struct ClaudeRig {
        let prefs: Preferences
        let replies: ReplyCenter
        let store = SessionStore()
        let module: ClaudeModule

        init(_ test: XCTestCase, replyFromNotch: Bool = true) {
            prefs = Preferences(defaults: makeEphemeralDefaults(test))
            prefs.replyFromNotch = replyFromNotch
            replies = ReplyCenter(prefs: prefs)
            let config = FileManager.default.temporaryDirectory.appendingPathComponent("oriel-no-config")
            module = ClaudeModule(store: store, monitor: ClaudeMonitor(), tools: ToolsFeed(paths: LayoutTests.absentPaths),
                                  prefs: prefs, hooks: HookSetup(installer: HookInstaller(configDirectory: config,
                                                                                         bundledHook: nil)),
                                  replies: replies)
        }

        func session(_ id: String) {
            store.send("UserPromptSubmit", id, ["prompt": "Lance les tests"])
        }
    }

    func testClaudeVerbExistsOnlyWhenRepliesAreOn() {
        XCTAssertEqual(ClaudeRig(self, replyFromNotch: true).module.commandVerb?.key, ">")
        let off = ClaudeRig(self, replyFromNotch: false)
        XCTAssertNil(off.module.commandVerb, "réponses coupées : pas de verbe, pas de pastille")
        XCTAssertEqual(off.module.commands(for: CommandQuery(verb: ">", argument: "salut")).count, 0)
    }

    func testClaudeSendsOnlyOnRunAndOnlyToSessionsThatCanReceive() throws {
        let rig = ClaudeRig(self)
        rig.session("mon-app")
        rig.session("api")
        rig.session("ferme")
        rig.store.send("SessionEnd", "ferme")
        rig.session("sans-terminal")
        // `claude -p` : pas de terminal, on ne peut pas lui écrire.
        rig.replies.processArguments = { _ in ["claude", "-p", "Bonjour"] }
        rig.replies.wait(sessionId: "sans-terminal", pid: getpid()) { _ in }
        XCTAssertTrue(rig.replies.headless.contains("sans-terminal"))

        let commands = rig.module.commands(for: CommandQuery(verb: ">", argument: "relance les tests"))
        let send = commands.filter { $0.id.hasPrefix("claude.send.") }
        XCTAssertEqual(Set(send.map(\.id)), ["claude.send.mon-app", "claude.send.api"],
                       "ni la session terminée ni celle sans terminal")
        XCTAssertTrue(commands.contains { $0.id == "claude.open.api" })
        XCTAssertTrue(rig.replies.queued.isEmpty, "rien n'est parti avant ⏎")

        let target = try XCTUnwrap(send.first { $0.id == "claude.send.api" })
        XCTAssertNil(target.run())
        XCTAssertEqual(rig.replies.queued["api"], ["relance les tests"])
        XCTAssertNil(rig.replies.queued["mon-app"])
    }

    func testClaudeNeedsAMessageAndExplainsWhenNoSessionIsOpen() throws {
        let rig = ClaudeRig(self)
        let none = rig.module.commands(for: CommandQuery(verb: ">", argument: "salut"))
        XCTAssertEqual(none.map(\.id), ["claude.none"])
        XCTAssertFalse(none[0].isEnabled)

        rig.session("mon-app")
        let empty = rig.module.commands(for: CommandQuery(verb: ">", argument: ""))
        XCTAssertFalse(try XCTUnwrap(empty.first { $0.id == "claude.send.mon-app" }).isEnabled, "pas de message : grisé")
        XCTAssertTrue(try XCTUnwrap(empty.first { $0.id == "claude.open.mon-app" }).isEnabled)
        XCTAssertEqual(rig.module.commands(for: CommandQuery(verb: nil, argument: "salut")).count, 0)
    }

    func testClaudeReportsAMessageThatCouldNotBeSent() throws {
        let rig = ClaudeRig(self)
        rig.session("mon-app")
        let command = try XCTUnwrap(rig.module.commands(for: CommandQuery(verb: ">", argument: "salut"))
            .first { $0.id == "claude.send.mon-app" })
        for index in 0..<ReplyCenter.maxQueuedPerSession { rig.replies.send("message \(index)", to: "mon-app") }
        XCTAssertNotNil(command.run(), "file pleine : l'échec est dit, la barre reste ouverte")
        XCTAssertEqual(rig.replies.queued["mon-app"]?.count, ReplyCenter.maxQueuedPerSession)
    }
}
