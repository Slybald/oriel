import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI

/// Mise à jour automatique depuis les releases GitHub (tag vX.Y.Z construit par la CI).
///
/// - Seule une app construite pour la release (clé `OrielUpdateChannel = release` posée par
///   `RELEASE_CHANNEL=1 scripts/build.sh`) vérifie : 60 s après le lancement, puis toutes les 6 h.
/// - Le DMG n'est installé que si sa signature Ed25519 correspond à la clé publique ci-dessous.
/// - Échange par deux renommages dans le dossier de l'app : jamais d'app à moitié remplacée.
///
/// `@unchecked Sendable` : l'état n'est lu et modifié que sur le main thread ; les tâches de fond n'appellent
/// que des fonctions statiques et reviennent sur le main thread pour publier leur résultat.
final class Updater: ObservableObject, @unchecked Sendable {
    static let shared = Updater()

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/Slybald/oriel/releases/latest")!
    /// Clé publique Ed25519 (base64). La privée signe les DMG dans la CI (scripts/update-signing.swift).
    static let publicKey = "KKwGDnHEGrzmG6F26Dco+/RUrliwrPPztW0ceaG5/UA="
    static let channelKey = "OrielUpdateChannel"
    /// Version installée juste avant la relance, pour afficher « Mis à jour en X ».
    static let installedVersionKey = "updateInstalledVersion"
    static let firstCheckDelay: TimeInterval = 60
    static let checkInterval: TimeInterval = 6 * 3600
    static let idleRetryInterval: TimeInterval = 10 * 60
    /// Au réveil, le temps que le réseau revienne.
    static let wakeCheckDelay: TimeInterval = 30

    enum Status: Equatable {
        case idle
        case checking
        case available(version: String, page: URL)
        case installing(version: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    let currentVersion: String
    let isReleaseBuild: Bool
    /// Version installée par la mise à jour qui vient de relancer l'app.
    let justUpdatedTo: String?
    /// Vrai si une session travaille ou attend l'utilisateur (fourni par AppCore).
    var isBusy: () -> Bool = { false }

    private var latest: Release?
    private var lastCheck: Date?
    private var launchCheckDone = false
    private var checkTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var retryTimer: Timer?

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        currentVersion = version
        isReleaseBuild = bundle.object(forInfoDictionaryKey: Self.channelKey) as? String == "release"
        let installed = defaults.string(forKey: Self.installedVersionKey)
        defaults.removeObject(forKey: Self.installedVersionKey)
        justUpdatedTo = installed.flatMap { Self.compareVersions($0, version) == .orderedSame ? $0 : nil }
    }

    // MARK: - Planification

    /// Première vérification 60 s après le lancement, puis toutes les 6 h. Rien pour un build de développement.
    func start() {
        guard isReleaseBuild, checkTimer == nil else { return }
        let timer = Timer(fire: Date().addingTimeInterval(Self.firstCheckDelay), interval: Self.checkInterval,
                          repeats: true) { [weak self] _ in
            guard let self else { return }
            let atLaunch = !launchCheckDone
            launchCheckDone = true
            check(atLaunch: atLaunch)
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
        // Le minuteur ne compte pas le temps de veille (mesuré : 16 h sans vérification après une nuit) : au réveil,
        // on rattrape une vérification due.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeCheckDelay) {
                guard let self, Self.isOverdue(lastCheck: self.lastCheck, now: Date()) else { return }
                self.check(atLaunch: false)
            }
        }
    }

    /// Dernière vérification plus vieille que l'intervalle, en temps réel (veille comprise). Jamais faite : la
    /// vérification du lancement s'en charge.
    static func isOverdue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return false }
        return now.timeIntervalSince(lastCheck) >= checkInterval
    }

    /// « Rechercher les mises à jour ».
    func checkNow() {
        check(atLaunch: false)
    }

    /// « Installer » : version disponible, sans attendre que les sessions soient au repos.
    func installNow() {
        guard let latest, case .available = status else { return }
        install(latest)
    }

    func openReleasePage() {
        guard case .available(_, let page) = status else { return }
        NSWorkspace.shared.open(page)
    }

    var isWorking: Bool {
        switch status {
        case .checking, .installing: return true
        default: return false
        }
    }

    var canInstall: Bool { Self.canInstall(bundlePath: Bundle.main.bundlePath) }

    // MARK: - Vérification

    private func check(atLaunch: Bool) {
        guard isReleaseBuild, !isWorking else { return }
        status = .checking
        lastCheck = Date()
        let version = currentVersion
        Task.detached(priority: .utility) { [weak self] in
            let result: Result<Release, Error>
            do {
                result = .success(try await Self.fetchLatestRelease(userAgentVersion: version))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { self?.received(result, atLaunch: atLaunch) }
        }
    }

    private func received(_ result: Result<Release, Error>, atLaunch: Bool) {
        switch result {
        case .failure(let error):
            fail(error)
        case .success(let release):
            latest = release
            apply(release, atLaunch: atLaunch)
        }
    }

    private func apply(_ release: Release, atLaunch: Bool) {
        let decision = Self.decide(release: release, currentVersion: currentVersion, releaseChannel: isReleaseBuild,
                                   autoUpdate: Preferences.shared.autoUpdate, installable: canInstall,
                                   busy: isBusy(), atLaunch: atLaunch)
        switch decision {
        case .disabled, .upToDate:
            stopRetry()
            status = .idle
        case .offer:
            stopRetry()
            status = .available(version: release.version, page: release.htmlUrl)
        case .wait:
            status = .available(version: release.version, page: release.htmlUrl)
            scheduleRetry()
        case .install:
            stopRetry()
            install(release)
        }
    }

    /// Sessions occupées : nouvel essai toutes les 10 min, avec la décision du moment (préférence comprise).
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: Self.idleRetryInterval, repeats: true) { [weak self] _ in
            guard let self, let latest = self.latest, case .available = self.status else {
                self?.stopRetry()
                return
            }
            apply(latest, atLaunch: false)
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func stopRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: - Installation

    private func install(_ release: Release) {
        if case .installing = status { return }
        guard canInstall else {
            status = .available(version: release.version, page: release.htmlUrl)
            return
        }
        status = .installing(version: release.version)
        let app = Bundle.main.bundleURL
        let version = currentVersion
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await Self.downloadAndInstall(release, over: app, userAgentVersion: version)
                DispatchQueue.main.async { self?.relaunch(after: release, app: app) }
            } catch {
                DispatchQueue.main.async { self?.fail(error) }
            }
        }
    }

    /// Nouvelle app en place : on note la version, on lance le relais qui rouvrira l'app, puis on quitte.
    private func relaunch(after release: Release, app: URL) {
        NSLog("Oriel : mise à jour %@ → %@ installée, relance.", currentVersion, release.version)
        UserDefaults.standard.set(release.version, forKey: Self.installedVersionKey)
        do {
            try Self.spawnRelaunch(of: app, waitingFor: ProcessInfo.processInfo.processIdentifier)
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.installedVersionKey)
            let message = String(format: L("Version %@ installée : quitte et rouvre Oriel pour l'utiliser."),
                                 release.version)
            NSLog("Oriel : relance impossible (%@). %@", String(describing: error), message)
            status = .failed(message)
            return
        }
        NSApp.terminate(nil)
    }

    private func fail(_ error: Error) {
        let message = error is UpdateError
            ? error.localizedDescription
            : String(format: L("Mise à jour impossible (%@)."), error.localizedDescription)
        NSLog("Oriel : %@", message)
        status = .failed(message)
    }

    // MARK: - Menu et /state

    var versionLine: String {
        if case .installing(let version) = status { return String(format: L("Mise à jour vers %@…"), version) }
        if let justUpdatedTo { return String(format: L("Mis à jour en %@"), justUpdatedTo) }
        return String(format: L("Version %@"), currentVersion)
    }

    var debugSummary: [String: Any] {
        var info: [String: Any] = [
            "channel": isReleaseBuild ? "release" : "development",
            "autoUpdate": Preferences.shared.autoUpdate,
            "installable": canInstall,
            "waitingForIdle": retryTimer != nil,
        ]
        switch status {
        case .idle: info["status"] = "idle"
        case .checking: info["status"] = "checking"
        case .available(let version, _): info["status"] = "available \(version)"
        case .installing(let version): info["status"] = "installing \(version)"
        case .failed(let message): info["status"] = "failed: \(message)"
        }
        info["latest"] = latest?.version
        info["lastCheck"] = lastCheck.map { ISO8601DateFormatter().string(from: $0) }
        info["updatedTo"] = justUpdatedTo
        return info
    }
}

// MARK: - Logique (pure, testée)

extension Updater {
    /// Release GitHub, telle que renvoyée par /releases/latest (champs utiles seulement).
    struct Release: Decodable, Equatable {
        struct Asset: Decodable, Equatable {
            let name: String
            let browserDownloadUrl: URL
        }

        let tagName: String
        let htmlUrl: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        /// Tag sans « v » (v1.2.0 → 1.2.0).
        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    enum Decision: Equatable {
        /// Build de développement : jamais de mise à jour.
        case disabled
        case upToDate
        /// Montrer « Version X disponible » ; installation à la main (ou page de la release).
        case offer
        /// Sessions occupées : réessayer plus tard.
        case wait
        case install
    }

    static func decodeRelease(_ data: Data) throws -> Release {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Release.self, from: data)
        } catch {
            throw UpdateError.invalidRelease
        }
    }

    /// Composants numériques (« v1.2 » → [1, 2]) ; nil pour autre chose que des chiffres séparés par des points.
    /// Une version valide ne contient donc ni « / » ni « .. » : elle peut entrer dans un nom de fichier.
    static func versionComponents(_ text: String) -> [Int]? {
        let body = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            return Int(part)
        }
        return numbers.count == parts.count && !numbers.isEmpty ? numbers : nil
    }

    /// Comparaison numérique composant par composant ; les composants manquants valent 0 (1.0 == 1.0.0).
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = versionComponents(lhs), let right = versionComponents(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Au lancement, une version trouvée s'installe tout de suite ; ensuite, seulement sessions au repos.
    static func decide(release: Release, currentVersion: String, releaseChannel: Bool, autoUpdate: Bool,
                       installable: Bool, busy: Bool, atLaunch: Bool) -> Decision {
        guard releaseChannel else { return .disabled }
        guard !release.draft, !release.prerelease,
              compareVersions(release.version, currentVersion) == .orderedDescending else { return .upToDate }
        guard autoUpdate, installable else { return .offer }
        return busy && !atLaunch ? .wait : .install
    }

    /// « Oriel-<v>.dmg » et sa signature « .dmg.sig », en HTTPS.
    static func updateAssets(in release: Release) throws -> (dmg: URL, signature: URL) {
        let name = "\(AppIdentity.name)-\(release.version).dmg"
        func url(_ assetName: String) -> URL? {
            release.assets.first { $0.name == assetName && $0.browserDownloadUrl.scheme == "https" }?.browserDownloadUrl
        }
        guard let dmg = url(name) else { throw UpdateError.missingAsset(name) }
        guard let signature = url(name + ".sig") else { throw UpdateError.missingSignature }
        return (dmg, signature)
    }

    /// Signature Ed25519 (base64, espaces et saut de ligne final tolérés) de tous les octets de `data`.
    static func isValidSignature(_ signature: String, for data: Data, publicKey: String = publicKey) -> Bool {
        guard let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let bytes = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return key.isValidSignature(bytes, for: data)
    }

    /// App dans /Applications ou ~/Applications, dans un dossier où l'on peut écrire (échange par renommage).
    static func canInstall(bundlePath: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path)
        -> Bool {
        AppIdentity.isInApplicationsFolder(bundlePath, home: home)
            && FileManager.default.isWritableFile(atPath: (bundlePath as NSString).deletingLastPathComponent)
    }
}

// MARK: - Fichiers et processus

extension Updater {
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.bundleId).appendingPathComponent("updates")
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    private static func request(_ url: URL, accept: String, userAgentVersion: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("\(AppIdentity.name)/\(userAgentVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func checkHTTP(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.http(code) }
    }

    static func fetchLatestRelease(from url: URL = latestReleaseURL, userAgentVersion: String) async throws -> Release {
        let request = request(url, accept: "application/vnd.github+json", userAgentVersion: userAgentVersion)
        let (data, response) = try await session.data(for: request)
        try checkHTTP(response)
        return try decodeRelease(data)
    }

    /// Télécharge le DMG et sa signature dans le cache, vérifie la signature, puis installe.
    static func downloadAndInstall(_ release: Release, over app: URL, userAgentVersion: String) async throws {
        let assets = try updateAssets(in: release)
        let manager = FileManager.default
        let folder = cacheDirectory
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }

        let dmg = folder.appendingPathComponent("\(AppIdentity.name)-\(release.version).dmg")
        let accept = "application/octet-stream"
        let (downloaded, response) = try await session.download(
            for: request(assets.dmg, accept: accept, userAgentVersion: userAgentVersion))
        try checkHTTP(response)
        try manager.moveItem(at: downloaded, to: dmg)
        let (signature, signatureResponse) = try await session.data(
            for: request(assets.signature, accept: accept, userAgentVersion: userAgentVersion))
        try checkHTTP(signatureResponse)

        let data = try Data(contentsOf: dmg, options: .mappedIfSafe)
        guard isValidSignature(String(decoding: signature, as: UTF8.self), for: data) else {
            throw UpdateError.invalidSignature
        }
        try installUpdate(dmg: dmg, version: release.version, over: app)
    }

    /// Monte le DMG, copie l'app à côté de l'app installée (même volume), démonte, puis échange les deux apps.
    /// L'app garde son chemin.
    static func installUpdate(dmg: URL, version: String, over app: URL, bundleId: String = AppIdentity.bundleId,
                              bundleName: String = AppIdentity.bundleName) throws {
        let manager = FileManager.default
        let staging = app.deletingLastPathComponent().appendingPathComponent(".Oriel-update")
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }

        let staged = staging.appendingPathComponent(bundleName)
        try withMountedImage(dmg) { volume in
            let source = volume.appendingPathComponent(bundleName)
            try validateBundle(source, bundleId: bundleId, version: version)
            // --noqtn : signature déjà vérifiée ; une quarantaine ferait bloquer la relance par Gatekeeper.
            try run("/usr/bin/ditto", ["--noqtn", source.path, staged.path])
        }
        try validateBundle(staged, bundleId: bundleId, version: version)
        try swapBundles(current: app, replacement: staged)
    }

    /// L'app du DMG est bien la nôtre, dans la version annoncée, avec son exécutable.
    static func validateBundle(_ app: URL, bundleId: String, version: String) throws {
        let contents = app.appendingPathComponent("Contents")
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleId,
              let found = info["CFBundleShortVersionString"] as? String,
              compareVersions(found, version) == .orderedSame,
              let executable = info["CFBundleExecutable"] as? String, !executable.contains("/"),
              FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("MacOS/\(executable)").path)
        else { throw UpdateError.wrongBundle }
    }

    /// Actuelle → .Oriel-old.app, nouvelle → emplacement de l'actuelle, puis suppression de l'ancienne.
    /// Si le second renommage échoue, l'ancienne app revient à sa place.
    static func swapBundles(current: URL, replacement: URL) throws {
        let manager = FileManager.default
        let backup = current.deletingLastPathComponent().appendingPathComponent(".Oriel-old.app")
        if manager.fileExists(atPath: backup.path) { try manager.removeItem(at: backup) }
        try manager.moveItem(at: current, to: backup)
        do {
            try manager.moveItem(at: replacement, to: current)
        } catch {
            do {
                try manager.moveItem(at: backup, to: current)
            } catch let restore {
                NSLog("Oriel : ancienne app non restaurée (%@), elle reste dans %@.",
                      String(describing: restore), backup.path)
            }
            throw error
        }
        do {
            try manager.removeItem(at: backup)
        } catch {
            // La nouvelle app est en place : l'ancienne sera retirée à la prochaine mise à jour.
            NSLog("Oriel : suppression de %@ impossible (%@).", backup.path, String(describing: error))
        }
    }

    /// Point de montage privé dans le dossier temporaire ; toujours démonté, même en cas d'erreur.
    static func withMountedImage(_ dmg: URL, _ body: (URL) throws -> Void) throws {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oriel-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        // rmdir et non removeItem : ne supprime jamais le contenu d'un volume resté monté.
        defer { rmdir(mountPoint.path) }
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                     "-mountpoint", mountPoint.path, dmg.path])
        defer {
            if (try? run("/usr/bin/hdiutil", ["detach", mountPoint.path])) == nil {
                _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path])
            }
        }
        try body(mountPoint)
    }

    /// Lance un outil système et attend sa fin ; code de sortie non nul → erreur avec sa sortie.
    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.command((tool as NSString).lastPathComponent,
                                      text.isEmpty ? "code \(process.terminationStatus)" : String(text.prefix(200)))
        }
    }

    /// Relais `/bin/sh` qui attend la fin de `pid` puis rouvre l'app. posix_spawn plutôt que Process :
    /// nouvelle session (lancée par le LaunchAgent, l'app partage son groupe de processus, que launchd tue à sa
    /// sortie) et aucun descripteur hérité (le shell garderait le port des hooks, et la nouvelle app quitterait).
    static func spawnRelaunch(of app: URL, waitingFor pid: pid_t) throws {
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$0\""
        try spawnDetached(["/bin/sh", "-c", script, app.path])
    }

    /// Lance `arguments[0]` dans sa propre session, sans aucun de nos descripteurs (0, 1, 2 → /dev/null).
    @discardableResult
    static func spawnDetached(_ arguments: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        let result = posix_spawn(&child, arguments[0], &actions, &attributes, argv, environ)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return child
    }
}

// MARK: - Erreurs

enum UpdateError: LocalizedError, Equatable {
    case http(Int)
    case invalidRelease
    case missingAsset(String)
    case missingSignature
    case invalidSignature
    case wrongBundle
    case command(String, String)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return String(format: L("Mise à jour impossible : GitHub a répondu %d."), code)
        case .invalidRelease:
            return L("Mise à jour impossible : réponse de GitHub illisible.")
        case .missingAsset(let name):
            return String(format: L("Mise à jour impossible : %@ absent de la release."), name)
        case .missingSignature:
            return L("Mise à jour refusée : signature absente.")
        case .invalidSignature:
            return L("Mise à jour refusée : signature invalide.")
        case .wrongBundle:
            return L("Mise à jour refusée : l'image disque ne contient pas la version attendue.")
        case .command(let tool, let detail):
            return String(format: L("Mise à jour impossible : %@ a échoué (%@)."), tool, detail)
        }
    }
}

// MARK: - Menu

/// Entrées du menu « … » : version, état de la mise à jour, préférence et vérification manuelle.
struct UpdateMenuItems: View {
    @ObservedObject var updater: Updater
    @ObservedObject var prefs: Preferences

    var body: some View {
        Button(updater.versionLine) {}
            .disabled(true)
        if updater.isReleaseBuild {
            switch updater.status {
            case .available(let version, _):
                Button(String(format: L("Version %@ disponible"), version)) {}
                    .disabled(true)
                if updater.canInstall {
                    Button("Installer", action: updater.installNow)
                } else {
                    Button("Ouvrir la page de la release", action: updater.openReleasePage)
                }
            case .failed(let message):
                Button(message) {}
                    .disabled(true)
            case .idle, .checking, .installing:
                EmptyView()
            }
            Toggle("Mises à jour automatiques", isOn: $prefs.autoUpdate)
            Button("Rechercher les mises à jour", action: updater.checkNow)
                .disabled(updater.isWorking)
        } else {
            Button("Build de développement : mises à jour désactivées") {}
                .disabled(true)
        }
    }
}
