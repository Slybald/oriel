import Foundation

/// Retrait de l'ancien relais de `statusLine` (jauges de quota Claude, retirées en 3.5.0 : l'app Claude ne lance
/// jamais la `statusLine`, le quota ne venait donc que de `claude` dans un terminal).
///
/// Au lancement, si le script du relais traîne encore dans `~/.claude/hooks`, l'ancienne commande de `statusLine` revient
/// (ou la `statusLine` créée par Oriel part) et les deux fichiers sont supprimés. Une `statusLine` que l'utilisateur a
/// changée depuis n'est pas touchée. Sauvegarde horodatée et écriture atomique de `HookInstaller`.
struct StatusLineInstaller {
    static let scriptName = "oriel-statusline.sh"
    static let previousName = "oriel-statusline.previous"

    let base: HookInstaller

    /// ~/.claude. Sous XCTest, un dossier qui n'existe pas : un test ne lit ni n'écrit jamais le vrai settings.json.
    static var standard: StatusLineInstaller {
        guard NSClassFromString("XCTestCase") == nil else {
            let none = FileManager.default.temporaryDirectory.appendingPathComponent("oriel-no-config")
            return StatusLineInstaller(base: HookInstaller(configDirectory: none, bundledHook: nil))
        }
        return StatusLineInstaller(base: .standard)
    }

    var scriptURL: URL { base.configDirectory.appendingPathComponent("hooks").appendingPathComponent(Self.scriptName) }
    var previousURL: URL { base.configDirectory.appendingPathComponent("hooks").appendingPathComponent(Self.previousName) }

    /// Un fichier du relais est encore là : un simple `stat`, settings.json n'est pas lu sans raison.
    var hasLeftovers: Bool {
        [scriptURL, previousURL].contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Remet l'ancienne commande (ou retire la `statusLine` qu'on avait créée), puis supprime les fichiers du relais.
    /// settings.json illisible : erreur, fichiers gardés (la `statusLine` continue de marcher).
    @discardableResult
    func uninstall() throws -> HookInstaller.Outcome {
        let original = try base.loadSettings()
        var settings = original
        if let line = settings["statusLine"], let current = Self.commandText(line), Self.isOurs(current) {
            if let text = try? String(contentsOf: previousURL, encoding: .utf8), !text.isEmpty {
                var restored = line
                restored["command"] = .string(text)
                settings["statusLine"] = restored
            } else {
                settings["statusLine"] = nil
            }
        }
        let outcome = try base.save(settings, replacing: original)
        for url in [scriptURL, previousURL] where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        return outcome
    }

    /// Lancement : retrait silencieux s'il reste quelque chose.
    func removeLeftovers() {
        guard hasLeftovers else { return }
        _ = try? uninstall()
    }

    /// La commande d'une `statusLine` de type « command » ; nil pour tout autre forme.
    static func commandText(_ line: OrderedJSON) -> String? {
        guard line.members != nil, line["type"]?.stringValue == "command" else { return nil }
        return line["command"]?.stringValue
    }

    static func isOurs(_ command: String) -> Bool { command.contains(scriptName) }
}
