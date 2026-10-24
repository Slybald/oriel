import AppKit
import SwiftUI

struct Note: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String { didSet { title = Self.makeTitle(text) } }
    var pinned: Bool
    let created: Date
    var updated: Date
    /// Première ligne non vide (80 caractères au plus), calculée une fois par modification : la liste ne relit
    /// jamais le texte entier.
    private(set) var title: String

    init(id: UUID = UUID(), text: String = "", pinned: Bool = false, created: Date, updated: Date? = nil) {
        self.id = id
        self.text = text
        self.pinned = pinned
        self.created = created
        self.updated = updated ?? created
        title = Self.makeTitle(text)
    }

    private enum CodingKeys: String, CodingKey { case id, text, pinned, created, updated }

    /// Tolérant : seuls l'identifiant et le texte sont obligatoires.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        let updated = try container.decodeIfPresent(Date.self, forKey: .updated)
        let created = try container.decodeIfPresent(Date.self, forKey: .created) ?? updated ?? Date(timeIntervalSince1970: 0)
        self.init(id: try container.decode(UUID.self, forKey: .id), text: text,
                  pinned: try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false,
                  created: created, updated: updated ?? created)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(created, forKey: .created)
        try container.encode(updated, forKey: .updated)
    }

    static let maxTitleLength = 80

    static func makeTitle(_ text: String) -> String {
        // Seul le début compte : inutile de parcourir une note de 100 000 caractères.
        for line in text.prefix(500).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(maxTitleLength)) }
        }
        return ""
    }

    /// Épinglées d'abord, puis la plus récemment modifiée.
    static func isOrderedBefore(_ lhs: Note, _ rhs: Note) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned }
        if lhs.updated != rhs.updated { return lhs.updated > rhs.updated }
        if lhs.created != rhs.created { return lhs.created > rhs.created }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// Onglet « Notes rapides » : plusieurs notes en texte brut, liste à gauche, éditeur à droite.
/// Textes dans Resources/{en,fr}.lproj/Notes.strings. Pas d'oreilles ni de résumé compact.
///
/// - Données : `notes.json` (0600, atomique), écrit environ 1 s après la dernière frappe (débounce), au changement
///   de note, au repli du panneau (`stop`) et à la fin de l'app (`NSApplication.willTerminateNotification`, écouté
///   tant que le module tourne : l'AppDelegate n'a pas de point d'entrée pour les modules). Une app tuée de force
///   perd au plus la dernière seconde de frappe.
/// - Lu au premier `start`, gardé en mémoire ensuite. Jamais lu si le module est désactivé.
/// - Plafonds : 200 notes, 100 000 caractères par note (à la frappe et au collage ; un fichier déjà plus gros n'est
///   jamais tronqué à la lecture).
/// - Une note vide n'est jamais enregistrée : elle disparaît quand on en change ou quand le panneau se replie.
/// - Suppression : jusqu'à `maxUndo` notes restent restaurables (la dernière d'abord) pendant `undoDelay` secondes
///   après la dernière suppression, panneau replié compris (l'échéance est une date, sans minuteur en veille).
/// - Une entrée illisible du fichier n'emporte pas les autres : les notes valides sont chargées, le fichier
///   d'origine est copié en `.corrupt` et un message le dit tant que le panneau reste ouvert.
/// - Clavier : voir `NotchKeyboard` ; le panneau le rend à l'app de devant au repli (`releaseKeyboard`).
final class NotesModule: NotchModule {
    let id = "notes"
    let symbol = "note.text"
    var title: String { L("Notes rapides", table: "Notes") }

    static let maxNotes = 200
    static let maxLength = 100_000
    /// Au-delà, la liste affiche un champ de recherche.
    static let searchThreshold = 8
    static let saveDelay: TimeInterval = 1
    static let undoDelay: TimeInterval = 5
    static let maxUndo = 10
    static let noticeDelay: TimeInterval = 4

    struct FileContent: Codable {
        var version = 1
        var notes: [Note]
        /// Entrées illisibles ignorées à la lecture (jamais écrit).
        var skipped = 0

        private enum CodingKeys: String, CodingKey { case version, notes }

        init(notes: [Note]) { self.notes = notes }

        /// Une note invalide est ignorée, pas le fichier entier.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            var list = try container.nestedUnkeyedContainer(forKey: .notes)
            var notes: [Note] = []
            while !list.isAtEnd {
                if let note = try? list.decode(Note.self) {
                    notes.append(note)
                } else {
                    skipped += 1
                    // Sans cette lecture, l'index ne bouge pas après un échec : boucle sans fin.
                    _ = try? list.decode(AnyEntry.self)
                }
            }
            self.notes = notes
        }

        private struct AnyEntry: Decodable {}
    }

    // MARK: État

    /// Dans l'ordre d'affichage : épinglées, puis les plus récentes.
    @Published private(set) var notes: [Note] = []
    @Published private(set) var selectedID: UUID?
    @Published var query = ""
    /// Notes supprimées, restaurables pendant `undoDelay` (la dernière en dernier).
    @Published private(set) var deletedNotes: [Note] = []
    /// Message bref sous la liste (plafond atteint).
    @Published private(set) var notice: String?

    private let file: SecureJSONFile<FileContent>
    private let clock: () -> Date
    private let scheduler: ModuleScheduler
    private let copyToPasteboard: (String) -> Void
    private let releaseKeyboard: () -> Void
    private let reveal: (URL) -> Void
    private let center: NotificationCenter

    private var loaded = false
    private var terminateObserver: NSObjectProtocol?
    private var cancelUndo: (() -> Void)?
    private var undoDeadline: Date?
    private var cancelNotice: (() -> Void)?

    init(directory: URL = ModuleDataDirectory.standard, clock: @escaping () -> Date = Date.init,
         scheduler: ModuleScheduler = .system, fileScheduler: ModuleScheduler? = nil,
         copy: @escaping (String) -> Void = NotesModule.copyToGeneralPasteboard,
         releaseKeyboard: @escaping () -> Void = { NotchKeyboard.release(force: true) },
         reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
         center: NotificationCenter = .default) {
        self.clock = clock
        self.scheduler = scheduler
        copyToPasteboard = copy
        self.releaseKeyboard = releaseKeyboard
        self.reveal = reveal
        self.center = center
        file = SecureJSONFile(url: directory.appendingPathComponent("notes.json"), debounce: Self.saveDelay,
                              scheduler: fileScheduler ?? scheduler)
    }

    deinit {
        cancelUndo?()
        cancelNotice?()
        if let terminateObserver { center.removeObserver(terminateObserver) }
    }

    static func copyToGeneralPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Contrat

    func start() {
        loadIfNeeded()
        ensureSelection()
        resumeUndo()
        guard terminateObserver == nil else { return }
        // Sans file : exécuté tout de suite, avant la sortie du processus.
        terminateObserver = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: nil) { [weak self] _ in self?.saveNow() }
    }

    /// Panneau replié (ou module désactivé) : plus de note vide, tout est écrit, le clavier est rendu.
    func stop() {
        if let terminateObserver { center.removeObserver(terminateObserver) }
        terminateObserver = nil
        // Le délai d'annulation continue de courir (sa date) ; plus aucun minuteur n'attend pendant le repli.
        cancelUndo?()
        cancelUndo = nil
        cancelNotice?()
        cancelNotice = nil
        if notice != nil { notice = nil }
        if !query.isEmpty { query = "" }
        purgeEmpty(keeping: nil)
        saveNow()
        releaseKeyboard()
    }

    func makeView() -> AnyView { AnyView(NotesPanel(module: self)) }
    func makeSettingsView() -> AnyView? { AnyView(NotesSettingsView(module: self)) }

    // MARK: Lecture et écriture

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let content = file.load { $0.skipped > 0 }
        if let aside = file.asideURL {
            // Sans minuteur : le message reste jusqu'au repli, il ne se perd pas si l'onglet n'est pas à l'écran.
            notice = String(format: L("Notes illisibles : copie gardée dans %@", table: "Notes"), aside.lastPathComponent)
        }
        if let content { notes = content.notes.sorted(by: Note.isOrderedBefore) }
    }

    private func save() {
        file.save(FileContent(notes: notes.filter { !$0.text.isEmpty }))
    }

    /// Écrit tout de suite et attend la fin.
    func saveNow() {
        file.flush()
        file.wait()
    }

    /// Dossier des données (réglages).
    var dataURL: URL { file.url }

    func revealData() {
        reveal(FileManager.default.fileExists(atPath: file.url.path) ? file.url : file.url.deletingLastPathComponent())
    }

    // MARK: Sélection

    /// La note que « Annuler » rend.
    var deleted: Note? { deletedNotes.last }

    var selectedNote: Note? { selectedID.flatMap { id in notes.first { $0.id == id } } }

    var showsSearch: Bool { notes.count > Self.searchThreshold }

    /// Notes affichées dans la liste : toutes, ou celles qui contiennent la recherche.
    var visibleNotes: [Note] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard showsSearch, !needle.isEmpty else { return notes }
        return notes.filter { $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    func select(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        purgeEmpty(keeping: id)
        selectedID = id
        // Changement de note : on écrit sans attendre le délai.
        file.flush()
    }

    /// Une note est toujours sélectionnée : la plus récente, ou une note vide prête à recevoir le texte.
    private func ensureSelection() {
        if let id = selectedID, notes.contains(where: { $0.id == id }) { return }
        if let first = notes.first {
            selectedID = first.id
        } else {
            insertEmptyNote()
        }
    }

    private func insertEmptyNote() {
        let now = clock()
        let note = Note(created: now)
        notes.insert(note, at: 0)
        notes.sort(by: Note.isOrderedBefore)
        selectedID = note.id
    }

    private func purgeEmpty(keeping keep: UUID?) {
        let remaining = notes.filter { !$0.text.isEmpty || $0.id == keep }
        if remaining.count != notes.count { notes = remaining }
    }

    // MARK: Actions

    /// Bouton « + » : une note vide prête à écrire (celle qui l'est déjà est réutilisée).
    func newNote() {
        loadIfNeeded()
        if let selected = selectedNote, selected.text.isEmpty { return }
        if notes.count >= Self.maxNotes {
            return show(notice: String(format: L("Limite de %d notes atteinte", table: "Notes"), Self.maxNotes))
        }
        purgeEmpty(keeping: nil)
        file.flush()
        insertEmptyNote()
    }

    /// Barre de commande : une note avec ce texte (plafonné), sélectionnée ; la note vide qui attendait disparaît.
    /// Faux au plafond de notes.
    @discardableResult
    func addNote(_ text: String) -> Bool {
        loadIfNeeded()
        let text = String(text.prefix(Self.maxLength))
        guard !text.isEmpty, notes.count < Self.maxNotes else { return false }
        purgeEmpty(keeping: nil)
        let note = Note(text: text, created: clock())
        notes = (notes + [note]).sorted(by: Note.isOrderedBefore)
        selectedID = note.id
        save()
        file.flush()
        return true
    }

    /// Texte tapé dans l'éditeur. Rend le texte retenu (tronqué au plafond).
    @discardableResult
    func setText(_ text: String, for id: UUID) -> String {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return text }
        var text = text
        let previous = notes[index].text
        // Le plafond limite la croissance ; un fichier déjà plus gros n'est pas rogné par une simple frappe.
        if text.utf16.count > Self.maxLength {
            let limit = max(Self.maxLength, previous.count)
            if text.count > limit {
                text = String(text.prefix(limit))
                show(notice: String(format: L("Note limitée à %d caractères", table: "Notes"), Self.maxLength))
            }
        }
        guard text != previous else { return text }
        var updated = notes
        updated[index].text = text
        updated[index].updated = clock()
        updated.sort(by: Note.isOrderedBefore)
        notes = updated
        save()
        return text
    }

    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var updated = notes
        updated[index].pinned.toggle()
        updated.sort(by: Note.isOrderedBefore)
        notes = updated
        save()
    }

    func copyAll(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }), !note.text.isEmpty else { return }
        copyToPasteboard(note.text)
    }

    /// Supprime et garde la note `undoDelay` secondes pour l'annuler (avec les précédentes, `maxUndo` au plus).
    func delete(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let note = notes[index]
        var updated = notes
        updated.remove(at: index)
        notes = updated
        if !note.text.isEmpty {
            deletedNotes = Array((deletedNotes + [note]).suffix(Self.maxUndo))
            armUndo()
        }
        if selectedID == id {
            // Le voisin dans la liste prend la place ; sinon une note vide.
            selectedID = notes.isEmpty ? nil : notes[min(index, notes.count - 1)].id
            ensureSelection()
        }
        save()
    }

    func undoDelete() {
        guard let note = deletedNotes.popLast() else { return }
        armUndo()
        guard !notes.contains(where: { $0.id == note.id }) else { return }
        purgeEmpty(keeping: nil)
        var updated = notes
        updated.append(note)
        updated.sort(by: Note.isOrderedBefore)
        notes = updated
        selectedID = note.id
        save()
    }

    /// (Re)lance le délai d'annulation depuis maintenant ; rien à annuler : plus de délai.
    private func armUndo() {
        cancelUndo?()
        cancelUndo = nil
        guard !deletedNotes.isEmpty else { undoDeadline = nil; return }
        undoDeadline = clock().addingTimeInterval(Self.undoDelay)
        waitForUndoExpiry(Self.undoDelay)
    }

    private func waitForUndoExpiry(_ delay: TimeInterval) {
        cancelUndo = scheduler.after(delay) { [weak self] in
            self?.cancelUndo = nil
            self?.undoDeadline = nil
            self?.deletedNotes = []
        }
    }

    /// Le panneau se rouvre : l'annulation vaut encore jusqu'à son échéance, sinon elle est oubliée.
    private func resumeUndo() {
        guard !deletedNotes.isEmpty, cancelUndo == nil else { return }
        let left = undoDeadline?.timeIntervalSince(clock()) ?? 0
        if left > 0 {
            waitForUndoExpiry(left)
        } else {
            undoDeadline = nil
            deletedNotes = []
        }
    }

    private func show(notice text: String) {
        notice = text
        cancelNotice?()
        cancelNotice = scheduler.after(Self.noticeDelay) { [weak self] in
            self?.cancelNotice = nil
            self?.notice = nil
        }
    }
}
