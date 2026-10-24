import Combine
import Foundation

/// Sessions Codex suivies, alimentées par les hooks (`HookServer`, routes `/codex/*`). Main thread uniquement.
///
/// Coût au repos nul : aucun timer périodique, aucune lecture de fichier. Une seule minuterie à échéance unique
/// (fin du « Terminé » affiché 5 s, retrait d'une session finie), et un `kqueue` par processus Codex (sa fin ferme ses
/// sessions sans scrutation). Arrêté (onglet désactivé), le magasin oublie tout et ignore les événements.
final class CodexStore: ObservableObject {
    @Published private(set) var sessions: [String: CodexSession] = [:]

    static let doneFlashDuration: TimeInterval = 5
    static let endedLinger: TimeInterval = 10
    /// Session sans processus connu et sans activité : oubliée.
    static let orphanTimeout: TimeInterval = 3 * 3600
    static let maxMessage = 280
    /// Les relais sont asynchrones (aucune latence pour Codex) mais `PermissionRequest` est synchrone : le `PreToolUse`
    /// (ou le `PostToolUse` de l'outil d'avant) du même appel peut arriver APRÈS lui (mesuré avec le vrai Codex). Pendant
    /// ce court délai, ils ne font pas repasser la session de « attend ton approbation » à « travaille ».
    static let reorderWindow: TimeInterval = 1.5

    private var started = false
    /// Sessions terminées : leurs événements tardifs (hooks async) sont ignorés, sauf un nouveau `SessionStart`
    /// (reprise de la session).
    private var endedIds: Set<String> = []
    private var watchers: [pid_t: DispatchSourceProcess] = [:]
    private var expiryTimer: Timer?

    /// Une minuterie est armée (diagnostic, tests : aucune au repos).
    var isTicking: Bool { expiryTimer != nil }

    func start() { started = true }

    func stop() {
        started = false
        endedIds = []
        watchers.values.forEach { $0.cancel() }
        watchers = [:]
        expiryTimer?.invalidate()
        expiryTimer = nil
        if !sessions.isEmpty { sessions = [:] }
    }

    // MARK: - Lecture pour la vue

    /// Attente d'approbation → en cours → prêtes ou terminées (plus récent d'abord) → finies.
    var sortedSessions: [CodexSession] {
        sessions.values.sorted { a, b in
            let rankA = Self.rank(a), rankB = Self.rank(b)
            if rankA != rankB { return rankA < rankB }
            if rankA <= 1 {
                // Ordre stable pendant un tour, sinon les cartes sautent à chaque outil.
                let startA = a.turnStart ?? .distantPast, startB = b.turnStart ?? .distantPast
                if startA != startB { return startA < startB }
                return a.id < b.id
            }
            return a.lastActivity > b.lastActivity
        }
    }

    private static func rank(_ session: CodexSession) -> Int {
        switch session.phase {
        case .waitingApproval: return 0
        case .working: return 1
        case .ready, .done: return 2
        case .ended: return 3
        }
    }

    var liveSessions: [CodexSession] { sessions.values.filter { $0.phase != .ended } }

    var indicator: NotchIndicator {
        let live = liveSessions
        if live.contains(where: { $0.phase == .waitingApproval }) { return .attention }
        if live.contains(where: { $0.phase == .working }) { return .working }
        if live.contains(where: \.isDoneFlashing) { return .done }
        return .none
    }

    /// Quelque chose se passe : les oreilles de la notch repliée ont de quoi s'afficher.
    var hasActivity: Bool { indicator != .none }

    /// Sessions qui travaillent ou attendent, pour l'oreille droite.
    var activeCount: Int { liveSessions.filter { $0.phase == .working || $0.phase == .waitingApproval }.count }

    var trackedPids: Set<pid_t> { Set(sessions.values.compactMap(\.pid)) }

    func clearEnded() {
        sessions = sessions.filter { $0.value.phase != .ended }
        scheduleExpiry()
    }

    // MARK: - Événements

    func handle(_ event: HookEvent, context: CodexContext, now: Date = Date()) {
        guard started, let id = event.sessionId, !id.isEmpty else { return }
        let name = event.name
        if name == "SessionStart" {
            endedIds.remove(id)
        } else if endedIds.contains(id) || (name == "SessionEnd" && sessions[id] == nil) {
            return
        }
        var session = sessions[id] ?? CodexSession(id: id, cwd: event.cwd)
        absorb(event, context, into: &session)

        switch name {
        case "SessionStart":
            // Reprise d'une session finie : elle n'est plus à retirer.
            session.endedAt = nil
            if !session.inTurn { session.phase = .ready }
        case "UserPromptSubmit":
            beginTurn(&session, now: now)
            session.lastPrompt = event.prompt.map(Self.oneLine)
            session.lastMessage = nil
            session.doneFlashUntil = nil
        case "PreToolUse":
            if !session.inTurn { beginTurn(&session, now: now) }
            if !isWaitingForReorderedEvent(session, now: now) {
                session.phase = .working
                session.attention = nil
                session.waitingSince = nil
                session.currentTool = event.toolName.map { CodexTools.describe(name: $0, input: event.toolInput) }
            }
        case "PostToolUse":
            if !session.inTurn { beginTurn(&session, now: now) }
            session.toolCount += 1
            if !isWaitingForReorderedEvent(session, now: now) {
                session.phase = .working
                session.attention = nil
                session.waitingSince = nil
                session.currentTool = nil
            }
        case "Stop":
            endTurn(&session, now: now)
            session.phase = .done
            session.lastMessage = event.lastAssistantMessage.map(Self.oneLine)
            session.doneFlashUntil = now.addingTimeInterval(Self.doneFlashDuration)
        case "Interrupt":
            endTurn(&session, now: now)
            session.phase = .ready
        case "SessionEnd":
            finish(&session, now: now)
        default:
            break
        }
        session.lastActivity = now
        sessions[id] = session
        if session.phase != .ended { watch(session) }
        scheduleExpiry(now: now)
    }

    /// Le hook `PermissionRequest` est arrivé : la session attend une décision (dans la notch ou le terminal).
    func markWaiting(sessionId: String, tool: CodexToolText, context: CodexContext, cwd: String?, now: Date = Date()) {
        guard started, !endedIds.contains(sessionId) else { return }
        var session = sessions[sessionId] ?? CodexSession(id: sessionId, cwd: cwd)
        absorb(nil, context, into: &session)
        if !session.inTurn { beginTurn(&session, now: now) }
        session.phase = .waitingApproval
        session.attention = tool
        session.waitingSince = now
        session.lastActivity = now
        sessions[sessionId] = session
        watch(session)
        scheduleExpiry(now: now)
    }

    /// Décision prise dans la notch : Codex reprend (autorisé) ou renonce à l'outil (refusé) ; dans les deux cas il
    /// travaille de nouveau jusqu'à son prochain événement.
    func resolveApproval(_ sessionId: String, now: Date = Date()) {
        guard var session = sessions[sessionId], session.phase == .waitingApproval else { return }
        session.phase = .working
        session.attention = nil
        session.waitingSince = nil
        session.lastActivity = now
        sessions[sessionId] = session
    }

    private func isWaitingForReorderedEvent(_ session: CodexSession, now: Date) -> Bool {
        guard session.phase == .waitingApproval, let since = session.waitingSince else { return false }
        return now.timeIntervalSince(since) < Self.reorderWindow
    }

    private func beginTurn(_ session: inout CodexSession, now: Date) {
        session.inTurn = true
        session.turnStart = now
        session.phase = .working
        session.attention = nil
        session.waitingSince = nil
        session.currentTool = nil
    }

    private func endTurn(_ session: inout CodexSession, now: Date) {
        if session.inTurn, let start = session.turnStart { session.lastTurnDuration = now.timeIntervalSince(start) }
        session.inTurn = false
        session.currentTool = nil
        session.attention = nil
        session.waitingSince = nil
    }

    private func finish(_ session: inout CodexSession, now: Date) {
        endTurn(&session, now: now)
        session.phase = .ended
        session.endedAt = now
        endedIds.insert(session.id)
    }

    private func absorb(_ event: HookEvent?, _ context: CodexContext, into session: inout CodexSession) {
        if let cwd = event?.cwd, cwd != session.cwd {
            session.cwd = cwd
            session.projectName = (cwd as NSString).lastPathComponent
        }
        if let model = event?.model { session.model = model }
        if let pid = context.pid {
            session.pid = pid
            session.pidStart = context.start
        }
        if context.hostName != nil || session.hostName == nil {
            session.hostName = context.hostName ?? session.hostName
            session.hostBundleId = context.hostBundleId ?? session.hostBundleId
        }
    }

    /// Une ligne, sans espaces en trop, bornée.
    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > maxMessage ? String(flat.prefix(maxMessage)) + "…" : flat
    }

    // MARK: - Fin du processus Codex (kqueue, sans scrutation)

    private func watch(_ session: CodexSession) {
        guard let pid = session.pid, watchers[pid] == nil, ProcessInspector.isAlive(pid, startedAt: session.pidStart) else {
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.processExited(pid) }
        source.resume()
        watchers[pid] = source
    }

    func processExited(_ pid: pid_t, now: Date = Date()) {
        watchers.removeValue(forKey: pid)?.cancel()
        for var session in sessions.values where session.pid == pid && session.phase != .ended {
            finish(&session, now: now)
            sessions[session.id] = session
        }
        scheduleExpiry(now: now)
    }

    // MARK: - Échéances

    /// Une seule minuterie, à échéance unique, sur la prochaine date qui change l'affichage ; aucune sans session.
    private func scheduleExpiry(now: Date = Date()) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard started, let next = nextDeadline(after: now) else { return }
        let timer = Timer(fire: max(next, now.addingTimeInterval(0.05)), interval: 0, repeats: false) { [weak self] _ in
            self?.expire()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    private func nextDeadline(after now: Date) -> Date? {
        var dates: [Date] = []
        for session in sessions.values {
            if let flash = session.doneFlashUntil, flash > now { dates.append(flash) }
            if let ended = session.endedAt { dates.append(ended.addingTimeInterval(Self.endedLinger)) }
            if session.pid == nil, !session.inTurn, session.phase != .ended {
                dates.append(session.lastActivity.addingTimeInterval(Self.orphanTimeout))
            }
        }
        return dates.min()
    }

    func expire(now: Date = Date()) {
        let kept = sessions.filter { _, session in
            if let ended = session.endedAt { return now.timeIntervalSince(ended) < Self.endedLinger }
            if session.pid == nil, !session.inTurn { return now.timeIntervalSince(session.lastActivity) < Self.orphanTimeout }
            return true
        }
        if kept.count != sessions.count { sessions = kept } else { objectWillChange.send() }
        scheduleExpiry(now: now)
    }
}
