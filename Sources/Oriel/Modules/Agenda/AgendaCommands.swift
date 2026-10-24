import Foundation

// Barre de commande : « a équipe » cherche dans les prochains rendez-vous, ⏎ rejoint la réunion (lien reconnu) ou
// ouvre Calendrier à ce jour. Textes dans la table « Command ».

extension AgendaModule {
    var commandVerb: CommandVerb? { CommandVerb(key: "a", title: L("agenda", table: "Command")) }

    /// Rendez-vous pas encore finis d'aujourd'hui et de demain, déjà lus (rien n'est relu ici). « Rejoindre » passe par
    /// `join`, le même contrôle du lien que le bouton. Sans verbe, trois lettres au moins.
    func commands(for query: CommandQuery) -> [NotchCommand] {
        guard access == .granted, query.verb != nil || query.argument.count >= 3 else { return [] }
        let now = clock()
        let cal = Calendar.current
        let limit = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)) ?? now
        let upcoming = events.filter { !$0.isAllDay && $0.end > now && $0.start < limit }.sorted { $0.start < $1.start }
        var commands: [NotchCommand] = []
        for (index, event) in upcoming.prefix(20).enumerated() {
            let match = query.argument.isEmpty ? 500 - index : FuzzyMatch.score(query.argument, in: event.title)
            guard let score = match else { continue }
            var detail = event.start <= now ? L("en cours", table: "Agenda") : AgendaFormat.until(event.start, from: now)
            detail += " · " + AgendaFormat.range(event)
            if !event.location.isEmpty { detail += " · " + event.location }
            let joinable = event.meeting.map { MeetingLink.isOpenable($0.url) } ?? false
            commands.append(NotchCommand(
                id: "agenda.\(joinable ? "join" : "open").\(event.id)", symbol: joinable ? "video.fill" : "calendar",
                title: joinable ? String(format: L("Rejoindre « %@ »", table: "Command"), event.title) : event.title,
                detail: detail, score: score,
                run: { [weak self] in
                    if joinable { self?.join(event) } else { self?.openCalendar(at: event.start) }
                    return nil
                }))
        }
        return commands
    }
}
