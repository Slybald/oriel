import Foundation

/// Identité publique de l'app.
///
/// `bundleId` doit rester égal à CFBundleIdentifier (Resources/Info.plist), à l'identifiant que
/// hooks/oriel-hook.sh relance (`open -g -b`) et au label du LaunchAgent (scripts/install.sh).
enum AppIdentity {
    static let bundleId = "io.github.slybald.oriel"
    /// Identifiant des premières versions, installées par scripts/install.sh.
    static let legacyBundleId = "local.claudenotch"
    /// Nom de l'app et de son bundle depuis la 2.0.0.
    static let name = "Oriel"
    static let bundleName = "Oriel.app"
    /// Bundle jusqu'à la 1.9.0 : le seul nom que leur mise à jour automatique sait installer.
    static let legacyBundleName = "ClaudeNotch.app"

    /// Reprend une installation faite sous l'ancien identifiant : préférences, puis LaunchAgent.
    /// Le LaunchAgent n'est migré que depuis Applications : lancée depuis le DMG, l'app y écrirait
    /// un chemin qui disparaît à l'éjection.
    static func migrateLegacyInstall() {
        let defaults = UserDefaults.standard
        if Bundle.main.bundleIdentifier != legacyBundleId {
            migrateLegacyDefaults(from: defaults.persistentDomain(forName: legacyBundleId), to: defaults)
        }
        if isInApplicationsFolder(Bundle.main.bundlePath) {
            LaunchAgent.migrateLegacy()
            // Bundle renommé ou installé à côté de l'ancien : le LaunchAgent suit l'app qui tourne.
            LaunchAgent.refresh()
            if Bundle.main.bundleURL.lastPathComponent == bundleName,
               let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                retireLegacyBundles(version: version)
            }
        }
    }

    /// Premier lancement après une mise à jour faite par une version d'avant le renommage : leur Updater a installé
    /// Oriel.app. L'app se renomme Oriel.app dans le même dossier et rend le bundle à relancer. Un Oriel.app
    /// au moins aussi récent prend la place (il retirera celui-ci), un plus ancien part à la Corbeille. nil : rien à
    /// faire (autre nom, hors Applications, Oriel.app d'un autre éditeur, renommage impossible).
    static func adoptNewBundleName(_ app: URL, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                   launchAgents: URL = LaunchAgent.directory,
                                   discard: (URL) throws -> Void = moveToTrash) -> URL? {
        guard app.lastPathComponent == legacyBundleName, isInApplicationsFolder(app.path, home: home),
              let mine = bundleInfo(app) else { return nil }
        let target = app.deletingLastPathComponent().appendingPathComponent(bundleName)
        do {
            if let other = bundleInfo(target) {
                guard other.id == bundleId else { return nil }
                if Updater.compareVersions(other.version, mine.version) != .orderedAscending { return target }
                try discard(target)
            }
            try FileManager.default.moveItem(at: app, to: target)
        } catch {
            NSLog("Oriel : renommage en %@ impossible (%@).", bundleName, String(describing: error))
            return nil
        }
        LaunchAgent.refresh(in: launchAgents,
                            executable: target.appendingPathComponent("Contents/MacOS/\(mine.executable)").path)
        return target
    }

    /// Oriel.app installée à la main à côté d'une ancienne Oriel.app : celle-ci (même identifiant, version
    /// inférieure ou égale) part à la Corbeille, sinon le Launchpad et Spotlight montreraient deux apps.
    @discardableResult
    static func retireLegacyBundles(version: String, folders: [URL] = applicationsFolders(),
                                    discard: (URL) throws -> Void = moveToTrash) -> [URL] {
        folders.map { $0.appendingPathComponent(legacyBundleName) }.filter { legacy in
            guard let info = bundleInfo(legacy), info.id == bundleId,
                  [.orderedAscending, .orderedSame].contains(Updater.compareVersions(info.version, version))
            else { return false }
            do {
                try discard(legacy)
                return true
            } catch {
                NSLog("Oriel : %@ non retirée (%@).", legacy.path, String(describing: error))
                return false
            }
        }
    }

    static func applicationsFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Identifiant, version et exécutable lus dans Contents/Info.plist (pas `Bundle(url:)`, qui garde en cache un
    /// bundle remplacé depuis) ; nil si ce n'est pas une app lisible.
    static func bundleInfo(_ app: URL) -> (id: String, version: String, executable: String)? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String else { return nil }
        return (id, info["CFBundleShortVersionString"] as? String ?? "0", info["CFBundleExecutable"] as? String ?? "")
    }

    /// Les préférences changent de domaine avec l'identifiant : recopie celles de l'ancien domaine,
    /// sans écraser une valeur déjà présente dans le nouveau.
    static func migrateLegacyDefaults(from legacy: [String: Any]?, to defaults: UserDefaults) {
        guard let legacy else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// Vrai si l'app tourne depuis /Applications ou ~/Applications, et non depuis le DMG ou une copie
    /// translocalisée par Gatekeeper (/private/var/folders/…/AppTranslocation/…).
    static func isInApplicationsFolder(_ bundlePath: String,
                                       home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        let path = (bundlePath as NSString).standardizingPath.lowercased()
        let folders = ["/Applications", (home as NSString).appendingPathComponent("Applications")]
        return folders.contains { path.hasPrefix($0.lowercased() + "/") }
    }
}
