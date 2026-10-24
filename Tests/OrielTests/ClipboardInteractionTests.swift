import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Clavier de la recherche, suivi des apps au premier plan et capture de bout en bout sur un presse-papiers privé.
final class ClipboardInteractionTests: XCTestCase {
    private func wait(until condition: () -> Bool, timeout: TimeInterval = 4) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: Clavier

    private final class Recorder {
        var moves: [Int] = []
        var submits = 0
        var cancels = 0
        var text = ""
        var focus: [Bool] = []
    }

    private func coordinator(_ recorder: Recorder) -> ClipboardSearchField.Coordinator {
        _ = NSApplication.shared
        let field = ClipboardSearchField(
            text: Binding(get: { recorder.text }, set: { recorder.text = $0 }), placeholder: "",
            onFocus: { recorder.focus.append($0) }, onMove: { recorder.moves.append($0) },
            onSubmit: { recorder.submits += 1 }, onCancel: { recorder.cancels += 1 })
        return ClipboardSearchField.Coordinator(field)
    }

    func testSearchFieldTurnsArrowsReturnAndEscapeIntoActions() {
        let recorder = Recorder()
        let coordinator = coordinator(recorder)
        let control = NSTextField()
        let editor = NSTextView()
        func press(_ selector: Selector) -> Bool {
            coordinator.control(control, textView: editor, doCommandBy: selector)
        }
        XCTAssertTrue(press(#selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(press(#selector(NSResponder.moveUp(_:))))
        XCTAssertTrue(press(#selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(press(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(recorder.moves, [1, -1])
        XCTAssertEqual(recorder.submits, 1)
        XCTAssertEqual(recorder.cancels, 1)
        // Le reste (effacer, déplacer le curseur…) revient à l'éditeur de texte.
        XCTAssertFalse(press(#selector(NSResponder.deleteBackward(_:))))
        XCTAssertFalse(press(#selector(NSResponder.moveLeft(_:))))
        XCTAssertEqual(recorder.moves.count, 2)

        control.stringValue = "abc"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: control))
        XCTAssertEqual(recorder.text, "abc")
    }

    func testFocusIsReportedBothWays() {
        let recorder = Recorder()
        let coordinator = coordinator(recorder)
        coordinator.focusGained()
        XCTAssertTrue(coordinator.isFocused)
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        XCTAssertFalse(coordinator.isFocused)
        XCTAssertEqual(recorder.focus, [true, false])
    }

    func testArrowSelectionStaysInTheListAndStartsAtTheEnds() throws {
        let rig = try makeClipboardRig()
        for text in ["a", "b", "c"] { rig.copy(text) }
        let ids = rig.items.map(\.id)
        let next = ClipboardPanel.nextSelection
        XCTAssertNil(next(nil, 1, []))
        XCTAssertEqual(next(nil, 1, rig.items), ids[0], "↓ sans choix : la première ligne")
        XCTAssertEqual(next(nil, -1, rig.items), ids[2], "↑ sans choix : la dernière")
        XCTAssertEqual(next(ids[0], 1, rig.items), ids[1])
        XCTAssertEqual(next(ids[1], -1, rig.items), ids[0])
        XCTAssertEqual(next(ids[0], -1, rig.items), ids[0], "pas de bouclage en haut")
        XCTAssertEqual(next(ids[2], 1, rig.items), ids[2], "ni en bas")
        XCTAssertEqual(next(UUID(), 1, rig.items), ids[0], "choix disparu : on repart du haut")
    }

    // MARK: Apps au premier plan

    func testFrontAppsKeepEveryAppSeenSinceTheLastTick() throws {
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
                                   "le Finder tourne toujours")
        let apps = WorkspaceFrontApps()
        apps.start()
        addTeardownBlock { apps.stop() }
        _ = apps.drain()

        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                    userInfo: [NSWorkspace.applicationUserInfoKey: finder])
        XCTAssertEqual(apps.drain().last?.bundleID, "com.apple.finder")
        XCTAssertEqual(apps.drain().map(\.bundleID), ["com.apple.finder"], "l'app actuelle ouvre l'intervalle suivant")

        apps.stop()
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                    userInfo: [NSWorkspace.applicationUserInfoKey: finder])
        XCTAssertEqual(apps.drain(), [], "arrêté : plus d'observateur")
    }

    // MARK: De bout en bout

    /// Vrai `NSPasteboard` (privé), vrai timer d'une seconde : la copie d'une autre app est capturée, la recopie
    /// depuis la liste ne l'est pas (le `changeCount` réel après écriture sert de repère), un type confidentiel
    /// n'est jamais lu.
    func testEndToEndOnAPrivatePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("oriel-e2e-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        let apps = FakeFrontApps()
        apps.current = .textEdit
        let module = ClipboardModule(defaults: makeEphemeralDefaults(self), pasteboard: SystemPasteboard(pasteboard: pasteboard),
                                     frontApps: apps, storage: ClipboardStorage(directory: try makeTemporaryDirectory(self)))
        module.start()
        addTeardownBlock { module.stop() }

        pasteboard.clearContents()
        pasteboard.setString("copié par une autre app", forType: .string)
        wait(until: { module.history.items.count == 1 })
        XCTAssertEqual(module.history.items.first?.content.plainText, "copié par une autre app")
        XCTAssertEqual(module.history.items.first?.source, .textEdit)

        pasteboard.clearContents()
        pasteboard.setString("autre texte", forType: .string)
        wait(until: { module.history.items.count == 2 })
        XCTAssertEqual(module.history.items.count, 2)

        // Recopie du plus ancien : l'écriture réelle ne doit pas être recapturée au tic suivant.
        // L'app de devant a changé : si la recopie était recapturée, la source de l'élément changerait.
        apps.current = .safari
        let oldest = try XCTUnwrap(module.history.items.last)
        module.copy(oldest.id)
        XCTAssertEqual(pasteboard.string(forType: .string), "copié par une autre app")
        RunLoop.main.run(until: Date().addingTimeInterval(2.6))
        XCTAssertEqual(module.history.items.count, 2, "pas de doublon")
        XCTAssertEqual(module.history.items.first?.id, oldest.id)
        XCTAssertEqual(module.history.items.first?.source, .textEdit, "la recopie n'a pas été recapturée")

        // Un gestionnaire de mots de passe : type confidentiel, jamais enregistré.
        pasteboard.clearContents()
        pasteboard.setString("mot de passe", forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        RunLoop.main.run(until: Date().addingTimeInterval(2.6))
        XCTAssertEqual(module.history.items.count, 2)
        XCTAssertFalse(module.history.items.contains { $0.content.plainText == "mot de passe" })
    }
}
