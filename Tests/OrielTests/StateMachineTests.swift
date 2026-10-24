import XCTest
@testable import Oriel

/// Machine à états, avec des payloads calqués sur ceux capturés (Claude Code 2.1.299).
final class StateMachineTests: XCTestCase {
    private var store: SessionStore!
    private let sid = "f34e31e3-eb3c-43d5-ae38-2a4738e4b486"
    private var transcriptPath = "/nonexistent/projects/p/x.jsonl"

    override func setUp() {
        store = SessionStore()
    }

    private func send(_ name: String, _ extra: [String: Any] = [:], session: String? = nil) {
        var raw: [String: Any] = [
            "hook_event_name": name, "session_id": session ?? sid, "cwd": "/Users/x/proj",
            "transcript_path": transcriptPath, "prompt_id": "p",
        ]
        raw.merge(extra) { $1 }
        store.handle(HookEvent(raw: raw), context: ProcessContext())
    }

    private var session: Session { store.sessions[sid]! }

    /// Sans session, le timer d'une seconde s'arrête : aucun réveil inutile.
    func testTimerRunsOnlyWithSessions() {
        store.start()
        XCTAssertFalse(store.isTicking)
        send("SessionStart", ["source": "startup"])
        XCTAssertTrue(store.isTicking)
        send("SessionEnd", ["reason": "exit"])
        XCTAssertTrue(store.isTicking, "session terminée encore affichée")
        store.tick(now: Date().addingTimeInterval(SessionStore.endedLinger + 1))
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(store.isTicking)
    }

    func testPermissionWithoutToolUseId() {
        send("SessionStart", ["source": "startup", "model": "claude-sonnet-5-5"])
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.projectName, "proj")

        send("UserPromptSubmit", ["prompt": "crée sub", "permission_mode": "default"])
        send("PreToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_1",
                            "tool_input": ["command": "mkdir sub && touch sub/x", "description": "Crée sub"]])
        XCTAssertEqual(session.phase, .tool)
        XCTAssertEqual(session.currentTool?.text, "Terminal · Crée sub")

        // PermissionRequest n'a pas de tool_use_id : on se rattache au dernier Bash actif.
        send("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "mkdir sub && touch sub/x"],
                                   "permission_suggestions": []])
        XCTAssertEqual(session.phase, .waitingPermission)
        XCTAssertEqual(session.attentionToolId, "toolu_1")
        XCTAssertEqual(store.indicator, .attention)

        send("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission"])
        XCTAssertEqual(session.phase, .waitingPermission)

        send("PostToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_1", "tool_response": ["stdout": ""]])
        XCTAssertEqual(session.phase, .thinking)
        XCTAssertNil(session.attentionText)
        XCTAssertEqual(session.toolCount, 1)

        send("Stop", ["last_assistant_message": "**Fait.** Le dossier `sub` existe.", "stop_hook_active": false])
        XCTAssertEqual(session.phase, .done)
        XCTAssertFalse(session.inTurn)
        XCTAssertEqual(session.lastMessage, "Fait. Le dossier sub existe.")
        XCTAssertEqual(store.indicator, .done)
    }

    func testAsyncReorderingIgnoresLatePreToolUse() {
        send("UserPromptSubmit", ["prompt": "ls"])
        send("PostToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_2"])
        send("PreToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_2", "tool_input": ["command": "ls"]])
        XCTAssertTrue(session.activeTools.isEmpty)
        XCTAssertEqual(session.phase, .thinking)
    }

    func testAskUserQuestionAndItsPermissionRequest() {
        send("UserPromptSubmit", ["prompt": "pose-moi une question"])
        let input: [String: Any] = ["questions": [["question": "Pick a color", "header": "Color", "multiSelect": false,
                                                   "options": [["label": "Red", "description": "r"]]]]]
        send("PreToolUse", ["tool_name": "AskUserQuestion", "tool_use_id": "toolu_q", "tool_input": input])
        XCTAssertEqual(session.phase, .waitingAnswer)
        XCTAssertEqual(session.attentionText, "Pick a color")

        send("PermissionRequest", ["tool_name": "AskUserQuestion", "tool_input": input])
        XCTAssertEqual(session.phase, .waitingAnswer)

        send("PostToolUse", ["tool_name": "AskUserQuestion", "tool_use_id": "toolu_q",
                             "tool_response": ["answers": ["Pick a color": "Red"]]])
        XCTAssertEqual(session.phase, .thinking)
    }

    func testPlanReview() {
        send("UserPromptSubmit", ["prompt": "planifie", "permission_mode": "plan"])
        send("PreToolUse", ["tool_name": "ExitPlanMode", "tool_use_id": "toolu_p",
                            "tool_input": ["plan": "# Plan\n\n1. Ajouter **une ligne**\n2. Relancer", "planFilePath": "/x.md"]])
        XCTAssertEqual(session.phase, .planReview)
        XCTAssertEqual(session.attentionText, "Plan")
        send("Notification", ["notification_type": "permission_prompt",
                              "message": "Claude Code needs your approval for the plan"])
        XCTAssertEqual(session.phase, .planReview)
    }

    func testFailureAndApiError() {
        send("UserPromptSubmit", ["prompt": "ls"])
        send("PreToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_f", "tool_input": ["command": "ls /nope"]])
        send("PostToolUseFailure", ["tool_name": "Bash", "tool_use_id": "toolu_f",
                                    "error": "Exit code 1\nls: /nope: No such file or directory", "is_interrupt": false])
        XCTAssertEqual(session.phase, .thinking)
        XCTAssertTrue(session.inTurn)

        send("StopFailure", ["error": "model_not_found", "last_assistant_message": "API Error"])
        XCTAssertEqual(session.phase, .error)
        XCTAssertEqual(session.errorText, "model_not_found")
        XCTAssertFalse(session.inTurn)
    }

    func testInterruptFlagOnFailure() {
        send("UserPromptSubmit", ["prompt": "long"])
        send("PreToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_i", "tool_input": ["command": "sleep 9"]])
        send("PostToolUseFailure", ["tool_name": "Bash", "tool_use_id": "toolu_i", "error": "x", "is_interrupt": true])
        XCTAssertEqual(session.phase, .ready)
        XCTAssertFalse(session.inTurn)
    }

    func testSubagentsIgnoreInternalAgents() {
        send("UserPromptSubmit", ["prompt": "délègue"])
        send("SubagentStop", ["agent_id": "internal", "agent_type": ""])
        send("SubagentStart", ["agent_id": "aeb97", "agent_type": "general-purpose"])
        XCTAssertEqual(session.activeAgents, ["aeb97"])
        send("SubagentStop", ["agent_id": "zzz", "agent_type": ""])
        XCTAssertEqual(session.activeAgents.count, 1)

        // Agent en arrière-plan : Stop avant SubagentStop, puis résultat sous forme de faux prompt.
        send("Stop", ["last_assistant_message": "J'ai lancé l'agent."])
        XCTAssertEqual(session.phase, .done)
        send("SubagentStop", ["agent_id": "aeb97", "agent_type": "general-purpose"])
        XCTAssertTrue(session.activeAgents.isEmpty)
        send("UserPromptSubmit", ["prompt": "<task-notification>\n<task-id>aeb97</task-id>\n</task-notification>"])
        XCTAssertEqual(session.phase, .thinking)
        XCTAssertEqual(session.lastPrompt, "résultat d'un agent en arrière-plan")
    }

    func testCompactRestoresPhase() {
        send("SessionStart", ["source": "startup"])
        send("UserPromptSubmit", ["prompt": "x"])
        send("Stop", ["last_assistant_message": "ok"])
        send("PreCompact", ["trigger": "manual", "custom_instructions": NSNull()])
        XCTAssertEqual(session.phase, .compacting)
        XCTAssertEqual(store.indicator, .working)
        send("SubagentStop", ["agent_id": "c", "agent_type": ""])
        send("SessionStart", ["source": "compact", "model": "claude-sonnet-5-5"])
        XCTAssertEqual(session.phase, .done)
        send("PostCompact", ["trigger": "manual", "compact_summary": "…"])
        XCTAssertEqual(session.phase, .done)
    }

    func testSessionEndIgnoresLateEventsUntilRestart() {
        send("SessionStart", ["source": "startup"])
        send("SessionEnd", ["reason": "prompt_input_exit"])
        XCTAssertEqual(session.phase, .ended)
        XCTAssertFalse(store.hasLiveSessions)
        send("PostToolUse", ["tool_name": "Bash", "tool_use_id": "late"])
        XCTAssertEqual(session.phase, .ended)
        send("SessionStart", ["source": "resume"])
        XCTAssertEqual(session.phase, .ready)
    }

    func testTodoWriteAndEars() {
        send("UserPromptSubmit", ["prompt": "x"])
        send("PreToolUse", ["tool_name": "TodoWrite", "tool_use_id": "t", "tool_input": ["todos": [
            ["content": "A", "status": "completed", "activeForm": "Fait A"],
            ["content": "B", "status": "in_progress", "activeForm": "Fait B"],
            ["content": "C", "status": "weird"],
        ]]])
        XCTAssertEqual(session.tasks.map(\.subject), ["A", "B"])
        XCTAssertEqual(session.currentTask?.activeForm, "Fait B")
        XCTAssertEqual(store.earsText, "1/2")
    }

    func testEarsShowSessionsAndAgents() {
        send("UserPromptSubmit", ["prompt": "lance un workflow"])
        XCTAssertEqual(store.earsText, "1")
        for index in 0..<6 {
            send("SubagentStart", ["agent_id": "a\(index)", "agent_type": "workflow-subagent"])
        }
        XCTAssertEqual(store.ears, SessionStore.EarsContent(tasks: nil, sessions: 1, agents: 6))
        XCTAssertEqual(store.earsText, "1·6")

        // Agents en arrière-plan après le Stop : la session n'est plus active, les agents comptent encore.
        send("Stop", ["last_assistant_message": "lancé"])
        XCTAssertEqual(store.earsText, "0·6")
        for index in 0..<6 { send("SubagentStop", ["agent_id": "a\(index)", "agent_type": "workflow-subagent"]) }
        XCTAssertNil(store.earsText)
    }

    func testTaskFilesOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let list = root.appendingPathComponent("tasks/\(sid)")
        try FileManager.default.createDirectory(at: list, withIntermediateDirectories: true)
        try "3".write(to: list.appendingPathComponent(".highwatermark"), atomically: true, encoding: .utf8)
        try Data().write(to: list.appendingPathComponent(".lock"))
        let files: [(String, String)] = [
            ("10", #"{"id":"10","subject":"dix","description":"d","status":"pending","blocks":[],"blockedBy":[]}"#),
            ("2", #"{"id":"2","subject":"deux","description":"d","status":"in_progress","blocks":[],"blockedBy":[]}"#),
            ("3", #"{"id":3,"subject":"trois","status":"deleted"}"#),
        ]
        for (name, json) in files {
            try json.write(to: list.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8)
        }
        transcriptPath = root.appendingPathComponent("projects/-Users-x-proj/\(sid).jsonl").path
        send("SessionStart", ["source": "startup"])

        XCTAssertEqual(TaskListLoader.configDir(for: session).standardizedFileURL, root.standardizedFileURL)
        let tasks = try XCTUnwrap(TaskListLoader.load(for: session))
        XCTAssertEqual(tasks.map(\.id), ["2", "10"])
        XCTAssertEqual(tasks.first?.status, .inProgress)
    }

    func testEscInterruptionFromTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("projects/p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcript = dir.appendingPathComponent("\(sid).jsonl")
        try Data(#"{"type":"user","message":{"role":"user","content":"[Request interrupted by user] ancien"}}"#.utf8 + [0x0A])
            .write(to: transcript)
        transcriptPath = transcript.path

        send("UserPromptSubmit", ["prompt": "dors"])
        send("PreToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_s", "tool_input": ["command": "sleep 25"]])
        store.tick()
        XCTAssertEqual(session.phase, .tool, "l'ancien marqueur, avant le tour, est ignoré")

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        let lines = [
            #"{"type":"ai-title","aiTitle":"Hello.txt file edits","sessionId":"x"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"The user doesn't want to proceed","is_error":true,"tool_use_id":"toolu_s"}]},"toolUseResult":"User rejected tool use"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"interruptedMessageId":"msg_1"}"#,
        ]
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()

        store.tick()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertFalse(session.inTurn)
        XCTAssertEqual(session.title, "Hello.txt file edits")
    }

    /// Rejoue le log brut capturé (`ORIEL_REPLAY_LOG`) : aucun plantage, états finaux plausibles.
    func testReplayCapturedLog() throws {
        guard let path = ProcessInfo.processInfo.environment["ORIEL_REPLAY_LOG"] else {
            throw XCTSkip("ORIEL_REPLAY_LOG non défini")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var count = 0
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            store.handle(HookEvent(raw: payload), context: ProcessContext())
            count += 1
        }
        XCTAssertGreaterThan(count, 0)
        for session in store.sortedSessions {
            print("REPLAY \(session.id.prefix(8)) phase=\(session.phase) tours=\(session.toolCount) "
                  + "agents=\(session.activeAgents.count) msg=\(session.lastMessage ?? "-") err=\(session.errorText ?? "-")")
        }
    }
}
