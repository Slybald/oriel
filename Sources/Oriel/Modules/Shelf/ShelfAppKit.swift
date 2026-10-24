import AppKit
import Quartz
import SwiftUI

// MARK: - Dépôt sur la notch

/// Vue racine de la fenêtre de la notch, sous le contenu SwiftUI : reçoit les fichiers glissés sur le panneau
/// déplié et les pose sur l'étagère. Un `onDrop` SwiftUI d'un autre onglet reste prioritaire sur sa propre zone
/// (SwiftUI y place sa propre vue de destination).
final class ShelfDropView: NSView {
    weak var shelf: ShelfModule?
    /// Dépôt possible à ce point de l'écran : module activé, panneau déplié, dans la forme noire.
    var accepts: (NSPoint) -> Bool = { _ in false }
    /// Le glisser arrive : l'onglet Étagère passe devant.
    var showShelf: () -> Void = {}
    /// Des fichiers ont été posés sur l'étagère.
    var dropped: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(ShelfDrop.types)
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setTargeted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setTargeted(false)
        guard let shelf, operation(sender) != [] else { return false }
        let urls = ShelfDrop.fileURLs(in: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        shelf.add(urls)
        dropped()
        return true
    }

    private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let window, accepts(window.convertPoint(toScreen: sender.draggingLocation)),
              ShelfDrop.hasFiles(sender.draggingPasteboard) else { return [] }
        return ShelfDrop.operation(for: sender.draggingSourceOperationMask)
    }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = operation(sender)
        if operation != [], shelf?.isDropTargeted == false { showShelf() }
        setTargeted(operation != [])
        return operation
    }

    private func setTargeted(_ targeted: Bool) {
        if let shelf, shelf.isDropTargeted != targeted { shelf.isDropTargeted = targeted }
    }
}

// MARK: - Vignette

/// Calque AppKit d'une vignette, sous son dessin SwiftUI : clics (sélection, ⌘, ⇧, double-clic pour ouvrir),
/// menu contextuel, survol, et glisser vers le Finder ou une app (plusieurs fichiers, fin du glisser connue,
/// ce que `onDrag` de SwiftUI ne donne pas).
struct ShelfItemInteraction: NSViewRepresentable {
    let id: UUID
    /// Infobulle : le nom complet (la vignette le tronque).
    let name: String
    let module: ShelfModule

    func makeNSView(context: Context) -> ShelfItemView { ShelfItemView() }

    func updateNSView(_ view: ShelfItemView, context: Context) {
        view.itemId = id
        view.module = module
        if view.toolTip != name { view.toolTip = name }
    }
}

final class ShelfItemView: NSView {
    var itemId: UUID?
    weak var module: ShelfModule?
    private var downEvent: NSEvent?
    /// Clic simple sur une vignette déjà sélectionnée : appliqué au relâchement, pour pouvoir glisser la sélection.
    private var deferredClick = false
    private var dragging = false

    /// Le panneau n'est jamais actif : le premier clic compte.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        if let itemId, module?.hovered != itemId { module?.hovered = itemId }
    }

    override func mouseExited(with event: NSEvent) {
        if let itemId, module?.hovered == itemId { module?.hovered = nil }
    }

    override func mouseDown(with event: NSEvent) {
        guard let itemId, let module else { return }
        downEvent = event
        dragging = false
        if event.clickCount == 2 {
            deferredClick = false
            return module.open(module.targets(for: itemId))
        }
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        deferredClick = !command && !shift && module.selection.contains(itemId)
        if !deferredClick { module.click(itemId, command: command, shift: shift) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, !dragging, let itemId, let module else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 9 else { return }
        dragging = true
        deferredClick = false
        module.beginDrag(itemId, from: self, event: down)
    }

    override func mouseUp(with event: NSEvent) {
        if deferredClick, let itemId { module?.click(itemId) }
        deferredClick = false
        downEvent = nil
    }

    /// Clic droit hors de la sélection : la vignette seule est sélectionnée, comme dans le Finder.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let itemId, let module else { return nil }
        if !module.selection.contains(itemId) { module.click(itemId) }
        return module.menu(for: module.targets(for: itemId))
    }
}

// MARK: - Glisser vers l'extérieur

final class ShelfDragSource: NSObject, NSDraggingSource {
    var onEnd: (NSDragOperation) -> Void = { _ in }

    /// Vers une autre app : copie ou alias, jamais déplacer (ni corbeille). Vers la notch elle-même : rien.
    static func operations(for context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link] : []
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operations(for: context)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let done = onEnd
        onEnd = { _ in }
        done(operation)
    }
}

// MARK: - Coup d'œil

/// Panneau Coup d'œil sur les fichiers choisis. Le panneau de la notch ne devient jamais clé : la source est donnée
/// directement au panneau Coup d'œil, sans passer par la chaîne des répondeurs.
final class ShelfPreview: NSObject, QLPreviewPanelDataSource {
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        // Fenêtre de l'app : activée pour passer devant et répondre au clavier (Espace, Échap, flèches).
        HookSetup.activateApp()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

// MARK: - Menu

/// Entrée de menu à fermeture ; la cible d'un NSMenuItem est faible : c'est l'entrée elle-même, gardée par le menu.
final class ShelfMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    @objc private func run() { handler() }
}
