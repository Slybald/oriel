import Foundation

/// Tâches de fond des outils compagnons (git-radar, claude-usage, course-sorter, claude-recap).
///
/// Lancées par l'app plutôt que par des LaunchAgents : macOS refuse ~/Documents, ~/Desktop et
/// ~/Downloads aux scripts démarrés par launchd, alors qu'une app obtient l'accès une fois
/// (fenêtre système) et que les processus qu'elle lance en héritent.
/// Un outil absent (script non installé) est simplement ignoré.
final class JobRunner {
    struct Job {
        let name: String
        /// Chemin du script sous ~/.local/share.
        let script: String
        let arguments: [String]
        /// Intervalle entre deux passages ; nil pour le récap, quotidien.
        let interval: TimeInterval?
        let firstDelay: TimeInterval
    }

    struct Status {
        var lastStart: Date?
        var lastEnd: Date?
        var lastExit: Int32?
        var running = false
    }

    static let jobs: [Job] = [
        Job(name: "git-radar", script: "git-radar/git_radar.py", arguments: ["scan", "--quiet"],
            interval: 900, firstDelay: 20),
        Job(name: "claude-usage", script: "claude-usage/claude-usage", arguments: ["refresh", "--quiet"],
            interval: 1800, firstDelay: 40),
        Job(name: "course-sorter", script: "course-sorter/course_sorter.py", arguments: ["run"],
            interval: 300, firstDelay: 60),
        Job(name: "claude-recap", script: "claude-recap/claude_recap.py", arguments: ["morning"],
            interval: nil, firstDelay: 90),
    ]

    /// Le récap part le premier passage après 8 h 30 (heure locale), une fois par jour.
    private static let recapHour = 8, recapMinute = 30
    private static let recapDayKey = "jobs.claude-recap.lastDay"
    private static let maxRuntime: TimeInterval = 600
    private static let downloadsDebounce: TimeInterval = 12

    private let home: URL
    private let launchDate = Date()
    private var statuses: [String: Status] = [:]
    private var processes: [String: Process] = [:]
    private var pendingRerun: Set<String> = []
    private var timer: Timer?
    private var downloadsSource: DispatchSourceFileSystemObject?
    private var downloadsWork: DispatchWorkItem?
    private var downloadsWatchStarted = false

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    func start() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        watchDownloadsIfNeeded()
    }

    // MARK: - Planification

    private static var courseSorter: Job? { jobs.first { $0.name == "course-sorter" } }

    private static func scriptURL(_ job: Job, home: URL) -> URL {
        home.appendingPathComponent(".local/share").appendingPathComponent(job.script)
    }

    private func scriptURL(_ job: Job) -> URL {
        Self.scriptURL(job, home: home)
    }

    private func isInstalled(_ job: Job) -> Bool {
        FileManager.default.fileExists(atPath: scriptURL(job).path)
    }

    /// Au moins un outil compagnon installé : l'accès à Documents, Bureau ou Téléchargements est alors attendu.
    static func anyToolInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        jobs.contains { FileManager.default.fileExists(atPath: scriptURL($0, home: home).path) }
    }

    private func tick(now: Date = Date()) {
        watchDownloadsIfNeeded()
        for job in Self.jobs where isInstalled(job) {
            let status = statuses[job.name] ?? Status()
            if status.running {
                if let start = status.lastStart, now.timeIntervalSince(start) > Self.maxRuntime {
                    processes[job.name]?.terminate()
                }
                continue
            }
            guard now.timeIntervalSince(launchDate) >= job.firstDelay else { continue }
            if isDue(job, status: status, now: now) { run(job) }
        }
    }

    private func isDue(_ job: Job, status: Status, now: Date) -> Bool {
        guard let interval = job.interval else {
            // Récap quotidien : après 8 h 30, s'il n'a pas déjà tourné aujourd'hui.
            let calendar = Calendar.current
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            guard minutes >= Self.recapHour * 60 + Self.recapMinute else { return false }
            return UserDefaults.standard.string(forKey: Self.recapDayKey) != Self.dayString(now)
        }
        guard let last = status.lastEnd ?? status.lastStart else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Téléchargements

    /// Seulement si course-sorter est installé : sans lui, aucun accès à Téléchargements, donc aucune
    /// fenêtre d'autorisation de macOS. Revérifié à chaque passage (outil installé après le lancement).
    private func watchDownloadsIfNeeded() {
        guard !downloadsWatchStarted, let job = Self.courseSorter, isInstalled(job) else { return }
        downloadsWatchStarted = true
        watchDownloads()
    }

    /// Rangement dès qu'un fichier arrive, plutôt qu'au prochain passage de 5 min.
    private func watchDownloads() {
        let path = home.appendingPathComponent("Downloads").path
        // open() attend la réponse à la fenêtre d'autorisation de macOS (Téléchargements est protégé) :
        // jamais sur le main thread, sinon la notch reste figée tant qu'on n'a pas répondu.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return }
            DispatchQueue.main.async {
                guard let self else {
                    close(fd)
                    return
                }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                       eventMask: [.write, .rename, .extend],
                                                                       queue: .main)
                source.setEventHandler { [weak self] in self?.downloadsChanged() }
                source.setCancelHandler { close(fd) }
                source.resume()
                self.downloadsSource = source
            }
        }
    }

    private func downloadsChanged() {
        downloadsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let job = Self.courseSorter, self.isInstalled(job) else { return }
            if self.statuses[job.name]?.running == true {
                self.pendingRerun.insert(job.name)
            } else {
                self.run(job)
            }
        }
        downloadsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.downloadsDebounce, execute: work)
    }

    // MARK: - Exécution

    private func run(_ job: Job) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL(job).path] + job.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["LANG"] = environment["LANG"] ?? "fr_FR.UTF-8"
        process.environment = environment
        process.currentDirectoryURL = home

        let log = logHandle(for: job)
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                try? log?.close()
                self?.finished(job, exit: finished.terminationStatus)
            }
        }
        do {
            try process.run()
        } catch {
            try? log?.close()
            NSLog("Oriel : lancement de %@ impossible (%@).", job.name, String(describing: error))
            statuses[job.name, default: Status()].lastEnd = Date()
            return
        }
        processes[job.name] = process
        statuses[job.name, default: Status()].running = true
        statuses[job.name, default: Status()].lastStart = Date()
    }

    private func finished(_ job: Job, exit: Int32) {
        processes[job.name] = nil
        statuses[job.name, default: Status()].running = false
        statuses[job.name, default: Status()].lastEnd = Date()
        statuses[job.name, default: Status()].lastExit = exit
        if job.interval == nil, exit == 0 {
            UserDefaults.standard.set(Self.dayString(Date()), forKey: Self.recapDayKey)
        }
        if pendingRerun.remove(job.name) != nil { run(job) }
    }

    /// ~/Library/Logs/Oriel/<outil>.log, remis à zéro au-delà de 1 Mo.
    private func logHandle(for job: Job) -> FileHandle? {
        let dir = home.appendingPathComponent("Library/Logs/Oriel")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(job.name).log")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 1_000_000 || !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        let header = "\n[\(ISO8601DateFormatter().string(from: Date()))] \(job.name) \(job.arguments.joined(separator: " "))\n"
        try? handle.write(contentsOf: Data(header.utf8))
        return handle
    }

    // MARK: - Diagnostic

    var debugSummary: [String: Any] {
        var summary: [String: Any] = [:]
        let formatter = ISO8601DateFormatter()
        for job in Self.jobs {
            let status = statuses[job.name] ?? Status()
            var item: [String: Any] = ["installed": isInstalled(job), "running": status.running]
            item["lastStart"] = status.lastStart.map { formatter.string(from: $0) }
            item["lastExit"] = status.lastExit.map { Int($0) }
            summary[job.name] = item
        }
        summary["watchingDownloads"] = downloadsSource != nil
        return summary
    }
}

/// Documents, Bureau et Téléchargements : macOS demande une autorisation au premier accès, même pour un
/// simple test d'existence. L'app n'y regarde que si un outil compagnon est installé (il en a besoin, la
/// fenêtre est alors attendue) ; sinon, aucune fenêtre d'autorisation.
enum ProtectedFolders {
    static let names = ["Documents", "Desktop", "Downloads"]

    /// Chemin à l'intérieur d'un de ces dossiers (casse ignorée, comme le disque).
    static func contains(_ path: String, home: String) -> Bool {
        let path = path.lowercased()
        return names.contains { path.hasPrefix((home as NSString).appendingPathComponent($0).lowercased() + "/") }
    }

    static func mayAccess(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        !contains(path, home: home.path) || JobRunner.anyToolInstalled(home: home)
    }
}
