import Foundation

// Barre de commande : « > relance les tests » écrit à une session Claude, comme le champ de la conversation.
// Seulement si « Répondre depuis la notch » est activé. Textes dans la table « Command ».

extension ClaudeModule {
    /// Pas de verbe tant que les réponses sont coupées : la barre n'offre rien qui ne marcherait pas.
    var commandVerb: CommandVerb? {
        prefs.replyFromNotch ? CommandVerb(key: ">", title: "Claude") : nil
    }

    func commands(for query: CommandQuery) -> [NotchCommand] {
        guard prefs.replyFromNotch, query.verb == ">" else { return [] }
        let sessions = store.sortedSessions.filter { $0.phase != .ended && !replies.headless.contains($0.id) }
        guard !sessions.isEmpty else {
            return [NotchCommand(id: "claude.none", symbol: "moon.zzz", title: L("Aucune session à qui écrire", table: "Command"),
                                 detail: L("Une session Claude Code ouverte apparaîtra ici", table: "Command"),
                                 isEnabled: false)]
        }
        let message = query.argument
        var commands: [NotchCommand] = []
        for (index, session) in sessions.enumerated() {
            let id = session.id
            commands.append(NotchCommand(
                id: "claude.send.\(id)", symbol: "sparkle",
                title: String(format: L("Envoyer à « %@ »", table: "Command"), session.projectName),
                detail: message.isEmpty ? L("Écris ton message après le >", table: "Command") : delivery(session),
                tint: session.phase.needsAttention ? Palette.amber : Palette.accent, score: 1000 - index,
                isEnabled: !message.isEmpty,
                run: { [weak self] in
                    self?.replies.send(message, to: id) == nil ? L("Message non envoyé (file pleine ou session fermée)", table: "Command") : nil
                }))
        }
        for (index, session) in sessions.enumerated() {
            commands.append(NotchCommand(
                id: "claude.open.\(session.id)", symbol: "arrow.up.forward.app",
                title: String(format: L("Ouvrir « %@ »", table: "Command"), session.projectName),
                detail: L("Met la session au premier plan", table: "Command"), tint: Palette.secondary, score: 500 - index,
                run: { [weak self] in
                    self?.actions.activate(session)
                    return nil
                }))
        }
        return commands
    }

    /// Quand Claude lira le message : les mêmes textes que le champ de la conversation.
    private func delivery(_ session: Session) -> String {
        if replies.waiting.contains(session.id) {
            return session.phase.isWorking ? L("Claude le lira après l'action en cours", table: "Claude")
                : L("Claude le lira tout de suite", table: "Claude")
        }
        return session.phase.isWorking ? L("En file : il partira à la fin du tour", table: "Claude")
            : L("En file : Claude le lira à son prochain tour", table: "Claude")
    }
}
