import Darwin
import Foundation

// Briques communes aux modules Minuteur et Notes : planificateur injectable, dossier des données et fichier JSON
// privé (0600, écriture atomique, débouncée, hors du main thread).

/// Planificateur injectable : exécute `work` dans `delay` secondes sur le main thread ; rend l'annulation.
/// File GCD principale (et non `Timer`) : elle continue de tourner pendant un menu ouvert ou un glisser.
struct ModuleScheduler {
    var after: (TimeInterval, @escaping () -> Void) -> () -> Void

    static let system = ModuleScheduler { delay, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return { item.cancel() }
    }
}

enum ModuleDataDirectory {
    /// `~/Library/Application Support/Oriel`. Sous XCTest : un dossier temporaire du processus, pour que
    /// l'initialiseur par défaut d'un module (registre de `NotchHarness`) ne touche jamais aux vraies données.
    static var standard: URL {
        if NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("oriel-tests-data-\(ProcessInfo.processInfo.processIdentifier)")
        }
        return SharedFiles.notchDirectory
    }
}

/// Fichier JSON d'un module : lecture tolérante, écriture atomique en 0600, débouncée, sur une file à part.
///
/// - Illisible (JSON invalide, schéma inconnu, lecture refusée alors que le fichier existe) : le fichier est
///   renommé en `<nom>.corrupt` (jamais écrasé par un état vide) et le module repart de zéro. Lu en partie
///   seulement (`isPartial`) : une copie est gardée de la même façon et le reste est chargé.
/// - `save` mémorise la dernière valeur et arme un seul délai ; à l'échéance, la valeur est encodée et écrite hors
///   du main thread. `flush` écrit tout de suite (et attend la fin avec `wait`) : repli du panneau, fin de l'app.
final class SecureJSONFile<Value: Codable> {
    let url: URL
    private let debounce: TimeInterval
    private let scheduler: ModuleScheduler
    private let io = DispatchQueue(label: "oriel.modulefile", qos: .utility)
    private var pending: Value?
    private var cancelTimer: (() -> Void)?

    init(url: URL, debounce: TimeInterval, scheduler: ModuleScheduler = .system) {
        self.url = url
        self.debounce = debounce
        self.scheduler = scheduler
    }

    deinit { cancelTimer?() }

    /// Où est allé le fichier mis de côté (ou sa copie) par `load` ; nil si rien n'a été écarté.
    private(set) var asideURL: URL?

    /// nil : pas de fichier, ou fichier illisible (mis de côté en `.corrupt`). `isPartial` : le contenu lu a perdu
    /// des entrées illisibles ; le fichier d'origine est alors copié en `.corrupt` avant que la prochaine écriture
    /// ne les efface.
    func load(isPartial: (Value) -> Bool = { _ in false }) -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            // Le fichier existe mais ne se lit pas (droits, verrou, erreur d'E/S) : jamais traité comme « absent ».
            setAside(copy: false)
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(Value.self, from: data) else {
            setAside(copy: false)
            return nil
        }
        if isPartial(value) { setAside(copy: true) }
        return value
    }

    /// `<nom>.corrupt`, ou `<nom>.corrupt-<n>` si un précédent est déjà là : rien n'est jamais écrasé.
    private func setAside(copy: Bool) {
        let manager = FileManager.default
        var target = url.appendingPathExtension("corrupt")
        var index = 1
        while manager.fileExists(atPath: target.path) {
            target = url.appendingPathExtension("corrupt-\(index)")
            index += 1
        }
        do {
            if copy { try manager.copyItem(at: url, to: target) } else { try manager.moveItem(at: url, to: target) }
            asideURL = target
        } catch {
            asideURL = nil
        }
    }

    func save(_ value: Value) {
        pending = value
        cancelTimer?()
        cancelTimer = scheduler.after(debounce) { [weak self] in self?.flush() }
    }

    /// Écrit la dernière valeur en attente, sans attendre le délai. Rend la main avant la fin de l'écriture.
    func flush() {
        cancelTimer?()
        cancelTimer = nil
        guard let value = pending else { return }
        pending = nil
        io.async { [url] in Self.write(value, to: url) }
    }

    /// Attend la fin des écritures lancées (fin de l'app, tests).
    func wait() { io.sync {} }

    private static func write(_ value: Value, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        let complete = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        // fsync avant le rename : une coupure de courant ne laisse pas un fichier vide à la place de l'ancien.
        let synced = complete && fsync(fd) == 0
        close(fd)
        if !synced || rename(temporary.path, url.path) != 0 { unlink(temporary.path) }
    }
}
