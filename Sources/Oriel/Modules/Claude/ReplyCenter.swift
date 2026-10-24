import Combine
import Darwin
import Foundation

/// « Répondre depuis la notch » : les requêtes longues des hooks synchrones, tenues par `HookServer`.
///
/// - `/permission` (hook PermissionRequest synchrone) : la demande est tenue jusqu'à un clic dans la notch, ou
///   rendue sans décision (le terminal garde la main) dès que l'outil se termine, que le tour change, que le hook
///   ferme sa connexion (réponse donnée au terminal) ou à l'échéance : 4 s si la carte n'a pas été vue dans la
///   notch, ~590 s sinon. Le dialogue du terminal reste utilisable pendant ce temps : la première réponse gagne.
/// - `/inbox` (hooks SessionStart et Stop en `asyncRewake`) : une seule attente par session. Un message envoyé
///   depuis la notch lui est remis et réveille Claude ; sans attente, il reste en file (FIFO) jusqu'à la suivante.
///   Session sans terminal (`claude -p`, SDK) : rendue tout de suite, pas de message. Onglet Code de Claude
///   Desktop : tenue à la fin d'un tour (`Stop`), rendue tout de suite au démarrage (voir `wait`).
///
/// Une décision n'existe qu'en réponse à la requête d'un hook, après un clic : jamais de « toujours autoriser »,
/// jamais d'autorisation par défaut. Réglage désactivé : tout est rendu tout de suite. Main thread uniquement.
final class ReplyCenter: ObservableObject {
    static let shared = ReplyCenter(prefs: .shared)

    /// Carte jamais vue dans la notch : le terminal reprend la main.
    static let graceDelay: TimeInterval = 4
    /// Carte vue : sous le timeout du hook (600 s).
    static let engagedDelay: TimeInterval = 590
    /// Message remis à Claude par stderr : taille bornée, caractères de contrôle retirés.
    static let maxMessageBytes = 1800
    static let maxQueuedPerSession = 10
    static let noticeDuration: TimeInterval = 4

    // MARK: - Types

    struct Permission: Equatable {
        /// « Terminal », « Édition »…
        let label: String
        /// Ce qui sera fait : commande complète, chemin, adresse.
        let detail: String?
        let isCode: Bool
        /// Description donnée par Claude (Bash).
        let note: String?
    }

    struct Question: Equatable, Identifiable {
        struct Option: Equatable {
            let label: String
            let detail: String?
        }

        let id: Int
        /// Texte exact : c'est la clé de la réponse.
        let text: String
        let header: String?
        let options: [Option]
        let multiSelect: Bool
    }

    enum Kind {
        case permission(Permission)
        case question([Question])
        case plan(String)
    }

    struct Request: Identifiable {
        let id: UUID
        let sessionId: String
        let toolName: String
        /// `tool_input` d'origine, renvoyé dans `updatedInput` (questions, plan).
        let input: [String: Any]
        let kind: Kind
        let received: Date
        var engaged = false
        var deadline: Date
        fileprivate let reply: (Data?) -> Void
    }

    enum Decision: Equatable {
        case allow
        case deny(String)
        /// Texte exact de la question → libellé choisi (ou texte libre).
        case answer([String: String])
        case approvePlan
        case revisePlan(String)
    }

    struct Notice: Equatable {
        enum Tone { case done, info, warning }

        let text: String
        let tone: Tone
        let id = UUID()
    }

    enum SendResult: Equatable { case delivered, queued }

    // MARK: - État

    /// Demandes tenues, dans l'ordre d'arrivée.
    @Published private(set) var requests: [Request] = []
    /// Sessions dont une attente `asyncRewake` est connectée : un message part tout de suite.
    @Published private(set) var waiting: Set<String> = []
    /// Messages en file, par session.
    @Published private(set) var queued: [String: [String]] = [:]
    /// Dernier retour visible, par session (quelques secondes).
    @Published private(set) var notices: [String: Notice] = [:]
    /// Sessions sans terminal : on ne peut pas leur écrire.
    @Published private(set) var headless: Set<String> = []

    private struct Waiter {
        let id: UUID
        let pid: pid_t?
        let reply: (String?) -> Void
    }

    private let prefs: Preferences
    private var waiters: [String: Waiter] = [:]
    private var processSources: [pid_t: DispatchSourceProcess] = [:]
    private var expiryTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Horloge des échéances (injectable pour les tests).
    var clock: () -> Date = { Date() }
    /// argv d'un processus Claude (injectable pour les tests).
    var processArguments: (pid_t) -> [String] = { ProcessInspector.arguments($0) }

    init(prefs: Preferences) {
        self.prefs = prefs
        prefs.$replyFromNotch
            .removeDuplicates()
            .sink { [weak self] isOn in
                if !isOn { self?.releaseAll() }
            }
            .store(in: &cancellables)
    }

    var isEnabled: Bool { prefs.replyFromNotch }

    /// Voie vers la session, pour `/state` : une attente connectée (message immédiat), des messages en file, une
    /// session sans terminal fermée aux messages, ou rien (le prochain `Stop` en ouvrira une).
    func channel(for sessionId: String) -> String {
        if waiting.contains(sessionId) { return "waiting" }
        if queued[sessionId] != nil { return "queued" }
        return headless.contains(sessionId) ? "headless" : "none"
    }

    /// Plus ancienne demande tenue pour la session.
    func request(for sessionId: String) -> Request? {
        requests.first { $0.sessionId == sessionId }
    }

    // MARK: - Permissions (`/permission`)

    /// Tient la demande d'un hook PermissionRequest ; `reply` reçoit la sortie du hook (JSON) ou nil (204).
    func hold(_ event: HookEvent, id: UUID = UUID(), reply: @escaping (Data?) -> Void) {
        guard isEnabled, let sessionId = event.sessionId, let tool = event.toolName else { return reply(nil) }
        let input = event.toolInput ?? [:]
        let kind: Kind
        switch tool {
        case "AskUserQuestion":
            let questions = Self.questions(from: input)
            guard !questions.isEmpty else { return reply(nil) }
            kind = .question(questions)
        case "ExitPlanMode":
            kind = .plan(Self.planPreview((input["plan"] as? String) ?? ""))
        default:
            kind = .permission(Self.permission(tool: tool, input: input))
        }
        let now = clock()
        requests.append(Request(id: id, sessionId: sessionId, toolName: tool, input: input, kind: kind,
                                received: now, deadline: now.addingTimeInterval(Self.graceDelay), reply: reply))
        scheduleExpiry()
    }

    /// La carte est à l'écran : l'utilisateur a le temps de répondre.
    func engage(_ id: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == id }), !requests[index].engaged else { return }
        requests[index].engaged = true
        requests[index].deadline = requests[index].received.addingTimeInterval(Self.engagedDelay)
        scheduleExpiry()
    }

    /// Clic dans la notch. Faux si la demande n'est plus tenue (déjà réglée ailleurs, délai passé) ou si la
    /// décision ne correspond pas à son type.
    @discardableResult
    func decide(_ request: Request, _ decision: Decision) -> Bool {
        guard let index = requests.firstIndex(where: { $0.id == request.id }) else {
            notify(request.sessionId, L("Trop tard : déjà réglé ailleurs", table: "Claude"), .warning)
            return false
        }
        guard let output = Self.output(decision, for: requests[index]) else { return false }
        let held = requests.remove(at: index)
        held.reply(output)
        notify(held.sessionId, Self.confirmation(decision), .done)
        scheduleExpiry()
        return true
    }

    /// Événement relayé par `/hook` : l'outil s'est terminé, le tour a changé, la session est finie.
    func observe(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }
        switch event.name {
        case "PostToolUse", "PostToolUseFailure":
            release { request in
                request.sessionId == sessionId && request.toolName == event.toolName && Self.sameCall(request, event)
            }
        case "Stop", "StopFailure", "UserPromptSubmit":
            release { $0.sessionId == sessionId }
        case "SessionEnd":
            release { $0.sessionId == sessionId }
            closeWaiter(sessionId)
            queued[sessionId] = nil
            headless.remove(sessionId)
        default:
            break
        }
    }

    /// Le hook a fermé sa connexion : réponse donnée au terminal, hook tué ou arrivé à son timeout.
    func connectionClosed(_ id: UUID) {
        if let index = requests.firstIndex(where: { $0.id == id }) {
            let request = requests.remove(at: index)
            if request.engaged { notify(request.sessionId, L("Déjà réglé dans la session", table: "Claude"), .info) }
            scheduleExpiry()
        }
        if let entry = waiters.first(where: { $0.value.id == id }) {
            waiters[entry.key] = nil
            waitersChanged()
        }
    }

    /// Échéances atteintes : rendues sans décision.
    func expire(now: Date? = nil) {
        let now = now ?? clock()
        let due = requests.filter { $0.deadline <= now }
        if !due.isEmpty {
            requests.removeAll { $0.deadline <= now }
            for request in due {
                request.reply(nil)
                if request.engaged {
                    notify(request.sessionId, L("Délai dépassé : réponds dans la session", table: "Claude"), .warning)
                }
            }
        }
        scheduleExpiry()
    }

    private func release(where matches: (Request) -> Bool) {
        let released = requests.filter(matches)
        guard !released.isEmpty else { return }
        requests.removeAll(where: matches)
        for request in released {
            request.reply(nil)
            if request.engaged { notify(request.sessionId, L("Déjà réglé dans la session", table: "Claude"), .info) }
        }
        scheduleExpiry()
    }

    /// Une seule minuterie, sur l'échéance la plus proche ; aucune sans demande tenue.
    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let next = requests.map(\.deadline).min() else { return }
        let timer = Timer(fire: max(next, Date()), interval: 0, repeats: false) { [weak self] _ in self?.expire() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    // MARK: - Messages (`/inbox`)

    /// Attente d'un hook `asyncRewake` : `reply` reçoit le message, ou nil (204) si l'attente est remplacée,
    /// si Claude est mort ou si le réglage est coupé. Un message en file part tout de suite.
    ///
    /// Sans terminal, Claude attend la fin de ce hook avant de lire le prompt (mesuré, 2.1.304) : tenu sur
    /// `SessionStart` il bloquerait la session (21 s pour 20 s tenues), et sur `claude -p` il bloquerait la sortie.
    /// Seule exception, l'onglet Code de Claude Desktop (`desktop` : identifiant de session Desktop, flux stream-json,
    /// session qui reste ouverte) à la fin d'un tour (`atStop`). Le résultat du tour est déjà parti, le prompt suivant
    /// n'attend pas, et un message réveille Claude (nouveau tour ~3 s plus tard, ou lu après l'outil en cours).
    /// À la fermeture, SIGTERM sort aussitôt ; fermer stdin laisse au plus ~30 s.
    func wait(sessionId: String, pid: pid_t?, id: UUID = UUID(), desktop: Bool = false, atStop: Bool = false,
              reply: @escaping (String?) -> Void) {
        guard isEnabled, pid.map({ ProcessInspector.isAlive($0) }) ?? true else { return reply(nil) }
        if let pid {
            let arguments = processArguments(pid)
            if Self.isHeadless(arguments) {
                if desktop, !Self.isPrint(arguments) {
                    // Pas de terminal mais une session Desktop : on peut lui écrire, sauf au démarrage.
                    guard atStop else { return reply(nil) }
                    headless.remove(sessionId)
                } else {
                    headless.insert(sessionId)
                    return reply(nil)
                }
            }
        }
        // Une seule attente par session : la nouvelle remplace l'ancienne.
        waiters.removeValue(forKey: sessionId)?.reply(nil)
        if var queue = queued[sessionId], !queue.isEmpty {
            let message = queue.removeFirst()
            queued[sessionId] = queue.isEmpty ? nil : queue
            waitersChanged()
            reply(message)
            notify(sessionId, L("Message remis à Claude", table: "Claude"), .done)
            return
        }
        waiters[sessionId] = Waiter(id: id, pid: pid, reply: reply)
        if let pid { watchProcess(pid) }
        waitersChanged()
    }

    /// Message de l'utilisateur : remis à l'attente connectée, sinon mis en file. nil : message vide ou file pleine.
    @discardableResult
    func send(_ text: String, to sessionId: String) -> SendResult? {
        let message = Self.sanitize(text)
        guard isEnabled, !message.isEmpty, !headless.contains(sessionId) else { return nil }
        if let waiter = waiters.removeValue(forKey: sessionId) {
            waiter.reply(message)
            waitersChanged()
            notify(sessionId, L("Message envoyé", table: "Claude"), .done)
            return .delivered
        }
        var queue = queued[sessionId] ?? []
        guard queue.count < Self.maxQueuedPerSession else {
            notify(sessionId, L("File pleine : attends la fin du tour", table: "Claude"), .warning)
            return nil
        }
        queue.append(message)
        queued[sessionId] = queue
        return .queued
    }

    /// Retire les messages en file d'une session.
    func dropQueue(_ sessionId: String) {
        queued[sessionId] = nil
    }

    private func closeWaiter(_ sessionId: String) {
        guard let waiter = waiters.removeValue(forKey: sessionId) else { return }
        waiter.reply(nil)
        waitersChanged()
    }

    private func waitersChanged() {
        let sessions = Set(waiters.keys)
        if sessions != waiting { waiting = sessions }
        // Plus d'attente pour ce processus : on ne le surveille plus.
        let pids = Set(waiters.values.compactMap(\.pid))
        for (pid, source) in processSources where !pids.contains(pid) {
            source.cancel()
            processSources[pid] = nil
        }
    }

    /// Fin du processus claude, par kqueue (aucune scrutation) : ses attentes orphelines sont fermées.
    private func watchProcess(_ pid: pid_t) {
        guard processSources[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.processExited(pid) }
        source.resume()
        processSources[pid] = source
        // Mort entre la requête et l'abonnement : kqueue ne dira rien.
        if !ProcessInspector.isAlive(pid) { processExited(pid) }
    }

    private func processExited(_ pid: pid_t) {
        for (sessionId, waiter) in waiters where waiter.pid == pid {
            waiters[sessionId] = nil
            queued[sessionId] = nil
            waiter.reply(nil)
        }
        processSources.removeValue(forKey: pid)?.cancel()
        waitersChanged()
    }

    /// Réglage coupé ou onglet Claude désactivé : tout est rendu au terminal.
    func releaseAll() {
        let held = requests
        let open = waiters
        requests = []
        waiters = [:]
        queued = [:]
        held.forEach { $0.reply(nil) }
        open.values.forEach { $0.reply(nil) }
        waitersChanged()
        scheduleExpiry()
    }

    // MARK: - Retours

    private func notify(_ sessionId: String, _ text: String, _ tone: Notice.Tone) {
        let notice = Notice(text: text, tone: tone)
        notices[sessionId] = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeDuration) { [weak self] in
            if self?.notices[sessionId]?.id == notice.id { self?.notices[sessionId] = nil }
        }
    }

    private static func confirmation(_ decision: Decision) -> String {
        switch decision {
        case .allow: return L("Autorisé", table: "Claude")
        case .deny: return L("Refusé", table: "Claude")
        case .answer: return L("Réponse envoyée", table: "Claude")
        case .approvePlan: return L("Plan approuvé", table: "Claude")
        case .revisePlan: return L("Changements demandés", table: "Claude")
        }
    }

    var debugInfo: [String: Any] {
        [
            "enabled": isEnabled,
            "pending": requests.count,
            "engaged": requests.filter(\.engaged).count,
            "waiting": waiters.count,
            "queued": queued.values.reduce(0) { $0 + $1.count },
        ]
    }

    // MARK: - Sortie du hook

    /// Messages lus par Claude (et affichés dans sa session), pas par l'interface : en anglais.
    static let defaultDenyMessage = "The user denied this from Oriel."
    static let defaultReviseMessage = "The user wants changes to the plan. Keep planning."

    /// JSON écrit par le hook sur sa sortie standard ; nil si la décision ne correspond pas à la demande.
    static func output(_ decision: Decision, for request: Request) -> Data? {
        var body: [String: Any]
        switch (decision, request.kind) {
        case (.allow, .permission):
            body = ["behavior": "allow"]
        case (.deny(let message), .permission):
            body = ["behavior": "deny", "message": sanitize(message).nonEmpty ?? defaultDenyMessage]
        case (.answer(let answers), .question(let questions)):
            let texts = Set(questions.map(\.text))
            let cleaned = answers.compactMapValues { sanitize($0).nonEmpty }.filter { texts.contains($0.key) }
            guard cleaned.count == texts.count else { return nil }
            var input = request.input
            input["answers"] = cleaned
            body = ["behavior": "allow", "updatedInput": input]
        case (.approvePlan, .plan):
            // `allow` seul est ignoré pour ExitPlanMode : il faut l'entrée d'origine et le mode.
            body = ["behavior": "allow", "updatedInput": request.input,
                    "updatedPermissions": [["type": "setMode", "mode": "acceptEdits", "destination": "session"]]]
        case (.revisePlan(let message), .plan):
            body = ["behavior": "deny", "message": sanitize(message).nonEmpty ?? defaultReviseMessage]
        default:
            return nil
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }

    /// Réponse d'une question : un libellé, ou les libellés choisis joints par « , » (multiSelect), plus le texte
    /// libre éventuel.
    static func answer(selected: [String], other: String) -> String {
        let free = sanitize(other)
        return (selected + (free.isEmpty ? [] : [free])).joined(separator: ", ")
    }

    // MARK: - Lecture de la demande

    static func questions(from input: [String: Any]) -> [Question] {
        let raw = input["questions"] as? [[String: Any]] ?? []
        return raw.enumerated().compactMap { index, question in
            guard let text = question["question"] as? String, !text.isEmpty else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> Question.Option? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return Question.Option(label: label, detail: (option["description"] as? String)?.nonEmpty)
            }
            return Question(id: index, text: text, header: (question["header"] as? String)?.nonEmpty,
                            options: options, multiSelect: question["multiSelect"] as? Bool ?? false)
        }
    }

    /// Ce que l'utilisateur autorise, en entier : commande complète, chemin, adresse.
    static func permission(tool: String, input: [String: Any]) -> Permission {
        let description = ToolDescriber.describe(tool: tool, input: input)
        func text(_ key: String) -> String? {
            (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        switch tool {
        case "Bash":
            return Permission(label: description.label, detail: text("command"), isCode: true, note: text("description"))
        case "Read", "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = text("file_path") ?? text("notebook_path")
            return Permission(label: description.label, detail: path.map { ($0 as NSString).abbreviatingWithTildeInPath },
                              isCode: true, note: nil)
        case "WebFetch":
            return Permission(label: description.label, detail: text("url"), isCode: true, note: nil)
        default:
            // Toute l'entrée (arguments MCP, prompt d'un agent, args d'un skill), comme le dialogue du terminal ;
            // au-delà de 6 lignes, la carte prévient qu'elle est coupée.
            let json = input.isEmpty ? nil : (try? JSONSerialization.data(
                withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) }
            return Permission(label: description.label, detail: json.map { ToolDescriber.truncate($0, max: 2000) },
                              isCode: true, note: description.detail)
        }
    }

    /// Claude lancé sans terminal : `-p`/`--print`, ou entrée/sortie en flux (SDK, IDE, onglet Code de Claude
    /// Desktop, qui passe `--input-format stream-json` sans `-p`).
    static func isHeadless(_ arguments: [String]) -> Bool {
        isPrint(arguments) || arguments.dropFirst().prefix { $0 != "--" }.contains { argument in
            ["--input-format", "--output-format"].contains { argument == $0 || argument.hasPrefix($0 + "=") }
        }
    }

    /// `claude -p` : un seul tour, le processus sort quand les hooks ont fini.
    static func isPrint(_ arguments: [String]) -> Bool {
        arguments.dropFirst().prefix { $0 != "--" }.contains { $0 == "-p" || $0 == "--print" }
    }

    /// Plan lisible sans rendu Markdown : titres et gras retirés, lignes vides regroupées, longueur bornée.
    static func planPreview(_ plan: String) -> String {
        var lines: [String] = []
        for raw in plan.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        return ToolDescriber.truncate(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                                      max: 2000)
    }

    /// Même appel d'outil : même entrée (sauf questions et plan, dont l'entrée revient complétée).
    private static func sameCall(_ request: Request, _ event: HookEvent) -> Bool {
        if request.toolName == "AskUserQuestion" || request.toolName == "ExitPlanMode" { return true }
        guard let input = event.toolInput else { return true }
        return NSDictionary(dictionary: request.input).isEqual(to: input)
    }

    /// Caractères de contrôle retirés (sauf saut de ligne et tabulation), blancs de bord retirés, taille bornée
    /// en octets UTF-8 sans couper un caractère.
    static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            switch scalar {
            case "\n", "\t": scalars.append(scalar)
            case "\r", "\u{2028}", "\u{2029}": scalars.append("\n")
            default:
                if scalar.properties.generalCategory != .control { scalars.append(scalar) }
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maxMessageBytes else { return trimmed }
        let ellipsis = "…"
        var result = ""
        var size = 0
        for character in trimmed {
            let length = character.utf8.count
            if size + length > maxMessageBytes - ellipsis.utf8.count { break }
            result.append(character)
            size += length
        }
        return result + ellipsis
    }
}

private extension String {
    /// nil si vide.
    var nonEmpty: String? { isEmpty ? nil : self }
}
