import CryptoKit
import XCTest
@testable import Oriel

/// Mise à jour automatique : logique pure, puis fichiers dans des dossiers temporaires.
/// Aucun accès réseau, rien n'est lu ni écrit dans /Applications.
final class UpdaterTests: XCTestCase {
    typealias Release = Updater.Release

    /// Réponse de /repos/…/releases/latest, au format de l'API GitHub (valeurs fictives).
    static let releaseJSON = #"""
    {
      "url": "https://api.github.com/repos/Slybald/oriel/releases/250000001",
      "assets_url": "https://api.github.com/repos/Slybald/oriel/releases/250000001/assets",
      "upload_url": "https://uploads.github.com/repos/Slybald/oriel/releases/250000001/assets{?name,label}",
      "html_url": "https://github.com/Slybald/oriel/releases/tag/v1.2.0",
      "id": 250000001,
      "author": {"login": "github-actions[bot]", "id": 41898282, "type": "Bot", "site_admin": false},
      "node_id": "RE_kwDOExample",
      "tag_name": "v1.2.0",
      "target_commitish": "main",
      "name": "Oriel 1.2.0",
      "draft": false,
      "immutable": false,
      "prerelease": false,
      "created_at": "2026-11-02T09:12:44Z",
      "updated_at": "2026-11-02T09:20:03Z",
      "published_at": "2026-11-02T09:20:03Z",
      "assets": [
        {
          "url": "https://api.github.com/repos/Slybald/oriel/releases/assets/300000001",
          "id": 300000001,
          "name": "Oriel-1.2.0.dmg",
          "label": "",
          "content_type": "application/x-apple-diskimage",
          "state": "uploaded",
          "size": 2411520,
          "digest": "sha256:0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
          "download_count": 12,
          "browser_download_url": "https://github.com/Slybald/oriel/releases/download/v1.2.0/Oriel-1.2.0.dmg"
        },
        {
          "url": "https://api.github.com/repos/Slybald/oriel/releases/assets/300000002",
          "id": 300000002,
          "name": "Oriel-1.2.0.dmg.sha256",
          "label": "",
          "content_type": "application/octet-stream",
          "state": "uploaded",
          "size": 88,
          "download_count": 3,
          "browser_download_url": "https://github.com/Slybald/oriel/releases/download/v1.2.0/Oriel-1.2.0.dmg.sha256"
        },
        {
          "url": "https://api.github.com/repos/Slybald/oriel/releases/assets/300000003",
          "id": 300000003,
          "name": "Oriel-1.2.0.dmg.sig",
          "label": null,
          "content_type": "application/octet-stream",
          "state": "uploaded",
          "size": 89,
          "download_count": 12,
          "browser_download_url": "https://github.com/Slybald/oriel/releases/download/v1.2.0/Oriel-1.2.0.dmg.sig"
        }
      ],
      "tarball_url": "https://api.github.com/repos/Slybald/oriel/tarball/v1.2.0",
      "zipball_url": "https://api.github.com/repos/Slybald/oriel/zipball/v1.2.0",
      "body": "## What's Changed\n* feat: something by @someone"
    }
    """#

    private func release(tag: String = "v1.2.0", draft: Bool = false, prerelease: Bool = false,
                         assets: [Release.Asset]? = nil) throws -> Release {
        let base = try Updater.decodeRelease(Data(Self.releaseJSON.utf8))
        return Release(tagName: tag, htmlUrl: base.htmlUrl, draft: draft, prerelease: prerelease,
                       assets: assets ?? base.assets)
    }

    // MARK: - Versions

    /// Au réveil : vérification seulement si la dernière date de plus de 6 h (veille comprise).
    func testWakeCheckOnlyWhenOverdue() {
        let now = Date()
        XCTAssertFalse(Updater.isOverdue(lastCheck: nil, now: now), "pas encore de vérification : celle du lancement")
        XCTAssertFalse(Updater.isOverdue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(Updater.isOverdue(lastCheck: now.addingTimeInterval(-Updater.checkInterval), now: now))
        XCTAssertTrue(Updater.isOverdue(lastCheck: now.addingTimeInterval(-16 * 3600), now: now), "une nuit de veille")
    }

    func testVersionComparison() {
        XCTAssertEqual(Updater.compareVersions("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(Updater.compareVersions("v1.2.0", "1.2"), .orderedSame)
        XCTAssertEqual(Updater.compareVersions("1.1.0", "1.0.9"), .orderedDescending)
        XCTAssertEqual(Updater.compareVersions("1.10", "1.9"), .orderedDescending, "numérique, pas lexical")
        XCTAssertEqual(Updater.compareVersions("2", "10"), .orderedAscending)
        XCTAssertEqual(Updater.compareVersions("1.0.1", "1.0"), .orderedDescending)
        XCTAssertEqual(Updater.compareVersions("1.0", "1.0.1"), .orderedAscending)
        XCTAssertEqual(Updater.versionComponents("v1.2.3"), [1, 2, 3])
        for invalid in ["", "v", "1..2", "1.2.", ".1", "1.2-beta", "1.2/../x", "١.٢", "v1.2.3.x", "1.0000000000", "nightly"] {
            XCTAssertNil(Updater.versionComponents(invalid), invalid)
            XCTAssertNil(Updater.compareVersions(invalid, "1.0"), invalid)
        }
    }

    // MARK: - Release et fichiers à télécharger

    func testAssetsFromRealisticRelease() throws {
        let release = try Updater.decodeRelease(Data(Self.releaseJSON.utf8))
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertFalse(release.draft)
        XCTAssertFalse(release.prerelease)
        XCTAssertEqual(release.htmlUrl.absoluteString, "https://github.com/Slybald/oriel/releases/tag/v1.2.0")
        let assets = try Updater.updateAssets(in: release)
        XCTAssertEqual(assets.dmg.absoluteString,
                       "https://github.com/Slybald/oriel/releases/download/v1.2.0/Oriel-1.2.0.dmg")
        XCTAssertEqual(assets.signature.absoluteString,
                       "https://github.com/Slybald/oriel/releases/download/v1.2.0/Oriel-1.2.0.dmg.sig")
    }

    func testMissingOrUnsafeAssetsAreRefused() throws {
        let all = try release().assets
        XCTAssertThrowsError(try Updater.updateAssets(in: release(assets: all.filter { !$0.name.hasSuffix(".sig") }))) {
            XCTAssertEqual($0 as? UpdateError, .missingSignature)
        }
        XCTAssertThrowsError(try Updater.updateAssets(in: release(assets: all.filter { !$0.name.hasSuffix(".dmg") }))) {
            XCTAssertEqual($0 as? UpdateError, .missingAsset("Oriel-1.2.0.dmg"))
        }
        // Les fichiers d'une autre version ne comptent pas.
        XCTAssertThrowsError(try Updater.updateAssets(in: release(tag: "v1.3.0"))) {
            XCTAssertEqual($0 as? UpdateError, .missingAsset("Oriel-1.3.0.dmg"))
        }
        // Signature servie en HTTP : refusée comme absente.
        let insecure = all.map { asset in
            asset.name.hasSuffix(".sig")
                ? Release.Asset(name: asset.name, browserDownloadUrl: URL(string: "http://example.com/x.sig")!)
                : asset
        }
        XCTAssertThrowsError(try Updater.updateAssets(in: release(assets: insecure))) {
            XCTAssertEqual($0 as? UpdateError, .missingSignature)
        }
        XCTAssertThrowsError(try Updater.decodeRelease(Data(#"{"message": "Not Found"}"#.utf8))) {
            XCTAssertEqual($0 as? UpdateError, .invalidRelease)
        }
    }

    // MARK: - Signature

    func testSignatureVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let dmg = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let signature = try key.signature(for: dmg).base64EncodedString()

        XCTAssertTrue(Updater.isValidSignature(signature, for: dmg, publicKey: publicKey))
        XCTAssertTrue(Updater.isValidSignature(signature + "\n", for: dmg, publicKey: publicKey), "sortie de `print`")

        var tampered = dmg
        tampered[40_000] ^= 0x01
        XCTAssertFalse(Updater.isValidSignature(signature, for: tampered, publicKey: publicKey), "DMG falsifié")
        XCTAssertFalse(Updater.isValidSignature(signature, for: dmg + Data([0]), publicKey: publicKey), "octet ajouté")

        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(Updater.isValidSignature(signature, for: dmg, publicKey: otherKey), "mauvaise clé")
        XCTAssertFalse(Updater.isValidSignature(signature, for: dmg), "clé intégrée : signature de test refusée")
        XCTAssertFalse(Updater.isValidSignature("", for: dmg, publicKey: publicKey))
        XCTAssertFalse(Updater.isValidSignature("pas du base64 !", for: dmg, publicKey: publicKey))
        XCTAssertFalse(Updater.isValidSignature(signature, for: dmg, publicKey: "AAAA"), "clé tronquée")

        let embedded = try XCTUnwrap(Data(base64Encoded: Updater.publicKey))
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: embedded))
    }

    // MARK: - Décision

    func testDecision() throws {
        let newer = try release()
        func decide(_ release: Release? = nil, current: String = "1.1.0", channel: Bool = true, auto: Bool = true,
                    installable: Bool = true, busy: Bool = false, atLaunch: Bool = false) -> Updater.Decision {
            Updater.decide(release: release ?? newer, currentVersion: current, releaseChannel: channel,
                           autoUpdate: auto, installable: installable, busy: busy, atLaunch: atLaunch)
        }
        XCTAssertEqual(decide(), .install)
        // Canal : un build de développement ne se met jamais à jour.
        XCTAssertEqual(decide(channel: false), .disabled)
        XCTAssertEqual(decide(channel: false, atLaunch: true), .disabled)
        // Versions.
        XCTAssertEqual(decide(current: "1.2"), .upToDate)
        XCTAssertEqual(decide(current: "1.3.0"), .upToDate)
        XCTAssertEqual(decide(try release(tag: "nightly")), .upToDate)
        XCTAssertEqual(decide(try release(draft: true)), .upToDate)
        XCTAssertEqual(decide(try release(prerelease: true)), .upToDate)
        // Préférence et emplacement : seulement signalée.
        XCTAssertEqual(decide(auto: false), .offer)
        XCTAssertEqual(decide(installable: false), .offer)
        XCTAssertEqual(decide(auto: false, busy: true, atLaunch: true), .offer)
        XCTAssertEqual(decide(installable: false, busy: true), .offer)
        // Sessions occupées : on attend, sauf au lancement.
        XCTAssertEqual(decide(busy: true), .wait)
        XCTAssertEqual(decide(busy: true, atLaunch: true), .install)
        XCTAssertEqual(decide(atLaunch: true), .install)
    }

    func testInstallLocation() throws {
        let home = try makeTemporaryDirectory(self)
        let applications = home.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let app = applications.appendingPathComponent("Oriel.app").path
        XCTAssertTrue(Updater.canInstall(bundlePath: app, home: home.path))

        // Ni depuis le DMG, ni depuis une copie translocalisée, ni hors d'un dossier Applications.
        XCTAssertFalse(Updater.canInstall(bundlePath: "/Volumes/Oriel/Oriel.app", home: home.path))
        XCTAssertFalse(Updater.canInstall(
            bundlePath: "/private/var/folders/ab/cd/T/AppTranslocation/1234/d/Oriel.app", home: home.path))
        XCTAssertFalse(Updater.canInstall(bundlePath: home.appendingPathComponent("Apps/Oriel.app").path,
                                          home: home.path))

        // Dossier non inscriptible.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications.path) }
        XCTAssertFalse(Updater.canInstall(bundlePath: app, home: home.path))
    }

    // MARK: - Bundles

    func testValidateBundle() throws {
        let folder = try makeTemporaryDirectory(self)
        let app = try makeApp(in: folder, version: "1.2.0")
        XCTAssertNoThrow(try Updater.validateBundle(app, bundleId: AppIdentity.bundleId, version: "1.2.0"))
        XCTAssertNoThrow(try Updater.validateBundle(app, bundleId: AppIdentity.bundleId, version: "1.2"))
        for (bundleId, version) in [(AppIdentity.bundleId, "1.3.0"), (AppIdentity.legacyBundleId, "1.2.0")] {
            XCTAssertThrowsError(try Updater.validateBundle(app, bundleId: bundleId, version: version)) {
                XCTAssertEqual($0 as? UpdateError, .wrongBundle)
            }
        }
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/MacOS/Oriel"))
        XCTAssertThrowsError(try Updater.validateBundle(app, bundleId: AppIdentity.bundleId, version: "1.2.0"))
        XCTAssertThrowsError(try Updater.validateBundle(folder.appendingPathComponent("absente.app"),
                                                        bundleId: AppIdentity.bundleId, version: "1.2.0"))
    }

    func testSwapBundlesReplacesTheApp() throws {
        let folder = try makeTemporaryDirectory(self)
        let current = try makeApp(in: folder, version: "1.1.0")
        let staged = try makeApp(in: folder.appendingPathComponent(".Oriel-update"), version: "1.2.0")
        // Reste d'une mise à jour précédente : remplacé.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".Oriel-old.app/Contents"),
                                                withIntermediateDirectories: true)

        try Updater.swapBundles(current: current, replacement: staged)
        XCTAssertEqual(try version(of: current), "1.2.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".Oriel-old.app").path))
    }

    func testSwapBundlesRollsBackWhenTheSecondRenameFails() throws {
        let folder = try makeTemporaryDirectory(self)
        let current = try makeApp(in: folder, version: "1.1.0")
        let missing = folder.appendingPathComponent(".Oriel-update/\(AppIdentity.bundleName)")

        XCTAssertThrowsError(try Updater.swapBundles(current: current, replacement: missing))
        XCTAssertEqual(try version(of: current), "1.1.0", "l'ancienne app est revenue à sa place")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: current.appendingPathComponent("Contents/MacOS/Oriel").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".Oriel-old.app").path))
    }

    /// Chaîne complète sur une vraie image disque : hdiutil attach, ditto, detach, échange.
    func testInstallUpdateFromDiskImage() throws {
        let root = try makeTemporaryDirectory(self)
        let volume = root.appendingPathComponent("volume")
        _ = try makeApp(in: volume, version: "1.2.0")
        let dmg = root.appendingPathComponent("Oriel-1.2.0.dmg")
        try Updater.run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Oriel Test", "-srcfolder", volume.path,
                                             "-fs", "HFS+", "-format", "UDZO", "-ov", dmg.path])
        let applications = root.appendingPathComponent("Applications")
        let installed = try makeApp(in: applications, version: "1.1.0")

        // Version annoncée différente de celle du DMG : refus, rien ne bouge.
        XCTAssertThrowsError(try Updater.installUpdate(dmg: dmg, version: "1.3.0", over: installed)) {
            XCTAssertEqual($0 as? UpdateError, .wrongBundle)
        }
        XCTAssertEqual(try version(of: installed), "1.1.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), [AppIdentity.bundleName])

        try Updater.installUpdate(dmg: dmg, version: "1.2.0", over: installed)
        XCTAssertEqual(try version(of: installed), "1.2.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), [AppIdentity.bundleName],
                       "ni dossier de copie ni ancienne app oubliés")
        // Dossier unique du test (hdiutil info affiche le chemin résolu, /private/var/…).
        XCTAssertFalse(try mountedImages().contains(root.lastPathComponent), "image démontée")
    }

    /// Relais de relance : il attend la fin du processus visé, tourne dans sa propre session et n'hérite
    /// d'aucun de nos descripteurs (sinon il garderait le port des hooks).
    func testDetachedRelayWaitsInItsOwnSession() throws {
        let folder = try makeTemporaryDirectory(self)
        let output = folder.appendingPathComponent("relais.txt")
        // Descripteur sans FD_CLOEXEC, placé au-delà de ceux qu'ouvre ls : il ne doit pas passer au relais.
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let inherited = fcntl(fds[0], F_DUPFD, 64)
        defer { (fds + [inherited]).forEach { close($0) } }
        XCTAssertGreaterThanOrEqual(inherited, 64)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.5"]
        try sleeper.run()

        let script = "while /bin/kill -0 \(sleeper.processIdentifier) 2>/dev/null; do /bin/sleep 0.05; done; "
            + #"echo "$$ $(/bin/ps -o pgid= -p $$) $(/bin/ls /dev/fd | /usr/bin/tr '\n' ' ')" > "$0.tmp" && /bin/mv "$0.tmp" "$0""#
        let relay = try Updater.spawnDetached(["/bin/sh", "-c", script, output.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "le relais attend")
        sleeper.waitUntilExit()

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: output.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        var status: Int32 = 0
        waitpid(relay, &status, 0)
        let fields = try String(contentsOf: output, encoding: .utf8).split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertGreaterThanOrEqual(fields.count, 2, fields.joined(separator: " "))
        XCTAssertEqual(fields.first, String(relay))
        XCTAssertEqual(fields.dropFirst().first, String(relay), "chef de son propre groupe (setsid)")
        XCTAssertNotEqual(fields.dropFirst().first, String(getpgrp()))
        // 0, 1, 2 (/dev/null) et les deux descripteurs que ls ouvre lui-même (3, 4) : rien d'autre.
        XCTAssertEqual(Set(fields.dropFirst(2)).subtracting(["0", "1", "2", "3", "4"]), [], fields.joined(separator: " "))
    }

    // MARK: - Outils

    /// App minimale (Oriel.app par défaut) : Info.plist et exécutable.
    @discardableResult
    private func makeApp(in folder: URL, version: String, name: String = AppIdentity.bundleName) throws -> URL {
        let app = folder.appendingPathComponent(name)
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": AppIdentity.bundleId, "CFBundleShortVersionString": version,
                                   "CFBundleExecutable": "Oriel"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Oriel")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    private func version(of app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return info?["CFBundleShortVersionString"] as? String
    }

    private func mountedImages() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
