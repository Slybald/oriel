import XCTest
@testable import Oriel

/// Installateur de hooks : toujours dans un dossier temporaire, jamais le vrai ~/.claude.
final class HookInstallerTests: XCTestCase {
    private static let bundledHook = repositoryRoot.appendingPathComponent("hooks/oriel-hook.sh")

    /// settings.json réaliste, au format exact de `json.dump(indent=2, ensure_ascii=False)`.
    static let realistic = #"""
    {
      "$schema": "https://json.schemastore.org/claude-code-settings.json",
      "env": {
        "CLAUDE_CODE_ENABLE_TODO_TOOLS": "1",
        "MAX_THINKING_TOKENS": "31999"
      },
      "permissions": {
        "allow": [
          "Bash(git status:*)",
          "Bash(swift test:*)",
          "Read(//Users/me/Documents/**)"
        ],
        "deny": [],
        "defaultMode": "acceptEdits"
      },
      "model": "opus",
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "~/.claude/hooks/garde-fou.sh \"$CLAUDE_PROJECT_DIR\"",
                "timeout": 5
              }
            ]
          }
        ],
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "afplay /System/Library/Sounds/Glass.aiff"
              }
            ]
          }
        ],
        "Notification": [
          {
            "matcher": "",
            "hooks": [
              {
                "type": "command",
                "command": "terminal-notifier -title 'Claude' -message \"Besoin de toi 👋\"\tdéfaut"
              }
            ]
          }
        ]
      },
      "statusLine": {
        "type": "command",
        "command": "~/.claude/statusline.sh",
        "padding": 0
      },
      "feedbackSurveyRate": 0.05,
      "cleanupPeriodDays": 30,
      "includeCoAuthoredBy": false,
      "apiKeyHelper": null,
      "nested": [
        [
          1,
          -2.5,
          1e-07,
          "ctrl \u0001 \u001f",
          "😀 é ü 中文"
        ],
        {}
      ]
    }
    """# + "\n"

    /// Cas tordus : nos entrées anciennes mélangées aux tiennes, événement vide, valeur qui n'est pas une liste,
    /// commande qui n'est pas une chaîne, entrée compacte avec échappements.
    static let tricky = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"afplay x"},"#
        + #"{"type":"command","command":"\"/ancien/chemin/oriel-hook.sh\"","async":true}]},"#
        + #"{"matcher":"","hooks":[{"type":"command","command":"/ancien/oriel-hook.sh"}]}],"#
        + #""SessionStart":[],"Custom":"pas une liste","#
        + #""PreCompact":[{"matcher":"auto","hooks":[{"type":"command","command":["oriel-hook.sh"]}]}],"#
        + #""PostToolUse":[{"hooks":"pas une liste"},42,{"hooks":[{"command":"oriel-hook.sh-fin"}]}]},"#
        + #""z":"\u00e9\/","a":[1,2,{}]}"#

    private var root: URL!
    private var config: URL!

    override func setUpWithError() throws {
        root = try makeTemporaryDirectory(self)
        config = root.appendingPathComponent("claude")
    }

    private func installer(in directory: URL? = nil, bundled: URL? = HookInstallerTests.bundledHook) -> HookInstaller {
        var installer = HookInstaller(configDirectory: directory ?? config, bundledHook: bundled)
        installer.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        return installer
    }

    private func write(_ text: String, to url: URL? = nil) throws {
        let url = url ?? config.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func settingsData(_ directory: URL? = nil) throws -> Data {
        try Data(contentsOf: (directory ?? config).appendingPathComponent("settings.json"))
    }

    private func backups(_ directory: URL? = nil) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: (directory ?? config).path)) ?? []
        return names.filter { $0.hasPrefix("settings.json.oriel-") }.sorted()
    }

    // MARK: - Installation

    func testInstallIntoEmptyConfig() throws {
        let installer = installer()
        XCTAssertEqual(installer.status(), .notInstalled)
        let outcome = try installer.install()
        XCTAssertEqual(outcome, HookInstaller.Outcome(settingsChanged: true, backup: nil))
        XCTAssertEqual(backups(), [], "rien à sauvegarder : settings.json n'existait pas")

        let settings = try OrderedJSON.parse(settingsData())
        XCTAssertEqual(settings["hooks"]?.members?.map(\.key), HookInstaller.events)
        let entries = HookInstaller.entries(command: installer.hookCommand)
        for event in HookInstaller.events {
            XCTAssertEqual(settings["hooks"]?[event], .array([.object([
                OrderedJSON.Member(key: "hooks", value: .array(entries[event] ?? [])),
            ])]))
            // Le relais async d'abord, partout.
            XCTAssertEqual(entries[event]?.first, HookInstaller.entry(command: installer.hookCommand), event)
        }
        // Répondre depuis la notch : PermissionRequest synchrone, attente asyncRewake sur SessionStart et Stop.
        XCTAssertEqual(HookInstaller.events.filter { (entries[$0]?.count ?? 0) > 1 },
                       ["SessionStart", "PermissionRequest", "Stop"])
        let permission = try XCTUnwrap(entries["PermissionRequest"]?.last)
        XCTAssertEqual(permission["command"], .string(installer.hookCommand + " permission"))
        XCTAssertEqual(permission["timeout"], .number("600"))
        XCTAssertNil(permission["async"], "synchrone")
        XCTAssertNil(permission["onFailure"], "un échec rend la main au terminal")
        XCTAssertEqual(entries["SessionStart"]?.last, entries["Stop"]?.last)
        let inbox = try XCTUnwrap(entries["Stop"]?.last)
        XCTAssertEqual(inbox["command"], .string(installer.hookCommand + " inbox"))
        XCTAssertEqual(inbox["asyncRewake"], .bool(true))
        XCTAssertEqual(inbox["timeout"], .number("86400"))

        let text = String(decoding: try settingsData(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\n  \"hooks\": {\n    \"SessionStart\": [\n      {\n        \"hooks\": [\n"))
        XCTAssertTrue(text.contains("\"command\": \"\\\"\(installer.hookURL.path)\\\"\",\n"))
        XCTAssertTrue(text.contains("\"command\": \"\\\"\(installer.hookURL.path)\\\" permission\",\n"))
        XCTAssertTrue(text.contains("\"async\": true,\n            \"timeout\": 10\n"))
        XCTAssertTrue(text.contains("\"rewakeSummary\": \"Message from Oriel\"\n"))
        XCTAssertTrue(text.hasSuffix("}\n"))

        // Script copié, exécutable, identique à celui de l'app.
        XCTAssertEqual(try Data(contentsOf: installer.hookURL), try Data(contentsOf: Self.bundledHook))
        let mode = try FileManager.default.attributesOfItem(atPath: installer.hookURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
        XCTAssertEqual(installer.status(), .installed)
    }

    func testInstallTwiceChangesNothing() throws {
        try write(Self.realistic)
        let installer = installer()
        XCTAssertTrue(try installer.install().settingsChanged)
        let installed = try settingsData()
        XCTAssertEqual(backups().count, 1)
        XCTAssertEqual(try installer.install(), HookInstaller.Outcome(settingsChanged: false, backup: nil))
        XCTAssertEqual(try settingsData(), installed)
        XCTAssertEqual(backups().count, 1, "aucune écriture, donc aucune sauvegarde")
    }

    func testInstallKeepsOtherHooksAndKeyOrder() throws {
        try write(Self.realistic)
        try installer().install()
        let settings = try OrderedJSON.parse(settingsData())
        let original = try OrderedJSON.parse(Self.realistic)
        XCTAssertEqual(settings.members?.map(\.key), original.members?.map(\.key))
        // Événements existants à leur place, les nouveaux à la suite, dans l'ordre de hooks_config.py.
        let expectedEvents = ["PreToolUse", "Stop", "Notification"]
            + HookInstaller.events.filter { !["PreToolUse", "Stop", "Notification"].contains($0) }
        XCTAssertEqual(settings["hooks"]?.members?.map(\.key), expectedEvents)
        // Ton groupe d'abord, le nôtre ensuite.
        let preToolUse = settings["hooks"]?["PreToolUse"]?.items
        XCTAssertEqual(preToolUse?.count, 2)
        XCTAssertEqual(preToolUse?.first, original["hooks"]?["PreToolUse"]?.items?.first)
        for key in ["env", "permissions", "statusLine", "nested", "feedbackSurveyRate"] {
            XCTAssertEqual(settings[key], original[key], key)
        }
    }

    // MARK: - Aller-retour octet pour octet

    func testInstallThenUninstallRestoresFileByteForByte() throws {
        try write(Self.realistic)
        let original = try settingsData()
        let installer = installer()
        try installer.install()
        XCTAssertNotEqual(try settingsData(), original)
        let outcome = try installer.uninstall()
        XCTAssertTrue(outcome.settingsChanged)
        XCTAssertTrue(try settingsData() == original, "settings.json doit revenir identique octet pour octet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.hookURL.path))
        let first = "settings.json.oriel-\(Self.stamp).bak"
        XCTAssertEqual(Set(backups()), [first, "settings.json.oriel-\(Self.stamp)-1.bak"])
        // Première sauvegarde = l'original.
        XCTAssertTrue(try Data(contentsOf: config.appendingPathComponent(first)) == original)
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    /// Même horloge que `installer()` : 1 800 000 000 s, heure locale.
    private static var stamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testBackupNamesGetSuffixOnCollision() throws {
        try write("{}\n")
        let installer = installer()
        try installer.install()
        try installer.uninstall()
        try installer.install()
        try installer.uninstall()
        XCTAssertEqual(backups(), [
            "settings.json.oriel-\(Self.stamp)-1.bak",
            "settings.json.oriel-\(Self.stamp)-2.bak",
            "settings.json.oriel-\(Self.stamp)-3.bak",
            "settings.json.oriel-\(Self.stamp).bak",
        ])
        XCTAssertEqual(String(decoding: try settingsData(), as: UTF8.self), "{}\n")
    }

    /// Même résultat que scripts/hooks_config.py, octet pour octet, à l'installation comme au retrait.
    func testMatchesPythonInstaller() throws {
        try Python.requireAvailable()
        let fixtures: [(String, String?)] = [
            ("absent", nil),
            ("vide", "  \n"),
            ("objet vide", "{}"),
            ("hooks vide", #"{"hooks": {}, "x": 1}"#),
            ("réaliste", Self.realistic),
            ("tordu", Self.tricky),
            ("indentation 4", "{\n    \"b\": [\n        1\n    ],\n    \"a\": \"\\u00e9\"\n}"),
        ]
        for (name, text) in fixtures {
            let swiftDir = root.appendingPathComponent("swift-\(name)")
            let pythonDir = root.appendingPathComponent("python-\(name)")
            for dir in [swiftDir, pythonDir] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let text { try write(text, to: dir.appendingPathComponent("settings.json")) }
            }
            let swift = installer(in: swiftDir)
            try swift.install()
            XCTAssertEqual(try Python.hooksConfig(["install", swift.hookURL.path], configDirectory: pythonDir), 0, name)
            XCTAssertTrue(try settingsData(swiftDir) == settingsData(pythonDir), "install, \(name)")
            XCTAssertEqual(backups(swiftDir).count, backups(pythonDir).count, "sauvegardes, \(name)")

            try swift.uninstall()
            XCTAssertEqual(try Python.hooksConfig(["uninstall"], configDirectory: pythonDir), 0, name)
            XCTAssertTrue(try settingsData(swiftDir) == settingsData(pythonDir), "uninstall, \(name)")
        }
    }

    /// Copie du vrai ~/.claude/settings.json, lu en lecture seule et traité dans un dossier temporaire.
    func testRealSettingsCopyRoundTrip() throws {
        try Python.requireAvailable()
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: real) else { throw XCTSkip("pas de ~/.claude/settings.json") }
        let copy = root.appendingPathComponent("copie.json")
        try data.write(to: copy)

        let swiftDir = root.appendingPathComponent("swift")
        let pythonDir = root.appendingPathComponent("python")
        for dir in [swiftDir, pythonDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Au format de Python d'abord : c'est le format que l'installateur écrit.
            try Python.normalize(copy, to: dir.appendingPathComponent("settings.json"))
        }
        let normalized = try settingsData(swiftDir)
        var reserialized = try OrderedJSON.parse(normalized).serialized()
        reserialized.append(0x0A)
        XCTAssertTrue(reserialized == normalized, "lecture puis écriture doivent redonner le texte de Python")

        // Nos entrées éventuelles retirées des deux côtés : c'est la base de l'aller-retour.
        let swift = installer(in: swiftDir)
        try swift.uninstall()
        XCTAssertEqual(try Python.hooksConfig(["uninstall"], configDirectory: pythonDir), 0)
        let base = try settingsData(swiftDir)
        XCTAssertTrue(try settingsData(pythonDir) == base, "uninstall identique à Python")

        try swift.install()
        XCTAssertEqual(try Python.hooksConfig(["install", swift.hookURL.path], configDirectory: pythonDir), 0)
        XCTAssertTrue(try settingsData(swiftDir) == settingsData(pythonDir), "install identique à Python")
        XCTAssertEqual(swift.status(), .installed)

        try swift.uninstall()
        // Un « hooks » vide ou un événement à [] ne survit pas au retrait (comme avec Python) : aller-retour
        // exact seulement sans eux.
        let hooks = try OrderedJSON.parse(base)["hooks"]
        let hasEmpty = hooks?.members.map { $0.isEmpty || $0.contains { $0.value.items?.isEmpty == true } } ?? false
        if !hasEmpty {
            XCTAssertTrue(try settingsData(swiftDir) == base, "install puis uninstall doit redonner le fichier")
        }
    }

    // MARK: - Erreurs : rien n'est touché

    func testInvalidJSONTouchesNothing() throws {
        let text = "{\n  \"hooks\": {,\n}\n"
        try write(text)
        let installer = installer()
        XCTAssertThrowsError(try installer.install()) { error in
            guard case .invalidSettings? = error as? HookInstaller.Failure else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.hasPrefix("settings.json invalide ("))
            XCTAssertTrue(error.localizedDescription.hasSuffix(" : rien n'a été modifié."))
        }
        XCTAssertThrowsError(try installer.uninstall())
        XCTAssertEqual(String(decoding: try settingsData(), as: UTF8.self), text)
        XCTAssertEqual(backups(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.hookURL.path), "script non copié")
        guard case .unreadable = installer.status() else { return XCTFail("illisible attendu") }
    }

    func testHooksNotAnObject() throws {
        let text = #"{"hooks": ["pas", "un", "objet"]}"#
        try write(text)
        let installer = installer()
        XCTAssertThrowsError(try installer.install()) { error in
            XCTAssertEqual(error as? HookInstaller.Failure, .hooksNotObject)
        }
        XCTAssertEqual(installer.status(), .unreadable(HookInstaller.Failure.hooksNotObject.localizedDescription))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.hookURL.path))
        // Comme hooks_config.py : le retrait n'a rien à retirer et ne réécrit pas le fichier.
        XCTAssertEqual(try installer.uninstall().settingsChanged, false)
        XCTAssertEqual(String(decoding: try settingsData(), as: UTF8.self), text)
    }

    func testEventNotAListAndRootNotAnObject() throws {
        try write(#"{"hooks": {"Stop": {"hooks": []}}}"#)
        XCTAssertThrowsError(try installer().install()) { error in
            XCTAssertEqual(error as? HookInstaller.Failure, .eventNotList("Stop"))
        }
        try write("[1, 2]")
        XCTAssertThrowsError(try installer().install()) { error in
            XCTAssertEqual(error as? HookInstaller.Failure, .settingsNotObject)
        }
        XCTAssertEqual(backups(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer().hookURL.path))
    }

    func testMissingBundledHookTouchesNothing() throws {
        try write(Self.realistic)
        let installer = installer(bundled: nil)
        XCTAssertThrowsError(try installer.install()) { error in
            XCTAssertEqual(error as? HookInstaller.Failure, .missingBundledHook)
        }
        XCTAssertEqual(String(decoding: try settingsData(), as: UTF8.self), Self.realistic)
        XCTAssertEqual(backups(), [])
    }

    // MARK: - Retrait

    func testUninstallKeepsForeignHooksInMixedGroups() throws {
        try write(Self.tricky)
        try installer().uninstall()
        let settings = try OrderedJSON.parse(settingsData())
        let stop = settings["hooks"]?["Stop"]?.items
        XCTAssertEqual(stop?.count, 1, "le groupe qui ne contenait que nous disparaît")
        XCTAssertEqual(stop?.first?["hooks"]?.items?.count, 1)
        XCTAssertEqual(stop?.first?["hooks"]?.items?.first?["command"], .string("afplay x"))
        XCTAssertNil(settings["hooks"]?["PreCompact"], "événement vidé par le retrait : supprimé")
        XCTAssertEqual(settings["hooks"]?["SessionStart"], .array([]), "déjà vide avant : conservé")
        XCTAssertEqual(settings["hooks"]?["Custom"], .string("pas une liste"))
        XCTAssertEqual(settings["hooks"]?["PostToolUse"]?.items?.count, 2,
                       "groupes illisibles conservés, « oriel-hook.sh-fin » est aussi à nous")
    }

    func testUninstallDropsEmptyHooksKeyAndScript() throws {
        try write(#"{"model": "opus"}"#)
        let installer = installer()
        try installer.install()
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.hookURL.path))
        try installer.uninstall()
        XCTAssertEqual(String(decoding: try settingsData(), as: UTF8.self), "{\n  \"model\": \"opus\"\n}\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.hookURL.path))
        // Rien à retirer : aucune écriture.
        let before = backups()
        XCTAssertEqual(try installer.uninstall().settingsChanged, false)
        XCTAssertEqual(backups(), before)
    }

    func testUninstallWithoutSettingsFile() throws {
        XCTAssertEqual(try installer().uninstall(), HookInstaller.Outcome(settingsChanged: false, backup: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.appendingPathComponent("settings.json").path))
    }

    // MARK: - Fichiers

    func testFileModeIsPreserved() throws {
        try write(Self.realistic)
        let path = config.appendingPathComponent("settings.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try installer().install()
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: config.path).filter { $0.hasPrefix(".settings") }
        XCTAssertEqual(leftovers, [], "pas de fichier temporaire oublié")
    }

    /// settings.json en lien symbolique (dotfiles) : le lien reste, sa cible est mise à jour.
    func testSymlinkedSettingsStaysALink() throws {
        let dotfiles = root.appendingPathComponent("dotfiles/settings.json")
        try write(Self.realistic, to: dotfiles)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let link = config.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dotfiles)

        let outcome = try installer().install()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), dotfiles.path)
        XCTAssertEqual(installer().status(), .installed)
        let backup = try XCTUnwrap(outcome.backup)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: backup.path), "copie, pas un lien")
        XCTAssertEqual(String(decoding: try Data(contentsOf: backup), as: UTF8.self), Self.realistic)

        try installer().uninstall()
        XCTAssertEqual(String(decoding: try Data(contentsOf: dotfiles), as: UTF8.self), Self.realistic)
    }

    // MARK: - État

    func testStatusDetectsOutdatedInstallations() throws {
        let installer = installer()
        try installer.install()
        XCTAssertEqual(installer.status(), .installed)
        let installed = try settingsData()

        // Autre chemin (installation faite ailleurs ou par une version précédente).
        var settings = try OrderedJSON.parse(installed)
        HookInstaller.strip(&settings, dropEmptyRoot: true)
        try HookInstaller.addEntries(to: &settings, command: "\"/ailleurs/oriel-hook.sh\"")
        try write(String(decoding: settings.serialized(), as: UTF8.self))
        XCTAssertEqual(installer.status(), .outdated)

        // Autres options.
        try write(String(decoding: installed, as: UTF8.self).replacingOccurrences(of: "\"timeout\": 10", with: "\"timeout\": 5"))
        XCTAssertEqual(installer.status(), .outdated)

        // Un événement manquant.
        settings = try OrderedJSON.parse(installed)
        settings["hooks"]?["PostCompact"] = nil
        try write(String(decoding: settings.serialized(), as: UTF8.self))
        XCTAssertEqual(installer.status(), .outdated)

        // Entrée en double.
        settings = try OrderedJSON.parse(installed)
        var stop = settings["hooks"]?["Stop"]?.items ?? []
        stop.append(stop[0])
        settings["hooks"]?["Stop"] = .array(stop)
        try write(String(decoding: settings.serialized(), as: UTF8.self))
        XCTAssertEqual(installer.status(), .outdated)

        // Installation d'une version précédente : le relais seul sur chaque événement (sans les hooks de réponse).
        settings = try OrderedJSON.parse(installed)
        HookInstaller.strip(&settings, dropEmptyRoot: true)
        var hooks = settings["hooks"] ?? .object([])
        for event in HookInstaller.events {
            hooks[event] = .array([.object([OrderedJSON.Member(key: "hooks", value: .array([
                HookInstaller.entry(command: installer.hookCommand),
            ]))])])
        }
        settings["hooks"] = hooks
        try write(String(decoding: settings.serialized(), as: UTF8.self))
        XCTAssertEqual(installer.status(), .outdated)

        // Hooks posés avant le renommage (« Message from Claude Notch ») : à réécrire, en silence au lancement.
        try write(String(decoding: installed, as: UTF8.self)
            .replacingOccurrences(of: HookInstaller.rewakeSummary, with: HookInstaller.legacyRewakeSummary)
            .replacingOccurrences(of: HookInstaller.rewakeMessage, with: HookInstaller.legacyRewakeMessage))
        XCTAssertEqual(installer.status(), .outdated)
        XCTAssertTrue(try installer.install().settingsChanged)
        XCTAssertEqual(try settingsData(), installed)
        XCTAssertFalse(try installer.install().settingsChanged, "idempotent")

        // Ordre des clés différent : toujours à jour.
        settings = try OrderedJSON.parse(installed)
        let reversed = HookInstaller.entries(command: installer.hookCommand)["Stop"]!.map { hook in
            OrderedJSON.object(Array(hook.members!.reversed()))
        }
        settings["hooks"]?["Stop"] = .array([.object([OrderedJSON.Member(key: "hooks", value: .array(reversed))])])
        try write(String(decoding: settings.serialized(), as: UTF8.self))
        XCTAssertEqual(installer.status(), .installed)

        // Script ancien, puis absent : entrées à jour, seul le script est à refaire.
        try write(String(decoding: installed, as: UTF8.self))
        XCTAssertEqual(installer.status(), .installed)
        try Data("#!/bin/sh\nopen -g -b local.oriel\n".utf8).write(to: installer.hookURL)
        XCTAssertEqual(installer.status(), .scriptOutdated)
        try FileManager.default.removeItem(at: installer.hookURL)
        XCTAssertEqual(installer.status(), .scriptOutdated)

        // Réinstaller remet tout d'aplomb.
        try installer.install()
        XCTAssertEqual(installer.status(), .installed)
        XCTAssertTrue(try settingsData() == installed)
    }

    /// Après une mise à jour de l'app : seul le script est réécrit, settings.json reste intact (ni écriture ni
    /// sauvegarde), même quand nos entrées ne sont pas en fin de liste.
    func testUpdateScriptLeavesSettingsUntouched() throws {
        let installer = installer()
        try installer.install()
        var settings = try OrderedJSON.parse(try settingsData())
        var stop = settings["hooks"]?["Stop"]?.items ?? []
        stop.append(.object([OrderedJSON.Member(key: "hooks", value: .array([
            .object([OrderedJSON.Member(key: "type", value: .string("command")),
                     OrderedJSON.Member(key: "command", value: .string("~/.claude/hooks/apres.sh"))]),
        ]))]))
        settings["hooks"]?["Stop"] = .array(stop)
        try write(String(decoding: settings.serialized(), as: UTF8.self))
        let before = try settingsData()
        let backupsBefore = backups()
        try Data("#!/bin/sh\n# ancienne version\n".utf8).write(to: installer.hookURL)
        XCTAssertEqual(installer.status(), .scriptOutdated)

        try installer.updateScript()
        XCTAssertEqual(installer.status(), .installed)
        XCTAssertTrue(try settingsData() == before)
        XCTAssertEqual(backups(), backupsBefore)
        XCTAssertEqual(try Data(contentsOf: installer.hookURL), try Data(contentsOf: Self.bundledHook))
        XCTAssertThrowsError(try self.installer(bundled: nil).updateScript()) { error in
            XCTAssertEqual(error as? HookInstaller.Failure, .missingBundledHook)
        }
    }

    /// Après une mise à jour de l'app : des hooks d'une version précédente sont mis à jour sans fenêtre, avec
    /// sauvegarde ; des hooks absents ne sont jamais installés en silence.
    func testSilentUpdateOfPreviousInstallation() throws {
        let installer = installer()
        let setup = HookSetup(installer: installer)
        setup.refresh()
        setup.silentUpdate()
        XCTAssertEqual(setup.status, .notInstalled, "jamais installé : rien en silence")
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.appendingPathComponent("settings.json").path))

        // Version précédente : le relais seul, et un ancien script.
        var settings = try OrderedJSON.parse(Self.realistic)
        var hooks = settings["hooks"] ?? .object([])
        for event in HookInstaller.events {
            var groups = hooks[event]?.items ?? []
            groups.append(.object([OrderedJSON.Member(key: "hooks", value: .array([
                HookInstaller.entry(command: installer.hookCommand),
            ]))]))
            hooks[event] = .array(groups)
        }
        settings["hooks"] = hooks
        try write(String(decoding: settings.serialized(), as: UTF8.self) + "\n")
        try FileManager.default.createDirectory(at: installer.hookURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\n# ancienne version\n".utf8).write(to: installer.hookURL)
        setup.refresh()
        XCTAssertEqual(setup.status, .outdated)

        setup.silentUpdate()
        XCTAssertEqual(setup.status, .installed)
        XCTAssertEqual(backups().count, 1, "sauvegarde horodatée avant l'écriture")
        XCTAssertEqual(try Data(contentsOf: installer.hookURL), try Data(contentsOf: Self.bundledHook))
        let updated = try OrderedJSON.parse(settingsData())
        XCTAssertEqual(updated["hooks"]?["PreToolUse"]?.items?.first,
                       try OrderedJSON.parse(Self.realistic)["hooks"]?["PreToolUse"]?.items?.first, "tes hooks restent")
    }

    func testOursRequiresAnObjectWithMarker() {
        XCTAssertTrue(HookInstaller.isOurs(.object([OrderedJSON.Member(key: "command", value: .string("x/oriel-hook.sh y"))])))
        XCTAssertFalse(HookInstaller.isOurs(.object([OrderedJSON.Member(key: "command", value: .string("autre.sh"))])))
        XCTAssertFalse(HookInstaller.isOurs(.object([OrderedJSON.Member(key: "cmd", value: .string("oriel-hook.sh"))])))
        XCTAssertFalse(HookInstaller.isOurs(.string("oriel-hook.sh")))
        XCTAssertTrue(HookInstaller.isOurs(.object([OrderedJSON.Member(
            key: "command", value: .array([.string("oriel-hook.sh")]))])))
        XCTAssertFalse(HookInstaller.isOurs(.object([OrderedJSON.Member(key: "command", value: .number("42"))])))
    }
}
