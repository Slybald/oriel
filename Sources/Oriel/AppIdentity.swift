import Foundation

/// Identité publique de l'app.
///
/// `bundleId` doit rester égal à CFBundleIdentifier (Resources/Info.plist), à l'identifiant que
/// hooks/oriel-hook.sh relance (`open -g -b`) et au label du LaunchAgent (scripts/install.sh).
enum AppIdentity {
    static let bundleId = "io.github.slybald.oriel"
    /// Identifiants d'avant le renommage en Oriel (2.1 et avant : `io.github.slybald.claudenotch` ; premières versions,
    /// installées par scripts/install.sh : `local.claudenotch`). Servent seulement à reprendre l'installation.
    static let previousBundleId = "io.github.slybald.claudenotch"
    static let legacyBundleId = "local.claudenotch"
    static let legacyBundleIds = [previousBundleId, legacyBundleId]
    /// Nom de l'app et de son bundle.
    static let name = "Oriel"
    static let bundleName = "Oriel.app"

    /// Reprend une installation faite sous un ancien nom (voir `LegacyMigration`). Le LaunchAgent n'est migré que
    /// depuis Applications : lancée depuis le DMG, l'app y écrirait un chemin qui disparaît à l'éjection.
    static func migrateLegacyInstall() {
        LegacyMigration.run(.standard, defaults: .standard, ownDomain: Bundle.main.bundleIdentifier ?? bundleId,
                            executable: isInApplicationsFolder(Bundle.main.bundlePath)
                                ? Bundle.main.executablePath : nil)
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
