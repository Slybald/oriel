import Foundation

// Barre de commande : « c lien » cherche dans les copies, ⏎ recopie la ligne choisie. Textes dans la table « Command ».

extension ClipboardModule {
    var commandVerb: CommandVerb? { CommandVerb(key: "c", title: L("copies", table: "Command")) }

    /// Les copies déjà gardées, jamais celles que la confidentialité a écartées. Sans verbe : rien (les résultats
    /// d'une recherche libre n'ont pas à montrer le contenu du presse-papiers).
    func commands(for query: CommandQuery) -> [NotchCommand] {
        guard query.verb != nil else { return [] }
        let now = Date()
        var commands: [NotchCommand] = []
        for item in history.ordered {
            guard commands.count < 10, let score = FuzzyMatch.score(query.argument, inFolded: item.searchText) else { continue }
            var detail = SessionCard.relative(now.timeIntervalSince(item.date))
            if let source = item.source?.name { detail += " · " + source }
            if item.pinned { detail = L("Épinglée", table: "Command") + " · " + detail }
            let id = item.id
            commands.append(NotchCommand(id: "clipboard.copy.\(id.uuidString)", symbol: Self.symbol(of: item.content),
                                         title: Self.title(of: item.content), detail: detail, score: score,
                                         run: { [weak self] in
                                             self?.copy(id)
                                             return nil
                                         }))
        }
        return commands
    }

    /// Première ligne du texte, ou ce que la copie est (lien, image, fichiers, couleur).
    static func title(of content: ClipboardContent) -> String {
        switch content {
        case .text(let text):
            let line = text.prefix(300).split(whereSeparator: \.isNewline)
                .first { !$0.allSatisfy(\.isWhitespace) }
            return String((line ?? "").trimmingCharacters(in: .whitespaces).prefix(80))
        case .url(let url): return String(url.absoluteString.prefix(80))
        case .image(let image): return L("Image", table: "Clipboard") + " " + ClipboardPreview.imageDetail(image)
        case .files(let urls): return String(urls.map(\.lastPathComponent).joined(separator: ", ").prefix(80))
        case .color(let hex): return "#" + hex
        }
    }

    static func symbol(of content: ClipboardContent) -> String {
        switch content {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .image: return "photo"
        case .files: return "doc"
        case .color: return "paintpalette"
        }
    }
}
