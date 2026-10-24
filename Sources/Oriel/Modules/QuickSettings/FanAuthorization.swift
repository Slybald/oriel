import CryptoKit
import Foundation

// Autorisation du pilotage des ventilateurs : l'outil `fanctl` (compilé avec l'app) est copié une fois, sur clic de
// l'utilisateur et avec un mot de passe administrateur, dans un dossier de root ; une règle sudoers permet ensuite de
// le lancer sans mot de passe, avec exactement `auto` ou `hold`. Même méthode que `LowPowerAuthorization` : tout
// se fait côté root, rien ne passe par un fichier que l'utilisateur pourrait modifier, et visudo valide la règle
// avant qu'elle n'entre dans sudoers.d. Tout ce fichier est pur : il fabrique des textes, il n'exécute rien.

enum FanAuthorizationState: Equatable {
    case notInstalled
    case installed
    /// L'outil installé n'est pas celui de cette version de l'app : il sera remplacé au prochain passage en manuel.
    case outdated
}

enum FanAuthorization {
    /// Jamais dans le bundle de l'app (modifiable par l'utilisateur) : un dossier de root, root:wheel 0755.
    static let helperPath = "/Library/PrivilegedHelperTools/io.github.slybald.oriel.fanctl"
    /// Sans point : sudo ignore les fichiers de sudoers.d dont le nom en contient un.
    static let rulePath = "/etc/sudoers.d/oriel-fans"

    static let copyPath = "/bin/cp"
    static let mkdirPath = "/bin/mkdir"
    static let shasumPath = "/usr/bin/shasum"
    static let cutPath = "/usr/bin/cut"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: helperPath) && FileManager.default.fileExists(atPath: rulePath)
    }

    /// L'outil fourni avec l'app : `Contents/Helpers/fanctl` dans le bundle, sinon à côté de l'exécutable
    /// (`swift run`). nil : introuvable, la vitesse fixe n'est pas proposée.
    static func bundledHelper(_ bundle: Bundle = .main) -> URL? {
        let candidates = [bundle.bundleURL.appendingPathComponent("Contents/Helpers/fanctl"),
                          bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("fanctl")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Empreinte SHA-256 en hexadécimal minuscule ; nil si le fichier est illisible.
    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Règle

    /// Contenu exact de la règle ; nil si le nom d'utilisateur n'est pas sûr. Deux commandes complètes, arguments
    /// compris : sudo refuse tout autre argument.
    static func ruleContents(forUser user: String) -> String? {
        guard LowPowerAuthorization.isValidUser(user) else { return nil }
        return [
            "# Oriel : pilote les ventilateurs (automatique ou vitesse fixe bornee) sans mot de passe.",
            "# Pour retirer cette autorisation : sudo rm \(rulePath) \(helperPath)",
            "\(user) ALL=(root) NOPASSWD: \(helperPath) auto, \(helperPath) hold",
        ].joined(separator: "\n") + "\n"
    }

    // MARK: - Commandes

    /// `sudo -n` : jamais de question. `command` vaut `auto` ou `hold`, rien d'autre (la règle n'autorise que ça).
    static func sudoArguments(_ command: String) -> [String] {
        precondition(command == "auto" || command == "hold")
        return ["-n", helperPath, command]
    }

    /// Commande lancée en root. root crée ses deux fichiers de travail (mktemp : 0600, à lui), y copie l'outil du
    /// bundle et vérifie son empreinte (celle que l'app a lue : un échange entre la lecture et la copie est refusé),
    /// écrit la règle et la fait valider par visudo, puis seulement installe l'outil et la règle. Les fichiers de
    /// travail sont supprimés dans tous les cas ; la commande rend le code de la première étape en échec.
    static func installShellCommand(helperSource: String, sha256: String, ruleContents: String) -> String? {
        guard sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        let q = LowPowerAuthorization.shellQuote
        let lines = ruleContents.split(separator: "\n").map { q(String($0)) }.joined(separator: " ")
        let mktemp = "\(LowPowerAuthorization.mktempPath) \(LowPowerAuthorization.workFileTemplate)"
        let install = LowPowerAuthorization.installPath
        return "T=$(\(mktemp)) || exit 1; B=$(\(mktemp)) || { \(LowPowerAuthorization.removePath) -f \"$T\"; exit 1; };"
            + " \(copyPath) \(q(helperSource)) \"$B\""
            + " && [ \"$(\(shasumPath) -a 256 \"$B\" | \(cutPath) -c1-64)\" = \(sha256) ]"
            + " && \(LowPowerAuthorization.printfPath) '%s\\n' \(lines) > \"$T\""
            + " && \(LowPowerAuthorization.visudoPath) -cf \"$T\""
            + " && \(mkdirPath) -p /Library/PrivilegedHelperTools"
            + " && \(install) -m 0755 -o root -g wheel \"$B\" \(helperPath)"
            + " && \(install) -m 0440 -o root -g wheel \"$T\" \(rulePath);"
            + " R=$?; \(LowPowerAuthorization.removePath) -f \"$T\" \"$B\"; exit $R"
    }

    /// Rend d'abord les ventilateurs à macOS (si l'outil est là), puis retire la règle et l'outil.
    static let removeShellCommand = "[ -x \(helperPath) ] && \(helperPath) auto;"
        + " \(LowPowerAuthorization.removePath) -f \(rulePath) \(helperPath)"

    // MARK: - Désinstallation de l'app

    /// À brancher dans la désinstallation de l'app : retire l'outil et la règle s'ils existent (une demande de mot
    /// de passe administrateur), sinon réussit tout de suite. `completion` arrive sur le fil principal.
    static func remove(fans: FanBackend = SystemFans(),
                       isInstalled: () -> Bool = {
                           FileManager.default.fileExists(atPath: FanAuthorization.helperPath)
                               || FileManager.default.fileExists(atPath: FanAuthorization.rulePath)
                       },
                       completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void) {
        guard isInstalled() else { return completion(.success(())) }
        fans.uninstall(completion: completion)
    }
}
