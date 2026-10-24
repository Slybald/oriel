import Combine
import Foundation

enum Phase: Equatable {
    case ready
    case thinking
    case tool
    case waitingAnswer
    case waitingPermission
    case planReview
    case done
    case error
    case compacting
    case ended

    var needsAttention: Bool {
        switch self {
        case .waitingAnswer, .waitingPermission, .planReview: return true
        default: return false
        }
    }

    var isWorking: Bool {
        switch self {
        case .thinking, .tool, .compacting: return true
        default: return false
        }
    }
}

/// Ce que montrent les oreilles de la notch repliée.
enum NotchIndicator: Equatable {
    case none
    case working
    case attention
    case done
}

struct TaskItem: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case inProgress
        case completed

        init?(_ raw: String?) {
            switch raw {
            case "pending": self = .pending
            case "in_progress": self = .inProgress
            case "completed": self = .completed
            default: return nil
            }
        }
    }

    let id: String
    let subject: String
    let activeForm: String?
    let status: Status
}

struct ActiveTool: Equatable {
    let id: String
    let name: String
    let description: ToolDescriber.Description
}

/// Une réplique de la conversation, telle que les hooks la rapportent (UserPromptSubmit, Stop, SubagentStop).
/// En mémoire seulement : ni sur disque, ni dans `/state`.
struct Utterance: Equatable, Identifiable {
    enum Speaker: Equatable {
        case you
        case claude
        /// Sous-agent, avec son type (« Explore »…), vide s'il est inconnu.
        case agent(String)
    }

    let id = UUID()
    let speaker: Speaker
    let text: String
    let date: Date

    static let maxCount = 6
    static let maxLength = 6000

    /// Même réplique : le texte seul compte (un hook relancé ne la double pas).
    static func == (lhs: Utterance, rhs: Utterance) -> Bool {
        lhs.speaker == rhs.speaker && lhs.text == rhs.text
    }
}

struct Session: Identifiable, Equatable {
    let id: String
    var cwd: String?
    var projectName: String
    var source: SessionSource = .cli
    var hostName: String?
    var hostBundleId: String?
    var claudePid: pid_t?
    var claudeStart: TimeInterval?
    var taskListId: String?
    var configDir: String?
    /// Session côté Claude Desktop (`local_…`) : le clic sur la carte l'ouvre directement.
    var desktopSessionId: String?
    var transcriptPath: String?
    var model: String?
    var title: String?

    var phase: Phase = .ready
    var phaseBeforeCompact: Phase?
    var inTurn = false
    var turnStart: Date?
    var lastTurnDuration: TimeInterval?
    var lastActivity = Date()
    var lastPrompt: String?
    var lastMessage: String?
    var currentTool: ToolDescriber.Description?
    var attentionText: String?
    var attentionToolId: String?
    var errorText: String?
    var activeTools: [ActiveTool] = []
    var finishedTools: Set<String> = []
    var toolCount = 0
    var activeAgents: Set<String> = []
    var tasks: [TaskItem] = []
    /// Dernières répliques (les plus récentes en dernier), pour la vue conversation.
    var conversation: [Utterance] = []
    var doneFlashUntil: Date?
    var endedAt: Date?

    init(id: String, cwd: String?) {
        self.id = id
        self.cwd = cwd
        projectName = cwd.map { ($0 as NSString).lastPathComponent } ?? String(id.prefix(8))
    }

    var isDoneFlashing: Bool { (doneFlashUntil ?? .distantPast) > Date() }
    var completedTaskCount: Int { tasks.filter { $0.status == .completed }.count }
    var currentTask: TaskItem? { tasks.first { $0.status == .inProgress } }
    /// Toutes les cartes sont des sessions Claude Code : l'étiquette dit où elles tournent.
    var sourceLabel: String { source == .desktop ? L("Claude Code (app)") : (hostName ?? "CLI") }

    /// Ajoute une réplique (texte borné, jamais deux fois de suite la même) et garde les plus récentes.
    mutating func say(_ speaker: Utterance.Speaker, _ text: String?, at date: Date) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let bounded = text.count > Utterance.maxLength ? String(text.prefix(Utterance.maxLength - 1)) + "…" : text
        let utterance = Utterance(speaker: speaker, text: bounded, date: date)
        guard conversation.last != utterance else { return }
        conversation.append(utterance)
        if conversation.count > Utterance.maxCount { conversation.removeFirst(conversation.count - Utterance.maxCount) }
    }

    mutating func absorb(_ context: ProcessContext) {
        if let pid = context.claudePid {
            claudePid = pid
            claudeStart = context.claudeStart
        }
        if context.hostName != nil || hostName == nil {
            source = context.source
            hostName = context.hostName ?? hostName
            hostBundleId = context.hostBundleId ?? hostBundleId
        }
        if let id = context.taskListId { taskListId = id }
        if let dir = context.configDir { configDir = dir }
        if let id = context.desktopSessionId { desktopSessionId = id }
    }
}

/// État de toutes les sessions suivies, alimenté par les hooks et un timer de 2 s.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [String: Session] = [:] {
        didSet { updateTimer() }
    }

    static let doneFlashDuration: TimeInterval = 5
    static let endedLinger: TimeInterval = 10
    static let orphanTimeout: TimeInterval = 3 * 3600

    /// Sessions terminées : on ignore leurs événements tardifs (hooks async).
    private var endedIds: Set<String> = []
    private var transcripts: [String: TranscriptCursor] = [:]
    private var timer: Timer?
    private var tickCount = 0
    private var started = false

    /// Le timer tourne (diagnostic, tests).
    var isTicking: Bool { timer != nil }

    /// Timer à 1 s : le transcript (Esc) est relu chaque seconde, le reste toutes les 2 s.
    /// Seulement tant qu'il y a des sessions : sans session, rien à surveiller, aucun réveil.
    func start() {
        started = true
        updateTimer()
    }

    /// Onglet Claude désactivé : sessions oubliées, plus de timer ni de lecture de transcript. Elles reviennent à
    /// leur prochain événement une fois l'onglet réactivé.
    func stop() {
        started = false
        endedIds = []
        transcripts = [:]
        if !sessions.isEmpty { sessions = [:] }
        updateTimer()
    }

    private func updateTimer() {
        if started, !sessions.isEmpty, timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.tickCount += 1
                self.tick(full: self.tickCount % 2 == 0)
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !started || sessions.isEmpty, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    // MARK: - Lecture pour la vue

    /// Attention → en cours → terminé/prête (plus récent d'abord) → terminées.
    var sortedSessions: [Session] {
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

    private static func rank(_ session: Session) -> Int {
        if session.phase.needsAttention { return 0 }
        if session.phase.isWorking { return 1 }
        return session.phase == .ended ? 3 : 2
    }

    var hasLiveSessions: Bool { sessions.values.contains { $0.phase != .ended } }

    /// Une session travaille ou attend l'utilisateur : la mise à jour automatique attend.
    var hasBusySessions: Bool { sessions.values.contains { $0.phase.isWorking || $0.phase.needsAttention } }

    var trackedPids: Set<pid_t> { Set(sessions.values.compactMap(\.claudePid)) }

    var indicator: NotchIndicator {
        let live = sessions.values.filter { $0.phase != .ended }
        if live.contains(where: { $0.phase.needsAttention }) { return .attention }
        if live.contains(where: { $0.phase.isWorking }) { return .working }
        if live.contains(where: \.isDoneFlashing) { return .done }
        return .none
    }

    /// Oreille droite : tâches de la session en avant, sinon nombre de sessions actives.
    var earsText: String? {
        guard let ears else { return nil }
        if let tasks = ears.tasks { return tasks }
        return ears.agents > 0 ? "\(ears.sessions)·\(ears.agents)" : "\(ears.sessions)"
    }

    /// Oreille droite : tâches de la session en avant ; sinon sessions actives, puis agents en cours (« 1·6 »).
    struct EarsContent: Equatable {
        var tasks: String?
        var sessions: Int
        var agents: Int
    }

    var ears: EarsContent? {
        let sorted = sortedSessions
        let focus = sorted.first { $0.phase.needsAttention || $0.phase.isWorking } ?? sorted.first(where: \.isDoneFlashing)
        if let focus, !focus.tasks.isEmpty {
            return EarsContent(tasks: "\(focus.completedTaskCount)/\(focus.tasks.count)", sessions: 0, agents: 0)
        }
        let active = sorted.filter { $0.phase.needsAttention || $0.phase.isWorking }.count
        // Agents en arrière-plan compris : ils tournent parfois après le Stop de leur session.
        let agents = sorted.filter { $0.phase != .ended }.reduce(0) { $0 + $1.activeAgents.count }
        guard active > 0 || agents > 0 else { return nil }
        return EarsContent(tasks: nil, sessions: active, agents: agents)
    }

    func clearEnded() {
        sessions = sessions.filter { _, session in
            session.phase != .ended && !(session.claudePid == nil && !session.inTurn)
        }
    }

    // MARK: - Événements

    func handle(_ event: HookEvent, context: ProcessContext, now: Date = Date()) {
        guard let id = event.sessionId, !id.isEmpty else { return }
        let name = event.name
        if name == "SessionStart" {
            endedIds.remove(id)
        } else if endedIds.contains(id) {
            return
        }

        var session = sessions[id] ?? Session(id: id, cwd: event.cwd)
        session.absorb(context)
        if let path = event.transcriptPath { session.transcriptPath = path }
        session.lastActivity = now
        var reloadTasks = false

        switch name {
        case "SessionStart":
            if let model = event.model { session.model = model }
            if let title = event.sessionTitle { session.title = title }
            if event.source == "compact" {
                restoreAfterCompact(&session)
            } else if !session.inTurn {
                session.phase = .ready
            }

        case "UserPromptSubmit":
            beginTurn(&session, now: now)
            session.phase = .thinking
            if let message = event.notchMessage {
                session.lastPrompt = message.isEmpty
                    ? L("message envoyé depuis la notch", table: "Claude") : ToolDescriber.firstLine(message, max: 90)
                session.say(.you, message, at: now)
            } else if event.isTaskNotification {
                session.lastPrompt = L("résultat d'un agent en arrière-plan")
            } else if let prompt = event.prompt {
                session.lastPrompt = ToolDescriber.firstLine(prompt, max: 90)
                session.say(.you, prompt, at: now)
            }

        case "PreToolUse":
            handlePreToolUse(event, session: &session, now: now)

        case "PermissionRequest":
            ensureTurn(&session, now: now)
            let tool = event.toolName ?? ""
            let description = ToolDescriber.describe(tool: tool, input: event.toolInput)
            let toolId = event.toolUseId ?? session.activeTools.last(where: { $0.name == tool })?.id
            if let toolId, !session.activeTools.contains(where: { $0.id == toolId }),
               !session.finishedTools.contains(toolId) {
                session.activeTools.append(ActiveTool(id: toolId, name: tool, description: description))
            }
            session.attentionToolId = toolId
            switch tool {
            case "AskUserQuestion":
                session.phase = .waitingAnswer
                session.attentionText = ToolDescriber.question(from: event.toolInput)
            case "ExitPlanMode":
                session.phase = .planReview
                session.attentionText = ToolDescriber.planSummary(from: event.toolInput)
            default:
                session.phase = .waitingPermission
                session.attentionText = description.text
            }

        case "PostToolUse", "PostToolUseFailure":
            let tool = event.toolName ?? ""
            if let toolId = event.toolUseId {
                session.finishedTools.insert(toolId)
                if session.finishedTools.count > 400 { session.finishedTools = [toolId] }
                session.activeTools.removeAll { $0.id == toolId }
            } else if let index = session.activeTools.firstIndex(where: { $0.name == tool }) {
                session.activeTools.remove(at: index)
            }
            session.toolCount += 1
            if let attention = session.attentionToolId, !session.activeTools.contains(where: { $0.id == attention }) {
                session.attentionToolId = nil
                session.attentionText = nil
            }
            if session.inTurn, session.phase != .compacting, session.attentionToolId == nil {
                if let last = session.activeTools.last {
                    session.phase = .tool
                    session.currentTool = last.description
                } else {
                    session.phase = .thinking
                }
            }
            if tool == "TodoWrite", let todos = Self.todos(from: event.toolInput) {
                session.tasks = todos
            }
            if tool == "TaskCreate" || tool == "TaskUpdate" { reloadTasks = true }
            if name == "PostToolUseFailure", event.isInterrupt, session.inTurn {
                interrupt(&session, now: now)
            }

        case "Notification":
            handleNotification(event, session: &session, now: now)

        case "Stop":
            endTurn(&session, now: now)
            session.phase = .done
            session.doneFlashUntil = now.addingTimeInterval(Self.doneFlashDuration)
            if let message = event.lastAssistantMessage.flatMap({ ToolDescriber.cleanMarkdown($0) }) {
                session.lastMessage = message
            }
            session.say(.claude, event.lastAssistantMessage, at: now)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.doneFlashDuration + 0.05) { [weak self] in
                self?.objectWillChange.send()
            }

        case "StopFailure":
            endTurn(&session, now: now)
            session.phase = .error
            session.errorText = event.errorText ?? L("erreur de l'API")

        case "SubagentStart":
            if !event.isInternalAgent {
                session.activeAgents.insert(event.agentId ?? UUID().uuidString)
            }

        case "SubagentStop":
            if event.isInternalAgent {
                break
            }
            session.say(.agent(event.agentType ?? ""), event.lastAssistantMessage, at: now)
            if let agent = event.agentId {
                session.activeAgents.remove(agent)
            } else if let any = session.activeAgents.first {
                session.activeAgents.remove(any)
            }

        case "TaskCreated", "TaskCompleted":
            reloadTasks = true

        case "PreCompact":
            if session.phase != .compacting { session.phaseBeforeCompact = session.phase }
            session.phase = .compacting

        case "PostCompact":
            restoreAfterCompact(&session)

        case "SessionEnd":
            markEnded(&session, at: now)

        default:
            break
        }

        sessions[id] = session
        if reloadTasks { scheduleTaskReload(id) }
    }

    /// Réponse donnée depuis la notch : la carte quitte « Attend ta permission » sans attendre la fin de l'outil.
    /// Autorisé : l'outil tourne. Refusé : il ne tournera pas, Claude reprend la main.
    func resolveAttention(_ id: String, allowed: Bool, now: Date = Date()) {
        guard var session = sessions[id], session.phase.needsAttention else { return }
        let toolId = session.attentionToolId
        session.attentionToolId = nil
        session.attentionText = nil
        if allowed, let tool = session.activeTools.first(where: { $0.id == toolId }) ?? session.activeTools.last {
            session.phase = .tool
            session.currentTool = tool.description
        } else {
            if let toolId { session.activeTools.removeAll { $0.id == toolId } }
            session.phase = .thinking
        }
        session.lastActivity = now
        sessions[id] = session
    }

    private func handlePreToolUse(_ event: HookEvent, session: inout Session, now: Date) {
        let tool = event.toolName ?? ""
        let toolId = event.toolUseId ?? UUID().uuidString
        // Hooks async : un PostToolUse peut arriver avant son PreToolUse.
        guard !session.finishedTools.contains(toolId) else { return }
        ensureTurn(&session, now: now)

        let description = ToolDescriber.describe(tool: tool, input: event.toolInput)
        session.activeTools.removeAll { $0.id == toolId }
        session.activeTools.append(ActiveTool(id: toolId, name: tool, description: description))

        switch tool {
        case "AskUserQuestion":
            session.phase = .waitingAnswer
            session.attentionToolId = toolId
            session.attentionText = ToolDescriber.question(from: event.toolInput)
        case "ExitPlanMode":
            session.phase = .planReview
            session.attentionToolId = toolId
            session.attentionText = ToolDescriber.planSummary(from: event.toolInput)
        default:
            // Une demande en attente sur un autre outil reste prioritaire.
            let attentionPending = session.attentionToolId.map { attention in
                session.activeTools.contains { $0.id == attention }
            } ?? false
            if !attentionPending {
                session.phase = .tool
                session.attentionToolId = nil
                session.attentionText = nil
            }
            session.currentTool = description
            if tool == "TodoWrite", let todos = Self.todos(from: event.toolInput) {
                session.tasks = todos
            }
        }
    }

    private func handleNotification(_ event: HookEvent, session: inout Session, now: Date) {
        switch event.notificationType ?? Self.guessNotificationType(event.message) {
        case "permission_prompt":
            if !session.activeTools.isEmpty, !session.phase.needsAttention {
                session.phase = .waitingPermission
                session.attentionToolId = session.activeTools.last?.id
                session.attentionText = session.activeTools.last?.description.text ?? event.message
            }
        case "idle_prompt":
            // Le Stop s'est perdu : on clôt le tour.
            if session.inTurn {
                endTurn(&session, now: now)
                session.phase = .done
            }
        case "agent_needs_input", "elicitation_dialog":
            session.phase = .waitingAnswer
            session.attentionText = event.message
        default:
            break
        }
    }

    // MARK: - Tours

    private func beginTurn(_ session: inout Session, now: Date) {
        session.inTurn = true
        session.turnStart = now
        session.activeTools = []
        session.attentionToolId = nil
        session.attentionText = nil
        session.errorText = nil
        session.currentTool = nil
        session.doneFlashUntil = nil
        resetTranscriptCursor(for: session)
    }

    /// L'app a pu démarrer en plein tour : on rattrape l'état.
    private func ensureTurn(_ session: inout Session, now: Date) {
        guard !session.inTurn else { return }
        session.inTurn = true
        session.turnStart = now
        session.doneFlashUntil = nil
        resetTranscriptCursor(for: session)
    }

    private func endTurn(_ session: inout Session, now: Date) {
        if let start = session.turnStart { session.lastTurnDuration = now.timeIntervalSince(start) }
        session.inTurn = false
        session.turnStart = nil
        session.activeTools = []
        session.attentionToolId = nil
        session.attentionText = nil
        session.currentTool = nil
        transcripts[session.id] = nil
    }

    private func interrupt(_ session: inout Session, now: Date) {
        endTurn(&session, now: now)
        session.phase = .ready
    }

    private func restoreAfterCompact(_ session: inout Session) {
        if session.phase == .compacting {
            session.phase = session.phaseBeforeCompact ?? (session.inTurn ? .thinking : .ready)
        }
        session.phaseBeforeCompact = nil
    }

    private func markEnded(_ session: inout Session, at now: Date) {
        session.phase = .ended
        session.endedAt = now
        session.inTurn = false
        session.activeTools = []
        session.activeAgents = []
        session.attentionToolId = nil
        session.attentionText = nil
        session.doneFlashUntil = nil
        endedIds.insert(session.id)
        transcripts[session.id] = nil
    }

    // MARK: - Timer

    /// `full` : mort des PID, nettoyage et rechargement des tâches (toutes les 2 s).
    /// Sinon seulement la lecture des transcripts des tours en cours.
    func tick(now: Date = Date(), full: Bool = true) {
        var updated = sessions
        for (id, original) in sessions {
            var session = original
            if full {
                if session.phase != .ended, let pid = session.claudePid,
                   !ProcessInspector.isAlive(pid, startedAt: session.claudeStart) {
                    markEnded(&session, at: now)
                }
                if session.phase == .ended {
                    if let ended = session.endedAt, now.timeIntervalSince(ended) > Self.endedLinger {
                        updated[id] = nil
                        continue
                    }
                } else if session.claudePid == nil, now.timeIntervalSince(session.lastActivity) > Self.orphanTimeout {
                    updated[id] = nil
                    transcripts[id] = nil
                    continue
                }
            }
            if session.inTurn, scanTranscript(&session) {
                interrupt(&session, now: now)
            }
            if full, session.phase != .ended, let tasks = TaskListLoader.load(for: session), tasks != session.tasks {
                session.tasks = tasks
            }
            updated[id] = session
        }
        if updated != sessions { sessions = updated }
    }

    // MARK: - Tâches

    private func scheduleTaskReload(_ id: String) {
        for delay in [0.0, 0.3, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reloadTasks(id)
            }
        }
    }

    private func reloadTasks(_ id: String) {
        guard var session = sessions[id], let tasks = TaskListLoader.load(for: session), tasks != session.tasks else { return }
        session.tasks = tasks
        sessions[id] = session
    }

    /// Ancien outil TodoWrite : `tool_input.todos = [{content, status, activeForm}]`.
    static func todos(from input: [String: Any]?) -> [TaskItem]? {
        guard let todos = input?["todos"] as? [[String: Any]] else { return nil }
        return todos.enumerated().compactMap { index, todo in
            guard let status = TaskItem.Status(todo["status"] as? String) else { return nil }
            let subject = (todo["content"] as? String) ?? (todo["subject"] as? String) ?? ""
            return TaskItem(id: (todo["id"] as? String) ?? String(index + 1), subject: subject,
                            activeForm: todo["activeForm"] as? String, status: status)
        }
    }

    // MARK: - Interruption (Esc)

    private struct TranscriptCursor {
        var offset: UInt64
        var carry = Data()
    }

    private static let interruptMarker = "[Request interrupted by user"
    private static let maxTranscriptRead: UInt64 = 4 * 1024 * 1024

    private func resetTranscriptCursor(for session: Session) {
        guard let path = session.transcriptPath else {
            transcripts[session.id] = nil
            return
        }
        transcripts[session.id] = TranscriptCursor(offset: Self.fileSize(path))
    }

    /// Lit ce qui a été ajouté au transcript depuis la dernière fois : marqueur d'interruption (renvoyé)
    /// et titre généré (ligne `ai-title`).
    private func scanTranscript(_ session: inout Session) -> Bool {
        guard let path = session.transcriptPath else { return false }
        let size = Self.fileSize(path)
        guard var cursor = transcripts[session.id] else {
            transcripts[session.id] = TranscriptCursor(offset: size)
            return false
        }
        if size < cursor.offset {
            transcripts[session.id] = TranscriptCursor(offset: size)
            return false
        }
        guard size > cursor.offset else { return false }

        var start = cursor.offset
        if size - start > Self.maxTranscriptRead {
            start = size - Self.maxTranscriptRead
            cursor.carry = Data()
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)) else { return false }
        cursor.offset = start + UInt64(data.count)

        var buffer = cursor.carry + data
        var interrupted = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if Self.isInterruptLine(line) { interrupted = true }
            if let title = Self.aiTitle(in: line) { session.title = title }
            buffer = buffer[(newline + 1)...]
        }
        cursor.carry = buffer.count > 1_000_000 ? Data() : Data(buffer)
        transcripts[session.id] = cursor
        return interrupted
    }

    /// Ligne `type: user` dont le texte commence par « [Request interrupted by user ».
    /// On vérifie la structure pour ne pas réagir à une simple citation du texte.
    static func isInterruptLine(_ line: Data) -> Bool {
        guard line.range(of: Data(interruptMarker.utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "user",
              let message = object["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String {
            return text.hasPrefix(interruptMarker)
        }
        if let blocks = message["content"] as? [[String: Any]] {
            return blocks.contains { ($0["text"] as? String)?.hasPrefix(interruptMarker) ?? false }
        }
        return false
    }

    private static let aiTitleMarker = Data(#""type":"ai-title""#.utf8)

    /// `{"type":"ai-title","aiTitle":"…","sessionId":"…"}`
    static func aiTitle(in line: Data) -> String? {
        guard line.range(of: aiTitleMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let title = object["aiTitle"] as? String, !title.isEmpty else { return nil }
        return title
    }

    private static func fileSize(_ path: String) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func guessNotificationType(_ message: String?) -> String {
        let text = message?.lowercased() ?? ""
        if text.contains("permission") { return "permission_prompt" }
        if text.contains("waiting for your input") { return "idle_prompt" }
        return ""
    }
}

/// Lit les tâches écrites sur disque par TaskCreate / TaskUpdate.
enum TaskListLoader {
    /// Dossier de config = transcript_path moins `projects/<projet>/<id>.jsonl` (respecte CLAUDE_CONFIG_DIR).
    static func configDir(for session: Session) -> URL {
        if let transcript = session.transcriptPath {
            let projects = URL(fileURLWithPath: transcript).deletingLastPathComponent().deletingLastPathComponent()
            if projects.lastPathComponent == "projects" { return projects.deletingLastPathComponent() }
        }
        if let dir = session.configDir {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static func candidateNames(for session: Session) -> [String] {
        var names: [String] = []
        if let listId = session.taskListId { names.append(listId) }
        names.append(session.id)
        names.append("session-" + session.id.prefix(8))
        return names
    }

    /// `nil` si aucun dossier de tâches n'existe pour cette session.
    static func load(for session: Session) -> [TaskItem]? {
        let base = configDir(for: session).appendingPathComponent("tasks")
        for name in candidateNames(for: session) {
            var isDirectory: ObjCBool = false
            let dir = base.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return read(dir)
            }
        }
        return nil
    }

    static func read(_ dir: URL) -> [TaskItem] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let items: [TaskItem] = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = TaskItem.Status(json["status"] as? String) else { return nil }
            let id = (json["id"] as? String)
                ?? (json["id"] as? NSNumber)?.stringValue
                ?? url.deletingPathExtension().lastPathComponent
            let subject = (json["subject"] as? String) ?? (json["content"] as? String) ?? (json["title"] as? String) ?? ""
            return TaskItem(id: id, subject: subject, activeForm: json["activeForm"] as? String, status: status)
        }
        return items.sorted { a, b in
            switch (Int(a.id), Int(b.id)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.id < b.id
            }
        }
    }
}
