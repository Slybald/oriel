import Darwin
import Foundation

/// Historique sur disque (réglage « garder l'historique après redémarrage », désactivé par défaut) : textes et
/// liens seulement, jamais les images, fichiers ni couleurs.
///
/// - Un seul fichier JSON en 0600, dans le dossier de l'app (injectable pour les tests).
/// - Écriture atomique (fichier temporaire 0600 créé en `O_EXCL`, puis `rename`) sur une file en arrière-plan.
/// - JSON illisible : le fichier est renommé en `.corrupt` (jamais écrasé) et l'historique repart de zéro.
///   « Effacer l'historique » et la désactivation du réglage suppriment aussi ces fichiers mis de côté : ils
///   peuvent contenir l'ancien historique en clair.
final class ClipboardStorage {
    struct Record: Codable, Equatable {
        var id: UUID
        /// « text » ou « url ».
        var kind: String
        var value: String
        var date: Date
        var pinned: Bool
        var app: String?
        var appName: String?
        /// Le texte avait été coupé à 20 000 caractères (absent des anciens fichiers).
        var truncated: Bool?
    }

    private struct Document: Codable {
        var version = 1
        var items: [Record]
    }

    static let fileName = "clipboard-history.json"

    let url: URL
    private let queue = DispatchQueue(label: "oriel.clipboard.storage", qos: .utility)

    init(directory: URL = SharedFiles.notchDirectory) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    /// Lecture synchrone (une fois, au premier démarrage du module). Fichier absent : vide ; illisible : renommé.
    func load() -> [Record] {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if let document = try? decoder.decode(Document.self, from: data), document.version == 1 {
                return document.items
            }
            quarantine()
            return []
        }
    }

    /// Écriture asynchrone et atomique. `completion` (sur le main thread) dit si le fichier a bien été écrit.
    func save(_ records: [Record], completion: @escaping (Bool) -> Void = { _ in }) {
        queue.async { [url] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            var succeeded = false
            if let data = try? encoder.encode(Document(items: records)), (try? Self.write(data, to: url)) != nil {
                succeeded = true
            }
            DispatchQueue.main.async { completion(succeeded) }
        }
    }

    /// Supprime le fichier et ceux mis de côté (`.corrupt`), dans l'ordre des écritures déjà demandées.
    func delete() {
        queue.async { [url] in
            let manager = FileManager.default
            try? manager.removeItem(at: url)
            let names = (try? manager.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
            for name in names where name.hasPrefix(url.lastPathComponent + ".corrupt") {
                try? manager.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(name))
            }
        }
    }

    /// Attend la fin des écritures en cours (arrêt du module, fin de l'app, tests).
    func flush() {
        queue.sync {}
    }

    // MARK: Fichiers

    private func quarantine() {
        let manager = FileManager.default
        var target = url.appendingPathExtension("corrupt")
        if manager.fileExists(atPath: target.path) {
            target = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        }
        try? manager.moveItem(at: url, to: target)
    }

    private static func write(_ data: Data, to file: URL) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(file.lastPathComponent)-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temporary.path, file.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            unlink(temporary.path)
            throw POSIXError(code)
        }
    }
}

extension ClipboardItem {
    /// nil : seuls les textes et les liens se gardent sur disque.
    var record: ClipboardStorage.Record? {
        let kind: String
        let value: String
        switch content {
        case .text(let text): (kind, value) = ("text", text)
        case .url(let url): (kind, value) = ("url", url.absoluteString)
        default: return nil
        }
        return ClipboardStorage.Record(id: id, kind: kind, value: value, date: date, pinned: pinned,
                                       app: source?.bundleID, appName: source?.name, truncated: truncated ? true : nil)
    }

    init?(record: ClipboardStorage.Record) {
        let content: ClipboardContent
        switch record.kind {
        case "text": content = .text(record.value)
        case "url": guard let url = URL(string: record.value) else { return nil }; content = .url(url)
        default: return nil
        }
        let source = record.app.map { ClipboardSource(bundleID: $0, name: record.appName ?? $0) }
        self.init(content, date: record.date, source: source, pinned: record.pinned, id: record.id,
                  truncated: record.truncated ?? false)
    }
}
