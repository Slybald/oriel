import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendus PNG de « Approuver au clavier » : les cartes de permission avec leurs touches (Claude et Codex), « 1 sur 3 »
/// sur la plus ancienne, rien sur les suivantes. Ne fait rien sans `ORIEL_SNAPSHOT_DIR`. Données fictives.
final class ApprovalSnapshotTests: XCTestCase {
    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["ORIEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    /// Touches factices : aucune combinaison n'est réservée pour un rendu.
    private final class AcceptingKeys: HotKeyRegistering {
        func set(_ choice: HotKeyChoice, for slot: HotKeyCenter.Slot, action: @escaping () -> Void) -> Bool { true }
    }

    func testRenderApprovalCards() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        _ = NSApplication.shared
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.replyFromNotch = true
        prefs.approveByKeyboard = true
        let replies = ReplyCenter(prefs: prefs)
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("oriel-no-config")
        let claude = ClaudeModule(store: SessionStore(), monitor: ClaudeMonitor(), tools: ToolsFeed(paths: LayoutTests.absentPaths),
                                  prefs: prefs, hooks: HookSetup(installer: HookInstaller(configDirectory: config, bundledHook: nil)),
                                  replies: replies)
        let codex = CodexModule(defaults: makeEphemeralDefaults(self))
        codex.replyFromNotch = true

        var t = Date(timeIntervalSince1970: 1_800_000_000)
        replies.clock = { t }
        codex.approvals.clock = { t }
        replies.hold(HookEvent(raw: ["hook_event_name": "PermissionRequest", "session_id": "api", "tool_name": "Bash",
                                     "tool_input": ["command": "rm -rf build", "description": "Supprime le dossier build"]])) { _ in }
        t = t.addingTimeInterval(2)
        replies.hold(HookEvent(raw: ["hook_event_name": "PermissionRequest", "session_id": "site", "tool_name": "Edit",
                                     "tool_input": ["file_path": "/Users/demo/site/index.html", "old_string": "a", "new_string": "b"]])) { _ in }
        t = t.addingTimeInterval(2)
        codex.approvals.hold(CodexFixtures.bash("git push origin main", "PermissionRequest", description: "Publie la branche")) { _ in }

        let queue = ApprovalQueue(prefs: prefs, keys: AcceptingKeys())
        queue.attach([.claude(claude), .codex(codex)]) { _ in }
        XCTAssertEqual(queue.count, 3)

        let first = try XCTUnwrap(replies.requests.first)
        let second = try XCTUnwrap(replies.requests.last)
        let codexRequest = try XCTUnwrap(codex.approvals.requests.first)
        let panel = VStack(alignment: .leading, spacing: 8) {
            RequestCard(request: first, drafts: ReplyDrafts(), keys: queue, engage: {}, decide: { _ in })
            RequestCard(request: second, drafts: ReplyDrafts(), keys: queue, engage: {}, decide: { _ in })
            CodexApprovalCard(request: codexRequest, keys: queue, engage: {}, decide: { _ in })
        }
        .padding(14)
        .frame(width: 460)
        try render(panel, name: "approval-queue", to: outputDir, size: CGSize(width: 460, height: 390))

        // Une seule demande, côté Codex : pas de rang, les touches sur la carte.
        replies.releaseAll()
        let alone = VStack(alignment: .leading, spacing: 8) {
            CodexApprovalCard(request: codexRequest, keys: queue, engage: {}, decide: { _ in })
        }
        .padding(14)
        .frame(width: 460)
        XCTAssertEqual(queue.count, 1)
        try render(alone, name: "approval-codex", to: outputDir, size: CGSize(width: 460, height: 160))
    }

    private func render<V: View>(_ view: V, name: String, to dir: URL, size: CGSize) throws {
        let hosting = NSHostingView(rootView: view.preferredColorScheme(.dark).background(Color(white: 0.04)))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let layer = hosting.layer,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                            pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return XCTFail("rendu impossible")
        }
        let cg = context.cgContext
        cg.translateBy(x: 0, y: size.height * scale)
        cg.scaleBy(x: scale, y: -scale)
        layer.render(in: cg)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return XCTFail("PNG") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        window.close()
    }
}
