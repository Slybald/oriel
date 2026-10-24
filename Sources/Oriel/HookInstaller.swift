import Darwin
import Foundation

/// Ajoute ou retire les hooks de Oriel dans la configuration de Claude Code.
/// Équivalent de scripts/hooks_config.py, pour que l'app s'installe seule depuis un DMG.
///
/// Dossier de configuration : `~/.claude`. Une app ouverte depuis le Finder ne voit pas `CLAUDE_CONFIG_DIR`
/// (variable du shell) ; pour un autre dossier, il reste scripts/install.sh. Le dossier est injectable (tests).
///
/// - Idempotent : nos entrées (repérées par « oriel-hook.sh ») sont retirées puis rajoutées.
/// - Les autres hooks et l'ordre des clés sont conservés ; JSON invalide : rien n'est touché.
/// - Sauvegarde horodatée avant toute écriture, aucune écriture si rien ne change, écriture atomique.
struct HookInstaller {
    static let hookFileName = "oriel-hook.sh"
    static let marker = hookFileName
    static let events = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "PermissionRequest",
        "Notification",
        "Stop",
        "StopFailure",
        "SubagentStart",
        "SubagentStop",
        "TaskCreated",
        "TaskCompleted",
        "PreCompact",
        "PostCompact",
    ]
    static let timeout = "10"
    /// Hook PermissionRequest synchrone : sous le timeout, l'app rend toujours la main (~590 s au plus).
    static let permissionTimeout = "600"
    /// Attente `asyncRewake` d'un message : 24 h.
    static let inboxTimeout = "86400"
    /// Lus par Claude avec le message (même texte que hooks_config.py).
    static let rewakeMessage = "Message from the user, sent from Oriel:"
    static let rewakeSummary = "Message from Oriel"
    /// Textes d'avant le renommage : une session ouverte avant la mise à jour garde ses hooks d'alors.
    static let legacyRewakeMessage = "Message from the user, sent from Claude Notch:"
    static let legacyRewakeSummary = "Message from Claude Notch"

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
        case invalidSettings(String)
        case settingsNotObject
        case hooksNotObject
        case eventNotList(String)
        case missingBundledHook
        case io(String)

        var errorDescription: String? {
            switch self {
            case .invalidSettings(let detail):
                return String(format: L("settings.json invalide (%@) : rien n'a été modifié."), detail)
            case .settingsNotObject:
                return L("settings.json n'est pas un objet JSON : rien n'a été modifié.")
            case .hooksNotObject:
                return L("La clé « hooks » de settings.json n'est pas un objet : rien n'a été modifié.")
            case .eventNotList(let event):
                return String(format: L("hooks.%@ n'est pas une liste : rien n'a été modifié."), event)
            case .missingBundledHook:
                return String(format: L("Script de hook introuvable dans l'app (Contents/Resources/%@) : "
                                        + "rien n'a été modifié."), HookInstaller.hookFileName)
            case .io(let detail):
                return detail
            }
        }
    }

    struct Outcome: Equatable {
        /// settings.json réécrit (faux s'il était déjà à jour).
        var settingsChanged: Bool
        /// Copie de l'ancien settings.json, s'il existait.
        var backup: URL?
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

    /// ~/.claude et le script embarqué dans l'app.
    static var standard: HookInstaller {
        HookInstaller(configDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
                      bundledHook: Bundle.main.url(forResource: "oriel-hook", withExtension: "sh"))
    }

    /// Claude Code présent sur ce Mac : `~/.claude` ou `$CLAUDE_CONFIG_DIR` existe. Des hooks de Oriel déjà
    /// posés vivent dans `~/.claude` : ils sont couverts.
    static func claudeCodePresent(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        var paths = [home.appendingPathComponent(".claude").path]
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            paths.append((custom as NSString).expandingTildeInPath)
        }
        return paths.contains { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Détection réelle, jamais sous XCTest : un test ne dépend pas du Mac qui le lance.
    static var claudeCodeOnThisMac: Bool { NSClassFromString("XCTestCase") == nil && claudeCodePresent() }

    var settingsURL: URL { configDirectory.appendingPathComponent("settings.json") }
    var hookURL: URL { configDirectory.appendingPathComponent("hooks").appendingPathComponent(Self.hookFileName) }
    /// Chemin absolu entre guillemets, comme hooks_config.py.
    var hookCommand: String { "\"\(hookURL.path)\"" }

    // MARK: - Actions

    /// Copie le script de hook (755) puis ajoute nos entrées à settings.json (un groupe par événement).
    /// settings.json est validé avant toute écriture : en cas d'erreur, rien n'est touché.
    @discardableResult
    func install() throws -> Outcome {
        guard let bundledHook, let script = try? Data(contentsOf: bundledHook) else { throw Failure.missingBundledHook }
        let original = try loadSettings()
        var settings = original
        try Self.addEntries(to: &settings, command: hookCommand)
        try writeHookScript(script)
        return try save(settings, replacing: original)
    }

    /// Réécrit seulement le script de hook, sans toucher à settings.json (entrées déjà à jour).
    func updateScript() throws {
        guard let bundledHook, let script = try? Data(contentsOf: bundledHook) else { throw Failure.missingBundledHook }
        try writeHookScript(script)
    }

    /// Retire nos entrées (et ce qu'elles laissent vide), puis le script de hook.
    /// settings.json illisible : erreur, et le script reste en place (settings.json y renvoie peut-être encore).
    @discardableResult
    func uninstall() throws -> Outcome {
        let original = try loadSettings()
        var settings = original
        Self.strip(&settings, dropEmptyRoot: true)
        let outcome = try save(settings, replacing: original)
        if FileManager.default.fileExists(atPath: hookURL.path) {
            do {
                try FileManager.default.removeItem(at: hookURL)
            } catch {
                throw Failure.io(String(format: L("Suppression de %@ impossible (%@)."), hookURL.path,
                                        error.localizedDescription))
            }
        }
        return outcome
    }

    /// État actuel, sans rien modifier.
    func status() -> Status {
        let settings: OrderedJSON
        do {
            settings = try loadSettings()
        } catch {
            return .unreadable(error.localizedDescription)
        }
        var ours: [String: [OrderedJSON]] = [:]
        switch settings["hooks"] {
        case nil:
            break
        case .object(let members)?:
            for member in members {
                for group in member.value.items ?? [] {
                    for hook in group["hooks"]?.items ?? [] where Self.isOurs(hook) {
                        ours[member.key, default: []].append(hook)
                    }
                }
            }
        default:
            return .unreadable(Failure.hooksNotObject.localizedDescription)
        }
        if ours.isEmpty { return .notInstalled }
        let expected = Self.entries(command: hookCommand)
        let entriesCurrent = Set(ours.keys) == Set(Self.events) && ours.allSatisfy { event, hooks in
            let wanted = expected[event] ?? []
            return hooks.count == wanted.count && zip(hooks, wanted).allSatisfy(Self.sameObject)
        }
        guard entriesCurrent else { return .outdated }
        return hookScriptIsCurrent ? .installed : .scriptOutdated
    }

    // MARK: - Transformations (pures)

    /// Retire nos entrées, puis les groupes et événements que ce retrait a vidés.
    /// Un événement déjà vide avant (`[]`) reste tel quel, comme dans hooks_config.py.
    static func strip(_ settings: inout OrderedJSON, dropEmptyRoot: Bool) {
        guard case .object(let hooks)? = settings["hooks"] else { return }
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
        settings["hooks"] = dropEmptyRoot && kept.isEmpty ? nil : .object(kept)
    }

    /// Retire nos anciennes entrées puis ajoute un groupe par événement, en fin de liste.
    /// « hooks » est créé en fin de fichier s'il manque ; un nouvel événement va en fin de « hooks ».
    static func addEntries(to settings: inout OrderedJSON, command: String) throws {
        strip(&settings, dropEmptyRoot: false)
        var hooks: OrderedJSON
        switch settings["hooks"] {
        case nil: hooks = .object([])
        case .object(let members)?: hooks = .object(members)
        default: throw Failure.hooksNotObject
        }
        let ours = entries(command: command)
        for event in events {
            var groups: [OrderedJSON]
            switch hooks[event] {
            case nil: groups = []
            case .array(let items)?: groups = items
            default: throw Failure.eventNotList(event)
            }
            groups.append(.object([OrderedJSON.Member(key: "hooks", value: .array(ours[event] ?? []))]))
            hooks[event] = .array(groups)
        }
        settings["hooks"] = hooks
    }

    /// Nos hooks par événement, dans l'ordre écrit : le relais async partout ; pour « Répondre depuis la notch »,
    /// le hook PermissionRequest synchrone (sans `onFailure` : un échec rend la main au terminal) et l'attente
    /// `asyncRewake` de SessionStart et Stop.
    static func entries(command: String) -> [String: [OrderedJSON]] {
        let relay = entry(command: command)
        let permission = OrderedJSON.object([
            OrderedJSON.Member(key: "type", value: .string("command")),
            OrderedJSON.Member(key: "command", value: .string(command + " permission")),
            OrderedJSON.Member(key: "timeout", value: .number(permissionTimeout)),
        ])
        let inbox = OrderedJSON.object([
            OrderedJSON.Member(key: "type", value: .string("command")),
            OrderedJSON.Member(key: "command", value: .string(command + " inbox")),
            OrderedJSON.Member(key: "asyncRewake", value: .bool(true)),
            OrderedJSON.Member(key: "timeout", value: .number(inboxTimeout)),
            OrderedJSON.Member(key: "rewakeMessage", value: .string(rewakeMessage)),
            OrderedJSON.Member(key: "rewakeSummary", value: .string(rewakeSummary)),
        ])
        let extra = ["SessionStart": [inbox], "PermissionRequest": [permission], "Stop": [inbox]]
        return Dictionary(uniqueKeysWithValues: events.map { ($0, [relay] + (extra[$0] ?? [])) })
    }

    /// Relais async d'un événement.
    static func entry(command: String) -> OrderedJSON {
        .object([
            OrderedJSON.Member(key: "type", value: .string("command")),
            OrderedJSON.Member(key: "command", value: .string(command)),
            OrderedJSON.Member(key: "async", value: .bool(true)),
            OrderedJSON.Member(key: "timeout", value: .number(timeout)),
        ])
    }

    /// Un hook (objet) dont la commande contient « oriel-hook.sh ». Une commande qui n'est pas
    /// une chaîne est lue sous forme de texte, comme `str()` en Python.
    static func isOurs(_ hook: OrderedJSON) -> Bool {
        guard hook.members != nil, let command = hook["command"] else { return false }
        let text = command.stringValue ?? String(decoding: command.serialized(), as: UTF8.self)
        return containsMarker(text)
    }

    /// Recherche octet par octet (pas de regroupement Unicode, comme `in` en Python).
    private static func containsMarker(_ text: String) -> Bool {
        let haystack = Array(text.utf8)
        let needle = Array(marker.utf8)
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
            where haystack[start..<start + needle.count].elementsEqual(needle) {
            return true
        }
        return false
    }

    // MARK: - État

    /// Mêmes clés et mêmes valeurs, à l'ordre des clés près.
    private static func sameObject(_ hook: OrderedJSON, _ wanted: OrderedJSON) -> Bool {
        guard let members = hook.members, let expected = wanted.members, members.count == expected.count else {
            return false
        }
        return expected.allSatisfy { hook[$0.key] == $0.value }
    }

    /// Script présent, exécutable et identique à celui de l'app (s'il est connu).
    private var hookScriptIsCurrent: Bool {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: hookURL.path) else { return false }
        guard let bundledHook else { return true }
        guard let installed = try? Data(contentsOf: hookURL), let expected = try? Data(contentsOf: bundledHook) else {
            return false
        }
        return installed == expected
    }

    // MARK: - Fichiers

    /// Fichier absent ou vide : objet vide. JSON invalide ou autre chose qu'un objet : erreur.
    func loadSettings() throws -> OrderedJSON {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return .object([]) }
        let data: Data
        do {
            data = try Data(contentsOf: settingsURL)
        } catch {
            throw Failure.io(String(format: L("Lecture de %@ impossible (%@)."), settingsURL.path,
                                    error.localizedDescription))
        }
        if let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .object([])
        }
        let value: OrderedJSON
        do {
            value = try OrderedJSON.parse(data)
        } catch {
            throw Failure.invalidSettings(String(describing: error))
        }
        guard value.members != nil else { throw Failure.settingsNotObject }
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
                                              + "settings.json n'a pas été modifié."), error.localizedDescription))
        }
    }

    /// Sauvegarde puis écriture atomique, seulement si quelque chose change (aussi pour `StatusLineInstaller`).
    func save(_ settings: OrderedJSON, replacing original: OrderedJSON) throws -> Outcome {
        guard settings != original else { return Outcome(settingsChanged: false, backup: nil) }
        var data = settings.serialized()
        data.append(0x0A)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            var backup: URL?
            if manager.fileExists(atPath: settingsURL.path) { backup = try makeBackup() }
            try writeAtomically(data)
            return Outcome(settingsChanged: true, backup: backup)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.io(String(format: L("Écriture de %@ impossible (%@)."), settingsURL.path,
                                    error.localizedDescription))
        }
    }

    /// `settings.json.oriel-AAAAMMJJ-HHMMSS.bak`, suffixe -1, -2… en cas de collision.
    /// Copie du contenu (un lien symbolique est suivi), dates et droits conservés.
    private func makeBackup() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = settingsURL.path + ".oriel-" + formatter.string(from: now())
        var backup = stem + ".bak"
        var counter = 1
        while FileManager.default.fileExists(atPath: backup) {
            backup = "\(stem)-\(counter).bak"
            counter += 1
        }
        let url = URL(fileURLWithPath: backup)
        try FileManager.default.copyItem(at: settingsURL.resolvingSymlinksInPath(), to: url)
        return url
    }

    /// Fichier temporaire dans le même dossier puis `rename` : jamais de settings.json à moitié écrit.
    /// Droits de l'ancien fichier conservés (0644 sinon). Un settings.json en lien symbolique (dotfiles)
    /// reste un lien : c'est sa cible qui est remplacée.
    private func writeAtomically(_ data: Data) throws {
        let manager = FileManager.default
        let target = manager.fileExists(atPath: settingsURL.path) ? settingsURL.resolvingSymlinksInPath() : settingsURL
        let mode = (try? manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".settings.oriel-\(UUID().uuidString)")
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
