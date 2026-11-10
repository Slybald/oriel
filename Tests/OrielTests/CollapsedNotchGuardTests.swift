import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Garde-fou visuel (audit du 2026-11-09) : la notch repliée au repos ne doit porter aucun effet coûteux.
/// Elle est toujours à l'écran, donc un flou, une animation sans fin ou un redessin continu y coûtent en permanence.
/// Tourne en CI comme en local ; la fenêtre n'est jamais montrée.
final class CollapsedNotchGuardTests: XCTestCase {
    /// Exceptions légitimes, une ligne par cas avec sa raison. Clé : nom de la violation (voir `violations`).
    /// Vide : au repos sur une vraie encoche, aucune exception n'existe à ce jour.
    static let allowed: [String: String] = [:]

    /// Construit la notch repliée au repos (vraie encoche, aucune session) et décrit ce qu'elle contient de coûteux.
    private func violations() -> [String] {
        let notch = NotchHarness(self)
        notch.model.isExpanded = false
        let size = NotchController.panelSize
        let hosting = NSHostingView(rootView: notch.root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }

        // Attente sur condition : SwiftUI a mesuré la notch (la mise en page est faite), au plus 5 s.
        let deadline = Date().addingTimeInterval(5)
        while notch.model.contentSize == .zero, Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        hosting.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(notch.model.contentSize, .zero, "la notch n'a pas été mise en page : le test ne prouverait rien")

        var found: [String] = []
        // 3. Redessin continu : `TimelineView` laisse son type dans celui du corps de la vue racine (types génériques
        // imbriqués). Couvre la vue racine elle-même, pas le corps des vues filles (un `TimelineView` dans `EarTabsView`
        // par exemple n'est pas vu ici).
        if String(describing: type(of: notch.root.body)).contains("TimelineView") { found.append("TimelineView") }

        func walk(layer: CALayer, path: String) {
            for key in layer.animationKeys() ?? [] {
                if let animation = layer.animation(forKey: key), isEndless(animation) {
                    found.append("animation infinie \(key) sur \(path)")
                }
            }
            for sub in layer.sublayers ?? [] { walk(layer: sub, path: "\(path)/\(type(of: sub))") }
        }
        func walk(view: NSView) {
            let name = String(describing: type(of: view))
            if view is NSVisualEffectView { found.append("NSVisualEffectView") }
            if let layer = view.layer { walk(layer: layer, path: name) }
            for sub in view.subviews { walk(view: sub) }
        }
        walk(view: hosting)
        return found
    }

    private func isEndless(_ animation: CAAnimation) -> Bool {
        if animation.repeatCount == .infinity || animation.repeatDuration == .infinity { return true }
        return (animation as? CAAnimationGroup)?.animations?.contains(where: isEndless) ?? false
    }

    func testCollapsedNotchAtRestHasNoCostlyEffect() {
        let unexpected = violations().filter { violation in
            !Self.allowed.keys.contains { violation.hasPrefix($0) }
        }
        XCTAssertTrue(unexpected.isEmpty, "notch repliée au repos : effet coûteux interdit : \(unexpected)")
    }
}
