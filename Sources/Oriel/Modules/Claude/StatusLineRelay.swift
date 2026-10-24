import Foundation

/// Pose et retire le relais de `statusLine` (jauges de quota Claude), dans `~/.claude/settings.json`.
///
/// Claude Code n'accepte qu'UNE commande de `statusLine` et c'est la seule source du quota (les hooks n'ont pas ces champs) :
/// le relais prend sa place, envoie `rate_limits` à l'app puis relance l'ancienne commande avec le même JSON.
/// - Jamais sans clic : l'installation part du réglage « Jauges de quota » (Réglages › Claude).
/// - L'ancienne commande est copiée dans `oriel-statusline.previous` (0600, à côté du script) ; ses autres
///   clés (`padding`, `refreshInterval`) et l'ordre du fichier ne bougent pas. Retrait : elle revient telle quelle.
/// - Une `statusLine` qui n'est pas une simple commande (type inconnu, commande absente) est refusée, rien n'est touché.
/// - Réutilise la lecture, la sauvegarde horodatée et l'écriture atomique de `HookInstaller`.
struct StatusLineInstaller {
    static let scriptName = "oriel-statusline.sh"
    static let previousName = "oriel-statusline.previous"

    enum Status: Equatable {
        case notInstalled
        case installed
        /// Posé, mais le script diffère de celui de l'app (app mise à jour).
        case scriptOutdated
        /// `statusLine` qui n'est pas une commande : on n'y touche pas.
        case unsupported
        case unreadable(String)
    }

    enum Failure: LocalizedError, Equatable {
        case unsupportedStatusLine
        case missingBundledScript
        case io(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedStatusLine:
                return L("La « statusLine » de settings.json n'est pas une simple commande : rien n'a été modifié.",
                         table: "Claude")
            case .missingBundledScript:
                return String(format: L("Script introuvable dans l'app (Contents/Resources/%@) : rien n'a été modifié.",
                                        table: "Claude"), StatusLineInstaller.scriptName)
            case .io(let detail):
                return detail
            }
        }
    }

    let base: HookInstaller
    /// Script embarqué dans l'app (Contents/Resources) ; nil hors bundle (`swift run`).
    let bundledScript: URL?

    init(base: HookInstaller, bundledScript: URL?) {
        self.base = base
        self.bundledScript = bundledScript
    }

    /// ~/.claude et le script embarqué dans l'app. Sous XCTest, un dossier qui n'existe pas : un test ne lit ni n'écrit
    /// jamais le vrai settings.json (même règle que `HookInstaller.claudeCodeOnThisMac`).
    static var standard: StatusLineInstaller {
        guard NSClassFromString("XCTestCase") == nil else {
            let none = FileManager.default.temporaryDirectory.appendingPathComponent("oriel-no-config")
            return StatusLineInstaller(base: HookInstaller(configDirectory: none, bundledHook: nil), bundledScript: nil)
        }
        return StatusLineInstaller(base: .standard,
                                   bundledScript: Bundle.main.url(forResource: "oriel-statusline", withExtension: "sh"))
    }

    var scriptURL: URL { base.configDirectory.appendingPathComponent("hooks").appendingPathComponent(Self.scriptName) }
    var previousURL: URL { base.configDirectory.appendingPathComponent("hooks").appendingPathComponent(Self.previousName) }
    /// Chemin absolu entre guillemets, comme la commande des hooks.
    var command: String { "\"\(scriptURL.path)\"" }

    /// L'ancienne commande que le relais relance, s'il y en a une.
    var previousCommand: String? {
        guard let text = try? String(contentsOf: previousURL, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    // MARK: - État

    func status() -> Status {
        let settings: OrderedJSON
        do { settings = try base.loadSettings() } catch { return .unreadable(error.localizedDescription) }
        guard let line = settings["statusLine"] else { return .notInstalled }
        guard let current = Self.commandText(line) else { return .unsupported }
        guard Self.isOurs(current) else { return .notInstalled }
        return scriptIsCurrent ? .installed : .scriptOutdated
    }

    // MARK: - Actions

    /// Copie le script (755), garde l'ancienne commande puis met le relais à sa place. Le script et l'ancienne commande
    /// sont écrits AVANT settings.json : une interruption laisse des fichiers inertes, jamais un relais sans script.
    @discardableResult
    func install() throws -> HookInstaller.Outcome {
        guard let bundledScript, let script = try? Data(contentsOf: bundledScript) else { throw Failure.missingBundledScript }
        let original = try base.loadSettings()
        var settings = original
        let previous = try Self.attach(&settings, command: command)
        try write(script: script, previous: previous)
        return try base.save(settings, replacing: original)
    }

    /// Réécrit seulement le script (app mise à jour), sans toucher à settings.json.
    func updateScript() throws {
        guard let bundledScript, let script = try? Data(contentsOf: bundledScript) else { throw Failure.missingBundledScript }
        try write(script: script, previous: .keep)
    }

    /// Remet l'ancienne commande (ou retire la `statusLine` qu'on avait créée), puis supprime le script. Une
    /// `statusLine` que l'utilisateur a changée depuis n'est pas touchée. settings.json illisible : erreur, fichiers gardés.
    @discardableResult
    func uninstall() throws -> HookInstaller.Outcome {
        let original = try base.loadSettings()
        var settings = original
        if let line = settings["statusLine"], let current = Self.commandText(line), Self.isOurs(current) {
            if let previous = previousCommand {
                var restored = line
                restored["command"] = .string(previous)
                settings["statusLine"] = restored
            } else {
                settings["statusLine"] = nil
            }
        }
        let outcome = try base.save(settings, replacing: original)
        for url in [scriptURL, previousURL] where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw Failure.io(String(format: L("Suppression de %@ impossible (%@).", table: "Claude"), url.path,
                                        error.localizedDescription))
            }
        }
        return outcome
    }

    // MARK: - Transformations (pures)

    enum Previous: Equatable {
        /// Ne pas toucher au fichier de l'ancienne commande.
        case keep
        /// Pas d'ancienne commande : le fichier est supprimé s'il traîne.
        case none
        case command(String)
    }

    /// Met notre commande dans `statusLine`. Renvoie ce qu'il faut garder de l'ancienne.
    static func attach(_ settings: inout OrderedJSON, command: String) throws -> Previous {
        guard let line = settings["statusLine"] else {
            settings["statusLine"] = .object([
                OrderedJSON.Member(key: "type", value: .string("command")),
                OrderedJSON.Member(key: "command", value: .string(command)),
            ])
            return .none
        }
        guard let current = commandText(line) else { throw Failure.unsupportedStatusLine }
        var updated = line
        updated["command"] = .string(command)
        settings["statusLine"] = updated
        return isOurs(current) ? .keep : .command(current)
    }

    /// La commande d'une `statusLine` de type « command » ; nil pour tout autre forme.
    static func commandText(_ line: OrderedJSON) -> String? {
        guard line.members != nil, line["type"]?.stringValue == "command" else { return nil }
        return line["command"]?.stringValue
    }

    static func isOurs(_ command: String) -> Bool { command.contains(scriptName) }

    // MARK: - Fichiers

    private var scriptIsCurrent: Bool {
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else { return false }
        guard let bundledScript else { return true }
        return (try? Data(contentsOf: scriptURL)) == (try? Data(contentsOf: bundledScript))
    }

    private func write(script: Data, previous: Previous) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch previous {
            case .keep:
                break
            case .none:
                try? manager.removeItem(at: previousURL)
            case .command(let text):
                try Data(text.utf8).write(to: previousURL, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previousURL.path)
            }
            if (try? Data(contentsOf: scriptURL)) != script { try script.write(to: scriptURL, options: .atomic) }
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw Failure.io(String(format: L("Copie du relais impossible (%@) : settings.json n'a pas été modifié.",
                                              table: "Claude"), error.localizedDescription))
        }
    }
}

/// État du relais pour les réglages : relu à l'ouverture du volet et après chaque action (jamais dans `init`).
final class StatusLineSetup: ObservableObject {
    static let shared = StatusLineSetup()

    @Published private(set) var status: StatusLineInstaller.Status = .notInstalled
    /// Une commande de statusLine existait : le relais la relance.
    @Published private(set) var chainsPrevious = false
    @Published private(set) var message: String?
    @Published private(set) var messageIsError = false

    private let makeInstaller: () -> StatusLineInstaller
    private let usage: ClaudeUsageStore

    init(installer: @escaping () -> StatusLineInstaller = { .standard }, usage: ClaudeUsageStore = .shared) {
        makeInstaller = installer
        self.usage = usage
    }

    var isOn: Bool { status == .installed || status == .scriptOutdated }

    func refresh() {
        let installer = makeInstaller()
        let current = installer.status()
        if current != status { status = current }
        let chains = installer.previousCommand != nil
        if chains != chainsPrevious { chainsPrevious = chains }
    }

    /// Mise à jour silencieuse du script au lancement (relais déjà accepté par l'utilisateur), onglet Claude activé.
    func updateScriptIfNeeded() {
        refresh()
        guard status == .scriptOutdated else { return }
        try? makeInstaller().updateScript()
        refresh()
    }

    func setOn(_ on: Bool) {
        do {
            let installer = makeInstaller()
            if on {
                let outcome = try installer.install()
                message = outcome.backup.map { String(format: L("Relais posé. Sauvegarde : %@", table: "Claude"),
                                                      $0.lastPathComponent) } ?? L("Relais posé.", table: "Claude")
            } else {
                let outcome = try installer.uninstall()
                usage.forget()
                message = outcome.settingsChanged ? L("Relais retiré, ta statusLine d'origine est revenue.", table: "Claude")
                    : L("Rien à retirer.", table: "Claude")
            }
            messageIsError = false
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
        refresh()
    }
}
