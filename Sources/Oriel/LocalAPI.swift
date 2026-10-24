import AppKit
import Combine
import Foundation

/// API locale (docs/API.md) : les programmes et scripts de l'utilisateur posent leurs propres intercalaires dans la
/// notch repliée, sans aucun code chargé dans l'app. Routes `/api/v1/ears` du serveur local (`HookServer`, qui a
/// déjà refusé tout `Host` autre que `127.0.0.1:<port>` et tout `Origin` : aucune page web ne l'atteint).
///
/// - Désactivée par défaut (Réglages › Scripts) : la notch est pour tout le monde, seuls ceux qui écrivent des
///   scripts en ont l'usage. Désactivée, ses routes répondent 403 et aucun jeton n'est sur disque.
/// - Jeton à elle (`api-token`, 0600, `Authorization: Bearer …`), distinct de celui des hooks : un script qui l'a
///   n'atteint ni `/hook`, ni `/permission`, ni `/state`. Nouveau à chaque lancement et à chaque activation.
/// - Schéma strict, tailles bornées, symboles et couleurs pris dans des listes, `maxItems` intercalaires au plus,
///   durée de vie bornée, 10 requêtes d'affilée puis 2 par seconde.
/// - Rien ne s'exécute : la seule action est d'ouvrir une app installée, désignée par son identifiant, sur un clic.
/// - Rien n'imite Claude ou Codex : jamais d'alerte (l'intercalaire ne reste pas déployé de lui-même), priorité
///   sous la leur, ni « Autoriser » ni « Refuser », et la carte dit toujours de quel programme elle vient.
final class LocalAPI: ObservableObject {
    static let shared = LocalAPI()

    static let path = "/api/v1/ears"
    /// Intercalaires externes en même temps ; au-delà, le plus ancien laisse sa place.
    static let maxItems = 3
    /// Durée de vie par défaut et maximale, en secondes.
    static let defaultTTL = 60
    static let maxTTL = 3600
    static let maxBody = 4096
    /// Au-dessus du lecteur (1), sous le minuteur (5), Codex (6, 9) et Claude (100, 1000).
    static let earPriority = 2
    /// Préfixe des identifiants d'intercalaire : jamais celui d'un module.
    static let earPrefix = "api."
    static let headerName = "Authorization"
    /// Lu par la commande `notch` : `$HOME/Library/Application Support/Oriel/api-token`.
    static var standardFile: URL { SharedFiles.notchDirectory.appendingPathComponent("api-token") }
    private static let enabledKey = "api.enabled"

    /// Réglages › Scripts. Coupée : intercalaires retirés, jeton effacé du disque et oublié.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            token = HookAccess.randomToken()
            if !isEnabled { clear() }
            writeToken()
        }
    }
    /// Du plus ancien au plus récent.
    @Published private(set) var items: [ExternalEar] = []
    /// Derniers programmes qui ont posé un intercalaire, du plus récent au plus ancien (en mémoire seulement).
    @Published private(set) var clients: [APIClient] = []

    private(set) var token = HookAccess.randomToken()
    /// nil : rien sur disque (tests).
    let tokenFile: URL?
    private let defaults: UserDefaults
    /// Nom affiché de l'app installée qui a cet identifiant ; nil si aucune.
    private let appName: (String) -> String?
    private var limiter: RateLimiter
    private var expiryWork: DispatchWorkItem?
    /// Le serveur tient le port : le jeton peut être écrit (une seconde instance n'écrase pas celui de la première).
    private var serverReady = false

    init(defaults: UserDefaults = .standard, tokenFile: URL? = LocalAPI.standardFile,
         appName: @escaping (String) -> String? = LocalAPI.installedAppName,
         limiter: RateLimiter = RateLimiter(capacity: 10, perSecond: 2)) {
        self.defaults = defaults
        self.tokenFile = tokenFile
        self.appName = appName
        self.limiter = limiter
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// Appelé par `HookServer` une fois le port à lui.
    func serverDidStart() {
        serverReady = true
        writeToken()
    }

    /// Le fichier n'existe que tant que l'API est activée.
    private func writeToken() {
        guard let tokenFile, serverReady else { return }
        guard isEnabled else {
            try? FileManager.default.removeItem(at: tokenFile)
            return
        }
        do {
            try FileManager.default.createDirectory(at: tokenFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try HookAccess.write("\(Self.headerName): Bearer \(token)\n", to: tokenFile)
        } catch {
            NSLog("Oriel : jeton de l'API locale impossible à écrire (%@).", String(describing: error))
        }
    }

    // MARK: - Requêtes

    struct Response: Equatable {
        let status: Int
        let body: Data

        static let noContent = Response(status: 204, body: Data())

        init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }

        init(status: Int, json: [String: String]) {
            let body = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
            self.init(status: status, body: body ?? Data())
        }

        static func error(_ status: Int, _ code: String, _ message: String) -> Response {
            Response(status: status, json: ["error": code, "message": message])
        }

        /// Fixe : `HTTPURLResponse.localizedString` suivrait la langue du Mac.
        var reason: String {
            switch status {
            case 200: return "OK"
            case 204: return "No Content"
            case 400: return "Bad Request"
            case 401: return "Unauthorized"
            case 403: return "Forbidden"
            case 413: return "Payload Too Large"
            case 415: return "Unsupported Media Type"
            case 429: return "Too Many Requests"
            default: return "Not Found"
            }
        }
    }

    /// Une requête `/api/…` dont `Host` et `Origin` sont déjà vérifiés. Main thread.
    func handle(_ request: HTTPRequest, now: Date = Date()) -> Response {
        guard isEnabled else {
            return .error(403, "api_disabled", "The local API is off: turn it on in Oriel, Settings, Scripts.")
        }
        guard HookAccess.constantTimeEquals(request.headers[Self.headerName.lowercased()], "Bearer \(token)") else {
            return .error(401, "unauthorized", "Missing or wrong token (Authorization header, see docs/API.md).")
        }
        guard limiter.allow(now: now) else { return .error(429, "rate_limited", "Too many requests, slow down.") }

        switch (request.method, request.path) {
        case ("POST", Self.path):
            guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
                return .error(415, "unsupported_media_type", "Content-Type must be application/json.")
            }
            guard request.body.count <= Self.maxBody else {
                return .error(413, "too_large", "The body is limited to \(Self.maxBody) bytes.")
            }
            do {
                let ear = try ExternalEar(json: request.body, now: now, appName: appName)
                show(ear, now: now)
                return Response(status: 200, json: ["id": ear.id])
            } catch let error as ExternalEar.Invalid {
                return .error(400, "invalid", error.message)
            } catch {
                return .error(400, "invalid", "Invalid request.")
            }
        case ("DELETE", Self.path):
            clear()
            return .noContent
        case ("DELETE", let path) where path.hasPrefix(Self.path + "/"):
            return remove(String(path.dropFirst(Self.path.count + 1))) ? .noContent
                : .error(404, "not_found", "No ear with this id.")
        default:
            return .error(404, "not_found", "Unknown route (see docs/API.md).")
        }
    }

    // MARK: - Intercalaires

    /// Même identifiant : remplacé en place. Sinon ajouté, quitte à retirer le plus ancien.
    func show(_ ear: ExternalEar, now: Date = Date()) {
        var next = items.filter { $0.id != ear.id }
        if next.count >= Self.maxItems { next.removeFirst(next.count - Self.maxItems + 1) }
        next.append(ear)
        items = next
        record(ear.client, now: now)
        scheduleExpiry(now: now)
    }

    @discardableResult
    func remove(_ id: String) -> Bool {
        guard items.contains(where: { $0.id == id }) else { return false }
        items.removeAll { $0.id == id }
        scheduleExpiry(now: Date())
        return true
    }

    func clear() {
        if !items.isEmpty { items = [] }
        expiryWork?.cancel()
        expiryWork = nil
    }

    /// Retire les intercalaires échus, puis attend le prochain : un seul réveil programmé, aucun timer périodique
    /// (CPU ≈ 0 % notch repliée).
    func expire(now: Date = Date()) {
        let alive = items.filter { $0.expires > now }
        if alive != items { items = alive }
        scheduleExpiry(now: now)
    }

    private func scheduleExpiry(now: Date) {
        expiryWork?.cancel()
        expiryWork = nil
        guard let next = items.map(\.expires).min() else { return }
        let work = DispatchWorkItem { [weak self] in self?.expire() }
        expiryWork = work
        // Horloge murale : l'échéance tient aussi après une veille.
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, next.timeIntervalSince(now)) + 0.05, execute: work)
    }

    private func record(_ client: String, now: Date) {
        let count = (clients.first { $0.name == client }?.count ?? 0) + 1
        clients = Array(([APIClient(name: client, lastSeen: now, count: count)] + clients.filter { $0.name != client })
            .prefix(5))
    }

    /// Bouton de la carte : ouvre l'app (sans document ni argument), retrouvée par son identifiant au moment du clic.
    func openApp(of ear: ExternalEar) {
        guard let bundleId = ear.app,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Intercalaires de la notch

    /// Le plus récent d'abord : à priorité égale, il passe le plus près de la notch.
    var earsEntries: [ModuleEarsEntry] {
        items.reversed().map { ear in
            ModuleEarsEntry(id: Self.earPrefix + ear.id,
                            ears: ModuleEars(symbol: ear.icon, text: ear.text, priority: Self.earPriority,
                                             accentHex: ear.accentHex))
        }
    }

    func item(earId: String) -> ExternalEar? {
        guard earId.hasPrefix(Self.earPrefix) else { return nil }
        let id = earId.dropFirst(Self.earPrefix.count)
        return items.first { $0.id == id }
    }

    var debugInfo: [String: Any] {
        ["enabled": isEnabled, "items": items.count, "clients": clients.map(\.name)]
    }

    static func installedAppName(_ bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
    }
}

/// Un programme qui a posé un intercalaire : le nom qu'il se donne (`client`), sans preuve, pour information.
struct APIClient: Equatable, Identifiable {
    let name: String
    let lastSeen: Date
    let count: Int
    var id: String { name }
}

/// Cadence : `capacity` requêtes d'affilée, puis `perSecond`.
struct RateLimiter {
    let capacity: Double
    let perSecond: Double
    private var tokens: Double
    private var last: Date?

    init(capacity: Double, perSecond: Double) {
        self.capacity = capacity
        self.perSecond = perSecond
        tokens = capacity
    }

    mutating func allow(now: Date) -> Bool {
        if let last { tokens = min(capacity, tokens + max(0, now.timeIntervalSince(last)) * perSecond) }
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

// MARK: - Schéma

/// Un intercalaire posé par un programme, validé champ par champ : tout champ inconnu, de mauvais type ou trop long
/// est refusé (400), rien n'est tronqué en silence.
struct ExternalEar: Equatable, Identifiable {
    struct Invalid: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    let id: String
    /// Titre de la carte déployée.
    let title: String
    /// Information très courte à côté de l'icône, notch repliée ; vide = icône seule.
    let text: String
    /// Quelques lignes dans la carte déployée.
    let detail: String
    let icon: String
    let color: String
    /// Identifiant de l'app que le bouton de la carte ouvre, et son nom affiché.
    let app: String?
    let appName: String?
    /// Nom que le programme se donne (« via … » sur la carte).
    let client: String
    let expires: Date

    var accentHex: String { Self.colors[color] ?? Self.colors[Self.defaultColor]! }

    static let fields: Set<String> = ["id", "title", "text", "detail", "icon", "color", "ttl", "app", "client"]
    static let maxTitle = 40
    static let maxText = 12
    static let maxDetail = 160
    static let defaultIcon = "bell.fill"
    static let defaultColor = "indigo"
    static let defaultClient = "script"

    /// Symboles permis : de quoi dire « fini », « en cours », « erreur » et les sujets courants. Aucun ne rappelle une
    /// demande d'autorisation (main levée, cadenas, clé, bouclier, point d'interrogation).
    static let icons: [String] = [
        "bell.fill", "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill", "info.circle.fill",
        "hourglass", "clock.fill", "timer", "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill",
        "terminal.fill", "server.rack", "externaldrive.fill", "cpu", "memorychip", "arrow.down.circle.fill",
        "arrow.up.circle.fill", "arrow.triangle.2.circlepath", "icloud.fill", "network", "globe", "envelope.fill",
        "bubble.left.fill", "star.fill", "heart.fill", "flag.fill", "bolt.fill", "flame.fill", "leaf.fill",
        "drop.fill", "sun.max.fill", "moon.fill", "cloud.fill", "music.note", "film.fill", "photo.fill", "doc.fill",
        "folder.fill", "tray.full.fill", "shippingbox.fill", "cart.fill", "chart.bar.fill",
        "chart.line.uptrend.xyaxis", "battery.100", "wifi", "house.fill", "person.fill", "calendar", "sparkles",
        "cup.and.saucer.fill", "gamecontroller.fill", "book.fill", "paintbrush.fill", "tag.fill",
    ]

    /// Couleurs permises, par nom. Aucune n'est celle de Codex (2DD4BF).
    static let colors: [String: String] = [
        "gray": "A1A1AA", "red": "F87171", "orange": "FB923C", "yellow": "FACC15", "green": "4ADE80",
        "mint": "34D399", "cyan": "22D3EE", "blue": "60A5FA", "indigo": "818CF8", "purple": "C084FC",
        "pink": "F472B6",
    ]
    /// Un programme ne se présente pas comme l'un d'eux (« via Codex ») : casse ignorée.
    static let reservedClients = ["claude", "codex", "anthropic", "openai"]

    init(id: String, title: String, text: String = "", detail: String = "", icon: String = ExternalEar.defaultIcon,
         color: String = ExternalEar.defaultColor, app: String? = nil, appName: String? = nil,
         client: String = ExternalEar.defaultClient, expires: Date) {
        self.id = id
        self.title = title
        self.text = text
        self.detail = detail
        self.icon = icon
        self.color = color
        self.app = app
        self.appName = appName
        self.client = client
        self.expires = expires
    }

    init(json body: Data, now: Date, appName: (String) -> String?) throws {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw Invalid("The body must be a JSON object.")
        }
        let unknown = Set(json.keys).subtracting(Self.fields)
        guard unknown.isEmpty else {
            throw Invalid("Unknown field: \(unknown.sorted()[0].prefix(32)). Allowed: \(Self.fields.sorted().joined(separator: ", ")).")
        }
        let id = try Self.token(json, "id", pattern: "^[A-Za-z0-9._-]{1,32}$",
                                rule: "1 to 32 letters, digits, dot, dash or underscore")
        let icon = try Self.token(json, "icon", pattern: "^[a-z0-9.]{1,40}$", rule: "a symbol from the list")
        let color = try Self.token(json, "color", pattern: "^[a-z]{1,10}$", rule: "a color name from the list")
        let client = try Self.token(json, "client", pattern: "^[A-Za-z0-9][A-Za-z0-9 ._-]{0,23}$",
                                    rule: "1 to 24 letters, digits, space, dot, dash or underscore")
        let app = try Self.token(json, "app", pattern: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$",
                                 rule: "a bundle identifier such as com.apple.Terminal", max: 155)
        if let client, Self.reservedClients.contains(where: { client.lowercased().contains($0) }) {
            throw Invalid("client: this name is reserved.")
        }
        if let icon, !Self.icons.contains(icon) { throw Invalid("icon: not in the list (see docs/API.md).") }
        if let color, Self.colors[color] == nil {
            throw Invalid("color: one of \(Self.colors.keys.sorted().joined(separator: ", ")).")
        }
        let name = try app.map { bundleId -> String in
            guard let name = appName(bundleId) else { throw Invalid("app: no installed app has this bundle identifier.") }
            return name
        }
        self.init(id: id ?? Self.newId(),
                  title: try Self.text(json, "title", max: Self.maxTitle, required: true),
                  text: try Self.text(json, "text", max: Self.maxText),
                  detail: try Self.text(json, "detail", max: Self.maxDetail),
                  icon: icon ?? Self.defaultIcon, color: color ?? Self.defaultColor, app: app, appName: name,
                  client: client ?? Self.defaultClient,
                  expires: now.addingTimeInterval(TimeInterval(try Self.ttl(json))))
    }

    static func newId() -> String { String(HookAccess.randomToken().prefix(8)) }

    /// Champ ASCII à motif fixe (identifiants, noms de la liste) ; nil s'il est absent.
    private static func token(_ json: [String: Any], _ key: String, pattern: String, rule: String,
                              max: Int = 64) throws -> String? {
        guard let value = json[key] else { return nil }
        guard let text = value as? String, text.count <= max,
              text.range(of: pattern, options: .regularExpression) != nil else {
            throw Invalid("\(key): \(rule).")
        }
        return text
    }

    /// Texte affiché : nettoyé (`clean`), puis borné en caractères ; jamais tronqué.
    private static func text(_ json: [String: Any], _ key: String, max: Int, required: Bool = false) throws -> String {
        guard let value = json[key] else {
            if required { throw Invalid("\(key): required.") }
            return ""
        }
        guard let raw = value as? String else { throw Invalid("\(key): must be a string.") }
        let text = clean(raw)
        // Les signes combinants empilés comptent pour un caractère : on borne aussi les scalaires.
        guard text.count <= max, text.unicodeScalars.count <= 4 * max else {
            throw Invalid("\(key): \(max) characters at most.")
        }
        if required, text.isEmpty { throw Invalid("\(key): required.") }
        return text
    }

    private static func ttl(_ json: [String: Any]) throws -> Int {
        guard let value = json["ttl"] else { return LocalAPI.defaultTTL }
        // Un booléen JSON arrive aussi en NSNumber : refusé.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let seconds = Int(exactly: number.doubleValue), (1...LocalAPI.maxTTL).contains(seconds) else {
            throw Invalid("ttl: whole number of seconds, 1 to \(LocalAPI.maxTTL).")
        }
        return seconds
    }

    /// Une seule ligne, rien qui trompe l'œil : blancs (retours à la ligne compris) ramenés à une espace, caractères
    /// de contrôle, de format (sens d'écriture forcé, largeur nulle), privés et non attribués retirés. Le liant des
    /// émojis composés (U+200D) reste.
    static func clean(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                scalars.append(" ")
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .surrogate, .unassigned:
                continue
            case .format where scalar.value != 0x200D:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }
}

// MARK: - Commande `notch`

/// La commande `notch` (hooks/notch, livrée dans l'app) : copiée dans ~/.local/bin seulement sur un clic dans les
/// réglages, jamais par-dessus un autre programme du même nom.
enum NotchCLI {
    /// Ligne que porte notre script : un fichier sans elle n'est pas à nous.
    static let marker = "# oriel-cli"
    /// Marqueur d'avant le renommage : une commande installée par la 2.1 ou avant est la nôtre, à mettre à jour.
    static let legacyMarker = "# claude-notch-cli"

    enum Status: Equatable {
        /// Pas de script dans l'app (`swift run`).
        case unavailable
        case notInstalled
        case installed
        /// Le nôtre, d'une autre version.
        case outdated
        /// Un autre programme porte ce nom : on n'y touche pas.
        case foreign
    }

    enum Failure: LocalizedError {
        case unavailable
        case foreign

        var errorDescription: String? {
            switch self {
            case .unavailable: return L("La commande n'est pas livrée avec cette copie de l'app.", table: "API")
            case .foreign: return L("Un autre programme s'appelle déjà « notch » à cet endroit : rien n'a été modifié.", table: "API")
            }
        }
    }

    static var bundled: URL? { Bundle.main.url(forResource: "notch", withExtension: nil) }
    static var standardDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/notch")
    }

    static func status(bundled: URL? = bundled, destination: URL = standardDestination) -> Status {
        guard let bundled, let expected = try? Data(contentsOf: bundled) else { return .unavailable }
        guard let installed = try? Data(contentsOf: destination) else {
            // Présent mais illisible : pas à nous.
            return FileManager.default.fileExists(atPath: destination.path) ? .foreign : .notInstalled
        }
        if installed == expected { return .installed }
        return isOurs(installed) ? .outdated : .foreign
    }

    static func install(bundled: URL? = bundled, destination: URL = standardDestination) throws {
        let status = status(bundled: bundled, destination: destination)
        guard status != .foreign else { throw Failure.foreign }
        guard let bundled, let script = try? Data(contentsOf: bundled) else { throw Failure.unavailable }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: destination, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    /// Seulement le nôtre.
    static func remove(destination: URL = standardDestination) throws {
        guard let installed = try? Data(contentsOf: destination) else { return }
        guard isOurs(installed) else { throw Failure.foreign }
        try FileManager.default.removeItem(at: destination)
    }

    private static func isOurs(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self)
        return head.contains(marker) || head.contains(legacyMarker)
    }
}
