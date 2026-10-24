import Foundation

// Types et décodages purs de l'onglet Messages (testés sans base ni fenêtre).

// MARK: - Accès

/// Où en est la lecture de `~/Library/Messages/chat.db`.
enum MessagesAccess: Equatable {
    /// Pas encore regardé.
    case unknown
    case ready
    /// `open()` refuse (EPERM) : l'app n'a pas l'« Accès complet au disque ». Aucune fenêtre de macOS pour ça :
    /// il faut l'accorder à la main dans Réglages Système.
    case needsFullDiskAccess
    /// Le fichier n'existe pas : Messages n'a jamais servi sur ce Mac.
    case noDatabase
    /// La base s'ouvre mais ses tables ne sont pas celles qu'on connaît (format changé).
    case unsupported
}

enum ContactsAccess: Equatable {
    case notDetermined
    case denied
    case granted
}

// MARK: - Ce que donne la base

/// Une conversation telle que la base la décrit (pas de nom de contact : il vient de Contacts, à part).
struct ThreadRow: Equatable {
    var guid: String
    /// `chat_identifier` : numéro, adresse e-mail, ou « chatNNN » pour un groupe.
    var identifier: String
    var displayName: String
    var isGroup: Bool
    /// Texte du dernier message, sur une ligne ; vide pour une pièce jointe seule.
    var text: String
    var hasAttachment: Bool
    var date: Date
    var fromMe: Bool
    var unread: Int
    /// Participants d'un groupe sans nom (adresses), de quoi en faire un titre.
    var participants: [String]
}

struct MessagesSnapshot: Equatable {
    var rows: [ThreadRow]
    /// Messages reçus non lus des 30 derniers jours (voir `SQLiteMessagesDatabase.unreadWindow`).
    var unread: Int
}

enum MessagesRead: Equatable {
    case snapshot(MessagesSnapshot)
    case unavailable(MessagesAccess)
}

// MARK: - Ce que montre la vue

struct MessageThread: Identifiable, Equatable {
    /// `chat.guid` : l'identifiant que comprend AppleScript (`chat id`).
    var id: String
    var title: String
    var snippet: String
    var date: Date
    var unread: Int
    var fromMe: Bool
    var isGroup: Bool
    /// Ouvre la conversation dans Messages (1 contre 1 seulement) ; nil = ouvrir l'app.
    var openURL: URL?
}

// MARK: - Texte d'un message

/// Sur macOS récent, `message.text` est souvent NULL : le texte est dans `attributedBody`, un `NSAttributedString`
/// archivé par `NSArchiver` (format « typedstream », pas un plist). On ne désarchive pas (`NSUnarchiver` est
/// obsolète) : on lit la chaîne à la main, comme les outils d'export.
///
/// Disposition mesurée sur macOS 27.0.1 avec `NSArchiver` : en-tête `04 0b "streamtyped" 81 e8 03`, puis les classes,
/// puis `"NSString" 01 94 84 01 2b <longueur> <octets UTF-8>`. La classe est `NSMutableString` pour un
/// `NSMutableAttributedString` (le nom `NSString` apparaît alors comme sa superclasse, juste avant le `2b`).
/// Longueur : un octet < 0x80, ou `81` + 2 octets, ou `82` + 4 octets (petit-boutiste).
enum TypedStreamText {
    static func string(from data: Data) -> String? {
        let bytes = [UInt8](data)
        let header = Array("streamtyped".utf8)
        guard bytes.count > 20, bytes[0] == 0x04, bytes[1] == 0x0b, Array(bytes[2..<13]) == header,
              let marker = index(of: Array("NSString".utf8), in: bytes, from: 13) else { return nil }
        let after = marker + 8
        guard let plus = (after..<min(after + 8, bytes.count)).first(where: { bytes[$0] == 0x2b }) else { return nil }
        var cursor = plus + 1
        guard cursor < bytes.count else { return nil }
        let length: Int
        switch bytes[cursor] {
        case 0x81:
            guard cursor + 2 < bytes.count else { return nil }
            length = Int(bytes[cursor + 1]) | Int(bytes[cursor + 2]) << 8
            cursor += 3
        case 0x82:
            guard cursor + 4 < bytes.count else { return nil }
            length = (1...4).reduce(0) { $0 | Int(bytes[cursor + $1]) << (8 * ($1 - 1)) }
            cursor += 5
        case ..<0x80:
            length = Int(bytes[cursor])
            cursor += 1
        default:
            return nil
        }
        guard cursor + length <= bytes.count else { return nil }
        return String(data: Data(bytes[cursor..<cursor + length]), encoding: .utf8)
    }

    private static func index(of needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard start <= bytes.count - needle.count else { return nil }
        return (start...(bytes.count - needle.count)).first {
            bytes[$0] == needle[0] && Array(bytes[$0..<$0 + needle.count]) == needle
        }
    }
}

enum MessageText {
    /// U+FFFC : l'emplacement d'une pièce jointe dans le texte.
    static let attachmentMark = "\u{FFFC}"
    static let maxLength = 300

    /// Le texte à montrer : `text` s'il existe, sinon `attributedBody` ; sur une ligne, sans marque de pièce jointe.
    static func plain(text: String?, attributedBody: Data?) -> String {
        let raw: String
        if let text, !text.isEmpty {
            raw = text
        } else if let attributedBody, let decoded = TypedStreamText.string(from: attributedBody) {
            raw = decoded
        } else {
            raw = ""
        }
        let words = raw.replacingOccurrences(of: attachmentMark, with: "").split(whereSeparator: \.isWhitespace)
        return String(words.joined(separator: " ").prefix(maxLength))
    }
}

enum MessageDates {
    /// `message.date` : nanosecondes depuis 2001-01-01 depuis macOS 10.13, secondes avant.
    static func date(fromAppleTime value: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: usesNanoseconds(value) ? Double(value) / 1e9 : Double(value))
    }

    static func usesNanoseconds(_ value: Int64) -> Bool { abs(value) > 100_000_000_000 }

    static func appleTime(_ date: Date, nanoseconds: Bool) -> Int64 {
        Int64(date.timeIntervalSinceReferenceDate * (nanoseconds ? 1e9 : 1))
    }
}

// MARK: - Noms des contacts

/// Carnet d'adresses réduit à ce qu'il faut pour nommer une adresse de Messages.
struct ContactBook: Equatable {
    /// Neuf derniers chiffres du numéro → nom (+33 6… et 06… tombent sur la même clé).
    var phones: [String: String] = [:]
    var emails: [String: String] = [:]

    func name(for handle: String) -> String? {
        if handle.contains("@") { return emails[handle.lowercased()] }
        return Self.phoneKey(handle).flatMap { phones[$0] }
    }

    static func phoneKey(_ number: String) -> String? {
        let digits = number.filter(\.isNumber)
        return digits.count >= 6 ? String(digits.suffix(9)) : nil
    }
}
