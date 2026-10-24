import Foundation

/// Reprise, au premier lancement d'Oriel, d'une installation faite sous l'ancien nom (ClaudeNotch, 2.1 et avant).
///
/// Chaque étape est idempotente et ne remplace jamais ce qui existe déjà. Les emplacements sont injectés : les tests
/// n'ouvrent jamais le vrai `~`.
enum LegacyMigration {
    struct Locations {
        var applicationSupport: URL
        var launchAgents: URL
        var claudeConfig: URL
        var codexConfig: URL

        static var standard: Locations {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Locations(applicationSupport: home.appendingPathComponent("Library/Application Support"),
                             launchAgents: LaunchAgent.directory,
                             claudeConfig: home.appendingPathComponent(".claude"),
                             codexConfig: home.appendingPathComponent(".codex"))
        }
    }

    static let oldDataFolder = "ClaudeNotch"
    static let oldClaudeHook = "claude-notch-hook.sh"
    static let oldStatusLine = "claude-notch-statusline.sh"
    static let oldStatusLinePrevious = "claude-notch-statusline.previous"
    static let oldCodexStatus = "Claude Notch"

    /// `executable` : l'exécutable à mettre dans le LaunchAgent (nil : app hors Applications, l'ancien est laissé).
    static func run(_ locations: Locations, defaults: UserDefaults, ownDomain: String, executable: String?) {
        moveDataFolder(in: locations.applicationSupport)
        copyDefaults(into: defaults, ownDomain: ownDomain)
        rewriteClaudeHooks(in: locations.claudeConfig)
        rewriteCodexHooks(in: locations.codexConfig)
        LaunchAgent.migrateLegacy(in: locations.launchAgents, executable: executable)
    }

    /// `Application Support/ClaudeNotch` → `Oriel` (jeton d'API, notes, presse-papiers… avec lui). Les deux existent :
    /// rien n'est écrasé.
    @discardableResult
    static func moveDataFolder(in support: URL) -> Bool {
        let old = support.appendingPathComponent(oldDataFolder)
        let new = support.appendingPathComponent(AppIdentity.name)
        let manager = FileManager.default
        guard manager.fileExists(atPath: old.path), !manager.fileExists(atPath: new.path) else { return false }
        do {
            try manager.moveItem(at: old, to: new)
        } catch {
            NSLog("Oriel : déplacement de %@ impossible (%@).", old.path, String(describing: error))
            return false
        }
        return true
    }

    /// Réglages : copiés depuis l'ancien domaine seulement quand le nouveau est vide (une valeur retirée à la main
    /// ne revient pas aux lancements suivants).
    @discardableResult
    static func copyDefaults(into defaults: UserDefaults, ownDomain: String,
                             legacyDomains: [String] = AppIdentity.legacyBundleIds) -> Bool {
        guard defaults.persistentDomain(forName: ownDomain)?.isEmpty ?? true else { return false }
        for domain in legacyDomains {
            guard let old = defaults.persistentDomain(forName: domain),
                  !old.isEmpty else { continue }
            for (key, value) in old { defaults.set(value, forKey: key) }
            return true
        }
        return false
    }

    /// settings.json (Claude Code) : les commandes des hooks et de la ligne d'état pointent vers les scripts renommés.
    /// Seuls ces noms sont touchés ; le reste du fichier reste tel quel (copie `.oriel-migration.bak` à côté).
    @discardableResult
    static func rewriteClaudeHooks(in config: URL) -> Bool {
        let hooks = config.appendingPathComponent("hooks")
        let moved = [(oldClaudeHook, HookInstaller.hookFileName), (oldStatusLine, StatusLineInstaller.scriptName),
                     (oldStatusLinePrevious, StatusLineInstaller.previousName)]
            .map { renameFile(hooks.appendingPathComponent($0.0), to: hooks.appendingPathComponent($0.1)) }
        let rewritten = rewrite(config.appendingPathComponent("settings.json"),
                                [(oldClaudeHook, HookInstaller.hookFileName), (oldStatusLine, StatusLineInstaller.scriptName)])
        return rewritten || moved.contains(true)
    }

    /// hooks.json (Codex) : le script garde son nom, seul le message affiché pendant la demande change.
    @discardableResult
    static func rewriteCodexHooks(in config: URL) -> Bool {
        let file = config.appendingPathComponent("hooks.json")
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains(CodexHookInstaller.hookFileName)
        else { return false }
        let pattern = #"("statusMessage"\s*:\s*)"\#(oldCodexStatus)""#
        let updated = text.replacingOccurrences(of: pattern, with: "$1\"\(CodexHookInstaller.permissionStatus)\"",
                                                options: .regularExpression)
        return write(updated, replacing: text, at: file)
    }

    // MARK: - Fichiers

    private static func rewrite(_ file: URL, _ replacements: [(String, String)]) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let updated = replacements.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        return write(updated, replacing: text, at: file)
    }

    private static func write(_ updated: String, replacing text: String, at file: URL) -> Bool {
        guard updated != text else { return false }
        let manager = FileManager.default
        let backup = file.appendingPathExtension("oriel-migration.bak")
        let permissions = (try? manager.attributesOfItem(atPath: file.path))?[.posixPermissions]
        do {
            if !manager.fileExists(atPath: backup.path) { try manager.copyItem(at: file, to: backup) }
            try Data(updated.utf8).write(to: file, options: .atomic)
            if let permissions { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
        } catch {
            NSLog("Oriel : réécriture de %@ impossible (%@).", file.path, String(describing: error))
            return false
        }
        return true
    }

    /// Renomme un script de hook ; le nouveau existe déjà : rien n'est écrasé.
    private static func renameFile(_ old: URL, to new: URL) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: old.path), !manager.fileExists(atPath: new.path) else { return false }
        return (try? manager.moveItem(at: old, to: new)) != nil
    }
}
