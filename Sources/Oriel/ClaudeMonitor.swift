import AppKit
import Combine

/// Surveille Claude Desktop (NSWorkspace) et les processus `claude` du CLI (scan toutes les 2 s), seulement tant
/// que l'onglet Claude est activé (`AppCore`).
final class ClaudeMonitor: ObservableObject {
    @Published private(set) var desktopRunning = false
    @Published private(set) var desktopFrontmost = false
    /// Processus `claude` lancés hors de Claude Desktop.
    @Published private(set) var cliPids: Set<pid_t> = []
    /// Processus `claude` lancés par Claude Desktop (onglet Code).
    @Published private(set) var desktopPids: Set<pid_t> = []

    private let scanner = ProcessScanner()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard timer == nil else { return }
        refreshDesktop()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDesktop()
            })
        }

        scan()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.scan() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Plus de scan ni d'observateur ; l'état retombe à « rien d'ouvert ».
    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        if desktopRunning { desktopRunning = false }
        if desktopFrontmost { desktopFrontmost = false }
        if !cliPids.isEmpty { cliPids = [] }
        if !desktopPids.isEmpty { desktopPids = [] }
    }

    private func refreshDesktop() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: ProcessInspector.desktopBundleId)
            .contains { !$0.isTerminated }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ProcessInspector.desktopBundleId
        if running != desktopRunning { desktopRunning = running }
        if frontmost != desktopFrontmost { desktopFrontmost = frontmost }
    }

    private func scan() {
        scanner.scan { [weak self] cli, desktop in
            // Arrêté pendant le scan : son résultat est jeté.
            guard let self, self.timer != nil else { return }
            if cli != self.cliPids { self.cliPids = cli }
            if desktop != self.desktopPids { self.desktopPids = desktop }
        }
    }
}

/// Liste les processus Claude sur une queue utilitaire. Le classement (CLI ou Desktop) est mis en cache par pid.
final class ProcessScanner {
    enum Kind {
        case cli
        case desktop
    }

    private struct Entry {
        let start: TimeInterval
        let kind: Kind?
    }

    private let queue = DispatchQueue(label: AppIdentity.bundleId + ".scan", qos: .utility)
    private var cache: [pid_t: Entry] = [:]
    private var bundleIds: [String: String] = [:]

    func scan(completion: @escaping (Set<pid_t>, Set<pid_t>) -> Void) {
        queue.async {
            var cli = Set<pid_t>()
            var desktop = Set<pid_t>()
            var seen = Set<pid_t>()

            for pid in ProcessInspector.allPids() where pid > 1 {
                seen.insert(pid)
                guard ProcessInspector.isCandidateName(ProcessInspector.name(pid)),
                      let info = ProcessInspector.kinfo(pid) else { continue }
                let start = ProcessInspector.startTime(info)

                let kind: Kind?
                if let entry = self.cache[pid], entry.start == start {
                    kind = entry.kind
                } else {
                    kind = self.classify(pid)
                    self.cache[pid] = Entry(start: start, kind: kind)
                }
                switch kind {
                case .cli: cli.insert(pid)
                case .desktop: desktop.insert(pid)
                case nil: break
                }
            }
            self.cache = self.cache.filter { seen.contains($0.key) }
            DispatchQueue.main.async { completion(cli, desktop) }
        }
    }

    private func classify(_ pid: pid_t) -> Kind? {
        guard let process = ProcessInspector.info(pid), ProcessInspector.isClaude(process) else { return nil }
        let fromDesktop = ProcessInspector.ancestors(of: process.ppid).contains { ancestor in
            guard let bundle = ProcessInspector.outermostBundlePath(ancestor.path) else { return false }
            return bundleId(bundle) == ProcessInspector.desktopBundleId
        }
        return fromDesktop ? .desktop : .cli
    }

    private func bundleId(_ bundlePath: String) -> String? {
        if let cached = bundleIds[bundlePath] { return cached.isEmpty ? nil : cached }
        let identifier = ProcessInspector.bundleIdentifier(atPath: bundlePath)
        bundleIds[bundlePath] = identifier ?? ""
        return identifier
    }
}
