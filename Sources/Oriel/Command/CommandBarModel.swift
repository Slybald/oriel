import SwiftUI

// Barre de commande : un champ dans le panneau, des verbes d'une touche (« t 25 », « n idée », « > message »), les
// modules proposent les actions. Rien ne s'exécute avant que l'utilisateur valide. Tout ce fichier est pur (aucune
// fenêtre, aucun accès système) : la vue est dans `CommandBarView`, les commandes dans le dossier de chaque module.

/// Une touche qui adresse un module (« t » pour le minuteur).
struct CommandVerb: Equatable {
    /// Une lettre (« t ») ou un symbole (« > »). Jamais traduite : les doigts ne changent pas de langue.
    let key: String
    /// Nom sous le champ, localisé (« minuteur »).
    let title: String

    var isSymbol: Bool { !(key.first?.isLetter ?? false) }
}

/// Saisie analysée : le verbe tapé et ce qui le suit.
struct CommandQuery: Equatable {
    /// Touche du verbe (« t ») ; nil = texte libre, adressé à tous les modules.
    var verb: String?
    /// Texte après le verbe, espaces autour retirés ; toute la saisie sans verbe.
    var argument: String

    func addresses(_ verb: CommandVerb) -> Bool { self.verb == nil || self.verb == verb.key }
}

/// Une action proposée par un module. `run` n'est appelée qu'à la validation (⏎ ou clic sur la ligne).
struct NotchCommand: Identifiable {
    /// Stable (« timer.start.25 ») : identité de la ligne et clé des tests.
    let id: String
    var symbol: String
    var title: String
    var detail: String
    var tint: Color = Palette.accent
    /// Pertinence pour la saisie : le plus grand d'abord ; à égalité, l'ordre des onglets puis celui du module.
    var score = 0
    /// Faux : ligne grisée qui explique (« Écris ton message »), sans action.
    var isEnabled = true
    /// Exécute l'action. Rend le message d'un échec (la barre reste ouverte et le dit), nil si c'est fait.
    var run: () -> String? = { nil }
}

// MARK: - Analyse

enum CommandParser {
    /// Verbe tapé en tête de saisie et ce qui le suit ; nil = texte libre. Un verbe-lettre n'en est un que suivi
    /// d'une espace (« t 25 » : « tomate » reste du texte), un symbole dès qu'il ouvre la saisie (« >message »).
    static func leadingVerb(in text: String, keys: [String]) -> (key: String, rest: String)? {
        let input = text.drop(while: \.isWhitespace)
        guard let first = input.first else { return nil }
        let key = String(first).lowercased()
        guard keys.contains(key) else { return nil }
        let rest = input.dropFirst()
        if first.isLetter {
            guard let next = rest.first, next.isWhitespace else { return nil }
        }
        return (key, String(rest.drop(while: \.isWhitespace)))
    }
}

// MARK: - Recherche floue

enum FuzzyMatch {
    /// Au-delà, seule l'inclusion compte : presque tout long texte contient « lien » comme suite de lettres.
    static let maxSubsequenceLength = 64

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// nil : pas de correspondance. Sinon plus c'est grand, mieux c'est. Casse et accents ignorés ; tous les mots de
    /// `query` doivent correspondre. Un mot correspond s'il est inclus (mieux au début du texte ou d'un mot), ou,
    /// dans un texte court, si ses lettres s'y suivent de près (« prsnt » trouve « Présentation »).
    /// shortcut : alignement glouton (la première lettre trouvée), pas le meilleur alignement possible ; à
    /// reprendre si un classement fin devient nécessaire.
    static func score(_ query: String, in text: String) -> Int? {
        score(query, inFolded: fold(text))
    }

    /// Comme `score(_:in:)` pour un texte déjà passé par `fold` (l'historique du presse-papiers garde le sien).
    static func score(_ query: String, inFolded haystack: String) -> Int? {
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return 0 }
        var total = 0
        for word in words {
            guard let value = score(word: String(word), in: haystack) else { return nil }
            total += value
        }
        return total
    }

    private static func score(word: String, in haystack: String) -> Int? {
        if let range = haystack.range(of: word) {
            let position = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            var value = 1000 - min(position, 150) - min(haystack.count, 100) / 4
            if position == 0 {
                value += 400
            } else if !haystack[haystack.index(before: range.lowerBound)].isLetterOrNumber {
                value += 200
            }
            return value
        }
        guard word.count >= 2, haystack.count <= maxSubsequenceLength else { return nil }
        var gaps = 0
        var start: Int?
        var previous: Int?
        var query = word.makeIterator()
        var wanted = query.next()
        for (offset, character) in haystack.enumerated() {
            guard let target = wanted else { break }
            guard character == target else { continue }
            if start == nil { start = offset }
            if let previous { gaps += offset - previous - 1 }
            previous = offset
            wanted = query.next()
        }
        guard wanted == nil, let start, gaps <= word.count * 2 else { return nil }
        return max(1, 500 - gaps * 8 - start * 4)
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}

// MARK: - Modèle de la barre

/// Saisie, verbe, résultats et sélection de la barre. Interroge les modules qui tournent (jamais ceux qui sont
/// arrêtés ou désactivés : la recherche ne réveille personne) ; n'exécute rien avant `run`.
final class CommandBarModel: ObservableObject {
    /// Lignes affichées : le panneau reste sous ses 460 pt.
    static let maxResults = 5

    /// Texte du champ, sans le verbe : le verbe reconnu devient `verb` (la vue le montre à part).
    @Published var text = "" {
        didSet {
            guard !rewriting, text != oldValue else { return }
            edited()
        }
    }
    @Published private(set) var verb: CommandVerb?
    /// Verbes des modules interrogeables, dans l'ordre des onglets : les pastilles sous le champ.
    @Published private(set) var verbs: [CommandVerb] = []
    @Published private(set) var results: [NotchCommand] = []
    @Published private(set) var selection = 0
    /// Pourquoi la dernière action n'a pas abouti ; effacé dès que la saisie ou la sélection change.
    @Published private(set) var failure: String?

    /// Modules interrogeables, dans l'ordre des onglets (puis l'API locale).
    private let modules: () -> [any CommandSource]
    /// La barre a fini (action lancée) : le contrôleur la ferme.
    var onFinish: () -> Void = {}
    private var rewriting = false

    /// Une barre neuve à chaque ouverture : champ vide, sans verbe.
    init(modules: @escaping () -> [any CommandSource]) {
        self.modules = modules
        refreshVerbs()
    }

    var query: CommandQuery {
        CommandQuery(verb: verb?.key, argument: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Pastille touchée : le verbe s'ajoute à ce qui est tapé ; touchée à nouveau, il s'en va.
    func pick(_ chip: CommandVerb) {
        verb = verb == chip ? nil : chip
        refresh()
    }

    /// Retour arrière sur un champ vide : le verbe redevient une lettre à effacer (un symbole disparaît).
    func backspaceOnEmptyField() {
        guard let current = verb, text.isEmpty else { return }
        verb = nil
        rewriting = true
        text = current.isSymbol ? "" : current.key
        rewriting = false
        refresh()
    }

    func move(_ delta: Int) {
        failure = nil
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    /// ⏎ : lance la ligne choisie, si elle a une action.
    func runSelected() {
        guard results.indices.contains(selection) else { return }
        run(results[selection])
    }

    func run(_ command: NotchCommand) {
        guard command.isEnabled else { return }
        if let message = command.run() {
            failure = message
        } else {
            onFinish()
        }
    }

    private func edited() {
        refreshVerbs()
        if verb == nil, let found = CommandParser.leadingVerb(in: text, keys: verbs.map(\.key)),
           let match = verbs.first(where: { $0.key == found.key }) {
            verb = match
            rewriting = true
            text = found.rest
            rewriting = false
        }
        refresh()
    }

    private func refreshVerbs() {
        var seen = Set<String>()
        let current = modules().compactMap(\.commandVerb).filter { seen.insert($0.key).inserted }
        if current != verbs { verbs = current }
        // Un module désactivé pendant la saisie emporte son verbe.
        if let verb, !current.contains(verb) { self.verb = nil }
    }

    private func refresh() {
        let query = self.query
        failure = nil
        defer { selection = 0 }
        guard query.verb != nil || !query.argument.isEmpty else {
            results = []
            return
        }
        var found: [(command: NotchCommand, module: Int, index: Int)] = []
        for (order, module) in modules().enumerated() {
            guard let moduleVerb = module.commandVerb, query.addresses(moduleVerb) else { continue }
            for (index, command) in module.commands(for: query).enumerated() {
                found.append((command, order, index))
            }
        }
        found.sort { a, b in
            if a.command.score != b.command.score { return a.command.score > b.command.score }
            return (a.module, a.index) < (b.module, b.index)
        }
        results = found.prefix(Self.maxResults).map(\.command)
    }
}

extension ModuleRegistry {
    /// Modules que la barre peut interroger : activés ET en marche. Un module arrêté (panneau replié, onglet masqué)
    /// ne se réveille pas pour une recherche.
    var commandModules: [any NotchModule] { enabled.filter { running.contains($0.id) } }

    /// Ce que la barre interroge : ces modules, puis les intercalaires des scripts (sans verbe s'il n'y en a aucun).
    var commandSources: [any CommandSource] { commandModules + [external] }
}
