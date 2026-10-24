import AppKit
import Darwin
import Foundation

// MARK: - Élément

/// Un fichier ou un dossier posé sur l'étagère : une référence (signet), jamais une copie.
struct ShelfItem: Codable, Equatable, Identifiable {
    let id: UUID
    /// `URL.bookmarkData` : retrouve le fichier même déplacé ou renommé.
    var bookmark: Data
    /// Dernier chemin connu : nom affiché, icône, doublons, glisser vers l'extérieur.
    var path: String
    var isDirectory: Bool

    var name: String { (path as NSString).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    /// Signet du fichier. Touche le système de fichiers : jamais sur le main thread (dossiers protégés).
    static func make(_ url: URL) -> ShelfItem? {
        let url = url.standardizedFileURL
        guard let bookmark = try? url.bookmarkData() else { return nil }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
        return ShelfItem(id: UUID(), bookmark: bookmark, path: url.path, isDirectory: isDirectory)
    }

    enum Resolution: Equatable {
        /// Le fichier est là, peut-être ailleurs ; `bookmark` = signet renouvelé s'il était périmé.
        case found(path: String, bookmark: Data?)
        /// Signet qui ne se résout plus, ou fichier parti à la corbeille (`~/.Trash`, ou `.Trashes` d'un volume).
        case missing
    }

    /// Où est le fichier maintenant. Même règle que `make` : hors du main thread.
    func resolve(fileManager: FileManager = .default) -> Resolution {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              fileManager.fileExists(atPath: url.path),
              !url.path.contains("/.Trash/"), !url.path.contains("/.Trashes/") else { return .missing }
        return .found(path: url.standardizedFileURL.path, bookmark: stale ? try? url.bookmarkData() : nil)
    }
}

// MARK: - Liste

enum ShelfList {
    /// Plafond absolu (le réglage peut le baisser).
    static let maxCount = 50

    /// `new` en tête (le dernier dépôt d'abord, dans son ordre) : doublons ignorés (même chemin, déjà là ou
    /// répété dans le dépôt), plafond respecté. `refused` = éléments laissés de côté faute de place.
    static func adding(_ new: [ShelfItem], to items: [ShelfItem], limit: Int) -> (items: [ShelfItem], refused: Int) {
        var paths = Set(items.map { $0.path })
        let fresh = new.filter { paths.insert($0.path).inserted }
        let room = max(0, min(limit, maxCount) - items.count)
        return (Array(fresh.prefix(room)) + items, max(0, fresh.count - room))
    }
}

// MARK: - Sélection

/// Sélection des vignettes, comme dans le Finder : clic = celle-là seule, ⌘-clic = ajoute ou retire,
/// ⇧-clic = la plage depuis le dernier clic.
struct ShelfSelection: Equatable {
    private(set) var ids: Set<UUID> = []
    private var anchor: UUID?

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    mutating func click(_ id: UUID, command: Bool = false, shift: Bool = false, order: [UUID]) {
        if command {
            if ids.remove(id) == nil { ids.insert(id) }
            anchor = id
        } else if shift, let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            ids = Set(order[min(from, to)...max(from, to)])
        } else {
            ids = [id]
            anchor = id
        }
    }

    mutating func clear() {
        ids = []
        anchor = nil
    }

    /// Retire ce qui n'est plus sur l'étagère.
    mutating func keep(_ order: [UUID]) {
        ids.formIntersection(order)
        if let anchor, !order.contains(anchor) { self.anchor = nil }
    }

    /// Ce que vise un geste sur `id` : toute la sélection si `id` en fait partie, sinon `id` seul ; dans l'ordre.
    func targets(for id: UUID, order: [UUID]) -> [UUID] {
        ids.contains(id) ? order.filter { ids.contains($0) } : [id]
    }
}

// MARK: - Dépôt

/// Ce que l'étagère accepte d'un glisser : des fichiers et des dossiers (URL de fichier). Ni texte, ni lien web,
/// ni promesse de fichier (photo de Photos, pièce jointe de Mail) : l'étagère garde des références, pas de copie.
enum ShelfDrop {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL]
    private static let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    static func hasFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: options)
    }

    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    /// Copie (on ne fait que référencer), lien ou générique à défaut. Jamais « déplacer » : la source
    /// supprimerait l'original.
    static func operation(for mask: NSDragOperation) -> NSDragOperation {
        [NSDragOperation.copy, .link, .generic].first { mask.contains($0) } ?? []
    }
}

// MARK: - Fichier

/// `shelf.json` (0600) dans ~/Library/Application Support/Oriel : la liste et ses signets.
struct ShelfStore {
    let file: URL

    static var standard: ShelfStore {
        ShelfStore(file: standardDirectory.appendingPathComponent("shelf.json"))
    }

    /// Le dossier de l'app, sauf sous XCTest : le harnais commun des tests démarre les modules standard, et un test
    /// ne doit jamais lire ni écrire le vrai ~/Library/Application Support/Oriel.
    static var standardDirectory: URL {
        NSClassFromString("XCTestCase") == nil
            ? SharedFiles.notchDirectory
            : FileManager.default.temporaryDirectory.appendingPathComponent("oriel-tests-shelf")
    }

    private struct Contents: Codable {
        var version = 1
        var items: [ShelfItem]
    }

    var corruptFile: URL { file.appendingPathExtension("corrupt") }

    /// Absent = vide. Illisible = renommé en `.corrupt` (jamais écrasé par la sauvegarde suivante), puis vide.
    func load() -> [ShelfItem] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        guard let contents = try? JSONDecoder().decode(Contents.self, from: data) else {
            try? FileManager.default.removeItem(at: corruptFile)
            try? FileManager.default.moveItem(at: file, to: corruptFile)
            return []
        }
        return Array(contents.items.prefix(ShelfList.maxCount))
    }

    /// Fichier temporaire créé en 0600 (`O_EXCL`) dans le même dossier, puis `rename` : jamais de fichier à moitié
    /// écrit ni lisible par un autre compte.
    func save(_ items: [ShelfItem]) throws {
        let data = try JSONEncoder().encode(Contents(items: items))
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    func erase() {
        try? FileManager.default.removeItem(at: file)
    }
}
