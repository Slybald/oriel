import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendus PNG de l'onglet Notes rapides (vide, rempli, long avec recherche, annulation, fichier abîmé, largeurs, réglages) et
/// mise en page. Ne fait rien sans `ORIEL_SNAPSHOT_DIR`, sauf les mesures.
final class NotesSnapshotTests: XCTestCase {
    /// Des notes sans donnée personnelle, étalées dans le temps pour que les dates relatives varient.
    private func filled(_ rig: NotesRig, count: Int = 5) -> NotesModule {
        let module = rig.makeModule()
        module.start()
        let samples: [(String, TimeInterval)] = [
            ("Courses : lait, œufs, pain\ncitrons, basilic", 5 * 86_400),
            ("Réunion jeudi 14h, salle B\nPréparer les chiffres du trimestre\nDemander le budget formation", 2 * 86_400),
            ("docker compose up -d --build\ndocker logs -f api", 3 * 3_600),
            ("Code wifi invité : 4821-77", 25 * 60),
            ("Idée de nom pour l'app\nEncoche ? Notchbook ? Pocket ?\n\nÀ revoir avec l'équipe : le nom doit se "
             + "prononcer facilement dans les deux langues et rester disponible comme nom de domaine.", 40),
            ("Appeler le garage\nPneus d'hiver avant le 15", 9 * 86_400),
            ("Lire : article sur le Pomodoro", 11 * 86_400),
            ("Livre à rendre vendredi", 12 * 86_400),
            ("Mot de passe du routeur sur l'étiquette", 14 * 86_400),
            ("Gâteau pour l'anniversaire de samedi", 15 * 86_400),
            ("Réunion de quartier : lundi 18h", 20 * 86_400),
            ("Plantes : arroser le ficus le dimanche", 30 * 86_400),
        ]
        let now = Date()
        for (text, age) in samples.prefix(count).sorted(by: { $0.1 > $1.1 }) {
            rig.clock.now = Date(timeIntervalSince1970: (now.timeIntervalSince1970 - age).rounded())
            rig.write(module, text, after: 0)
        }
        rig.clock.now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded())
        return module
    }

    private func scene(_ module: NotesModule, expanded: Bool = true) -> (NotchHarness, ModuleRegistry) {
        TimerNotesSnapshot.scene(self, replacing: module, expanded: expanded)
    }

    func testRenderNotes() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        func show(_ module: NotesModule, _ name: String, size: PanelSize? = nil) throws {
            addTeardownBlock { module.stop() }
            let pair = scene(module)
            if let size { pair.0.prefs.panelSize = size }
            try TimerNotesSnapshot.render(TimerNotesSnapshot.root(pair), name, dir)
        }

        // Vide : l'éditeur prêt avec sa phrase.
        let empty = try NotesRig(self)
        let emptyModule = empty.startedModule()
        try show(emptyModule, "notes-empty")

        // Rempli : une note épinglée, une longue sélectionnée.
        let rig = try NotesRig(self)
        let module = filled(rig)
        module.togglePin(module.notes[2].id)
        module.select(module.notes.first { $0.text.hasPrefix("Réunion") }!.id)
        try show(module, "notes-filled")
        for size in [PanelSize.compact, .large] {
            try show(module, "notes-filled-\(size.rawValue)", size: size)
        }

        // Une note longue à sélectionner.
        let long = module.notes.first { $0.text.hasPrefix("Idée") }!
        module.select(long.id)
        try show(module, "notes-filled-long")

        // Plus de 8 notes : recherche en tête de liste.
        let many = try NotesRig(self)
        let manyModule = filled(many, count: 12)
        manyModule.query = "réunion"
        try show(manyModule, "notes-search")
        manyModule.query = ""
        try show(manyModule, "notes-many")

        // Suppression récente : « Annuler la suppression ».
        manyModule.delete(manyModule.notes[1].id)
        try show(manyModule, "notes-undo")

        // Fichier en partie illisible : les bonnes notes, et où est la copie.
        let damaged = try NotesRig(self)
        let hourAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))
        let json = "{\"version\":1,\"notes\":[{\"id\":\"\(UUID().uuidString)\",\"text\":\"Courses : lait, œufs, pain\","
            + "\"updated\":\"\(hourAgo)\"},{\"id\":\"cassé\",\"text\":\"x\"}]}"
        try Data(json.utf8).write(to: damaged.fileURL)
        try show(damaged.startedModule(), "notes-salvaged")

        // Réglages › Notes rapides.
        let pair = scene(module)
        try TimerNotesSnapshot.render(TimerNotesSnapshot.settings(pair, "notes"), "settings-notes", dir,
                                      size: SettingsWindow.size, background: nil)
    }

    /// Survol : épingler et supprimer sur la ligne, copier, épingler et supprimer sous l'éditeur.
    func testRenderNotesHover() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let rig = try NotesRig(self)
        let module = filled(rig, count: 3)
        addTeardownBlock { module.stop() }
        let notes = module.notes
        let view = HStack(spacing: 8) {
            VStack(spacing: 2) {
                NoteRow(note: notes[0], selected: false, hovering: true, select: {}, pin: {}, delete: {})
                NoteRow(note: notes[1], selected: true, hovering: false, select: {}, pin: {}, delete: {})
            }
            .frame(width: 150)
            NotesEditorCard(module: module, focusToken: 0, hovering: true, requestFocus: {})
                .frame(width: 330, height: 120)
        }
        .padding(12)
        .environment(\.colorScheme, .dark)
        .background(Color.black)
        try TimerNotesSnapshot.render(view, "notes-hover", dir, size: CGSize(width: 520, height: 150))
    }

    /// Un `NSTextView` rendu hors écran : le texte et le texte indicatif apparaissent bien dans la capture.
    func testRenderNotesEditorAlone() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let rig = try NotesRig(self)
        let module = filled(rig, count: 3)
        addTeardownBlock { module.stop() }
        let card = NotesEditorCard(module: module, focusToken: 0, requestFocus: {})
            .environment(\.colorScheme, .dark)
            .frame(width: 360, height: 214)
            .padding(10)
            .background(Color.black)
        try TimerNotesSnapshot.render(card, "notes-editor-card", dir, size: CGSize(width: 380, height: 234))
    }

    // MARK: Mise en page

    /// L'onglet tient dans sa fenêtre à toutes les largeurs, même avec 200 notes et une note de 100 000 caractères.
    func testNotesPanelStaysUnderTheMaximumHeight() throws {
        let rig = try NotesRig(self)
        let module = filled(rig, count: 12)
        module.setText(String(repeating: "ligne très longue de la note\n", count: 3_000), for: module.selectedID!)
        addTeardownBlock { module.stop() }
        for size in PanelSize.allCases {
            let pair = scene(module)
            pair.0.prefs.panelSize = size
            let height = measure(TimerNotesSnapshot.root(pair), pair.0)
            XCTAssertLessThanOrEqual(height, ExpandedPanel.maxPanelHeight, "\(size)")
            XCTAssertGreaterThan(height, NotesPanel.height)
        }
    }

    private func measure(_ root: NotchRootView, _ harness: NotchHarness) -> CGFloat {
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: NotchController.panelSize)
        let window = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        window.close()
        return harness.model.contentSize.height
    }
}
