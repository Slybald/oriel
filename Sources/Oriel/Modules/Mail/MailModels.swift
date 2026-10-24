import Foundation

// Types, scripts AppleScript et décodage de leurs réponses pour l'onglet Mail (purs, testés sans Mail).

enum MailState: Equatable {
    /// Pas encore regardé.
    case unknown
    /// Mail est fermé. Oriel ne le lance jamais : le script commence par vérifier qu'il tourne.
    case notRunning
    /// L'Automatisation vers Mail n'a jamais été demandée : un clic sur « Autoriser » fait poser la question.
    case needsPermission
    case denied
    /// Mail tourne mais n'a aucun compte (la boîte de réception est vide faute de compte, pas d'e-mail).
    case noAccount
    case ready
    /// Mail n'a pas répondu à temps, ou sa réponse n'est pas lisible.
    case failed
}

struct MailMessage: Identifiable, Equatable {
    /// En-tête Message-ID (RFC 822), sans chevrons.
    var id: String
    /// Nom affiché de l'expéditeur, à défaut son adresse.
    var sender: String
    var subject: String
    var date: Date
    /// Début du texte sur une ligne (vide si Mail n'a rien rendu : message d'images, corps pas encore téléchargé).
    var snippet = ""
    var isUnread = false

    /// `message://` est le lien que Mail comprend pour ouvrir un message ; il ne demande aucune autorisation.
    var openURL: URL? {
        guard !id.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return "<\(id)>".addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: "message://\($0)") }
    }
}

struct MailReading: Equatable {
    var unread: Int
    var accounts: Int
    var messages: [MailMessage]
}

enum MailAnswer: Equatable {
    case notRunning
    case reading(MailReading)
}

/// Où en est la réponse en cours. Rien ne part sans un appel explicite à `sendReply` (clic sur « Envoyer » ou Entrée).
enum MailReplyState: Equatable {
    case idle
    case sending
    case sent
    case failed(MailReplyFailure)
}

enum MailReplyFailure: Equatable {
    /// Mail s'est fermé : on propose de l'ouvrir, on ne le lance pas.
    case notRunning
    case notAuthorized
    /// Mail n'a pas confirmé : la réponse est peut-être partie, à vérifier avant de réessayer.
    case timedOut
    /// Le message n'est plus parmi les derniers reçus.
    case notFound
    case failed
}

enum MailScript {
    static let bundleIdentifier = "com.apple.mail"
    static let appURL = URL(fileURLWithPath: "/System/Applications/Mail.app")
    static let recordSeparator: Character = "\u{1E}"
    static let unitSeparator: Character = "\u{1F}"
    /// Le script de lecture examine les `candidateFactor × n` premiers messages de la boîte de réception et garde
    /// les `n` plus récents ; le script de réponse cherche le message parmi les `replyScanDepth` premiers.
    static let candidateFactor = 4
    static let replyScanDepth = 40
    /// Caractères de corps gardés par message (le reste ne quitte jamais Mail) puis dans la ligne affichée.
    static let bodyCharacters = 600
    static let snippetCharacters = 280

    /// Argument 1 : combien de derniers messages reçus détailler (0 = seulement les compteurs, instantané).
    ///
    /// - `application id … is not running` est évalué par AppleScript lui-même, hors de tout `tell` : Mail n'est
    ///   jamais lancé et aucune autorisation n'est demandée (mesuré : Mail fermé → « false », Mail toujours fermé).
    /// - Mesuré sur une vraie boîte (1 compte, 5 316 messages) : `messages of inbox whose …` dépasse 30 s (un filtre
    ///   par date ou par statut de lecture, 40 s sans réponse), alors que `messages 1 thru N of inbox` répond en
    ///   5 s à froid, 1,4 s ensuite. Le script prend donc les premiers messages par rang (Mail les range du plus
    ///   récent au plus ancien, vérifié sur 40 messages) et retrie par date reçue, sans supposer cet ordre exact.
    /// - Séparateurs ASCII 30 / 31 : un objet de message ne les contient pas. L'âge est en secondes depuis la
    ///   réception (une date en texte dépendrait de la langue du Mac). `my safeText(…)` : un champ vide vaut
    ///   « missing value » dans Mail et ne se concatène pas.
    /// - Réponse : `NOTRUNNING`, ou `OK␟non-lus␟comptes` puis un enregistrement
    ///   `␞expéditeur␟objet␟âge␟Message-ID␟non-lu(0/1)␟début du texte` par message.
    static let source = """
    on safeText(v)
        if v is missing value then return ""
        return v as text
    end safeText

    on run argv
        set maxItems to (item 1 of argv) as integer
        if application id "com.apple.mail" is not running then return "NOTRUNNING"
        set rs to character id 30
        set us to character id 31
        set nowDate to current date
        set out to ""
        tell application id "com.apple.mail"
            with timeout of 20 seconds
                set unreadTotal to unread count of inbox
                set out to "OK" & us & unreadTotal & us & (count of accounts)
                if maxItems > 0 then
                    set candidates to {}
                    try
                        set candidates to (messages 1 thru (maxItems * \(candidateFactor)) of inbox)
                    on error errText number errNum
                        if errNum is -1712 then error errText number errNum
                        set candidates to (messages of inbox)
                    end try
                    set dts to {}
                    repeat with m in candidates
                        set end of dts to (date received of m)
                    end repeat
                    set oldest to nowDate - 36500 * days
                    set picks to {}
                    repeat maxItems times
                        set best to 0
                        set bestDate to oldest
                        repeat with i from 1 to count of dts
                            set d to item i of dts
                            if d > bestDate then
                                set bestDate to d
                                set best to i
                            end if
                        end repeat
                        if best is 0 then exit repeat
                        set end of picks to best
                        set item best of dts to oldest
                    end repeat
                    repeat with pick in picks
                        set m to item (contents of pick) of candidates
                        set age to (nowDate - (date received of m)) as integer
                        set unreadFlag to "0"
                        if (read status of m) is false then set unreadFlag to "1"
                        set bodyText to ""
                        try
                            set bodyText to my safeText(content of m)
                            if (length of bodyText) > \(bodyCharacters) then set bodyText to text 1 thru \(bodyCharacters) of bodyText
                        end try
                        set out to out & rs & my safeText(sender of m) & us & my safeText(subject of m) & us & age & us & my safeText(message id of m) & us & unreadFlag & us & bodyText
                    end repeat
                end if
            end timeout
        end tell
        return out
    end run
    """

    /// Arguments : Message-ID (sans chevrons), texte de la réponse, `send` ou `draft`. Le texte passe en argument,
    /// jamais dans le script.
    ///
    /// - `reply` répond à l'expéditeur seul (objet « Re: … », destinataire et citation faits par Mail). La réponse
    ///   est invisible pour `send` (rien ne s'affiche) ; pour `draft`, la fenêtre de réponse s'ouvre avec le texte
    ///   déjà tapé et Mail passe au premier plan : l'utilisateur finit dans Mail.
    /// - Le texte tapé est placé avant la citation que Mail a mise dans `content`. `send` rend `false` si l'envoi
    ///   échoue ; seul `false` compte (une valeur vide ne prouve pas l'échec, et renvoyer une réponse partie
    ///   ferait un doublon).
    /// - Si une étape échoue après la création de la réponse, on la supprime avant de relancer l'erreur : pas de
    ///   message sortant orphelin.
    /// - Le script se compile. Il n'a JAMAIS été exécuté sur une vraie boîte (une exécution crée une réponse, donc
    ///   peut déposer un brouillon chez l'utilisateur) : à essayer à la main avant une version.
    static let replySource = """
    on run argv
        set wantedID to item 1 of argv
        set replyText to item 2 of argv
        set sendNow to ((item 3 of argv) is "send")
        if application id "com.apple.mail" is not running then return "NOTRUNNING"
        tell application id "com.apple.mail"
            with timeout of 45 seconds
                set recent to {}
                try
                    set recent to (messages 1 thru \(replyScanDepth) of inbox)
                on error errText number errNum
                    if errNum is -1712 then error errText number errNum
                    set recent to (messages of inbox)
                end try
                set theMessage to missing value
                repeat with m in recent
                    set rawID to message id of m
                    if rawID is wantedID or rawID is ("<" & wantedID & ">") then
                        set theMessage to contents of m
                        exit repeat
                    end if
                end repeat
                if theMessage is missing value then return "NOTFOUND"
                set theReply to reply theMessage opening window (not sendNow)
                try
                    try
                        set quoted to content of theReply
                    on error
                        set quoted to ""
                    end try
                    if replyText is not "" then
                        if quoted is "" then
                            set content of theReply to replyText
                        else
                            set content of theReply to replyText & return & return & quoted
                        end if
                    end if
                    if sendNow then
                        set didSend to send theReply
                        if didSend is false then return "FAILED"
                    else
                        activate
                    end if
                on error errText number errNum
                    try
                        delete theReply
                    end try
                    error errText number errNum
                end try
            end timeout
        end tell
        return "OK"
    end run
    """

    /// nil : réponse illisible.
    static func parse(_ output: String, now: Date) -> MailAnswer? {
        if output == "NOTRUNNING" { return .notRunning }
        let records = output.split(separator: recordSeparator, omittingEmptySubsequences: false)
        guard let head = records.first?.split(separator: unitSeparator, omittingEmptySubsequences: false),
              head.count == 3, head[0] == "OK", let unread = Int(head[1]), let accounts = Int(head[2]) else { return nil }
        var seen = Set<String>()
        let messages: [MailMessage] = records.dropFirst().compactMap { record in
            let fields = record.split(separator: unitSeparator, maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, let age = Double(fields[2]) else { return nil }
            let id = messageID(fields[3])
            // Un même message peut être dans deux dossiers de la boîte de réception (étiquettes de Gmail).
            guard id.isEmpty || seen.insert(id).inserted else { return nil }
            return MailMessage(id: id, sender: displayName(of: fields[0]), subject: oneLine(fields[1]),
                               date: now.addingTimeInterval(-max(0, age)), snippet: snippet(from: fields[5]),
                               isUnread: fields[4] == "1")
        }
        return .reading(MailReading(unread: unread, accounts: accounts, messages: messages.sorted { $0.date > $1.date }))
    }

    /// Issue d'un envoi ou d'une ouverture de réponse : nil = réussi.
    static func replyFailure(_ result: Result<String, AppleScriptFailure>) -> MailReplyFailure? {
        switch result {
        case .success(let output):
            switch output {
            case "OK": return nil
            case "NOTRUNNING": return .notRunning
            case "NOTFOUND": return .notFound
            default: return .failed
            }
        case .failure(.notAuthorized): return .notAuthorized
        case .failure(.timedOut): return .timedOut
        case .failure: return .failed
        }
    }

    /// « Prénom Nom <a@b.c> » → « Prénom Nom » ; une adresse seule reste telle quelle.
    static func displayName(of sender: String) -> String {
        let text = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix(">"), let open = text.lastIndex(of: "<") else { return text }
        let name = text[..<open].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        return name.isEmpty ? String(text[text.index(after: open)..<text.index(before: text.endIndex)]) : name
    }

    /// Mail rend l'identifiant avec ou sans chevrons selon les versions : on ne garde que le contenu.
    static func messageID(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>")))
    }

    /// Début du corps : une ligne, sans espaces en trop ni caractère d'objet (U+FFFC pour une image insérée).
    static func snippet(from body: String) -> String {
        let text = oneLine(body.replacingOccurrences(of: "\u{FFFC}", with: " "))
        guard text.count > snippetCharacters else { return text }
        return String(text.prefix(snippetCharacters))
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
