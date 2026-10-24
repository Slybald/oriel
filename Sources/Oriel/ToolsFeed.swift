import Combine
import Foundation

/// Données de la section « outils » du panneau déplié : fichiers récents (CF1), état git (CF3), usage du jour (CF4).
/// Lecture seulement à l'ouverture du panneau puis toutes les 15 s tant qu'il reste ouvert ; rien quand il est replié.
final class ToolsFeed: ObservableObject {
    struct Paths {
        var files: URL
        var gitState: URL
        var usage: URL

        static var standard: Paths {
            Paths(files: SharedFiles.notchDirectory.appendingPathComponent("files.jsonl"),
                  gitState: SharedFiles.gitRadarState, usage: SharedFiles.usageToday)
        }
    }

    struct RecentFile: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let project: String
        let date: Date
        var exists = true

        var name: String { (path as NSString).lastPathComponent }
    }

    struct GitRepo: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let name: String
        let branch: String
        let dirty: Int
        let untracked: Int
        let ahead: Int
        let behind: Int
        let noUpstream: Bool
        let error: String?
        let needsAttention: Bool
    }

    struct GitStatus: Equatable {
        let generatedAt: Date
        let total: Int
        let needsAttention: Int
        /// Dépôts à traiter seulement.
        let repos: [GitRepo]
    }

    struct Usage: Equatable {
        struct Project: Equatable {
            let name: String
            let minutes: Int
        }

        let activeMinutes: Int
        let sessions: Int
        let turns: Int
        let topProjects: [Project]
    }

    /// Lecture incrémentale du registre : seules les lignes ajoutées depuis la dernière fois sont analysées.
    /// Garder les meilleurs candidats suffit : un chemin hors de ce lot ne peut y revenir que par une nouvelle ligne.
    struct FilesCache {
        let inode: UInt64
        /// Octets consommés, jusqu'au dernier saut de ligne (une ligne en cours d'écriture sera relue).
        let offset: UInt64
        let candidates: [RecentFile]
    }

    static let refreshInterval: TimeInterval = 15
    static let recentLimit = 5
    /// Au-delà, l'état git-radar est jugé périmé et n'est plus affiché.
    static let gitMaxAge: TimeInterval = 2 * 3600
    /// Première lecture : au plus les 16 derniers Mo, le registre ne faisant que grossir.
    static let initialReadLimit: UInt64 = 16 << 20
    static let keptCandidates = 50

    @Published private(set) var recentFiles: [RecentFile] = []
    @Published private(set) var git: GitStatus?
    @Published private(set) var usage: Usage?
    /// Heure de la dernière lecture : sert de « maintenant » pour les « il y a 3 min ».
    @Published private(set) var lastRefresh: Date?

    var hasContent: Bool { !recentFiles.isEmpty || git != nil || usage != nil }
    private(set) var isActive = false
    private(set) var refreshCount = 0

    let paths: Paths
    /// Injectable pour les captures : des chemins fictifs peuvent passer pour présents.
    private let fileExists: (String) -> Bool
    private let queue = DispatchQueue(label: AppIdentity.bundleId + ".tools", qos: .utility)
    private var timer: Timer?
    private var loading = false
    private var filesCache: FilesCache?

    /// Dans Documents, Bureau ou Téléchargements sans outil compagnon, le fichier est supposé présent :
    /// le vérifier ferait surgir une fenêtre d'autorisation de macOS.
    init(paths: Paths = .standard,
         fileExists: @escaping (String) -> Bool = { path in
             ProtectedFolders.mayAccess(path) ? FileManager.default.fileExists(atPath: path) : true
         }) {
        self.paths = paths
        self.fileExists = fileExists
    }

    /// Panneau ouvert : lecture immédiate puis toutes les 15 s. Fermé : plus rien.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            refresh()
            let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Lecture en arrière-plan, publication sur le main thread.
    func refresh() {
        guard !loading else { return }
        loading = true
        let cache = filesCache
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.load(now: Date(), cache: cache)
            DispatchQueue.main.async {
                self.loading = false
                self.apply(snapshot)
            }
        }
    }

    /// Lecture synchrone (tests, captures).
    func refreshNow(now: Date = Date()) {
        apply(load(now: now, cache: filesCache))
    }

    /// Résumé pour `GET /state`.
    var debugSummary: [String: Any] {
        var summary: [String: Any] = [
            "active": isActive,
            "refreshCount": refreshCount,
            "recentFiles": recentFiles.count,
            "missingFiles": recentFiles.filter { !$0.exists }.count,
        ]
        summary["lastRefresh"] = lastRefresh.map(ISODate.string)
        summary["git"] = git.map { ["total": $0.total, "needsAttention": $0.needsAttention,
                                    "generatedAt": ISODate.string($0.generatedAt)] as [String: Any] }
        summary["usage"] = usage.map { ["activeMinutes": $0.activeMinutes, "sessions": $0.sessions,
                                        "turns": $0.turns] as [String: Any] }
        return summary
    }

    // MARK: - Lecture

    private struct Snapshot {
        let files: [RecentFile]
        let filesCache: FilesCache?
        let git: GitStatus?
        let usage: Usage?
        let now: Date
    }

    private func load(now: Date, cache: FilesCache?) -> Snapshot {
        let newCache = Self.updateFiles(paths.files, cache: cache)
        let files = (newCache?.candidates ?? []).prefix(Self.recentLimit).map { file -> RecentFile in
            var file = file
            file.exists = fileExists(file.path)
            return file
        }
        return Snapshot(files: files, filesCache: newCache,
                        git: Self.gitStatus(at: paths.gitState, now: now),
                        usage: Self.usage(at: paths.usage, now: now), now: now)
    }

    private func apply(_ snapshot: Snapshot) {
        filesCache = snapshot.filesCache
        if recentFiles != snapshot.files { recentFiles = snapshot.files }
        if git != snapshot.git { git = snapshot.git }
        if usage != snapshot.usage { usage = snapshot.usage }
        // Toujours publié : les durées relatives avancent.
        lastRefresh = snapshot.now
        refreshCount += 1
    }

    // MARK: - CF1 : fichiers écrits

    /// Registre absent : `nil`. Remplacé ou tronqué (autre inode, taille plus petite) : relu depuis le début.
    static func updateFiles(_ url: URL, cache: FilesCache?, initialLimit: UInt64 = initialReadLimit) -> FilesCache? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var base: [RecentFile] = []
        var start: UInt64 = 0
        var skipPartialLine = false
        if let cache, cache.inode == inode, cache.offset <= size {
            if cache.offset == size { return cache }
            base = cache.candidates
            start = cache.offset
        } else if size > initialLimit {
            start = size - initialLimit
            skipPartialLine = true
        }
        guard let chunk = readCompleteLines(url, from: start, skipPartialFirstLine: skipPartialLine) else {
            return cache
        }
        return FilesCache(inode: inode, offset: start + chunk.consumed,
                          candidates: recentFiles(from: chunk.data, merging: base, limit: keptCandidates))
    }

    /// Lignes complètes à partir de `offset` ; `consumed` s'arrête après le dernier saut de ligne.
    static func readCompleteLines(_ url: URL, from offset: UInt64,
                                  skipPartialFirstLine: Bool = false) -> (data: Data, consumed: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return nil }
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return (Data(), 0) }
        var begin = data.startIndex
        if skipPartialFirstLine, let first = data.firstIndex(of: 0x0A) { begin = first + 1 }
        let end = lastNewline + 1
        return (begin < end ? data.subdata(in: begin..<end) : Data(), UInt64(end - data.startIndex))
    }

    /// Chemins distincts les plus récents (par `ts`, pas par ordre d'écriture : le rattrapage ajoute
    /// des lignes anciennes en fin de fichier). Lignes invalides et chemins temporaires ignorés.
    static func recentFiles(from data: Data, merging base: [RecentFile] = [],
                            limit: Int = recentLimit) -> [RecentFile] {
        var latest = Dictionary(base.map { ($0.path, $0) }, uniquingKeysWith: { a, b in a.date >= b.date ? a : b })
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let path = object["path"] as? String, path.hasPrefix("/"), !isTemporary(path),
                  let ts = object["ts"] as? String, let date = ISODate.parse(ts) else { continue }
            if let known = latest[path], known.date >= date { continue }
            var project = (object["project"] as? String) ?? ""
            // Session lancée depuis un dossier jetable : son nom (« scratch-2026-… ») ne dit rien, le dossier du fichier si.
            if project.isEmpty || isTemporary(((object["cwd"] as? String) ?? "") + "/") {
                project = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            }
            latest[path] = RecentFile(path: path, project: project, date: date)
        }
        let sorted = latest.values.sorted { a, b in a.date != b.date ? a.date > b.date : a.path < b.path }
        return Array(sorted.prefix(limit))
    }

    /// Même règle que pour les projets jetables : dossiers temporaires, espaces de travail éphémères,
    /// et fichiers internes de Claude Code (mémoire, transcripts sous ~/.claude/projects/).
    static func isTemporary(_ path: String) -> Bool {
        let prefixes = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        if prefixes.contains(where: { path.hasPrefix($0) }) { return true }
        return path.contains("/scratch-workspaces/") || path.contains("/scratchpad") || path.contains("/.claude/projects/")
    }

    // MARK: - CF3 : git-radar

    static func gitStatus(at url: URL, now: Date) -> GitStatus? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawRepos = object["repos"] as? [[String: Any]] else { return nil }
        let generated = (object["generated_at"] as? String).flatMap(ISODate.parse)
            ?? ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
        guard let generated, now.timeIntervalSince(generated) < gitMaxAge else { return nil }

        let repos = rawRepos.compactMap { raw -> GitRepo? in
            guard let path = raw["path"] as? String else { return nil }
            func int(_ key: String) -> Int { (raw[key] as? NSNumber)?.intValue ?? 0 }
            let name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (path as NSString).lastPathComponent
            return GitRepo(path: path, name: name, branch: (raw["branch"] as? String) ?? "",
                           dirty: int("dirty"), untracked: int("untracked"), ahead: int("ahead"), behind: int("behind"),
                           noUpstream: (raw["no_upstream"] as? Bool) ?? false,
                           error: (raw["error"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                           needsAttention: (raw["needs_attention"] as? Bool) ?? false)
        }
        let attention = repos.filter(\.needsAttention)
        let summary = object["summary"] as? [String: Any]
        let total = (summary?["total"] as? NSNumber)?.intValue ?? repos.count
        return GitStatus(generatedAt: generated, total: total, needsAttention: attention.count, repos: attention)
    }

    // MARK: - CF4 : usage du jour

    static func usage(at url: URL, now: Date, calendar: Calendar = .current) -> Usage? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let date = object["date"] as? String, date == localDay(now, calendar: calendar) else { return nil }
        func int(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
        let top = (object["top_projects"] as? [[String: Any]] ?? []).compactMap { item -> Usage.Project? in
            guard let name = item["name"] as? String else { return nil }
            return Usage.Project(name: name, minutes: (item["minutes"] as? NSNumber)?.intValue ?? 0)
        }
        return Usage(activeMinutes: int("active_minutes"), sessions: int("sessions"), turns: int("turns"),
                     topProjects: top)
    }

    static func localDay(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: - Textes

extension ToolsFeed.Usage {
    /// « Aujourd'hui · 2 h 10 · 6 sessions »
    var text: String {
        let count = String(format: L(sessions, one: "%d session", other: "%d sessions"), sessions)
        return [L("Aujourd'hui"), Self.duration(minutes: activeMinutes), count].joined(separator: " · ")
    }

    /// « mon-app 1 h 20 · api 40 min »
    var topProjectsText: String? {
        let parts = topProjects.prefix(3).map { "\($0.name) \(Self.duration(minutes: $0.minutes))" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func duration(minutes: Int) -> String {
        let total = max(0, minutes)
        if total < 60 { return String(format: L("%d min"), total) }
        let rest = total % 60
        return rest == 0 ? String(format: L("%d h"), total / 60) : String(format: L("%d h %02d"), total / 60, rest)
    }
}

extension ToolsFeed.GitStatus {
    /// « Git · tout est poussé » ou « Git · 2 dépôts à traiter »
    var text: String {
        needsAttention == 0
            ? L("Git · tout est poussé")
            : String(format: L(needsAttention, one: "Git · %d dépôt à traiter",
                               other: "Git · %d dépôts à traiter"), needsAttention)
    }
}
