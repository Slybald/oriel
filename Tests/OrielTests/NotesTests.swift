import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Notes rapides sur doubles : horloge, planificateurs, presse-papiers, clavier, dossier jetable.
final class NotesRig {
    let clock = FakeClock()
    let timers = ManualScheduler()
    let writes = ManualScheduler()
    let center = NotificationCenter()
    let directory: URL
    private(set) var copied: [String] = []
    private(set) var keyboardReleases = 0
    private(set) var revealed: [URL] = []

    private var modules: [NotesModule] = []

    init(_ test: XCTestCase) throws {
        directory = try makeTemporaryDirectory(test)
        // Enregistré après la suppression du dossier, donc exécuté avant : une écriture lancée en fin de test ne
        // recrée pas le dossier supprimé.
        test.addTeardownBlock { [self] in modules.forEach { $0.saveNow() } }
    }

    var fileURL: URL { directory.appendingPathComponent("notes.json") }

    func makeModule() -> NotesModule {
        let module = NotesModule(directory: directory, clock: clock.read, scheduler: timers.scheduler,
                                 fileScheduler: writes.scheduler, copy: { [self] in copied.append($0) },
                                 releaseKeyboard: { [self] in keyboardReleases += 1 },
                                 reveal: { [self] in revealed.append($0) }, center: center)
        modules.append(module)
        return module
    }

    func startedModule() -> NotesModule {
        let module = makeModule()
        module.start()
        return module
    }

    /// Une note créée puis remplie, `seconds` après la précédente.
    @discardableResult
    func write(_ module: NotesModule, _ text: String, after seconds: TimeInterval = 1) -> UUID {
        clock.advance(seconds)
        module.newNote()
        let id = module.selectedID!
        module.setText(text, for: id)
        return id
    }

    func savedNotes() throws -> [Note] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NotesModule.FileContent.self, from: Data(contentsOf: fileURL)).notes
    }
}

final class NotesTests: XCTestCase {
    // MARK: Création et titre

    func testStartingWithoutNotesGivesAnEmptyNoteReadyToType() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        XCTAssertEqual(module.notes.count, 1)
        XCTAssertEqual(module.selectedNote?.text, "")
        XCTAssertEqual(module.id, "notes")
        XCTAssertNil(module.makeCompactView(), "pas de résumé compact")
        XCTAssertNil(module.ears, "pas d'oreilles")
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
        XCTAssertEqual(module.title, "Notes rapides")

        module.newNote()
        XCTAssertEqual(module.notes.count, 1, "la note vide est réutilisée, pas empilée")
    }

    func testTitleIsTheFirstNonEmptyLine() {
        XCTAssertEqual(Note.makeTitle("Courses\nlait\npain"), "Courses")
        XCTAssertEqual(Note.makeTitle("\n  \n   Idée du jour  \nsuite"), "Idée du jour")
        XCTAssertEqual(Note.makeTitle(""), "")
        XCTAssertEqual(Note.makeTitle(" \n\t\n "), "")
        XCTAssertEqual(Note.makeTitle(String(repeating: "a", count: 200)).count, 80)
        XCTAssertEqual(Note.makeTitle(String(repeating: " ", count: 600) + "perdu"), "", "seul le début est lu")
    }

    func testTitleFollowsTheText() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let id = module.selectedID!
        module.setText("Premier titre\nsuite", for: id)
        XCTAssertEqual(module.selectedNote?.title, "Premier titre")
        module.setText("Autre\nsuite", for: id)
        XCTAssertEqual(module.selectedNote?.title, "Autre")
    }

    // MARK: Tri

    func testPinnedNotesComeFirstThenMostRecentlyEdited() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let old = rig.write(module, "ancienne")
        let middle = rig.write(module, "milieu")
        let recent = rig.write(module, "récente")
        XCTAssertEqual(module.notes.map(\.id), [recent, middle, old])

        module.togglePin(old)
        XCTAssertEqual(module.notes.map(\.id), [old, recent, middle])

        rig.clock.advance(5)
        module.setText("milieu modifié", for: middle)
        XCTAssertEqual(module.notes.map(\.id), [old, middle, recent], "modifiée = remontée parmi les non épinglées")

        module.togglePin(middle)
        module.togglePin(old)
        XCTAssertEqual(module.notes.map(\.id), [middle, recent, old])
        XCTAssertEqual(module.notes.first?.pinned, true)
    }

    func testTypingTheSameTextDoesNotMoveOrSave() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let first = rig.write(module, "a")
        rig.write(module, "b")
        let pending = rig.writes.pending.count
        rig.clock.advance(10)
        module.setText("a", for: first)
        XCTAssertEqual(module.notes.last?.id, first)
        XCTAssertEqual(rig.writes.pending.count, pending)
    }

    // MARK: Sauvegarde

    func testSaveIsDebouncedToTheLastKeystroke() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let id = module.selectedID!
        module.setText("a", for: id)
        module.setText("ab", for: id)
        module.setText("abc", for: id)
        XCTAssertEqual(rig.writes.pending.count, 1, "chaque frappe repousse l'écriture")
        XCTAssertEqual(rig.writes.pending.first?.delay, NotesModule.saveDelay)
        XCTAssertEqual(NotesModule.saveDelay, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.fileURL.path))

        rig.writes.fire(delay: 1)
        module.saveNow()
        XCTAssertEqual(try rig.savedNotes().map(\.text), ["abc"])
    }

    func testTextIsWrittenWhenSwitchingNotes() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let first = rig.write(module, "première")
        rig.write(module, "seconde")
        module.select(first)
        module.saveNow()
        XCTAssertEqual(Set(try rig.savedNotes().map(\.text)), ["première", "seconde"])
    }

    func testTextIsWrittenWhenThePanelCollapses() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        rig.write(module, "à garder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.fileURL.path))
        module.stop()
        XCTAssertEqual(try rig.savedNotes().map(\.text), ["à garder"])
        XCTAssertEqual(rig.keyboardReleases, 1, "le clavier retourne à l'app de devant")
        XCTAssertTrue(rig.writes.pending.isEmpty, "le délai armé est annulé")
    }

    func testTextIsWrittenWhenTheAppTerminates() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        rig.write(module, "avant la sortie")
        rig.center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(try rig.savedNotes().map(\.text), ["avant la sortie"])

        module.stop()
        try FileManager.default.removeItem(at: rig.fileURL)
        rig.center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.fileURL.path), "observateur retiré à l'arrêt")
    }

    func testCollapsingWithoutChangesWritesNothing() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        module.stop()
        module.start()
        module.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.fileURL.path))
    }

    func testFileIsPrivateAtomicAndKeepsEverythingAcrossARelaunch() throws {
        let rig = try NotesRig(self)
        let first = rig.startedModule()
        let a = rig.write(first, "Une idée\nlongue")
        let b = rig.write(first, "Un numéro")
        first.togglePin(a)
        first.stop()

        let attributes = try FileManager.default.attributesOfItem(atPath: rig.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rig.directory.path), ["notes.json"])

        let second = rig.startedModule()
        XCTAssertEqual(second.notes.map(\.id), [a, b])
        XCTAssertEqual(second.notes.first?.pinned, true)
        XCTAssertEqual(second.notes.first?.text, "Une idée\nlongue")
        XCTAssertEqual(second.selectedID, a, "la première de la liste est ouverte")
    }

    func testNothingIsReadWhileTheModuleIsNotStarted() throws {
        let rig = try NotesRig(self)
        try Data("illisible".utf8).write(to: rig.fileURL)
        let module = rig.makeModule()
        _ = module.title
        _ = module.makeView()
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.fileURL.path))
        XCTAssertTrue(module.notes.isEmpty)
    }

    func testCorruptJSONIsSetAsideAndNotesStartOver() throws {
        let rig = try NotesRig(self)
        try Data("{ \"notes\": [oups".utf8).write(to: rig.fileURL)
        let module = rig.startedModule()
        XCTAssertEqual(module.notes.count, 1, "juste la note vide")
        XCTAssertEqual(module.selectedNote?.text, "")
        let aside = rig.fileURL.appendingPathExtension("corrupt")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ \"notes\": [oups")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.fileURL.path), "pas de fichier vide à la place")
        XCTAssertEqual(module.notice, "Notes illisibles : copie gardée dans notes.json.corrupt", "dit où elles sont")

        rig.write(module, "nouvelle vie")
        module.stop()
        XCTAssertEqual(try rig.savedNotes().map(\.text), ["nouvelle vie"])
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ \"notes\": [oups", "l'ancien reste")
    }

    func testValidJSONOfAnotherShapeIsAlsoSetAside() throws {
        let rig = try NotesRig(self)
        try Data("[1, 2, 3]".utf8).write(to: rig.fileURL)
        let module = rig.startedModule()
        XCTAssertEqual(module.notes.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.fileURL.appendingPathExtension("corrupt").path))
    }

    /// Le fichier existe mais ne se lit pas (droits) : il n'est pas pris pour « absent » puis écrasé.
    func testExistingButUnreadableFileIsSetAsideNotOverwritten() throws {
        let rig = try NotesRig(self)
        let json = "{\"version\":1,\"notes\":[{\"id\":\"\(UUID().uuidString)\",\"text\":\"précieuse\"}]}"
        try Data(json.utf8).write(to: rig.fileURL)
        let aside = rig.fileURL.appendingPathExtension("corrupt")
        XCTAssertEqual(chmod(rig.fileURL.path, 0o000), 0)
        addTeardownBlock {
            chmod(rig.fileURL.path, 0o600)
            chmod(aside.path, 0o600)
        }

        let module = rig.startedModule()
        XCTAssertEqual(module.notes.count, 1, "juste la note vide")
        XCTAssertEqual(module.notice, "Notes illisibles : copie gardée dans notes.json.corrupt")
        rig.write(module, "autre chose")
        module.stop()

        XCTAssertEqual(try rig.savedNotes().map(\.text), ["autre chose"])
        chmod(aside.path, 0o600)
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), json, "l'ancien fichier est intact")
    }

    /// Une entrée invalide n'emporte pas les autres : les bonnes notes restent, l'original est copié en `.corrupt`.
    func testOneInvalidNoteDoesNotTakeTheOthers() throws {
        let rig = try NotesRig(self)
        let good = UUID()
        let json = "{\"version\":1,\"notes\":[{\"id\":\"\(good.uuidString)\",\"text\":\"bonne\"},"
            + "{\"id\":\"pas-un-uuid\",\"text\":\"cassée\"},42,{\"text\":\"sans identifiant\"}]}"
        try Data(json.utf8).write(to: rig.fileURL)

        let module = rig.startedModule()
        XCTAssertEqual(module.notes.map(\.id), [good])
        XCTAssertEqual(module.selectedID, good)
        XCTAssertEqual(module.notice, "Notes illisibles : copie gardée dans notes.json.corrupt")
        let aside = rig.fileURL.appendingPathExtension("corrupt")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), json, "copie, pas déplacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.fileURL.path), "le fichier d'origine reste en place")

        module.togglePin(good)
        module.stop()
        XCTAssertNil(module.notice, "le message disparaît au repli")
        XCTAssertEqual(try rig.savedNotes().map(\.id), [good])
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), json, "l'original n'est pas touché par l'écriture")
        XCTAssertEqual(rig.timers.pending.count, 0, "aucun minuteur pour le message")
    }

    func testAFullyValidFileKeepsNoCopyAndNoNotice() throws {
        let rig = try NotesRig(self)
        let writer = rig.startedModule()
        rig.write(writer, "une")
        writer.stop()
        let module = rig.startedModule()
        XCTAssertEqual(module.notes.count, 1)
        XCTAssertNil(module.notice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.fileURL.appendingPathExtension("corrupt").path))
    }

    func testNoteDecodingToleratesMissingOptionalFields() throws {
        let rig = try NotesRig(self)
        let id = UUID()
        let json = "{\"version\":1,\"notes\":[{\"id\":\"\(id.uuidString)\",\"text\":\"minimal\"}]}"
        try Data(json.utf8).write(to: rig.fileURL)
        let module = rig.startedModule()
        XCTAssertEqual(module.notes.first?.id, id)
        XCTAssertEqual(module.notes.first?.title, "minimal")
        XCTAssertEqual(module.notes.first?.pinned, false)
    }

    // MARK: Suppression et annulation

    func testDeleteThenUndoRestoresTheNote() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let a = rig.write(module, "a")
        let b = rig.write(module, "b")
        let c = rig.write(module, "c")
        module.togglePin(b)
        module.select(b)

        module.delete(b)
        XCTAssertEqual(module.notes.map(\.id), [c, a])
        XCTAssertEqual(module.selectedID, c, "le voisin prend la place")
        XCTAssertEqual(module.deleted?.id, b)
        XCTAssertEqual(rig.timers.pending.first?.delay, NotesModule.undoDelay)
        XCTAssertEqual(NotesModule.undoDelay, 5)

        module.undoDelete()
        XCTAssertEqual(module.notes.map(\.id), [b, c, a], "épinglée : retrouve sa place")
        XCTAssertEqual(module.selectedID, b)
        XCTAssertEqual(module.notes.first?.pinned, true)
        XCTAssertNil(module.deleted)
        XCTAssertTrue(rig.timers.pending.isEmpty)
        module.saveNow()
        XCTAssertEqual(Set(try rig.savedNotes().map(\.id)), [a, b, c])
    }

    func testUndoExpiresAfterAFewSeconds() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let a = rig.write(module, "a")
        rig.write(module, "b")
        module.delete(a)
        XCTAssertNotNil(module.deleted)
        rig.timers.fire(delay: NotesModule.undoDelay)
        XCTAssertNil(module.deleted)
        module.undoDelete()
        XCTAssertEqual(module.notes.count, 1)
        module.saveNow()
        XCTAssertEqual(try rig.savedNotes().count, 1, "supprimée pour de bon")
    }

    /// Deux suppressions rapprochées : « Annuler » rend la dernière, puis l'avant-dernière.
    func testSeveralDeletionsAreUndoneLastFirst() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let a = rig.write(module, "a")
        let b = rig.write(module, "b")
        let c = rig.write(module, "c")
        module.delete(a)
        module.delete(b)
        XCTAssertEqual(module.deleted?.id, b)
        XCTAssertEqual(rig.timers.pending.count, 1, "un seul délai d'annulation")
        XCTAssertEqual(module.notes.map(\.id), [c])

        module.undoDelete()
        XCTAssertEqual(module.notes.count, 2)
        XCTAssertEqual(module.deleted?.id, a, "la précédente reste annulable")
        XCTAssertEqual(rig.timers.pending.count, 1, "le délai repart")
        module.undoDelete()
        XCTAssertEqual(Set(module.notes.map(\.id)), [a, b, c])
        XCTAssertNil(module.deleted)
        XCTAssertTrue(rig.timers.pending.isEmpty)
        module.undoDelete()
        XCTAssertEqual(module.notes.count, 3, "plus rien à annuler")
    }

    func testTheUndoHistoryIsBounded() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let ids = (0..<(NotesModule.maxUndo + 3)).map { rig.write(module, "note \($0)") }
        ids.forEach(module.delete)
        XCTAssertEqual(module.deletedNotes.count, NotesModule.maxUndo)
        XCTAssertEqual(module.deleted?.id, ids.last)
        XCTAssertEqual(module.deletedNotes.first?.id, ids[3], "les plus anciennes sont oubliées")
    }

    func testDeletingTheLastNoteLeavesAnEmptyOneReady() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let only = rig.write(module, "seule")
        module.delete(only)
        XCTAssertEqual(module.notes.count, 1)
        XCTAssertEqual(module.selectedNote?.text, "")
        XCTAssertNotNil(module.deleted)
        module.stop()
        XCTAssertEqual(try rig.savedNotes().count, 0)
    }

    func testPanelCollapseDropsEmptyNotesButKeepsTheUndoUntilItsDeadline() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let a = rig.write(module, "a")
        rig.write(module, "b")
        module.delete(a)
        module.newNote()
        XCTAssertEqual(module.notes.count, 2, "b et la note vide")
        rig.clock.advance(2)
        module.stop()
        XCTAssertEqual(module.notes.map(\.text), ["b"])
        XCTAssertEqual(module.deleted?.id, a, "replier n'efface pas l'annulation")
        XCTAssertTrue(rig.timers.pending.isEmpty, "replié : aucun minuteur en attente")

        rig.clock.advance(1)
        module.start()
        XCTAssertEqual(module.selectedNote?.text, "b")
        XCTAssertEqual(module.deleted?.id, a)
        XCTAssertEqual(try XCTUnwrap(rig.timers.pending.first?.delay), NotesModule.undoDelay - 3, accuracy: 0.001,
                       "il reste le temps d'origine, pas un nouveau délai")
        module.undoDelete()
        XCTAssertEqual(Set(module.notes.map(\.text)), ["a", "b"])
    }

    func testUndoIsForgottenWhenThePanelReopensAfterTheDeadline() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let a = rig.write(module, "a")
        rig.write(module, "b")
        module.delete(a)
        module.stop()
        rig.clock.advance(NotesModule.undoDelay + 1)
        module.start()
        XCTAssertNil(module.deleted)
        XCTAssertTrue(rig.timers.pending.isEmpty)
        module.undoDelete()
        XCTAssertEqual(module.notes.map(\.text), ["b"])
    }

    func testLeavingAnEmptyNoteRemovesIt() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let a = rig.write(module, "a")
        module.newNote()
        XCTAssertEqual(module.notes.count, 2)
        module.select(a)
        XCTAssertEqual(module.notes.count, 1)
    }

    // MARK: Plafonds

    func testNoMoreThan200Notes() throws {
        let rig = try NotesRig(self)
        let base = rig.clock.now
        let notes = (0..<NotesModule.maxNotes).map { index in
            Note(text: "note \(index)", created: base.addingTimeInterval(TimeInterval(index)))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(NotesModule.FileContent(notes: notes)).write(to: rig.fileURL)

        let module = rig.startedModule()
        XCTAssertEqual(module.notes.count, 200)
        module.newNote()
        XCTAssertEqual(module.notes.count, 200)
        XCTAssertEqual(module.notice, "Limite de 200 notes atteinte")
        rig.timers.fire(delay: NotesModule.noticeDelay)
        XCTAssertNil(module.notice)

        module.delete(module.notes[0].id)
        module.newNote()
        XCTAssertEqual(module.notes.count, 200, "une place libérée, une note vide prend la place")
        XCTAssertEqual(module.selectedNote?.text, "")
    }

    func testNoteTextIsCappedAt100000Characters() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let id = module.selectedID!
        let atLimit = String(repeating: "é", count: NotesModule.maxLength)
        XCTAssertEqual(module.setText(atLimit, for: id), atLimit)
        XCTAssertNil(module.notice)

        let kept = module.setText(atLimit + "plus", for: id)
        XCTAssertEqual(kept.count, 100_000)
        XCTAssertEqual(module.selectedNote?.text.count, 100_000)
        XCTAssertEqual(module.notice, "Note limitée à 100000 caractères")
    }

    func testAnOversizedNoteFromAFileIsNeverTruncatedBySmallEdits() throws {
        let rig = try NotesRig(self)
        let big = String(repeating: "x", count: 120_000)
        let note = Note(text: big, created: rig.clock.now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(NotesModule.FileContent(notes: [note])).write(to: rig.fileURL)

        let module = rig.startedModule()
        XCTAssertEqual(module.notes.first?.text.count, 120_000)
        XCTAssertEqual(module.setText(big + "y", for: note.id).count, 120_000, "pas de croissance au-delà de l'existant")
        let shorter = String(big.dropLast(10))
        XCTAssertEqual(module.setText(shorter, for: note.id).count, 119_990, "on peut réduire")
    }

    // MARK: Recherche, copie, réglages

    func testSearchAppearsOnlyBeyondEightNotes() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        for index in 0..<8 { rig.write(module, "note \(index)") }
        XCTAssertFalse(module.showsSearch)
        module.query = "note 3"
        XCTAssertEqual(module.visibleNotes.count, 8, "pas de recherche tant que la liste est courte")

        rig.write(module, "Réunion à 14h : café")
        XCTAssertTrue(module.showsSearch)
        XCTAssertEqual(module.visibleNotes.map(\.text), ["note 3"], "la recherche s'applique dès que la liste est longue")
        module.query = "reunion CAFE"
        XCTAssertEqual(module.visibleNotes.count, 0, "les deux mots doivent se suivre")
        module.query = "reunion"
        XCTAssertEqual(module.visibleNotes.map(\.text), ["Réunion à 14h : café"], "sans casse ni accents")
        module.query = "  "
        XCTAssertEqual(module.visibleNotes.count, 9)
        module.stop()
        XCTAssertEqual(module.query, "", "la recherche est vidée au repli")
    }

    func testCopyAllSendsTheWholeTextToThePasteboardCallback() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let id = rig.write(module, "ligne 1\nligne 2")
        module.copyAll(id)
        XCTAssertEqual(rig.copied, ["ligne 1\nligne 2"])
        module.newNote()
        module.copyAll(module.selectedID!)
        XCTAssertEqual(rig.copied.count, 1, "rien à copier dans une note vide")
    }

    func testRevealPointsToTheFileOrItsFolder() throws {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        module.revealData()
        XCTAssertEqual(rig.revealed.map(\.path), [rig.directory.path])
        rig.write(module, "x")
        module.saveNow()
        module.revealData()
        XCTAssertEqual(rig.revealed.last?.path, rig.fileURL.path)
        XCTAssertNotNil(module.makeSettingsView())
    }

    func testCharacterCountFormat() {
        XCTAssertEqual(NotesFormat.characters(1), "1 caractère")
        XCTAssertEqual(NotesFormat.characters(2), "2 caractères")
        XCTAssertTrue(NotesFormat.characters(12_345).hasSuffix(" caractères"))
        XCTAssertEqual(NotesFormat.relative(Date(), now: Date()), "À l'instant")
    }

    func testDefaultInitUsesATemporaryFolderUnderTests() {
        XCTAssertTrue(ModuleDataDirectory.standard.path.contains("oriel-tests-data"),
                      "jamais le vrai ~/Library/Application Support/Oriel pendant les tests")
        XCTAssertTrue(NotesModule().dataURL.path.contains("oriel-tests-data"))
    }

    // MARK: Éditeur AppKit

    /// L'éditeur enveloppé : la frappe remonte au module, un changement de note remplace le texte, et le texte
    /// du module n'écrase pas ce qui vient d'être tapé.
    func testEditorReportsTypingAndSwitchesNotes() throws {
        _ = NSApplication.shared
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        let first = rig.write(module, "un")
        let second = rig.write(module, "autre")

        var shown = first
        let hosting = NSHostingController(rootView: NotesEditorProbe(module: module, noteID: Binding(get: { shown }, set: { shown = $0 })))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 320, height: 200))
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        hosting.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let textView = try XCTUnwrap(Self.findTextView(in: window.contentView))
        XCTAssertEqual(textView.string, "un")
        textView.insertText(" Bonjour", replacementRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(module.notes.first { $0.id == first }?.text, "un Bonjour")
        XCTAssertEqual(textView.string, "un Bonjour")

        shown = second
        hosting.rootView = NotesEditorProbe(module: module, noteID: Binding(get: { shown }, set: { shown = $0 }))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(textView.string, "autre")
        XCTAssertFalse(textView.isRichText)
        XCTAssertTrue(textView.allowsUndo)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
    }

    private static func findTextView(in view: NSView?) -> NotesNSTextView? {
        guard let view else { return nil }
        if let found = view as? NotesNSTextView { return found }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }
}

/// Un éditeur seul, branché sur le module comme dans `NotesEditorCard`.
private struct NotesEditorProbe: View {
    @ObservedObject var module: NotesModule
    @Binding var noteID: UUID

    var body: some View {
        NotesTextView(noteID: noteID, text: module.notes.first { $0.id == noteID }?.text ?? "", placeholder: "…",
                      focusToken: 0, onChange: { module.setText($0, for: noteID) }, onEscape: {})
            .frame(width: 320, height: 200)
    }
}
