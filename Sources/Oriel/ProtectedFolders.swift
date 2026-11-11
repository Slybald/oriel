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
    static func fullDiskAccessGranted() -> Bool {
        SQLiteMessagesDatabase.probe(SQLiteMessagesDatabase.defaultPath) == nil
    }

    /// Existence d'un fichier : vraie ailleurs ; dans un dossier protégé, supposée présente tant que l'accès
    /// complet manque (`disk` n'est alors pas appelé).
    static func exists(_ path: String, home: URL, hasFullDiskAccess: () -> Bool = fullDiskAccessGranted,
                       disk: (String) -> Bool) -> Bool {
        !contains(path, home: home.path) || hasFullDiskAccess() ? disk(path) : true
    }
}
