import Foundation
import XCTest
@testable import Oriel

/// Diagnostic « en vrai » : le vrai Codex (`codex app-server`, celui de l'app et de l'interface texte) contre le vrai
/// serveur de hooks, le vrai script et le vrai installateur. Sauté sans `ORIEL_CODEX_LIVE=1` : il demande Codex
/// installé et connecté, et consomme un peu de quota (trois courts tours).
///
///     ORIEL_CODEX_LIVE=1 swift test --filter CodexLiveTests
///
/// Rien n'est écrit dans le vrai ~/.codex : CODEX_HOME jetable (seul `auth.json` y est un lien vers le vrai), hooks posés
/// par `CodexHookInstaller`, confiance écrite dans le config.toml jetable comme le fait `/hooks`.
final class CodexLiveTests: XCTestCase {
    private struct Seen: Decodable {
        let thread: String
        let hooksListed: Int
        let untrustedBefore: Int
        let clientApprovals: Int
        let marker: Bool
        let turn: String?
        let hooksRun: [String]
    }

    /// `ORIEL_CODEX_BIN` (par exemple le `codex` embarqué dans l'app ChatGPT), sinon la commande `codex`.
    private func codexExecutable() throws -> String {
        if let custom = ProcessInfo.processInfo.environment["ORIEL_CODEX_BIN"] { return custom }
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path]
        return try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0) }, "codex introuvable")
    }

    func testRealCodexTurnsThroughTheNotch() throws {
        guard ProcessInfo.processInfo.environment["ORIEL_CODEX_LIVE"] == "1" else {
            throw XCTSkip("ORIEL_CODEX_LIVE non défini")
        }
        let codex = try codexExecutable()
        let realAuth = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: realAuth.path) else { throw XCTSkip("Codex n'est pas connecté") }

        let fixture = try ReplyServerFixture(self)
        let module = CodexModule(defaults: makeEphemeralDefaults(self))
        module.replyFromNotch = true
        module.setTracking(true)
        fixture.server.codex = module
        fixture.server.isCodexPaused = false
        addTeardownBlock { module.setTracking(false) }

        let root = try makeTemporaryDirectory(self)
        let codexHome = root.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: codexHome.appendingPathComponent("auth.json"), withDestinationURL: realAuth)
        try "model_reasoning_effort = \"low\"\n".write(to: codexHome.appendingPathComponent("config.toml"),
                                                         atomically: true, encoding: .utf8)
        // Le vrai installateur, avec le vrai script de l'app.
        let installer = CodexHookInstaller(configDirectory: codexHome,
                                           bundledHook: repositoryRoot.appendingPathComponent("hooks/codex-notch-hook.sh"))
        try installer.install()
        XCTAssertEqual(installer.status(), .installed)

        func run(_ name: String, client: String, decide: (CodexApprovals.Request) -> Void) throws -> Seen {
            let work = root.appendingPathComponent("work-\(name)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", repositoryRoot.appendingPathComponent("Tests/Live/codex_live_driver.py").path,
                                 codexHome.path, fixture.home.path, String(fixture.port), work.path, client]
            process.environment = ["PATH": "\((codex as NSString).deletingLastPathComponent):/usr/bin:/bin",
                                   "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            defer { if process.isRunning { process.terminate() } }

            XCTAssertTrue(spin(timeout: 90) { module.approvals.requests.count == 1 }, "\(name) : le hook tient la demande")
            let request = try XCTUnwrap(module.approvals.requests.first)
            XCTAssertEqual(request.tool.detail, "touch marker.txt", name)
            XCTAssertEqual(module.store.sessions.values.first { $0.phase == .waitingApproval }?.id != nil, true,
                           "\(name) : la session attend une approbation")
            module.approvals.engage(request.id)
            decide(request)
            XCTAssertTrue(spin(timeout: 120) { !process.isRunning }, "\(name) : le tour se termine")
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let seen = try JSONDecoder().decode(Seen.self, from: XCTUnwrap(String(decoding: data, as: UTF8.self)
                .split(separator: "\n").last.map { Data($0.utf8) }))
            XCTAssertEqual(seen.hooksListed, 8, "\(name) : Codex voit nos huit hooks")
            XCTAssertEqual(seen.turn, "completed", name)
            // Codex n'annonce que les hooks synchrones ; les relais `async` se voient dans le magasin (ci-dessous).
            XCTAssertTrue(seen.hooksRun.contains("permissionRequest"), "\(name) : hook PermissionRequest exécuté (\(seen.hooksRun))")
            return seen
        }

        // Autorisé depuis la notch : la commande tourne, Codex n'a rien demandé au client.
        let allowed = try run("allow", client: "decline") { module.decide($0, .allow) }
        XCTAssertTrue(allowed.marker)
        XCTAssertEqual(allowed.clientApprovals, 0, "le hook a décidé avant l'invite de Codex")
        XCTAssertEqual(allowed.untrustedBefore, 8, "hooks neufs : à valider (ici dans le CODEX_HOME jetable)")
        // Relais asynchrones : `Stop` a posé le dernier message ; à l'arrêt du serveur, `SessionEnd` clôt la session.
        XCTAssertTrue(spin { module.store.sessions[allowed.thread]?.lastMessage != nil }, "Stop reçu : dernier message")
        let session = try XCTUnwrap(module.store.sessions[allowed.thread])
        XCTAssertTrue([.done, .ended].contains(session.phase), "\(session.phase)")
        XCTAssertEqual(session.toolCount >= 1, true, "PostToolUse reçu")
        XCTAssertEqual(session.model?.isEmpty, false)
        XCTAssertNotNil(session.pid, "le processus Codex est identifié")
        XCTAssertEqual(session.projectName, "work-allow", "projet = dossier de travail")
        if codex.contains("/ChatGPT.app/") {
            // Le serveur de l'app ChatGPT : la session est présentée comme venant de l'app, et « Ouvrir » ira à sa conversation.
            XCTAssertEqual(session.hostBundleId, "com.openai.codex")
            XCTAssertEqual(session.sourceLabel, "ChatGPT")
            XCTAssertEqual(CodexModule.deepLink(for: session), URL(string: "codex://threads/\(allowed.thread)"))
        }

        // Refusé : la commande ne tourne pas.
        let denied = try run("deny", client: "accept") { module.decide($0, .deny) }
        XCTAssertFalse(denied.marker)
        XCTAssertEqual(denied.clientApprovals, 0)

        // « Dans le terminal » : le hook ne décide rien, Codex pose lui-même sa question au client.
        let terminal = try run("terminal", client: "accept") { module.decide($0, .terminal) }
        XCTAssertEqual(terminal.clientApprovals, 1, "Codex pose sa question : le terminal garde la main")
        XCTAssertTrue(terminal.marker)
        XCTAssertTrue(module.approvals.requests.isEmpty)
    }

    /// Le vrai `codex app-server` (celui de l'app ChatGPT, ou `ORIEL_CODEX_BIN`) contre `CodexAppServer` : lister
    /// les hooks, les approuver (config.toml du CODEX_HOME jetable seulement), les relire. Aucun tour, aucun quota.
    func testRealAppServerListsThenApprovesOurHooks() throws {
        guard ProcessInfo.processInfo.environment["ORIEL_CODEX_LIVE"] == "1" else {
            throw XCTSkip("ORIEL_CODEX_LIVE non défini")
        }
        let override = ProcessInfo.processInfo.environment["ORIEL_CODEX_BIN"].map { URL(fileURLWithPath: $0) }
        guard let codex = override ?? CodexBinary.find() else { throw XCTSkip("Codex introuvable") }
        let realConfig = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        let realBefore = try? Data(contentsOf: realConfig)

        let home = try makeTemporaryDirectory(self).appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let installer = CodexHookInstaller(configDirectory: home,
                                           bundledHook: repositoryRoot.appendingPathComponent("hooks/codex-notch-hook.sh"))
        try installer.install()
        let setup = CodexHookSetup(installer: { installer }, service: { _ in
            CodexAppServer(executable: codex, home: home, timeout: 90)
        })
        setup.refresh()
        XCTAssertEqual(setup.flow, .pendingApproval(8), "estimation d'après config.toml : rien d'approuvé")

        setup.verify(force: true)
        XCTAssertTrue(spin(timeout: 100) { !setup.isWorking }, "hooks/list")
        XCTAssertEqual(setup.flow, .pendingApproval(8), "Codex confirme : huit hooks neufs, ignorés (\(setup.message ?? "-"))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.configURL.path), "lister n'écrit rien")

        setup.approve()
        XCTAssertTrue(spin(timeout: 100) { !setup.isWorking }, "config/batchWrite")
        XCTAssertEqual(setup.flow, .active, setup.message ?? "-")
        XCTAssertEqual(installer.unapprovedCount(), 0, "config.toml porte maintenant huit trusted_hash, écrits par Codex")

        let hooks = try CodexAppServer(executable: codex, home: home, timeout: 90).hooks(approving: nil).filter(installer.isOurs)
        XCTAssertEqual(hooks.count, 8)
        XCTAssertTrue(hooks.allSatisfy { $0.trustStatus == "trusted" && $0.enabled })
        XCTAssertEqual(try? Data(contentsOf: realConfig), realBefore, "le vrai config.toml n'a pas bougé")
    }
}
