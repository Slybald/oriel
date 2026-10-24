import Darwin
import Foundation
import XCTest
@testable import Oriel

/// Routes `/codex/*` du vrai serveur de hooks (connexions HTTP réelles, jeton, preuve) et le vrai
/// hooks/codex-notch-hook.sh (sh et curl du système) contre ce serveur. HOME jetable, aucun vrai Codex.
final class CodexServerTests: XCTestCase {
    private static let script = repositoryRoot.appendingPathComponent("hooks/codex-notch-hook.sh")

    private func makeFixture(reply: Bool = true) throws -> (ReplyServerFixture, CodexModule) {
        let fixture = try ReplyServerFixture(self)
        let module = CodexModule(defaults: makeEphemeralDefaults(self))
        module.replyFromNotch = reply
        module.setTracking(true)
        fixture.server.codex = module
        fixture.server.isCodexPaused = false
        addTeardownBlock { module.setTracking(false) }
        return (fixture, module)
    }

    private func payload(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        CodexFixtures.event(name, extra).raw
    }

    private var permission: [String: Any] {
        CodexFixtures.bash("rm -rf build", "PermissionRequest", description: "Supprime build").raw
    }

    // MARK: - Protection et pause

    func testCodexRoutesRequireHostAndToken() throws {
        let (fixture, module) = try makeFixture()
        let body = try JSONSerialization.data(withJSONObject: payload("UserPromptSubmit", ["prompt": "x"]))
        func status(_ path: String, _ headers: [(String, String)]) -> Int? {
            RawHTTP.send(port: fixture.port, RawHTTP.request("POST", path, headers: headers, body: body))?.status
        }
        for path in ["/codex/hook", "/codex/permission"] {
            XCTAssertEqual(status(path, [fixture.host]), 401, "\(path) sans jeton")
            XCTAssertEqual(status(path, [("Host", "evil.example:\(fixture.port)"), fixture.token]), 403, "\(path) DNS rebinding")
            XCTAssertEqual(status(path, [fixture.host, fixture.token, ("Origin", "https://evil.example")]), 403, "\(path) Origin")
        }
        XCTAssertTrue(module.store.sessions.isEmpty, "aucune requête refusée n'a touché l'état")
        XCTAssertEqual(RawHTTP.send(port: fixture.port, RawHTTP.request("GET", "/codex/hook", headers: [fixture.host, fixture.token]))?.status,
                       404, "GET non servi")
    }

    func testRelayDeliversTheEventWithItsHost() throws {
        let (fixture, module) = try makeFixture()
        let headers = [fixture.host, fixture.token, ("X-Bundle-Id", "com.googlecode.iterm2"), ("Content-Type", "application/json")]
        let request = RawHTTP.request("POST", "/codex/hook", headers: headers,
                                      body: try JSONSerialization.data(withJSONObject: payload("UserPromptSubmit", ["prompt": "Salut"])))
        XCTAssertEqual(RawHTTP.send(port: fixture.port, request)?.status, 204)
        XCTAssertTrue(spin { module.store.sessions[CodexFixtures.session]?.phase == .working })
        let session = try XCTUnwrap(module.store.sessions[CodexFixtures.session])
        XCTAssertEqual(session.lastPrompt, "Salut")
        XCTAssertEqual(session.hostBundleId, "com.googlecode.iterm2")
        XCTAssertNotNil(module.lastEventAt)
    }

    /// Onglet Codex désactivé : le port reste ouvert mais rien n'est analysé ni suivi, et les demandes sont rendues.
    func testPausedServerIgnoresCodexAndFailsOpen() throws {
        let (fixture, module) = try makeFixture()
        fixture.server.isCodexPaused = true
        let relay = fixture.post("/codex/hook", payload("UserPromptSubmit", ["prompt": "x"]))
        XCTAssertEqual(RawHTTP.send(port: fixture.port, relay)?.status, 204)
        let held = RawHTTP.send(port: fixture.port, fixture.post("/codex/permission", permission))
        XCTAssertEqual(held?.status, 204)
        XCTAssertEqual(held?.body.count, 0, "aucune décision")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(module.store.sessions.isEmpty)
        XCTAssertTrue(module.approvals.requests.isEmpty)
    }

    // MARK: - Approbation par HTTP

    func testPermissionHeldThenAllowedOverHTTP() throws {
        let (fixture, module) = try makeFixture()
        let response = Background { RawHTTP.read(RawHTTP.open(port: fixture.port, fixture.post("/codex/permission", self.permission))) }
        XCTAssertTrue(spin { module.approvals.requests.count == 1 }, "la requête est tenue")
        XCTAssertEqual(module.store.sessions[CodexFixtures.session]?.phase, .waitingApproval)
        let request = try XCTUnwrap(module.approvals.requests.first)
        XCTAssertEqual(request.tool.detail, "rm -rf build")

        module.approvals.engage(request.id)
        module.decide(request, .allow)
        let reply = try XCTUnwrap(response.wait(timeout: 5) ?? nil)
        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(reply.headers.contains("\(HookAccess.proofHeader): \(fixture.access.proof)"), "preuve de l'app")
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: reply.body) as? NSDictionary)
        XCTAssertEqual(output, ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]])
        XCTAssertEqual(module.store.sessions[CodexFixtures.session]?.phase, .working, "Codex reprend")
    }

    func testPermissionDeniedAndHandedToTheTerminal() throws {
        let (fixture, module) = try makeFixture()
        let denied = Background { RawHTTP.read(RawHTTP.open(port: fixture.port, fixture.post("/codex/permission", self.permission))) }
        XCTAssertTrue(spin { module.approvals.requests.count == 1 })
        module.decide(try XCTUnwrap(module.approvals.requests.first), .deny)
        let refusal = try XCTUnwrap(denied.wait(timeout: 5) ?? nil)
        let decision = ((try XCTUnwrap(JSONSerialization.jsonObject(with: refusal.body) as? NSDictionary))["hookSpecificOutput"]
            as? NSDictionary)?["decision"] as? NSDictionary
        XCTAssertEqual(decision?["behavior"] as? String, "deny")

        let terminal = Background { RawHTTP.read(RawHTTP.open(port: fixture.port, fixture.post("/codex/permission", self.permission))) }
        XCTAssertTrue(spin { module.approvals.requests.count == 1 })
        module.decide(try XCTUnwrap(module.approvals.requests.first), .terminal)
        let reply = try XCTUnwrap(terminal.wait(timeout: 5) ?? nil)
        XCTAssertEqual(reply.status, 204)
        XCTAssertEqual(reply.body.count, 0)
        XCTAssertEqual(module.store.sessions[CodexFixtures.session]?.phase, .waitingApproval,
                       "rendue au terminal : Codex attend toujours, là-bas")
    }

    func testClosingTheHookConnectionDropsTheCard() throws {
        let (fixture, module) = try makeFixture()
        let fd = RawHTTP.open(port: fixture.port, fixture.post("/codex/permission", permission))
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertTrue(spin { module.approvals.requests.count == 1 })
        close(fd)
        XCTAssertTrue(spin { module.approvals.requests.isEmpty }, "hook tué (Ctrl-C, timeout) : la carte disparaît")
    }

    func testSettingOffReturnsAtOnceButTheSessionStillShowsWaiting() throws {
        let (fixture, module) = try makeFixture(reply: false)
        let started = Date()
        let reply = RawHTTP.send(port: fixture.port, fixture.post("/codex/permission", permission))
        XCTAssertEqual(reply?.status, 204)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(spin { module.store.sessions[CodexFixtures.session]?.phase == .waitingApproval })
        XCTAssertTrue(module.approvals.requests.isEmpty)
    }

    func testTurningTheSettingOffReleasesHeldRequests() throws {
        let (fixture, module) = try makeFixture()
        let response = Background { RawHTTP.read(RawHTTP.open(port: fixture.port, fixture.post("/codex/permission", self.permission))) }
        XCTAssertTrue(spin { module.approvals.requests.count == 1 })
        module.replyFromNotch = false
        let reply = try XCTUnwrap(response.wait(timeout: 5) ?? nil)
        XCTAssertEqual(reply.status, 204)
    }

    // MARK: - Le vrai script

    /// Processus du script, sorties lues à la fin.
    final class Run {
        let process = Process()
        private let out = Pipe()
        private let err = Pipe()
        private(set) var stdout = ""
        let started = Date()

        init(mode: String?, payload: [String: Any], home: URL, port: UInt16, extra: [String: String] = [:]) throws {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [CodexServerTests.script.path] + (mode.map { [$0] } ?? [])
            process.environment = ["HOME": home.path, "ORIEL_PORT": String(port), "PATH": "/usr/bin:/bin",
                                   "TMPDIR": home.path].merging(extra) { $1 }
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = out
            process.standardError = err
            try process.run()
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
            try input.fileHandleForWriting.close()
        }

        @discardableResult
        func finish(timeout: TimeInterval = 10) -> Bool {
            guard spin(timeout: timeout, until: { !process.isRunning }) else { return false }
            stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            _ = err.fileHandleForReading.readDataToEndOfFile()
            return true
        }

        var status: Int32 { process.terminationStatus }
        var duration: TimeInterval { Date().timeIntervalSince(started) }
    }

    func testScriptRelaysEventsAndPrintsNothing() throws {
        let (fixture, module) = try makeFixture()
        let hook = try Run(mode: nil, payload: payload("UserPromptSubmit", ["prompt": "Bonjour"]), home: fixture.home,
                           port: fixture.port, extra: ["__CFBundleIdentifier": "com.apple.Terminal"])
        XCTAssertTrue(hook.finish())
        XCTAssertEqual(hook.status, 0)
        XCTAssertEqual(hook.stdout, "", "un relais asynchrone ne répond rien à Codex")
        XCTAssertTrue(spin { module.store.sessions[CodexFixtures.session] != nil })
        let session = try XCTUnwrap(module.store.sessions[CodexFixtures.session])
        XCTAssertEqual(session.phase, .working)
        XCTAssertEqual(session.pid, ProcessInfo.processInfo.processIdentifier, "$PPID du script = processus appelant")
    }

    func testScriptPermissionDecisionGoesToStdout() throws {
        let (fixture, module) = try makeFixture()
        let hook = try Run(mode: "permission", payload: permission, home: fixture.home, port: fixture.port)
        XCTAssertTrue(spin { module.approvals.requests.count == 1 }, "le hook tient sa requête")
        XCTAssertTrue(hook.process.isRunning)
        let request = try XCTUnwrap(module.approvals.requests.first)
        module.approvals.engage(request.id)
        module.decide(request, .deny)
        XCTAssertTrue(hook.finish())
        XCTAssertEqual(hook.status, 0)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hook.stdout.utf8)) as? NSDictionary)
        XCTAssertEqual((((output["hookSpecificOutput"] as? NSDictionary)?["decision"]) as? NSDictionary)?["behavior"] as? String,
                       "deny")
    }

    func testScriptWithoutDecisionLeavesTheTerminal() throws {
        let (fixture, module) = try makeFixture()
        let hook = try Run(mode: "permission", payload: permission, home: fixture.home, port: fixture.port)
        XCTAssertTrue(spin { module.approvals.requests.count == 1 })
        module.approvals.expire(now: Date().addingTimeInterval(CodexApprovals.graceDelay))
        XCTAssertTrue(hook.finish())
        XCTAssertEqual(hook.status, 0)
        XCTAssertEqual(hook.stdout, "", "aucune décision : Codex pose sa question")
    }

    /// Une réponse sans la preuve de l'app (autre programme sur le port) n'est jamais appliquée.
    func testScriptIgnoresAnAnswerWithoutTheAppsProof() throws {
        let (fixture, module) = try makeFixture()
        let hook = try Run(mode: "permission", payload: permission, home: fixture.home, port: fixture.port)
        XCTAssertTrue(spin { module.approvals.requests.count == 1 })
        let proof = try XCTUnwrap(fixture.access.proofFile)
        try FileManager.default.removeItem(at: proof)
        try "0000000000000000000000000000dead\n".write(to: proof, atomically: true, encoding: .utf8)
        module.decide(try XCTUnwrap(module.approvals.requests.first), .allow)
        XCTAssertTrue(hook.finish())
        XCTAssertEqual(hook.stdout, "", "preuve différente : on ne décide pas")
    }

    func testScriptWithoutTokenExitsAtOnceSilently() throws {
        let home = try makeTemporaryDirectory(self)
        for mode in [nil, "permission"] as [String?] {
            let hook = try Run(mode: mode, payload: payload("Stop"), home: home, port: 1)
            XCTAssertTrue(hook.finish(timeout: 5), "mode \(mode ?? "relais")")
            XCTAssertEqual(hook.status, 0)
            XCTAssertEqual(hook.stdout, "")
            XCTAssertLessThan(hook.duration, 3)
        }
    }
}
