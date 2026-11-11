import AppKit
import Darwin
import Foundation
import XCTest
@testable import Oriel

/// Serveur local durci (audit du 2026-11-09, C13 à C15), joué contre le vrai serveur et le vrai script de hook :
/// refus dès les en-têtes, délai, plafond de connexions, jeton retiré à l'arrêt, script muet sans l'app, motifs
/// ancrés en fin de texte. Les clients légitimes passent comme avant.
final class LocalServerHardeningTests: XCTestCase {
    private let permission: [String: Any] = [
        "hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "Bash",
        "tool_input": ["command": "rm -rf build"],
    ]
    private let stop: [String: Any] = ["hook_event_name": "Stop", "session_id": "s1"]
    private let toolUse: [String: Any] = ["hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Bash",
                                          "tool_input": ["command": "ls"]]

    /// En-têtes seuls, sans le corps annoncé : une réponse ne peut venir que d'une décision prise sur les en-têtes.
    private func headOnly(_ path: String, _ headers: [(String, String)], length: Int) -> Data {
        var head = "POST \(path) HTTP/1.1\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        return Data((head + "Content-Length: \(length)\r\nConnection: close\r\n\r\n").utf8)
    }

    /// Réponse lue sur une connexion déjà ouverte, la boucle principale tournant.
    private func response(_ fd: Int32, timeout: TimeInterval = 5) -> RawHTTP.Response? {
        Background { RawHTTP.read(fd) }.wait(timeout: timeout) ?? nil
    }

    // MARK: - C14 : le jeton avant le corps

    /// À refuser : pas de jeton, mauvais jeton, Host ou Origin étrangers, avec un corps énorme annoncé et jamais
    /// envoyé. Le refus part sur les en-têtes seuls, sans attendre ni garder ce corps.
    func testRefusedOnHeadersAlone() throws {
        let fixture = try ReplyServerFixture(self)
        let huge = HookServer.maxBodySize - 1
        let cases: [(String, [(String, String)], Int)] = [
            ("sans jeton", [fixture.host], 401),
            ("mauvais jeton", [fixture.host, (HookAccess.headerName, String(repeating: "0", count: 32))], 401),
            ("Host étranger", [("Host", "evil.example:\(fixture.port)"), fixture.token], 403),
            ("page web", [fixture.host, fixture.token, ("Origin", "http://evil.example")], 403),
        ]
        for (label, headers, expected) in cases {
            for path in ["/hook", "/permission"] {
                let fd = RawHTTP.open(port: fixture.port, headOnly(path, headers, length: huge))
                XCTAssertEqual(response(fd)?.status, expected, "\(label) \(path) : refusé sans attendre le corps")
            }
        }
        // Trop gros, même avec le jeton : refusé sur la longueur annoncée.
        let tooLarge = RawHTTP.open(port: fixture.port,
                                    headOnly("/hook", [fixture.host, fixture.token], length: HookServer.maxBodySize + 1))
        XCTAssertEqual(response(tooLarge)?.status, 413)
        XCTAssertTrue(fixture.receivedEvents.isEmpty && fixture.replies.requests.isEmpty)
    }

    /// À accepter : le bon jeton, puis le corps arrivé à part ; un gros corps légitime sous la limite ; toutes les
    /// routes du script de hook et du diagnostic.
    func testLegitimeClientsStillServed() throws {
        let fixture = try ReplyServerFixture(self)
        let event = try JSONSerialization.data(withJSONObject: stop)
        let split = RawHTTP.open(port: fixture.port, headOnly("/hook", [fixture.host, fixture.token], length: event.count))
        _ = event.withUnsafeBytes { Darwin.write(split, $0.baseAddress, $0.count) }
        XCTAssertEqual(response(split)?.status, 204, "en-têtes acceptés, puis corps lu")

        // Un Write de 8 Mo (contenu du fichier dans l'événement) : sous la limite de 32 Mo, relayé.
        let bigWrite: [String: Any] = ["hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Write",
                                    "tool_input": ["file_path": "/tmp/gros", "content": String(repeating: "a", count: 8 << 20)]]
        XCTAssertEqual(RawHTTP.send(port: fixture.port, fixture.post("/hook", bigWrite))?.status, 204)
        XCTAssertTrue(spin { fixture.receivedEvents.contains { $0.name == "PostToolUse" } }, "gros corps relayé")

        XCTAssertEqual(RawHTTP.send(port: fixture.port, fixture.post("/claude/status", ["model": "x"]))?.status, 204)
        XCTAssertEqual(RawHTTP.send(port: fixture.port, RawHTTP.request("GET", "/health", headers: [fixture.host]))?.status,
                       204)
        XCTAssertEqual(RawHTTP.send(port: fixture.port,
                                    RawHTTP.request("GET", "/state", headers: [fixture.host, fixture.token]))?.status, 200)

        // Requêtes tenues : admises, et rendues à la décision.
        let held = RawHTTP.open(port: fixture.port, fixture.post("/permission", permission))
        XCTAssertTrue(spin { fixture.replies.requests.count == 1 })
        let request = try XCTUnwrap(fixture.replies.requests.first)
        fixture.replies.engage(request.id)
        XCTAssertTrue(fixture.replies.decide(request, .deny("Non")))
        XCTAssertEqual(response(held)?.status, 200)
        let inbox = RawHTTP.open(port: fixture.port, fixture.post("/inbox", stop, headers: [
            fixture.host, fixture.token, ("Content-Type", "application/json"), ("X-Claude-PPID", "\(getpid())"),
        ]))
        XCTAssertTrue(spin { fixture.replies.waiting == ["s1"] })
        XCTAssertEqual(fixture.replies.send("Bonjour", to: "s1"), .delivered)
        XCTAssertEqual(response(inbox)?.text, "Bonjour")
    }

    /// API locale : son jeton aussi est contrôlé avant le corps ; les routes de la commande `notch` passent.
    func testLocalAPIChecksItsTokenFirst() throws {
        let fixture = try LocalAPIServerFixture(self)
        let fd = RawHTTP.open(port: fixture.port,
                              headOnly(LocalAPI.path, [fixture.host, fixture.json], length: HookServer.maxBodySize - 1))
        let refused = response(fd)
        XCTAssertEqual(refused?.status, 401, "sans jeton, sans attendre le corps")
        XCTAssertEqual(refused?.text.contains("unauthorized"), true, "même réponse qu'avant")

        let posted = fixture.send("POST", body: ["title": "Build", "id": "build", "client": "make.sh"])
        XCTAssertEqual(posted?.status, 200)
        XCTAssertEqual(fixture.send("DELETE", LocalAPI.path + "/build")?.status, 204)
        XCTAssertEqual(fixture.send("DELETE")?.status, 204)
    }

    // MARK: - C14 : délai et plafond

    /// Connexion muette, en-têtes jamais finis, corps annoncé jamais envoyé : 408 au bout du délai. Une requête
    /// tenue, elle, n'est plus soumise au délai une fois lue.
    func testIdleConnectionsAreClosed() throws {
        let fixture = try ReplyServerFixture(self) { $0.requestTimeout = 0.3 }
        let held = RawHTTP.open(port: fixture.port, fixture.post("/permission", permission))
        XCTAssertTrue(spin { fixture.replies.requests.count == 1 })

        let mute = RawHTTP.open(port: fixture.port, Data())
        XCTAssertEqual(response(mute)?.status, 408, "connexion muette")
        let partial = RawHTTP.open(port: fixture.port, Data("POST /hook HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\n".utf8))
        XCTAssertEqual(response(partial)?.status, 408, "en-têtes jamais finis")
        let stalled = RawHTTP.open(port: fixture.port, headOnly("/hook", [fixture.host, fixture.token], length: 100))
        XCTAssertEqual(response(stalled)?.status, 408, "corps jamais envoyé, même avec le jeton")

        // Ouverte avant les trois autres : son délai est passé, elle attend toujours la décision.
        XCTAssertEqual(fixture.replies.requests.count, 1, "requête tenue intacte")
        let request = try XCTUnwrap(fixture.replies.requests.first)
        fixture.replies.engage(request.id)
        XCTAssertTrue(fixture.replies.decide(request, .deny("Non")))
        XCTAssertEqual(response(held)?.status, 200)
    }

    /// Plafond atteint (requêtes tenues comprises) : 503 sans rien lire. Un hook qui ferme sa connexion rend sa place.
    func testConnectionCap() throws {
        let fixture = try ReplyServerFixture(self) { $0.maxConnections = 3 }
        let held = (0..<3).map { _ in RawHTTP.open(port: fixture.port, fixture.post("/permission", permission)) }
        XCTAssertTrue(spin { fixture.replies.requests.count == 3 })

        XCTAssertEqual(response(RawHTTP.open(port: fixture.port, Data()))?.status, 503, "une de trop")

        close(held[0])
        XCTAssertTrue(spin { fixture.replies.requests.count == 2 }, "fermeture vue par l'app")
        XCTAssertTrue(spin { RawHTTP.send(port: fixture.port, fixture.post("/hook", self.toolUse))?.status == 204 },
                      "place rendue")
        held.dropFirst().forEach { close($0) }
    }

    // MARK: - C13 : pas de jeton sans l'app

    private static func oriel(_ home: URL) -> URL { home.appendingPathComponent("Library/Application Support/Oriel") }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// App quittée normalement, ou serveur arrêté : jeton, preuve et processus retirés. Une seconde instance qui n'a
    /// pas eu le port ne retire pas le jeton de la première.
    func testTokenRemovedWhenTheAppQuits() throws {
        let quitting = try ReplyServerFixture(self)
        let names = ["hook-token", "hook-proof", "hook-pid"]
        let files = names.map { Self.oriel(quitting.home).appendingPathComponent($0) }
        XCTAssertEqual(files.map(exists), [true, true, true])
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(files.map(exists), [false, false, false], "retirés à la fermeture de l'app")

        let fixture = try ReplyServerFixture(self)
        let token = try XCTUnwrap(fixture.access.file)
        var failed = false
        let second = HookServer(port: fixture.port, access: HookAccess(file: token), replies: fixture.replies) { _, _ in }
        second.onFailure = { _ in failed = true }
        try second.start()
        XCTAssertTrue(spin { failed }, "port déjà pris")
        second.stop()
        XCTAssertEqual(try String(contentsOf: token, encoding: .utf8), "X-Oriel-Token: \(fixture.access.token)\n",
                       "le jeton de la première instance reste")

        fixture.server.stop()
        XCTAssertEqual(names.map { exists(Self.oriel(fixture.home).appendingPathComponent($0)) }, [false, false, false],
                       "retirés à l'arrêt du serveur")
    }

    /// Un autre programme tient le port, app tuée (jeton resté, processus parti) ou quittée (jeton retiré) : le script
    /// n'envoie rien, dans aucun de ses modes. Témoin : avec l'app vivante, il envoie bien.
    func testScriptSendsNothingWithoutTheApp() throws {
        let squatter = try Squatter()
        let home = try makeTemporaryDirectory(self)
        let access = HookAccess(file: Self.oriel(home).appendingPathComponent("hook-token"))
        try access.writeFile()
        func run(_ mode: String?, _ payload: [String: Any]) throws {
            let hook = try ClaudeHookScriptTests.Run(mode: mode, payload: payload, home: home, port: squatter.port,
                                                     environment: ["ORIEL_RETRY": "0"])
            addTeardownBlock { if hook.process.isRunning { hook.process.terminate() } }
            XCTAssertTrue(hook.finish(timeout: 10), mode ?? "relais")
            XCTAssertEqual(hook.status, 0, mode ?? "relais")
        }

        try run(nil, toolUse)
        XCTAssertEqual(squatter.connections, 1, "témoin : app vivante, l'événement part")

        // App tuée : les fichiers restent, le processus qui les a écrits est parti.
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try dead.run()
        dead.waitUntilExit()
        try "\(dead.processIdentifier)\n".write(to: Self.oriel(home).appendingPathComponent("hook-pid"),
                                                atomically: true, encoding: .utf8)
        for (mode, payload) in [(nil, toolUse), ("permission", permission), ("inbox", stop)] {
            try run(mode, payload)
        }
        XCTAssertEqual(squatter.connections, 1, "app tuée : rien n'est parti")

        // App quittée : plus de jeton.
        try FileManager.default.removeItem(at: Self.oriel(home).appendingPathComponent("hook-token"))
        try run(nil, toolUse)
        XCTAssertEqual(squatter.connections, 1, "app quittée : rien n'est parti")
    }

    /// Programme qui tient le port à la place de l'app : compte les connexions, les ferme sans répondre.
    private final class Squatter {
        private(set) var port: UInt16 = 0
        private let fd: Int32
        private let lock = NSLock()
        private var count = 0

        init() throws {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                    Darwin.bind(fd, pointer, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, pointer, &length) == 0
                }
            }
            guard fd >= 0, bound else { throw POSIXError(.EADDRINUSE) }
            port = UInt16(bigEndian: address.sin_port)
            let listening = fd
            Thread.detachNewThread { [weak self] in
                while true {
                    let client = accept(listening, nil, nil)
                    guard client >= 0 else { return }
                    self?.lock.lock()
                    self?.count += 1
                    self?.lock.unlock()
                    close(client)
                }
            }
        }

        deinit {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }

        var connections: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    // MARK: - C15 : fin de texte stricte

    /// Chaîne passée par JSONSerialization, comme celles de l'app : c'est sur elles que `$` acceptait un saut de ligne
    /// final (règle ICU « fin de texte, ou juste avant un dernier séparateur de ligne »).
    private func viaJSON(_ text: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [text])
        return try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String])?.first)
    }

    func testTrailingLineBreakIsRefused() throws {
        let fixture = try LocalAPIServerFixture(self)
        let values = [("client", "make.sh\n"), ("client", "make.sh\u{2028}"), ("id", "abcdefgh\n"),
                      ("app", "com.apple.Terminal\n")]
        for (field, value) in values {
            XCTAssertEqual(fixture.send("POST", body: ["title": "T", field: value])?.status, 400,
                           "\(field) = \(value.debugDescription)")
        }
        XCTAssertEqual(fixture.send("POST", body: ["title": "T", "client": "make.sh", "id": "abcdefgh",
                                                   "app": "com.apple.Terminal"])?.status, 200, "sans saut de ligne")

        XCTAssertFalse(HookHeaders.isDesktopSessionId(try viaJSON("local_abc-123\n")))
        XCTAssertNil(HookHeaders(["x-host-session-id": try viaJSON("local_abc-123\u{2028}")]).hostSessionId)
        XCTAssertTrue(HookHeaders.isDesktopSessionId(try viaJSON("local_abc-123")))

        XCTAssertNil(CommandDuration.minutes(from: try viaJSON("25 min\n"), allowBare: true))
        XCTAssertEqual(CommandDuration.minutes(from: try viaJSON("25 min"), allowBare: true), 25)
        let meet = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij%0A"))
        XCTAssertFalse(MeetingLink.isOpenable(meet))
        XCTAssertTrue(MeetingLink.isOpenable(try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))))
    }
}
