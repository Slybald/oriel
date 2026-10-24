import XCTest
@testable import Oriel

/// Autorisation « sans mot de passe » de l'économie d'énergie (règle sudoers) : contenu de la règle, commandes,
/// choix entre `sudo -n` et la fenêtre d'autorisation, installation, retrait, états de l'interface.
/// Aucun test n'exécute sudo, AppleScript ou une commande privilégiée, ni n'écrit dans /etc : les accès sont des
/// doubles. Seuls tournent pour de vrai, sans droits root, /bin/sh, mktemp, printf et `visudo -c` (lecture) sur
/// la commande d'installation, dont `install` est remplacé par une copie dans un dossier d'essai.
final class QuickSettingsAuthorizationTests: XCTestCase {
    // MARK: - Doubles et outils

    private static func ok(_ stdout: String = "") -> SystemProcess.Output {
        SystemProcess.Output(status: 0, stdout: Data(stdout.utf8), stderr: Data(), timedOut: false)
    }

    private static func fail(_ stderr: String, status: Int32 = 1) -> SystemProcess.Output {
        SystemProcess.Output(status: status, stdout: Data(), stderr: Data(stderr.utf8), timedOut: false)
    }

    /// Remplace `SystemProcess.run` : note les appels, répond selon le programme. Appelé hors du fil principal.
    private final class ScriptedRunner {
        struct Call: Equatable {
            var path: String
            var arguments: [String]
        }

        var sudoReply: SystemProcess.Output? = QuickSettingsAuthorizationTests.ok()
        var osascriptReply: SystemProcess.Output? = QuickSettingsAuthorizationTests.ok()
        private let lock = NSLock()
        private var recorded: [Call] = []

        var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
        var sudoCalls: [Call] { calls.filter { $0.path == LowPowerAuthorization.sudoPath } }
        var scripts: [String] { calls.filter { $0.path == "/usr/bin/osascript" }.map { $0.arguments[1] } }

        lazy var run: SystemProcess.Runner = { [self] path, arguments, _ in
            lock.lock(); recorded.append(Call(path: path, arguments: arguments)); lock.unlock()
            switch path {
            case LowPowerAuthorization.sudoPath:
                return sudoReply
            case "/usr/bin/osascript":
                return osascriptReply
            default:
                return QuickSettingsAuthorizationTests.fail("programme inattendu : \(path)")
            }
        }
    }

    /// `autoAuthorize` faux : l'utilisateur a retiré la règle, le mot de passe est demandé à chaque bascule.
    private func power(_ runner: ScriptedRunner, ruleInstalled: Bool = false, user: String = "alice",
                       autoAuthorize: Bool = false) -> SystemPowerMode {
        let defaults = makeEphemeralDefaults(self)
        defaults.set(autoAuthorize, forKey: LowPowerAuthorization.autoAuthorizeKey)
        return SystemPowerMode(run: runner.run, ruleExists: { ruleInstalled }, userName: { user }, defaults: defaults)
    }

    private func write(_ mode: SystemPowerMode, _ on: Bool) throws -> Result<LowPowerWrite, QuickSettingsFailure> {
        let done = expectation(description: "setLowPower")
        var outcome: Result<LowPowerWrite, QuickSettingsFailure>?
        mode.setLowPower(on) {
            XCTAssertTrue(Thread.isMainThread)
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(outcome)
    }

    private func authorize(_ mode: SystemPowerMode) throws -> Result<Void, QuickSettingsFailure> {
        let done = expectation(description: "authorize")
        var outcome: Result<Void, QuickSettingsFailure>?
        mode.authorize {
            XCTAssertTrue(Thread.isMainThread)
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(outcome)
    }

    private func revoke(_ mode: SystemPowerMode) throws -> Result<Void, QuickSettingsFailure> {
        let done = expectation(description: "revoke")
        var outcome: Result<Void, QuickSettingsFailure>?
        mode.revokeAuthorization {
            XCTAssertTrue(Thread.isMainThread)
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(outcome)
    }

    /// Relit un littéral AppleScript comme AppleScript le lit (`\\`, `\"`, `\n`, `\r`, `\t`) ; nil si le script n'a
    /// pas la forme attendue ou si un guillemet y est resté sans protection.
    private func shellCommand(inScript script: String) -> String? {
        let prefix = "do shell script \""
        let suffix = "\" with administrator privileges"
        guard script.hasPrefix(prefix), script.hasSuffix(suffix) else { return nil }
        var literal = script.dropFirst(prefix.count).dropLast(suffix.count)
        // Texte de la fenêtre d'autorisation : `" with prompt "…` après la commande (un guillemet non protégé).
        if let prompt = literal.range(of: "\" with prompt \"", options: .backwards),
           literal[..<prompt.lowerBound].last != "\\" {
            literal = literal[..<prompt.lowerBound]
        }
        var result = ""
        var escaping = false
        for character in literal {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\", "\"": result.append(character)
                default: return nil
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" {
                return nil
            } else {
                result.append(character)
            }
        }
        return escaping ? nil : result
    }

    private func failure(of result: Result<Void, QuickSettingsFailure>) -> QuickSettingsFailure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    /// La commande réelle crée ses fichiers de travail dans /tmp/oriel.XXXXXX, partagé entre tests en parallèle :
    /// ici le modèle pointe vers un dossier propre au test, et `workFiles()` ne compte que ce qui s'y trouve.
    private var work: URL!

    override func setUpWithError() throws { work = try makeTemporaryDirectory(self) }

    private func shell(_ command: String) throws -> SystemProcess.Output {
        let isolated = command.replacingOccurrences(of: LowPowerAuthorization.workFileTemplate,
                                                    with: work.appendingPathComponent("oriel.XXXXXX").path)
        return try XCTUnwrap(SystemProcess.run("/bin/sh", ["-c", isolated], timeout: 10))
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// Les fichiers de travail restés dans le dossier du test (une commande qui ne nettoie pas en laisserait un).
    private func workFiles() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).filter { $0.hasPrefix("oriel.") })
    }

    /// Un dossier d'essai au nom hostile (espace, apostrophe, accent), supprimé en fin de test.
    private func scratchDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Dossier d'essai é \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Exécute pour de vrai, sans droits root, la commande d'installation de `contents` (mktemp, printf, visudo -c,
    /// rm), mais avec l'étape `install` remplacée par `install` (et, au besoin, l'étape visudo par `visudo`) : rien
    /// n'est installé, rien n'est écrit dans /etc. Vérifie d'abord que la commande ainsi modifiée n'en contient plus.
    private func dryRun(_ contents: String, install: String, visudo: String? = nil) throws -> SystemProcess.Output {
        let real = LowPowerAuthorization.installShellCommand(ruleContents: contents)
        let installStep = "\(LowPowerAuthorization.installPath) -m 0440 -o root -g wheel \"$T\" \(LowPowerAuthorization.rulePath)"
        let visudoStep = "\(LowPowerAuthorization.visudoPath) -cf \"$T\""
        XCTAssertTrue(real.contains(installStep))
        XCTAssertTrue(real.contains(visudoStep))
        XCTAssertTrue(real.contains(LowPowerAuthorization.workFileTemplate), "le fichier de travail est redirigé vers le dossier du test")
        var dry = real.replacingOccurrences(of: installStep, with: install)
        if let visudo { dry = dry.replacingOccurrences(of: visudoStep, with: visudo) }
        XCTAssertFalse(dry.contains(LowPowerAuthorization.installPath), "l'installation réelle est retirée")
        XCTAssertEqual(dry.components(separatedBy: LowPowerAuthorization.rulePath).count,
                       contents.components(separatedBy: LowPowerAuthorization.rulePath).count,
                       "le chemin de la règle ne reste que dans le texte du commentaire")
        XCTAssertEqual(dry.components(separatedBy: ">").count, 2, "une seule redirection : vers le fichier de root")
        return try shell(dry)
    }

    // MARK: - Règle sudoers

    func testRuleContentsAreExact() {
        XCTAssertEqual(LowPowerAuthorization.ruleContents(forUser: "jean.dupont"), """
            # Oriel : active ou coupe l'economie d'energie sans demander le mot de passe.
            # Pour retirer cette autorisation : sudo rm /etc/sudoers.d/oriel-lowpower
            jean.dupont ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1

            """)
    }

    /// Une seule règle, deux commandes complètes, ni joker ni autre commande.
    func testRuleAllowsExactlyTwoPmsetCommands() throws {
        let rule = try XCTUnwrap(LowPowerAuthorization.ruleContents(forUser: "alice"))
        XCTAssertTrue(rule.hasSuffix("\n"))
        XCTAssertTrue(rule.allSatisfy(\.isASCII), "lu par root : pas de caractère exotique")
        let rules = rule.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertEqual(rules.count, 1)
        let parts = rules[0].components(separatedBy: " NOPASSWD: ")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], "alice ALL=(root)")
        XCTAssertEqual(parts[1].components(separatedBy: ", "),
                       ["/usr/bin/pmset -a lowpowermode 0", "/usr/bin/pmset -a lowpowermode 1"])
        for forbidden in ["*", "ALL=(ALL", "SETENV", "!", "\\"] {
            XCTAssertFalse(rule.contains(forbidden), forbidden)
        }
    }

    /// sudo ignore les fichiers de sudoers.d dont le nom contient un point ou finit par `~`.
    func testRuleFileNameIsReadBySudo() {
        let url = URL(fileURLWithPath: LowPowerAuthorization.rulePath)
        XCTAssertEqual(url.deletingLastPathComponent().path, "/etc/sudoers.d")
        XCTAssertEqual(url.lastPathComponent, "oriel-lowpower")
        XCTAssertFalse(url.lastPathComponent.contains("."))
        XCTAssertFalse(url.lastPathComponent.hasSuffix("~"))
    }

    func testValidUsersAreAccepted() {
        for name in ["alice", "Jean.Dupont", "_www", "user-1", "a", "a_b-c.d", "0", String(repeating: "a", count: 64)] {
            XCTAssertTrue(LowPowerAuthorization.isValidUser(name), name)
            XCTAssertNotNil(LowPowerAuthorization.ruleContents(forUser: name), name)
        }
    }

    func testUnsafeUsersAreRefused() {
        let unsafe = [
            "", "-alice", "-", "ALL", "alice bob", "alice\nbob ALL=(ALL) NOPASSWD: ALL", "alice\n", "\nalice",
            "alice\r", "a\tb", "a#b", "#0", "%admin", "+netgroup", "!alice", "a,b", "a:b", "a=b", "a\\b", "a/b",
            "../x", "a'b", "a\"b", "a$b", "a;b", "a*b", "a(b)", "é", "alicé", "a\u{0}b",
            String(repeating: "a", count: 65),
        ]
        for name in unsafe {
            XCTAssertFalse(LowPowerAuthorization.isValidUser(name), name.debugDescription)
            XCTAssertNil(LowPowerAuthorization.ruleContents(forUser: name), name.debugDescription)
        }
    }

    /// Preuve avec le vrai `mktemp`, `printf` et `visudo -c` (sans droits root) : le fichier que la commande écrit
    /// elle-même est exactement `ruleContents(forUser:)`, visudo l'accepte, et il est supprimé ensuite. L'étape
    /// `install` est remplacée par une copie dans un dossier d'essai : rien n'est écrit dans /etc.
    func testFileWrittenByTheCommandIsExactlyTheRuleAndPassesRealVisudo() throws {
        guard FileManager.default.isExecutableFile(atPath: LowPowerAuthorization.visudoPath) else {
            throw XCTSkip("visudo absent")
        }
        let directory = try scratchDirectory()
        var users = ["alice", "jean.dupont", "_user-1"]
        if LowPowerAuthorization.isValidUser(NSUserName()) { users.append(NSUserName()) }
        for user in users {
            let contents = try XCTUnwrap(LowPowerAuthorization.ruleContents(forUser: user))
            let target = directory.appendingPathComponent("règle d'essai \(user)")
            let before = workFiles()
            let output = try dryRun(contents, install: "/bin/cp \"$T\" \(LowPowerAuthorization.shellQuote(target.path))")
            XCTAssertEqual(output.status, 0, "\(user) : \(text(output.stdout)) \(text(output.stderr))")
            XCTAssertTrue(text(output.stdout).contains("parsed OK"), "visudo -cf a accepté le fichier : \(text(output.stdout))")
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), contents, user)
            XCTAssertEqual(workFiles(), before, "le fichier de travail est supprimé")
        }
    }

    /// Même chaîne avec une règle abîmée : visudo la refuse (sinon le test précédent ne prouverait rien), `install`
    /// ne tourne pas, la commande rend un code d'échec, et le fichier de travail est quand même supprimé.
    func testInstallIsSkippedWhenVisudoRefusesTheRule() throws {
        guard FileManager.default.isExecutableFile(atPath: LowPowerAuthorization.visudoPath) else {
            throw XCTSkip("visudo absent")
        }
        let before = workFiles()
        let good = try dryRun(try XCTUnwrap(LowPowerAuthorization.ruleContents(forUser: "alice")),
                              install: "/usr/bin/printf INSTALLED")
        XCTAssertEqual(good.status, 0, text(good.stderr))
        XCTAssertTrue(text(good.stdout).hasSuffix("INSTALLED"), text(good.stdout))

        let refused = try dryRun("alice ALL=(root) NOPASSWD /usr/bin/pmset\n", install: "/usr/bin/printf INSTALLED")
        XCTAssertNotEqual(refused.status, 0, "le code de visudo est rendu")
        XCTAssertFalse(text(refused.stdout).contains("INSTALLED"), "install ne tourne pas si visudo refuse")
        XCTAssertEqual(workFiles(), before)
    }

    /// Le fichier que root vérifie est un fichier à lui : `mktemp` le crée en 0600 (un autre processus de
    /// l'utilisateur ne peut donc pas le réécrire entre `visudo -c` et `install`). Le propriétaire (root) ne se
    /// teste pas sans droits ; le mode, si.
    func testWorkFileIsCreatedPrivateByMktemp() throws {
        let output = try dryRun(try XCTUnwrap(LowPowerAuthorization.ruleContents(forUser: "alice")),
                                install: "/usr/bin/true", visudo: "/usr/bin/stat -f %Lp \"$T\"")
        XCTAssertEqual(text(output.stdout), "600\n")
        XCTAssertEqual(output.status, 0)
    }

    /// Chaque ligne passe par `shellQuote` puis `printf '%s\n'` : apostrophes, `$`, accent grave, guillemets,
    /// barres obliques inverses et `%` ressortent intacts, sans rien exécuter.
    func testRuleLinesSurviveTheShellAndPrintfUnchanged() throws {
        let contents = "it's $HOME `id` \"x\" \\ %s %d 100%\nsecond 'line' ; touch /nonexistent\n$(id)\n"
        let output = try dryRun(contents, install: "/usr/bin/true", visudo: "/bin/cat \"$T\"")
        XCTAssertEqual(text(output.stdout), contents)
        XCTAssertEqual(output.status, 0)
    }

    // MARK: - Commandes

    func testSudoRunsOneFixedCommandWithoutShell() {
        XCTAssertEqual(LowPowerAuthorization.sudoArguments(lowPower: true),
                       ["-n", "/usr/bin/pmset", "-a", "lowpowermode", "1"])
        XCTAssertEqual(LowPowerAuthorization.sudoArguments(lowPower: false),
                       ["-n", "/usr/bin/pmset", "-a", "lowpowermode", "0"])
    }

    func testShellQuoteSurvivesARealShell() throws {
        let texts = ["plain", "with space", "it's", "a'b'c", "'", "''", "$HOME", "`id`", "\"dq\"", "back\\slash",
                     "new\nline", "; touch /nonexistent", "Mon dossier d'essai/règle \"x\" \\ $y", "é"]
        for original in texts {
            let output = try shell("printf %s \(LowPowerAuthorization.shellQuote(original))")
            XCTAssertEqual(text(output.stdout), original, original.debugDescription)
        }
    }

    func testAppleScriptLiteralKeepsTheCommandIntact() throws {
        let commands = ["/usr/bin/pmset -a lowpowermode 1", "a \"b\" c", "back\\slash", "\\\"", "tab\tand\nnewline\r",
                        "'quoted' path/règle \\n"]
        for command in commands {
            let script = LowPowerAuthorization.administratorScript(running: command)
            XCTAssertEqual(shellCommand(inScript: script), command, script)
        }
        XCTAssertEqual(LowPowerAuthorization.administratorScript(running: "/usr/bin/pmset -a lowpowermode 1"),
                       "do shell script \"/usr/bin/pmset -a lowpowermode 1\" with administrator privileges",
                       "le script de bascule avec mot de passe reste celui d'avant")
    }

    /// La commande lancée en root, mot pour mot : root crée son fichier (mktemp), y écrit la règle, la valide, puis
    /// seulement l'installe, supprime son fichier et rend le code de visudo ou d'install. Aucun fichier de
    /// l'utilisateur n'y figure.
    func testInstallCommandIsTheExpectedChain() throws {
        let contents = try XCTUnwrap(LowPowerAuthorization.ruleContents(forUser: "alice"))
        let command = LowPowerAuthorization.installShellCommand(ruleContents: contents)
        let lines = contents.split(separator: "\n").map { LowPowerAuthorization.shellQuote(String($0)) }
            .joined(separator: " ")
        XCTAssertEqual(command, "T=$(/usr/bin/mktemp /tmp/oriel.XXXXXX) || exit 1; /usr/bin/printf '%s\\n' \(lines)"
            + " > \"$T\" && /usr/sbin/visudo -cf \"$T\" && /usr/bin/install -m 0440 -o root -g wheel \"$T\""
            + " /etc/sudoers.d/oriel-lowpower; R=$?; /bin/rm -f \"$T\"; exit $R")
        func position(_ text: String) throws -> String.Index { try XCTUnwrap(command.range(of: text)).lowerBound }
        XCTAssertTrue(try position("/usr/bin/mktemp") < position("/usr/bin/printf")
            && position("/usr/bin/printf") < position("/usr/sbin/visudo")
            && position("/usr/sbin/visudo") < position("/usr/bin/install"), "écrire, valider, puis installer")
        XCTAssertEqual(command.components(separatedBy: "/usr/bin/install").count, 2, "un seul install")
        XCTAssertFalse(command.contains(NSTemporaryDirectory()), "pas de fichier côté utilisateur")
        XCTAssertFalse(command.contains("/var/folders"))
    }

    // MARK: - Bascule : sudo -n, puis repli sur la fenêtre d'autorisation

    func testWithoutARuleTheSystemPromptIsUsedLikeBefore() throws {
        let runner = ScriptedRunner()
        let mode = power(runner)
        XCTAssertEqual(mode.authorization, .none)
        XCTAssertEqual(try write(mode, true), .success(.done))
        XCTAssertEqual(try write(mode, false), .success(.done))
        XCTAssertTrue(runner.sudoCalls.isEmpty, "sans règle, sudo n'est pas essayé")
        XCTAssertEqual(runner.scripts.map(shellCommand(inScript:)),
                       ["/usr/bin/pmset -a lowpowermode 1", "/usr/bin/pmset -a lowpowermode 0"])
    }

    func testWithTheRuleNoPromptIsShown() throws {
        let runner = ScriptedRunner()
        let mode = power(runner, ruleInstalled: true)
        XCTAssertEqual(mode.authorization, .granted)
        XCTAssertEqual(try write(mode, true), .success(.done))
        XCTAssertEqual(try write(mode, false), .success(.done))
        XCTAssertEqual(runner.calls, [
            .init(path: "/usr/bin/sudo", arguments: ["-n", "/usr/bin/pmset", "-a", "lowpowermode", "1"]),
            .init(path: "/usr/bin/sudo", arguments: ["-n", "/usr/bin/pmset", "-a", "lowpowermode", "0"]),
        ], "deux bascules, aucune fenêtre d'autorisation")
        XCTAssertEqual(mode.authorization, .granted)
    }

    func testRuleRefusedBySudoFallsBackToThePasswordThenStopsTrying() throws {
        let runner = ScriptedRunner()
        runner.sudoReply = Self.fail("sudo: a password is required")
        let mode = power(runner, ruleInstalled: true)

        XCTAssertEqual(try write(mode, true), .success(.authorizationRefused), "réussi, mais avec le mot de passe")
        XCTAssertEqual(runner.calls.map(\.path), ["/usr/bin/sudo", "/usr/bin/osascript"])
        XCTAssertEqual(runner.scripts.map(shellCommand(inScript:)), ["/usr/bin/pmset -a lowpowermode 1"])
        XCTAssertEqual(mode.authorization, .refused)

        XCTAssertEqual(try write(mode, false), .success(.done))
        XCTAssertEqual(runner.calls.map(\.path), ["/usr/bin/sudo", "/usr/bin/osascript", "/usr/bin/osascript"],
                       "sudo n'est plus essayé tant que la règle n'est pas redonnée")
    }

    func testReGrantingTheRuleMakesSudoUsableAgain() throws {
        let runner = ScriptedRunner()
        runner.sudoReply = Self.fail("sudo: a password is required")
        let mode = power(runner, ruleInstalled: true)
        _ = try write(mode, true)
        XCTAssertEqual(mode.authorization, .refused)

        runner.sudoReply = Self.ok()
        XCTAssertNoThrow(try authorize(mode).get())
        XCTAssertEqual(mode.authorization, .granted)
        let before = runner.sudoCalls.count
        XCTAssertEqual(try write(mode, false), .success(.done))
        XCTAssertEqual(runner.sudoCalls.count, before + 1)
    }

    func testSudoThatCannotStartFallsBackToo() throws {
        let runner = ScriptedRunner()
        runner.sudoReply = nil
        let mode = power(runner, ruleInstalled: true)
        XCTAssertEqual(try write(mode, true), .success(.authorizationRefused))
        XCTAssertEqual(mode.authorization, .refused)
    }

    /// La fenêtre d'autorisation fermée ne prouve rien contre la règle : on la garde, sans bruit.
    func testClosingThePromptAfterARefusedRuleKeepsTheRule() throws {
        let runner = ScriptedRunner()
        runner.sudoReply = Self.fail("sudo: a password is required")
        runner.osascriptReply = Self.fail("0:60: execution error: User canceled. (-128)")
        let mode = power(runner, ruleInstalled: true)
        XCTAssertEqual(try write(mode, true), .failure(QuickSettingsFailure(.cancelled)))
        XCTAssertEqual(mode.authorization, .granted)
    }

    func testWrongPasswordFailureIsPassedOn() throws {
        let runner = ScriptedRunner()
        runner.osascriptReply = Self.fail("execution error: The administrator user name or password was incorrect. (-60005)")
        let result = try write(power(runner), true)
        guard case .failure(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(failure.kind, .denied)
    }

    // MARK: - Installation

    /// Les fichiers que l'app laisserait dans le dossier temporaire de l'utilisateur : il ne doit y en avoir aucun.
    private func userTemporaryFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(names.filter { $0.hasPrefix("oriel.") })
    }

    func testInstallRunsOneAdministratorScriptAndLeavesNoUserFile() throws {
        let runner = ScriptedRunner()
        let before = userTemporaryFiles()
        XCTAssertNoThrow(try authorize(power(runner, user: "alice")).get())

        XCTAssertEqual(runner.calls.count, 1, "un seul mot de passe : un seul script")
        XCTAssertTrue(runner.sudoCalls.isEmpty)
        let script = try XCTUnwrap(runner.scripts.first)
        let command = try XCTUnwrap(shellCommand(inScript: script), script)
        XCTAssertEqual(command, LowPowerAuthorization.installShellCommand(
            ruleContents: try XCTUnwrap(LowPowerAuthorization.ruleContents(forUser: "alice"))))
        XCTAssertTrue(command.hasPrefix("T=$(/usr/bin/mktemp /tmp/oriel.XXXXXX) || exit 1; "),
                      "le fichier est créé par root")
        XCTAssertEqual(userTemporaryFiles(), before, "aucun fichier côté utilisateur")
    }

    func testInstallIsRefusedForAnUnsafeUserBeforeAnythingIsRun() throws {
        let runner = ScriptedRunner()
        let mode = power(runner, user: "alice\nmallory ALL=(ALL) NOPASSWD: ALL")
        XCTAssertEqual(failure(of: try authorize(mode)), QuickSettingsFailure(.invalidUser))
        XCTAssertTrue(runner.calls.isEmpty, "ni script ni mot de passe")
    }

    func testInstallFailuresAreClassified() throws {
        let cases: [(stderr: String, kind: QuickSettingsFailure.Kind)] = [
            ("0:60: execution error: User canceled. (-128)", .cancelled),
            ("execution error: The administrator user name or password was incorrect. (-60005)", .denied),
            ("/tmp/x:1:30: syntax error\nexecution error: boom (1)", .failed),
        ]
        for (stderr, kind) in cases {
            let runner = ScriptedRunner()
            runner.osascriptReply = Self.fail(stderr)
            let result = try authorize(power(runner))
            XCTAssertEqual(failure(of: result)?.kind, kind, stderr)
        }
    }

    // MARK: - Retrait

    func testRemovalRunsOneAdministratorCommandThatOnlyRemovesTheRule() throws {
        let runner = ScriptedRunner()
        let mode = power(runner, ruleInstalled: true)
        XCTAssertNoThrow(try revoke(mode).get())
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.scripts, [
            "do shell script \"/bin/rm -f /etc/sudoers.d/oriel-lowpower\" with administrator privileges",
        ])
    }

    func testRemovalFailureIsReported() throws {
        let runner = ScriptedRunner()
        runner.osascriptReply = Self.fail("0:60: execution error: User canceled. (-128)")
        let result = try revoke(power(runner, ruleInstalled: true))
        guard case .failure(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(failure.kind, .cancelled)
    }

    /// Pour la désinstallation de l'app : rien à retirer, rien n'est demandé.
    func testUninstallHookOnlyPromptsWhenTheRuleExists() {
        let fake = QSFakePower()
        var results: [Result<Void, QuickSettingsFailure>] = []
        LowPowerAuthorization.remove(power: fake, isInstalled: { false }) { results.append($0) }
        XCTAssertEqual(fake.revokeCalls, 0)
        XCTAssertEqual(results.count, 1)

        fake.authorization = .granted
        LowPowerAuthorization.remove(power: fake, isInstalled: { true }) { results.append($0) }
        XCTAssertEqual(fake.revokeCalls, 1)
        XCTAssertEqual(fake.authorization, .none)
        XCTAssertEqual(results.count, 2)
    }

    func testAuthorizationStateFollowsTheRuleFile() {
        var installed = false
        let defaults = makeEphemeralDefaults(self)
        let mode = SystemPowerMode(run: ScriptedRunner().run, ruleExists: { installed }, defaults: defaults)
        XCTAssertEqual(mode.authorization, .onFirstUse, "par défaut, le premier clic pose la règle")
        defaults.set(false, forKey: LowPowerAuthorization.autoAuthorizeKey)
        XCTAssertEqual(mode.authorization, .none, "règle retirée par l'utilisateur")
        installed = true
        XCTAssertEqual(mode.authorization, .granted)
    }

    // MARK: - Premier clic : bascule et pose de la règle dans la même fenêtre

    func testFirstToggleInstallsTheRuleInTheSamePrompt() throws {
        let runner = ScriptedRunner()
        let mode = power(runner, autoAuthorize: true)
        XCTAssertEqual(mode.authorization, .onFirstUse)
        XCTAssertEqual(try write(mode, true), .success(.done))
        XCTAssertTrue(runner.sudoCalls.isEmpty, "pas de règle : sudo n'est pas essayé")
        let rule = try XCTUnwrap(LowPowerAuthorization.ruleContents(forUser: "alice"))
        XCTAssertEqual(runner.scripts.map(shellCommand(inScript:)),
                       [LowPowerAuthorization.pmsetAndInstallShellCommand(lowPower: true, ruleContents: rule)],
                       "une seule fenêtre : bascule puis pose")
        XCTAssertTrue(try XCTUnwrap(runner.scripts.first).contains("ne sera plus demandé"), "la fenêtre le dit")
    }

    func testRefusedRuleIsPutBackInTheSamePromptAndSudoIsTriedAgain() throws {
        let runner = ScriptedRunner()
        runner.sudoReply = Self.fail("sudo: a password is required")
        let mode = power(runner, ruleInstalled: true, autoAuthorize: true)
        XCTAssertEqual(try write(mode, true), .success(.done))
        XCTAssertEqual(runner.calls.map(\.path), ["/usr/bin/sudo", "/usr/bin/osascript"])
        XCTAssertTrue(try XCTUnwrap(runner.scripts.first.flatMap(shellCommand(inScript:))).contains(LowPowerAuthorization.visudoPath))
        XCTAssertEqual(mode.authorization, .granted, "règle reposée : sudo sera réessayé")
        runner.sudoReply = Self.ok()
        XCTAssertEqual(try write(mode, false), .success(.done))
        XCTAssertEqual(runner.sudoCalls.count, 2)
    }

    func testRevokingStopsTheAutomaticInstall() throws {
        let runner = ScriptedRunner()
        let mode = power(runner, autoAuthorize: true)
        XCTAssertNoThrow(try revoke(mode).get())
        XCTAssertEqual(mode.authorization, .none)
        XCTAssertEqual(try write(mode, true), .success(.done))
        XCTAssertEqual(runner.scripts.dropFirst().map(shellCommand(inScript:)), ["/usr/bin/pmset -a lowpowermode 1"],
                       "après un retrait, plus de pose automatique")
    }

    /// Pour de vrai dans /bin/sh, sans root : `pmset` et `install` remplacés. Le code rendu est celui de la bascule,
    /// que la pose réussisse ou échoue, et le fichier de travail ne reste pas.
    func testToggleResultIsKeptWhateverTheInstallDoes() throws {
        let rule = try XCTUnwrap(LowPowerAuthorization.ruleContents(forUser: "alice"))
        let real = LowPowerAuthorization.pmsetAndInstallShellCommand(lowPower: true, ruleContents: rule)
        let pmset = LowPowerAuthorization.pmsetShellCommand(lowPower: true)
        let installStep = "\(LowPowerAuthorization.installPath) -m 0440 -o root -g wheel \"$T\" \(LowPowerAuthorization.rulePath)"
        XCTAssertTrue(real.hasPrefix(pmset))
        XCTAssertTrue(real.contains(LowPowerAuthorization.workFileTemplate), "le fichier de travail est redirigé vers le dossier du test")
        let before = workFiles()
        for (toggle, install, expected) in [("true", "true", Int32(0)), ("true", "false", 0), ("(exit 3)", "true", 3)] {
            let dry = real.replacingOccurrences(of: pmset, with: toggle).replacingOccurrences(of: installStep, with: install)
            XCTAssertFalse(dry.contains(LowPowerAuthorization.installPath))
            XCTAssertFalse(dry.contains(LowPowerAuthorization.pmsetPath + " -a lowpowermode 1;"))
            XCTAssertEqual(try shell(dry).status, expected, "bascule \(toggle), pose \(install)")
        }
        XCTAssertEqual(workFiles(), before)
    }

    func testUninstallScriptRemovesTheRule() throws {
        let script = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/uninstall.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains(LowPowerAuthorization.rulePath))
        XCTAssertTrue(script.contains("sudo /bin/rm -f \"$LOWPOWER_RULE\""), "retrait avec sudo")
        XCTAssertTrue(script.contains("if [ -e \"$LOWPOWER_RULE\" ]"), "seulement si le fichier existe")
    }

    // MARK: - États de l'interface

    func testInterfaceStates() {
        XCTAssertTrue(QuickSettingsView.asksPassword(.none))
        XCTAssertTrue(QuickSettingsView.asksPassword(.onFirstUse))
        XCTAssertTrue(QuickSettingsView.asksPassword(.refused))
        XCTAssertFalse(QuickSettingsView.asksPassword(.granted), "ni cadenas ni note de pied")

        typealias Action = QuickSettingsSettingsView.AuthorizationAction
        XCTAssertEqual(QuickSettingsSettingsView.authorizationActions(.none), [Action.grant])
        XCTAssertEqual(QuickSettingsSettingsView.authorizationActions(.onFirstUse), [Action.grant])
        XCTAssertEqual(QuickSettingsSettingsView.authorizationActions(.granted), [Action.revoke])
        XCTAssertEqual(QuickSettingsSettingsView.authorizationActions(.refused), [Action.regrant, Action.revoke])

        XCTAssertEqual(QuickSettingsSettingsView.authorizationState(.none), "Mot de passe demandé à chaque fois")
        XCTAssertEqual(QuickSettingsSettingsView.authorizationState(.granted), "Autorisé sans mot de passe")
        XCTAssertEqual(Action.grant.title, "Ne plus demander le mot de passe")
        XCTAssertEqual(Action.revoke.title, "Retirer l'autorisation")
        XCTAssertEqual(QuickSettingsSettingsView.authorizationNote,
                       "Ajoute une règle système limitée à l'activation et la désactivation de l'économie d'énergie.")
    }
}

/// Le module face à l'autorisation : état lu, pose, retrait, erreurs, règle refusée par sudo. Doubles seulement.
final class QuickSettingsAuthorizationModuleTests: XCTestCase {
    private func settle() { QuickSettingsFixture.settle() }

    func testAuthorizationIsReadAtStartAndWhenTheTabAppears() {
        let f = QuickSettingsFixture(self)
        f.power.authorization = .granted
        f.module.start()
        XCTAssertEqual(f.module.authorization, .granted)
        // La règle est retirée hors de l'app (script de désinstallation, retrait à la main).
        f.power.authorization = .none
        f.module.viewAppeared()
        XCTAssertEqual(f.module.authorization, .none)
        f.power.authorization = .granted
        f.module.refreshAuthorization()
        XCTAssertEqual(f.module.authorization, .granted)
    }

    func testGrantingPutsTheRuleInPlaceWithoutAnyError() {
        let f = QuickSettingsFixture(self)
        f.startAndShow()
        f.module.grantLowPowerAuthorization()
        XCTAssertEqual(f.power.authorizeCalls, 1)
        XCTAssertEqual(f.module.authorization, .granted)
        XCTAssertFalse(f.module.busy.contains(.authorization))
        XCTAssertNil(f.module.issue)
    }

    func testRevokingPutsThePasswordBack() {
        let f = QuickSettingsFixture(self)
        f.power.authorization = .granted
        f.startAndShow()
        f.module.revokeLowPowerAuthorization()
        XCTAssertEqual(f.power.revokeCalls, 1)
        XCTAssertEqual(f.module.authorization, .none)
        XCTAssertNil(f.module.issue)
    }

    func testClosingThePromptIsNotAnError() {
        let f = QuickSettingsFixture(self)
        f.power.authorizeFailure = QuickSettingsFailure(.cancelled)
        f.startAndShow()
        f.module.grantLowPowerAuthorization()
        XCTAssertEqual(f.module.authorization, .none)
        XCTAssertNil(f.module.issue)
        XCTAssertFalse(f.module.busy.contains(.authorization))
    }

    func testFailuresAreExplained() {
        let cases: [(QuickSettingsFailure, String)] = [
            (QuickSettingsFailure(.denied), "Autorisation : identifiants administrateur refusés."),
            (QuickSettingsFailure(.timeout), "Autorisation : pas de réponse à la demande d'autorisation."),
            (QuickSettingsFailure(.invalidUser), "Autorisation : nom d'utilisateur non pris en charge."),
            (QuickSettingsFailure(.failed, "boom (1)"), "Autorisation : boom (1)"),
            (QuickSettingsFailure(.failed), "Autorisation : installation impossible."),
        ]
        for (failure, message) in cases {
            let f = QuickSettingsFixture(self)
            f.power.authorizeFailure = failure
            f.startAndShow()
            f.module.grantLowPowerAuthorization()
            XCTAssertEqual(f.module.issue?.message, message)
            XCTAssertEqual(f.module.authorization, .none)
        }
        let f = QuickSettingsFixture(self)
        f.power.authorization = .granted
        f.power.revokeFailure = QuickSettingsFailure(.failed)
        f.startAndShow()
        f.module.revokeLowPowerAuthorization()
        XCTAssertEqual(f.module.issue?.message, "Autorisation : retrait impossible.")
        XCTAssertEqual(f.module.authorization, .granted, "la règle est toujours là")
    }

    func testOnlyOneAuthorizationPromptAtATime() {
        let f = QuickSettingsFixture(self)
        f.power.holdsCompletion = true
        f.startAndShow()
        f.module.grantLowPowerAuthorization()
        f.module.grantLowPowerAuthorization()
        f.module.revokeLowPowerAuthorization()
        XCTAssertEqual(f.power.authorizeCalls, 1)
        XCTAssertEqual(f.power.revokeCalls, 0)
        XCTAssertTrue(f.module.busy.contains(.authorization))
        // Pas non plus une bascule de l'économie d'énergie pendant la fenêtre de pose.
        f.module.toggleLowPower()
        XCTAssertTrue(f.power.setCalls.isEmpty)
        XCTAssertFalse(f.module.lowPower)
        f.power.release()
        XCTAssertFalse(f.module.busy.contains(.authorization))
        XCTAssertEqual(f.module.authorization, .granted)
    }

    func testGrantingIsRefusedWhileTheLowPowerPromptIsOpen() {
        let f = QuickSettingsFixture(self)
        f.power.holdsCompletion = true
        f.startAndShow()
        f.module.toggleLowPower()
        f.module.grantLowPowerAuthorization()
        XCTAssertEqual(f.power.authorizeCalls, 0)
        f.power.release()
    }

    func testTogglesWithTheRuleInPlaceStayQuiet() {
        let f = QuickSettingsFixture(self)
        f.power.authorization = .granted
        f.startAndShow()
        f.module.toggleLowPower()
        settle()
        f.module.toggleLowPower()
        settle()
        XCTAssertEqual(f.power.setCalls, [true, false])
        XCTAssertEqual(f.module.authorization, .granted)
        XCTAssertNil(f.module.issue)
    }

    /// La règle ne marche plus (autre utilisateur…) : la bascule réussit avec le mot de passe, l'état le dit (note
    /// de pied « La redonner », volet de réglages), et aucune erreur n'est affichée.
    func testARuleThatNoLongerWorksIsFlaggedButTheToggleSucceeds() {
        let f = QuickSettingsFixture(self)
        f.power.authorization = .granted
        f.power.ruleWorks = false
        f.startAndShow()
        f.module.toggleLowPower()
        settle()
        XCTAssertTrue(f.module.lowPower)
        XCTAssertEqual(f.module.authorization, .refused)
        XCTAssertNil(f.module.issue)

        f.module.grantLowPowerAuthorization()
        XCTAssertEqual(f.module.authorization, .granted)
    }

    func testScenesGoThroughTheSameWrite() {
        let f = QuickSettingsFixture(self)
        f.power.authorization = .granted
        f.startAndShow()
        f.module.applyScene(.autonomy)
        settle()
        f.module.applyScene(.presentation)
        settle()
        f.module.applyScene(.normal)
        settle()
        XCTAssertEqual(f.power.setCalls, [true, false], "Normal rend l'état d'avant : déjà coupé, rien à écrire")
        XCTAssertEqual(f.module.authorization, .granted)
        XCTAssertNil(f.module.issue)
    }
}
