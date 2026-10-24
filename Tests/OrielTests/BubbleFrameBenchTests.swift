import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Banc du temps par image de la bulle, hors écran (fenêtres jamais affichées). Mesure le coût sur le fil principal
/// d'une image : mise à jour SwiftUI, mise en page, liste d'affichage envoyée à RenderBox (`CATransaction.flush`). Le
/// dessin lui-même (flou de la goutte compris) part au GPU, en dehors du fil principal : sonde faite, les vues sont
/// des `RBDrawingLayer`. Ne fait rien sans `ORIEL_BENCH` (nom du rapport), écrit dans `ORIEL_BENCH_OUT`.
final class BubbleFrameBenchTests: XCTestCase {
    private static var enabled: Bool { ProcessInfo.processInfo.environment["ORIEL_BENCH"] != nil }

    /// MacBook Pro 14" : écran 1512 × 982 pt, encoche 185 × 32.
    private static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private static let notch = CGRect(x: 663.5, y: 950, width: 185, height: 32)

    /// Vue dans une fenêtre jamais affichée.
    private final class Offscreen<V: View> {
        let hosting: NSHostingView<V>
        let window: NSWindow

        init(_ view: V, size: CGSize) {
            hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = []
            hosting.frame = CGRect(origin: .zero, size: size)
            window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
        }

        /// Une image : nouvelle vue (ou nil : l'état observé a changé), mise en page, envoi. En millisecondes.
        @discardableResult
        func frame(_ view: V? = nil) -> Double {
            let start = CACurrentMediaTime()
            if let view { hosting.rootView = view }
            hosting.layoutSubtreeIfNeeded()
            hosting.layer?.displayIfNeeded()
            CATransaction.flush()
            return (CACurrentMediaTime() - start) * 1000
        }

        deinit { window.close() }
    }

    private struct Stats: CustomStringConvertible {
        let samples: [Double]
        var median: Double { samples.sorted()[samples.count / 2] }
        var p95: Double { samples.sorted()[min(samples.count - 1, Int(Double(samples.count) * 0.95))] }
        var max: Double { samples.max() ?? 0 }
        var description: String { String(format: "médiane %.2f ms, p95 %.2f ms, max %.2f ms", median, p95, max) }
    }

    private func report(_ part: String, _ lines: [String]) {
        let text = lines.joined(separator: "\n")
        print("\n=== Banc de la bulle ===\n" + text + "\n")
        if let dir = ProcessInfo.processInfo.environment["ORIEL_BENCH_OUT"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let name = ProcessInfo.processInfo.environment["ORIEL_BENCH"] ?? "bench"
            try? text.write(toFile: dir + "/bench-\(name)-\(part).txt", atomically: true, encoding: .utf8)
        }
    }

    /// Panneau déplié du MacBook (largeur des réglages par défaut) et poignée de son coin bas droit.
    private func pullGeometry(_ prefs: Preferences) -> (panel: CGRect, handle: CGPoint) {
        let width = prefs.expandedWidth(compact: false) - 24
        let panel = CGRect(x: Self.notch.midX - width / 2, y: Self.screen.maxY - 360, width: width, height: 360)
        return (panel, CGPoint(x: panel.maxX - 10, y: panel.minY + 6))
    }

    /// Une image de goutte par position de souris le long d'un glisser de 0 à 200 pt (décollage à 120), à la taille de
    /// la fenêtre de la goutte que `BubbleController.beginPull` ouvre.
    func testGooFrameTime() throws {
        guard Self.enabled else { throw XCTSkip("ORIEL_BENCH non défini") }
        _ = NSApplication.shared
        let notch = NotchHarness(self)
        let (panel, handle) = pullGeometry(notch.prefs)
        let frame = BubbleController.gooFrame(
            covering: BubbleController.pullCover(panel: panel, notch: Self.notch, handle: handle),
            screenTop: Self.screen.maxY)
        let local = GooCoordinates(frame)
        var state = GooState(panel: local.body(panel), notch: local.body(Self.notch), handle: local.point(handle),
                             drop: local.point(handle))
        let start = Date()
        let view = { (date: Date) in GooCanvas(shapes: state.shapes(at: date), color: .black) }
        let t0 = CACurrentMediaTime()
        let bench = Offscreen(view(start), size: frame.size)
        let first = bench.frame() + (CACurrentMediaTime() - t0) * 1000
        for _ in 0..<10 { bench.frame(view(start)) }
        var times: [Double] = []
        for step in 0..<120 {
            let distance = CGFloat(step) * 200 / 119
            state.drop = local.point(CGPoint(x: handle.x + distance * 0.45, y: handle.y - distance * 0.89))
            times.append(bench.frame(view(start)))
        }
        report("goutte", [
            String(format: "Fenêtre de la goutte : %.0f × %.0f pt", frame.width, frame.height),
            String(format: "Goutte, première image (fenêtre neuve) : %.2f ms", first),
            "Goutte, une image du glisser : \(Stats(samples: times))",
        ])
    }

    /// Le décollage, rangé par moment comme `BubbleController` le fait : au lancement (vues préparées), au premier
    /// glisser (la goutte paraît, la bulle se dessine transparente), dans l'image du décollage, au lâcher (réglage
    /// rangé, notch repliée). Avant ce découpage, tout tombait dans l'image du décollage (79 ms en release).
    func testDetachHitch() throws {
        guard Self.enabled else { throw XCTSkip("ORIEL_BENCH non défini") }
        _ = NSApplication.shared
        let notch = NotchHarness(self, store: .working(2))
        notch.model.isExpanded = true
        notch.model.selectedTab = "claude"
        let notchBench = Offscreen(notch.root, size: NotchController.panelSize)
        for _ in 0..<5 { notchBench.frame(notch.root) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        notchBench.frame()

        // Au lancement : vues de la bulle et fenêtre de la goutte construites, pas affichées.
        let bubble = BubbleModel()
        let root = BubbleRootView(model: notch.model, bubble: bubble, store: notch.store, registry: notch.registry,
                                  prefs: notch.prefs, actions: NotchActions(), input: BubbleInput())
        let goo = GooModel()
        let (panel, handle) = pullGeometry(notch.prefs)
        let gooFrame = BubbleController.gooFrame(
            covering: BubbleController.pullCover(panel: panel, notch: Self.notch, handle: handle),
            screenTop: Self.screen.maxY)
        let t0 = CACurrentMediaTime()
        let bubbleBench = Offscreen(root, size: BubbleController.bubbleWindowSize)
        bubbleBench.hosting.layoutSubtreeIfNeeded()
        let gooBench = Offscreen(GooView(goo: goo, color: .black), size: gooFrame.size)
        gooBench.hosting.layoutSubtreeIfNeeded()
        let launch = (CACurrentMediaTime() - t0) * 1000

        // Premier glisser : la notch s'efface sous la goutte, la bulle se dessine transparente.
        notch.model.gooActive = true
        let fade = notchBench.frame()
        let local = GooCoordinates(gooFrame)
        goo.state = GooState(panel: local.body(panel), notch: local.body(Self.notch), handle: local.point(handle),
                             drop: local.point(handle))
        let gooFirst = gooBench.frame()
        bubble.scale = 0.72
        let bubbleFirst = bubbleBench.frame()

        // Image du décollage : la phase change, la bulle (déjà dessinée) devient opaque et rebondit.
        notch.model.bubble = .bubble
        let phase = notchBench.frame()
        bubble.scale = 0.8
        let bounce = bubbleBench.frame()

        // Au lâcher : réglage rangé, notch repliée (cachée sous la goutte).
        notch.prefs.bubbleDetached = true
        let saved = notchBench.frame()
        notch.model.isExpanded = false
        let collapse = notchBench.frame()

        report("decollage", [
            String(format: "Au lancement (une fois) : vues de la bulle et fenêtre de la goutte : %.2f ms", launch),
            String(format: "Premier glisser : notch effacée %.2f + goutte %.2f + bulle transparente %.2f = %.2f ms",
                   fade, gooFirst, bubbleFirst, fade + gooFirst + bubbleFirst),
            String(format: "Image du décollage : phase publiée %.2f + bulle %.2f = %.2f ms", phase, bounce,
                   phase + bounce),
            String(format: "Au lâcher : réglage rangé %.2f + notch repliée %.2f = %.2f ms", saved, collapse,
                   saved + collapse),
        ])
    }

    /// Retour aimanté : une image par position, de la portée de l'aimant jusqu'à l'aspiration, dans la fenêtre agrandie
    /// au champ de la notch (bulle déplacée dans la fenêtre, contour et pointes recalculés).
    func testFerroFrameTime() throws {
        guard Self.enabled else { throw XCTSkip("ORIEL_BENCH non défini") }
        _ = NSApplication.shared
        let notch = NotchHarness(self, store: .working(2))
        notch.model.bubble = .bubble
        let field = Ferro.fieldFrame(notch: Self.notch)
        let local = GooCoordinates(field)
        let bubble = BubbleModel()
        var state = FerroState(notch: local.rect(Self.notch), center: .zero)
        func place(gap: CGFloat) {
            let wanted = CGPoint(x: Self.notch.midX + 60, y: Self.notch.minY - BubbleGeometry.radius - gap)
            let pulled = Ferro.attract(wanted, notch: Self.notch)
            state.move(to: local.point(pulled.center), strength: pulled.strength, at: Date())
            bubble.ferro = state
            bubble.layout(center: local.point(pulled.center), window: field.size)
        }
        place(gap: Ferro.reach)
        let root = BubbleRootView(model: notch.model, bubble: bubble, store: notch.store, registry: notch.registry,
                                  prefs: notch.prefs, actions: NotchActions(), input: BubbleInput())
        let bench = Offscreen(root, size: field.size)
        for _ in 0..<10 { bench.frame() }
        var times: [Double] = []
        // Approche jusqu'au pont épais, puis éloignement : pont étiré, rompu.
        for step in 0..<160 {
            let t = CGFloat(step) / 159
            let gap = t < 0.7 ? Ferro.reach - (Ferro.reach - 20) * t / 0.7 : 20 + (120 - 20) * (t - 0.7) / 0.3
            place(gap: gap)
            times.append(bench.frame())
        }
        report("ferro", [
            String(format: "Champ de la notch : %.0f × %.0f pt", field.width, field.height),
            "Ferrofluide, une image (approche, pont, rupture) : \(Stats(samples: times))",
        ])
    }
}
