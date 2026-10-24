import XCTest
@testable import Oriel

/// Installation de l'outil des ventilateurs et de sa règle sudoers : contenu de la règle, arguments de sudo, chaîne
/// d'installation, retrait. Aucun test n'exécute sudo ou AppleScript, ni n'écrit dans /etc ou /Library : seuls
/// tournent pour de vrai, sans droits root, /bin/sh, mktemp, cp, shasum, printf et `visudo -c` (lecture), avec les
/// étapes d'installation remplacées par des copies dans un dossier d'essai (même méthode que la règle d'économie
/// d'énergie).
final class FanAuthorizationTests: XCTestCase {
    /// La commande réelle crée ses fichiers de travail dans /tmp/oriel.XXXXXX, partagé entre tests en parallèle :
    /// ici le modèle pointe vers un dossier propre au test, et `workFiles()` ne compte que ce qui s'y trouve.
    private var work: URL!

    override func setUpWithError() throws { work = try makeTemporaryDirectory(self) }

    private func shell(_ command: String) throws -> SystemProcess.Output {
        let isolated = command.replacingOccurrences(of: LowPowerAuthorization.workFileTemplate,
                                                    with: work.appendingPathComponent("oriel.XXXXXX").path)
        return try XCTUnwrap(SystemProcess.run("/bin/sh", ["-c", isolated], timeout: 20))
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// Un dossier d'essai au nom hostile (espace, apostrophe, accent), supprimé en fin de test.
    private func scratchDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Ventilateurs d'essai é \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func workFiles() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).filter { $0.hasPrefix("oriel.") })
    }

    private var installHelperStep: String {
        "\(LowPowerAuthorization.installPath) -m 0755 -o root -g wheel \"$B\" \(FanAuthorization.helperPath)"
    }

    private var installRuleStep: String {
        "\(LowPowerAuthorization.installPath) -m 0440 -o root -g wheel \"$T\" \(FanAuthorization.rulePath)"
    }

    private let mkdirStep = "/bin/mkdir -p /Library/PrivilegedHelperTools"

    /// La vraie commande, avec les trois étapes qui écrivent hors du dossier d'essai remplacées : rien n'est installé.
    private func dryRun(source: URL, sha256: String, rule: String, into target: URL) throws -> SystemProcess.Output {
        let real = try XCTUnwrap(FanAuthorization.installShellCommand(helperSource: source.path, sha256: sha256, ruleContents: rule))
        for step in [installHelperStep, installRuleStep, mkdirStep, LowPowerAuthorization.workFileTemplate] {
            XCTAssertTrue(real.contains(step), step)
        }
        let q = LowPowerAuthorization.shellQuote
        let dry = real
            .replacingOccurrences(of: installHelperStep, with: "/bin/cp \"$B\" \(q(target.appendingPathComponent("fanctl").path))")
            .replacingOccurrences(of: installRuleStep, with: "/bin/cp \"$T\" \(q(target.appendingPathComponent("rule").path))")
            .replacingOccurrences(of: mkdirStep, with: "/usr/bin/true")
        XCTAssertFalse(dry.contains(LowPowerAuthorization.installPath), "aucune installation réelle")
        XCTAssertFalse(dry.contains("/bin/mkdir"))
        return try shell(dry)
    }

    // MARK: - Règle

    func testRuleContentsAreExact() {
        XCTAssertEqual(FanAuthorization.ruleContents(forUser: "jean.dupont"), """
            # Oriel : pilote les ventilateurs (automatique ou vitesse fixe bornee) sans mot de passe.
            # Pour retirer cette autorisation : sudo rm /etc/sudoers.d/oriel-fans /Library/PrivilegedHelperTools/io.github.slybald.oriel.fanctl
            jean.dupont ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/io.github.slybald.oriel.fanctl auto, /Library/PrivilegedHelperTools/io.github.slybald.oriel.fanctl hold

            """)
    }

    /// Une seule règle, l'outil avec exactement `auto` ou `hold`, ni joker ni autre commande ; un utilisateur
    /// douteux n'obtient aucune règle.
    func testRuleAllowsOnlyTheToolWithItsTwoCommands() throws {
        let rule = try XCTUnwrap(FanAuthorization.ruleContents(forUser: "alice"))
        XCTAssertTrue(rule.allSatisfy(\.isASCII))
        let rules = rule.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertEqual(rules.count, 1)
        let parts = rules[0].components(separatedBy: " NOPASSWD: ")
        XCTAssertEqual(parts[0], "alice ALL=(root)")
        XCTAssertEqual(parts[1].components(separatedBy: ", "),
                       ["\(FanAuthorization.helperPath) auto", "\(FanAuthorization.helperPath) hold"])
        for forbidden in ["*", "ALL=(ALL", "SETENV", "!", "\\"] { XCTAssertFalse(rule.contains(forbidden), forbidden) }
        for user in ["", "ALL", "-alice", "al ice", "alice\nbob ALL=(ALL) ALL", "%admin", "#0"] {
            XCTAssertNil(FanAuthorization.ruleContents(forUser: user), user)
        }
        XCTAssertFalse((FanAuthorization.rulePath as NSString).lastPathComponent.contains("."), "lu par sudo")
    }

    /// L'outil vit chez root, jamais dans le bundle de l'app ; sudo ne reçoit que `auto` ou `hold`.
    func testHelperLivesInARootFolderAndSudoGetsFixedArguments() {
        XCTAssertTrue(FanAuthorization.helperPath.hasPrefix("/Library/PrivilegedHelperTools/"))
        XCTAssertEqual(FanAuthorization.sudoArguments("auto"), ["-n", FanAuthorization.helperPath, "auto"])
        XCTAssertEqual(FanAuthorization.sudoArguments("hold"), ["-n", FanAuthorization.helperPath, "hold"])
    }

    // MARK: - Installation

    /// Copier, vérifier l'empreinte, écrire la règle, la valider, puis seulement installer l'outil et la règle ;
    /// fichiers de travail supprimés quoi qu'il arrive.
    func testInstallCommandIsTheExpectedChain() throws {
        let hash = String(repeating: "a", count: 64)
        let command = try XCTUnwrap(FanAuthorization.installShellCommand(
            helperSource: "/Applications/Oriel.app/Contents/Helpers/fanctl", sha256: hash,
            ruleContents: XCTUnwrap(FanAuthorization.ruleContents(forUser: "alice"))))
        func position(_ needle: String) -> String.Index { command.range(of: needle)!.lowerBound }
        let order = ["/bin/cp '/Applications/Oriel.app/Contents/Helpers/fanctl' \"$B\"", "/usr/bin/shasum -a 256",
                     "= \(hash) ]", "/usr/bin/printf", "/usr/sbin/visudo -cf \"$T\"", mkdirStep, installHelperStep,
                     installRuleStep, "/bin/rm -f \"$T\" \"$B\"; exit $R"]
        for (first, second) in zip(order, order.dropFirst()) {
            XCTAssertLessThan(position(first), position(second), "\(first) avant \(second)")
        }
        XCTAssertEqual(command.components(separatedBy: " && ").count, 7, "chaque étape dépend de la précédente")
        XCTAssertEqual(command.components(separatedBy: ">").count, 2, "une seule redirection : vers le fichier de root")
    }

    func testInstallCommandRefusesAMalformedHash() throws {
        let rule = try XCTUnwrap(FanAuthorization.ruleContents(forUser: "alice"))
        for bad in ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64),
                    String(repeating: "a", count: 63) + ";", String(repeating: "a", count: 63) + "g"] {
            XCTAssertNil(FanAuthorization.installShellCommand(helperSource: "/x", sha256: bad, ruleContents: rule), bad)
        }
    }

    /// Preuve avec les vrais mktemp, cp, shasum, printf et visudo -c : l'outil copié est octet pour octet celui du
    /// bundle, la règle est exactement `ruleContents`, visudo l'accepte, et les fichiers de travail disparaissent.
    func testRealChainInstallsTheExactHelperAndRule() throws {
        guard FileManager.default.isExecutableFile(atPath: LowPowerAuthorization.visudoPath) else { throw XCTSkip("visudo absent") }
        let directory = try scratchDirectory()
        let source = directory.appendingPathComponent("fanctl d'origine")
        let helper = Data((0..<4096).map { UInt8($0 % 251) })
        try helper.write(to: source)
        let hash = try XCTUnwrap(FanAuthorization.sha256(of: source))
        let rule = try XCTUnwrap(FanAuthorization.ruleContents(forUser: "alice"))
        let before = workFiles()
        let output = try dryRun(source: source, sha256: hash, rule: rule, into: directory)
        XCTAssertEqual(output.status, 0, text(output.stderr))
        XCTAssertTrue(text(output.stdout).contains("parsed OK"), text(output.stdout))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("fanctl")), helper)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("rule"), encoding: .utf8), rule)
        XCTAssertEqual(workFiles(), before, "fichiers de travail supprimés")
    }

    /// Un outil échangé entre la lecture de l'app et la copie de root (empreinte différente) : rien n'est installé.
    func testSwappedHelperIsNotInstalled() throws {
        let directory = try scratchDirectory()
        let source = directory.appendingPathComponent("fanctl")
        try Data("outil attendu".utf8).write(to: source)
        let hash = try XCTUnwrap(FanAuthorization.sha256(of: source))
        try Data("autre outil".utf8).write(to: source)
        let target = directory.appendingPathComponent("cible")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let before = workFiles()
        let output = try dryRun(source: source, sha256: hash, rule: XCTUnwrap(FanAuthorization.ruleContents(forUser: "alice")),
                                into: target)
        XCTAssertNotEqual(output.status, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [], "ni outil ni règle")
        XCTAssertEqual(workFiles(), before)
    }

    /// Règle refusée par visudo : l'outil n'est pas installé non plus.
    func testNothingIsInstalledWhenVisudoRefusesTheRule() throws {
        guard FileManager.default.isExecutableFile(atPath: LowPowerAuthorization.visudoPath) else { throw XCTSkip("visudo absent") }
        let directory = try scratchDirectory()
        let source = directory.appendingPathComponent("fanctl")
        try Data("outil".utf8).write(to: source)
        let target = directory.appendingPathComponent("cible")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let output = try dryRun(source: source, sha256: XCTUnwrap(FanAuthorization.sha256(of: source)),
                                rule: "alice ALL=(root) NOPASSWD /x\n", into: target)
        XCTAssertNotEqual(output.status, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    /// Le retrait rend d'abord la main à macOS (si l'outil est là), puis supprime la règle et l'outil.
    func testRemoveCommandReturnsToAutomaticFirst() {
        XCTAssertEqual(FanAuthorization.removeShellCommand,
                       "[ -x \(FanAuthorization.helperPath) ] && \(FanAuthorization.helperPath) auto;"
                           + " /bin/rm -f \(FanAuthorization.rulePath) \(FanAuthorization.helperPath)")
    }

    /// Désinstallation de l'app : sans outil ni règle, rien n'est demandé.
    func testUninstallAsksNothingWhenNothingIsInstalled() {
        let fans = QSFakeFans()
        var result: Result<Void, QuickSettingsFailure>?
        FanAuthorization.remove(fans: fans, isInstalled: { false }) { result = $0 }
        XCTAssertNotNil(try result?.get())
        XCTAssertEqual(fans.uninstalls, 0)
        FanAuthorization.remove(fans: fans, isInstalled: { true }) { result = $0 }
        XCTAssertEqual(fans.uninstalls, 1)
    }

    // MARK: - Accès système (sans exécution)

    /// L'installation passe par la fenêtre d'autorisation du système avec la chaîne ci-dessus ; un utilisateur
    /// douteux ne déclenche rien.
    func testInstallGoesThroughTheSystemPromptOnly() throws {
        var calls: [(String, [String])] = []
        let lock = NSLock()
        let helper = try scratchDirectory().appendingPathComponent("fanctl")
        try Data("outil".utf8).write(to: helper)
        let fans = SystemFans(run: { path, arguments, _ in
            lock.lock(); calls.append((path, arguments)); lock.unlock()
            return SystemProcess.Output(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
        }, userName: { "alice" }, bundledHelper: helper)
        XCTAssertTrue(fans.canInstall)
        let done = expectation(description: "install")
        fans.install { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNotNil(try? result.get())
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(calls.map(\.0), ["/usr/bin/osascript"])
        let script = calls[0].1[1]
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains(FanAuthorization.rulePath) && script.contains("visudo"))
        XCTAssertTrue(script.contains(try XCTUnwrap(FanAuthorization.sha256(of: helper))), "empreinte de l'outil lu")

        let refused = SystemFans(run: { _, _, _ in XCTFail("rien ne doit tourner"); return nil }, userName: { "al ice" },
                                 bundledHelper: helper)
        var failure: QuickSettingsFailure?
        refused.install { if case .failure(let error) = $0 { failure = error } }
        XCTAssertEqual(failure?.kind, .invalidUser)
    }
}
