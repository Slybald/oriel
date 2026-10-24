import AppKit
import SwiftUI

// Barre de commande dans le panneau : le champ, les actions proposées par les modules, les verbes sous le champ.
// Remplace le contenu du panneau tant qu'elle est ouverte. Textes : table « Command ».

struct CommandBarView: View {
    @StateObject private var model: CommandBarModel
    @ObservedObject var prefs: Preferences
    let notchHeight: CGFloat
    let close: () -> Void

    init(registry: ModuleRegistry, prefs: Preferences, notchHeight: CGFloat, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: CommandBarModel(modules: { registry.commandSources }))
        self.prefs = prefs
        self.notchHeight = notchHeight
        self.close = close
    }

    /// Pour les rendus et les tests : un modèle déjà prêt.
    init(model: CommandBarModel, prefs: Preferences, notchHeight: CGFloat, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.prefs = prefs
        self.notchHeight = notchHeight
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // La bande de la barre des menus reste vide : son milieu est la notch physique.
            Color.clear.frame(height: notchHeight)
            fieldRow
            results
            chips
            footer
        }
        .padding(.horizontal, ExpandedPanel.horizontalPadding)
        .padding(.bottom, ExpandedPanel.bottomPadding)
        .frame(width: prefs.expandedWidth(compact: false), alignment: .top)
        .onAppear {
            model.onFinish = close
        }
        .onChange(of: model.results.map(\.id)) { _ in announce(resultsSummary) }
        .onChange(of: model.selection) { _ in announce(selectedSummary) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Barre de commande", table: "Command"))
    }

    // MARK: - Champ

    private var fieldRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right.circle.fill")
                .font(.system(size: 19))
                .foregroundColor(Palette.accent)
                .accessibilityHidden(true)
            if let verb = model.verb {
                Text(verbatim: verb.key)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(Palette.accent)
                    .frame(minWidth: 18)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(ModuleStyle.shape(7).fill(Palette.accent.opacity(0.18)))
                    .accessibilityLabel(String(format: L("Préfixe %@", table: "Command"), verb.title))
                    .transition(.opacity)
            }
            CommandField(text: $model.text,
                         placeholder: model.verb == nil ? L("Que veux-tu faire ?", table: "Command") : "",
                         label: L("Barre de commande", table: "Command"),
                         onMove: model.move, onSubmit: model.runSelected, onCancel: close,
                         onBackspaceOnEmpty: model.backspaceOnEmptyField)
            Button(action: close) {
                Text(verbatim: "esc")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(ModuleStyle.shape(6).fill(Color.white.opacity(0.1)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Fermer la barre de commande", table: "Command"))
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(ModuleStyle.shape(ModuleStyle.rowRadius).fill(Color.white.opacity(0.07)))
        .animation(ModuleStyle.hover, value: model.verb)
    }

    // MARK: - Résultats

    @ViewBuilder
    private var results: some View {
        if model.results.isEmpty {
            if model.verb != nil || !model.text.isEmpty {
                Text(verbatim: emptyMessage)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        } else {
            VStack(spacing: 3) {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, command in
                    CommandRow(command: command, isSelected: index == model.selection)
                        .onTapGesture { model.run(command) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Actions proposées", table: "Command"))
        }
    }

    private var emptyMessage: String {
        let argument = model.query.argument
        return argument.isEmpty ? L("Rien à proposer ici pour l'instant", table: "Command")
            : String(format: L("Rien ne correspond à « %@ »", table: "Command"), argument)
    }

    // MARK: - Verbes et pied

    /// Avec beaucoup de modules (Mail, Agenda, scripts…), les noms ne tiennent plus sur une ligne : touches seules.
    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            chipRow(titles: true)
            chipRow(titles: false)
        }
    }

    private func chipRow(titles: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(model.verbs, id: \.key) { verb in
                let active = model.verb == verb
                Button { model.pick(verb) } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: verb.key)
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundColor(Palette.accent)
                        if titles {
                            Text(verbatim: verb.title)
                                .font(.system(size: 11.5))
                                .foregroundColor(active ? Palette.primary : Palette.secondary)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(active ? Palette.accent.opacity(0.22) : Color.white.opacity(0.07)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: L("%@, touche %@", table: "Command"), verb.title, verb.key))
                .accessibilityAddTraits(active ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let failure = model.failure {
                Text(verbatim: failure)
                    .foregroundColor(Palette.amber)
                    .lineLimit(1)
            } else {
                Text(verbatim: footerHint)
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            KeyHint(keys: "↑↓", title: L("choisir", table: "Command"))
            KeyHint(keys: "↩", title: L("lancer", table: "Command"))
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
    }

    private var footerHint: String {
        if model.verb?.key == ">" { return L("Rien n'est envoyé sans ⏎", table: "Command") }
        let hotKey = prefs.commandHotKey
        return hotKey == .none ? "" : String(format: L("%@ ouvre la barre", table: "Command"), hotKey.title)
    }

    // MARK: - VoiceOver

    private var resultsSummary: String {
        let count = model.results.count
        guard count > 0 else { return emptyMessage }
        return String(format: L(count, one: "%d action proposée", other: "%d actions proposées", table: "Command"), count)
    }

    private var selectedSummary: String {
        guard model.results.indices.contains(model.selection) else { return "" }
        let command = model.results[model.selection]
        return command.title + ", " + command.detail
    }

    /// Le focus reste dans le champ : sans annonce, VoiceOver ne dirait rien des lignes qu'on parcourt aux flèches.
    private func announce(_ text: String) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }
}

// MARK: - Éléments

/// Une action proposée : icône teintée, titre, détail ; la ligne choisie est cernée et montre ⏎.
struct CommandRow: View {
    let command: NotchCommand
    let isSelected: Bool

    /// Le survol colore la ligne sans changer la sélection : une souris immobile ne doit pas déplacer ce que ⏎ lance.
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: command.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(command.tint)
                .frame(width: 32, height: 32)
                .background(ModuleStyle.shape(ModuleStyle.itemRadius + 1).fill(command.tint.opacity(0.17)))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: command.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .lineLimit(1)
                Text(verbatim: command.detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if isSelected, command.isEnabled {
                Image(systemName: "return")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .frame(width: 26, height: 20)
                    .background(ModuleStyle.shape(6).fill(Color.white.opacity(0.13)))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(ModuleStyle.shape(ModuleStyle.rowRadius)
            .fill(isSelected ? Palette.accent.opacity(0.13) : Color.white.opacity(hovering && command.isEnabled ? 0.06 : 0)))
        .overlay(ModuleStyle.shape(ModuleStyle.rowRadius).stroke(Palette.accent.opacity(isSelected ? 0.6 : 0), lineWidth: 1))
        .opacity(command.isEnabled ? 1 : 0.55)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: isSelected)
        .animation(ModuleStyle.hover, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.title + ", " + command.detail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAddTraits(command.isEnabled ? .isButton : .isStaticText)
    }
}

private struct KeyHint: View {
    let keys: String
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: keys)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Palette.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(ModuleStyle.shape(5).fill(Color.white.opacity(0.1)))
            Text(verbatim: title)
                .foregroundColor(Palette.secondary)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Champ de texte

/// Champ de texte AppKit : les flèches, Retour, Échap et le retour arrière sur un champ vide y sont des commandes
/// (un `TextField` SwiftUI ne livre pas ↑ ↓ avant macOS 14). Il prend le clavier du panneau (`NotchKeyboard`),
/// qui ne s'active jamais.
struct CommandField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let label: String
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onBackspaceOnEmpty: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15, weight: .medium)
        field.textColor = .white
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel(label)
        field.delegate = context.coordinator
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            // Le texte réécrit (le verbe vient de passer à part) : le curseur reste au bout, rien n'est sélectionné.
            (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder, attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.4),
                                              .font: NSFont.systemFont(ofSize: 15, weight: .medium)])
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField

        init(_ parent: CommandField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = NSColor(Palette.accent)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            // Tabulation avalée : elle ferait passer le focus à un autre élément du panneau.
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)): break
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.string.isEmpty else { return false }
                parent.onBackspaceOnEmpty()
            default: return false
            }
            return true
        }
    }
}

/// Prend le focus dès qu'il entre dans la fenêtre (le panneau a déjà le clavier : `NotchKeyboard.take`).
private final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        NotchKeyboard.take()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.makeFirstResponder(self) == true else { return }
            // Un champ qui prend le focus sélectionne son texte : le curseur va au bout.
            (self.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: (self.stringValue as NSString).length, length: 0))
        }
    }
}
