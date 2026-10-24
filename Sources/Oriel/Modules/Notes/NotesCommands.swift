import Foundation

// Barre de commande : « n idée » crée une note. Textes dans la table « Command ».

extension NotesModule {
    var commandVerb: CommandVerb? { CommandVerb(key: "n", title: L("note", table: "Command")) }

    /// « Notes rapides » : une note créée sans toucher à celle qui est ouverte. Les notes ne sont pas cherchées ici.
    func commands(for query: CommandQuery) -> [NotchCommand] {
        guard query.verb != nil else { return [] }
        let text = query.argument
        let title = text.isEmpty ? L("Nouvelle note", table: "Command")
            : String(format: L("Nouvelle note « %@ »", table: "Command"), String(text.prefix(50)))
        let isFull = notes.count >= Self.maxNotes
        let detail: String
        if isFull {
            detail = String(format: L("Limite de %d notes atteinte", table: "Notes"), Self.maxNotes)
        } else if text.isEmpty {
            detail = L("Écris le texte de la note, puis ⏎", table: "Command")
        } else {
            detail = L("Ajoutée à tes notes rapides", table: "Command")
        }
        return [NotchCommand(id: "notes.add", symbol: "note.text", title: title, detail: detail, score: 1000,
                             isEnabled: !text.isEmpty && !isFull,
                             run: { [weak self] in self?.addNote(text) == true ? nil : L("Note non créée", table: "Command") })]
    }
}
