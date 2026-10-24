import Darwin
import Foundation

/// Emplacements des fichiers partagés avec les outils en ligne de commande
/// (claude-files, git-radar, claude-usage). Tous sous `~/Library/Application Support/`.
enum SharedFiles {
    static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    /// Dossier de Oriel : `files.jsonl` (CF1) et `permissions.jsonl` (CF2).
    static var notchDirectory: URL { applicationSupport.appendingPathComponent("Oriel") }
    /// CF3, écrit par git-radar.
    static var gitRadarState: URL { applicationSupport.appendingPathComponent("GitRadar/state.json") }
    /// CF4, écrit par claude-usage.
    static var usageToday: URL { applicationSupport.appendingPathComponent("ClaudeUsage/today.json") }
}

/// Dates ISO 8601 des fichiers partagés.
enum ISODate {
    private static let utc: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// `2026-10-19T10:34:56Z`, sans fraction de seconde.
    static func string(_ date: Date) -> String { utc.string(from: date) }

    /// Accepte `Z` ou `+00:00`, avec ou sans fraction (Python écrit des microsecondes).
    static func parse(_ text: String) -> Date? {
        if let date = utc.date(from: text) ?? fractional.date(from: text) { return date }
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return trimmed == text ? nil : utc.date(from: trimmed)
    }
}

/// Registres écrits en direct à partir des hooks :
/// - CF1 `files.jsonl` : un fichier écrit par Claude (PostToolUse réussi de Write, Edit, MultiEdit, NotebookEdit) ;
/// - CF2 `permissions.jsonl` : une demande de permission (PermissionRequest).
/// Une ligne JSON par événement, ajoutée en fin de fichier sur une queue série.
final class ActivityLog {
    static let fileTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]
    static let maxDetailLength = 200

    let directory: URL
    var filesURL: URL { directory.appendingPathComponent("files.jsonl") }
    var permissionsURL: URL { directory.appendingPathComponent("permissions.jsonl") }

    /// Compteurs depuis le lancement (diagnostic `GET /state`), lus et écrits sur le main thread.
    private(set) var filesLogged = 0
    private(set) var permissionsLogged = 0
    /// Écritures ratées (disque plein, droits) : lu depuis n'importe quel thread pour le diagnostic.
    private let failures = Counter()

    private let queue = DispatchQueue(label: AppIdentity.bundleId + ".activity-log", qos: .utility)

    init(directory: URL = SharedFiles.notchDirectory) {
        self.directory = directory
    }

    /// À appeler après `SessionStore.handle`, pour profiter du cwd de la session.
    func record(_ event: HookEvent, session: Session?, now: Date = Date()) {
        if let line = Self.fileRecord(for: event, session: session, now: now) {
            filesLogged += 1
            // Le projet réel demande de regarder le disque (dépôt git du fichier) : sur la queue, jamais sur
            // le main thread, où un accès à un dossier protégé peut attendre une fenêtre d'autorisation.
            append(line, to: filesURL) { record in
                var record = record
                if let path = record["path"] as? String, let cwd = record["cwd"] as? String {
                    record["project"] = Self.projectName(forFile: path, cwd: cwd)
                }
                return record
            }
        }
        if let line = Self.permissionRecord(for: event, session: session, now: now) {
            permissionsLogged += 1
            append(line, to: permissionsURL)
        }
    }

    /// Attend la fin des écritures en cours (tests).
    func flush() {
        queue.sync {}
    }

    var failedWrites: Int { failures.value }

    // MARK: - Lignes

    /// Ligne CF1, ou `nil` si l'événement n'est pas l'écriture réussie d'un fichier.
    static func fileRecord(for event: HookEvent, session: Session?, now: Date) -> [String: Any]? {
        guard event.name == "PostToolUse", let tool = event.toolName, fileTools.contains(tool),
              let raw = (event.toolInput?["file_path"] as? String) ?? (event.toolInput?["notebook_path"] as? String)
        else { return nil }
        let cwd = session?.cwd ?? event.cwd ?? ""
        guard let path = absolutePath(raw, cwd: cwd) else { return nil }
        return [
            "ts": ISODate.string(now),
            "path": path,
            "tool": tool,
            "session_id": event.sessionId ?? "",
            "project": projectName(cwd),
            "cwd": cwd,
            "source": "live",
        ]
    }

    /// Ligne CF2 pour chaque PermissionRequest.
    static func permissionRecord(for event: HookEvent, session: Session?, now: Date) -> [String: Any]? {
        guard event.name == "PermissionRequest" else { return nil }
        let tool = event.toolName ?? ""
        let input = event.toolInput
        let detail: String
        if tool == "Bash", let command = input?["command"] as? String {
            detail = ToolDescriber.firstLine(command, max: maxDetailLength)
        } else if let path = (input?["file_path"] as? String) ?? (input?["notebook_path"] as? String),
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detail = ToolDescriber.firstLine(path, max: maxDetailLength)
        } else {
            detail = ToolDescriber.truncate(ToolDescriber.describe(tool: tool, input: input).text, max: maxDetailLength)
        }
        return [
            "ts": ISODate.string(now),
            "session_id": event.sessionId ?? "",
            "project": projectName(session?.cwd ?? event.cwd ?? ""),
            "tool": tool,
            "detail": detail,
        ]
    }

    /// Dernier composant du cwd, comme dans les autres outils.
    static func projectName(_ cwd: String) -> String {
        cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
    }

    /// Fichier sous le cwd : le projet du cwd. Ailleurs (Claude a écrit hors de son dossier, ou le cwd a changé
    /// après un `cd`) : le dépôt git qui contient le fichier, sinon son dossier parent.
    static func projectName(forFile path: String, cwd: String) -> String {
        if !cwd.isEmpty, path.hasPrefix(cwd.hasSuffix("/") ? cwd : cwd + "/") { return projectName(cwd) }
        // Documents, Bureau, Téléchargements sans outil compagnon : pas de recherche (fenêtre d'autorisation).
        if ProtectedFolders.mayAccess(path) {
            var dir = (path as NSString).deletingLastPathComponent
            for _ in 0..<12 where dir.count > 1 {
                if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                    return (dir as NSString).lastPathComponent
                }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.isEmpty ? projectName(cwd) : parent
    }

    /// Les outils d'édition exigent un chemin absolu ; un chemin relatif est résolu depuis le cwd.
    static func absolutePath(_ raw: String, cwd: String) -> String? {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        guard cwd.hasPrefix("/") else { return nil }
        return ((cwd as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    // MARK: - Écriture

    private func append(_ record: [String: Any], to url: URL,
                        refine: (([String: Any]) -> [String: Any])? = nil) {
        let directory = self.directory
        let failures = self.failures
        queue.async {
            let final = refine?(record) ?? record
            guard var data = try? JSONSerialization.data(withJSONObject: final, options: [.withoutEscapingSlashes]) else {
                return
            }
            data.append(0x0A)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Self.appendLine(data, to: url)
            } catch {
                failures.increment()
                NSLog("Oriel : écriture de %@ impossible (%@).", url.lastPathComponent, String(describing: error))
            }
        }
    }

    /// `O_APPEND` : une ligne entière par `write`, sans écraser celles d'un autre écrivain (claude-files).
    private static func appendLine(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { buffer in write(fd, buffer.baseAddress, buffer.count) }
        guard written == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Compteur partagé entre threads.
private final class Counter {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
