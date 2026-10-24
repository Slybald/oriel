import Darwin
import Foundation
import Network
import os

/// Mini serveur HTTP local (127.0.0.1:47823) qui reçoit les événements relayés par le script de hook.
///
/// Chaque requête doit porter l'en-tête Host exact (`127.0.0.1:<port>`) et aucun en-tête Origin : une page web
/// ne parle pas au serveur, même par DNS rebinding. Sauf `/health`, elle doit aussi porter le jeton du fichier
/// partagé avec le script (`HookAccess`) ; en retour, une décision ou un message porte la preuve que c'est bien
/// l'app qui répond. Routes : `/hook` (événements async), `/permission` et `/inbox`
/// (requêtes longues des hooks synchrones, confiées à `ReplyCenter`), `GET /state` (diagnostic), `/api/…` (API
/// locale des scripts de l'utilisateur, avec son propre jeton : `LocalAPI`). Aucune route
/// ne permet à un client de décider : une décision n'est que la réponse à la requête d'un hook, après un clic.
final class HookServer {
    typealias Handler = (HookEvent, ProcessContext) -> Void

    static let defaultPort: UInt16 = 47823
    static let maxBodySize = 32 * 1024 * 1024

    var onFailure: ((Error) -> Void)?
    /// Diagnostic en lecture seule pour `GET /state` (appelé sur le main thread).
    var stateProvider: (() -> [String: Any])?
    /// Suivi des sessions Codex (routes `/codex/hook` et `/codex/permission`). À poser avant `start()`.
    weak var codex: CodexRelay?
    /// API locale (routes `/api/…`). À poser avant `start()` ; nil : 404.
    var api: LocalAPI?
    /// Corps de `POST /claude/status` (JSON de la `statusLine` de Claude Code, relayé pour les jauges de quota). Tout thread.
    var onClaudeStatus: ((Data) -> Void)?

    let port: UInt16
    let access: HookAccess
    private let replies: ReplyCenter
    private let handler: Handler
    private let queue = DispatchQueue(label: AppIdentity.bundleId + ".server", qos: .userInitiated)
    private var listener: NWListener?
    /// Connexions ouvertes (sur `queue`) : `stop()` les ferme, comme l'arrêt de l'app, pour que les hooks tenus le voient.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private let codexPaused = OSAllocatedUnfairLock(initialState: true)

    /// Onglet Claude désactivé : le port reste ouvert (rien ne tourne au repos), mais les événements sont ignorés
    /// sans remonter les processus, et `/permission` et `/inbox` répondent 204 tout de suite (le terminal garde la
    /// main). Écrit sur le main thread, lu sur la queue du serveur.
    var isPaused: Bool {
        get { paused.withLock { $0 } }
        set { paused.withLock { $0 = newValue } }
    }

    /// Onglet Codex désactivé (ou pas encore démarré) : les routes `/codex/*` répondent 204 sans rien analyser.
    var isCodexPaused: Bool {
        get { codexPaused.withLock { $0 } }
        set { codexPaused.withLock { $0 = newValue } }
    }

    init(port: UInt16 = HookServer.defaultPort, access: HookAccess = HookAccess(), replies: ReplyCenter = .shared,
         handler: @escaping Handler) {
        self.port = port
        self.access = access
        self.replies = replies
        self.handler = handler
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let access = self.access
        let api = self.api
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Seulement une fois le port à nous : une seconde instance n'écrase pas le jeton de la première.
                do {
                    try access.writeFile()
                } catch {
                    NSLog("Oriel : jeton des hooks impossible à écrire (%@).", String(describing: error))
                }
                DispatchQueue.main.async { api?.serverDidStart() }
            case .failed(let error):
                self?.onFailure?(error)
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [self] in
            let open = connections.values
            connections = [:]
            open.forEach { $0.cancel() }
        }
    }

    // MARK: - Connexions

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .cancelled, .failed: self?.connections[ObjectIdentifier(connection)] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch HTTPRequest.parse(buffer, maxBody: Self.maxBodySize) {
            case .complete(let request):
                self.serve(request, on: connection)
            case .needMore:
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            case .tooLarge:
                self.reply(413, "Payload Too Large", on: connection)
            case .invalid:
                self.reply(400, "Bad Request", on: connection)
            }
        }
    }

    private func serve(_ request: HTTPRequest, on connection: NWConnection) {
        guard request.headers["host"] == "127.0.0.1:\(port)", request.headers["origin"] == nil else {
            return reply(403, "Forbidden", on: connection)
        }
        if request.path == "/health" { return reply(204, "No Content", on: connection) }
        // API locale : son propre jeton, jamais celui des hooks (voir `LocalAPI`).
        if request.path.hasPrefix("/api/"), let api {
            let response = DispatchQueue.main.sync { api.handle(request) }
            return reply(response.status, response.reason, body: response.body, on: connection)
        }
        guard access.accepts(request.headers[HookAccess.headerKey]) else {
            return reply(401, "Unauthorized", on: connection)
        }
        if isPaused, request.method == "POST", ["/hook", "/permission", "/inbox", "/claude/status"].contains(request.path) {
            return reply(204, "No Content", on: connection)
        }
        if isCodexPaused, request.method == "POST", ["/codex/hook", "/codex/permission"].contains(request.path) {
            return reply(204, "No Content", on: connection)
        }
        switch (request.method, request.path) {
        case ("POST", "/codex/hook"):
            relayCodex(request, on: connection)
        case ("POST", "/codex/permission"):
            holdCodex(request, on: connection)
        case ("POST", "/claude/status"):
            onClaudeStatus?(request.body)
            reply(204, "No Content", on: connection)
        case ("POST", "/hook"):
            relay(request, on: connection)
        case ("POST", "/permission"):
            hold(request, on: connection)
        case ("POST", "/inbox"):
            wait(request, on: connection)
        case ("GET", "/state"):
            let replies = self.replies
            let state = DispatchQueue.main.sync { () -> [String: Any] in
                var state = stateProvider?() ?? [:]
                state["replies"] = replies.debugInfo
                return state
            }
            let body = (try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            reply(200, "OK", body: body, on: connection)
        default:
            reply(404, "Not Found", on: connection)
        }
    }

    private func relay(_ request: HTTPRequest, on connection: NWConnection) {
        // Le script de hook attend notre réponse : ses processus parents sont encore vivants,
        // c'est le moment de remonter la chaîne pour identifier Claude et l'app hôte.
        let headers = HookHeaders(request.headers)
        let context = ProcessInspector.context(for: headers)
        reply(204, "No Content", on: connection)

        guard let event = HookEvent(data: request.body, headers: headers) else { return }
        handler(event, context)
        let replies = self.replies
        DispatchQueue.main.async { replies.observe(event) }
    }

    /// Événement de hook Codex (asynchrone) : même règle que `relay`, le contexte est résolu avant de répondre.
    private func relayCodex(_ request: HTTPRequest, on connection: NWConnection) {
        let context = CodexProcess.context(for: HookHeaders(request.headers))
        reply(204, "No Content", on: connection)
        guard let event = HookEvent(data: request.body, headers: HookHeaders(request.headers)) else { return }
        codex?.codexEvent(event, context: context)
    }

    /// Hook PermissionRequest de Codex, synchrone : la connexion reste ouverte jusqu'à la décision (200 + sortie du hook)
    /// ou son abandon (204, le terminal pose sa question). Codex attend le hook avant d'afficher son invite.
    private func holdCodex(_ request: HTTPRequest, on connection: NWConnection) {
        let headers = HookHeaders(request.headers)
        guard let relay = codex, let event = HookEvent(data: request.body, headers: headers) else {
            return reply(204, "No Content", on: connection)
        }
        let context = CodexProcess.context(for: headers)
        let id = UUID()
        let respond: (Data?) -> Void = { [weak self] output in
            guard let self else { return connection.cancel() }
            if let output {
                self.reply(200, "OK", body: output, proof: true, on: connection)
            } else {
                self.reply(204, "No Content", on: connection)
            }
        }
        relay.codexHold(event, context: context, id: id, reply: respond)
        watchClosure(of: connection) { [weak relay] in relay?.codexConnectionClosed(id) }
    }

    /// Hook PermissionRequest synchrone : la connexion reste ouverte jusqu'à la réponse de `ReplyCenter`
    /// (200 + décision, ou 204 sans décision) ou jusqu'à sa fermeture par le hook (réponse donnée au terminal).
    private func hold(_ request: HTTPRequest, on connection: NWConnection) {
        guard let event = HookEvent(data: request.body, headers: HookHeaders(request.headers)) else {
            return reply(204, "No Content", on: connection)
        }
        let id = UUID()
        let replies = self.replies
        let respond: (Data?) -> Void = { [weak self] output in
            guard let self else { return connection.cancel() }
            if let output {
                self.reply(200, "OK", body: output, proof: true, on: connection)
            } else {
                self.reply(204, "No Content", on: connection)
            }
        }
        DispatchQueue.main.async { replies.hold(event, id: id, reply: respond) }
        watchClosure(of: connection) { DispatchQueue.main.async { replies.connectionClosed(id) } }
    }

    /// Attente `asyncRewake` (SessionStart, Stop) : 200 + texte du message, ou 204.
    private func wait(_ request: HTTPRequest, on connection: NWConnection) {
        let headers = HookHeaders(request.headers)
        guard let event = HookEvent(data: request.body, headers: headers), let sessionId = event.sessionId else {
            return reply(204, "No Content", on: connection)
        }
        // Onglet Code de Claude Desktop (identifiant de session Desktop) : voir `ReplyCenter.wait`.
        let desktop = headers.hostSessionId != nil
        let atStop = event.name == "Stop"
        let id = UUID()
        let replies = self.replies
        let respond: (String?) -> Void = { [weak self] message in
            guard let self else { return connection.cancel() }
            if let message {
                self.reply(200, "OK", body: Data(message.utf8), contentType: "text/plain; charset=utf-8", proof: true,
                           on: connection)
            } else {
                self.reply(204, "No Content", on: connection)
            }
        }
        DispatchQueue.main.async {
            replies.wait(sessionId: sessionId, pid: headers.ppid, id: id, desktop: desktop, atStop: atStop,
                         reply: respond)
        }
        watchClosure(of: connection) { DispatchQueue.main.async { replies.connectionClosed(id) } }
    }

    /// Le client n'envoie plus rien après sa requête : une lecture qui aboutit signale sa fermeture (hook tué,
    /// réponse donnée au terminal). Après notre propre réponse, l'annulation de la connexion la termine aussi.
    private func watchClosure(of connection: NWConnection, _ onClose: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil || self == nil {
                onClose()
            } else {
                self?.watchClosure(of: connection, onClose)
            }
        }
    }

    /// `proof` : seulement en réponse à une requête authentifiée, sinon n'importe qui pourrait la lire.
    private func reply(_ status: Int, _ reason: String, body: Data = Data(), contentType: String = "application/json",
                       proof: Bool = false, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: \(contentType)\r\n" }
        if proof { head += "\(HookAccess.proofHeader): \(access.proof)\r\n" }
        connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Jeton partagé entre l'app et le script de hook : 32 caractères hexadécimaux, nouveaux à chaque lancement,
/// écrits dans un fichier 0600 sous forme de ligne d'en-tête que le script donne à curl (`-H @fichier`, jamais
/// en argument, donc invisible dans `ps`). Comparaison en temps constant.
///
/// Le jeton prouve à l'app que le client est le script ; la preuve (second secret, fichier 0600 `hook-proof`,
/// jamais envoyée par le script) prouve au script que c'est l'app qui répond. Sans elle, un programme d'un autre
/// compte qui occupe le port pendant que l'app est fermée verrait sa « décision » appliquée.
struct HookAccess {
    static let headerName = "X-Oriel-Token"
    static let headerKey = headerName.lowercased()
    static let proofHeader = "X-Oriel-Proof"
    /// Lu par hooks/oriel-hook.sh : `$HOME/Library/Application Support/Oriel/hook-token`.
    static var standardFile: URL { SharedFiles.notchDirectory.appendingPathComponent("hook-token") }

    let token: String
    let proof: String
    /// nil : rien sur disque (tests qui n'ont pas besoin du script).
    let file: URL?
    /// À côté du jeton.
    var proofFile: URL? { file?.deletingLastPathComponent().appendingPathComponent("hook-proof") }

    init(token: String = HookAccess.randomToken(), proof: String = HookAccess.randomToken(),
         file: URL? = HookAccess.standardFile) {
        self.token = token
        self.proof = proof
        self.file = file
    }

    /// `SystemRandomNumberGenerator` est le générateur cryptographique du système sur les plateformes Apple.
    static func randomToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    func accepts(_ presented: String?) -> Bool {
        Self.constantTimeEquals(presented, token)
    }

    /// Temps constant pour une longueur donnée ; une attente vide n'ouvre rien. Sert aussi à l'API locale.
    static func constantTimeEquals(_ presented: String?, _ expected: String) -> Bool {
        let given = Array((presented ?? "").utf8)
        let expected = Array(expected.utf8)
        guard given.count == expected.count, !expected.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= given[index] ^ expected[index] }
        return difference == 0
    }

    /// La preuve, puis le jeton (le script ne parle à l'app qu'une fois le jeton là).
    func writeFile() throws {
        guard let file, let proofFile else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.write("\(proof)\n", to: proofFile)
        try Self.write("\(Self.headerName): \(token)\n", to: file)
    }

    /// Fichier temporaire créé en 0600 (`O_EXCL`) dans le même dossier, puis `rename` : jamais de secret
    /// lisible par un autre compte, ni de fichier à moitié écrit. Sert aussi au jeton de l'API locale.
    static func write(_ text: String, to file: URL) throws {
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent)-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let line = Array(text.utf8)
        let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == line.count, rename(temporary.path, file.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            unlink(temporary.path)
            throw POSIXError(code)
        }
    }
}

/// Requête HTTP/1.1 minimale : ligne de requête, en-têtes, corps de taille Content-Length.
struct HTTPRequest {
    enum ParseResult {
        case complete(HTTPRequest)
        case needMore
        case tooLarge
        case invalid
    }

    let method: String
    let path: String
    /// Clés en minuscules.
    let headers: [String: String]
    let body: Data

    private static let terminator = Data("\r\n\r\n".utf8)
    private static let maxHeaderSize = 64 * 1024

    static func parse(_ data: Data, maxBody: Int) -> ParseResult {
        guard let end = data.range(of: terminator) else {
            return data.count > maxHeaderSize ? .invalid : .needMore
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        guard length <= maxBody else { return .tooLarge }

        let bodyStart = end.upperBound
        guard data.endIndex - bodyStart >= length else { return .needMore }

        let rawPath = String(requestLine[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: path,
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + length))
        ))
    }
}
