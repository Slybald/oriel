import XCTest
@testable import Oriel

/// Identifiant public, migration depuis local.claudenotch, dossiers protégés.
final class IdentityTests: XCTestCase {
    private static let executable = "/Applications/Oriel.app/Contents/MacOS/Oriel"

    // MARK: - Identifiant unique

    func testIdentifierIsTheSameEverywhere() throws {
        XCTAssertEqual(AppIdentity.bundleId, "io.github.slybald.oriel")
        let plistData = try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        XCTAssertEqual(plist?["CFBundleIdentifier"] as? String, AppIdentity.bundleId)

        let hook = try String(contentsOf: repositoryRoot.appendingPathComponent("hooks/oriel-hook.sh"), encoding: .utf8)
        XCTAssertTrue(hook.contains("open -g -b \(AppIdentity.bundleId) "))
        XCTAssertFalse(hook.contains(AppIdentity.legacyBundleId))

        let install = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
        XCTAssertTrue(install.contains("LABEL=\(AppIdentity.bundleId)\n"))
        let uninstall = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/uninstall.sh"), encoding: .utf8)
        XCTAssertTrue(uninstall.contains(AppIdentity.bundleId))
        XCTAssertEqual(LaunchAgent.label, AppIdentity.bundleId)
    }

    // MARK: - LaunchAgent

    private func agent(_ directory: URL, _ label: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: LaunchAgent.plistURL(label: label, in: directory)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    func testLegacyAgentIsReplaced() throws {
        let dir = try makeTemporaryDirectory(self)
        let legacy = LaunchAgent.plistURL(label: "local.claudenotch", in: dir)
        try Data("<plist/>".utf8).write(to: legacy)

        XCTAssertTrue(LaunchAgent.migrateLegacy(in: dir, executable: Self.executable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let plist = try XCTUnwrap(agent(dir, AppIdentity.bundleId))
        XCTAssertEqual(plist["Label"] as? String, AppIdentity.bundleId)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [Self.executable])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")

        // Deuxième passage : plus rien à migrer, le nouveau plist reste.
        XCTAssertFalse(LaunchAgent.migrateLegacy(in: dir, executable: Self.executable))
        XCTAssertNotNil(agent(dir, AppIdentity.bundleId))
    }

    func testNoLegacyAgentMeansNoNewAgent() throws {
        let dir = try makeTemporaryDirectory(self)
        XCTAssertFalse(LaunchAgent.migrateLegacy(in: dir, executable: Self.executable))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [],
                       "« Lancer à l'ouverture de session » était décoché : rien à créer")
    }

    func testLegacyAgentWithoutExecutableIsLeftAlone() throws {
        let dir = try makeTemporaryDirectory(self)
        let legacy = LaunchAgent.plistURL(label: "local.claudenotch", in: dir)
        try Data("<plist/>".utf8).write(to: legacy)
        XCTAssertFalse(LaunchAgent.migrateLegacy(in: dir, executable: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testDisablingRemovesBothAgents() throws {
        let dir = try makeTemporaryDirectory(self)
        LaunchAgent.setEnabled(true, in: dir, executable: Self.executable)
        XCTAssertNotNil(agent(dir, AppIdentity.bundleId))
        try Data("<plist/>".utf8).write(to: LaunchAgent.plistURL(label: "local.claudenotch", in: dir))
        LaunchAgent.setEnabled(false, in: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    // MARK: - Emplacement de l'app

    func testApplicationsFolderDetection() {
        let home = "/Users/me"
        XCTAssertTrue(AppIdentity.isInApplicationsFolder("/Applications/Oriel.app", home: home))
        XCTAssertTrue(AppIdentity.isInApplicationsFolder("/Applications/Outils/Oriel.app", home: home))
        XCTAssertTrue(AppIdentity.isInApplicationsFolder("/Users/me/Applications/Oriel.app", home: home))
        XCTAssertTrue(AppIdentity.isInApplicationsFolder("/applications/Oriel.app/", home: home))
        XCTAssertFalse(AppIdentity.isInApplicationsFolder("/Volumes/Oriel/Oriel.app", home: home))
        XCTAssertFalse(AppIdentity.isInApplicationsFolder(
            "/private/var/folders/ab/cd/T/AppTranslocation/1F2E/d/Oriel.app", home: home))
        XCTAssertFalse(AppIdentity.isInApplicationsFolder("/Users/me/Downloads/Oriel.app", home: home))
        XCTAssertFalse(AppIdentity.isInApplicationsFolder("/ApplicationsX/Oriel.app", home: home))
        XCTAssertFalse(AppIdentity.isInApplicationsFolder("/Users/other/Applications/Oriel.app", home: home))
    }

    // MARK: - Dossiers protégés

    func testProtectedFolders() {
        let home = "/Users/me"
        XCTAssertTrue(ProtectedFolders.contains("/Users/me/Documents/projet/a.swift", home: home))
        XCTAssertTrue(ProtectedFolders.contains("/Users/me/Desktop/notes.md", home: home))
        XCTAssertTrue(ProtectedFolders.contains("/Users/me/Downloads/cours.pdf", home: home))
        XCTAssertTrue(ProtectedFolders.contains("/Users/me/documents/a", home: home), "disque insensible à la casse")
        XCTAssertFalse(ProtectedFolders.contains("/Users/me/Documents", home: home), "le dossier lui-même n'est pas protégé")
        XCTAssertFalse(ProtectedFolders.contains("/Users/me/Projets/a", home: home))
        XCTAssertFalse(ProtectedFolders.contains("/Users/me/DocumentsX/a", home: home))
        XCTAssertFalse(ProtectedFolders.contains("/tmp/Documents/a", home: home))
    }

    /// Sans Accès complet au disque, jamais de sonde dans Documents, Bureau, Téléchargements  ;
    /// avec l'accès, le disque est regardé comme avant.
    func testProtectedFoldersProbedOnlyWithFullDiskAccess() throws {
        do {
            // Home fictif hors des dossiers temporaires (le fil de ToolsFeed les écarte). Plus aucun outil à installer :
            // la règle ne dépend plus de ~/.local/share.
            let home = URL(fileURLWithPath: "/Users/x")
            let inside = ["Documents", "Desktop", "Downloads"].map { home.appendingPathComponent("\($0)/projet/a.swift").path }
            var probed: [String] = []
            let spy: (String) -> Bool = { probed.append($0); return false }

            // ProtectedFolders, ActivityLog et ToolsFeed (via un registre qui cite ces chemins).
            for path in inside { XCTAssertTrue(ProtectedFolders.exists(path, home: home, hasFullDiskAccess: { false }, disk: spy)) }
            for path in inside {
                _ = ActivityLog.projectName(forFile: path, cwd: "/elsewhere", home: home, hasFullDiskAccess: { false }, disk: spy)
            }
            let fixtures = try ToolsFixtures()
            try fixtures.writeLines(inside.map { ToolsFixtures.fileLine($0, ago: 5, now: Date(), project: "p") },
                                    to: fixtures.paths.files)
            let feed = ToolsFeed(paths: fixtures.paths, home: home, hasFullDiskAccess: { false }, disk: spy)
            feed.refreshNow()
            XCTAssertEqual(feed.recentFiles.count, 3)
            XCTAssertTrue(feed.recentFiles.allSatisfy(\.exists))
            XCTAssertEqual(probed, [])

            // Accès complet accordé : le disque est consulté.
            XCTAssertFalse(ProtectedFolders.exists(inside[0], home: home, hasFullDiskAccess: { true }, disk: spy))
            XCTAssertEqual(probed, [inside[0]])
            let granted = ToolsFeed(paths: fixtures.paths, home: home, hasFullDiskAccess: { true }, disk: spy)
            granted.refreshNow()
            XCTAssertTrue(granted.recentFiles.allSatisfy { !$0.exists })
            XCTAssertFalse(ProtectedFolders.exists(home.appendingPathComponent("Projets/a").path, home: home,
                                                   hasFullDiskAccess: { false }, disk: spy), "hors dossiers protégés")
        }
    }

    /// La sonde d'accès est faite une fois, et jamais si aucun chemin n'est dans un dossier protégé.
    func testAccessProbeRunsOnceAndOnlyWhenNeeded() {
        let home = URL(fileURLWithPath: "/Users/x")
        var count = 0
        let access = AccessProbe { count += 1; return false }
        for _ in 0..<100 { _ = ProtectedFolders.exists("/Users/x/Projets/a", home: home, hasFullDiskAccess: { access.granted }, disk: { _ in true }) }
        XCTAssertEqual(count, 0)
        for i in 0..<100 {
            let path = i % 2 == 0 ? "/Users/x/Downloads/a\(i)" : "/Users/x/Projets/a\(i)"
            _ = ProtectedFolders.exists(path, home: home, hasFullDiskAccess: { access.granted }, disk: { _ in true })
            _ = ActivityLog.projectName(forFile: path, cwd: "/elsewhere", home: home, hasFullDiskAccess: { access.granted }, disk: { _ in false })
        }
        XCTAssertEqual(count, 1)
    }
}
