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

    func testProtectedFoldersNeedACompanionTool() throws {
        let home = try makeTemporaryDirectory(self)
        let inside = home.appendingPathComponent("Documents/projet/a.swift").path
        XCTAssertFalse(ProtectedFolders.mayAccess(inside, home: home))
        XCTAssertTrue(ProtectedFolders.mayAccess(home.appendingPathComponent("Projets/a.swift").path, home: home))

        let tool = home.appendingPathComponent(".local/share/git-radar/git_radar.py")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: tool)
        XCTAssertTrue(ProtectedFolders.mayAccess(inside, home: home))
    }

    /// Sans course-sorter, Téléchargements n'est jamais ouvert ; avec, il est surveillé.
    func testDownloadsWatchedOnlyWithCourseSorter() throws {
        let home = try makeTemporaryDirectory(self)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Downloads"),
                                                withIntermediateDirectories: true)
        let without = JobRunner(home: home)
        without.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(without.debugSummary["watchingDownloads"] as? Bool, false)

        let script = home.appendingPathComponent(".local/share/course-sorter/course_sorter.py")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: script)
        let with = JobRunner(home: home)
        with.start()
        let deadline = Date().addingTimeInterval(3)
        while with.debugSummary["watchingDownloads"] as? Bool != true, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(with.debugSummary["watchingDownloads"] as? Bool, true)
    }
}
