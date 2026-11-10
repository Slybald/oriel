import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Garde-fou visuel (audit du 2026-11-09) : la notch repliée au repos ne doit porter aucun effet coûteux.
/// Elle est toujours à l'écran, donc un flou, une animation sans fin ou un redessin continu y coûtent en permanence.
/// Tourne en CI comme en local ; la fenêtre n'est jamais montrée. Deux contrôles, qui ne couvrent pas la même chose :
/// - l'arbre de vues et de calques (`testCollapsedNotchAtRestHasNoCostlyEffect`) : un `NSVisualEffectView`, une
///   `CAAnimation` à répétition infinie (poser par AppKit/Core Animation), et un `TimelineView` écrit directement dans
///   le corps de `NotchRootView`. Il NE voit PAS les animations SwiftUI (`.repeatForever`, qui ne posent aucune
///   `CAAnimation` dans une fenêtre jamais montrée) ni un `TimelineView` dans une vue fille ;
/// - les sources (`testNoEndlessAnimationOutsideAllowedFiles`) : toute occurrence de `repeatForever` ou de
///   `TimelineView` dans `Sources/Oriel`, hors fichiers autorisés. Il couvre ces deux cas partout, mais il juge un
///   fichier entier, pas l'état affiché : d'où la liste d'autorisations, qui dit pourquoi chaque fichier est hors notch
///   repliée. Un redessin continu obtenu autrement (`CADisplayLink`, minuteur) n'est couvert par aucun des deux.
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

    /// Fichiers qui contiennent légitimement `TimelineView` : une ligne par fichier, avec sa raison. Aucun n'est dans la
    /// notch repliée (intercalaires, perle, pop-up) ; ils sont tous dans le panneau déplié ou dans la bulle détachée.
    static let allowedSourceFiles: [String: String] = [
        "BubbleViews.swift": "bulle détachée (autre fenêtre), absente de la notch repliée",
        "Modules/Agenda/AgendaViews.swift": "panneau déplié, onglet Agenda (horloge à la minute)",
        "Modules/Mail/MailViews.swift": "panneau déplié, onglet Mail (dates relatives à la minute)",
        "Modules/Messages/MessagesViews.swift": "panneau déplié, onglet Messages (dates relatives à la minute)",
        "Modules/Clipboard/ClipboardViews.swift": "panneau déplié, onglet Presse-papiers (âge à la minute)",
        "Modules/Media/MediaViews.swift": "panneau déplié, onglet Média (progression, seulement en lecture)",
        "Modules/Claude/ClaudeModule.swift": "panneau déplié, liste des sessions (durées à la seconde)",
        "Modules/Codex/CodexViews.swift": "panneau déplié, liste des sessions Codex (durées à la seconde)",
    ]

    func testNoEndlessAnimationOutsideAllowedFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Oriel")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "sources introuvables sous \(root.path) : le contrôle ne prouverait rien")

        var found: [String] = []
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if line.contains("repeatForever") { found.append("\(relative):\(index + 1) repeatForever") }
                if line.contains("TimelineView"), Self.allowedSourceFiles[relative] == nil {
                    found.append("\(relative):\(index + 1) TimelineView")
                }
            }
        }
        XCTAssertTrue(found.isEmpty, "animation sans fin ou redessin continu hors liste d'autorisations : \(found)")
    }
}
