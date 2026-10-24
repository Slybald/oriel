import Combine
import Foundation

/// Approbations Codex depuis la notch : les requêtes longues de `/codex/permission` (hook `PermissionRequest`
/// synchrone), tenues par `HookServer` jusqu'à un clic.
///
/// Mesuré sur Codex 0.154 (CLI, app-server) : le hook tourne AVANT l'invite de Codex et celle-ci attend sa fin. Contrairement
/// à Claude Code, le terminal ne propose donc rien tant que la notch tient la demande : le délai est court et le
/// terminal reprend la main à l'échéance (sortie sans décision), au clic sur « Dans le terminal », ou quand le hook
/// ferme sa connexion. Une carte jamais vue dans la notch est rendue après 4 s.
///
/// Une décision n'existe qu'en réponse à la requête d'un hook, après un clic : jamais « toujours autoriser », jamais
/// d'autorisation par défaut. Réglage coupé : tout est rendu tout de suite (fail-open). Main thread uniquement.
final class CodexApprovals: ObservableObject {
    /// Carte jamais vue dans la notch : le terminal reprend la main.
    static let graceDelay: TimeInterval = 4
    /// Carte vue : sous le timeout du hook (75 s dans hooks.json).
    static let engagedDelay: TimeInterval = 60
    static let noticeDuration: TimeInterval = 4

    struct Request: Identifiable {
        let id: UUID
        let sessionId: String
        let toolName: String
        let tool: CodexToolText
        /// Commande ou patch d'origine (`tool_input.command`) : permet de reconnaître l'appel au `PostToolUse`.
        let command: String?
        /// Description donnée par Codex (`tool_input.description`).
        let note: String?
        let received: Date
        var engaged = false
        var deadline: Date
        fileprivate let reply: (Data?) -> Void
    }

    enum Decision: Equatable {
        case allow
        case deny
        /// Rendre la main au terminal sans décider.
        case terminal
    }

    struct Notice: Equatable {
        enum Tone { case done, info, warning }

        let text: String
        let tone: Tone
        let id = UUID()
    }

    @Published private(set) var requests: [Request] = []
    /// Dernier retour visible, par session (quelques secondes).
    @Published private(set) var notices: [String: Notice] = [:]

    /// Réglage « Approuver depuis la notch » ; coupé, rien n'est tenu.
    var isEnabled: () -> Bool = { false }
    /// Horloge des échéances (injectable pour les tests).
    var clock: () -> Date = { Date() }
    private var expiryTimer: Timer?

    /// Plus ancienne demande tenue pour la session.
    func request(for sessionId: String) -> Request? {
        requests.first { $0.sessionId == sessionId }
    }

    // MARK: - Demandes

    /// Tient la demande d'un hook PermissionRequest ; `reply` reçoit la sortie du hook (JSON) ou nil (204).
    func hold(_ event: HookEvent, id: UUID = UUID(), reply: @escaping (Data?) -> Void) {
        guard isEnabled(), let sessionId = event.sessionId, let name = event.toolName else { return reply(nil) }
        let tool = CodexTools.describe(name: name, input: event.toolInput)
        let now = clock()
        requests.append(Request(id: id, sessionId: sessionId, toolName: name, tool: tool,
                                command: event.toolInput?["command"] as? String,
                                note: (event.toolInput?["description"] as? String).flatMap(CodexTools.clipped),
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

    /// Clic dans la notch. Faux si la demande n'est plus tenue (déjà réglée ailleurs, délai passé).
    @discardableResult
    func decide(_ request: Request, _ decision: Decision) -> Bool {
        guard let index = requests.firstIndex(where: { $0.id == request.id }) else {
            notify(request.sessionId, L("Trop tard : déjà réglé ailleurs", table: "Codex"), .warning)
            return false
        }
        let held = requests.remove(at: index)
        switch decision {
        case .allow:
            held.reply(Self.output(allow: true))
            notify(held.sessionId, L("Autorisé depuis la notch", table: "Codex"), .done)
        case .deny:
            held.reply(Self.output(allow: false))
            notify(held.sessionId, L("Refusé depuis la notch", table: "Codex"), .done)
        case .terminal:
            held.reply(nil)
            notify(held.sessionId, L("À toi dans le terminal", table: "Codex"), .info)
        }
        scheduleExpiry()
        return true
    }

    /// Événement relayé par `/codex/hook` : l'outil s'est terminé, le tour a changé, la session est finie.
    func observe(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }
        switch event.name {
        case "PostToolUse":
            release { $0.sessionId == sessionId && $0.toolName == event.toolName && Self.sameCall($0, event) }
        case "Stop", "UserPromptSubmit", "Interrupt", "SessionEnd":
            release { $0.sessionId == sessionId }
        default:
            break
        }
    }

    /// Le hook a fermé sa connexion : réponse donnée au terminal, hook tué ou arrivé à son timeout.
    func connectionClosed(_ id: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        let request = requests.remove(at: index)
        if request.engaged { notify(request.sessionId, L("Déjà réglé dans la session", table: "Codex"), .info) }
        scheduleExpiry()
    }

    /// Échéances atteintes : rendues sans décision, Codex pose sa question dans le terminal.
    func expire(now: Date? = nil) {
        let now = now ?? clock()
        let due = requests.filter { $0.deadline <= now }
        if !due.isEmpty {
            requests.removeAll { $0.deadline <= now }
            for request in due {
                request.reply(nil)
                if request.engaged { notify(request.sessionId, L("Délai dépassé : réponds dans le terminal", table: "Codex"), .warning) }
            }
        }
        scheduleExpiry()
    }

    /// Tout rendu sans décision (onglet désactivé, réglage coupé, arrêt).
    func releaseAll() {
        guard !requests.isEmpty else { return }
        let all = requests
        requests = []
        all.forEach { $0.reply(nil) }
        scheduleExpiry()
    }

    private func release(where matches: (Request) -> Bool) {
        let released = requests.filter(matches)
        guard !released.isEmpty else { return }
        requests.removeAll(where: matches)
        for request in released {
            request.reply(nil)
            if request.engaged { notify(request.sessionId, L("Déjà réglé dans la session", table: "Codex"), .info) }
        }
        scheduleExpiry()
    }

    /// La demande et l'événement portent la même commande (la demande n'a pas d'identifiant d'appel).
    private static func sameCall(_ request: Request, _ event: HookEvent) -> Bool {
        guard let held = request.command, let done = event.toolInput?["command"] as? String else { return true }
        return held == done
    }

    // MARK: - Échéances et retours

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

    private func notify(_ sessionId: String, _ text: String, _ tone: Notice.Tone) {
        let notice = Notice(text: text, tone: tone)
        notices[sessionId] = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeDuration) { [weak self] in
            if self?.notices[sessionId] == notice { self?.notices[sessionId] = nil }
        }
    }

    // MARK: - Sortie du hook

    /// Format de sortie de PermissionRequest (documenté, vérifié sur Codex 0.154) : `allow`, ou `deny` avec un
    /// message qui revient à Codex comme raison du refus. Ni `updatedInput` ni `updatedPermissions` (refusés).
    static func output(allow: Bool) -> Data {
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if !allow { decision["message"] = "Denied from Oriel." }
        let root: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }

    var debugInfo: [String: Any] {
        ["held": requests.count, "engaged": requests.filter(\.engaged).count]
    }
}
