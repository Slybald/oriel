import Foundation

// Barre de commande : « m facture » cherche dans les derniers mails reçus, ⏎ ouvre le mail choisi dans Mail.
// Textes dans la table « Command ».

extension MailModule {
    var commandVerb: CommandVerb? { CommandVerb(key: "m", title: L("mail", table: "Command")) }

    /// Les mails déjà lus pour l'onglet (expéditeur, sujet) : la recherche ne lance aucun script et ne répond jamais.
    /// Sujets masqués dans les réglages : aucun mail n'est montré. Sans verbe, trois lettres au moins.
    func commands(for query: CommandQuery) -> [NotchCommand] {
        guard state == .ready, query.verb != nil || query.argument.count >= 3 else { return [] }
        var commands: [NotchCommand] = []
        if showSubjects {
            for (index, message) in messages.enumerated() {
                let match = query.argument.isEmpty ? 500 - index
                    : FuzzyMatch.score(query.argument, in: message.sender + " " + message.subject)
                guard let score = match else { continue }
                commands.append(NotchCommand(
                    id: "mail.open.\(message.id)", symbol: message.isUnread ? "envelope.badge" : "envelope",
                    title: message.sender, detail: message.subject, score: score,
                    run: { [weak self] in
                        self?.openMessage(message)
                        return nil
                    }))
            }
        }
        if query.verb != nil, query.argument.isEmpty {
            commands.append(NotchCommand(id: "mail.app", symbol: "envelope.open", title: L("Ouvrir Mail", table: "Command"),
                                         detail: L("Met Mail au premier plan", table: "Command"),
                                         run: { [weak self] in
                                             self?.openMail()
                                             return nil
                                         }))
        }
        return commands
    }
}
