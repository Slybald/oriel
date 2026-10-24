import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Étagère : fichier JSON (aller-retour, 0600, JSON corrompu), signets (fichier déplacé, disparu), doublons et
/// plafond, sélection, ce que le dépôt accepte, et le module (ajout, retrait, tout vider + annuler, retrait après
/// glisser, « vider en quittant »). Dossiers temporaires et presse-papiers nommés : jamais les vrais.
final class ShelfTests: XCTestCase {
    // MARK: Outils

    /// Fichiers vides (un nom finissant par « / » = dossier) dans un dossier temporaire.
    private func makeFiles(_ names: [String]) throws -> (dir: URL, urls: [URL]) {
        let dir = try makeTemporaryDirectory(self)
        let urls = try names.map { name -> URL in
            let url = dir.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
            return url.standardizedFileURL
        }
        return (dir, urls)
    }

    private func wait(_ message: String = "", until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), message)
    }

    private func store(in dir: URL) -> ShelfStore {
        ShelfStore(file: dir.appendingPathComponent("support/shelf.json"))
    }

    private func module(_ store: ShelfStore, defaults: UserDefaults? = nil, undoDelay: TimeInterval = 5,
                        releaseDelay: TimeInterval = 60,
                        thumbnailer: @escaping ShelfModule.Thumbnailer = { _, done in done(nil) }) -> ShelfModule {
        let module = ShelfModule(defaults: defaults ?? makeEphemeralDefaults(self), store: store,
                                 thumbnailer: thumbnailer, saveDelay: 0, undoDelay: undoDelay,
                                 releaseDelay: releaseDelay)
        addTeardownBlock { module.stop() }
        return module
    }

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("oriel-tests-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        return pasteboard
    }

    // MARK: Fichier

    func testStoreRoundTripWritesAPrivateFile() throws {
        let (dir, urls) = try makeFiles(["Rapport.pdf", "Projet/"])
        let store = store(in: dir)
        XCTAssertEqual(store.load(), [], "fichier absent = étagère vide")

        let items = urls.compactMap(ShelfItem.make)
        XCTAssertEqual(items.map { $0.path }, urls.map { $0.path })
        XCTAssertEqual(items.map { $0.isDirectory }, [false, true])
        try store.save(items)
        XCTAssertEqual(store.load(), items)

        let mode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.file.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["shelf.json"], "aucun fichier temporaire laissé")
    }

    /// Le harnais commun crée l'étagère standard et ouvre parfois le panneau : jamais le vrai dossier de l'app.
    func testStandardStoreStaysOutOfTheRealAppFolderUnderTests() {
        XCTAssertFalse(ShelfStore.standard.file.path.hasPrefix(SharedFiles.notchDirectory.path))
        XCTAssertTrue(ShelfStore.standard.file.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    func testCorruptJSONIsSetAsideAndNeverOverwritten() throws {
        let (dir, urls) = try makeFiles(["a.txt"])
        let store = store(in: dir)
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ pas du json".utf8).write(to: store.file)

        XCTAssertEqual(store.load(), [], "on repart de zéro sans planter")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
        XCTAssertEqual(try String(contentsOf: store.corruptFile, encoding: .utf8), "{ pas du json")

        try store.save(urls.compactMap(ShelfItem.make))
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(try String(contentsOf: store.corruptFile, encoding: .utf8), "{ pas du json",
                       "l'ancien fichier reste à part")
    }

    func testBookmarkFollowsAMovedFileAndReportsADeletedOne() throws {
        let (dir, urls) = try makeFiles(["Notes.md", "Brouillon.txt"])
        let items = urls.compactMap(ShelfItem.make)
        XCTAssertEqual(items.count, 2)

        let moved = dir.appendingPathComponent("Rangé/Notes renommées.md")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: urls[0], to: moved)
        guard case let .found(path, _) = items[0].resolve() else { return XCTFail("fichier déplacé perdu") }
        XCTAssertEqual(path, moved.standardizedFileURL.path)

        try FileManager.default.removeItem(at: urls[1])
        XCTAssertEqual(items[1].resolve(), .missing)
    }

    /// Corbeille de l'utilisateur (`~/.Trash`) ou d'un volume externe (`/Volumes/X/.Trashes/<uid>/`) : introuvable.
    func testFilesInATrashAreMissing() throws {
        let (_, urls) = try makeFiles([".Trash/a.txt", ".Trashes/501/b.txt", "Trashes/c.txt"])
        XCTAssertEqual(urls.compactMap(ShelfItem.make).map { $0.resolve() == .missing }, [true, true, false])
    }

    // MARK: Liste

    func testAddingIgnoresDuplicatesAndRespectsTheLimit() {
        func item(_ path: String) -> ShelfItem {
            ShelfItem(id: UUID(), bookmark: Data(), path: path, isDirectory: false)
        }
        let existing = [item("/a"), item("/b")]
        let new = [item("/c"), item("/a"), item("/c"), item("/d"), item("/e")]
        let result = ShelfList.adding(new, to: existing, limit: 4)
        XCTAssertEqual(result.items.map { $0.path }, ["/c", "/d", "/a", "/b"], "nouveaux en tête, doublons ignorés")
        XCTAssertEqual(result.refused, 1)

        let capped = ShelfList.adding((0..<60).map { item("/\($0)") }, to: [], limit: 500)
        XCTAssertEqual(capped.items.count, ShelfList.maxCount, "plafond absolu")
        XCTAssertEqual(capped.refused, 10)
    }

    // MARK: Sélection

    func testSelectionFollowsFinderClicks() {
        let ids = (0..<5).map { _ in UUID() }
        var selection = ShelfSelection()
        selection.click(ids[1], order: ids)
        XCTAssertEqual(selection.ids, [ids[1]])
        selection.click(ids[3], command: true, order: ids)
        XCTAssertEqual(selection.ids, [ids[1], ids[3]])
        selection.click(ids[1], command: true, order: ids)
        XCTAssertEqual(selection.ids, [ids[3]], "⌘-clic retire")
        selection.click(ids[0], shift: true, order: ids)
        XCTAssertEqual(selection.ids, Set(ids[0...1]), "⇧-clic : plage depuis le dernier clic (ancre = ids[1])")
        selection.click(ids[3], order: ids)
        selection.click(ids[1], shift: true, order: ids)
        XCTAssertEqual(selection.ids, Set(ids[1...3]))
        selection.click(ids[4], order: ids)
        XCTAssertEqual(selection.ids, [ids[4]], "clic simple : celle-là seule")

        selection.click(ids[2], command: true, order: ids)
        XCTAssertEqual(selection.targets(for: ids[4], order: ids), [ids[2], ids[4]], "geste sur la sélection")
        XCTAssertEqual(selection.targets(for: ids[0], order: ids), [ids[0]], "geste hors sélection")
        selection.keep([ids[4]])
        XCTAssertEqual(selection.ids, [ids[4]])
        selection.clear()
        XCTAssertTrue(selection.ids.isEmpty)
    }

    // MARK: Dépôt

    func testDropAcceptsFilesAndFoldersOnly() throws {
        let (_, urls) = try makeFiles(["Photo.png", "Dossier/"])
        let files = pasteboard()
        files.writeObjects(urls.map { $0 as NSURL })
        XCTAssertTrue(ShelfDrop.hasFiles(files))
        XCTAssertEqual(ShelfDrop.fileURLs(in: files).map { $0.standardizedFileURL.path }, urls.map { $0.path })

        let web = pasteboard()
        web.writeObjects([URL(string: "https://example.com/fichier.pdf")! as NSURL])
        XCTAssertFalse(ShelfDrop.hasFiles(web), "lien web refusé")
        XCTAssertEqual(ShelfDrop.fileURLs(in: web), [])

        let text = pasteboard()
        text.setString("/Users/x/Rapport.pdf", forType: .string)
        XCTAssertFalse(ShelfDrop.hasFiles(text), "texte refusé, même s'il ressemble à un chemin")
    }

    func testDropOperationNeverMoves() {
        XCTAssertEqual(ShelfDrop.operation(for: .every), .copy)
        XCTAssertEqual(ShelfDrop.operation(for: [.link, .move]), .link)
        XCTAssertEqual(ShelfDrop.operation(for: .generic), .generic)
        XCTAssertEqual(ShelfDrop.operation(for: .move), [], "la source supprimerait l'original")
        XCTAssertEqual(ShelfDrop.operation(for: []), [])

        XCTAssertEqual(ShelfDragSource.operations(for: .outsideApplication), [.copy, .link],
                       "vers une autre app : copie ou alias, jamais déplacer")
        XCTAssertEqual(ShelfDragSource.operations(for: .withinApplication), [], "pas de dépôt sur la notch elle-même")
    }

    func testNotchWindowRootReceivesFileDrags() {
        let notch = NotchHarness(self)
        notch.model.isExpanded = true
        let hosting = FirstMouseHostingView(rootView: notch.root)
        hosting.frame = CGRect(origin: .zero, size: NotchController.panelSize)
        let drop = ShelfDropView(frame: hosting.frame)
        drop.addSubview(hosting)
        let window = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = drop
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.close()

        XCTAssertEqual(drop.registeredDraggedTypes, [.fileURL])
        XCTAssertEqual(hosting.registeredDraggedTypes, [], "le contenu SwiftUI laisse les fichiers à la vue racine")
    }

    /// Chaîne complète d'un dépôt sur le panneau déplié, avec un faux glisser : cible, sortie de la zone, dépôt
    /// (fichier et dossier), puis refus d'un « déplacer » seul et du texte.
    func testDropViewTargetsAndAddsFiles() throws {
        let (dir, urls) = try makeFiles(["Photo.png", "Dossier/"])
        let shelf = module(store(in: dir))
        shelf.start()
        let drop = ShelfDropView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let window = NSWindow(contentRect: drop.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = drop
        var inside = true
        var shown = 0
        var dropped = 0
        drop.shelf = shelf
        drop.accepts = { _ in inside }
        drop.showShelf = { shown += 1 }
        drop.dropped = { dropped += 1 }

        let files = pasteboard()
        files.writeObjects(urls.map { $0 as NSURL })
        let drag = FakeDrag(files)
        XCTAssertEqual(drop.draggingEntered(drag), .copy)
        XCTAssertTrue(shelf.isDropTargeted)
        XCTAssertEqual(shown, 1, "l'onglet Étagère passe devant")
        inside = false
        XCTAssertEqual(drop.draggingUpdated(drag), [])
        XCTAssertFalse(shelf.isDropTargeted, "hors de la forme noire")
        inside = true
        XCTAssertEqual(drop.draggingUpdated(drag), .copy)
        XCTAssertTrue(drop.performDragOperation(drag))
        XCTAssertFalse(shelf.isDropTargeted)
        XCTAssertEqual(dropped, 1)
        wait { shelf.items.count == 2 }
        XCTAssertEqual(Set(shelf.items.map { $0.path }), Set(urls.map { $0.path }))

        let move = FakeDrag(files, mask: .move)
        XCTAssertEqual(drop.draggingEntered(move), [], "la source supprimerait l'original")
        XCTAssertFalse(drop.performDragOperation(move))
        let text = pasteboard()
        text.setString(urls[0].path, forType: .string)
        XCTAssertEqual(drop.draggingEntered(FakeDrag(text)), [])
        XCTAssertFalse(drop.performDragOperation(FakeDrag(text)))
        XCTAssertEqual(dropped, 1)
        XCTAssertFalse(shelf.isDropTargeted)
    }

    /// Notch repliée (200 × 32 au centre d'un écran de 1512 × 982) : la forme, les oreilles et une marge.
    func testDropZoneCoversTheNotchAndItsEars() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let notch = CGRect(x: 656, y: 950, width: 200, height: 32)
        let zone = NotchController.dropZone(notch: notch, screen: screen, contentWidth: 0)
        XCTAssertEqual(zone, CGRect(x: 600, y: 934, width: 312, height: 49))
        XCTAssertTrue(zone.contains(CGPoint(x: 756, y: 982)), "pile sur le bord haut de l'écran")
        XCTAssertTrue(zone.contains(CGPoint(x: 606, y: 960)), "sur l'oreille gauche")
        XCTAssertFalse(zone.contains(CGPoint(x: 756, y: 930)), "sous la notch")
        XCTAssertFalse(zone.contains(CGPoint(x: 590, y: 960)), "au-delà de l'oreille")
        XCTAssertEqual(NotchController.dropZone(notch: notch, screen: screen, contentWidth: 400).width, 440,
                       "forme plus large (oreilles d'un module)")
    }

    /// Un glisser passé sur l'Étagère sans dépôt ne change pas l'onglet « dernier utilisé ».
    func testFileDragWithoutDropKeepsTheLastTab() {
        XCTAssertEqual(NotchController.tabToRemember(selected: "shelf", beforeDrag: "media"), "media")
        XCTAssertEqual(NotchController.tabToRemember(selected: "shelf", beforeDrag: nil), "shelf", "dépôt fait")
        XCTAssertEqual(NotchController.tabToRemember(selected: "media", beforeDrag: "claude"), "media",
                       "onglet choisi ensuite à la main")
    }

    // MARK: Module

    func testModuleAddsPersistsAndReloads() throws {
        let (dir, urls) = try makeFiles(["Rapport.pdf", "Image.png", "Projet/"])
        let store = store(in: dir)
        let shelf = module(store)
        shelf.start()
        shelf.add(Array(urls.prefix(2)))
        wait { shelf.items.count == 2 }
        shelf.add([urls[0], urls[2]])
        wait { shelf.items.count == 3 }
        XCTAssertEqual(shelf.items.map { $0.name }, ["Projet", "Rapport.pdf", "Image.png"], "doublon ignoré")
        XCTAssertEqual(shelf.summary, "3 éléments")
        shelf.flushSave()

        let reloaded = module(store)
        XCTAssertTrue(reloaded.items.isEmpty, "arrêté, le module ne lit rien")
        reloaded.start()
        XCTAssertEqual(reloaded.items, shelf.items)
    }

    func testDropsBeyondTheLimitAreRefusedWithANotice() throws {
        let (dir, urls) = try makeFiles(["1", "2", "3", "4"])
        let shelf = module(store(in: dir))
        shelf.limit = 3
        shelf.start()
        shelf.add(urls)
        wait { shelf.items.count == 3 }
        wait { shelf.notice != nil }
        XCTAssertEqual(shelf.notice, "Étagère pleine : 3 éléments au maximum.")
    }

    func testClearAllCanBeUndoneForAFewSeconds() throws {
        let (dir, urls) = try makeFiles(["a", "b"])
        let store = store(in: dir)
        let shelf = module(store, undoDelay: 0.3)
        shelf.start()
        shelf.add(urls)
        wait { shelf.items.count == 2 }
        let before = shelf.items

        shelf.clearAll()
        XCTAssertTrue(shelf.items.isEmpty)
        shelf.flushSave()
        XCTAssertEqual(store.load(), [], "vidée aussi sur le disque")
        shelf.undoClear()
        XCTAssertEqual(shelf.items, before)
        XCTAssertNil(shelf.undoItems)
        shelf.flushSave()
        XCTAssertEqual(store.load(), before)

        shelf.clearAll()
        XCTAssertNotNil(shelf.undoItems)
        wait("l'annulation expire") { shelf.undoItems == nil }
        shelf.undoClear()
        XCTAssertTrue(shelf.items.isEmpty)
    }

    /// Clic sur « Tout vider » puis la souris s'éloigne : le panneau se replie (stop) et se rouvre (start) ;
    /// « Annuler » est toujours là tant que le délai court, et le délai expire aussi panneau replié.
    func testUndoSurvivesCollapsingThePanel() throws {
        let (dir, urls) = try makeFiles(["a", "b"])
        let shelf = module(store(in: dir), undoDelay: 0.3)
        shelf.start()
        shelf.add(urls)
        wait { shelf.items.count == 2 }
        let before = shelf.items

        shelf.clearAll()
        shelf.stop()
        shelf.start()
        XCTAssertEqual(shelf.undoItems, before)
        shelf.undoClear()
        XCTAssertEqual(shelf.items, before)

        shelf.clearAll()
        shelf.stop()
        wait("l'annulation expire panneau replié") { shelf.undoItems == nil }
    }

    func testRemoveAfterDragOnlyWhenEnabledAndSuccessful() throws {
        let (dir, urls) = try makeFiles(["a", "b", "c"])
        let shelf = module(store(in: dir))
        shelf.start()
        shelf.add(urls)
        wait { shelf.items.count == 3 }
        let ids = shelf.items.map { $0.id }

        shelf.dragEnded([ids[0]], operation: .copy)
        XCTAssertEqual(shelf.items.count, 3, "réglage désactivé par défaut")
        shelf.removeAfterDrag = true
        shelf.dragEnded([ids[0]], operation: [])
        XCTAssertEqual(shelf.items.count, 3, "glisser annulé : rien ne bouge")
        shelf.click(ids[0])
        shelf.click(ids[1], command: true)
        shelf.dragEnded([ids[0], ids[1]], operation: .copy)
        XCTAssertEqual(shelf.items.map { $0.id }, [ids[2]])
        XCTAssertTrue(shelf.selection.ids.isEmpty, "la sélection suit")
    }

    func testClearOnQuitKeepsNothingOnDisk() throws {
        let (dir, urls) = try makeFiles(["a"])
        let store = store(in: dir)
        try store.save(urls.compactMap(ShelfItem.make))
        let defaults = makeEphemeralDefaults(self)
        defaults.set(true, forKey: "shelf.clearOnQuit")

        let shelf = module(store, defaults: defaults)
        shelf.start()
        XCTAssertTrue(shelf.items.isEmpty, "rien n'est repris d'un lancement précédent")
        shelf.add(urls)
        wait { shelf.items.count == 1 }
        shelf.flushSave()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path), "liste jamais écrite")

        shelf.clearOnQuit = false
        shelf.flushSave()
        XCTAssertEqual(store.load().count, 1)
    }

    func testShownTabFindsMovedAndMissingFilesThenThumbnails() throws {
        let (dir, urls) = try makeFiles(["Garde.txt", "Supprimé.txt"])
        var requests: [String] = []
        let shelf = module(store(in: dir), releaseDelay: 0.3) { url, done in
            DispatchQueue.main.async { requests.append(url.lastPathComponent) }
            done(NSImage(size: NSSize(width: 4, height: 4)))
        }
        shelf.start()
        shelf.add(urls)
        wait { shelf.items.count == 2 }
        XCTAssertEqual(requests, [], "onglet caché : aucune vignette")

        let moved = dir.appendingPathComponent("Déplacé.txt")
        try FileManager.default.moveItem(at: urls[0], to: moved)
        try FileManager.default.removeItem(at: urls[1])
        shelf.viewAppeared()
        wait { shelf.missing.count == 1 }
        let missing = try XCTUnwrap(shelf.items.first { $0.name == "Supprimé.txt" })
        XCTAssertEqual(shelf.missing, [missing.id])
        XCTAssertTrue(shelf.items.contains { $0.path == moved.standardizedFileURL.path }, "chemin mis à jour")
        wait { shelf.thumbnails.count == 1 }
        XCTAssertEqual(requests, ["Déplacé.txt"], "pas de vignette pour un fichier introuvable")
        XCTAssertEqual(shelf.urls(shelf.items.map { $0.id }), [moved.standardizedFileURL])

        // Repli puis réouverture rapide : vignettes gardées, rien de redemandé à Quick Look.
        shelf.stop()
        shelf.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(shelf.thumbnails.count, 1)
        XCTAssertEqual(requests, ["Déplacé.txt"])

        shelf.stop()
        XCTAssertEqual(shelf.thumbnails.count, 1)
        wait("vignettes libérées un moment après l'arrêt") { shelf.thumbnails.isEmpty }
    }

    /// Icône immédiate : un paquet (.app, .rtfd) a la sienne, pas celle d'un dossier.
    func testPackagesGetTheirOwnIconType() {
        XCTAssertEqual(ShelfModule.iconType(extension: "app", isDirectory: true), .applicationBundle)
        XCTAssertEqual(ShelfModule.iconType(extension: "rtfd", isDirectory: true), .rtfd)
        XCTAssertEqual(ShelfModule.iconType(extension: "", isDirectory: true), .folder)
        XCTAssertEqual(ShelfModule.iconType(extension: "2026", isDirectory: true), .folder, "« Photos.2026 » : dossier")
        XCTAssertEqual(ShelfModule.iconType(extension: "pdf", isDirectory: false), .pdf)
        XCTAssertEqual(ShelfModule.iconType(extension: "", isDirectory: false), .data)
    }

    func testMenuActsOnTheSelectionAndLeavesMissingFilesRemovable() throws {
        let (dir, urls) = try makeFiles(["a", "b"])
        let shelf = module(store(in: dir))
        shelf.start()
        shelf.add(urls)
        wait { shelf.items.count == 2 }
        let ids = shelf.items.map { $0.id }

        let both = shelf.menu(for: ids).items.map { $0.title }
        XCTAssertTrue(both.contains("Ouvrir") && both.contains("Afficher dans le Finder") && both.contains("Coup d'œil"))
        XCTAssertTrue(both.contains("Retirer 2 éléments"))
        XCTAssertTrue(both.contains("Tout vider"))

        try FileManager.default.removeItem(at: urls[0])
        try FileManager.default.removeItem(at: urls[1])
        shelf.viewAppeared()
        wait { shelf.missing.count == 2 }
        XCTAssertEqual(shelf.menu(for: [ids[0]]).items.map { $0.title }, ["Retirer de l'étagère", "Tout vider"])
        let remove = try XCTUnwrap(shelf.menu(for: [ids[0]]).items.first)
        _ = remove.target?.perform(remove.action, with: remove)
        XCTAssertEqual(shelf.items.map { $0.id }, [ids[1]], "un introuvable se retire du menu")
    }

    // MARK: Vignettes : clics

    /// Le dessin d'une vignette laisse passer la souris vers le calque AppKit (clics, menu, glisser), mais le
    /// bouton « retirer » du survol reste au-dessus et cliquable.
    func testTileClicksReachTheAppKitLayerButNotOverTheRemoveButton() throws {
        let (dir, urls) = try makeFiles(["a.txt"])
        let shelf = module(store(in: dir))
        shelf.start()
        shelf.add(urls)
        wait { shelf.items.count == 1 }
        shelf.hovered = shelf.items[0].id

        let hosting = NSHostingView(rootView: ShelfPanel(module: shelf).environment(\.notchContentWidth, 512)
            .frame(width: 512, height: 300, alignment: .top))
        hosting.frame = CGRect(x: 0, y: 0, width: 512, height: 300)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        addTeardownBlock { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        func find(_ view: NSView) -> ShelfItemView? {
            (view as? ShelfItemView) ?? view.subviews.lazy.compactMap(find).first
        }
        let tile = try XCTUnwrap(find(hosting), "calque AppKit de la vignette")
        let flip: (CGFloat) -> CGFloat = { tile.isFlipped ? $0 : tile.bounds.height - $0 }
        let center = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: hosting.superview)
        XCTAssertTrue(hosting.hitTest(center) === tile, "clic au centre : la vignette")
        let corner = tile.convert(NSPoint(x: tile.bounds.maxX - 12, y: flip(12)), to: hosting.superview)
        XCTAssertFalse(hosting.hitTest(corner) === tile, "coin haut droit : le bouton « retirer »")
    }
}

/// Faux glisser : un presse-papiers, un masque d'opérations ; le reste n'est pas lu par `ShelfDropView`.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation

    init(_ pasteboard: NSPasteboard, mask: NSDragOperation = .every) {
        draggingPasteboard = pasteboard
        draggingSourceOperationMask = mask
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { NSPoint(x: 10, y: 10) }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
