import Foundation
import XCTest
@testable import Oriel

final class CodexApprovalsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let permission = CodexFixtures.bash("rm -rf build", "PermissionRequest", description: "Supprime le dossier build")

    private func makeApprovals(enabled: Bool = true) -> CodexApprovals {
        let approvals = CodexApprovals()
        approvals.isEnabled = { enabled }
        approvals.clock = { [t0] in t0 }
        return approvals
    }

    private final class Replies {
        var outputs: [Data?] = []
        lazy var reply: (Data?) -> Void = { [unowned self] data in self.outputs.append(data) }
    }

    /// Format vérifié sur Codex 0.154 : `hookSpecificOutput.decision.behavior`, `message` pour un refus.
    func testOutputsHaveCodexFormat() throws {
        let allow = try XCTUnwrap(JSONSerialization.jsonObject(with: CodexApprovals.output(allow: true)) as? NSDictionary)
        XCTAssertEqual(allow, ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                      "decision": ["behavior": "allow"]]])
        let deny = try XCTUnwrap(JSONSerialization.jsonObject(with: CodexApprovals.output(allow: false)) as? NSDictionary)
        let decision = try XCTUnwrap((deny["hookSpecificOutput"] as? NSDictionary)?["decision"] as? NSDictionary)
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertNotNil(decision["message"] as? String)
        // Codex refuse `updatedInput`, `updatedPermissions` et `interrupt` pour PermissionRequest.
        let text = String(decoding: CodexApprovals.output(allow: true), as: UTF8.self)
        for forbidden in ["updatedInput", "updatedPermissions", "interrupt"] { XCTAssertFalse(text.contains(forbidden)) }
    }

    func testAllowAndDenyAnswerTheHeldHook() throws {
        let approvals = makeApprovals()
        let replies = Replies()
        approvals.hold(permission, reply: replies.reply)
        let request = try XCTUnwrap(approvals.requests.first)
        XCTAssertEqual(request.tool.detail, "rm -rf build")
        XCTAssertEqual(request.note, "Supprime le dossier build")
        XCTAssertEqual(request.deadline, t0.addingTimeInterval(CodexApprovals.graceDelay), "carte jamais vue : 4 s")

        approvals.engage(request.id)
        XCTAssertEqual(approvals.requests.first?.deadline, t0.addingTimeInterval(CodexApprovals.engagedDelay))
        XCTAssertTrue(approvals.decide(request, .allow))
        XCTAssertEqual(replies.outputs.count, 1)
        XCTAssertEqual(replies.outputs[0], CodexApprovals.output(allow: true))
        XCTAssertTrue(approvals.requests.isEmpty)
        XCTAssertEqual(approvals.notices[CodexFixtures.session]?.tone, .done)

        approvals.hold(permission, reply: replies.reply)
        let second = try XCTUnwrap(approvals.requests.first)
        XCTAssertTrue(approvals.decide(second, .deny))
        XCTAssertEqual(replies.outputs[1], CodexApprovals.output(allow: false))
    }

    /// « Dans le terminal » : le hook rend la main sans décider, Codex pose sa question.
    func testHandingOverToTheTerminalDecidesNothing() throws {
        let approvals = makeApprovals()
        let replies = Replies()
        approvals.hold(permission, reply: replies.reply)
        XCTAssertTrue(approvals.decide(try XCTUnwrap(approvals.requests.first), .terminal))
        XCTAssertEqual(replies.outputs.count, 1)
        XCTAssertNil(replies.outputs[0] as Data?, "pas de décision")
    }

    func testSettingOffAnswersAtOnceWithoutDecision() {
        let approvals = makeApprovals(enabled: false)
        let replies = Replies()
        approvals.hold(permission, reply: replies.reply)
        XCTAssertEqual(replies.outputs.count, 1)
        XCTAssertNil(replies.outputs[0] as Data?)
        XCTAssertTrue(approvals.requests.isEmpty)
    }

    func testDeadlinesReleaseWithoutDecision() throws {
        let approvals = makeApprovals()
        let replies = Replies()
        approvals.hold(permission, reply: replies.reply)
        approvals.expire(now: t0.addingTimeInterval(CodexApprovals.graceDelay - 0.1))
        XCTAssertEqual(approvals.requests.count, 1)
        approvals.expire(now: t0.addingTimeInterval(CodexApprovals.graceDelay))
        XCTAssertTrue(approvals.requests.isEmpty)
        XCTAssertNil(replies.outputs[0] as Data?, "à l'échéance : le terminal reprend la main")
        XCTAssertNil(approvals.notices[CodexFixtures.session], "carte jamais vue : pas de message")

        // Carte vue : 60 s, puis un message dit pourquoi.
        approvals.hold(permission, reply: replies.reply)
        approvals.engage(try XCTUnwrap(approvals.requests.first).id)
        approvals.expire(now: t0.addingTimeInterval(CodexApprovals.engagedDelay - 1))
        XCTAssertEqual(approvals.requests.count, 1)
        approvals.expire(now: t0.addingTimeInterval(CodexApprovals.engagedDelay))
        XCTAssertTrue(approvals.requests.isEmpty)
        XCTAssertEqual(approvals.notices[CodexFixtures.session]?.tone, .warning)
        XCTAssertLessThan(CodexApprovals.engagedDelay, Double(CodexHookInstaller.permissionTimeout)!,
                          "l'app rend toujours la main avant le timeout du hook")
    }

    func testDecisionTooLateIsRefused() throws {
        let approvals = makeApprovals()
        let replies = Replies()
        approvals.hold(permission, reply: replies.reply)
        let request = try XCTUnwrap(approvals.requests.first)
        approvals.expire(now: t0.addingTimeInterval(10))
        XCTAssertFalse(approvals.decide(request, .allow), "demande déjà rendue : aucun clic tardif ne décide")
        XCTAssertEqual(replies.outputs.count, 1)
        XCTAssertNil(replies.outputs[0] as Data?)
    }

    func testClosedConnectionDropsTheCard() throws {
        let approvals = makeApprovals()
        let id = UUID()
        let replies = Replies()
        approvals.hold(permission, id: id, reply: replies.reply)
        approvals.engage(id)
        approvals.connectionClosed(id)
        XCTAssertTrue(approvals.requests.isEmpty)
        XCTAssertTrue(replies.outputs.isEmpty, "le hook est déjà parti : personne à qui répondre")
        XCTAssertEqual(approvals.notices[CodexFixtures.session]?.tone, .info)
    }

    func testEventsReleaseTheMatchingRequestOnly() {
        let approvals = makeApprovals()
        let replies = Replies()
        approvals.hold(permission, reply: replies.reply)
        // Un autre outil ou une autre commande ne la libère pas.
        approvals.observe(CodexFixtures.bash("ls", "PostToolUse"))
        approvals.observe(CodexFixtures.bash("rm -rf build", "PostToolUse", session: "autre"))
        XCTAssertEqual(approvals.requests.count, 1)
        // La même commande terminée dans le terminal : la demande est rendue.
        approvals.observe(CodexFixtures.bash("rm -rf build", "PostToolUse"))
        XCTAssertTrue(approvals.requests.isEmpty)
        XCTAssertEqual(replies.outputs.count, 1)

        for name in ["Stop", "UserPromptSubmit", "Interrupt", "SessionEnd"] {
            approvals.hold(permission, reply: replies.reply)
            approvals.observe(CodexFixtures.event(name))
            XCTAssertTrue(approvals.requests.isEmpty, name)
        }
    }

    func testReleaseAllGivesEverythingBack() {
        let approvals = makeApprovals()
        let replies = Replies()
        approvals.hold(permission, reply: replies.reply)
        approvals.hold(CodexFixtures.bash("ls", "PermissionRequest", session: "b"), reply: replies.reply)
        approvals.releaseAll()
        XCTAssertTrue(approvals.requests.isEmpty)
        XCTAssertEqual(replies.outputs.count, 2)
        XCTAssertTrue(replies.outputs.allSatisfy { $0 == nil })
    }

    func testRequestWithoutToolIsNotHeld() {
        let approvals = makeApprovals()
        let replies = Replies()
        approvals.hold(CodexFixtures.event("PermissionRequest"), reply: replies.reply)
        XCTAssertEqual(replies.outputs.count, 1)
        XCTAssertTrue(approvals.requests.isEmpty)
    }
}
