import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Oriel

/// Serveur local réel sur un port libre avec l'API locale ; jetons écrits dans un HOME jetable, au même endroit
/// relatif que l'app (la commande `notch` les lit sous $HOME).
final class LocalAPIServerFixture {
    let home: URL
    let api: LocalAPI
    let access: HookAccess
    private(set) var server: HookServer!
    private(set) var port: UInt16 = 0

    init(_ testCase: XCTestCase, enabled: Bool = true,
         apps: [String: String] = ["com.apple.Terminal": "Terminal"],
         limiter: RateLimiter = RateLimiter(capacity: 10, perSecond: 2)) throws {
        home = try makeTemporaryDirectory(testCase)
        let directory = home.appendingPathComponent("Library/Application Support/Oriel")
        api = LocalAPI(defaults: makeEphemeralDefaults(testCase), tokenFile: directory.appendingPathComponent("api-token"),
                       appName: { apps[$0] }, limiter: limiter)
        api.isEnabled = enabled
        access = HookAccess(file: directory.appendingPathComponent("hook-token"))
        let replies = ReplyCenter(prefs: Preferences(defaults: makeEphemeralDefaults(testCase)))
        let hookFile = access.file!
        for attempt in 1...3 {
            port = UInt16.random(in: 49_200...60_000)
            let candidate = HookServer(port: port, access: access, replies: replies) { _, _ in }
            candidate.api = api
            try candidate.start()
            if spin(until: { FileManager.default.fileExists(atPath: hookFile.path) }) {
                server = candidate
                break
            }
            candidate.stop()
            guard attempt < 3 else {
                throw NSError(domain: "LocalAPIServerFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "serveur de test non démarré (3 ports essayés)"])
            }
        }
        // Le jeton de l'API part sur la boucle principale une fois le port à nous.
        if enabled { spin { FileManager.default.fileExists(atPath: self.tokenFile.path) } }
        testCase.addTeardownBlock { [server] in server?.stop() }
    }

    var tokenFile: URL { api.tokenFile! }
    var host: (String, String) { ("Host", "127.0.0.1:\(port)") }
    var bearer: (String, String) { ("Authorization", "Bearer \(api.token)") }
    var json: (String, String) { ("Content-Type", "application/json") }

    func send(_ method: String, _ path: String = LocalAPI.path, body: Any? = nil,
              headers: [(String, String)]? = nil) -> RawHTTP.Response? {
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return RawHTTP.send(port: port, RawHTTP.request(method, path, headers: headers ?? [host, bearer, json], body: data))
    }
}

/// API locale : jeton, schéma strict et bornes, nettoyage des textes, cadence, durée de vie, routes et intercalaires.
final class LocalAPITests: XCTestCase {
    private func makeAPI(enabled: Bool = true, apps: [String: String] = ["com.apple.Terminal": "Terminal"]) -> LocalAPI {
        let api = LocalAPI(defaults: makeEphemeralDefaults(self), tokenFile: nil, appName: { apps[$0] })
        api.isEnabled = enabled
        return api
    }

    private func request(_ api: LocalAPI, _ method: String = "POST", _ path: String = LocalAPI.path, body: Any? = nil,
                         raw: Data? = nil, token: String? = nil,
                         contentType: String? = "application/json") -> HTTPRequest {
        var headers = ["host": "127.0.0.1:47823", "authorization": "Bearer \(token ?? api.token)"]
        headers["content-type"] = contentType
        let data = raw ?? body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return HTTPRequest(method: method, path: path, headers: headers, body: data)
    }

    private func post(_ api: LocalAPI, _ body: Any, now: Date = Date()) -> LocalAPI.Response {
        api.handle(request(api, body: body), now: now)
    }

    private func message(_ response: LocalAPI.Response) -> String {
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: String]
        return json?["message"] ?? ""
    }

    // MARK: - Activation et jeton

    func testOffByDefaultAndPersisted() {
        let defaults = makeEphemeralDefaults(self)
        let api = LocalAPI(defaults: defaults, tokenFile: nil, appName: { _ in nil })
        XCTAssertFalse(api.isEnabled, "coupée par défaut")
        let off = api.handle(request(api, body: ["title": "x"]))
        XCTAssertEqual(off.status, 403)
        XCTAssertTrue(api.items.isEmpty)

        api.isEnabled = true
        XCTAssertTrue(LocalAPI(defaults: defaults, tokenFile: nil, appName: { _ in nil }).isEnabled, "réglage gardé")
        XCTAssertEqual(post(api, ["title": "x"]).status, 200)
    }

    func testTokenIsRequiredAndRenewed() {
        let api = makeAPI()
        XCTAssertNotNil(api.token.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        XCTAssertEqual(api.handle(request(api, body: ["title": "x"], token: "")).status, 401)
        XCTAssertEqual(api.handle(request(api, body: ["title": "x"], token: String(repeating: "0", count: 32))).status, 401)
        var missing = request(api, body: ["title": "x"])
        missing = HTTPRequest(method: missing.method, path: missing.path,
                              headers: missing.headers.filter { $0.key != "authorization" }, body: missing.body)
        XCTAssertEqual(api.handle(missing).status, 401)
        XCTAssertTrue(api.items.isEmpty, "rien sans le bon jeton")

        let first = api.token
        api.isEnabled = false
        api.isEnabled = true
        XCTAssertNotEqual(api.token, first, "nouveau jeton à chaque activation")
        XCTAssertEqual(api.handle(request(api, body: ["title": "x"], token: first)).status, 401, "l'ancien ne sert plus")
        XCTAssertNotEqual(makeAPI().token, makeAPI().token, "nouveau jeton à chaque lancement")
    }

    func testTokenFileOnlyWhileEnabled() throws {
        let directory = try makeTemporaryDirectory(self)
        let file = directory.appendingPathComponent("Oriel/api-token")
        let api = LocalAPI(defaults: makeEphemeralDefaults(self), tokenFile: file, appName: { _ in nil })
        api.isEnabled = true
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "rien avant que le serveur tienne le port")
        api.serverDidStart()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Authorization: Bearer \(api.token)\n")

        api.show(ExternalEar(id: "a", title: "A", expires: Date().addingTimeInterval(60)))
        api.isEnabled = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "coupée : plus de jeton sur disque")
        XCTAssertTrue(api.items.isEmpty, "coupée : intercalaires retirés")
        api.isEnabled = true
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Authorization: Bearer \(api.token)\n")
    }

    // MARK: - Schéma

    func testValidEarWithEveryField() throws {
        let api = makeAPI()
        let now = Date()
        let response = post(api, ["id": "build-1", "title": "Build fini", "text": "2m14", "detail": "42 tests, 0 échec",
                                  "icon": "checkmark.circle.fill", "color": "green", "ttl": 30,
                                  "app": "com.apple.Terminal", "client": "make.sh"], now: now)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: response.body) as? [String: String], ["id": "build-1"])
        let ear = try XCTUnwrap(api.items.first)
        XCTAssertEqual(ear, ExternalEar(id: "build-1", title: "Build fini", text: "2m14", detail: "42 tests, 0 échec",
                                        icon: "checkmark.circle.fill", color: "green", app: "com.apple.Terminal",
                                        appName: "Terminal", client: "make.sh", expires: now.addingTimeInterval(30)))
        XCTAssertEqual(ear.accentHex, "4ADE80")
        XCTAssertEqual(api.clients.map(\.name), ["make.sh"])
    }

    func testDefaults() throws {
        let api = makeAPI()
        let now = Date()
        XCTAssertEqual(post(api, ["title": "Salut"], now: now).status, 200)
        let ear = try XCTUnwrap(api.items.first)
        XCTAssertNotNil(ear.id.range(of: "^[0-9a-f]{8}$", options: .regularExpression), "identifiant tiré au hasard")
        XCTAssertEqual(ear.icon, "bell.fill")
        XCTAssertEqual(ear.color, "indigo")
        XCTAssertEqual(ear.client, "script")
        XCTAssertEqual(ear.text, "")
        XCTAssertNil(ear.app)
        XCTAssertEqual(ear.expires, now.addingTimeInterval(60))
    }

    func testStrictSchemaAndBounds() {
        let api = makeAPI()
        // Une seconde entre deux requêtes : la cadence ne s'en mêle pas.
        var clock = Date()
        func tick() -> Date {
            clock.addTimeInterval(1)
            return clock
        }
        let cases: [(Any, String)] = [
            ([String: Any](), "title: required."),
            (["title": "   \n "], "title: required."),
            (["title": 3], "title: must be a string."),
            (["title": String(repeating: "a", count: 41)], "title: 40 characters at most."),
            (["title": "x", "text": String(repeating: "a", count: 13)], "text: 12 characters at most."),
            (["title": "x", "detail": String(repeating: "é", count: 161)], "detail: 160 characters at most."),
            (["title": "x", "script": "rm -rf ~"], "Unknown field: script."),
            (["title": "x", "url": "https://example.com"], "Unknown field: url."),
            (["title": "x", "icon": "hand.raised.fill"], "icon: not in the list (see docs/API.md)."),
            (["title": "x", "icon": "../../etc"], "icon: a symbol from the list."),
            (["title": "x", "color": "#FF0000"], "color: a color name from the list."),
            (["title": "x", "color": "black"], "color: one of"),
            (["title": "x", "ttl": 0], "ttl: whole number of seconds, 1 to 3600."),
            (["title": "x", "ttl": 3601], "ttl: whole number"),
            (["title": "x", "ttl": 2.5], "ttl: whole number"),
            (["title": "x", "ttl": "60"], "ttl: whole number"),
            (["title": "x", "ttl": true], "ttl: whole number"),
            (["title": "x", "id": "a/b"], "id: 1 to 32 letters"),
            (["title": "x", "id": ""], "id: 1 to 32 letters"),
            (["title": "x", "id": String(repeating: "a", count: 33)], "id: 1 to 32 letters"),
            (["title": "x", "client": "Claude\u{202E}"], "client: 1 to 24 letters"),
            (["title": "x", "client": "Claude Code"], "client: this name is reserved."),
            (["title": "x", "client": "my-CODEX-bot"], "client: this name is reserved."),
            (["title": "x", "client": "OpenAI"], "client: this name is reserved."),
            (["title": "x", "color": "teal"], "color: one of"),
            (["title": "x", "app": "Terminal"], "app: a bundle identifier"),
            (["title": "x", "app": "com.example.absent"], "app: no installed app has this bundle identifier."),
            (["title": "x", "app": "file:///Applications/Calculator.app"], "app: a bundle identifier"),
            ([["title": "x"]], "The body must be a JSON object."),
        ]
        for (body, expected) in cases {
            let response = post(api, body, now: tick())
            XCTAssertEqual(response.status, 400, "\(body)")
            XCTAssertTrue(message(response).hasPrefix(expected), "\(body) → \(message(response))")
        }
        XCTAssertEqual(api.handle(request(api, raw: Data("{\"title\": ".utf8)), now: tick()).status, 400, "JSON invalide")
        XCTAssertEqual(api.handle(request(api, raw: Data([0x7B, 0xFF, 0x7D])), now: tick()).status, 400, "UTF-8 invalide")
        XCTAssertEqual(api.handle(request(api, body: ["title": "x"], contentType: nil), now: tick()).status, 415)
        XCTAssertEqual(api.handle(request(api, body: ["title": "x"], contentType: "text/plain"), now: tick()).status, 415)
        let big = ["title": "x", "detail": String(repeating: "a", count: 5000)]
        XCTAssertEqual(api.handle(request(api, body: big), now: tick()).status, 413)
        XCTAssertTrue(api.items.isEmpty, "aucune requête refusée n'a rien posé")

        // Bornes exactes acceptées.
        XCTAssertEqual(post(api, ["title": String(repeating: "é", count: 40), "text": String(repeating: "9", count: 12),
                                  "detail": String(repeating: "a", count: 160), "ttl": 3600], now: tick()).status, 200)
        XCTAssertEqual(post(api, ["title": "x", "ttl": 1, "id": "A.b_c-9", "client": "My Tool 2"], now: tick()).status, 200)
    }

    /// Une seule ligne, rien qui trompe l'œil ; les émojis composés restent entiers.
    func testTextIsCleaned() throws {
        XCTAssertEqual(ExternalEar.clean("Build\nfini\t\r\n  ok "), "Build fini ok")
        XCTAssertEqual(ExternalEar.clean("abc\u{202E}def\u{2066}g\u{200B}h\u{FEFF}"), "abcdefgh", "sens forcé, largeur nulle")
        XCTAssertEqual(ExternalEar.clean("a\u{0}b\u{7}c\u{1B}[31md"), "abc[31md", "contrôles et séquences ANSI")
        XCTAssertEqual(ExternalEar.clean("x\u{E000}y"), "xy", "zone privée")
        XCTAssertEqual(ExternalEar.clean("a\u{2028}b\u{00A0}c"), "a b c")
        XCTAssertEqual(ExternalEar.clean("👨‍👩‍👧 é"), "👨‍👩‍👧 é")
        XCTAssertEqual(ExternalEar.clean("$(rm -rf ~) `id` \"q\" \\"), "$(rm -rf ~) `id` \"q\" \\", "du texte, jamais exécuté")

        let api = makeAPI()
        XCTAssertEqual(post(api, ["title": "Fin\n\u{202E}tset", "text": "ok\u{200B}"]).status, 200)
        XCTAssertEqual(api.items.first?.title, "Fin tset")
        XCTAssertEqual(api.items.first?.text, "ok")
        // Des signes combinants empilés comptent pour un caractère : bornés par les scalaires.
        let zalgo = "a" + String(repeating: "\u{0301}", count: 200)
        XCTAssertEqual(post(api, ["title": zalgo]).status, 400)
    }

    // MARK: - Nombre, durée de vie, cadence

    func testSameIdReplacesAndAtMostThree() {
        let api = makeAPI()
        for id in ["a", "b", "c"] { XCTAssertEqual(post(api, ["id": id, "title": id]).status, 200) }
        XCTAssertEqual(post(api, ["id": "b", "title": "B2"]).status, 200)
        XCTAssertEqual(api.items.map(\.id), ["a", "c", "b"], "remplacé, devenu le plus récent")
        XCTAssertEqual(api.items.last?.title, "B2")
        XCTAssertEqual(post(api, ["id": "d", "title": "d"]).status, 200)
        XCTAssertEqual(api.items.map(\.id), ["c", "b", "d"], "trois au plus : le plus ancien laisse sa place")
        XCTAssertEqual(LocalAPI.maxItems, 3)
    }

    func testEarsExpire() {
        let api = makeAPI()
        let now = Date()
        XCTAssertEqual(post(api, ["id": "short", "title": "s", "ttl": 5], now: now).status, 200)
        XCTAssertEqual(post(api, ["id": "long", "title": "l", "ttl": 60], now: now).status, 200)
        api.expire(now: now.addingTimeInterval(4))
        XCTAssertEqual(api.items.map(\.id), ["short", "long"])
        api.expire(now: now.addingTimeInterval(5))
        XCTAssertEqual(api.items.map(\.id), ["long"])
        api.expire(now: now.addingTimeInterval(61))
        XCTAssertTrue(api.items.isEmpty)
    }

    /// Le réveil programmé (un seul, pas de timer périodique) retire bien l'intercalaire à l'échéance.
    func testExpiryFiresByItself() {
        let api = makeAPI()
        api.show(ExternalEar(id: "x", title: "x", expires: Date().addingTimeInterval(0.2)))
        XCTAssertEqual(api.items.count, 1)
        XCTAssertTrue(spin(timeout: 3) { api.items.isEmpty })
    }

    func testRateLimit() {
        let api = makeAPI()
        let now = Date()
        for index in 0..<10 {
            XCTAssertEqual(post(api, ["id": "a", "title": "\(index)"], now: now).status, 200, "rafale de 10")
        }
        let limited = post(api, ["id": "a", "title": "late"], now: now)
        XCTAssertEqual(limited.status, 429)
        XCTAssertEqual(api.items.first?.title, "9")
        XCTAssertEqual(api.handle(request(api, "DELETE"), now: now).status, 429, "toutes les routes")
        let later = now.addingTimeInterval(1)
        XCTAssertEqual(post(api, ["id": "a", "title": "x"], now: later).status, 200, "2 par seconde ensuite")
        XCTAssertEqual(post(api, ["id": "a", "title": "y"], now: later).status, 200)
        XCTAssertEqual(post(api, ["id": "a", "title": "z"], now: later).status, 429)

        var limiter = RateLimiter(capacity: 2, perSecond: 1)
        XCTAssertTrue(limiter.allow(now: now))
        XCTAssertTrue(limiter.allow(now: now))
        XCTAssertFalse(limiter.allow(now: now))
        XCTAssertFalse(limiter.allow(now: now.addingTimeInterval(-10)), "une horloge qui recule ne rend rien")
        XCTAssertTrue(limiter.allow(now: now.addingTimeInterval(100)))
        XCTAssertTrue(limiter.allow(now: now.addingTimeInterval(100)), "plafond à la capacité")
        XCTAssertFalse(limiter.allow(now: now.addingTimeInterval(100)))
    }

    // MARK: - Routes

    func testDeleteRoutes() {
        let api = makeAPI()
        for id in ["a", "b"] { XCTAssertEqual(post(api, ["id": id, "title": id]).status, 200) }
        XCTAssertEqual(api.handle(request(api, "DELETE", LocalAPI.path + "/a")).status, 204)
        XCTAssertEqual(api.items.map(\.id), ["b"])
        XCTAssertEqual(api.handle(request(api, "DELETE", LocalAPI.path + "/a")).status, 404)
        XCTAssertEqual(api.handle(request(api, "DELETE", LocalAPI.path + "/..")).status, 404)
        XCTAssertEqual(api.handle(request(api, "DELETE")).status, 204)
        XCTAssertTrue(api.items.isEmpty)
        XCTAssertEqual(api.handle(request(api, "GET")).status, 404)
        XCTAssertEqual(api.handle(request(api, "PUT")).status, 404)
        XCTAssertEqual(api.handle(request(api, "POST", "/api/v1/run", body: ["title": "x"])).status, 404)
    }

    // MARK: - Intercalaires de la notch

    /// Un intercalaire par élément, sous Claude et Codex, jamais une alerte, titre et carte fournis par l'API.
    func testEarTabsFromScripts() throws {
        let api = makeAPI()
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let timer = FakeModule(id: "timer", ears: ModuleEars(symbol: "timer", text: "4:59", priority: 5),
                               keepsRunning: true)
        let media = FakeModule(id: "media", ears: ModuleEars(symbol: "music.note", text: "", priority: 1, bars: true),
                               keepsRunning: true)
        let registry = ModuleRegistry(modules: [FakeModule(id: "claude"), timer, media], prefs: prefs, external: api)
        XCTAssertEqual(post(api, ["id": "build", "title": "Build", "text": "ok", "icon": "hammer.fill",
                                  "color": "orange"]).status, 200)
        XCTAssertEqual(post(api, ["id": "mail", "title": "Courrier", "icon": "envelope.fill"]).status, 200)
        XCTAssertTrue(spin { registry.earsEntries.count == 4 }, "relu au tour de boucle suivant")

        let tabs = registry.earTabs(claude: .attention, claudeEars: nil)
        XCTAssertEqual(tabs.map(\.id), ["claude", "timer", "api.mail", "api.build", "media"],
                       "sous Claude et le minuteur, au-dessus du lecteur ; le plus récent d'abord")
        let build = try XCTUnwrap(tabs.first { $0.id == "api.build" })
        XCTAssertFalse(build.isAlert, "ne reste jamais déployé de lui-même")
        XCTAssertEqual(build.priority, LocalAPI.earPriority)
        XCTAssertLessThan(LocalAPI.earPriority, 6, "sous Codex (6 et 9) et Claude (100 et 1000)")
        XCTAssertEqual(build.text, "ok")
        XCTAssertEqual(build.accentHex, "FB923C")
        XCTAssertEqual(tabs.first { $0.id == "timer" }?.accentHex, "F5B83D", "les modules gardent leur couleur")
        XCTAssertEqual(registry.earTitle("api.build"), "Build")
        XCTAssertEqual(registry.earTitle("timer"), "timer")
        XCTAssertNotNil(registry.earDetailView("api.build"))
        XCTAssertNil(registry.earDetailView("api.absent"))
        let alone = ModuleRegistry(modules: [FakeModule(id: "notes")], prefs: prefs, external: api)
        XCTAssertNotNil(alone.moduleEars, "garde la notch à l'écran comme une activité")

        // Un script ne peut pas se faire passer pour un module : ses identifiants sont préfixés.
        XCTAssertEqual(post(api, ["id": "claude", "title": "Claude attend ta réponse"]).status, 200)
        XCTAssertTrue(spin { registry.earsEntries.contains { $0.id == "api.claude" } })
        XCTAssertEqual(registry.earTabs(claude: .none, claudeEars: nil).filter { $0.id == "claude" }.count, 0)
        XCTAssertNil(registry.module("api.claude"))

        api.isEnabled = false
        XCTAssertTrue(spin { registry.earsEntries.count == 2 }, "coupée : ses intercalaires partent")
    }

    /// Symboles de la liste tous présents dans le système, couleurs valides, aucun ne rappelle une demande d'accès.
    func testIconsAndColorsExist() {
        for icon in ExternalEar.icons {
            XCTAssertNotNil(NSImage(systemSymbolName: icon, accessibilityDescription: nil), icon)
            let words = Set(icon.split(separator: ".").map(String.init))
            XCTAssertTrue(words.isDisjoint(with: ["raised", "lock", "key", "shield", "questionmark"]), icon)
        }
        XCTAssertEqual(Set(ExternalEar.icons).count, ExternalEar.icons.count)
        for (name, hex) in ExternalEar.colors { XCTAssertNotNil(Color(hex: hex), name) }
        XCTAssertFalse(ExternalEar.colors.values.contains(EarTabs.accentHex(forId: ModuleRegistry.codexId) ?? ""),
                       "jamais la couleur de Codex")
        XCTAssertNotNil(ExternalEar.colors[ExternalEar.defaultColor])
        XCTAssertTrue(ExternalEar.icons.contains(ExternalEar.defaultIcon))
    }

    // MARK: - Par le vrai serveur

    /// Host exact, aucun Origin, et chaque jeton à sa place : celui des hooks n'ouvre pas l'API, et inversement.
    func testServerChecksHostOriginAndTokens() throws {
        let fixture = try LocalAPIServerFixture(self)
        let body = ["title": "x"]
        let host = fixture.host, bearer = fixture.bearer, json = fixture.json
        XCTAssertEqual(fixture.send("POST", body: body)?.status, 200)
        XCTAssertEqual(fixture.send("POST", body: body, headers: [("Host", "evil.example:\(fixture.port)"), bearer, json])?.status,
                       403, "DNS rebinding")
        XCTAssertEqual(fixture.send("POST", body: body, headers: [("Host", "localhost:\(fixture.port)"), bearer, json])?.status,
                       403)
        XCTAssertEqual(fixture.send("POST", body: body, headers: [bearer, json])?.status, 403, "sans Host")
        XCTAssertEqual(fixture.send("POST", body: body, headers: [host, bearer, json, ("Origin", "https://evil.example")])?.status,
                       403, "page web")
        XCTAssertEqual(fixture.send("POST", body: body, headers: [host, bearer, json, ("Origin", "null")])?.status, 403)
        XCTAssertEqual(fixture.send("POST", body: body, headers: [host, json])?.status, 401, "sans jeton")
        XCTAssertEqual(fixture.send("POST", body: body,
                                    headers: [host, json, (HookAccess.headerName, fixture.access.token)])?.status,
                       401, "le jeton des hooks n'ouvre pas l'API")
        XCTAssertEqual(fixture.send("POST", body: body,
                                    headers: [host, json, ("Authorization", "Bearer \(fixture.access.token)")])?.status, 401)
        XCTAssertEqual(fixture.send("GET", "/state", headers: [host, bearer])?.status, 401,
                       "le jeton de l'API n'ouvre pas le reste du serveur")
        XCTAssertEqual(fixture.send("POST", "/permission", body: ["hook_event_name": "PermissionRequest"],
                                    headers: [host, bearer, json, (HookAccess.headerName, fixture.api.token)])?.status, 401)
        XCTAssertEqual(fixture.api.items.count, 1, "seule la requête complète a posé quelque chose")

        let ok = try XCTUnwrap(fixture.send("POST", body: ["id": "r", "title": "y"]))
        XCTAssertEqual(ok.status, 200)
        XCTAssertTrue(ok.headers.contains("Content-Type: application/json"))
        XCTAssertFalse(ok.headers.contains(HookAccess.proofHeader), "la preuve des hooks ne sort jamais ici")
        XCTAssertEqual(ok.text, #"{"id":"r"}"#)
        let invalid = try XCTUnwrap(fixture.send("POST", body: ["title": "x", "color": "black"]))
        XCTAssertEqual(invalid.status, 400)
        XCTAssertTrue(invalid.text.contains(#""error":"invalid""#))
        XCTAssertEqual(fixture.send("DELETE", LocalAPI.path + "/r")?.status, 204)

        fixture.api.isEnabled = false
        XCTAssertEqual(fixture.send("POST", body: body)?.status, 403, "coupée")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.tokenFile.path))
    }

    /// Sans `LocalAPI` branchée, les routes n'existent pas.
    func testServerWithoutAPI() throws {
        let fixture = try ReplyServerFixture(self)
        let response = RawHTTP.send(port: fixture.port, RawHTTP.request("POST", LocalAPI.path,
                                                                         headers: [fixture.host, fixture.token]))
        XCTAssertEqual(response?.status, 404)
    }

    // MARK: - Barre de commande

    /// « i » retire un intercalaire d'un script (ou tous), seulement à ⏎ ; aucun verbe sans intercalaire, rien sans verbe.
    func testCommandBarRemovesScriptTabsOnlyOnRun() throws {
        let api = makeAPI()
        XCTAssertNil(api.commandVerb)
        XCTAssertEqual(post(api, ["id": "a", "title": "Sauvegarde", "client": "backup.sh"]).status, 200)
        XCTAssertEqual(post(api, ["id": "b", "title": "Build fini", "client": "make.sh"]).status, 200)
        XCTAssertEqual(api.commandVerb?.key, "i")
        func ids(_ verb: String?, _ argument: String) -> [String] {
            api.commands(for: CommandQuery(verb: verb, argument: argument)).map(\.id)
        }
        XCTAssertEqual(ids("i", ""), ["api.remove.b", "api.remove.a", "api.clear"], "le plus récent d'abord")
        XCTAssertEqual(ids("i", "backup"), ["api.remove.a"], "cherche aussi le nom du programme")
        XCTAssertEqual(ids(nil, "sauvegarde"), [], "pas dans une recherche libre")
        let remove = try XCTUnwrap(api.commands(for: CommandQuery(verb: "i", argument: "sauv")).first)
        XCTAssertEqual(api.items.count, 2, "rien n'est retiré avant ⏎")
        XCTAssertNil(remove.run())
        XCTAssertEqual(api.items.map(\.id), ["b"])
        XCTAssertNotNil(remove.run(), "déjà retiré : la barre le dit")
    }
}
