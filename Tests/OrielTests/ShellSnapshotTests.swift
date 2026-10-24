import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendus PNG des réglages de la notch : fonds, largeur libre, encoche virtuelle, volets Général, Apparence et
/// Confidentialité. Ne fait rien sans `ORIEL_SNAPSHOT_DIR`.
final class ShellSnapshotTests: XCTestCase {
    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["ORIEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private func notch(expanded: Bool = true, configure: (Preferences) -> Void = { _ in }) -> NotchHarness {
        let notch = NotchHarness(self, store: .working(2))
        configure(notch.prefs)
        notch.model.isExpanded = expanded
        return notch
    }

    func testRenderPanelBackgroundsAndWidths() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        try render(notch().root, "shell-background-black", outputDir)
        try render(notch { $0.panelBackground = .graphite }.root, "shell-background-graphite", outputDir)
        try render(notch { $0.panelBackground = .midnight }.root, "shell-background-midnight", outputDir)
        try render(notch {
            $0.panelBackground = .custom
            $0.customBackgroundHex = "3A1F5D"
        }.root, "shell-background-custom", outputDir)
        // Fond libre presque blanc : assombri, le texte reste lisible.
        try render(notch {
            $0.panelBackground = .custom
            $0.customBackgroundHex = "F2F2F2"
        }.root, "shell-background-custom-light", outputDir)
        try render(notch {
            $0.panelBackground = .graphite
            $0.backgroundOpacity = 0.75
        }.root, "shell-background-graphite-75", outputDir)
        try render(notch { $0.panelShadow = false }.root, "shell-no-shadow", outputDir)
        try render(notch { $0.customPanelWidth = 720 }.root, "shell-width-720", outputDir)
        try render(notch { $0.customPanelWidth = 460 }.root, "shell-width-460", outputDir)
    }

    /// Écran sans encoche : encoche virtuelle de 200 pt sur une barre des menus de 24 pt, noire ou teintée.
    func testRenderVirtualNotch() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        func virtual(expanded: Bool, ears: Bool = false, configure: (Preferences) -> Void = { _ in }) -> NotchHarness {
            let notch = NotchHarness(self, store: ears ? .working(1) : SessionStore())
            notch.model.hasNotch = false
            notch.model.notchSize = CGSize(width: NotchScreenPicker.virtualNotchWidth, height: 24)
            configure(notch.prefs)
            notch.model.isExpanded = expanded
            return notch
        }
        let size = CGSize(width: NotchController.panelSize.width, height: 120)
        try render(virtual(expanded: false).root, "shell-virtual-collapsed", outputDir, size: size)
        try render(virtual(expanded: false, ears: true).root, "shell-virtual-collapsed-ears", outputDir, size: size)
        try render(virtual(expanded: false) {
            $0.panelBackground = .midnight
            $0.tintCollapsed = true
        }.root, "shell-virtual-collapsed-tinted", outputDir, size: size)
        try render(virtual(expanded: true) { $0.panelBackground = .graphite }.root, "shell-virtual-expanded",
                   outputDir)
    }

    func testRenderSettingsPanes() throws {
        guard let outputDir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let notch = NotchHarness(self)
        func pane(_ section: SettingsSection, _ name: String) throws {
            let view = SettingsView(prefs: notch.prefs, registry: notch.registry, updater: Updater(), selection: section)
            try render(view, name, outputDir, size: SettingsWindow.size, background: nil)
            // Bas du volet (le formulaire défile).
            try render(view, name + "-bottom", outputDir, size: SettingsWindow.size, background: nil, scrolledDown: true)
        }
        try pane(.general, "shell-settings-general")
        try pane(.appearance, "shell-settings-appearance")
        try pane(.privacy, "shell-settings-privacy")

        // Masquée une heure, ouverture au clic, raccourcis choisis.
        notch.prefs.hide(.oneHour)
        notch.prefs.openTrigger = .click
        notch.prefs.closeOnClickOutside = true
        notch.prefs.toggleHotKey = .optionCommandN
        notch.prefs.hideHotKey = .controlOptionSpace
        notch.prefs.screenChoice = ScreenChoice.mouse
        try pane(.general, "shell-settings-general-hidden")

        // Apparence : largeur libre, fond personnalisé translucide, sans ombre, accent bleu.
        notch.prefs.customPanelWidth = 680
        notch.prefs.panelBackground = .custom
        notch.prefs.customBackgroundHex = "3A1F5D"
        notch.prefs.backgroundOpacity = 0.8
        notch.prefs.panelShadow = false
        notch.prefs.accentHex = "4C8DFF"
        notch.prefs.animationSpeed = .gentle
        try pane(.appearance, "shell-settings-appearance-custom")
        notch.prefs.panelBackground = .midnight
        notch.prefs.customPanelWidth = nil
        notch.prefs.panelSize = .compact
        notch.prefs.backgroundOpacity = 1
        notch.prefs.panelShadow = true
        try render(NotchAppearancePreview(prefs: notch.prefs).frame(width: 480).padding(),
                   "shell-preview-midnight-compact", outputDir, size: CGSize(width: 512, height: 190))
    }

    /// Fenêtre hors écran + rendu de l'arbre de calques (comme `SnapshotTests`).
    private func render<V: View>(_ view: V, _ name: String, _ dir: URL, size: CGSize = NotchController.panelSize,
                                 background: Color? = Color(white: 0.85), scrolledDown: Bool = false) throws {
        let hosting = NSHostingView(rootView: view.background(background ?? Color(nsColor: .windowBackgroundColor)))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        defer { window.close() }
        if scrolledDown {
            // Le formulaire du volet : la vue défilante la plus haute (la barre latérale est plus courte).
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
            }
            if let form = scrollViews(hosting).max(by: {
                ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
            }), let document = form.documentView {
                let bottom = document.isFlipped ? document.frame.height - form.contentView.bounds.height : 0
                form.contentView.scroll(to: NSPoint(x: 0, y: max(0, bottom)))
                form.reflectScrolledClipView(form.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                hosting.layoutSubtreeIfNeeded()
            }
        }

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
    }
}
