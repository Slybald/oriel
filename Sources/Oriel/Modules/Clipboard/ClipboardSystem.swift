import AppKit
import Foundation

// Le système (presse-papiers, app au premier plan) derrière deux protocoles : les tests y mettent des doubles.

protocol ClipboardPasteboard: AnyObject {
    /// Change à chaque copie : c'est la seule chose lue à chaque tic.
    var changeCount: Int { get }
    /// Types déclarés, sans lire aucun contenu : la confidentialité se décide dessus.
    var types: [String] { get }
    /// L'accès que macOS accorde à l'app (toujours `.allowed` avant macOS 15.4 et hors presse-papiers général).
    var access: ClipboardAccess { get }
    /// Contenu utilisable (fichiers, couleur, texte ou lien, image) et, pour un texte, sa mise en forme.
    func read() -> ClipboardRead
    /// Remplace le presse-papiers (par le texte brut du contenu si `plainText`, sinon avec la mise en forme `rich`
    /// d'un texte) ; rend le nouveau `changeCount`.
    func write(_ content: ClipboardContent, rich: ClipboardRichText?, plainText: Bool) -> Int
}

protocol ClipboardFrontApps: AnyObject {
    func start()
    func stop()
    /// Apps passées au premier plan depuis le dernier appel, la plus récente en dernier ; repart de l'app actuelle.
    /// Une copie suivie d'un changement d'app en moins d'une seconde est donc attribuée sans trou : l'exclusion
    /// vaut pour toutes les apps de l'intervalle.
    func drain() -> [ClipboardSource]
}

// MARK: - Presse-papiers réel

final class SystemPasteboard: ClipboardPasteboard {
    /// Le presse-papiers général ; les tests en donnent un privé, pour ne jamais toucher à celui de l'utilisateur.
    private let pasteboard: NSPasteboard
    private static let jpeg = NSPasteboard.PasteboardType("public.jpeg")

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    var types: [String] { pasteboard.types?.map(\.rawValue) ?? [] }

    var access: ClipboardAccess {
        guard #available(macOS 15.4, *) else { return .allowed }
        switch pasteboard.accessBehavior {
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        default: return .ask
        }
    }

    func read() -> ClipboardRead {
        let declared = Set(pasteboard.types ?? [])
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL]
        if let fileURLs, !fileURLs.isEmpty { return ClipboardRead(content: .files(fileURLs)) }

        // Les sélecteurs de couleur déclarent ce type ; un texte copié n'en a jamais.
        if declared.contains(.color), let color = (pasteboard.readObjects(forClasses: [NSColor.self]) as? [NSColor])?.first,
           let hex = Self.hex(of: color) {
            return ClipboardRead(content: .color(hex))
        }

        let text = pasteboard.string(forType: .string)
        if text == nil || text?.contains(where: { !$0.isWhitespace }) != true {
            for type in [NSPasteboard.PasteboardType.png, .tiff, Self.jpeg] where declared.contains(type) {
                guard let data = pasteboard.data(forType: type) else { continue }
                // Les formats suivants (TIFF non compressé) seraient encore plus lourds : on s'arrête là.
                if data.count > ClipboardImage.maxBytes { return ClipboardRead(imageTooLarge: true) }
                if let image = ClipboardImage.make(data: data, type: type.rawValue) {
                    return ClipboardRead(content: .image(image))
                }
            }
            if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                return ClipboardRead(content: .url(url))
            }
        }
        guard let text else { return ClipboardRead() }
        let content = ClipboardContent.classify(text: text)
        guard case .text = content else { return ClipboardRead(content: content) }
        let rich = ClipboardRichText.make(rtf: pasteboard.data(forType: .rtf), html: pasteboard.data(forType: .html))
        return ClipboardRead(content: content, rich: rich)
    }

    func write(_ content: ClipboardContent, rich: ClipboardRichText?, plainText: Bool) -> Int {
        pasteboard.clearContents()
        if plainText, let text = content.plainText {
            pasteboard.setString(text, forType: .string)
            return pasteboard.changeCount
        }
        switch content {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
            if let rtf = rich?.rtf { pasteboard.setData(rtf, forType: .rtf) }
            if let html = rich?.html { pasteboard.setData(html, forType: .html) }
        case .url(let url):
            pasteboard.writeObjects([url as NSURL])
            pasteboard.setString(url.absoluteString, forType: .string)
        case .image(let image):
            pasteboard.setData(image.data, forType: NSPasteboard.PasteboardType(image.type))
        case .files(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        case .color(let hex):
            if let color = Self.color(hex: hex) { pasteboard.writeObjects([color]) }
            pasteboard.setString("#" + hex, forType: .string)
        }
        return pasteboard.changeCount
    }

    /// « RRGGBB » (sRGB).
    static func hex(of color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    static func color(hex: String) -> NSColor? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - App au premier plan

/// Suit les changements d'app au premier plan par notification (aucun scrutin).
final class WorkspaceFrontApps: ClipboardFrontApps {
    private var observer: NSObjectProtocol?
    private var current: ClipboardSource?
    private var recent: [ClipboardSource] = []

    deinit { stop() }

    func start() {
        guard observer == nil else { return }
        current = Self.source(NSWorkspace.shared.frontmostApplication)
        recent = current.map { [$0] } ?? []
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let source = Self.source(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            else { return }
            current = source
            // Borné : une session de Cmd-Tab sans copie ne fait pas grossir la liste.
            recent = Array((recent + [source]).suffix(8))
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        current = nil
        recent = []
    }

    func drain() -> [ClipboardSource] {
        let apps = recent
        recent = current.map { [$0] } ?? []
        return apps
    }

    private static func source(_ app: NSRunningApplication?) -> ClipboardSource? {
        guard let id = app?.bundleIdentifier else { return nil }
        return ClipboardSource(bundleID: id, name: app?.localizedName ?? id)
    }
}

// MARK: - Icônes des apps

/// Icône (16 pt) de l'app d'un bundle identifier, gardée en cache : une entrée par app vue, quelques Ko.
enum ClipboardAppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        cache[bundleID] = icon
        return icon
    }

    /// Nom de l'app pour les réglages : celui de la liste par défaut, sinon celui de l'app installée, sinon l'identifiant.
    static func name(for bundleID: String) -> String {
        if let known = ClipboardPrivacy.defaultExcludedApps.first(where: {
            $0.id.caseInsensitiveCompare(bundleID) == .orderedSame
        }) { return known.name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }
}
