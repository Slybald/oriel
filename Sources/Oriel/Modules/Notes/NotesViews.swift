import AppKit
import SwiftUI

// MARK: - Onglet

/// Liste des notes à gauche (étroite), éditeur à droite.
struct NotesPanel: View {
    @ObservedObject var module: NotesModule
    @Environment(\.notchContentWidth) private var width
    /// Chaque incrément demande le focus à l'éditeur (bouton « + », survol d'une note vide).
    @State private var focusToken = 0

    static let height: CGFloat = 214

    private var sidebarWidth: CGFloat { min(172, max(124, (width * 0.3).rounded())) }

    var body: some View {
        HStack(spacing: 8) {
            NotesSidebar(module: module, newNote: {
                module.newNote()
                focusToken += 1
            }, focusEditor: { focusToken += 1 })
            .frame(width: sidebarWidth)
            NotesEditorCard(module: module, focusToken: focusToken) { focusToken += 1 }
        }
        .frame(height: Self.height)
        .animation(notchSpring, value: module.deleted?.id)
        .animation(notchSpring, value: module.showsSearch)
    }
}

private let notesCardShape = ModuleStyle.shape(ModuleStyle.cardRadius)

// MARK: - Liste

struct NotesSidebar: View {
    @ObservedObject var module: NotesModule
    let newNote: () -> Void
    /// Entrée dans la recherche : le clavier passe à l'éditeur.
    let focusEditor: () -> Void

    @State private var searching = false
    @State private var plusHovering = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("Notes", tableName: "Notes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                Spacer(minLength: 0)
                Button(action: newNote) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Palette.accent.onFill)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Palette.accent.opacity(plusHovering ? 1 : 0.85)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { plusHovering = $0 }
                .animation(ModuleStyle.hover, value: plusHovering)
                .help(L("Nouvelle note", table: "Notes"))
                .accessibilityLabel(L("Nouvelle note", table: "Notes"))
            }
            if module.showsSearch { search }
            list
            footer
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(notesCardShape.fill(Palette.card))
    }

    private var list: some View {
        let visible = module.visibleNotes
        return FadingScrollView {
            LazyVStack(spacing: 2) {
                ForEach(visible) { note in
                    NoteRow(note: note, selected: note.id == module.selectedID,
                            select: { module.select(note.id) },
                            pin: { module.togglePin(note.id) },
                            delete: { module.delete(note.id) })
                }
                if visible.isEmpty {
                    Text("Aucune note ne correspond.", tableName: "Notes")
                        .font(.system(size: 10.5))
                        .foregroundColor(Palette.secondary)
                        .padding(.top, 8)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Annulation de la dernière suppression, ou message de plafond.
    @ViewBuilder
    private var footer: some View {
        if module.deleted != nil {
            ModuleCapsuleButton(title: L("Annuler", table: "Notes"), symbol: "arrow.uturn.backward",
                                action: module.undoDelete)
                .frame(maxWidth: .infinity)
                .help(L("Annuler la suppression", table: "Notes"))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if let notice = module.notice {
            ModuleBanner(symbol: nil, text: notice, font: .system(size: 10), lines: nil, inset: 8)
        }
    }

    /// Recherche : ↑ ↓ choisissent une note, Entrée passe à l'éditeur, Échap efface et rend le clavier,
    /// comme dans le presse-papiers.
    private var search: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(Palette.secondary)
            ClipboardSearchField(text: $module.query, placeholder: L("Rechercher", table: "Notes"),
                                 onFocus: { searching = $0 }, onMove: move, onSubmit: submit, onCancel: leaveSearch)
                .frame(maxWidth: .infinity)
                .frame(height: 18)
            if !module.query.isEmpty {
                Button {
                    module.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundColor(Palette.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Effacer la recherche", table: "Notes"))
                .accessibilityLabel(L("Effacer la recherche", table: "Notes"))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().stroke(Palette.accent.opacity(searching ? 0.8 : 0), lineWidth: 1))
        .animation(ModuleStyle.hover, value: searching)
        .onDisappear { if searching { NotchKeyboard.release(force: true) } }
    }

    private func move(_ delta: Int) {
        let visible = module.visibleNotes
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == module.selectedID }
        let next = index.map { min(max($0 + delta, 0), visible.count - 1) } ?? (delta > 0 ? 0 : visible.count - 1)
        module.select(visible[next].id)
    }

    private func submit() {
        let visible = module.visibleNotes
        guard let first = visible.first else { return }
        if !visible.contains(where: { $0.id == module.selectedID }) { module.select(first.id) }
        focusEditor()
    }

    private func leaveSearch() {
        module.query = ""
        searching = false
        NotchKeyboard.release(force: true)
    }
}

/// Titre (première ligne), date relative ; épingler et supprimer au survol.
struct NoteRow: View {
    let note: Note
    let selected: Bool
    let select: () -> Void
    let pin: () -> Void
    let delete: () -> Void

    @State private var hovering: Bool

    /// `hovering` : état de départ, pour les rendus hors écran.
    init(note: Note, selected: Bool, hovering: Bool = false, select: @escaping () -> Void,
         pin: @escaping () -> Void, delete: @escaping () -> Void) {
        self.note = note
        self.selected = selected
        self.select = select
        self.pin = pin
        self.delete = delete
        _hovering = State(initialValue: hovering)
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if note.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundColor(Palette.accent)
                    }
                    Text(note.title.isEmpty ? L("Nouvelle note", table: "Notes") : note.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(note.title.isEmpty ? Palette.secondary : Palette.primary)
                        .lineLimit(1)
                }
                Text(NotesFormat.relative(note.updated, now: Date()))
                    .font(.system(size: 10))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(ModuleStyle.shape(ModuleStyle.itemRadius)
                .fill(selected ? Palette.accent.opacity(0.22) : Color.white.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if hovering {
                HStack(spacing: 2) {
                    ModuleIconButton(symbol: note.pinned ? "pin.slash" : "pin", label: note.pinned
                                     ? L("Désépingler", table: "Notes") : L("Épingler", table: "Notes"),
                                     box: 20, size: 9.5, action: pin)
                    ModuleIconButton(symbol: "trash", label: L("Supprimer", table: "Notes"), box: 20, size: 9.5,
                                     action: delete)
                }
                .padding(.horizontal, 2)
                .background(Capsule().fill(Color(white: 0.17)))
                .padding(.trailing, 3)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: hovering)
    }
}

// MARK: - Éditeur

/// Texte de la note sélectionnée, compteur discret et actions au survol (copier, épingler, supprimer).
struct NotesEditorCard: View {
    @ObservedObject var module: NotesModule
    let focusToken: Int
    let requestFocus: () -> Void

    @State private var hovering: Bool
    @State private var copied = false
    /// Note vide déjà focalisée au survol : un seul focus par note, pas à chaque passage de la souris.
    @State private var hoverFocused: UUID?

    /// `hovering` : état de départ, pour les rendus hors écran.
    init(module: NotesModule, focusToken: Int, hovering: Bool = false, requestFocus: @escaping () -> Void) {
        self.module = module
        self.focusToken = focusToken
        self.requestFocus = requestFocus
        _hovering = State(initialValue: hovering)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let note = module.selectedNote {
                NotesTextView(noteID: note.id, text: note.text,
                              placeholder: L("Écris une idée, un numéro, une commande…", table: "Notes"),
                              focusToken: focusToken,
                              onChange: { module.setText($0, for: note.id) },
                              onEscape: Self.leaveEditor)
                footer(note)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(notesCardShape.fill(Palette.card))
        .contentShape(notesCardShape)
        .onHover { inside in
            hovering = inside
            // Une note vide attend le texte : le survol de l'éditeur suffit à lui donner le clavier.
            if inside, let note = module.selectedNote, note.text.isEmpty, hoverFocused != note.id {
                hoverFocused = note.id
                requestFocus()
            }
        }
    }

    private func footer(_ note: Note) -> some View {
        HStack(spacing: 4) {
            Text(NotesFormat.characters(note.text.count))
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(Palette.secondary)
            Spacer(minLength: 0)
            Group {
                ModuleIconButton(symbol: copied ? "checkmark" : "doc.on.doc",
                                 label: copied ? L("Copié", table: "Notes") : L("Copier tout le texte", table: "Notes"),
                                 box: 20, size: 9.5) {
                    module.copyAll(note.id)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }
                ModuleIconButton(symbol: note.pinned ? "pin.slash" : "pin", label: note.pinned
                                 ? L("Désépingler", table: "Notes") : L("Épingler", table: "Notes"),
                                 box: 20, size: 9.5) {
                    module.togglePin(note.id)
                }
                ModuleIconButton(symbol: "trash", label: L("Supprimer", table: "Notes"), box: 20, size: 9.5) {
                    module.delete(note.id)
                }
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .animation(ModuleStyle.hover, value: hovering)
    }

    /// Échap : le clavier retourne à l'app de devant.
    private static func leaveEditor() {
        NotchKeyboard.panel?.makeFirstResponder(nil)
        NotchKeyboard.release(force: true)
    }
}

/// `NSTextView` enveloppé : texte brut, Échap, texte indicatif, et le clavier du panneau non activant
/// (`NotchKeyboard`). Un `TextEditor` ne laisse ni Échap ni le texte indicatif.
struct NotesTextView: NSViewRepresentable {
    let noteID: UUID
    let text: String
    let placeholder: String
    let focusToken: Int
    /// Rend le texte retenu (tronqué au plafond).
    let onChange: (String) -> String
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NotesNSTextView(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.appearance = NSAppearance(named: .darkAqua)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 12.5)
        textView.textColor = .white
        textView.insertionPointColor = NSColor(Palette.accent)
        // Notes de passage (commandes, numéros) : aucune correction ne doit les réécrire.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.appearance = NSAppearance(named: .darkAqua)
        scroll.documentView = textView

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.noteID = noteID
        coordinator.focusToken = focusToken
        textView.string = text
        textView.placeholder = placeholder
        textView.onEscape = onEscape
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        textView.placeholder = placeholder
        textView.onEscape = onEscape
        if coordinator.noteID != noteID {
            coordinator.noteID = noteID
            textView.string = text
            textView.undoManager?.removeAllActions()
            textView.scrollToBeginningOfDocument(nil)
        } else if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        if coordinator.focusToken != focusToken {
            coordinator.focusToken = focusToken
            // Après la mise en page : la fenêtre du panneau est alors connue.
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                NotchKeyboard.take()
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesTextView?
        weak var textView: NotesNSTextView?
        var noteID: UUID?
        var focusToken = 0

        func textDidChange(_ notification: Notification) {
            guard let textView, let parent else { return }
            let kept = parent.onChange(textView.string)
            if kept != textView.string { textView.string = kept }
        }

        /// Le champ perd le focus : le clavier retourne à l'app de devant, sauf si un autre champ le prend
        /// (relu au tour de boucle suivant, quand le nouveau premier répondeur est connu).
        func textDidEndEditing(_ notification: Notification) {
            DispatchQueue.main.async { NotchKeyboard.release() }
        }
    }
}

final class NotesNSTextView: NSTextView {
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    var onEscape: () -> Void = {}

    override func cancelOperation(_ sender: Any?) { onEscape() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { NotchKeyboard.take() }
        return accepted
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let rect = NSRect(x: textContainerInset.width + padding, y: textContainerInset.height,
                          width: max(0, bounds.width - 2 * (textContainerInset.width + padding)),
                          height: max(0, bounds.height - 2 * textContainerInset.height))
        NSAttributedString(string: placeholder, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]).draw(in: rect)
    }
}

// MARK: - Formats

enum NotesFormat {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// « À l'instant », « il y a 3 min », « hier » (le formateur suit la langue du système).
    static func relative(_ date: Date, now: Date) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return L("À l'instant", table: "Notes") }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    /// « 1 234 caractères ».
    static func characters(_ count: Int) -> String {
        String(format: L(count, one: "%@ caractère", other: "%@ caractères", table: "Notes"),
               count.formatted(.number.grouping(.automatic)))
    }
}

// MARK: - Réglages

/// Réglages › Notes rapides : où sont les notes et leurs limites.
struct NotesSettingsView: View {
    @ObservedObject var module: NotesModule

    var body: some View {
        SettingsPane {
            Section {
                LabeledContent {
                    Button(action: module.revealData) { Text("Afficher dans le Finder", tableName: "Notes") }
                } label: {
                    Text("Fichier des notes", tableName: "Notes")
                }
            } header: {
                Text("Notes rapides", tableName: "Notes")
            } footer: {
                SettingsNote(String(format: L("Texte brut : %d notes au plus, %@ caractères chacune.", table: "Notes"),
                                    NotesModule.maxNotes, NotesModule.maxLength.formatted(.number.grouping(.automatic))))
            }
        }
    }
}
