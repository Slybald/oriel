import Foundation

// Autorisation « sans mot de passe » de l'économie d'énergie : une règle sudoers qui n'autorise que deux commandes,
// `pmset -a lowpowermode 0` et `... 1`. Elle est posée une fois, à la demande de l'utilisateur (un mot de passe
// administrateur), puis la bascule passe par `sudo -n`. Tout ce fichier est pur : il fabrique des textes et des
// arguments, il n'exécute rien. Les tests n'ont donc besoin ni de sudo ni d'AppleScript, et n'écrivent pas dans /etc.

/// Où en est l'autorisation.
enum LowPowerAuthorizationState: Equatable {
    /// Pas de règle : la prochaine bascule la pose, dans la même fenêtre d'autorisation (un mot de passe, une fois).
    case onFirstUse
    /// Pas de règle, retirée par l'utilisateur : Touch ID ou le mot de passe est demandé à chaque bascule.
    case none
    /// Règle en place : la bascule se fait sans mot de passe.
    case granted
    /// La règle est là mais sudo l'a refusée (autre utilisateur, fichier modifié…) : le mot de passe est redemandé.
    case refused
}

/// Comment une écriture a abouti.
enum LowPowerWrite: Equatable {
    case done
    /// L'écriture a réussi avec le mot de passe, parce que la règle n'a pas marché.
    case authorizationRefused
}

enum LowPowerAuthorization {
    /// Sans point : sudo ignore les fichiers de sudoers.d dont le nom contient un point ou finit par `~`.
    static let rulePath = "/etc/sudoers.d/oriel-lowpower"
    /// Faux après « Retirer l'autorisation » : l'app ne repose plus la règle d'elle-même.
    static let autoAuthorizeKey = "quickSettings.lowPower.autoAuthorize"

    static let sudoPath = "/usr/bin/sudo"
    static let pmsetPath = "/usr/bin/pmset"
    static let visudoPath = "/usr/sbin/visudo"
    static let installPath = "/usr/bin/install"
    static let removePath = "/bin/rm"
    static let mktempPath = "/usr/bin/mktemp"
    static let printfPath = "/usr/bin/printf"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: rulePath) }

    // MARK: - Règle

    /// Caractères permis dans un nom d'utilisateur écrit dans sudoers : ni espace, ni `#` (identifiant), `%`
    /// (groupe), `+` (netgroup), `!`, `,`, `:`, `=`, `\`, ni saut de ligne. Tout est testé caractère par caractère
    /// (une expression avec `$` accepterait un saut de ligne final, donc une deuxième ligne de règle).
    static func isValidUser(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...64).contains(bytes.count), bytes[0] != UInt8(ascii: "-"),
              name != "ALL" else { return false } // « ALL » serait lu comme « tous les utilisateurs »
        return bytes.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    /// Contenu exact du fichier ; nil si le nom d'utilisateur n'est pas sûr (aucune règle n'est alors écrite).
    /// ASCII seulement : sudo lit ce fichier en tant que root.
    static func ruleContents(forUser user: String) -> String? {
        guard isValidUser(user) else { return nil }
        return [
            "# Oriel : active ou coupe l'economie d'energie sans demander le mot de passe.",
            "# Pour retirer cette autorisation : sudo rm \(rulePath)",
            "\(user) ALL=(root) NOPASSWD: \(pmsetPath) -a lowpowermode 0, \(pmsetPath) -a lowpowermode 1",
        ].joined(separator: "\n") + "\n"
    }

    // MARK: - Commandes

    /// `sudo -n` : jamais de question, il échoue si la règle ne s'applique pas. Arguments séparés, aucun shell.
    static func sudoArguments(lowPower on: Bool) -> [String] {
        ["-n", pmsetPath, "-a", "lowpowermode", on ? "1" : "0"]
    }

    /// Commande de bascule avec mot de passe (repli, et usage sans règle).
    static func pmsetShellCommand(lowPower on: Bool) -> String {
        "\(pmsetPath) -a lowpowermode \(on ? 1 : 0)"
    }

    /// Modèle du fichier de travail de root : `mktemp` le crée en 0600, propriété de root, dans /tmp (sticky bit :
    /// personne d'autre ne peut le modifier, le remplacer ni le renommer).
    static let workFileTemplate = "/tmp/oriel.XXXXXX"

    /// Commande lancée en root. Aucun fichier côté utilisateur : root crée lui-même son fichier de travail, y écrit
    /// la règle (les lignes passent par `printf`, chacune entre apostrophes), la valide, puis seulement l'installe.
    /// Rien n'entre dans sudoers.d sans que `visudo -c` ait réussi (un fichier faux peut casser sudo pour tout le
    /// monde), et le fichier vérifié est celui qui est installé : un autre processus de l'utilisateur ne peut pas le
    /// changer entre les deux. Le fichier de travail est supprimé dans tous les cas, et la commande rend le code
    /// de visudo ou d'install.
    static func installShellCommand(ruleContents: String) -> String {
        let lines = ruleContents.split(separator: "\n").map { shellQuote(String($0)) }.joined(separator: " ")
        return "T=$(\(mktempPath) \(workFileTemplate)) || exit 1; \(printfPath) '%s\\n' \(lines) > \"$T\""
            + " && \(visudoPath) -cf \"$T\""
            + " && \(installPath) -m 0440 -o root -g wheel \"$T\" \(rulePath);"
            + " R=$?; \(removePath) -f \"$T\"; exit $R"
    }

    /// Première bascule : la même fenêtre d'autorisation change le mode et pose la règle. La pose tourne dans un
    /// sous-shell : son échec ne change pas le résultat de la bascule (la suivante redemandera le mot de passe).
    static func pmsetAndInstallShellCommand(lowPower on: Bool, ruleContents: String) -> String {
        "\(pmsetShellCommand(lowPower: on)); P=$?; ( \(installShellCommand(ruleContents: ruleContents)) ); exit $P"
    }

    static let removeShellCommand = "\(removePath) -f \(rulePath)"

    /// Le texte entre guillemets simples pour /bin/sh ; une apostrophe devient `'\''`.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Script AppleScript qui lance `shell` en root (fenêtre d'autorisation du système). `shell` est mis dans un
    /// littéral AppleScript : on y double les barres obliques inverses et on protège les guillemets.
    /// `prompt` : texte affiché dans la fenêtre d'autorisation du système.
    static func administratorScript(running shell: String, prompt: String? = nil) -> String {
        let withPrompt = prompt.map { " with prompt \"\(appleScriptLiteral($0))\"" } ?? ""
        return "do shell script \"\(appleScriptLiteral(shell))\"\(withPrompt) with administrator privileges"
    }

    private static func appleScriptLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - Désinstallation de l'app

    /// À brancher dans la désinstallation de l'app : retire la règle si elle existe (une demande de mot de passe
    /// administrateur), sinon réussit tout de suite sans rien demander. `completion` arrive sur le fil principal.
    static func remove(power: PowerModeBackend = SystemPowerMode(), isInstalled: () -> Bool = { LowPowerAuthorization.isInstalled },
                       completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void) {
        guard isInstalled() else { return completion(.success(())) }
        power.revokeAuthorization(completion: completion)
    }
}
