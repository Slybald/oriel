import Foundation

/// Lecture du JSON que Claude Code passe à sa `statusLine` : seul `rate_limits` est gardé. Le reste (dossier, modèle,
/// session) n'est ni stocké ni écrit. Format mesuré sur Claude Code 2.1.304 : rien avant la première réponse de la
/// session, puis `rate_limits.five_hour` et `seven_day` (`used_percentage` 0-100, `resets_at` en secondes epoch), chaque
/// fenêtre pouvant manquer (hors abonnement Pro et Max, tout manque).
enum ClaudeUsage {
    private static let windows: [(key: String, minutes: Int)] = [("five_hour", 300), ("seven_day", 10_080)]

    static func parse(_ data: Data, now: Date) -> QuotaSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        let parsed: [QuotaWindow] = windows.compactMap { key, minutes in
            guard let window = limits[key] as? [String: Any],
                  let used = (window["used_percentage"] as? NSNumber)?.doubleValue,
                  let reset = (window["resets_at"] as? NSNumber)?.doubleValue, reset > 0 else { return nil }
            return QuotaWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: reset), minutes: minutes)
        }
        return parsed.isEmpty ? nil : QuotaSnapshot(windows: parsed, updatedAt: now)
    }
}

/// Dernier quota relayé par la `statusLine` (`POST /claude/status`). En mémoire seulement : rien sur le disque, et rien
/// à l'arrêt de l'app avant la prochaine réponse d'une session. Le quota est celui du compte, pas d'une session : la
/// dernière mesure reçue de n'importe quelle session vaut.
final class ClaudeUsageStore: ObservableObject {
    static let shared = ClaudeUsageStore()

    @Published private(set) var snapshot: QuotaSnapshot?

    /// Main thread. Un JSON sans `rate_limits` (début de session, API sans abonnement) ne change rien.
    func ingest(_ data: Data, now: Date = Date()) {
        guard let parsed = ClaudeUsage.parse(data, now: now) else { return }
        snapshot = parsed
    }

    /// Onglet Claude désactivé, relais retiré : plus de chiffre.
    func forget() {
        if snapshot != nil { snapshot = nil }
    }
}
