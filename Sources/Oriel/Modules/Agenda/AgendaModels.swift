import Foundation

// Logique pure de l'onglet Agenda (ni EventKit, ni vue) : lien de réunion, rendez-vous en vue, prochaine échéance.

// MARK: - Lien de réunion

/// Lien de visioconférence trouvé dans un événement.
///
/// Le titre, le lieu et les notes d'un événement viennent d'un tiers (une invitation). On ne retient donc qu'un lien
/// `https` dont le domaine est celui d'un service connu (jamais `zoom.us.autre.com`, jamais un compte dans l'adresse),
/// ou un lien `facetime:` posé dans le champ URL de l'événement. Il ne s'ouvre que sur un clic de l'utilisateur.
struct MeetingLink: Equatable {
    enum Provider: String, CaseIterable {
        case zoom, meet, teams, webex, facetime

        /// Noms de marque : pas traduits.
        var name: String {
            switch self {
            case .zoom: return "Zoom"
            case .meet: return "Google Meet"
            case .teams: return "Microsoft Teams"
            case .webex: return "Webex"
            case .facetime: return "FaceTime"
            }
        }

        fileprivate func accepts(host: String, path: String) -> Bool {
            func isDomain(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
            switch self {
            case .zoom: return isDomain("zoom.us") && (path.hasPrefix("/j/") || path.hasPrefix("/my/"))
            case .meet:
                // Un code de réunion Meet : trois lettres, quatre, trois.
                return host == "meet.google.com"
                    && path.range(of: "^/[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil
            case .teams:
                return (host == "teams.microsoft.com" && (path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/")))
                    || (host == "teams.live.com" && path.hasPrefix("/meet/"))
            case .webex: return isDomain("webex.com") && path.count > 1
            case .facetime: return host == "facetime.apple.com" && path.hasPrefix("/join")
            }
        }
    }

    let provider: Provider
    let url: URL

    /// Longueur maximale d'un lien retenu, et du texte parcouru (les notes d'une invitation peuvent être longues).
    private static let maxLinkLength = 2048
    private static let maxTextLength = 50_000

    /// Le champ URL de l'événement d'abord, puis le lieu, puis les notes ; le premier lien reconnu l'emporte.
    static func find(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        if let url, let link = link(for: url, isEventURL: true) { return link }
        for text in [location, notes] {
            guard let text else { continue }
            for candidate in candidates(in: text) {
                if let link = link(for: candidate, isEventURL: false) { return link }
            }
        }
        return nil
    }

    /// Même contrôle que `find`, pour un lien déjà en main : la dernière vérification avant l'ouverture.
    static func isOpenable(_ url: URL) -> Bool {
        link(for: url, isEventURL: true) != nil
    }

    private static func link(for url: URL, isEventURL: Bool) -> MeetingLink? {
        guard url.absoluteString.count <= maxLinkLength else { return nil }
        if isEventURL, url.scheme?.lowercased() == "facetime", url.absoluteString.count > "facetime://".count {
            return MeetingLink(provider: .facetime, url: url)
        }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(),
              // Un nom d'hôte ordinaire : un caractère codé (%2f), un antislash ou une lettre d'un autre alphabet
              // pourrait faire lire à `URLComponents` un autre domaine que celui que le système ouvrira.
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
        let path = parts.path.lowercased()
        guard let provider = Provider.allCases.first(where: { $0.accepts(host: host, path: path) }) else { return nil }
        return MeetingLink(provider: provider, url: url)
    }

    /// Adresses `http(s)://…` du texte, sans la ponctuation qui les suit dans une phrase.
    private static func candidates(in text: String) -> [URL] {
        let text = String(text.prefix(maxTextLength))
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s<>\"]+") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let found = Range(match.range, in: text) else { return nil }
            let trimmed = text[found].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>'"))
            return URL(string: trimmed)
        }
    }
}

// MARK: - Rendez-vous en vue

enum AgendaPhase: Equatable {
    /// Moins de 15 minutes avant le début : intercalaire discret.
    case soon
    /// 5 minutes ou moins : ambre.
    case imminent
    /// Commencé, pas terminé.
    case running
}

/// Le rendez-vous que montre l'intercalaire.
struct AgendaFocus: Equatable {
    let event: MediaEvent
    let phase: AgendaPhase
    /// Minutes avant le début, arrondies au-dessus (« 1 min » jusqu'à la dernière seconde) ; 0 une fois commencé.
    let minutes: Int
}

enum AgendaMath {
    static let soonLead: TimeInterval = 15 * 60
    static let imminentLead: TimeInterval = 5 * 60
    /// Un événement plus long (voyage, congés saisis à l'heure) n'est pas un rendez-vous : pas d'intercalaire « en cours ».
    static let maxDuration: TimeInterval = 12 * 3600

    static func minutes(until start: Date, from now: Date) -> Int {
        max(0, Int((start.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// Où en est l'événement ; nil s'il est trop loin, terminé, sans heure ou trop long.
    static func phase(of event: MediaEvent, at now: Date) -> AgendaPhase? {
        guard !event.isAllDay, event.end > now, event.end.timeIntervalSince(event.start) <= maxDuration else { return nil }
        let remaining = event.start.timeIntervalSince(now)
        if remaining <= 0 { return .running }
        if remaining <= imminentLead { return .imminent }
        return remaining <= soonLead ? .soon : nil
    }

    /// Le rendez-vous à montrer : celui qui va commencer (5 min) d'abord, puis celui en cours, puis celui qui approche
    /// (15 min) ; à égalité, le plus tôt.
    static func focus(_ events: [MediaEvent], at now: Date) -> AgendaFocus? {
        func rank(_ phase: AgendaPhase) -> Int { phase == .imminent ? 0 : (phase == .running ? 1 : 2) }
        return events.compactMap { event in phase(of: event, at: now).map { (event, $0) } }
            .min { (rank($0.1), $0.0.start) < (rank($1.1), $1.0.start) }
            .map { AgendaFocus(event: $0.0, phase: $0.1, minutes: minutes(until: $0.0.start, from: now)) }
    }

    /// La seule échéance à planifier : le prochain seuil (début − 15 min, − 5 min, début, fin) d'un événement et, tant
    /// qu'un compte à rebours s'affiche, le changement de minute. nil : rien à attendre.
    static func nextWake(_ events: [MediaEvent], after now: Date) -> Date? {
        var wakes: [Date] = []
        for event in events where !event.isAllDay && event.end > now {
            wakes += [event.start - soonLead, event.start - imminentLead, event.start, event.end]
        }
        if let focus = focus(events, at: now), focus.phase != .running {
            wakes.append(focus.event.start - TimeInterval(max(0, focus.minutes - 1) * 60))
        }
        return wakes.filter { $0 > now }.min()
    }
}

// MARK: - Textes

enum AgendaFormat {
    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let dayTimeFormatter = formatter("EEEjmm")

    /// Texte de l'intercalaire : « 14 min », « en cours ».
    static func ears(_ focus: AgendaFocus) -> String {
        focus.phase == .running
            ? L("en cours", table: "Agenda")
            : String(format: L("%d min", table: "Agenda"), focus.minutes)
    }

    /// « 10:30 – 11:00 ».
    static func range(_ event: MediaEvent) -> String {
        "\(MediaFormat.time(event.start)) – \(MediaFormat.time(event.end))"
    }

    /// « dans 4 min », « dans 1 h 15 », « 14:30 » (plus tard dans la journée), « jeu. 09:00 » (un autre jour).
    static func until(_ start: Date, from now: Date, calendar: Calendar = .current) -> String {
        let minutes = AgendaMath.minutes(until: start, from: now)
        if minutes < 60 { return String(format: L("dans %d min", table: "Agenda"), minutes) }
        if minutes < 6 * 60 {
            let rest = minutes % 60
            return rest == 0
                ? String(format: L("dans %d h", table: "Agenda"), minutes / 60)
                : String(format: L("dans %d h %02d", table: "Agenda"), minutes / 60, rest)
        }
        return calendar.isDate(start, inSameDayAs: now) ? MediaFormat.time(start) : dayTimeFormatter.string(from: start)
    }
}
