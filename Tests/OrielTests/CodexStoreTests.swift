import Foundation
import XCTest
@testable import Oriel

/// Événements de hook Codex fictifs, avec les champs réellement relevés sur Codex 0.154 (`transcript_path` nul compris).
enum CodexFixtures {
    static let session = "019f0000-aaaa-7bbb-8ccc-000000000001"
    static let cwd = "/Users/demo/projets/mon-app"

    static func event(_ name: String, session: String = session, _ extra: [String: Any] = [:]) -> HookEvent {
        var raw: [String: Any] = [
            "session_id": session, "transcript_path": NSNull(), "cwd": cwd, "hook_event_name": name,
            "model": "gpt-6-astra", "permission_mode": "default",
        ]
        if name != "SessionStart", name != "SessionEnd" { raw["turn_id"] = "019f0000-aaaa-7bbb-8ccc-0000000000a1" }
        if name == "SessionStart" { raw["source"] = "startup" }
        if name == "SessionEnd" { raw["reason"] = "other" }
        return HookEvent(raw: raw.merging(extra) { $1 })
    }

    static func bash(_ command: String, _ name: String = "PreToolUse", session: String = session,
                     description: String? = nil) -> HookEvent {
        var input: [String: Any] = ["command": command]
        if let description { input["description"] = description }
        var extra: [String: Any] = ["tool_name": "Bash", "tool_input": input]
        if name != "PermissionRequest" { extra["tool_use_id"] = "exec-1111" }
        return event(name, session: session, extra)
    }

    static let terminal = CodexContext(pid: nil, start: nil, hostName: "iTerm2", hostBundleId: "com.googlecode.iterm2")
}

final class CodexStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let sid = CodexFixtures.session

    private func makeStore() -> CodexStore {
        let store = CodexStore()
        store.start()
        return store
    }

    func testFullTurnFollowsTheHooks() throws {
        let store = makeStore()
        store.handle(CodexFixtures.event("SessionStart"), context: CodexFixtures.terminal, now: t0)
        var session = try XCTUnwrap(store.sessions[sid])
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.projectName, "mon-app")
        XCTAssertEqual(session.model, "gpt-6-astra")
        XCTAssertEqual(session.hostName, "iTerm2")
        XCTAssertEqual(session.sourceLabel, "iTerm2")
        XCTAssertEqual(store.indicator, .none)

        store.handle(CodexFixtures.event("UserPromptSubmit", ["prompt": "Lance les tests\n  puis résume"]),
                     context: CodexFixtures.terminal, now: t0.addingTimeInterval(1))
        session = try XCTUnwrap(store.sessions[sid])
        XCTAssertEqual(session.phase, .working)
        XCTAssertTrue(session.inTurn)
        XCTAssertEqual(session.lastPrompt, "Lance les tests puis résume", "une ligne, espaces normalisés")
        XCTAssertEqual(store.indicator, .working)

        store.handle(CodexFixtures.bash("swift test --parallel"), context: CodexFixtures.terminal,
                     now: t0.addingTimeInterval(2))
        session = try XCTUnwrap(store.sessions[sid])
        XCTAssertEqual(session.currentTool?.detail, "swift test --parallel")
        XCTAssertEqual(session.status.detail, "swift test --parallel")
        XCTAssertTrue(session.status.isCode)

        store.handle(CodexFixtures.bash("swift test --parallel", "PostToolUse"), context: CodexFixtures.terminal,
                     now: t0.addingTimeInterval(9))
        session = try XCTUnwrap(store.sessions[sid])
        XCTAssertNil(session.currentTool)
        XCTAssertEqual(session.toolCount, 1)

        store.handle(CodexFixtures.event("Stop", ["stop_hook_active": false, "last_assistant_message": "42 tests passent."]),
                     context: CodexFixtures.terminal, now: t0.addingTimeInterval(10))
        session = try XCTUnwrap(store.sessions[sid])
        XCTAssertEqual(session.phase, .done)
        XCTAssertFalse(session.inTurn)
        XCTAssertEqual(session.lastMessage, "42 tests passent.")
        XCTAssertEqual(try XCTUnwrap(session.lastTurnDuration), 9, accuracy: 0.001)
        XCTAssertEqual(session.doneFlashUntil, t0.addingTimeInterval(10 + CodexStore.doneFlashDuration))

        store.handle(CodexFixtures.event("SessionEnd"), context: CodexFixtures.terminal, now: t0.addingTimeInterval(11))
        XCTAssertEqual(store.sessions[sid]?.phase, .ended)
    }

    func testApprovalWaitsThenResumes() throws {
        let store = makeStore()
        store.handle(CodexFixtures.event("UserPromptSubmit", ["prompt": "Crée le fichier"]),
                     context: CodexFixtures.terminal, now: t0)
        store.handle(CodexFixtures.bash("touch marker.txt"), context: CodexFixtures.terminal, now: t0.addingTimeInterval(1))
        let tool = CodexTools.describe(name: "Bash", input: ["command": "touch marker.txt"])
        store.markWaiting(sessionId: sid, tool: tool, context: CodexFixtures.terminal, cwd: CodexFixtures.cwd,
                          now: t0.addingTimeInterval(2))
        var session = try XCTUnwrap(store.sessions[sid])
        XCTAssertEqual(session.phase, .waitingApproval)
        XCTAssertTrue(session.phase.needsAttention)
        XCTAssertEqual(store.indicator, .attention)
        XCTAssertEqual(session.status.label, L("Attend ton approbation", table: "Codex"))
        XCTAssertEqual(session.status.detail, "touch marker.txt")
        XCTAssertEqual(store.sortedSessions.first?.id, sid)

        // Autorisé dans la notch : Codex travaille de nouveau, puis l'outil se termine.
        store.resolveApproval(sid, now: t0.addingTimeInterval(3))
        XCTAssertEqual(store.sessions[sid]?.phase, .working)
        // Autorisé dans le terminal : c'est le PostToolUse qui le dit.
        store.markWaiting(sessionId: sid, tool: tool, context: CodexFixtures.terminal, cwd: nil, now: t0.addingTimeInterval(4))
        store.handle(CodexFixtures.bash("touch marker.txt", "PostToolUse"), context: CodexFixtures.terminal,
                     now: t0.addingTimeInterval(6))
        session = try XCTUnwrap(store.sessions[sid])
        XCTAssertEqual(session.phase, .working)
        XCTAssertNil(session.attention)
    }

    /// Mesuré avec le vrai Codex : le relais asynchrone d'un `PreToolUse` arrive après le `PermissionRequest` synchrone
    /// du même appel. Il ne doit pas effacer l'attente ; passé le court délai, un événement d'outil la lève.
    func testAsyncRelaysArrivingAfterThePermissionDoNotEraseTheWait() throws {
        let store = makeStore()
        store.handle(CodexFixtures.event("UserPromptSubmit", ["prompt": "x"]), context: CodexFixtures.terminal, now: t0)
        let tool = CodexTools.describe(name: "Bash", input: ["command": "touch marker.txt"])
        store.markWaiting(sessionId: sid, tool: tool, context: CodexFixtures.terminal, cwd: nil, now: t0.addingTimeInterval(1))

        store.handle(CodexFixtures.bash("touch marker.txt"), context: CodexFixtures.terminal, now: t0.addingTimeInterval(1.1))
        XCTAssertEqual(store.sessions[sid]?.phase, .waitingApproval, "PreToolUse tardif du même appel")
        store.handle(CodexFixtures.bash("ls", "PostToolUse"), context: CodexFixtures.terminal, now: t0.addingTimeInterval(1.2))
        XCTAssertEqual(store.sessions[sid]?.phase, .waitingApproval, "PostToolUse tardif de l'outil d'avant")
        XCTAssertEqual(store.sessions[sid]?.toolCount, 1, "mais il est compté")
        XCTAssertEqual(store.sessions[sid]?.status.detail, "touch marker.txt")
        XCTAssertEqual(store.indicator, .attention)

        // Approuvé dans le terminal : le PostToolUse arrive bien après le délai.
        store.handle(CodexFixtures.bash("touch marker.txt", "PostToolUse"), context: CodexFixtures.terminal,
                     now: t0.addingTimeInterval(1 + CodexStore.reorderWindow + 0.1))
        XCTAssertEqual(store.sessions[sid]?.phase, .working)
        XCTAssertNil(store.sessions[sid]?.attention)
        XCTAssertNil(store.sessions[sid]?.waitingSince)
    }

    func testInterruptReturnsToReady() throws {
        let store = makeStore()
        store.handle(CodexFixtures.event("UserPromptSubmit", ["prompt": "Refactore"]), context: CodexFixtures.terminal, now: t0)
        store.handle(CodexFixtures.event("Interrupt"), context: CodexFixtures.terminal, now: t0.addingTimeInterval(3))
        let session = try XCTUnwrap(store.sessions[sid])
        XCTAssertEqual(session.phase, .ready)
        XCTAssertFalse(session.inTurn)
        XCTAssertNil(session.currentTool)
        XCTAssertEqual(store.indicator, .none)
    }

    /// App lancée en cours de tour : un PreToolUse suffit à retrouver la session, sans SessionStart.
    func testSessionDiscoveredMidTurn() throws {
        let store = makeStore()
        store.handle(CodexFixtures.bash("ls"), context: CodexFixtures.terminal, now: t0)
        let session = try XCTUnwrap(store.sessions[sid])
        XCTAssertEqual(session.phase, .working)
        XCTAssertTrue(session.inTurn)
        XCTAssertEqual(session.turnStart, t0)
    }

    func testEndedSessionIgnoresLateEventsUntilItIsResumed() throws {
        let store = makeStore()
        store.handle(CodexFixtures.event("SessionStart"), context: CodexFixtures.terminal, now: t0)
        store.handle(CodexFixtures.event("SessionEnd"), context: CodexFixtures.terminal, now: t0.addingTimeInterval(1))
        store.handle(CodexFixtures.event("Stop", ["last_assistant_message": "trop tard"]),
                     context: CodexFixtures.terminal, now: t0.addingTimeInterval(2))
        XCTAssertEqual(store.sessions[sid]?.phase, .ended)
        XCTAssertNil(store.sessions[sid]?.lastMessage, "événement tardif ignoré")

        store.handle(CodexFixtures.event("SessionStart", ["source": "resume"]), context: CodexFixtures.terminal,
                     now: t0.addingTimeInterval(60))
        XCTAssertEqual(store.sessions[sid]?.phase, .ready, "reprise de la session")
        XCTAssertNil(store.sessions[sid]?.endedAt, "reprise : plus de retrait programmé")
        store.expire(now: t0.addingTimeInterval(60 + CodexStore.endedLinger + 5))
        XCTAssertNotNil(store.sessions[sid], "la session reprise n'est pas oubliée avec les finies")
    }

    func testSessionEndWithoutSessionCreatesNothing() {
        let store = makeStore()
        store.handle(CodexFixtures.event("SessionEnd"), context: CodexFixtures.terminal, now: t0)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(store.isTicking)
    }

    func testStoppedStoreIgnoresEventsAndForgetsEverything() {
        let store = CodexStore()
        store.handle(CodexFixtures.event("UserPromptSubmit", ["prompt": "x"]), context: CodexFixtures.terminal, now: t0)
        XCTAssertTrue(store.sessions.isEmpty, "pas démarré : rien n'est suivi")

        store.start()
        store.handle(CodexFixtures.event("UserPromptSubmit", ["prompt": "x"]), context: CodexFixtures.terminal)
        XCTAssertEqual(store.sessions.count, 1)
        store.stop()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(store.isTicking, "onglet désactivé : aucune minuterie")
        store.handle(CodexFixtures.event("Stop"), context: CodexFixtures.terminal)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    /// Au repos : aucune minuterie. En tour : aucune non plus (rien de périodique) ; seules la fin du « Terminé » et le
    /// retrait d'une session finie arment une échéance unique.
    func testNoTimerExceptOneShotDeadlines() {
        let store = makeStore()
        store.handle(CodexFixtures.event("UserPromptSubmit", ["prompt": "x"]), context: CodexFixtures.terminal)
        XCTAssertFalse(store.isTicking, "un tour en cours n'arme rien (session sans pid : retrait à 3 h seulement)")
        store.handle(CodexFixtures.event("Stop", ["last_assistant_message": "ok"]), context: CodexFixtures.terminal)
        XCTAssertTrue(store.isTicking, "fin du « Terminé » dans 5 s")
        store.stop()
        XCTAssertFalse(store.isTicking)
    }

    func testDoneFlashAndEndedLingerExpire() throws {
        let store = makeStore()
        store.handle(CodexFixtures.event("Stop", ["last_assistant_message": "ok"]), context: CodexFixtures.terminal, now: t0)
        XCTAssertEqual(try XCTUnwrap(store.sessions[sid]).doneFlashUntil, t0.addingTimeInterval(5))
        store.handle(CodexFixtures.event("SessionEnd"), context: CodexFixtures.terminal, now: t0.addingTimeInterval(6))
        store.expire(now: t0.addingTimeInterval(7))
        XCTAssertNotNil(store.sessions[sid], "encore affichée pendant le délai de grâce")
        store.expire(now: t0.addingTimeInterval(6 + CodexStore.endedLinger + 1))
        XCTAssertNil(store.sessions[sid], "session finie oubliée")
        XCTAssertFalse(store.isTicking)
    }

    func testOrphanSessionWithoutProcessIsForgottenAfterThreeHours() {
        let store = makeStore()
        store.handle(CodexFixtures.event("SessionStart"), context: CodexFixtures.terminal, now: t0)
        store.expire(now: t0.addingTimeInterval(CodexStore.orphanTimeout - 1))
        XCTAssertNotNil(store.sessions[sid])
        store.expire(now: t0.addingTimeInterval(CodexStore.orphanTimeout + 1))
        XCTAssertNil(store.sessions[sid])
    }

    func testProcessExitEndsItsSessionsOnly() throws {
        let store = makeStore()
        let alive = Process()
        alive.executableURL = URL(fileURLWithPath: "/bin/sleep")
        alive.arguments = ["30"]
        try alive.run()
        defer { alive.terminate() }
        let other = CodexContext(pid: alive.processIdentifier, start: nil, hostName: "Terminal", hostBundleId: nil)
        store.handle(CodexFixtures.event("UserPromptSubmit", session: "a", ["prompt": "x"]), context: other, now: t0)
        store.handle(CodexFixtures.event("UserPromptSubmit", session: "b", ["prompt": "y"]), context: CodexFixtures.terminal,
                     now: t0)
        XCTAssertEqual(store.trackedPids, [alive.processIdentifier])

        // Fin réelle du processus, détectée par kqueue (aucune scrutation).
        alive.terminate()
        XCTAssertTrue(spin { store.sessions["a"]?.phase == .ended }, "le processus Codex s'arrête : session finie")
        XCTAssertEqual(store.sessions["b"]?.phase, .working, "l'autre session n'est pas touchée")
    }

    func testSortingAndCounts() {
        let store = makeStore()
        store.handle(CodexFixtures.event("Stop", session: "fini", ["last_assistant_message": "ok"]),
                     context: CodexFixtures.terminal, now: t0)
        store.handle(CodexFixtures.event("UserPromptSubmit", session: "travaille", ["prompt": "x"]),
                     context: CodexFixtures.terminal, now: t0.addingTimeInterval(1))
        store.handle(CodexFixtures.event("UserPromptSubmit", session: "attend", ["prompt": "y"]),
                     context: CodexFixtures.terminal, now: t0.addingTimeInterval(2))
        store.markWaiting(sessionId: "attend", tool: CodexTools.describe(name: "Bash", input: ["command": "ls"]),
                          context: CodexFixtures.terminal, cwd: nil, now: t0.addingTimeInterval(3))
        XCTAssertEqual(store.sortedSessions.map(\.id), ["attend", "travaille", "fini"])
        XCTAssertEqual(store.activeCount, 2)
        XCTAssertTrue(store.hasActivity)
        XCTAssertEqual(store.indicator, .attention)
    }

    // MARK: - Description des outils

    func testToolDescriptions() {
        let bash = CodexTools.describe(name: "Bash", input: ["command": "  git status \n", "description": "x"])
        XCTAssertEqual(bash.detail, "git status")
        XCTAssertTrue(bash.isCode)

        let patch = "*** Begin Patch\n*** Update File: Sources/App/main.swift\n@@\n-a\n+b\n*** Add File: docs/NOTES.md\n+x\n*** End Patch"
        let edit = CodexTools.describe(name: "apply_patch", input: ["command": patch])
        XCTAssertEqual(edit.detail, "main.swift +1")
        XCTAssertEqual(CodexTools.patchedFiles(patch), ["main.swift", "NOTES.md"])

        let mcp = CodexTools.describe(name: "mcp__filesystem__read_file", input: ["path": "/x"])
        XCTAssertEqual(mcp.label, "filesystem")
        XCTAssertEqual(mcp.detail, "read_file")

        XCTAssertEqual(CodexTools.describe(name: "update_plan", input: nil).label, "update_plan")

        let long = CodexTools.describe(name: "Bash", input: ["command": String(repeating: "x", count: 900)])
        XCTAssertEqual(long.detail?.count, CodexTools.maxDetail + 1, "commande bornée, « … » ajouté")
        XCTAssertTrue(long.detail?.hasSuffix("…") ?? false)
    }

    func testOneLineIsBounded() {
        XCTAssertEqual(CodexStore.oneLine("a\n\nb   c"), "a b c")
        XCTAssertEqual(CodexStore.oneLine(String(repeating: "m", count: 400)).count, CodexStore.maxMessage + 1)
    }
}
