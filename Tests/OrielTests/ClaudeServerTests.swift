import Darwin
import Foundation
import XCTest
@testable import Oriel

/// Client HTTP brut (socket POSIX) : en-têtes au choix, Host compris, que URLSession ne laisse pas fixer.
enum RawHTTP {
    struct Response {
        let status: Int
        let headers: String
        let body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    static func request(_ method: String, _ path: String, headers: [(String, String)], body: Data = Data()) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Ouvre la connexion et envoie la requête ; -1 si la connexion échoue.
    static func open(port: UInt16, _ request: Data, timeout: Int = 10) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return -1
        }
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return fd
    }

    /// Lit jusqu'à la fermeture, puis ferme.
    static func read(_ fd: Int32) -> Response? {
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        let parts = head.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        return Response(status: status, headers: head, body: data[end.upperBound...])
    }

    /// Requête complète depuis une autre file, la boucle principale tournant (le serveur passe par elle).
    static func send(port: UInt16, _ request: Data, timeout: TimeInterval = 10) -> Response? {
        let result = Background { RawHTTP.read(RawHTTP.open(port: port, request)) }
        return result.wait(timeout: timeout) ?? nil
    }
}

/// Travail sur une file de fond ; `wait` fait tourner la boucle principale jusqu'au résultat.
final class Background<T> {
    private let lock = NSLock()
    private var result: T?
    private var finished = false

    init(_ work: @escaping () -> T) {
        DispatchQueue.global().async { [self] in
            let value = work()
            lock.lock()
            result = value
            finished = true
            lock.unlock()
        }
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func wait(timeout: TimeInterval = 10) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while !isFinished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

/// Fait tourner la boucle principale jusqu'à la condition ; faux après `timeout`.
@discardableResult
func spin(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return true
}

/// Serveur de hooks réel sur un port libre, jeton et fichier dans un dossier temporaire, réglages jetables.
final class ReplyServerFixture {
    private(set) var port: UInt16 = 0
    let prefs: Preferences
    let replies: ReplyCenter
    let access: HookAccess
    private(set) var server: HookServer!
    let home: URL
    private let sink = Sink()

    /// Événements relayés par `/hook` (main thread).
    final class Sink {
        var events: [HookEvent] = []
    }

    init(_ testCase: XCTestCase) throws {
        home = try makeTemporaryDirectory(testCase)
        prefs = Preferences(defaults: makeEphemeralDefaults(testCase))
        prefs.replyFromNotch = true
        replies = ReplyCenter(prefs: prefs)
        // Même emplacement relatif que l'app : le script le lit sous $HOME.
        access = HookAccess(file: home.appendingPathComponent("Library/Application Support/Oriel/hook-token"))
        let sink = self.sink
        let file = access.file!
        // Port pris au hasard : déjà occupé (autre programme, test voisin), on en essaie un autre. Le jeton n'est
        // écrit qu'une fois le port à nous.
        for attempt in 1...3 {
            port = UInt16.random(in: 49_200...60_000)
            let candidate = HookServer(port: port, access: access, replies: replies) { event, _ in
                DispatchQueue.main.async { sink.events.append(event) }
            }
            try candidate.start()
            if spin(until: { FileManager.default.fileExists(atPath: file.path) }) {
                server = candidate
                break
            }
            candidate.stop()
            guard attempt < 3 else {
                throw NSError(domain: "ReplyServerFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "serveur de test non démarré (3 ports essayés)"])
            }
        }
        testCase.addTeardownBlock { [server] in server?.stop() }
    }

    var receivedEvents: [HookEvent] { sink.events }

    var host: (String, String) { ("Host", "127.0.0.1:\(port)") }
    var token: (String, String) { (HookAccess.headerName, access.token) }

    func post(_ path: String, _ payload: [String: Any], headers: [(String, String)]? = nil) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return RawHTTP.request("POST", path, headers: headers ?? [host, token, ("Content-Type", "application/json")],
                               body: body)
    }
}

/// Serveur de hooks : protection du canal local et requêtes longues, par de vraies connexions HTTP.
final class ClaudeServerTests: XCTestCase {
    private let permission: [String: Any] = [
        "hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "Bash",
        "tool_input": ["command": "rm -rf build"],
    ]

    func testAccessTokenFileAndComparison() throws {
        let fixture = try ReplyServerFixture(self)
        let file = try XCTUnwrap(fixture.access.file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "X-Oriel-Token: \(fixture.access.token)\n")
        XCTAssertNotNil(fixture.access.token.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        let proofFile = try XCTUnwrap(fixture.access.proofFile)
        let proofAttributes = try FileManager.default.attributesOfItem(atPath: proofFile.path)
        XCTAssertEqual((proofAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: proofFile, encoding: .utf8), "\(fixture.access.proof)\n")
        XCTAssertNotEqual(fixture.access.proof, fixture.access.token, "deux secrets distincts")
        XCTAssertNotEqual(HookAccess().token, HookAccess().token, "nouveau jeton à chaque lancement")

        let access = HookAccess(token: "0123456789abcdef0123456789abcdef", file: nil)
        XCTAssertTrue(access.accepts("0123456789abcdef0123456789abcdef"))
        XCTAssertFalse(access.accepts("0123456789abcdef0123456789abcdee"))
        XCTAssertFalse(access.accepts("0123456789abcdef"))
        XCTAssertFalse(access.accepts(""))
        XCTAssertFalse(access.accepts(nil))
        XCTAssertFalse(HookAccess(token: "", file: nil).accepts(""), "un jeton vide n'ouvre rien")
    }

    /// Jeton exigé partout (sauf /health), Host exact, aucun Origin : rien ne passe sans les trois.
    func testHostOriginAndTokenAreRequired() throws {
        let fixture = try ReplyServerFixture(self)
        let host = fixture.host
        let token = fixture.token
        func status(_ method: String, _ path: String, _ headers: [(String, String)], body: Data = Data()) -> Int? {
            RawHTTP.send(port: fixture.port, RawHTTP.request(method, path, headers: headers, body: body))?.status
        }
        let event = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s1"])

        XCTAssertEqual(status("POST", "/hook", [host, token], body: event), 204)
        XCTAssertEqual(status("POST", "/hook", [host], body: event), 401, "sans jeton")
        XCTAssertEqual(status("POST", "/hook", [host, (HookAccess.headerName, String(repeating: "0", count: 32))],
                              body: event), 401, "mauvais jeton")
        XCTAssertEqual(status("POST", "/hook", [("Host", "evil.example:\(fixture.port)"), token], body: event), 403,
                       "DNS rebinding")
        XCTAssertEqual(status("POST", "/hook", [("Host", "localhost:\(fixture.port)"), token], body: event), 403)
        XCTAssertEqual(status("POST", "/hook", [token], body: event), 403, "sans Host")
        XCTAssertEqual(status("POST", "/hook", [host, token, ("Origin", "http://evil.example")], body: event), 403,
                       "page web")
        XCTAssertEqual(status("POST", "/permission", [host], body: event), 401)
        XCTAssertEqual(status("POST", "/inbox", [host], body: event), 401)
        XCTAssertEqual(status("GET", "/state", [host]), 401, "diagnostic aussi protégé")
        XCTAssertEqual(status("GET", "/state", [host, ("Origin", "null"), token]), 403)
        XCTAssertEqual(status("GET", "/nope", [host, token]), 404)
        XCTAssertEqual(status("GET", "/health", [host]), 204)

        let state = RawHTTP.send(port: fixture.port, RawHTTP.request("GET", "/state", headers: [host, token]))
        XCTAssertEqual(state?.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: state?.body ?? Data()) as? [String: Any])
        XCTAssertEqual((json["replies"] as? [String: Any])?["enabled"] as? Bool, true)

        XCTAssertTrue(spin { fixture.receivedEvents.count == 1 }, "seul l'événement authentifié est relayé")
        XCTAssertTrue(fixture.replies.requests.isEmpty && fixture.replies.waiting.isEmpty)
    }

    /// /permission : la connexion reste ouverte jusqu'au clic, la réponse est la sortie du hook.
    func testPermissionHeldUntilDecision() throws {
        let fixture = try ReplyServerFixture(self)
        let pending = Background { RawHTTP.read(RawHTTP.open(port: fixture.port, fixture.post("/permission", self.permission))) }
        XCTAssertTrue(spin { fixture.replies.requests.count == 1 })
        XCTAssertFalse(pending.isFinished, "tenue tant que personne n'a cliqué")
        let request = try XCTUnwrap(fixture.replies.requests.first)
        XCTAssertTrue(fixture.replies.decide(request, .allow))

        let response = try XCTUnwrap(pending.wait() ?? nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.headers.contains("Content-Type: application/json"))
        XCTAssertTrue(response.headers.contains("X-Oriel-Proof: \(fixture.access.proof)"), "l'app prouve que c'est elle")
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? NSDictionary)
        XCTAssertEqual(output, ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                       "decision": ["behavior": "allow"]]])
    }

    /// Sans décision (échéance, outil terminé) : 204, le terminal garde la main.
    func testPermissionWithoutDecisionGets204() throws {
        let fixture = try ReplyServerFixture(self)
        let pending = Background { RawHTTP.read(RawHTTP.open(port: fixture.port, fixture.post("/permission", self.permission))) }
        XCTAssertTrue(spin { fixture.replies.requests.count == 1 })
        let started = Date()
        fixture.replies.expire(now: Date().addingTimeInterval(ReplyCenter.graceDelay))
        let response = try XCTUnwrap(pending.wait() ?? nil)
        XCTAssertEqual(response.status, 204)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertFalse(response.headers.contains("Proof"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)

        // Réglage coupé : réponse immédiate.
        fixture.prefs.replyFromNotch = false
        let off = RawHTTP.send(port: fixture.port, fixture.post("/permission", permission))
        XCTAssertEqual(off?.status, 204)
    }

    /// Onglet Claude désactivé : événements ignorés, `/permission` et `/inbox` rendus tout de suite (fail-open), le
    /// reste du serveur inchangé. Réactivé : tout repart.
    func testPausedServerIgnoresHooksAndFailsOpen() throws {
        let fixture = try ReplyServerFixture(self)
        fixture.server.isPaused = true
        let event = ["hook_event_name": "Stop", "session_id": "s1"]
        let started = Date()
        XCTAssertEqual(RawHTTP.send(port: fixture.port, fixture.post("/hook", event))?.status, 204)
        XCTAssertEqual(RawHTTP.send(port: fixture.port, fixture.post("/permission", permission))?.status, 204)
        XCTAssertEqual(RawHTTP.send(port: fixture.port, fixture.post("/inbox", event))?.status, 204)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "rien n'est tenu")
        XCTAssertEqual(RawHTTP.send(port: fixture.port, RawHTTP.request("GET", "/state",
                                                                        headers: [fixture.host, fixture.token]))?.status,
                       200, "le diagnostic reste")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(fixture.receivedEvents.isEmpty, "aucun événement relayé")
        XCTAssertTrue(fixture.replies.requests.isEmpty && fixture.replies.waiting.isEmpty)

        fixture.server.isPaused = false
        XCTAssertEqual(RawHTTP.send(port: fixture.port, fixture.post("/hook", event))?.status, 204)
        XCTAssertTrue(spin { fixture.receivedEvents.count == 1 }, "réactivé : relayé")
    }

    /// Le hook meurt (« No » au terminal, SIGTERM) : la connexion se ferme, la carte disparaît.
    func testClosedConnectionDropsRequest() throws {
        let fixture = try ReplyServerFixture(self)
        let fd = RawHTTP.open(port: fixture.port, fixture.post("/permission", permission))
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertTrue(spin { fixture.replies.requests.count == 1 })
        close(fd)
        XCTAssertTrue(spin { fixture.replies.requests.isEmpty }, "connexion fermée vue par le serveur")
    }

    /// /inbox : attente longue ; un message envoyé depuis la notch part en text/plain.
    func testInboxDeliversMessage() throws {
        let fixture = try ReplyServerFixture(self)
        let stop: [String: Any] = ["hook_event_name": "Stop", "session_id": "s1"]
        let waiting = Background { RawHTTP.read(RawHTTP.open(port: fixture.port, fixture.post("/inbox", stop))) }
        XCTAssertTrue(spin { fixture.replies.waiting == ["s1"] })
        XCTAssertEqual(fixture.replies.send("Ajoute un test « é » 😀\nfin", to: "s1"), .delivered)
        let response = try XCTUnwrap(waiting.wait() ?? nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.headers.contains("Content-Type: text/plain; charset=utf-8"))
        XCTAssertEqual(response.text, "Ajoute un test « é » 😀\nfin")

        // Deux attentes pour la même session : la première reçoit 204.
        let first = Background { RawHTTP.read(RawHTTP.open(port: fixture.port, fixture.post("/inbox", stop))) }
        XCTAssertTrue(spin { fixture.replies.waiting == ["s1"] })
        let second = Background { RawHTTP.read(RawHTTP.open(port: fixture.port, fixture.post("/inbox", stop))) }
        XCTAssertEqual((first.wait() ?? nil)?.status, 204)
        XCTAssertTrue(spin { fixture.replies.waiting == ["s1"] })
        fixture.replies.observe(HookEvent(raw: ["hook_event_name": "SessionEnd", "session_id": "s1"]))
        XCTAssertEqual((second.wait() ?? nil)?.status, 204)
    }
}
