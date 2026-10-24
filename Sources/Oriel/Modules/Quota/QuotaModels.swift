import Foundation

/// Une fenêtre de quota (5 h, 7 jours…) : part consommée et heure de remise à zéro. Commune à Claude (`statusLine`) et à
/// Codex (`account/rateLimits/read`), pour que les deux onglets dessinent la même jauge.
struct QuotaWindow: Equatable {
    /// 0 à 100, arrondi.
    var usedPercent: Int
    var resetsAt: Date
    /// Durée de la fenêtre en minutes, quand la source la donne (Codex) ou la fixe (Claude : 300 et 10 080).
    var minutes: Int?

    init(usedPercent: Double, resetsAt: Date, minutes: Int?) {
        self.usedPercent = Int(min(100, max(0, usedPercent.isFinite ? usedPercent.rounded() : 0)))
        self.resetsAt = resetsAt
        self.minutes = minutes
    }

    enum Level: Equatable { case normal, high, critical }

    /// Au-delà de 80 % la jauge passe à l'ambre, au-delà de 95 % au rouge.
    var level: Level { usedPercent >= 95 ? .critical : usedPercent >= 80 ? .high : .normal }

    var fraction: Double { Double(usedPercent) / 100 }

    /// « 5 h », « 7 j » ; vide quand la durée est inconnue.
    var label: String {
        guard let minutes, minutes > 0 else { return "" }
        if minutes < 1440 {
            return String(format: L("%d h", table: "Quota"), max(1, Int((Double(minutes) / 60).rounded())))
        }
        return String(format: L("%d j", table: "Quota"), Int((Double(minutes) / 1440).rounded()))
    }

    /// L'heure de remise à zéro ; avec le jour quand ce n'est pas aujourd'hui (« 14:32 », « mar. 10:00 »).
    func resetText(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(resetsAt, inSameDayAs: now) ? "jmm" : "EEEjmm")
        return formatter.string(from: resetsAt)
    }
}

/// Ce qu'on sait des quotas à un instant : une à deux fenêtres, la plus courte d'abord.
struct QuotaSnapshot: Equatable {
    var windows: [QuotaWindow]
    var updatedAt: Date

    /// Sans les fenêtres déjà remises à zéro (leur chiffre ne vaut plus rien) ; nil s'il n'en reste aucune, ou si la
    /// mesure a plus de `maxAge` secondes (Codex n'est relu que panneau ouvert : un intercalaire ne montre pas un vieux chiffre).
    func live(at now: Date, maxAge: TimeInterval? = nil) -> [QuotaWindow]? {
        if let maxAge, now.timeIntervalSince(updatedAt) > maxAge { return nil }
        let kept = windows.filter { $0.resetsAt > now }
        return kept.isEmpty ? nil : kept
    }
}
