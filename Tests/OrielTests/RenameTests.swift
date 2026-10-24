import CryptoKit
import Darwin
import XCTest
@testable import ClaudeNotch

/// Renommage Claude Notch → Oriel : une app 1.8.0 installée reçoit Oriel par sa mise à jour
/// automatique, sans doublon, sans perdre son LaunchAgent ni les messages des sessions déjà ouvertes.
final class RenameTests: XCTestCase {
    private static let legacyName = "ClaudeNotch"
    private static let legacyPath = "/repos/Slybald/claude-notch/releases/latest"
    private static let redirectedPath = "/repositories/1425705848/releases/latest"

    // MARK: - Dépôt renommé

    /// Après `gh repo rename`, l'API répond 301 à l'ancienne adresse (celle des apps 1.1.0 à 1.8.0) : la requête
    /// d'Updater la suit, sur un vrai serveur HTTP local.
    func testLatestReleaseFollowsRepositoryRename() async throws {
        let server = try LocalServer(connections: 2) { path, port in
            switch path {
            case Self.legacyPath:
                let location = "http://127.0.0.1:\(port)\(Self.redirectedPath)"
                return Self.response("301 Moved Permanently", body: #"{"message":"Moved Permanently","url":"\#(location)"}"#,
                                     headers: "Location: \(location)\r\n")
            case Self.redirectedPath:
                return Self.response("200 OK", body: Self.releaseJSON("1.9.0"))
            default:
                return Self.response("404 Not Found", body: #"{"message":"Not Found"}"#)
            }
        }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)\(Self.legacyPath)"))
        let release = try await Updater.fetchLatestRelease(from: url, userAgentVersion: "1.8.0")
        XCTAssertEqual(release.version, "1.9.0")
        XCTAssertEqual(server.paths, [Self.legacyPath, Self.redirectedPath])
    }

    // MARK: - Chaîne 1.8.0 → Oriel

    /// Updater 1.8.0 (mêmes fonctions, anciens noms), vraie image disque, premier lancement, puis mise à jour suivante
    /// par l'Updater d'Oriel.
    func testLegacyUpdaterInstallsTheRenamedApp() throws {
        let root = try makeTemporaryDirectory(self)
        let home = root.appendingPathComponent("home")
        let applications = home.appendingPathComponent("Applications")
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        let installed = try makeApp(in: applications, name: AppIdentity.legacyBundleName, version: "1.8.0")
        LaunchAgent.setEnabled(true, in: agents, executable: executable(of: installed))
        let key = Curve25519.Signing.PrivateKey()

        // 1. L'Updater 1.8.0 installe la 1.9.0, depuis ClaudeNotch-1.9.0.dmg.
        let release = try Updater.decodeRelease(Data(Self.releaseJSON("1.9.0").utf8))
        XCTAssertEqual(Updater.decide(release: release, currentVersion: "1.8.0", releaseChannel: true, autoUpdate: true,
                                      installable: true, busy: false, atLaunch: true), .install)
        let assets = try Updater.updateAssets(in: release, appName: Self.legacyName)
        XCTAssertEqual(assets.dmg.lastPathComponent, "ClaudeNotch-1.9.0.dmg")
        XCTAssertEqual(assets.signature.lastPathComponent, "ClaudeNotch-1.9.0.dmg.sig")
        let legacyImage = try makeImage(appName: Self.legacyName, version: "1.9.0", in: root)
        let data = try Data(contentsOf: legacyImage)
        XCTAssertTrue(Updater.isValidSignature(try key.signature(for: data).base64EncodedString(), for: data,
                                               publicKey: key.publicKey.rawRepresentation.base64EncodedString()))
        try Updater.installUpdate(dmg: legacyImage, version: "1.9.0", over: installed,
                                  bundleName: AppIdentity.legacyBundleName)
        XCTAssertEqual(AppIdentity.bundleInfo(installed)?.version, "1.9.0")

        // 2. Premier lancement : Oriel.app, LaunchAgent repointé, plus aucune ClaudeNotch.app.
        let oriel = try XCTUnwrap(AppIdentity.adoptNewBundleName(installed, home: home.path, launchAgents: agents,
                                                                 discard: { XCTFail("rien à jeter : \($0.path)") }))
        XCTAssertEqual(oriel.path, applications.appendingPathComponent(AppIdentity.bundleName).path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), [AppIdentity.bundleName])
        XCTAssertEqual(program(agents), [executable(of: oriel)])
        XCTAssertNil(AppIdentity.adoptNewBundleName(oriel, home: home.path, launchAgents: agents), "idempotent")

        // 3. Mise à jour suivante, par l'Updater d'Oriel : Oriel-1.10.0.dmg, installée à la même place.
        let next = try Updater.decodeRelease(Data(Self.releaseJSON("1.10.0").utf8))
        XCTAssertEqual(try Updater.updateAssets(in: next).dmg.lastPathComponent, "Oriel-1.10.0.dmg")
        try Updater.installUpdate(dmg: try makeImage(appName: AppIdentity.name, version: "1.10.0", in: root),
                                  version: "1.10.0", over: oriel)
        XCTAssertEqual(AppIdentity.bundleInfo(oriel)?.version, "1.10.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), [AppIdentity.bundleName])
        XCTAssertEqual(program(agents), [executable(of: oriel)])
    }

    // MARK: - Premier lancement sous l'ancien nom

    func testAdoptNewBundleNameOnlyInApplications() throws {
        let home = try makeTemporaryDirectory(self)
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        let elsewhere = try makeApp(in: home.appendingPathComponent("Downloads"), name: AppIdentity.legacyBundleName,
                                    version: "1.9.0")
        XCTAssertNil(AppIdentity.adoptNewBundleName(elsewhere, home: home.path, launchAgents: agents))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path), "hors Applications : rien ne bouge")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.path), "aucun LaunchAgent créé")

        // Lancement à l'ouverture de session décoché : le renommage n'en crée pas.
        let applications = home.appendingPathComponent("Applications")
        let legacy = try makeApp(in: applications, name: AppIdentity.legacyBundleName, version: "1.9.0")
        XCTAssertNotNil(AppIdentity.adoptNewBundleName(legacy, home: home.path, launchAgents: agents))
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.path))
    }

    /// Un Oriel.app est déjà là : d'un autre éditeur, rien ne bouge ; le nôtre, le plus récent des deux reste.
    func testAdoptNewBundleNameWithAnExistingOriel() throws {
        let home = try makeTemporaryDirectory(self)
        let applications = home.appendingPathComponent("Applications")
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        var discarded: [String] = []
        let discard: (URL) throws -> Void = {
            discarded.append($0.lastPathComponent)
            try FileManager.default.removeItem(at: $0)
        }
        let legacy = try makeApp(in: applications, name: AppIdentity.legacyBundleName, version: "1.9.0")

        let stranger = try makeApp(in: applications, name: AppIdentity.bundleName, version: "4.0",
                                   bundleId: "com.example.oriel")
        XCTAssertNil(AppIdentity.adoptNewBundleName(legacy, home: home.path, launchAgents: agents, discard: discard))
        XCTAssertEqual(AppIdentity.bundleInfo(stranger)?.id, "com.example.oriel")
        XCTAssertEqual(AppIdentity.bundleInfo(legacy)?.version, "1.9.0")
        try FileManager.default.removeItem(at: stranger)

        // Oriel.app plus récent (ou égal) : il prend la place, sans rien déplacer ici ; il retirera l'ancienne.
        let newer = try makeApp(in: applications, name: AppIdentity.bundleName, version: "1.10.0")
        XCTAssertEqual(AppIdentity.adoptNewBundleName(legacy, home: home.path, launchAgents: agents, discard: discard)?.path,
                       newer.path)
        XCTAssertEqual(discarded, [])
        XCTAssertEqual(AppIdentity.bundleInfo(legacy)?.version, "1.9.0")

        // Oriel.app plus ancien : jeté, puis renommage.
        try FileManager.default.removeItem(at: newer)
        _ = try makeApp(in: applications, name: AppIdentity.bundleName, version: "1.8.5")
        let renamed = AppIdentity.adoptNewBundleName(legacy, home: home.path, launchAgents: agents, discard: discard)
        XCTAssertEqual(renamed?.path, applications.appendingPathComponent(AppIdentity.bundleName).path)
        XCTAssertEqual(discarded, [AppIdentity.bundleName])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), [AppIdentity.bundleName])
        XCTAssertEqual(renamed.flatMap(AppIdentity.bundleInfo)?.version, "1.9.0")
    }

    // MARK: - Oriel installée à la main à côté de l'ancienne

    func testRetireLegacyBundles() throws {
        let root = try makeTemporaryDirectory(self)
        let system = root.appendingPathComponent("Applications")
        let user = root.appendingPathComponent("home/Applications")
        let discard: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
        try makeApp(in: system, name: AppIdentity.bundleName, version: "1.9.0")
        let older = try makeApp(in: system, name: AppIdentity.legacyBundleName, version: "1.8.0")
        let newer = try makeApp(in: user, name: AppIdentity.legacyBundleName, version: "1.10.0")

        XCTAssertEqual(AppIdentity.retireLegacyBundles(version: "1.9.0", folders: [system, user], discard: discard)
            .map(\.path), [older.path])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: system.path), [AppIdentity.bundleName])
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path), "plus récente : elle se renommera elle-même")
        XCTAssertEqual(AppIdentity.retireLegacyBundles(version: "1.9.0", folders: [system, user], discard: discard), [],
                       "idempotent")

        // Même nom, autre app : jamais touchée.
        try FileManager.default.removeItem(at: newer)
        let stranger = try makeApp(in: user, name: AppIdentity.legacyBundleName, version: "1.0", bundleId: "com.example.x")
        XCTAssertEqual(AppIdentity.retireLegacyBundles(version: "1.9.0", folders: [system, user], discard: discard), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
    }

    func testLaunchAgentFollowsTheBundle() throws {
        let agents = try makeTemporaryDirectory(self)
        let old = "/Applications/ClaudeNotch.app/Contents/MacOS/ClaudeNotch"
        let new = "/Applications/Oriel.app/Contents/MacOS/ClaudeNotch"
        XCTAssertFalse(LaunchAgent.refresh(in: agents, executable: new))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: agents.path), [], "option décochée : rien")

        LaunchAgent.setEnabled(true, in: agents, executable: old)
        XCTAssertTrue(LaunchAgent.refresh(in: agents, executable: new))
        XCTAssertEqual(program(agents), [new])
        XCTAssertFalse(LaunchAgent.refresh(in: agents, executable: new), "idempotent")
    }

    // MARK: - Hooks et textes

    /// Une session Claude ouverte avant la mise à jour garde ses hooks d'alors : son message reste reconnu.
    func testNotchMessageFromBeforeTheRename() {
        for (summary, message) in [(HookInstaller.rewakeSummary, HookInstaller.rewakeMessage),
                                   (HookInstaller.legacyRewakeSummary, HookInstaller.legacyRewakeMessage)] {
            let prompt = "<task-notification>\n<summary>\(summary)</summary>\n</task-notification>\n"
                + "<system-reminder>\n\(message) Lance les tests</system-reminder>"
            let event = HookEvent(raw: ["hook_event_name": "UserPromptSubmit", "prompt": prompt])
            XCTAssertEqual(event.notchMessage, "Lance les tests", summary)
        }
        XCTAssertEqual(HookInstaller.rewakeSummary, "Message from Oriel")
    }

    /// Nouveau nom affiché, identifiant inchangé (autorisations, réglages, Updater des anciennes versions).
    func testDisplayedNameIsOriel() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, AppIdentity.name)
        XCTAssertEqual(plist["CFBundleName"] as? String, AppIdentity.name)
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "io.github.slybald.claudenotch")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "ClaudeNotch", "exécutable vérifié par make-dmg.sh")
        for (key, value) in plist {
            XCTAssertFalse("\(value)".contains("Claude Notch"), key)
        }

        // Aucun texte de l'interface ne garde l'ancien nom (commentaires des fichiers .strings exceptés).
        let resources = repositoryRoot.appendingPathComponent("Resources")
        for language in ["en", "fr"] {
            let folder = resources.appendingPathComponent("\(language).lproj")
            for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                let url = folder.appendingPathComponent(file)
                let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], file)
                for (key, value) in table {
                    XCTAssertFalse(key.contains("Claude Notch") || value.contains("Claude Notch"), "\(language)/\(file) : \(key)")
                }
            }
        }
    }

    // MARK: - Outils

    private static func response(_ status: String, body: String, headers: String = "") -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\(headers)\r\n\(body)"
    }

    /// Release telle que l'API la rend après le renommage : les deux images, servies par le dépôt oriel.
    private static func releaseJSON(_ version: String) -> String {
        let assets = ["Oriel", legacyName].flatMap { name in
            ["dmg", "dmg.sha256", "dmg.sig"].map { suffix in
                let file = "\(name)-\(version).\(suffix)"
                return #"{"name": "\#(file)", "browser_download_url": "https://github.com/Slybald/oriel/releases/download/v\#(version)/\#(file)"}"#
            }
        }
        return #"{"tag_name": "v\#(version)", "html_url": "https://github.com/Slybald/oriel/releases/tag/v\#(version)", "#
            + #""draft": false, "prerelease": false, "assets": [\#(assets.joined(separator: ", "))]}"#
    }

    /// App minimale : Info.plist (nom affiché Oriel) et exécutable ClaudeNotch.
    @discardableResult
    private func makeApp(in folder: URL, name: String, version: String,
                         bundleId: String = AppIdentity.bundleId) throws -> URL {
        let app = folder.appendingPathComponent(name)
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleId, "CFBundleShortVersionString": version,
                                   "CFBundleExecutable": "ClaudeNotch", "CFBundleDisplayName": AppIdentity.name]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("ClaudeNotch")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    /// `<appName>-<version>.dmg` contenant `<appName>.app`, comme scripts/make-dmg.sh.
    private func makeImage(appName: String, version: String, in root: URL) throws -> URL {
        let volume = root.appendingPathComponent("volume-\(appName)-\(version)")
        try makeApp(in: volume, name: "\(appName).app", version: version)
        let dmg = root.appendingPathComponent("\(appName)-\(version).dmg")
        try Updater.run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Oriel", "-srcfolder", volume.path,
                                             "-fs", "HFS+", "-format", "UDZO", "-ov", dmg.path])
        return dmg
    }

    private func executable(of app: URL) -> String {
        app.appendingPathComponent("Contents/MacOS/ClaudeNotch").path
    }

    private func program(_ agents: URL) -> [String]? {
        guard let data = try? Data(contentsOf: LaunchAgent.plistURL(in: agents)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["ProgramArguments"] as? [String]
    }
}

/// Serveur HTTP local d'un nombre fixe de connexions : chacune reçoit la réponse brute de `respond`, puis est fermée.
private final class LocalServer {
    let port: UInt16
    private let lock = NSLock()
    private var seen: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    init(connections: Int, respond: @escaping (_ path: String, _ port: UInt16) -> String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                Darwin.bind(fd, pointer, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        guard fd >= 0, bound else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        let port = UInt16(bigEndian: address.sin_port)
        self.port = port
        DispatchQueue.global().async { [self] in
            defer { close(fd) }
            for _ in 0..<connections {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 65_536)
                var request: HTTPRequest?
                while request == nil {
                    let count = read(client, &buffer, buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                    if case .complete(let complete) = HTTPRequest.parse(data, maxBody: 1 << 20) { request = complete }
                }
                let path = request?.path ?? ""
                lock.lock()
                seen.append(path)
                lock.unlock()
                _ = respond(path, port).withCString { write(client, $0, strlen($0)) }
                close(client)
            }
        }
    }
}
