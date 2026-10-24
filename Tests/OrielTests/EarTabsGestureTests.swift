import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Clics sur un intercalaire déployé, joués par des événements souris envoyés à une fenêtre transparente :
/// un clic dans le cadre ouvre l'onglet, un bouton du contenu garde son clic, un clic à côté ne fait rien.
final class EarTabsGestureTests: XCTestCase {
    private var opened: [String] = []
    private var window: NSPanel!
    private var adapter: FakeAdapter!
    private var scene: (NotchHarness, ModuleRegistry)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        adapter = try FakeAdapter(self, lines: [StreamLines.full(title: "Lumières de la ville", artist: "Les Fictifs")])
        let media = MediaModule(defaults: makeEphemeralDefaults(self), adapter: adapter.adapter,
                                calendar: FakeCalendar(.notDetermined))
        addTeardownBlock { media.stop() }
        scene = TimerNotesSnapshot.scene(self, replacing: media, expanded: false, store: .working(1))
        scene.1.reconcile()
        wait { self.scene.1.earsEntries.contains { $0.id == "media" } }
        scene.0.model.hoveredTab = "media"

        var actions = NotchActions()
        actions.openTab = { [unowned self] in opened.append($0) }
        let root = NotchRootView(model: scene.0.model, store: scene.0.store, registry: scene.1, prefs: scene.0.prefs,
                                 actions: actions)
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: NotchController.panelSize)
        window = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Transparente : elle doit être « à l'écran » pour recevoir des événements, sans rien montrer à l'utilisateur.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        wait { self.scene.0.model.tabCardHeight > 60 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    }

    override func tearDown() {
        window.close()
        super.tearDown()
    }

    private func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private var layout: EarTabsLayout {
        scene.1.earLayout(claude: scene.0.store.indicator, claudeEars: scene.0.store.ears,
                          notch: scene.0.model.notchSize)
    }

    /// Point de la fenêtre (origine en bas à gauche) pour un point `local` de la notch (origine en haut au centre).
    private func windowPoint(_ local: CGPoint) -> CGPoint {
        CGPoint(x: NotchController.panelSize.width / 2 + local.x, y: NotchController.panelSize.height - local.y)
    }

    private func click(_ local: CGPoint) {
        let point = windowPoint(local)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            window.sendEvent(event!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func testDeployedTabMeasuresItsHeightForTheHoverZone() {
        let model = scene.0.model
        XCTAssertGreaterThan(model.tabCardHeight, 60, "la vue remonte la hauteur du contenu")
        let item = layout.item("media")!
        let card = layout.cardFrame(item, height: model.tabCardHeight)
        XCTAssertGreaterThan(card.height, 60)
        XCTAssertEqual(layout.hit(CGPoint(x: card.midX, y: card.height - 4), hovered: "media",
                                  cardHeight: model.tabCardHeight), .tab("media"), "le bas du cadre est dans la zone")
        XCTAssertEqual(layout.hit(CGPoint(x: card.midX, y: card.height + 4), hovered: "media",
                                  cardHeight: model.tabCardHeight), .none, "sous le cadre, plus rien")
    }

    func testClickOnTheDeployedHeaderOpensItsTab() {
        let item = layout.item("media")!
        let card = layout.cardFrame(item, height: scene.0.model.tabCardHeight)
        click(CGPoint(x: card.midX, y: 14))
        XCTAssertEqual(opened, ["media"])
    }

    func testControlKeepsItsClickAndDoesNotOpenTheTab() throws {
        let item = layout.item("media")!
        let card = layout.cardFrame(item, height: scene.0.model.tabCardHeight)
        // Les commandes sont au bas du cadre (pause au milieu, sous le titre).
        click(CGPoint(x: card.midX, y: card.height - 26))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(adapter.commands.contains("send 2"), "bouton lecture / pause : \(adapter.commands)")
        XCTAssertEqual(opened, [], "le clic sur un bouton n'ouvre pas le panneau")
    }

    func testClickOutsideTheDeployedTabDoesNothing() {
        let item = layout.item("media")!
        let card = layout.cardFrame(item, height: scene.0.model.tabCardHeight)
        click(CGPoint(x: card.maxX + 60, y: 60))
        XCTAssertEqual(opened, [])
    }
}
