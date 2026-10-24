import XCTest
@testable import Oriel

/// Conversation d'une session (répliques des hooks), activation des réponses et rendu du Markdown en ligne.
final class ClaudeConversationTests: XCTestCase {
    private let store = SessionStore()
    private let context = ProcessContext(source: .desktop, hostName: nil, hostBundleId: nil)

    private func send(_ name: String, _ extra: [String: Any] = [:]) {
        store.send(name, "s1", extra, context: context)
    }

    private var conversation: [Utterance] { store.sessions["s1"]?.conversation ?? [] }

    func testStopAndPromptBuildTheConversation() {
        send("UserPromptSubmit", ["prompt": "Mets à jour le README"])
        send("Stop", ["last_assistant_message": "C'est fait.\n\n- section **installation** réécrite"])
        XCTAssertEqual(conversation.map(\.speaker), [.you, .claude])
        XCTAssertEqual(conversation[0].text, "Mets à jour le README")
        XCTAssertEqual(conversation[1].text, "C'est fait.\n\n- section **installation** réécrite", "texte entier, pas la première ligne")
        XCTAssertEqual(store.sessions["s1"]?.lastMessage, "C'est fait.", "la carte garde la première ligne")
    }

    func testBackgroundResultsAreNotYourWords() {
        send("UserPromptSubmit", ["prompt": "<task-notification>\n<summary>Agent terminé</summary>\n</task-notification>"])
        XCTAssertTrue(conversation.isEmpty)
    }

    func testMessageSentFromTheNotchIsYours() {
        let prompt = "<task-notification>\n<summary>\(HookInstaller.rewakeSummary)</summary>\n</task-notification>\n"
            + "<system-reminder>\n\(HookInstaller.rewakeMessage) Lance les tests</system-reminder>"
        send("UserPromptSubmit", ["prompt": prompt])
        XCTAssertEqual(conversation.map(\.speaker), [.you])
        XCTAssertEqual(conversation.first?.text, "Lance les tests")
    }

    func testSubagentsSpeakUnderTheirType() {
        send("SubagentStart", ["agent_id": "a1", "agent_type": "Explore"])
        send("SubagentStop", ["agent_id": "a1", "agent_type": "Explore", "last_assistant_message": "3 fichiers trouvés"])
        XCTAssertEqual(conversation.map(\.speaker), [.agent("Explore")])
        // Agents internes (type vide) : ignorés, comme pour le décompte.
        send("SubagentStop", ["agent_type": "", "last_assistant_message": "suggestion de prompt"])
        XCTAssertEqual(conversation.count, 1)
    }

    func testTheSameLineIsNotRepeatedAndOnlyTheLatestAreKept() {
        send("Stop", ["last_assistant_message": "Fini"])
        send("Stop", ["last_assistant_message": "Fini"])
        XCTAssertEqual(conversation.count, 1, "hook relancé : pas de doublon")
        for index in 1...10 { send("Stop", ["last_assistant_message": "Réponse \(index)"]) }
        XCTAssertEqual(conversation.count, Utterance.maxCount)
        XCTAssertEqual(conversation.last?.text, "Réponse 10")
        XCTAssertEqual(conversation.first?.text, "Réponse 5")
    }

    func testLongTextIsBoundedAndEmptyOnesAreSkipped() {
        send("Stop", ["last_assistant_message": String(repeating: "é", count: 20_000)])
        XCTAssertEqual(conversation.last?.text.count, Utterance.maxLength)
        XCTAssertTrue(conversation.last?.text.hasSuffix("…") ?? false)
        send("Stop", ["last_assistant_message": "  \n "])
        send("Stop", [:])
        XCTAssertEqual(conversation.count, 1)
    }

    // MARK: - Activation des réponses

    func testRepliesPromptIsRememberedOnceDismissed() {
        let defaults = makeEphemeralDefaults(self)
        let prefs = Preferences(defaults: defaults)
        XCTAssertFalse(prefs.replyPromptDismissed)
        prefs.replyPromptDismissed = true
        XCTAssertTrue(Preferences(defaults: defaults).replyPromptDismissed)
    }

    func testHooksRepairDependsOnTheirStatus() {
        XCTAssertEqual(HookSetup.repairNeeded(for: .installed), .none)
        XCTAssertEqual(HookSetup.repairNeeded(for: .outdated), .update)
        XCTAssertEqual(HookSetup.repairNeeded(for: .scriptOutdated), .update)
        XCTAssertEqual(HookSetup.repairNeeded(for: .notInstalled), .install)
        XCTAssertEqual(HookSetup.repairNeeded(for: .unreadable("x")), .install)
    }

    // MARK: - Texte

    func testInlineMarkdownIsRenderedAndHeadingsLoseTheirHashes() {
        let rendered = String(UtteranceBubble.rendered("## Bilan\nLe **gras** et `du code`").characters)
        XCTAssertEqual(rendered, "Bilan\nLe gras et du code")
        XCTAssertEqual(String(UtteranceBubble.rendered("Pas de dièse # au milieu").characters), "Pas de dièse # au milieu")
    }
}
