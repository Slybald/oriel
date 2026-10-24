import AppKit
import Darwin
import Foundation

/// Ajoute ou retire les hooks de Oriel dans `~/.codex/hooks.json` (le fichier de hooks de Codex).
///
/// - Jamais `config.toml` : on n'y touche pas. Son `notify` (un seul programme possible, souvent déjà pris par un autre
///   outil) reste intact ; les hooks, eux, s'ajoutent à ceux de l'utilisateur.
/// - Idempotent : nos entrées (repérées par « codex-notch-hook.sh ») sont retirées puis rajoutées ; les autres hooks et
///   l'ordre des clés sont conservés ; JSON invalide : rien n'est touché.
/// - Sauvegarde horodatée avant toute écriture sur un fichier existant, aucune écriture si rien ne change, écriture
///   atomique.
/// - Codex ne lance un hook qu'après son approbation (`/hooks` dans le terminal, « Review hooks » dans l'app) : ici on la
///   lit dans `config.toml` (lecture seule) ; `CodexHookSetup` la demande à Codex lui-même, sur un clic explicite.
struct CodexHookInstaller {
    static let hookFileName = "codex-notch-hook.sh"
    static let marker = hookFileName
    /// Événements suivis. `PermissionRequest` est le hook synchrone ; les autres sont des relais asynchrones.
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop",
                         "Interrupt", "SessionEnd"]
    static let relayTimeout = "10"
    /// Codex plafonne ces deux-là à 3 s (il le signale sinon).
    static let shortTimeout = "3"
    static let shortEvents: Set<String> = ["Interrupt", "SessionEnd"]
    /// Au-dessus de `CodexApprovals.engagedDelay` : l'app rend toujours la main avant.
    static let permissionTimeout = "75"
    /// Affiché par Codex pendant que le hook tient la demande.
    static let permissionStatus = "Oriel"

    enum Status: Equatable {
        case notInstalled
        case installed
        /// Entrées présentes mais différentes (chemin, options, événements).
        case outdated
        /// Entrées à jour, mais script de hook absent ou différent de celui de l'app (app mise à jour).
        case scriptOutdated
        case unreadable(String)
    }

    enum Failure: LocalizedError, Equatable {
        case invalidFile(String)
        case notObject
        case hooksNotObject
        case eventNotList(String)
        case missingBundledHook
        case io(String)

        var errorDescription: String? {
            switch self {
            case .invalidFile(let detail):
                return String(format: L("hooks.json invalide (%@) : rien n'a été modifié.", table: "Codex"), detail)
            case .notObject:
                return L("hooks.json n'est pas un objet JSON : rien n'a été modifié.", table: "Codex")
            case .hooksNotObject:
                return L("La clé « hooks » de hooks.json n'est pas un objet : rien n'a été modifié.", table: "Codex")
            case .eventNotList(let event):
                return String(format: L("hooks.%@ n'est pas une liste : rien n'a été modifié.", table: "Codex"), event)
            case .missingBundledHook:
                return String(format: L("Script de hook introuvable dans l'app (Contents/Resources/%@) : "
                                        + "rien n'a été modifié.", table: "Codex"), CodexHookInstaller.hookFileName)
            case .io(let detail):
                return detail
            }
        }
    }

    struct Outcome: Equatable {
        /// hooks.json réécrit (faux s'il était déjà à jour).
        var fileChanged: Bool
        /// Copie de l'ancien hooks.json, s'il existait.
        var backup: URL?
    }

    /// Ce que dit `config.toml` (lu, jamais écrit) des hooks.
    struct ConfigNotes: Equatable {
        /// `[features] hooks = false` : Codex n'exécute aucun hook.
        var hooksDisabled = false
        /// Des hooks en ligne dans `config.toml` : Codex charge les deux fichiers et prévient.
        var inlineHooks = false
        /// Un `notify` est configuré : il n'est pas touché.
        var hasNotify = false
    }

    let configDirectory: URL
    /// Script embarqué dans l'app (Contents/Resources) ; nil hors bundle (`swift run`).
    let bundledHook: URL?
    /// Horloge des noms de sauvegarde (injectable pour les tests).
    var now: () -> Date = { Date() }

    init(configDirectory: URL, bundledHook: URL?) {
        self.configDirectory = configDirectory
        self.bundledHook = bundledHook
    }

    /// ~/.codex et le script embarqué dans l'app. Une app ouverte depuis le Finder ne voit pas `CODEX_HOME`.
    static var standard: CodexHookInstaller {
        CodexHookInstaller(configDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
                           bundledHook: Bundle.main.url(forResource: "codex-notch-hook", withExtension: "sh"))
    }

    /// Codex présent sur ce Mac : `~/.codex`, `$CODEX_HOME`, l'app Codex (aujourd'hui dans l'app ChatGPT, bundle
    /// `com.openai.codex`) ou la commande `codex` à un endroit usuel.
    static func codexPresent(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             applications: [String] = ["/Applications/Codex.app", "/opt/homebrew/bin/codex",
                                                       "/usr/local/bin/codex"],
                             appInstalled: Bool = false) -> Bool {
        var directories = [home.appendingPathComponent(".codex").path]
        if let custom = environment["CODEX_HOME"], !custom.isEmpty {
            directories.append((custom as NSString).expandingTildeInPath)
        }
        let manager = FileManager.default
        let hasDirectory = directories.contains { path in
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let paths = applications + [home.appendingPathComponent(".local/bin/codex").path]
        return hasDirectory || appInstalled || paths.contains { manager.fileExists(atPath: $0) }
    }

    /// Détection réelle, jamais sous XCTest : un test ne dépend pas du Mac qui le lance.
    static var codexOnThisMac: Bool {
        NSClassFromString("XCTestCase") == nil
            && codexPresent(appInstalled: NSWorkspace.shared.urlForApplication(withBundleIdentifier: CodexBinary.appBundleId) != nil)
    }

    var hooksURL: URL { configDirectory.appendingPathComponent("hooks.json") }
    var configURL: URL { configDirectory.appendingPathComponent("config.toml") }
    var hookURL: URL { configDirectory.appendingPathComponent("hooks").appendingPathComponent(Self.hookFileName) }
    /// Chemin absolu entre guillemets.
    var hookCommand: String { "\"\(hookURL.path)\"" }

    // MARK: - Actions

    /// Copie le script de hook (755) puis ajoute nos entrées à hooks.json (un groupe par événement).
    /// hooks.json est validé avant toute écriture : en cas d'erreur, rien n'est touché.
    @discardableResult
    func install() throws -> Outcome {
        guard let bundledHook, let script = try? Data(contentsOf: bundledHook) else { throw Failure.missingBundledHook }
        let original = try loadHooks()
        var file = original
        try Self.addEntries(to: &file, command: hookCommand)
        try writeHookScript(script)
        return try save(file, replacing: original)
    }

    /// Retire nos entrées et le script. Un hooks.json qui n'avait que nos hooks disparaît (après sauvegarde).
    @discardableResult
    func uninstall() throws -> Outcome {
        let original = try loadHooks()
        var file = original
        Self.strip(&file)
        if file.members?.isEmpty == true, FileManager.default.fileExists(atPath: hooksURL.path) {
            let backup = try makeBackup()
            try FileManager.default.removeItem(at: hooksURL)
            removeHookScript()
            return Outcome(fileChanged: true, backup: backup)
        }
        let outcome = try save(file, replacing: original)
        removeHookScript()
        return outcome
    }

    // MARK: - Transformations (pures)

    /// Retire nos entrées, puis les groupes et événements que ce retrait a vidés ; `hooks` vide disparaît.
    static func strip(_ file: inout OrderedJSON) {
        guard case .object(let hooks)? = file["hooks"] else { return }
        var kept: [OrderedJSON.Member] = []
        for member in hooks {
            guard case .array(let groups) = member.value else {
                kept.append(member)
                continue
            }
            var keptGroups: [OrderedJSON] = []
            for var group in groups {
                if let inner = group["hooks"]?.items, inner.contains(where: isOurs) {
                    let remaining = inner.filter { !isOurs($0) }
                    if remaining.isEmpty { continue }
                    group["hooks"] = .array(remaining)
                }
                keptGroups.append(group)
            }
            if !keptGroups.isEmpty {
                kept.append(OrderedJSON.Member(key: member.key, value: .array(keptGroups)))
            } else if groups.isEmpty {
                kept.append(member)
            }
        }
        file["hooks"] = kept.isEmpty ? nil : .object(kept)
    }

    /// Retire nos anciennes entrées puis ajoute un groupe par événement, en fin de liste.
    static func addEntries(to file: inout OrderedJSON, command: String) throws {
        strip(&file)
        var hooks: OrderedJSON
        switch file["hooks"] {
        case nil: hooks = .object([])
        case .object(let members)?: hooks = .object(members)
        default: throw Failure.hooksNotObject
        }
        for event in events {
            var groups: [OrderedJSON]
            switch hooks[event] {
            case nil: groups = []
            case .array(let items)?: groups = items
            default: throw Failure.eventNotList(event)
            }
            groups.append(.object([OrderedJSON.Member(key: "hooks", value: .array([entry(event, command: command)]))]))
            hooks[event] = .array(groups)
        }
        file["hooks"] = hooks
    }

    /// Notre hook pour un événement : le relais asynchrone, ou la demande synchrone de `PermissionRequest`.
    static func entry(_ event: String, command: String) -> OrderedJSON {
        func member(_ key: String, _ value: OrderedJSON) -> OrderedJSON.Member { OrderedJSON.Member(key: key, value: value) }
        if event == "PermissionRequest" {
            return .object([
                member("type", .string("command")),
                member("command", .string(command + " permission")),
                member("timeout", .number(permissionTimeout)),
                member("statusMessage", .string(permissionStatus)),
            ])
        }
        return .object([
            member("type", .string("command")),
            member("command", .string(command)),
            member("async", .bool(true)),
            member("timeout", .number(shortEvents.contains(event) ? shortTimeout : relayTimeout)),
        ])
    }

    /// Un hook (objet) dont la commande contient « codex-notch-hook.sh ».
    static func isOurs(_ hook: OrderedJSON) -> Bool {
        guard hook.members != nil, let command = hook["command"] else { return false }
        let text = command.stringValue ?? String(decoding: command.serialized(), as: UTF8.self)
        return text.contains(marker)
    }

    // MARK: - État

    func status() -> Status {
        let file: OrderedJSON
        do {
            file = try loadHooks()
        } catch {
            return .unreadable(error.localizedDescription)
        }
        guard case .object(let hooks)? = file["hooks"] else { return .notInstalled }
        var present = 0
        var current = true
        for event in Self.events {
            let ours = (hooks.first { OrderedJSON.sameKey($0.key, event) }?.value.items ?? [])
                .compactMap { $0["hooks"]?.items }.flatMap { $0 }.filter(Self.isOurs)
            if !ours.isEmpty { present += 1 }
            if ours.count != 1 || !Self.sameObject(ours[0], Self.entry(event, command: hookCommand)) { current = false }
        }
        if present == 0 { return .notInstalled }
        if !current { return .outdated }
        return hookScriptIsCurrent ? .installed : .scriptOutdated
    }

    /// Lecture seule de `config.toml` : réglage, hooks en ligne, `notify`. Absent : valeurs vides.
    func configNotes() -> ConfigNotes {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return ConfigNotes() }
        return Self.configNotes(in: text)
    }

    static func configNotes(in text: String) -> ConfigNotes {
        var notes = ConfigNotes()
        var section = ""
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line
                if !line.hasPrefix("[hooks.state.") && !line.hasPrefix("[[hooks.state."),
                   line.hasPrefix("[hooks") || line.hasPrefix("[[hooks") {
                    notes.inlineHooks = true
                }
                continue
            }
            let key = line.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
            let value = line.split(separator: "=", maxSplits: 1).dropFirst().first
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if section == "[features]", key == "hooks" || key == "codex_hooks", value?.hasPrefix("false") == true {
                notes.hooksDisabled = true
            }
            if section.isEmpty, key == "notify" { notes.hasNotify = true }
        }
        return notes
    }

    // MARK: - Approbation (lecture seule)

    /// Clés que Codex donne à nos hooks dans `hooks.state` : `<hooks.json>:<événement>:<groupe>:<rang>`, l'événement
    /// en snake_case, le groupe et le rang étant leur position dans hooks.json (mesuré sur Codex 0.162).
    func hookKeys(path: String? = nil) -> [String] {
        guard let file = try? loadHooks(), case .object(let hooks)? = file["hooks"] else { return [] }
        let prefix = path ?? hooksURL.path
        var keys: [String] = []
        for event in Self.events {
            let groups = hooks.first { OrderedJSON.sameKey($0.key, event) }?.value.items ?? []
            for (group, item) in groups.enumerated() {
                for (rank, hook) in (item["hooks"]?.items ?? []).enumerated() where Self.isOurs(hook) {
                    keys.append("\(prefix):\(Self.snake(event)):\(group):\(rank)")
                }
            }
        }
        return keys
    }

    static func snake(_ event: String) -> String {
        event.reduce(into: "") { text, letter in
            if letter.isUppercase, !text.isEmpty { text.append("_") }
            text.append(contentsOf: letter.lowercased())
        }
    }

    /// Nos hooks que `config.toml` ne marque pas comme approuvés (un `trusted_hash` par clé). Estimation : seul Codex sait
    /// si un hachage est périmé (hook modifié depuis) ; `CodexHookSetup` la corrige avec la réponse de Codex.
    func unapprovedCount() -> Int {
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let trusted = Self.trustedKeys(in: text)
        let ours = Set(hookKeys() + hookKeys(path: Self.realPath(hooksURL.path)))
        let approved = Self.events.filter { event in
            ours.contains { key in trusted.contains(key) && key.contains(":\(Self.snake(event)):") }
        }.count
        return Self.events.count - approved
    }

    /// Clés des tables `[hooks.state."<clé>"]` qui portent un `trusted_hash` (forme que Codex écrit lui-même).
    static func trustedKeys(in text: String) -> Set<String> {
        var keys = Set<String>()
        var current: String?
        let prefix = "[hooks.state."
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = line.hasPrefix(prefix) ? unquotedKey(String(line.dropFirst(prefix.count))) : nil
            } else if let current, line.hasPrefix("trusted_hash"),
                      line.dropFirst("trusted_hash".count).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                keys.insert(current)
            }
        }
        return keys
    }

    /// `"clé"]` (début d'un nom de table TOML entre guillemets) -> `clé`, séquences `\\` et `\"` défaites.
    private static func unquotedKey(_ text: String) -> String? {
        guard text.hasPrefix("\"") else { return nil }
        var key = ""
        var escaped = false
        for character in text.dropFirst() {
            if escaped {
                key.append(character == "n" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return key
            } else {
                key.append(character)
            }
        }
        return nil
    }

    /// Hook de Oriel tel que Codex le liste : notre script, dans ce hooks.json.
    func isOurs(_ hook: CodexListedHook) -> Bool {
        let paths = [hooksURL.path, Self.realPath(hooksURL.path)]
        return hook.command.hasPrefix(hookCommand) && paths.contains(hook.sourcePath)
    }

    /// Chemin canonique, tel que Codex le donne dans les clés et `sourcePath` (/var -> /private/var, liens suivis).
    /// `resolvingSymlinksInPath` de Foundation ramène /private/var à /var : on passe par `realpath`.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Mêmes clés et mêmes valeurs, à l'ordre des clés près.
    private static func sameObject(_ hook: OrderedJSON, _ wanted: OrderedJSON) -> Bool {
        guard let members = hook.members, let expected = wanted.members, members.count == expected.count else {
            return false
        }
        return expected.allSatisfy { hook[$0.key] == $0.value }
    }

    /// Script présent, exécutable et identique à celui de l'app (s'il est connu).
    private var hookScriptIsCurrent: Bool {
        guard FileManager.default.isExecutableFile(atPath: hookURL.path) else { return false }
        guard let bundledHook else { return true }
        guard let installed = try? Data(contentsOf: hookURL), let expected = try? Data(contentsOf: bundledHook) else {
            return false
        }
        return installed == expected
    }

    // MARK: - Fichiers

    /// Fichier absent ou vide : objet vide. JSON invalide ou autre chose qu'un objet : erreur.
    func loadHooks() throws -> OrderedJSON {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return .object([]) }
        let data: Data
        do {
            data = try Data(contentsOf: hooksURL)
        } catch {
            throw Failure.io(String(format: L("Lecture de %@ impossible (%@).", table: "Codex"), hooksURL.path,
                                    error.localizedDescription))
        }
        if let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .object([])
        }
        let value: OrderedJSON
        do {
            value = try OrderedJSON.parse(data)
        } catch {
            throw Failure.invalidFile(String(describing: error))
        }
        guard value.members != nil else { throw Failure.notObject }
        return value
    }

    private func writeHookScript(_ script: Data) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: hookURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? Data(contentsOf: hookURL)) != script {
                try script.write(to: hookURL, options: .atomic)
            }
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
        } catch {
            throw Failure.io(String(format: L("Copie du script de hook impossible (%@) : "
                                              + "hooks.json n'a pas été modifié.", table: "Codex"), error.localizedDescription))
        }
    }

    private func removeHookScript() {
        let manager = FileManager.default
        try? manager.removeItem(at: hookURL)
        // Le dossier `hooks/` n'est retiré que s'il est vide : il peut contenir les scripts de l'utilisateur.
        let folder = hookURL.deletingLastPathComponent()
        if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? manager.removeItem(at: folder) }
    }

    /// Sauvegarde puis écriture atomique, seulement si quelque chose change.
    private func save(_ file: OrderedJSON, replacing original: OrderedJSON) throws -> Outcome {
        guard file != original else { return Outcome(fileChanged: false, backup: nil) }
        var data = file.serialized()
        data.append(0x0A)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            var backup: URL?
            if manager.fileExists(atPath: hooksURL.path) { backup = try makeBackup() }
            try writeAtomically(data)
            return Outcome(fileChanged: true, backup: backup)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.io(String(format: L("Écriture de %@ impossible (%@).", table: "Codex"), hooksURL.path,
                                    error.localizedDescription))
        }
    }

    /// `hooks.json.oriel-AAAAMMJJ-HHMMSS.bak`, suffixe -1, -2… en cas de collision.
    private func makeBackup() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = hooksURL.path + ".oriel-" + formatter.string(from: now())
        var backup = stem + ".bak"
        var counter = 1
        while FileManager.default.fileExists(atPath: backup) {
            backup = "\(stem)-\(counter).bak"
            counter += 1
        }
        let url = URL(fileURLWithPath: backup)
        try FileManager.default.copyItem(at: hooksURL.resolvingSymlinksInPath(), to: url)
        return url
    }

    /// Fichier temporaire dans le même dossier puis `rename` : jamais de hooks.json à moitié écrit. Droits de l'ancien
    /// fichier conservés (0644 sinon) ; un lien symbolique (dotfiles) reste un lien, sa cible est remplacée.
    private func writeAtomically(_ data: Data) throws {
        let manager = FileManager.default
        let target = manager.fileExists(atPath: hooksURL.path) ? hooksURL.resolvingSymlinksInPath() : hooksURL
        let mode = (try? manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".hooks.oriel-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
            guard rename(temporary.path, target.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }
}
