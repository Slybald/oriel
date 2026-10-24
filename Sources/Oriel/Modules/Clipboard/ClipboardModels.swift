import AppKit
import CryptoKit
import Foundation
import ImageIO

// Données de l'historique du presse-papiers : contenu, élément, historique (valeurs pures, sans AppKit système).

/// App au premier plan au moment de la copie. L'icône est retrouvée à l'affichage, jamais stockée.
struct ClipboardSource: Codable, Equatable {
    var bundleID: String
    var name: String
}

/// Image gardée : données d'origine (jamais plus de 5 Mo) et vignette réduite pour la liste.
///
/// Choix : une image de plus de 5 Mo est ignorée, pas gardée en vignette. Une vignette de 96 pt recopiée à sa place
/// donnerait une image minuscule, sans que rien le dise ; mieux vaut un historique sans elle.
struct ClipboardImage {
    static let maxBytes = 5 * 1_048_576
    /// 96 pt en @2x.
    static let thumbnailPixels = 192

    let data: Data
    /// Type du presse-papiers des données (`public.png`, `public.tiff`, `public.jpeg`).
    let type: String
    let thumbnail: NSImage
    let pixelSize: CGSize
    /// Empreinte des données : deux copies de la même image n'ont qu'une ligne.
    let digest: String

    /// nil : vide, trop lourde ou illisible. La vignette est décodée par ImageIO sans ouvrir l'image entière.
    static func make(data: Data, type: String) -> ClipboardImage? {
        guard !data.isEmpty, data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? Double(cgImage.width)
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? Double(cgImage.height)
        let thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
        let digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        return ClipboardImage(data: data, type: type, thumbnail: thumbnail,
                              pixelSize: CGSize(width: width, height: height), digest: digest)
    }
}

/// Mise en forme d'un texte copié (RTF, HTML), gardée en mémoire seulement pour que « Copier » la restitue ;
/// « Copier en texte brut » l'écarte. Jamais écrite sur disque. Au plus 100 Ko par élément : au-delà, le texte
/// est gardé sans sa mise en forme.
struct ClipboardRichText: Equatable {
    static let maxBytes = 100 * 1024

    var rtf: Data?
    var html: Data?

    /// nil : ni RTF ni HTML dans la limite.
    static func make(rtf: Data?, html: Data?) -> ClipboardRichText? {
        var rich = ClipboardRichText()
        if let rtf, !rtf.isEmpty, rtf.count <= maxBytes { rich.rtf = rtf }
        if let html, !html.isEmpty, html.count + (rich.rtf?.count ?? 0) <= maxBytes { rich.html = html }
        return rich.rtf == nil && rich.html == nil ? nil : rich
    }
}

/// Ce que le presse-papiers contient à un tic.
struct ClipboardRead {
    var content: ClipboardContent?
    /// Mise en forme d'un contenu `.text`.
    var rich: ClipboardRichText?
    /// Une image était là mais dépasse 5 Mo : elle est ignorée, l'utilisateur doit le savoir.
    var imageTooLarge = false
}

/// Accès programmatique au presse-papiers général (macOS 15.4 et après : Réglages Système › Confidentialité et
/// sécurité › Coller depuis d'autres apps).
enum ClipboardAccess: Equatable {
    case allowed
    /// macOS demande l'accord à la lecture (réglage par défaut).
    case ask
    /// Refusé : tout ce qui est lu est vide.
    case denied
}

enum ClipboardContent {
    case text(String)
    case url(URL)
    case image(ClipboardImage)
    case files([URL])
    /// « RRGGBB » (sRGB).
    case color(String)

    /// Texte tel que le presse-papiers le reçoit ; une chaîne qui est un lien web devient un lien.
    static func classify(text: String) -> ClipboardContent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
           let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
           scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty,
           let url = components.url {
            return .url(url)
        }
        return .text(text)
    }

    /// Identité du contenu : deux copies identiques ne font qu'une ligne.
    var key: String {
        switch self {
        case .text(let text): return "t:" + text
        case .url(let url): return "u:" + url.absoluteString
        case .image(let image): return "i:" + image.digest
        case .files(let urls): return "f:" + urls.map(\.path).joined(separator: "\n")
        case .color(let hex): return "c:" + hex
        }
    }

    /// Ce qu'on écrit pour « copier en texte brut » ; nil pour une image.
    var plainText: String? {
        switch self {
        case .text(let text): return text
        case .url(let url): return url.absoluteString
        case .image: return nil
        case .files(let urls): return urls.map(\.path).joined(separator: "\n")
        case .color(let hex): return "#" + hex
        }
    }

    /// Texte cherché par le champ de recherche (avant normalisation).
    fileprivate var searchable: String {
        switch self {
        case .text(let text): return text
        case .url(let url): return url.absoluteString
        case .image(let image): return "image \(Int(image.pixelSize.width)) \(Int(image.pixelSize.height))"
        case .files(let urls): return urls.map(\.lastPathComponent).joined(separator: " ")
        case .color(let hex): return hex
        }
    }

    var imageBytes: Int {
        if case .image(let image) = self { return image.data.count }
        return 0
    }
}

struct ClipboardItem: Identifiable {
    /// Au-delà, le texte est coupé (et marqué).
    static let maxTextCharacters = 20_000

    let id: UUID
    let content: ClipboardContent
    var date: Date
    var pinned: Bool
    var source: ClipboardSource?
    /// Mise en forme du texte (en mémoire seulement).
    var rich: ClipboardRichText?
    /// Le texte a été coupé à `maxTextCharacters` : le recopier redonne la version coupée.
    let truncated: Bool
    let key: String
    /// Contenu et app source, en minuscules sans accents : la recherche est une simple inclusion.
    let searchText: String

    /// nil : rien à garder (texte vide, image trop lourde). `truncated` : le texte avait déjà été coupé
    /// (élément relu depuis le disque).
    init?(_ content: ClipboardContent, date: Date, source: ClipboardSource? = nil, pinned: Bool = false,
          id: UUID = UUID(), rich: ClipboardRichText? = nil, truncated wasTruncated: Bool = false) {
        var content = content
        var truncated = wasTruncated
        var rich = rich
        // Un lien démesuré est un texte comme un autre : il est coupé.
        if case .url(let url) = content, url.absoluteString.count > Self.maxTextCharacters {
            content = .text(url.absoluteString)
        }
        switch content {
        case .text(let text):
            guard text.contains(where: { !$0.isWhitespace }) else { return nil }
            if let end = text.index(text.startIndex, offsetBy: Self.maxTextCharacters, limitedBy: text.endIndex),
               end != text.endIndex {
                content = .text(String(text[..<end]))
                truncated = true
            }
            // La mise en forme d'un texte coupé ne correspondrait plus au texte.
            if truncated { rich = nil }
        case .image(let image):
            guard image.data.count <= ClipboardImage.maxBytes else { return nil }
            rich = nil
        case .files(let urls):
            guard !urls.isEmpty else { return nil }
            rich = nil
        default:
            rich = nil
        }
        self.id = id
        self.content = content
        self.date = date
        self.pinned = pinned
        self.source = source
        self.rich = rich
        self.truncated = truncated
        key = content.key
        searchText = Self.fold(content.searchable + " " + (source?.name ?? ""))
    }

    /// « Copier en texte brut » n'a de sens que s'il change quelque chose : pour un texte, seulement quand il a
    /// une mise en forme à écarter.
    var offersPlainCopy: Bool {
        if case .text = content { return rich != nil }
        return content.plainText != nil
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

// MARK: - Historique

/// Éléments du plus récent au plus ancien. Le plafond ne compte que les éléments non épinglés : un élément
/// épinglé n'est jamais évincé. Les images partagent un budget de mémoire (les plus anciennes partent d'abord).
struct ClipboardHistory {
    static let imageBudget = 40 * 1_048_576

    private(set) var items: [ClipboardItem] = []

    /// Épinglés d'abord, puis le reste, chacun du plus récent au plus ancien.
    var ordered: [ClipboardItem] { items.filter(\.pinned) + items.filter { !$0.pinned } }

    /// Un contenu déjà présent remonte en tête (date et source mises à jour, épingle gardée) au lieu d'un doublon.
    mutating func add(_ item: ClipboardItem, limit: Int) {
        if let index = items.firstIndex(where: { $0.key == item.key }) {
            var existing = items.remove(at: index)
            existing.date = item.date
            existing.rich = item.rich
            if item.source != nil { existing.source = item.source }
            items.insert(existing, at: 0)
        } else {
            items.insert(item, at: 0)
        }
        trim(limit: limit)
    }

    /// Éléments d'une session précédente : ceux dont le contenu est déjà là sont ignorés ; le tout est remis par date.
    mutating func merge(_ older: [ClipboardItem], limit: Int) {
        let known = Set(items.map(\.key))
        items += older.filter { !known.contains($0.key) }
        items.sort { $0.date > $1.date }
        trim(limit: limit)
    }

    mutating func touch(_ id: UUID, at date: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.date = date
        items.insert(item, at: 0)
    }

    /// Désépingler peut faire dépasser le plafond. L'élément qu'on vient de choisir de garder ne doit pas être le
    /// premier à partir : désépinglé, il remonte en tête (à `date`) et c'est le plus ancien des autres qui est évincé.
    mutating func togglePin(_ id: UUID, limit: Int, at date: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        if !items[index].pinned { touch(id, at: date) }
        trim(limit: limit)
    }

    mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    mutating func clear() { items = [] }

    /// Retire les non épinglés au-delà de `limit`, puis les images les plus anciennes au-delà du budget.
    mutating func trim(limit: Int) {
        var kept = 0
        items = items.filter { item in
            if item.pinned { return true }
            kept += 1
            return kept <= limit
        }
        var total = items.reduce(0) { $0 + $1.content.imageBytes }
        var index = items.count - 1
        while total > Self.imageBudget, index >= 0 {
            let bytes = items[index].content.imageBytes
            if !items[index].pinned, bytes > 0 {
                total -= bytes
                items.remove(at: index)
            }
            index -= 1
        }
    }

    /// Filtre instantané : tous les mots de la recherche doivent figurer (casse et accents ignorés).
    static func filter(_ items: [ClipboardItem], query: String) -> [ClipboardItem] {
        let words = ClipboardItem.fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return items }
        return items.filter { item in words.allSatisfy { item.searchText.contains($0) } }
    }
}

// MARK: - Confidentialité

enum ClipboardPrivacy {
    /// Jamais enregistrés : éléments déclarés confidentiels, temporaires ou générés par un gestionnaire de mots de
    /// passe (https://nspasteboard.org et les types propres à quelques apps). En minuscules.
    static let ignoredTypes: Set<String> = [
        "org.nspasteboard.concealedtype",
        "org.nspasteboard.transienttype",
        "org.nspasteboard.autogeneratedtype",
        "com.agilebits.onepassword",
        "de.petermaurer.transientpasteboardtype",
        "com.typeit4me.clipping",
        "pasteboard generator type",
    ]

    static func hasIgnoredType(_ types: [String]) -> Bool {
        types.contains { ignoredTypes.contains($0.lowercased()) }
    }

    /// Apps dont les copies sont ignorées tant que l'utilisateur n'a rien changé.
    static var defaultExcludedApps: [(id: String, name: String)] {
        [
            ("com.apple.keychainaccess", L("Trousseaux d'accès", table: "Clipboard")),
            ("com.apple.Passwords", L("Mots de passe", table: "Clipboard")),
            ("com.1password.1password", "1Password"),
            ("com.agilebits.onepassword7", "1Password 7"),
            ("com.bitwarden.desktop", "Bitwarden"),
            ("com.dashlane.dashlanephonefinal", "Dashlane"),
            ("com.dashlane.Dashlane", "Dashlane"),
            ("org.keepassxc.keepassxc", "KeePassXC"),
        ]
    }

    static func isExcluded(_ source: ClipboardSource, in excluded: [String]) -> Bool {
        excluded.contains { $0.caseInsensitiveCompare(source.bundleID) == .orderedSame }
    }
}
