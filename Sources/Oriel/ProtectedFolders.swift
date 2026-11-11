import Foundation

/// Documents, Bureau et Téléchargements : macOS demande une autorisation au premier accès, même pour un
/// simple test d'existence. L'app n'y regarde jamais d'elle-même : un chemin dedans est supposé présent.
enum ProtectedFolders {
    static let names = ["Documents", "Desktop", "Downloads"]

    /// Chemin à l'intérieur d'un de ces dossiers (casse ignorée, comme le disque).
    static func contains(_ path: String, home: String) -> Bool {
        let path = path.lowercased()
        return names.contains { path.hasPrefix((home as NSString).appendingPathComponent($0).lowercased() + "/") }
    }

    /// Existence d'un fichier : vraie ailleurs, supposée dans les dossiers protégés (`disk` n'est pas appelé).
    static func exists(_ path: String, home: URL, disk: (String) -> Bool) -> Bool {
        contains(path, home: home.path) || disk(path)
    }
}
