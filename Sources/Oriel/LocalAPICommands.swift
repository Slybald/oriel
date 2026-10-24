import SwiftUI

// Barre de commande : « i sauvegarde » retire un intercalaire posé par un script. Textes dans la table « Command ».

extension LocalAPI: CommandSource {
    /// Pas de verbe tant qu'aucun script n'a posé d'intercalaire.
    var commandVerb: CommandVerb? {
        items.isEmpty ? nil : CommandVerb(key: "i", title: L("intercalaires", table: "Command"))
    }

    /// Le plus récent d'abord. Sans verbe : rien, le texte d'un script ne s'invite pas dans une recherche libre.
    func commands(for query: CommandQuery) -> [NotchCommand] {
        guard query.verb != nil else { return [] }
        var commands: [NotchCommand] = []
        for (index, ear) in items.reversed().enumerated() {
            let match = query.argument.isEmpty ? 500 - index : FuzzyMatch.score(query.argument, in: ear.title + " " + ear.client)
            guard let score = match else { continue }
            let id = ear.id
            commands.append(NotchCommand(
                id: "api.remove.\(id)", symbol: ear.icon,
                title: String(format: L("Retirer « %@ »", table: "Command"), ear.title),
                detail: String(format: L("via %@", table: "API"), ear.client), tint: Color(hex: ear.accentHex) ?? Palette.accent,
                score: score,
                run: { [weak self] in self?.remove(id) == true ? nil : L("Intercalaire déjà retiré", table: "Command") }))
        }
        if items.count > 1, query.argument.isEmpty {
            commands.append(NotchCommand(id: "api.clear", symbol: "xmark.circle",
                                         title: L("Retirer tous les intercalaires des scripts", table: "Command"),
                                         detail: String(format: L("%d intercalaires", table: "Command"), items.count),
                                         run: { [weak self] in
                                             self?.clear()
                                             return nil
                                         }))
        }
        return commands
    }
}
