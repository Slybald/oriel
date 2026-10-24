import Foundation
import XCTest
@testable import Oriel

/// Pose et retrait des hooks dans un faux ~/.codex (dossier temporaire) : faux hooks.json, faux config.toml.
/// Rien n'est lu ni écrit dans le vrai dossier de l'utilisateur.
final class CodexHookInstallerTests: XCTestCase {
    private var dir: URL!
    private var bundled: URL!
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        dir = try makeTemporaryDirectory(self).appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        bundled = dir.deletingLastPathComponent().appendingPathComponent("bundle-codex-notch-hook.sh")
        try "#!/bin/sh\nexit 0\n".write(to: bundled, atomically: true, encoding: .utf8)
    }

    private func installer(bundledHook: URL? = nil) -> CodexHookInstaller {
        var installer = CodexHookInstaller(configDirectory: dir, bundledHook: bundledHook ?? bundled)
        installer.now = { [date] in date }
        return installer
    }

    private var hooksFile: URL { dir.appendingPathComponent("hooks.json") }
    private var configFile: URL { dir.appendingPathComponent("config.toml") }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readHooks() throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hooksFile)) as? NSDictionary)
    }

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".bak") }.sorted()
    }

    private func ourEntries(_ hooks: NSDictionary, _ event: String) -> [NSDictionary] {
        let groups = (hooks["hooks"] as? NSDictionary)?[event] as? [NSDictionary] ?? []
        return groups.flatMap { ($0["hooks"] as? [NSDictionary] ?? []) }.filter {
            (($0["command"] as? String) ?? "").contains(CodexHookInstaller.marker)
        }
    }

    // MARK: - Pose

    func testFreshInstallWritesOurEightEvents() throws {
        let outcome = try installer().install()
        XCTAssertTrue(outcome.fileChanged)
        XCTAssertNil(outcome.backup, "pas d'ancien fichier : rien à sauvegarder")

        let hooks = try readHooks()
        let command = "\"\(dir.path)/hooks/codex-notch-hook.sh\""
        for event in CodexHookInstaller.events {
            let entries = ourEntries(hooks, event)
            XCTAssertEqual(entries.count, 1, event)
            if event == "PermissionRequest" {
                XCTAssertEqual(entries[0]["command"] as? String, command + " permission")
                XCTAssertEqual(entries[0]["timeout"] as? Int, 75)
                XCTAssertNil(entries[0]["async"], "synchrone : Codex attend la décision")
            } else {
                XCTAssertEqual(entries[0]["command"] as? String, command)
                XCTAssertEqual(entries[0]["async"] as? Bool, true)
                // Codex plafonne SessionEnd et Interrupt à 3 s (avertissement sinon).
                XCTAssertEqual(entries[0]["timeout"] as? Int, ["Interrupt", "SessionEnd"].contains(event) ? 3 : 10, event)
            }
        }
        let script = dir.appendingPathComponent("hooks/codex-notch-hook.sh")
        let mode = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
        XCTAssertEqual(installer().status(), .installed)
    }

    func testInstallIsIdempotentAndWritesNothingTwice() throws {
        try installer().install()
        let first = try Data(contentsOf: hooksFile)
        let again = try installer().install()
        XCTAssertFalse(again.fileChanged)
        XCTAssertNil(again.backup)
        XCTAssertEqual(try Data(contentsOf: hooksFile), first, "octet pour octet")
        XCTAssertTrue(try backups().isEmpty)
    }

    func testOtherHooksAndKeyOrderSurviveWithATimestampedBackup() throws {
        let original = """
        {
          "zzz": 1,
          "hooks": {
            "Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/mon-notifieur"}]}],
            "PreToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "audit.sh", "timeout": 30}]}]
          },
          "aaa": 2
        }
        """
        try write(original, to: hooksFile)
        let outcome = try installer().install()
        XCTAssertEqual(try backups(), ["hooks.json.oriel-\(Self.stamp(date)).bak"])
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(outcome.backup), encoding: .utf8), original, "copie intacte")

        let text = try String(contentsOf: hooksFile, encoding: .utf8)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"zzz\"")).lowerBound, try XCTUnwrap(text.range(of: "\"hooks\"")).lowerBound)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"hooks\"")).lowerBound, try XCTUnwrap(text.range(of: "\"aaa\"")).lowerBound,
                          "l'ordre des clés est conservé")
        let hooks = try readHooks()
        let stop = try XCTUnwrap((hooks["hooks"] as? NSDictionary)?["Stop"] as? [NSDictionary])
        XCTAssertEqual(stop.count, 2, "le hook de l'utilisateur d'abord, le nôtre ensuite")
        XCTAssertEqual(((stop[0]["hooks"] as? [NSDictionary])?.first?["command"]) as? String, "/usr/local/bin/mon-notifieur")
        let pre = try XCTUnwrap((hooks["hooks"] as? NSDictionary)?["PreToolUse"] as? [NSDictionary])
        XCTAssertEqual(pre[0]["matcher"] as? String, "^Bash$")
        XCTAssertEqual(pre.count, 2)

        // Deuxième sauvegarde le même jour : suffixe -1.
        try write("{}", to: hooksFile)
        try installer().install()
        XCTAssertEqual(try backups().count, 2)
        XCTAssertTrue(try backups().contains("hooks.json.oriel-\(Self.stamp(date))-1.bak"))
    }

    func testInvalidHooksFileIsLeftUntouched() throws {
        for broken in ["{ pas du json", "[1, 2]", "{\"hooks\": []}", "{\"hooks\": {\"Stop\": {}}}"] {
            try write(broken, to: hooksFile)
            XCTAssertThrowsError(try installer().install(), broken)
            XCTAssertEqual(try String(contentsOf: hooksFile, encoding: .utf8), broken)
            XCTAssertTrue(try backups().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("hooks").path),
                           "le script n'est pas copié non plus")
        }
        try write("{ pas du json", to: hooksFile)
        guard case .unreadable = installer().status() else { return XCTFail("illisible attendu") }
    }

    func testMissingBundledScriptFailsWithoutWriting() throws {
        XCTAssertThrowsError(try installer(bundledHook: dir.appendingPathComponent("absent.sh")).install()) { error in
            XCTAssertEqual(error as? CodexHookInstaller.Failure, .missingBundledHook)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksFile.path))
    }

    func testSymlinkedHooksFileStaysALink() throws {
        let real = dir.deletingLastPathComponent().appendingPathComponent("dotfiles-hooks.json")
        try write("{}", to: real)
        try FileManager.default.createSymbolicLink(at: hooksFile, withDestinationURL: real)
        try installer().install()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: hooksFile.path), real.path)
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).contains("codex-notch-hook.sh"))
    }

    // MARK: - État

    func testStatusFollowsTheFiles() throws {
        XCTAssertEqual(installer().status(), .notInstalled)
        try installer().install()
        XCTAssertEqual(installer().status(), .installed)

        // Script remplacé par une autre version (app mise à jour).
        try "#!/bin/sh\necho ancien\n".write(to: dir.appendingPathComponent("hooks/codex-notch-hook.sh"),
                                            atomically: true, encoding: .utf8)
        XCTAssertEqual(installer().status(), .scriptOutdated)
        try installer().install()
        XCTAssertEqual(installer().status(), .installed)

        // Entrée modifiée à la main : à mettre à jour.
        let edited = try String(contentsOf: hooksFile, encoding: .utf8).replacingOccurrences(of: "\"timeout\": 75", with: "\"timeout\": 9")
        try write(edited, to: hooksFile)
        XCTAssertEqual(installer().status(), .outdated)
        try installer().install()
        XCTAssertEqual(installer().status(), .installed)
    }

    // MARK: - Retrait

    func testUninstallRemovesOnlyOurHooksAndKeepsTheUsers() throws {
        try write("""
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/mon-notifieur"}]}]}}
        """, to: hooksFile)
        try installer().install()
        let outcome = try installer().uninstall()
        XCTAssertTrue(outcome.fileChanged)

        let hooks = try readHooks()
        for event in CodexHookInstaller.events { XCTAssertTrue(ourEntries(hooks, event).isEmpty, event) }
        let stop = try XCTUnwrap((hooks["hooks"] as? NSDictionary)?["Stop"] as? [NSDictionary])
        XCTAssertEqual(stop.count, 1, "le hook de l'utilisateur reste")
        XCTAssertNil((hooks["hooks"] as? NSDictionary)?["PreToolUse"], "événements vidés retirés")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("hooks/codex-notch-hook.sh").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("hooks").path),
                       "dossier hooks/ vide : retiré")
        XCTAssertEqual(installer().status(), .notInstalled)
        XCTAssertFalse(try backups().isEmpty, "sauvegarde avant le retrait")
    }

    func testUninstallKeepsAFolderWithTheUsersOwnScripts() throws {
        try installer().install()
        try "#!/bin/sh\n".write(to: dir.appendingPathComponent("hooks/mon-script.sh"), atomically: true, encoding: .utf8)
        try installer().uninstall()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("hooks/mon-script.sh").path))
    }

    func testUninstallDeletesAFileThatOnlyHeldOurHooksAfterABackup() throws {
        try installer().install()
        try installer().uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksFile.path))
        XCTAssertEqual(try backups().count, 1)
        // Rien n'est installé : retirer encore ne fait rien.
        let again = try installer().uninstall()
        XCTAssertFalse(again.fileChanged)
    }

    // MARK: - config.toml : lu, jamais écrit

    func testConfigTomlIsNeverWritten() throws {
        let config = """
        model = "gpt-6-astra"
        notify = ["/chemin/vers/un-outil", "turn-ended"]

        [features]
        multi_agent = true
        """
        try write(config, to: configFile)
        let before = try Data(contentsOf: configFile)
        let attributes = try FileManager.default.attributesOfItem(atPath: configFile.path)
        try installer().install()
        _ = installer().configNotes()
        try installer().uninstall()
        XCTAssertEqual(try Data(contentsOf: configFile), before, "config.toml (et son notify) intacts, octet pour octet")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: configFile.path)[.modificationDate] as? Date,
                       attributes[.modificationDate] as? Date)
    }

    func testConfigNotes() {
        let path = "/Users/demo/.codex/hooks.json"
        let none = CodexHookInstaller.configNotes(in: "model = \"x\"\n")
        XCTAssertEqual(none, CodexHookInstaller.ConfigNotes())

        let notify = CodexHookInstaller.configNotes(in: "notify = [\"a\", \"b\"]\n[features]\nmulti_agent = true\n")
        XCTAssertTrue(notify.hasNotify)
        XCTAssertFalse(notify.hooksDisabled)

        // `notify` dans une table n'est pas le `notify` racine.
        XCTAssertFalse(CodexHookInstaller.configNotes(in: "[tui]\nnotify = true\n").hasNotify)

        XCTAssertTrue(CodexHookInstaller.configNotes(in: "[features]\nhooks = false\n").hooksDisabled)
        XCTAssertTrue(CodexHookInstaller.configNotes(in: "[features]\ncodex_hooks = false # ancien nom\n").hooksDisabled)
        XCTAssertFalse(CodexHookInstaller.configNotes(in: "[features]\nhooks = true\n").hooksDisabled)
        XCTAssertFalse(CodexHookInstaller.configNotes(in: "[other]\nhooks = false\n").hooksDisabled)

        let inline = CodexHookInstaller.configNotes(in: "[[hooks.Stop]]\nmatcher = \"x\"\n")
        XCTAssertTrue(inline.inlineHooks)

        // Format relevé : l'approbation dans Codex écrit `hooks.state."<fichier>:<événement>:<groupe>:<hook>"`.
        let state = CodexHookInstaller.configNotes(in: """
        [hooks.state."\(path):stop:0:0"]
        trusted_hash = "sha256:abc"
        """)
        XCTAssertFalse(state.inlineHooks, "hooks.state n'est pas un hook en ligne")
    }

    // MARK: - Détection

    func testCodexPresenceDetection() throws {
        let home = try makeTemporaryDirectory(self)
        func present(_ environment: [String: String] = [:]) -> Bool {
            CodexHookInstaller.codexPresent(home: home, environment: environment, applications: [])
        }
        XCTAssertFalse(present())
        let custom = home.appendingPathComponent("codex-ailleurs")
        XCTAssertFalse(present(["CODEX_HOME": custom.path]))
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        XCTAssertTrue(present(["CODEX_HOME": custom.path]))
        try "x".write(to: home.appendingPathComponent(".codex"), atomically: true, encoding: .utf8)
        XCTAssertFalse(present(), "un fichier n'est pas le dossier de Codex")
        try FileManager.default.removeItem(at: home.appendingPathComponent(".codex"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        XCTAssertTrue(present())

        let bare = try makeTemporaryDirectory(self)
        let app = bare.appendingPathComponent("Codex.app")
        XCTAssertFalse(CodexHookInstaller.codexPresent(home: bare, environment: [:], applications: [app.path]))
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertTrue(CodexHookInstaller.codexPresent(home: bare, environment: [:], applications: [app.path]))
        // L'app ChatGPT (bundle com.openai.codex) suffit, sans ~/.codex ni commande.
        XCTAssertFalse(CodexHookInstaller.codexPresent(home: try makeTemporaryDirectory(self), environment: [:], applications: []))
        XCTAssertTrue(CodexHookInstaller.codexPresent(home: try makeTemporaryDirectory(self), environment: [:], applications: [],
                                                      appInstalled: true))
        XCTAssertFalse(CodexHookInstaller.codexOnThisMac, "jamais le vrai Mac sous XCTest")
    }

    func testTabDecisionIsMadeOnce() throws {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.decideCodexTab(codexPresent: { false })
        XCTAssertEqual(prefs.tabEnabled["codex"], false, "pas de Codex : onglet désactivé")
        prefs.decideCodexTab(codexPresent: { XCTFail("déjà décidé"); return true })
        XCTAssertEqual(prefs.tabEnabled["codex"], false)

        let withCodex = Preferences(defaults: makeEphemeralDefaults(self))
        withCodex.decideCodexTab(codexPresent: { true })
        XCTAssertEqual(withCodex.tabEnabled["codex"], true)

        // Réglages existants (mise à jour de l'app) : les autres choix ne bougent pas.
        let update = Preferences(defaults: makeEphemeralDefaults(self))
        update.tabEnabled = ["media": false, "claude": true]
        update.decideCodexTab(codexPresent: { true })
        XCTAssertEqual(update.tabEnabled, ["media": false, "claude": true, "codex": true])
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
