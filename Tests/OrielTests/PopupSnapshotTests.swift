import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendus PNG du pop-up sous la notch : vraie encoche, perle (écran sans encoche), encoche virtuelle, fond Verre, groupe
/// « +2 ». Ne fait rien sans `ORIEL_SNAPSHOT_DIR` (la CI le définit et publie les PNG ; rien ne se lance en local).
final class PopupSnapshotTests: XCTestCase {
    private static let wallpaper = Color(red: 0.36, green: 0.52, blue: 0.74)
    private static let size = CGSize(width: 800, height: 150)

    private func scene(_ event: PopupEvent, virtual: Bool = false, style: VirtualNotchStyle = .pearl,
                       glass: Bool = false) -> NotchRootView {
        let harness = NotchHarness(self, store: SessionStore())
        if virtual {
            harness.model.hasNotch = false
            harness.model.notchSize = CGSize(width: 200, height: 24)
            harness.prefs.virtualNotchStyle = style
        }
        if glass { harness.prefs.panelBackground = .glass }
        harness.model.popup = event
        let registry = ModuleRegistry(modules: [harness.claude], prefs: harness.prefs)
        registry.reconcile()
        return NotchRootView(model: harness.model, store: harness.store, registry: registry, prefs: harness.prefs,
                             actions: NotchActions())
    }

    func testRenderPopups() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        func render(_ root: NotchRootView, _ name: String) throws {
            try TimerNotesSnapshot.render(root, name, dir, size: Self.size, background: Self.wallpaper)
        }
        let message = PopupEvent(source: "messages", symbol: "message.fill", title: "Camille Martin",
                                 text: "On se retrouve à 19 h devant le cinéma ?", key: "a")
        try render(scene(message), "popup-notch")
        try render(scene(message, glass: true), "popup-notch-glass")
        try render(scene(message, virtual: true), "popup-pearl")
        try render(scene(message, virtual: true, style: .notch), "popup-virtual-notch")
        var grouped = message
        grouped.extra = 2
        try render(scene(grouped), "popup-grouped")
        let long = PopupEvent(source: "mail", symbol: "envelope.fill",
                              title: "Une expéditrice au nom vraiment très long à afficher",
                              text: "Un objet de mail tout aussi long, qui doit être coupé proprement par la vue", key: "b")
        try render(scene(long), "popup-long-text")
    }
}
