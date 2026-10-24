import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Onglet « Étagère » : fichiers et dossiers gardés sous la main, déposés sur la notch (même repliée, voir
/// `NotchController.openForFileDrag` et `ShelfDropView`) puis glissés vers le Finder ou une app.
/// Textes dans Resources/{en,fr}.lproj/Shelf.strings ; réglages dans UserDefaults sous « shelf.… » ;
/// liste dans `shelf.json` (`ShelfStore`).
///
/// - Références, pas de copies : un signet par élément retrouve le fichier déplacé ; un fichier disparu reste
///   grisé (« Introuvable ») jusqu'à ce qu'on le retire.
/// - Arrêté (panneau replié), le module ne fait rien. La liste est lue au premier démarrage ; signets et vignettes
///   ne sont relus que quand l'onglet est à l'écran, hors du main thread (dossiers protégés). Vignettes et icônes
///   survivent à un repli bref (`releaseDelay`) ; « Annuler » survit au repli jusqu'à son échéance.
final class ShelfModule: NotchModule {
    static let moduleId = "shelf"
    let id = ShelfModule.moduleId
    let symbol = "tray"
    var title: String { L("Étagère", table: "Shelf") }

    /// Choix du réglage « Nombre maximal d'éléments ».
    static let limitChoices = [10, 20, 30, ShelfList.maxCount]
    /// Côté des vignettes demandées à Quick Look (pt) ; affichées en 44 pt.
    static let thumbnailSize: CGFloat = 64

    /// Vignette d'un fichier, rendue sur n'importe quel thread (nil = garder l'icône).
    typealias Thumbnailer = (URL, @escaping (NSImage?) -> Void) -> Void

    // MARK: État

    @Published private(set) var items: [ShelfItem] = []
    /// Éléments introuvables (signet qui ne se résout plus, fichier à la corbeille).
    @Published private(set) var missing: Set<UUID> = []
    /// Vignettes Quick Look : au plus une par élément (50), vidées `releaseDelay` après l'arrêt.
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    @Published private(set) var selection = ShelfSelection()
    /// Vignette sous la souris : son bouton « retirer » apparaît.
    @Published var hovered: UUID?
    /// Un glisser de fichiers est au-dessus du panneau : la zone « Déposer ici » s'affiche.
    @Published var isDropTargeted = false
    /// Message bref (étagère pleine, erreur) ; s'efface seul.
    @Published private(set) var notice: String?
    /// « Tout vider » : la liste d'avant, gardée quelques secondes pour « Annuler ».
    @Published private(set) var undoItems: [ShelfItem]?

    // MARK: Réglages

    /// Retirer un élément de l'étagère une fois glissé avec succès vers une autre app.
    @Published var removeAfterDrag: Bool {
        didSet { defaults.set(removeAfterDrag, forKey: Key.removeAfterDrag) }
    }

    /// Rien n'est gardé d'un lancement à l'autre : la liste n'est plus écrite, le fichier est effacé.
    @Published var clearOnQuit: Bool {
        didSet {
            defaults.set(clearOnQuit, forKey: Key.clearOnQuit)
            if loaded { scheduleSave() }
        }
    }

    /// Plafond ; le baisser ne retire rien, les nouveaux dépôts sont refusés tant qu'on est au-dessus.
    @Published var limit: Int {
        didSet { defaults.set(limit, forKey: Key.limit) }
    }

    private enum Key {
        static let removeAfterDrag = "shelf.removeAfterDrag"
        static let clearOnQuit = "shelf.clearOnQuit"
        static let limit = "shelf.limit"
    }

    private let defaults: UserDefaults
    private let store: ShelfStore
    private let thumbnailer: Thumbnailer
    private let saveDelay: TimeInterval
    private let undoDelay: TimeInterval
    private let releaseDelay: TimeInterval
    /// Signets, existence des fichiers et écriture du JSON : jamais sur le main thread.
    private let ioQueue = DispatchQueue(label: "oriel.shelf.io", qos: .utility)
    private var loaded = false
    private var isRunning = false
    /// Vues de l'onglet à l'écran : signets et vignettes ne sont relus que pour elles.
    private var viewers = 0
    /// Change à chaque arrêt : les résultats en retard (signets, vignettes) sont ignorés.
    private var generation = 0
    private var pendingThumbnails: Set<UUID> = []
    private var pendingSave: DispatchWorkItem?
    private var undoWork: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?
    private var releaseWork: DispatchWorkItem?
    /// Icônes par type de fichier (aucun accès au fichier), vidées avec les vignettes.
    private var icons: [String: NSImage] = [:]
    private var sharePicker: NSSharingServicePicker?
    private let preview = ShelfPreview()
    /// Source des glisser vers l'extérieur ; vit avec le module, pas avec la vignette (repliée en cours de route).
    let dragSource = ShelfDragSource()

    init(defaults: UserDefaults = .standard, store: ShelfStore = .standard,
         thumbnailer: @escaping Thumbnailer = ShelfModule.quickLookThumbnail,
         saveDelay: TimeInterval = 0.5, undoDelay: TimeInterval = 6, releaseDelay: TimeInterval = 60) {
        self.defaults = defaults
        self.store = store
        self.thumbnailer = thumbnailer
        self.saveDelay = saveDelay
        self.undoDelay = undoDelay
        self.releaseDelay = releaseDelay
        removeAfterDrag = defaults.bool(forKey: Key.removeAfterDrag)
        clearOnQuit = defaults.bool(forKey: Key.clearOnQuit)
        let saved = defaults.integer(forKey: Key.limit)
        limit = saved > 0 ? min(saved, ShelfList.maxCount) : ShelfList.maxCount
    }

    // MARK: Contrat

    func start() {
        isRunning = true
        releaseWork?.cancel()
        releaseWork = nil
        loadIfNeeded()
        refresh()
    }

    func stop() {
        isRunning = false
        generation += 1
        pendingThumbnails = []
        if hovered != nil { hovered = nil }
        if isDropTargeted { isDropTargeted = false }
        if !selection.ids.isEmpty { selection.clear() }
        // Le panneau se replie dès que la souris sort : une réouverture rapide ne redemande rien à Quick Look.
        releaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.releaseImages() }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay, execute: work)
    }

    private func releaseImages() {
        releaseWork = nil
        icons = [:]
        if !thumbnails.isEmpty { thumbnails = [:] }
    }

    func makeView() -> AnyView { AnyView(ShelfPanel(module: self)) }
    func makeCompactView() -> AnyView? { AnyView(ShelfCompactView(module: self)) }
    func makeSettingsView() -> AnyView? { AnyView(ShelfSettingsView(module: self)) }
    func makeHeaderAccessory() -> AnyView? { AnyView(ShelfHeaderAccessory(module: self)) }

    func viewAppeared() {
        viewers += 1
        refresh()
    }

    func viewDisappeared() {
        viewers = max(0, viewers - 1)
    }

    // MARK: Liste

    private var order: [UUID] { items.map { $0.id } }

    /// « 5 éléments », ou « 2 sélectionnés » (assez court pour tenir dans l'en-tête à 480 pt).
    var summary: String {
        let count = items.count
        let selected = selection.ids.count
        if selected > 0 {
            return String(format: L(selected, one: "%d sélectionné", other: "%d sélectionnés", table: "Shelf"), selected)
        }
        return String(format: L(count, one: "%d élément", other: "%d éléments", table: "Shelf"), count)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if clearOnQuit {
            let store = store
            ioQueue.async { store.erase() }
        } else {
            items = store.load()
        }
    }

    /// Fichiers déposés sur la notch : signets créés hors du main thread, puis ajoutés en tête.
    func add(_ urls: [URL]) {
        loadIfNeeded()
        let known = Set(items.map { $0.path })
        let candidates = urls.map { $0.standardizedFileURL }.filter { !known.contains($0.path) }
        guard !candidates.isEmpty else { return }
        ioQueue.async { [weak self] in
            let made = candidates.compactMap(ShelfItem.make)
            DispatchQueue.main.async { self?.insert(made, failed: candidates.count - made.count) }
        }
    }

    private func insert(_ new: [ShelfItem], failed: Int) {
        let result = ShelfList.adding(new, to: items, limit: limit)
        if result.items != items {
            finishUndo()
            items = result.items
            scheduleSave()
            loadThumbnails()
        }
        if result.refused > 0 {
            show(notice: String(format: L("Étagère pleine : %d éléments au maximum.", table: "Shelf"), limit))
        } else if failed > 0 {
            show(notice: L("Certains éléments n'ont pas pu être ajoutés.", table: "Shelf"))
        }
    }

    func remove(_ ids: [UUID]) {
        let gone = Set(ids)
        guard items.contains(where: { gone.contains($0.id) }) else { return }
        finishUndo()
        items.removeAll { gone.contains($0.id) }
        forget(gone)
        scheduleSave()
    }

    /// Vide l'étagère ; « Annuler » la remet pendant `undoDelay`.
    func clearAll() {
        guard !items.isEmpty else { return }
        let previous = items
        items = []
        forget(Set(previous.map { $0.id }))
        scheduleSave()
        undoItems = previous
        undoWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishUndo() }
        undoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + undoDelay, execute: work)
    }

    func undoClear() {
        guard let previous = undoItems else { return }
        finishUndo()
        items = previous
        scheduleSave()
        refresh()
    }

    private func finishUndo() {
        undoWork?.cancel()
        undoWork = nil
        if undoItems != nil { undoItems = nil }
    }

    private func forget(_ ids: Set<UUID>) {
        if !missing.isDisjoint(with: ids) { missing.subtract(ids) }
        for id in ids where thumbnails[id] != nil { thumbnails[id] = nil }
        if hovered.map(ids.contains) == true { hovered = nil }
        if !selection.ids.isDisjoint(with: ids) { selection.keep(order) }
    }

    private func show(notice text: String) {
        notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // MARK: Fichier

    /// Écriture regroupée et hors du main thread ; « vider en quittant » efface le fichier au lieu d'écrire.
    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = items
        let store = store
        let keep = !clearOnQuit
        let work = DispatchWorkItem { [weak self] in
            guard keep else { return store.erase() }
            do {
                try store.save(snapshot)
            } catch {
                DispatchQueue.main.async {
                    self?.show(notice: L("Impossible d'enregistrer l'étagère.", table: "Shelf"))
                }
            }
        }
        pendingSave = work
        ioQueue.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    /// Écrit tout de suite ce qui attend (tests).
    func flushSave() {
        guard let work = pendingSave else { return }
        pendingSave = nil
        ioQueue.sync { if !work.isCancelled { work.perform() } }
        work.cancel()
    }

    // MARK: Signets et vignettes

    /// Onglet à l'écran : où sont les fichiers maintenant (déplacés, disparus), puis les vignettes manquantes.
    private func refresh() {
        guard isRunning, viewers > 0, !items.isEmpty else { return }
        let snapshot = items
        let generation = generation
        ioQueue.async { [weak self] in
            let resolved = snapshot.map { ($0.id, $0.resolve()) }
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.apply(resolved)
                self.loadThumbnails()
            }
        }
    }

    private func apply(_ resolved: [(UUID, ShelfItem.Resolution)]) {
        var updated = items
        var gone = Set<UUID>()
        for (id, resolution) in resolved {
            guard let index = updated.firstIndex(where: { $0.id == id }) else { continue }
            switch resolution {
            case .missing:
                gone.insert(id)
            case let .found(path, bookmark):
                updated[index].path = path
                if let bookmark { updated[index].bookmark = bookmark }
            }
        }
        if gone != missing { missing = gone }
        if updated != items {
            items = updated
            scheduleSave()
        }
    }

    private func loadThumbnails() {
        guard isRunning, viewers > 0 else { return }
        let generation = generation
        for item in items where thumbnails[item.id] == nil && !missing.contains(item.id)
            && !pendingThumbnails.contains(item.id) {
            let id = item.id
            pendingThumbnails.insert(id)
            thumbnailer(item.url) { [weak self] image in
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    self.pendingThumbnails.remove(id)
                    if let image, self.items.contains(where: { $0.id == id }) { self.thumbnails[id] = image }
                }
            }
        }
    }

    /// Quick Look, hors du main thread : vignette réduite (64 pt) ou, à défaut, l'icône du Finder.
    static func quickLookThumbnail(_ url: URL, _ done: @escaping (NSImage?) -> Void) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: thumbnailSize, height: thumbnailSize),
                                                   scale: 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            done(representation?.nsImage)
        }
    }

    /// Icône du type de fichier, sans toucher au fichier (affichée tout de suite, avant la vignette).
    func icon(for item: ShelfItem) -> NSImage {
        let ext = (item.path as NSString).pathExtension.lowercased()
        let key = item.isDirectory ? "dir.\(ext)" : ext
        if let icon = icons[key] { return icon }
        let icon = NSWorkspace.shared.icon(for: Self.iconType(extension: ext, isDirectory: item.isDirectory))
        if isRunning { icons[key] = icon }
        return icon
    }

    /// Un dossier n'a l'icône d'un paquet (.app, .rtfd, .xcodeproj) que si son extension en déclare un.
    /// `UTType(filenameExtension:)` seul ne cherche que des fichiers (`.data`) : « app » y donne un type sans paquet.
    static func iconType(extension ext: String, isDirectory: Bool) -> UTType {
        guard isDirectory else { return UTType(filenameExtension: ext) ?? .data }
        return UTType(filenameExtension: ext, conformingTo: .package).flatMap { $0.isDynamic ? nil : $0 } ?? .folder
    }

    func image(for item: ShelfItem) -> NSImage {
        thumbnails[item.id] ?? icon(for: item)
    }

    // MARK: Sélection

    func click(_ id: UUID, command: Bool = false, shift: Bool = false) {
        selection.click(id, command: command, shift: shift, order: order)
    }

    func clearSelection() {
        if !selection.ids.isEmpty { selection.clear() }
    }

    func targets(for id: UUID) -> [UUID] {
        selection.targets(for: id, order: order)
    }

    /// Boutons de l'en-tête : la sélection, ou toute l'étagère.
    var selectedOrAll: [UUID] {
        selection.ids.isEmpty ? order : order.filter(selection.contains)
    }

    /// Emplacements actuels, sans les introuvables.
    func urls(_ ids: [UUID]) -> [URL] {
        let wanted = Set(ids)
        return items.filter { wanted.contains($0.id) && !missing.contains($0.id) }.map { $0.url }
    }

    // MARK: Actions

    func open(_ ids: [UUID]) {
        urls(ids).forEach { NSWorkspace.shared.open($0) }
    }

    func reveal(_ ids: [UUID]) {
        let urls = urls(ids)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        NotchController.bringToFront(bundleId: "com.apple.finder")
    }

    func quickLook(_ ids: [UUID]) {
        preview.show(urls(ids))
    }

    func airDrop(_ ids: [UUID]) {
        let urls = urls(ids)
        guard !urls.isEmpty else { return }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            return show(notice: L("AirDrop n'est pas disponible.", table: "Shelf"))
        }
        // La fenêtre AirDrop appartient à l'app : sans activation, elle resterait derrière l'app de devant.
        HookSetup.activateApp()
        service.perform(withItems: urls)
    }

    /// Menu contextuel d'une vignette : agit sur `ids` (la sélection ou la vignette seule).
    func menu(for ids: [UUID]) -> NSMenu {
        let menu = NSMenu()
        let urls = urls(ids)
        if !urls.isEmpty {
            menu.addItem(ShelfMenuItem(L("Ouvrir", table: "Shelf")) { [weak self] in self?.open(ids) })
            menu.addItem(ShelfMenuItem(L("Afficher dans le Finder", table: "Shelf")) { [weak self] in self?.reveal(ids) })
            menu.addItem(ShelfMenuItem(L("Coup d'œil", table: "Shelf")) { [weak self] in self?.quickLook(ids) })
            menu.addItem(.separator())
            if let service = NSSharingService(named: .sendViaAirDrop) {
                let item = ShelfMenuItem(service.title) { [weak self] in self?.airDrop(ids) }
                item.image = service.image.resized(to: 16)
                menu.addItem(item)
            }
            let picker = NSSharingServicePicker(items: urls)
            sharePicker = picker
            menu.addItem(picker.standardShareMenuItem)
            menu.addItem(.separator())
        }
        let remove = ids.count > 1
            ? String(format: L("Retirer %d éléments", table: "Shelf"), ids.count)
            : L("Retirer de l'étagère", table: "Shelf")
        menu.addItem(ShelfMenuItem(remove) { [weak self] in self?.remove(ids) })
        menu.addItem(ShelfMenuItem(L("Tout vider", table: "Shelf")) { [weak self] in self?.clearAll() })
        return menu
    }

    // MARK: Glisser vers l'extérieur

    /// Glisse la vignette (ou toute la sélection qui la contient) hors de la notch. Appelé depuis `mouseDragged`.
    func beginDrag(_ id: UUID, from view: NSView, event: NSEvent) {
        let wanted = Set(targets(for: id))
        let entries = items.filter { wanted.contains($0.id) && !missing.contains($0.id) }
        guard !entries.isEmpty else { return }
        let side: CGFloat = 44
        let origin = NSPoint(x: (view.bounds.width - side) / 2, y: (view.bounds.height - side) / 2 + 8)
        let dragged = entries.enumerated().map { index, item -> NSDraggingItem in
            let dragging = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let offset = CGFloat(min(index, 4)) * 4
            dragging.setDraggingFrame(NSRect(x: origin.x + offset, y: origin.y - offset, width: side, height: side),
                                      contents: image(for: item))
            return dragging
        }
        let ids = entries.map { $0.id }
        dragSource.onEnd = { [weak self] operation in self?.dragEnded(ids, operation: operation) }
        let session = view.beginDraggingSession(with: dragged, event: event, source: dragSource)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// Fin d'un glisser vers l'extérieur : retiré de l'étagère si le dépôt a réussi et que le réglage le demande.
    func dragEnded(_ ids: [UUID], operation: NSDragOperation) {
        guard removeAfterDrag, operation != [] else { return }
        remove(ids)
    }
}

private extension NSImage {
    func resized(to side: CGFloat) -> NSImage {
        let image = copy() as? NSImage ?? self
        image.size = NSSize(width: side, height: side)
        return image
    }
}
