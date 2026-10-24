import XCTest
@testable import Oriel

/// Reprise d'une installation faite sous l'ancien nom (ClaudeNotch, 2.1 et avant). Aucun test ne touche au vrai `~`.
final class MigrationTests: XCTestCase {
    private func locations() throws -> LegacyMigration.Locations {
        let root = try makeTemporaryDirectory(self)
        let make = { (name: String) -> URL in
            let url = root.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        return .init(applicationSupport: make("support"), launchAgents: make("agents"),
                     claudeConfig: make(".claude"))
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    // MARK: - Dossier de données

    func testDataFolderMovesWithItsToken() throws {
        let support = try locations().applicationSupport
        let old = support.appendingPathComponent("ClaudeNotch")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("jeton".utf8).write(to: old.appendingPathComponent("hook-token"))

        XCTAssertTrue(LegacyMigration.moveDataFolder(in: support))
        XCTAssertEqual(text(support.appendingPathComponent("Oriel/hook-token")), "jeton")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(LegacyMigration.moveDataFolder(in: support), "idempotent")
        XCTAssertEqual(text(support.appendingPathComponent("Oriel/hook-token")), "jeton")
    }

    func testDataFolderIsNotOverwrittenWhenBothExist() throws {
        let support = try locations().applicationSupport
        for (name, content) in [("ClaudeNotch", "ancien"), ("Oriel", "nouveau")] {
            let folder = support.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: folder.appendingPathComponent("hook-token"))
        }
        XCTAssertFalse(LegacyMigration.moveDataFolder(in: support))
        XCTAssertEqual(text(support.appendingPathComponent("Oriel/hook-token")), "nouveau")
        XCTAssertEqual(text(support.appendingPathComponent("ClaudeNotch/hook-token")), "ancien")
    }

    // MARK: - Réglages

    func testDefaultsAreCopiedOnlyIntoAnEmptyDomain() throws {
        let suite = "oriel-tests-\(UUID().uuidString)"
        let old = "oriel-tests-old-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            defaults.removePersistentDomain(forName: old)
        }
        defaults.setPersistentDomain(["alwaysVisible": true, "taille": 3], forName: old)
        XCTAssertFalse(LegacyMigration.copyDefaults(into: defaults, ownDomain: suite, legacyDomains: ["absent-\(old)"]))

        XCTAssertTrue(LegacyMigration.copyDefaults(into: defaults, ownDomain: suite, legacyDomains: [old]))
        XCTAssertEqual(defaults.object(forKey: "alwaysVisible") as? Bool, true)
        XCTAssertEqual(defaults.integer(forKey: "taille"), 3)

        // Une valeur changée ou retirée ensuite ne revient pas au lancement suivant.
        defaults.removeObject(forKey: "taille")
        defaults.set(false, forKey: "alwaysVisible")
        XCTAssertFalse(LegacyMigration.copyDefaults(into: defaults, ownDomain: suite, legacyDomains: [old]))
        XCTAssertNil(defaults.object(forKey: "taille"))
        XCTAssertEqual(defaults.object(forKey: "alwaysVisible") as? Bool, false)
    }

    // MARK: - Hooks Claude Code

    func testClaudeHooksAreRewrittenWithoutTouchingOthers() throws {
        let config = try locations().claudeConfig
        let hooks = config.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        for name in ["claude-notch-hook.sh", "claude-notch-statusline.sh", "claude-notch-statusline.previous", "autre.sh"] {
            try Data(name.utf8).write(to: hooks.appendingPathComponent(name))
        }
        let settings = config.appendingPathComponent("settings.json")
        let before = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"\#(hooks.path)/claude-notch-hook.sh\""},"#
            + #"{"type":"command","command":"/usr/local/bin/mien"}]}]},"#
            + #""statusLine":{"type":"command","command":"\"\#(hooks.path)/claude-notch-statusline.sh\""}}"#
        try Data(before.utf8).write(to: settings)

        XCTAssertTrue(LegacyMigration.rewriteClaudeHooks(in: config))
        let after = try XCTUnwrap(text(settings))
        XCTAssertEqual(after, before.replacingOccurrences(of: "claude-notch-hook.sh", with: "oriel-hook.sh")
            .replacingOccurrences(of: "claude-notch-statusline.sh", with: "oriel-statusline.sh"))
        XCTAssertTrue(after.contains("/usr/local/bin/mien"))
        XCTAssertEqual(text(config.appendingPathComponent("settings.json.oriel-migration.bak")), before)
        for name in ["oriel-hook.sh", "oriel-statusline.sh", "oriel-statusline.previous", "autre.sh"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: hooks.appendingPathComponent(name).path), name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooks.appendingPathComponent("claude-notch-hook.sh").path))

        XCTAssertFalse(LegacyMigration.rewriteClaudeHooks(in: config), "idempotent")
        XCTAssertEqual(text(settings), after)
    }

    func testClaudeHooksWithoutSettingsAreLeftAlone() throws {
        let config = try locations().claudeConfig
        XCTAssertFalse(LegacyMigration.rewriteClaudeHooks(in: config))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: config.path), [])
    }

    /// Écriture impossible : settings.json garde son contenu et l'ancien script reste en place (des sessions Claude
    /// déjà ouvertes l'appellent encore).
    func testScriptsStayWhenSettingsCannotBeRewritten() throws {
        let config = try locations().claudeConfig
        let hooks = config.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: hooks.appendingPathComponent("claude-notch-hook.sh"))
        let settings = config.appendingPathComponent("settings.json")
        let before = #"{"hooks":{"Stop":[{"hooks":[{"command":"\"\#(hooks.path)/claude-notch-hook.sh\""}]}]}}"#
        try Data(before.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: config.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: config.path) }

        XCTAssertFalse(LegacyMigration.rewriteClaudeHooks(in: config))
        XCTAssertEqual(text(settings), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooks.appendingPathComponent("claude-notch-hook.sh").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooks.appendingPathComponent("oriel-hook.sh").path))
    }

    /// settings.json en lien symbolique (dotfiles) : le lien reste un lien, sa cible est réécrite.
    func testSymbolicLinkToSettingsIsKept() throws {
        let place = try locations()
        let config = place.claudeConfig
        let dotfiles = place.applicationSupport.appendingPathComponent("dotfiles.json")
        try Data(#"{"command":"/h/claude-notch-hook.sh"}"#.utf8).write(to: dotfiles)
        let link = config.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dotfiles)

        XCTAssertTrue(LegacyMigration.rewriteClaudeHooks(in: config))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "toujours un lien")
        XCTAssertEqual(text(dotfiles), #"{"command":"/h/oriel-hook.sh"}"#)
    }

    // MARK: - Anciennes entrées et commande

    /// Un hook posé par la 2.1 (« claude-notch-hook.sh ») est le nôtre : il n'est pas laissé à côté du nouveau.
    func testLegacyHookEntriesAreOursAndNotDuplicated() throws {
        let config = try makeTemporaryDirectory(self)
        let installer = HookInstaller(configDirectory: config,
                                      bundledHook: repositoryRoot.appendingPathComponent("hooks/oriel-hook.sh"))
        let legacy = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"/h/claude-notch-hook.sh\"","async":true},"#
            + #"{"type":"command","command":"/usr/local/bin/mien"}]}]}}"#
        try Data(legacy.utf8).write(to: installer.settingsURL)
        XCTAssertEqual(installer.status(), .outdated)

        try installer.install()
        let after = try XCTUnwrap(text(installer.settingsURL))
        XCTAssertFalse(after.contains("claude-notch-hook.sh"))
        let fresh = try makeTemporaryDirectory(self)
        let clean = HookInstaller(configDirectory: fresh, bundledHook: repositoryRoot.appendingPathComponent("hooks/oriel-hook.sh"))
        try clean.install()
        let count = { (text: String) in text.components(separatedBy: "oriel-hook.sh").count }
        XCTAssertEqual(count(after), count(try XCTUnwrap(text(clean.settingsURL))), "mêmes entrées qu'une installation neuve")
        XCTAssertTrue(after.contains("/usr/local/bin/mien"))
        XCTAssertEqual(installer.status(), .installed)
    }

    /// La commande `notch` posée par la 2.1 est à mettre à jour, pas « un autre programme ».
    func testLegacyNotchCommandIsOutdatedNotForeign() throws {
        let folder = try makeTemporaryDirectory(self)
        let bundled = folder.appendingPathComponent("bundled")
        let destination = folder.appendingPathComponent("notch")
        try Data("#!/bin/sh\n\(NotchCLI.marker)\necho new\n".utf8).write(to: bundled)
        try Data("#!/bin/sh\n# claude-notch-cli\necho old\n".utf8).write(to: destination)
        XCTAssertEqual(NotchCLI.status(bundled: bundled, destination: destination), .outdated)
        try NotchCLI.install(bundled: bundled, destination: destination)
        XCTAssertEqual(NotchCLI.status(bundled: bundled, destination: destination), .installed)
        XCTAssertNoThrow(try NotchCLI.remove(destination: destination))
    }

    // MARK: - Hooks Codex

    /// Les hooks Codex ne sont pas réécrits (leur hash de confiance changerait) ; seul le script est mis à jour,
    /// en silence, et hooks.json reste identique octet pour octet.
    func testCodexScriptIsUpdatedWithoutTouchingHooksJSON() throws {
        let config = try makeTemporaryDirectory(self)
        let bundled = config.appendingPathComponent("bundled.sh")
        try Data("#!/bin/sh\nnouveau\n".utf8).write(to: bundled)
        let installer = CodexHookInstaller(configDirectory: config, bundledHook: bundled)
        try installer.install()
        let hooksBefore = try Data(contentsOf: installer.hooksURL)
        try Data("#!/bin/sh\nancien\n".utf8).write(to: installer.hookURL)
        XCTAssertEqual(installer.status(), .scriptOutdated)

        let setup = CodexHookSetup(installer: { installer }, service: { _ in nil })
        setup.updateScriptIfNeeded()
        XCTAssertEqual(setup.status, .installed)
        XCTAssertEqual(text(installer.hookURL), "#!/bin/sh\nnouveau\n")
        XCTAssertEqual(try Data(contentsOf: installer.hooksURL), hooksBefore)
    }

    func testCodexEntriesFromBeforeTheRenameStayCurrent() throws {
        let config = try makeTemporaryDirectory(self)
        let bundled = config.appendingPathComponent("bundled.sh")
        try Data("x".utf8).write(to: bundled)
        let installer = CodexHookInstaller(configDirectory: config, bundledHook: bundled)
        try installer.install()
        XCTAssertEqual(CodexHookInstaller.permissionStatus, "Claude Notch", "même définition qu'avant le renommage")
        XCTAssertEqual(installer.status(), .installed)
    }

    // MARK: - LaunchAgent et ensemble

    func testRunMigratesEverythingOnceAndIsIdempotent() throws {
        let place = try locations()
        let suite = "oriel-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let old = place.applicationSupport.appendingPathComponent("ClaudeNotch")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("jeton".utf8).write(to: old.appendingPathComponent("hook-token"))
        let oldAgent = place.launchAgents.appendingPathComponent("io.github.slybald.claudenotch.plist")
        try Data("<plist/>".utf8).write(to: oldAgent)
        let executable = "/Applications/Oriel.app/Contents/MacOS/Oriel"

        LegacyMigration.run(place, defaults: defaults, ownDomain: suite, executable: executable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAgent.path))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: LaunchAgent.plistURL(in: place.launchAgents)), format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [executable])
        XCTAssertEqual(text(place.applicationSupport.appendingPathComponent("Oriel/hook-token")), "jeton")

        LegacyMigration.run(place, defaults: defaults, ownDomain: suite, executable: executable)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: place.launchAgents.path),
                       ["io.github.slybald.oriel.plist"])
        XCTAssertEqual(text(place.applicationSupport.appendingPathComponent("Oriel/hook-token")), "jeton")
    }

    func testOptionOffMeansNoAgent() throws {
        let place = try locations()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "oriel-tests-\(UUID().uuidString)"))
        LegacyMigration.run(place, defaults: defaults, ownDomain: "x", executable: "/Applications/Oriel.app/Contents/MacOS/Oriel")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: place.launchAgents.path), [])
    }

    // MARK: - Nom affiché

    func testDisplayedNameAndIdentifier() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, AppIdentity.name)
        XCTAssertEqual(plist["CFBundleName"] as? String, AppIdentity.name)
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, AppIdentity.bundleId)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Oriel", "exécutable vérifié par make-dmg.sh")
    }
}
