import Foundation

// Secrets probables dans un texte copié. Fonction pure, appelée une fois par copie : aucun contenu n'est gardé,
// envoyé ni journalisé ici.
//
// Choix : peu de motifs, tous à préfixe précis, pour éviter les faux positifs (un UUID, un hash git, une phrase ou
// un lien ne sont jamais pris pour un secret). Ce qui n'est pas dans la liste n'est PAS reconnu : mots de passe,
// codes à usage unique, IBAN, clés sans préfixe connu, cartes Diners, JCB, UnionPay ou Maestro, numéro de carte
// accompagné d'autre texte, textes de plus de `maxCharacters` caractères.

enum SecretKind: Equatable {
    case githubToken, awsKey, apiKey, slackToken, stripeKey, googleKey, privateKey, jwt, card

    var label: String {
        switch self {
        case .githubToken: return L("jeton GitHub", table: "Clipboard")
        case .awsKey: return L("clé d'accès AWS", table: "Clipboard")
        case .apiKey: return L("clé d'API (sk-…)", table: "Clipboard")
        case .slackToken: return L("jeton Slack", table: "Clipboard")
        case .stripeKey: return L("clé Stripe", table: "Clipboard")
        case .googleKey: return L("clé d'API Google", table: "Clipboard")
        case .privateKey: return L("clé privée", table: "Clipboard")
        case .jwt: return L("jeton JWT", table: "Clipboard")
        case .card: return L("numéro de carte", table: "Clipboard")
        }
    }
}

enum SecretDetector {
    /// Au-delà, le texte n'est pas analysé (coût borné, et un long texte est rarement un secret).
    static let maxCharacters = 8_000

    private static let sources: [(SecretKind, String)] = [
        (.githubToken, #"\b(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{60,255})\b"#),
        (.awsKey, #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        (.apiKey, #"\bsk-(?:ant-)?[A-Za-z0-9_-]{32,}"#),
        (.slackToken, #"\bxox[abprs]-[A-Za-z0-9-]{20,}"#),
        (.stripeKey, #"\b[sr]k_live_[A-Za-z0-9]{20,}"#),
        (.googleKey, #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        (.privateKey, #"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----"#),
        (.jwt, #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
    ]
    private static let patterns = sources.map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    static func detect(_ text: String) -> SecretKind? {
        guard text.count <= maxCharacters else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for (kind, regex) in patterns {
            for match in regex.matches(in: text, range: range) {
                guard let found = Range(match.range, in: text) else { continue }
                // Un slug (« sk-mon-article-de-blog… ») n'a ni chiffre ni majuscule ni minuscule mêlés.
                if kind == .apiKey, !looksRandom(text[found]) { continue }
                return kind
            }
        }
        return isCardNumber(text) ? .card : nil
    }

    private static func looksRandom(_ token: Substring) -> Bool {
        token.contains(where: \.isNumber) && token.contains(where: \.isUppercase) && token.contains(where: \.isLowercase)
    }

    /// Le texte entier est un numéro : chiffres seuls, par groupes séparés d'un espace ou d'un tiret, clé de Luhn
    /// valable et début propre à Visa, Mastercard, American Express ou Discover.
    static func isCardNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 23, trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == " " || $0 == "-") }),
              !trimmed.contains("  "), !trimmed.contains("--"), !trimmed.hasPrefix("-"), !trimmed.hasSuffix("-")
        else { return false }
        let digits = trimmed.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), luhn(digits) else { return false }
        let prefix2 = digits[0] * 10 + digits[1]
        let prefix4 = prefix2 * 100 + digits[2] * 10 + digits[3]
        switch digits.count {
        case 15: return prefix2 == 34 || prefix2 == 37
        case 16:
            return digits[0] == 4 || (51...55).contains(prefix2) || (2221...2720).contains(prefix4)
                || prefix4 == 6011 || prefix2 == 65
        case 13, 19: return digits[0] == 4
        default: return false
        }
    }

    private static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}
