import Carbon.HIToolbox
import Combine
import Foundation
import XCTest
@testable import Oriel

/// « Approuver au clavier » : aucune décision ne part sans l'appui attendu, sur la carte attendue, après la garde.
/// Les touches sont un double de `HotKeyCenter` (un appui n'atteint l'app que si la combinaison est enregistrée),
/// l'horloge est la nôtre : rien de réel (ni raccourci système, ni fenêtre).
final class ApprovalQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Double de `HotKeyCenter` : ce que macOS ferait d'un appui.
    private final class FakeKeys: HotKeyRegistering {
        var registered: [HotKeyCenter.Slot: HotKeyChoice] = [:]
        private var actions: [HotKeyCenter.Slot: () -> Void] = [:]
        var refuse = false

        func set(_ choice: HotKeyChoice, for slot: HotKeyCenter.Slot, action: @escaping () -> Void) -> Bool {
            registered[slot] = nil
            actions[slot] = nil
            guard choice != .none else { return true }
            guard !refuse else { return false }
            registered[slot] = choice
            actions[slot] = action
            return true
        }

        /// Appui physique : sans enregistrement, l'app ne reçoit rien.
        func press(_ slot: HotKeyCenter.Slot) { actions[slot]?() }
    }

    /// Deux files fictives (Claude, Codex), reliées à une vraie `ApprovalQueue`.
    private final class Harness {
        let prefs: Preferences
        let keys = FakeKeys()
        let queue: ApprovalQueue
        var now: Date
        let claude = CurrentValueSubject<[ApprovalEntry], Never>([])
        let codex = CurrentValueSubject<[ApprovalEntry], Never>([])
        var decided: [(id: UUID, allow: Bool)] = []
        var revealed: [String] = []

        init(_ testCase: XCTestCase, start: Date, enabled: Bool = true) {
            prefs = Preferences(defaults: makeEphemeralDefaults(testCase))
            prefs.approveByKeyboard = enabled
            now = start
            queue = ApprovalQueue(prefs: prefs, keys: keys)
            queue.clock = { [unowned self] in self.now }
            // Comme les vrais `decide` : la demande réglée sort de sa file.
            func source(_ tab: String, _ subject: CurrentValueSubject<[ApprovalEntry], Never>) -> ApprovalSource {
                ApprovalSource(tab: tab, entries: subject.eraseToAnyPublisher()) { [unowned self] id, allow in
                    self.decided.append((id, allow))
                    subject.value.removeAll { $0.id == id }
                }
            }
            queue.attach([source("claude", claude), source("codex", codex)]) { [unowned self] in self.revealed.append($0) }
        }

        @discardableResult
        func add(_ subject: CurrentValueSubject<[ApprovalEntry], Never>, at offset: TimeInterval = 0) -> UUID {
            let id = UUID()
            subject.value.append(ApprovalEntry(id: id, received: now.addingTimeInterval(offset)))
            return id
        }

        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
        func approve() { keys.press(.approve) }
        func deny() { keys.press(.deny) }
    }

    private func harness(enabled: Bool = true) -> Harness { Harness(self, start: t0, enabled: enabled) }

    // MARK: - Touches : prises seulement tant qu'une demande attend

    func testKeysAreTakenOnlyWhileARequestWaits() {
        let h = harness()
        XCTAssertTrue(h.keys.registered.isEmpty, "aucune demande : les touches ne sont prises à personne")
        let id = h.add(h.claude)
        XCTAssertEqual(h.keys.registered[.approve], .controlOptionY)
        XCTAssertEqual(h.keys.registered[.deny], .controlOptionN)
        XCTAssertEqual(h.queue.keyedId, id)
        h.claude.value = []
        XCTAssertTrue(h.keys.registered.isEmpty, "demande réglée ailleurs : touches rendues")
        XCTAssertNil(h.queue.keyedId)
    }

    func testSettingIsOffByDefaultAndTakesNothing() {
        XCTAssertFalse(Preferences(defaults: makeEphemeralDefaults(self)).approveByKeyboard)
        let h = harness(enabled: false)
        let id = h.add(h.claude)
        h.queue.cardAppeared(id)
        h.advance(30)
        XCTAssertTrue(h.keys.registered.isEmpty)
        XCTAssertNil(h.queue.keyedId)
        h.approve()
        h.queue.press(allow: true)
        XCTAssertTrue(h.decided.isEmpty, "réglage éteint : même un appel direct ne décide rien")
        XCTAssertTrue(h.revealed.isEmpty)

        h.prefs.approveByKeyboard = true
        XCTAssertEqual(h.keys.registered.count, 2)
        h.prefs.approveByKeyboard = false
        XCTAssertTrue(h.keys.registered.isEmpty, "réglage coupé pendant une demande : touches rendues")
    }

    func testRefusedCombinationShowsNoKeyOnTheCard() {
        let h = harness()
        h.keys.refuse = true
        h.add(h.claude)
        XCTAssertFalse(h.queue.approveLive)
        XCTAssertFalse(h.queue.denyLive)
        h.approve()
        XCTAssertTrue(h.decided.isEmpty)
    }

    // MARK: - Une touche ne décide que sur une carte vue, après la garde

    func testFirstPressOnlyRevealsTheCard() {
        let h = harness()
        h.add(h.claude, at: 0)
        h.add(h.codex, at: -5)
        h.advance(120)
        h.approve()
        h.deny()
        XCTAssertTrue(h.decided.isEmpty, "carte pas à l'écran : on la montre, on ne décide pas, même longtemps après")
        XCTAssertEqual(h.revealed, ["codex", "codex"], "l'onglet de la plus ancienne demande")
    }

    func testNothingIsDecidedWithoutAKeyPress() {
        let h = harness()
        let id = h.add(h.claude)
        h.queue.cardAppeared(id)
        h.advance(600)
        XCTAssertTrue(h.decided.isEmpty, "carte vue très longtemps, aucune touche : aucune décision")
        XCTAssertEqual(h.claude.value.count, 1)
    }

    func testGuardDelayBeforeAKeyDecides() {
        let h = harness()
        let id = h.add(h.claude)
        h.queue.cardAppeared(id)
        h.advance(0.4)
        h.approve()
        h.deny()
        XCTAssertTrue(h.decided.isEmpty, "garde de 1 s : un réflexe n'autorise rien")
        XCTAssertTrue(h.revealed.isEmpty)
        h.advance(ApprovalQueue.guardDelay - 0.4)
        h.approve()
        XCTAssertEqual(h.decided.count, 1)
        XCTAssertEqual(h.decided.first?.id, id)
        XCTAssertEqual(h.decided.first?.allow, true)
    }

    func testDenyKey() {
        let h = harness()
        let id = h.add(h.codex)
        h.queue.cardAppeared(id)
        h.advance(1.5)
        h.deny()
        XCTAssertEqual(h.decided.count, 1)
        XCTAssertEqual(h.decided.first?.id, id)
        XCTAssertEqual(h.decided.first?.allow, false)
    }

    func testCardLeavingTheScreenDisarms() {
        let h = harness()
        let id = h.add(h.claude)
        h.queue.cardAppeared(id)
        h.advance(10)
        h.queue.cardDisappeared(id)
        h.approve()
        XCTAssertTrue(h.decided.isEmpty, "panneau refermé : le premier appui montre la carte")
        XCTAssertEqual(h.revealed, ["claude"])

        h.queue.cardAppeared(id)
        h.advance(0.5)
        h.approve()
        XCTAssertTrue(h.decided.isEmpty, "elle revient : la garde repart de zéro")
        h.advance(0.6)
        h.approve()
        XCTAssertEqual(h.decided.count, 1)
    }

    // MARK: - File : plus ancienne d'abord, jamais en lot

    func testOldestRequestFirstAcrossAgents() {
        let h = harness()
        let late = h.add(h.claude, at: 5)
        let early = h.add(h.codex, at: 0)
        XCTAssertEqual(h.queue.keyedId, early)
        XCTAssertEqual(h.queue.count, 2)
        h.queue.cardAppeared(late)
        h.advance(5)
        h.approve()
        XCTAssertTrue(h.decided.isEmpty, "la carte qui a les touches n'est pas à l'écran : l'autre carte ne la remplace pas")
        XCTAssertEqual(h.revealed, ["codex"])
        h.queue.cardAppeared(early)
        h.advance(1)
        h.approve()
        XCTAssertEqual(h.decided.map(\.id), [early])
        XCTAssertEqual(h.queue.keyedId, late)
    }

    func testNeverTwoDecisionsInARow() {
        let h = harness()
        let first = h.add(h.claude, at: 0)
        let second = h.add(h.claude, at: 1)
        h.queue.cardAppeared(first)
        h.queue.cardAppeared(second)
        h.advance(30)
        h.approve()
        h.approve()
        h.approve()
        XCTAssertEqual(h.decided.map(\.id), [first], "même carte déjà visible : la suivante reprend sa garde")
        h.advance(0.9)
        h.approve()
        XCTAssertEqual(h.decided.map(\.id), [first])
        h.advance(0.2)
        h.approve()
        XCTAssertEqual(h.decided.map(\.id), [first, second])
    }

    func testRequestSettledElsewhereGivesTheKeysToTheNextWithAFreshGuard() {
        let h = harness()
        let first = h.add(h.claude, at: 0)
        let second = h.add(h.codex, at: 1)
        h.queue.cardAppeared(first)
        h.queue.cardAppeared(second)
        h.advance(20)
        // Réglée dans le terminal juste avant l'appui : la suivante ne part pas sur ce même appui.
        h.claude.value = []
        h.approve()
        XCTAssertTrue(h.decided.isEmpty)
        XCTAssertEqual(h.queue.keyedId, second)
        h.advance(1)
        h.approve()
        XCTAssertEqual(h.decided.map(\.id), [second])
    }

    // MARK: - Vrais décideurs (Claude, Codex)

    private func claudeModule(prefs: Preferences, replies: ReplyCenter) -> ClaudeModule {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("oriel-no-config")
        return ClaudeModule(store: SessionStore(), monitor: ClaudeMonitor(), tools: ToolsFeed(paths: LayoutTests.absentPaths),
                            prefs: prefs, hooks: HookSetup(installer: HookInstaller(configDirectory: config, bundledHook: nil)),
                            replies: replies)
    }

    private func decision(_ data: Data?) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
        return try XCTUnwrap((object["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
    }

    func testClaudePermissionIsDecidedByTheSameDeciderAsAClick() throws {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.replyFromNotch = true
        prefs.approveByKeyboard = true
        let replies = ReplyCenter(prefs: prefs)
        let keys = FakeKeys()
        let queue = ApprovalQueue(prefs: prefs, keys: keys)
        var now = t0
        queue.clock = { now }
        let module = claudeModule(prefs: prefs, replies: replies)
        queue.attach([.claude(module)]) { _ in }

        var answers: [Data?] = []
        replies.hold(HookEvent(raw: ["hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "Bash",
                                     "tool_input": ["command": "rm -rf build"]])) { answers.append($0) }
        let request = try XCTUnwrap(replies.requests.first)
        XCTAssertEqual(keys.registered.count, 2)

        // Rien ne part tant qu'aucune touche n'est pressée, carte vue ou non.
        queue.cardAppeared(request.id)
        now = now.addingTimeInterval(5)
        XCTAssertTrue(answers.isEmpty)

        keys.press(.approve)
        XCTAssertEqual(try decision(try XCTUnwrap(answers.first)).keys.sorted(), ["behavior"])
        XCTAssertEqual(try decision(try XCTUnwrap(answers.first))["behavior"] as? String, "allow")
        XCTAssertTrue(replies.requests.isEmpty)
        XCTAssertTrue(keys.registered.isEmpty)

        // Refus : le message par défaut, comme un clic sur « Refuser » sans motif.
        replies.hold(HookEvent(raw: ["hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "Bash",
                                     "tool_input": ["command": "git push --force"]])) { answers.append($0) }
        let second = try XCTUnwrap(replies.requests.first)
        queue.cardAppeared(second.id)
        now = now.addingTimeInterval(2)
        keys.press(.deny)
        let denied = try decision(try XCTUnwrap(answers.last))
        XCTAssertEqual(denied["behavior"] as? String, "deny")
        XCTAssertEqual(denied["message"] as? String, ReplyCenter.defaultDenyMessage)
    }

    /// Une question ou un plan demandent un choix ou un texte : ils ne passent jamais par les touches.
    func testQuestionsAndPlansStayWithTheMouse() throws {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.replyFromNotch = true
        prefs.approveByKeyboard = true
        let replies = ReplyCenter(prefs: prefs)
        let keys = FakeKeys()
        let queue = ApprovalQueue(prefs: prefs, keys: keys)
        let module = claudeModule(prefs: prefs, replies: replies)
        queue.attach([.claude(module)]) { _ in }
        var answers: [Data?] = []
        replies.hold(HookEvent(raw: ["hook_event_name": "PermissionRequest", "session_id": "s1",
                                     "tool_name": "ExitPlanMode", "tool_input": ["plan": "1. Migrer"]])) { answers.append($0) }
        replies.hold(HookEvent(raw: ["hook_event_name": "PermissionRequest", "session_id": "s2",
                                     "tool_name": "AskUserQuestion",
                                     "tool_input": ["questions": [["question": "Couleur ?", "header": "C", "multiSelect": false,
                                                                  "options": [["label": "Bleu"], ["label": "Rouge"]]]]]])) { answers.append($0) }
        XCTAssertEqual(replies.requests.count, 2)
        XCTAssertNil(queue.keyedId)
        XCTAssertEqual(queue.count, 0)
        XCTAssertTrue(keys.registered.isEmpty, "rien à régler au clavier : les touches ne sont prises à personne")
        keys.press(.approve)
        XCTAssertTrue(answers.isEmpty)
    }

    func testCodexRequestIsDecidedByTheModuleAndKeepsItsOutput() throws {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.approveByKeyboard = true
        let module = CodexModule(defaults: makeEphemeralDefaults(self))
        module.replyFromNotch = true
        let keys = FakeKeys()
        let queue = ApprovalQueue(prefs: prefs, keys: keys)
        var now = t0
        queue.clock = { now }
        var revealed: [String] = []
        queue.attach([.codex(module)]) { revealed.append($0) }

        var answers: [Data?] = []
        module.approvals.hold(CodexFixtures.bash("git push", "PermissionRequest")) { answers.append($0) }
        let request = try XCTUnwrap(module.approvals.requests.first)
        keys.press(.approve)
        XCTAssertTrue(answers.isEmpty, "carte pas à l'écran : seulement montrée")
        XCTAssertEqual(revealed, [ModuleRegistry.codexId])

        queue.cardAppeared(request.id)
        now = now.addingTimeInterval(1.2)
        keys.press(.approve)
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(try XCTUnwrap(answers.first), CodexApprovals.output(allow: true))
        XCTAssertTrue(module.approvals.requests.isEmpty)
    }

    // MARK: - Raccourcis

    func testShortcutsAreFixedAndNotOfferedInThePickers() {
        XCTAssertEqual(HotKeyChoice.controlOptionY.carbon?.keyCode, UInt32(kVK_ANSI_Y))
        XCTAssertEqual(HotKeyChoice.controlOptionN.carbon?.keyCode, UInt32(kVK_ANSI_N))
        let modifiers = UInt32(controlKey | optionKey)
        XCTAssertEqual(HotKeyChoice.controlOptionY.carbon?.modifiers, modifiers)
        XCTAssertEqual(HotKeyChoice.controlOptionN.carbon?.modifiers, modifiers)
        XCTAssertEqual(HotKeyChoice.controlOptionY.title, "⌃⌥Y")
        XCTAssertEqual(HotKeyChoice.controlOptionN.title, "⌃⌥N")
        XCTAssertFalse(HotKeyChoice.pickable.contains(.controlOptionY))
        XCTAssertFalse(HotKeyChoice.pickable.contains(.controlOptionN))
        XCTAssertEqual(HotKeyChoice.pickable.count, HotKeyChoice.allCases.count - 2)
        // Aucune des combinaisons proposées dans les réglages ne prend celles de l'approbation.
        let taken = HotKeyChoice.pickable.compactMap { $0.carbon }.filter { $0.modifiers == modifiers }
        XCTAssertFalse(taken.contains { $0.keyCode == UInt32(kVK_ANSI_Y) || $0.keyCode == UInt32(kVK_ANSI_N) })
        XCTAssertEqual(Set([HotKeyCenter.Slot.togglePanel, .toggleHidden, .approve, .deny].map(\.rawValue)).count, 4)
    }
}
