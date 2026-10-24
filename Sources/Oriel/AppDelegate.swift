import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Créé après la migration : les préférences lisent le LaunchAgent à leur création.
    private lazy var core = AppCore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }
        replaceLegacyInstance()
        AppIdentity.migrateLegacyInstall()
        core.start()
        HookSetup.shared.showOnboardingIfNeeded(claudeEnabled: core.isClaudeEnabled, prefs: core.prefs,
                                                registry: core.registry)
    }

    /// App rouverte (Finder, Spotlight) alors qu'elle tourne : sans icône dans le Dock ni la barre des menus, c'est
    /// le chemin de retour. Une notch masquée réapparaît et les réglages s'ouvrent (« Pendant une activité » au
    /// repos, aucun raccourci). Le `open -g` du hook n'arrive ici que si un envoi échoue app ouverte : serveur pas
    /// encore prêt, juste après le lancement.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        core.prefs.showAgain()
        core.openSettings()
        return true
    }

    /// Une instance d'Oriel tourne déjà : elle suffit.
    private func isAnotherInstanceRunning() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let ids = Set([AppIdentity.bundleId, Bundle.main.bundleIdentifier].compactMap { $0 })
        return ids.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// Une version d'avant le renommage (ClaudeNotch) cède la place : elle tient le port des hooks et le dossier de données.
    private func replaceLegacyInstance() {
        replace(AppIdentity.legacyBundleIds.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { !$0.isTerminated })
    }

    private func replace(_ legacy: [NSRunningApplication]) {
        guard !legacy.isEmpty else { return }
        legacy.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while legacy.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        legacy.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }
}

/// Assemble le serveur de hooks, la surveillance des processus, l'état des sessions et la notch.
final class AppCore {
    let store = SessionStore()
    let monitor = ClaudeMonitor()
    let prefs = Preferences.shared
    let tools: ToolsFeed
    let activityLog: ActivityLog
    let jobs = JobRunner()
    let updater = Updater.shared
    private var server: HookServer?
    private var notch: NotchController?
    private var cancellables = Set<AnyCancellable>()

    init(tools: ToolsFeed = ToolsFeed(), activityLog: ActivityLog = ActivityLog()) {
        self.tools = tools
        self.activityLog = activityLog
    }

    /// Chaque événement met à jour les sessions puis, au besoin, les registres CF1 / CF2 (cwd de la session connu).
    static func hookHandler(store: SessionStore, log: ActivityLog) -> HookServer.Handler {
        { event, context in
            DispatchQueue.main.async {
                store.handle(event, context: context)
                log.record(event, session: event.sessionId.flatMap { store.sessions[$0] })
            }
        }
    }

    func start() {
        // Premier lancement : l'onglet Claude n'est activé d'office que si Claude Code est sur ce Mac.
        prefs.decideClaudeTab(claudeCodePresent: { HookInstaller.claudeCodeOnThisMac })
        // Même règle pour Codex : l'onglet n'est activé d'office que si Codex est sur ce Mac.
        prefs.decideCodexTab(codexPresent: { CodexHookInstaller.codexOnThisMac })
        // Relancer l'app vaut réactivation (seuls les masquages à durée survivent au relancement).
        if prefs.hiddenUntil == .distantFuture { prefs.showAgain() }
        // Créée avant le serveur (rien n'est encore affiché) : ses onglets disent si les hooks sont écoutés.
        let notch = NotchController(store: store, monitor: monitor, prefs: prefs, tools: tools)
        self.notch = notch

        let server = HookServer(handler: Self.hookHandler(store: store, log: activityLog))
        server.stateProvider = { [weak self] in self?.debugState() ?? [:] }
        server.onFailure = { error in
            // Port déjà pris : une autre instance tourne, inutile de rester.
            NSLog("Oriel : serveur de hooks indisponible (%@), arrêt.", String(describing: error))
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        server.codex = notch.codex
        server.api = notch.registry.external
        server.onClaudeStatus = { data in DispatchQueue.main.async { ClaudeUsageStore.shared.ingest(data) } }
        self.server = server
        // Onglet Codex : même principe, indépendant de celui de Claude.
        notch.registry.$enabled
            .map { $0.contains { $0.id == ModuleRegistry.codexId } }
            .removeDuplicates()
            .sink { [weak self] isOn in self?.setCodexTracking(isOn) }
            .store(in: &cancellables)
        // Onglet Claude : appliqué tout de suite, puis à chaud à chaque changement.
        notch.registry.$enabled
            .map { $0.contains { $0.id == ModuleRegistry.claudeId } }
            .removeDuplicates()
            .sink { [weak self] isOn in self?.setClaudeTracking(isOn) }
            .store(in: &cancellables)
        do {
            try server.start()
        } catch {
            NSLog("Oriel : impossible d'ouvrir le port %d (%@).", Int(HookServer.defaultPort), String(describing: error))
            NSApp.terminate(nil)
            return
        }

        jobs.start()
        updater.isBusy = { [store] in store.hasBusySessions }
        updater.start()

        notch.start()
        MainMenu.install(openSettings: { [weak notch] in notch?.openSettings() })
    }

    /// Onglet Claude activé : hooks écoutés, sessions et processus `claude` suivis. Désactivé : plus rien de tout
    /// cela (scan, observation de Claude Desktop, transcripts) et les demandes tenues sont rendues au terminal.
    private func setClaudeTracking(_ isOn: Bool) {
        server?.isPaused = !isOn
        if isOn {
            monitor.start()
            store.start()
        } else {
            monitor.stop()
            store.stop()
            ReplyCenter.shared.releaseAll()
            ClaudeUsageStore.shared.forget()
        }
    }

    /// Onglet Codex activé : hooks écoutés et sessions suivies. Désactivé : routes `/codex/*` à 204, sessions oubliées,
    /// demandes tenues rendues à Codex.
    private func setCodexTracking(_ isOn: Bool) {
        server?.isCodexPaused = !isOn
        notch?.codex.setTracking(isOn)
    }

    var isClaudeEnabled: Bool { notch?.registry.isClaudeEnabled ?? false }
    var registry: ModuleRegistry? { notch?.registry }

    func openSettings() {
        notch?.openSettings()
    }

    /// Instantané lisible de l'état, servi par `GET /state` (diagnostic local).
    func debugState() -> [String: Any] {
        let sessions: [[String: Any]] = store.sortedSessions.map { session in
            var item: [String: Any] = [
                "id": session.id,
                "project": session.projectName,
                "source": session.source == .desktop ? "desktop" : "cli",
                "phase": String(describing: session.phase),
                "status": [session.status.label, session.status.detail].compactMap { $0 }.joined(separator: " · "),
                "inTurn": session.inTurn,
                "toolCount": session.toolCount,
                "agents": session.activeAgents.count,
                "tasks": "\(session.completedTaskCount)/\(session.tasks.count)",
            ]
            item["host"] = session.hostName
            item["hostBundleId"] = session.hostBundleId
            item["pid"] = session.claudePid.map { Int($0) }
            item["title"] = session.title
            item["desktopSessionId"] = session.desktopSessionId
            item["replyChannel"] = ReplyCenter.shared.channel(for: session.id)
            item["currentTask"] = session.currentTask?.subject
            return item
        }
        var state: [String: Any] = [
            "sessions": sessions,
            "indicator": String(describing: store.indicator),
            "desktopRunning": monitor.desktopRunning,
            "desktopFrontmost": monitor.desktopFrontmost,
            "cliPids": monitor.cliPids.map { Int($0) }.sorted(),
            "desktopPids": monitor.desktopPids.map { Int($0) }.sorted(),
            "untrackedCli": monitor.cliPids.subtracting(store.trackedPids).count,
        ]
        state["ears"] = store.earsText
        state["sessionTimer"] = store.isTicking
        state["notch"] = notch?.debugInfo
        state["codex"] = notch?.codex.debugInfo
        state["api"] = notch?.registry.external.debugInfo
        state["claudeQuota"] = ClaudeUsageStore.shared.snapshot.map { $0.windows.map { ["percent": $0.usedPercent, "minutes": $0.minutes ?? 0] } }
        var tools = self.tools.debugSummary
        tools["filesLogged"] = activityLog.filesLogged
        tools["permissionsLogged"] = activityLog.permissionsLogged
        tools["failedWrites"] = activityLog.failedWrites
        tools["logDirectory"] = activityLog.directory.path
        state["tools"] = tools
        state["jobs"] = jobs.debugSummary
        state["version"] = updater.currentVersion
        state["updater"] = updater.debugSummary
        return state
    }
}
