import Foundation

/// Documents, Bureau et Téléchargements : macOS demande une autorisation au premier accès, même pour un
/// simple test d'existence. Sans l'Accès complet au disque, l'app n'y regarde pas d'elle-même : un chemin dedans est supposé présent.
enum ProtectedFolders {
    static let names = ["Documents", "Desktop", "Downloads"]

    /// Chemin à l'intérieur d'un de ces dossiers (casse ignorée, comme le disque).
    static func contains(_ path: String, home: String) -> Bool {
        let path = path.lowercased()
        return names.contains { path.hasPrefix((home as NSString).appendingPathComponent($0).lowercased() + "/") }
    }

    /// Avec l'Accès complet au disque déjà accordé, macOS n'affiche aucune fenêtre : on regarde le disque.
    /// Même sonde que l'onglet Messages (`open` sur chat.db) ; sans Messages, l'accès est tenu pour absent.
    /// La valeur vaut pour le lancement en cours (un accès accordé ensuite est vu au prochain lancement).
    static let launchAccess = AccessProbe { SQLiteMessagesDatabase.probe(SQLiteMessagesDatabase.defaultPath) == nil }

    static func fullDiskAccessGranted() -> Bool { launchAccess.granted }

    /// Existence d'un fichier : vraie ailleurs ; dans un dossier protégé, supposée présente tant que l'accès
    /// complet manque (`disk` n'est alors pas appelé).
    static func exists(_ path: String, home: URL, hasFullDiskAccess: () -> Bool = fullDiskAccessGranted,
                       disk: (String) -> Bool) -> Bool {
        !contains(path, home: home.path) || hasFullDiskAccess() ? disk(path) : true
    }
}

/// Sonde faite au plus une fois (sûre entre files), seulement quand quelqu'un demande la valeur.
final class AccessProbe {
    private let probe: () -> Bool
    private let lock = NSLock()
    private var value: Bool?

    init(_ probe: @escaping () -> Bool) { self.probe = probe }

    var granted: Bool {
        lock.lock(); defer { lock.unlock() }
        if let value { return value }
        let result = probe()
        value = result
        return result
    }
}
