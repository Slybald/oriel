import AppKit
import SwiftUI

/// Fenêtre de réglages : créée à l'ouverture, libérée à la fermeture (rien en mémoire le reste du temps).
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let size = CGSize(width: 720, height: 500)

    private let prefs: Preferences
    private let registry: ModuleRegistry
    private var window: NSWindow?

    init(prefs: Preferences, registry: ModuleRegistry) {
        self.prefs = prefs
        self.registry = registry
    }

    func show() {
        if window == nil {
            let view = SettingsView(prefs: prefs, registry: registry, updater: .shared)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: view)
            window.title = L("Réglages d'Oriel")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            // Sur le Space courant, pas sur celui où la fenêtre a été ouverte la première fois.
            window.collectionBehavior = [.moveToActiveSpace]
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        HookSetup.activateApp()
    }

    func windowWillClose(_ notification: Notification) {
        // Le contenu SwiftUI part avec la fenêtre : aucune vue de réglages ne reste en mémoire.
        window?.contentView = nil
        window = nil
    }
}

// MARK: - Menu principal

/// Menu principal (invisible pour une app sans icône dans le Dock) : ses raccourcis marchent dès qu'une fenêtre
/// de l'app est devant. ⌘, ouvre les réglages, ⌘W ferme la fenêtre, ⌘C / ⌘V dans les champs de texte.
enum MainMenu {
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func perform(_ sender: Any?) { action() }
    }

    /// La cible d'un NSMenuItem est faible : on la garde ici.
    private static var settingsTarget: Target?

    static func install(openSettings: @escaping () -> Void) {
        let target = Target(openSettings)
        settingsTarget = target

        let appMenu = NSMenu()
        let settings = NSMenuItem(title: L("Réglages…"), action: #selector(Target.perform(_:)), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quitter Oriel"), action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let editMenu = NSMenu(title: L("Édition"))
        editMenu.addItem(withTitle: L("Annuler"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("Rétablir"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Couper"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copier"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Coller"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Tout sélectionner"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: L("Fenêtre"))
        windowMenu.addItem(withTitle: L("Fermer"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let main = NSMenu()
        for menu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }
}

// MARK: - Vue

enum SettingsSection: Hashable {
    case general
    case tabs
    case appearance
    case privacy
    case module(String)
    case scripts
    case updates
    case about
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var registry: ModuleRegistry
    @ObservedObject var updater: Updater
    @State var selection: SettingsSection? = .general

    static let sidebarWidth: CGFloat = 190

    private struct ModuleEntry: Identifiable {
        let id: String
        let title: String
        let symbol: String
    }

    /// Modules activés qui ont un volet de réglages, dans l'ordre des onglets (Claude d'abord par défaut).
    private var moduleSections: [ModuleEntry] {
        registry.enabled.compactMap { module in
            module.makeSettingsView() == nil ? nil : ModuleEntry(id: module.id, title: module.title, symbol: module.symbol)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height)
        .tint(Palette.accent)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Label("Général", systemImage: "gearshape").tag(SettingsSection.general)
            Label("Onglets", systemImage: "rectangle.split.3x1").tag(SettingsSection.tabs)
            Label("Apparence", systemImage: "paintpalette").tag(SettingsSection.appearance)
            Label("Confidentialité", systemImage: "hand.raised").tag(SettingsSection.privacy)
            ForEach(moduleSections) { section in
                Label(section.title, systemImage: section.symbol).tag(SettingsSection.module(section.id))
            }
            Label { Text("Scripts", tableName: "API") } icon: { Image(systemName: "terminal") }.tag(SettingsSection.scripts)
            Label("Mises à jour", systemImage: "arrow.down.circle").tag(SettingsSection.updates)
            Label("À propos", systemImage: "info.circle").tag(SettingsSection.about)
        }
        .listStyle(.sidebar)
        // Sous la barre de titre transparente.
        .padding(.top, 28)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .general {
        case .general:
            GeneralSettings(prefs: prefs, registry: registry, claudeEnabled: registry.isClaudeEnabled,
                            runAssistant: { HookSetup.shared.showSetupAssistant(registry: registry, prefs: prefs) })
        case .tabs: TabsSettings(prefs: prefs, registry: registry)
        case .appearance: AppearanceSettings(prefs: prefs, claudeEnabled: registry.isClaudeEnabled)
        case .privacy: PrivacySettings(prefs: prefs)
        case .module(let id): registry.module(id)?.makeSettingsView()
        case .scripts: LocalAPISettings(api: registry.external)
        case .updates: UpdateSettings(updater: updater, prefs: prefs)
        case .about: AboutSettings(registry: registry, updater: updater)
        }
    }
}

/// Volet de réglages : formulaire groupé. Les modules s'en servent pour leur propre volet.
struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}

/// Petit texte explicatif sous un réglage.
struct SettingsNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Général

private struct GeneralSettings: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var registry: ModuleRegistry
    let claudeEnabled: Bool
    let runAssistant: () -> Void
    @ObservedObject var hotKeys: HotKeyCenter = .shared
    @State private var confirmReset = false

    /// Écrans branchés, numérotés s'ils portent le même nom (le choix par nom les liste).
    private var screenNames: [String] { NotchScreenPicker.labels(NSScreen.screens.map(ScreenCandidate.init)) }
    private func now() -> Date { Date() }

    var body: some View {
        SettingsPane {
            Section(L("Profil", table: "Profiles")) {
                LabeledContent {
                    Button(L("Changer de profil…", table: "Profiles")) {
                        ProfileWindow.shared.show(registry: registry, prefs: prefs)
                    }
                } label: {
                    Text(verbatim: NotchProfile.matching(enabled: registry.enabled.map { $0.id },
                                                         known: registry.modules.map { $0.id })?.title
                         ?? L("Personnalisé"))
                }
                SettingsNote(L("Un profil règle les onglets, leur ordre, l'ouverture du panneau et les oreilles. "
                               + "Tes données ne changent pas.", table: "Profiles"))
            }
            Section {
                Toggle("Lancer à l'ouverture de session", isOn: $prefs.launchAtLogin)
            }
            Section("Visibilité") {
                Picker("Afficher la notch", selection: NotchMoreMenu.visibility(prefs, claudeEnabled: claudeEnabled)) {
                    ForEach(NotchVisibility.choices(claudeEnabled: claudeEnabled)) { mode in
                        Text(NotchMoreMenu.title(mode)).tag(mode)
                    }
                }
                SettingsNote(visibilityNote)
                hideRow
            }
            Section("Ouverture") {
                Picker("Ouvrir le panneau", selection: $prefs.openTrigger) {
                    Text("Au survol").tag(OpenTrigger.hover)
                    Text("Au clic").tag(OpenTrigger.click)
                }
                .pickerStyle(.segmented)
                if prefs.openTrigger == .hover {
                    delaySlider(L("Délai d'ouverture"), value: $prefs.openDelay, range: Preferences.openDelayRange)
                }
                Toggle("Fermer au clic à l'extérieur", isOn: $prefs.closeOnClickOutside)
                if !prefs.closeOnClickOutside {
                    delaySlider(L("Délai de fermeture"), value: $prefs.closeDelay, range: Preferences.closeDelayRange)
                }
                SettingsNote(prefs.closeOnClickOutside
                    ? L("Le panneau reste ouvert tant que tu ne cliques pas ailleurs.")
                    : L("Le panneau se ferme quand la souris le quitte."))
                Toggle("Retour haptique à l'ouverture", isOn: $prefs.hapticFeedback)
            }
            Section("Raccourcis") {
                hotKeyPicker(L("Ouvrir ou fermer le panneau"), selection: $prefs.toggleHotKey, slot: .togglePanel)
                hotKeyPicker(L("Masquer ou réafficher la notch"), selection: $prefs.hideHotKey, slot: .toggleHidden)
                hotKeyPicker(L("Barre de commande"), selection: $prefs.commandHotKey, slot: .commandBar)
                SettingsNote(L("Partout, sans autorisation. Panneau ouvert au clavier : ← → ou ⌘1…9 pour les "
                    + "onglets, Échap pour fermer."))
                SettingsNote(L("Barre de commande : t 25 lance un minuteur, n idée crée une note, c lien cherche "
                    + "dans les copies, s présentation applique une scène, > message écrit à Claude. Rien ne part sans ⏎."))
            }
            Section("Plein écran") {
                Picker("Quand une app est en plein écran", selection: $prefs.fullScreenBehavior) {
                    Text("Panneau compact").tag(FullScreenBehavior.compact)
                    Text("Panneau normal").tag(FullScreenBehavior.normal)
                    Text("Notch masquée").tag(FullScreenBehavior.hidden)
                }
                SettingsNote(claudeEnabled
                    ? L("Compact : demi-largeur, seulement l'essentiel (sessions Claude en cours, résumé de "
                        + "chaque onglet). Les oreilles restent les mêmes.")
                    : L("Compact : demi-largeur, seulement le résumé de chaque onglet. Les oreilles restent les mêmes."))
            }
            Section("Écran") {
                Picker("Écran de la notch", selection: $prefs.screenChoice) {
                    Text("Écran intégré (avec encoche)").tag(ScreenChoice.builtin)
                    Text("Écran principal").tag(ScreenChoice.main)
                    Text("Écran sous la souris").tag(ScreenChoice.mouse)
                    Divider()
                    ForEach(namedChoices, id: \.self) { name in
                        Text(screenNames.contains(name) ? name : String(format: L("%@ (débranché)"), name)).tag(name)
                    }
                }
                SettingsNote(L("Sans encoche, une encoche virtuelle est dessinée en haut au centre."))
            }
            Section(L("Bulle", table: "Bubble")) {
                Toggle(L("Permettre de détacher la notch", table: "Bubble"), isOn: $prefs.allowsDetach)
                if prefs.allowsDetach {
                    Toggle(L("Revenir à la notch au redémarrage", table: "Bubble"), isOn: $prefs.bubbleReturnsOnRelaunch)
                }
                SettingsNote(L("Glisse l'angle en bas à droite du panneau : la notch se décolle en bulle, à poser où tu "
                               + "veux. Approche-la de la notch, qui l'attire et l'aspire, double-clique sur son bord ou "
                               + "choisis « Rattacher à la notch » pour la remettre.", table: "Bubble"))
            }
            Section {
                HStack {
                    Spacer()
                    Button("Relancer l'assistant de configuration") { runAssistant() }
                }
            } footer: {
                SettingsNote(L("Rechoisis tes onglets, l'ouverture de la notch et le raccourci clavier."))
            }
            Section {
                HStack {
                    Spacer()
                    Button("Rétablir les réglages par défaut…") { confirmReset = true }
                }
            } footer: {
                SettingsNote(L("Les onglets, leurs données et les hooks ne changent pas."))
            }
        }
        .alert(L("Rétablir les réglages par défaut ?"), isPresented: $confirmReset) {
            Button("Réinitialiser", role: .destructive) { prefs.resetNotchSettings() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(L("Visibilité, ouverture, raccourcis, écran, taille, couleurs et animations reviennent à leurs "
                + "valeurs d'origine."))
        }
    }

    private var visibilityNote: String {
        switch prefs.visibility.effective(claudeEnabled: claudeEnabled) {
        case .always: return L("La notch reste toujours à l'écran.")
        case .whenClaudeOpen: return L("Tant que Claude Desktop ou une session Claude Code est ouverte.")
        case .duringActivity where claudeEnabled:
            return L("Quand Claude travaille ou t'attend, ou qu'un onglet signale quelque chose (minuteur, lecture). "
                + "Au repos, rouvre Oriel pour retrouver ces réglages.")
        case .duringActivity:
            return L("Quand un onglet signale quelque chose (minuteur, lecture). Au repos, rouvre Oriel pour "
                + "retrouver ces réglages.")
        }
    }

    /// Masquée : rappel et « Réafficher » ; sinon, les durées proposées.
    @ViewBuilder
    private var hideRow: some View {
        if let until = prefs.hiddenUntil, until > now() {
            LabeledContent {
                Button("Réafficher") { prefs.showAgain() }
            } label: {
                Label(HiddenNotice.text(until: until, now: now()), systemImage: "eye.slash")
                    .foregroundColor(Palette.amber)
            }
            SettingsNote(L("Aussi par le raccourci, ou en rouvrant Oriel."))
        } else {
            LabeledContent {
                Menu {
                    ForEach(HideDuration.allCases) { duration in
                        Button(NotchController.title(duration)) { prefs.hide(duration, now: now()) }
                    }
                } label: {
                    Text("Masquer")
                }
                .fixedSize()
            } label: {
                Text("Masquer la notch")
            }
        }
    }

    /// Écrans nommés : ceux qui sont branchés, plus celui choisi s'il est débranché.
    private var namedChoices: [String] {
        var names = screenNames
        let fixed = [ScreenChoice.builtin, ScreenChoice.main, ScreenChoice.mouse]
        if !fixed.contains(prefs.screenChoice), !names.contains(prefs.screenChoice) { names.append(prefs.screenChoice) }
        return names
    }

    private func hotKeyPicker(_ title: String, selection: Binding<HotKeyChoice>,
                              slot: HotKeyCenter.Slot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: selection) {
                ForEach(HotKeyChoice.pickable) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            if hotKeys.unavailable.contains(slot) {
                Text("Déjà pris par une autre app : choisis-en un autre.")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.amber)
            }
        }
    }

    private func delaySlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: 0.01)
                    .frame(width: 200)
                Text(String(format: L("%d ms"), Int((value.wrappedValue * 1000).rounded())))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }
}

// MARK: - Onglets

private struct TabsSettings: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var registry: ModuleRegistry

    var body: some View {
        SettingsPane {
            Section {
                ForEach(registry.ordered.map { $0.id }, id: \.self) { id in
                    if let module = registry.module(id) {
                        row(module)
                    }
                }
                .onMove { source, destination in registry.move(from: source, to: destination) }
            } header: {
                Text("Onglets")
            } footer: {
                SettingsNote(L("Glisse les onglets pour changer leur ordre. Un onglet désactivé ne fait rien, "
                    + "même en arrière-plan. Dans la notch, un appui long sur les onglets permet aussi de les "
                    + "déplacer et de les masquer."))
            }
            Section {
                Picker("Onglet à l'ouverture", selection: $prefs.defaultTab) {
                    Text("Dernier utilisé").tag(Preferences.lastTabChoice)
                    ForEach(registry.enabled.map { $0.id }, id: \.self) { id in
                        Text(registry.module(id)?.title ?? id).tag(id)
                    }
                }
                if registry.isClaudeEnabled {
                    SettingsNote(L("Quand Claude attend ta réponse, la notch s'ouvre toujours sur Claude."))
                }
            }
        }
    }

    private func row(_ module: any NotchModule) -> some View {
        let id = module.id
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
            Image(systemName: module.symbol)
                .frame(width: 20)
                .foregroundColor(Palette.accent)
            Text(module.title)
            Spacer()
            Toggle("Activé", isOn: Binding(get: { registry.isEnabled(id) },
                                           set: { registry.setEnabled(id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

// MARK: - Apparence

private struct AppearanceSettings: View {
    @ObservedObject var prefs: Preferences
    let claudeEnabled: Bool

    private var customColor: Binding<Color> {
        Binding(get: { prefs.accent },
                set: { color in if let hex = color.hexString { prefs.accentHex = hex } })
    }

    private var customBackground: Binding<Color> {
        Binding(get: { Color(hex: prefs.customBackgroundHex) ?? .black },
                set: { color in if let hex = color.hexString { prefs.customBackgroundHex = hex } })
    }

    /// Taille prédéfinie (`PanelSize.rawValue`) ou « custom » (largeur libre).
    private var sizeChoice: Binding<String> {
        Binding(get: { prefs.customPanelWidth == nil ? prefs.panelSize.rawValue : Self.customSize },
                set: { value in
                    if let size = PanelSize(rawValue: value) {
                        prefs.panelSize = size
                        prefs.customPanelWidth = nil
                    } else if prefs.customPanelWidth == nil {
                        // Le curseur part de la largeur affichée jusque-là.
                        prefs.customPanelWidth = Double(prefs.panelSize.width)
                    }
                })
    }

    private var customWidth: Binding<Double> {
        Binding(get: { prefs.customPanelWidth ?? Double(prefs.panelSize.width) },
                set: { prefs.customPanelWidth = $0 })
    }

    private static let customSize = "custom"

    var body: some View {
        SettingsPane {
            Section("Aperçu") {
                NotchAppearancePreview(prefs: prefs, claudeEnabled: claudeEnabled)
                    .padding(.vertical, 4)
            }
            Section("Couleur d'accent") {
                HStack(spacing: 10) {
                    ForEach(Preferences.accentPresets, id: \.self) { hex in
                        swatch(hex)
                    }
                    Divider().frame(height: 22)
                    ColorPicker(selection: customColor, supportsOpacity: false) {
                        Text("Couleur libre")
                    }
                    .labelsHidden()
                    Spacer()
                }
                .padding(.vertical, 2)
            }
            Section("Panneau") {
                Picker("Taille du panneau", selection: sizeChoice) {
                    Text("Compacte").tag(PanelSize.compact.rawValue)
                    Text("Standard").tag(PanelSize.standard.rawValue)
                    Text("Large").tag(PanelSize.large.rawValue)
                    Text("Personnalisée").tag(Self.customSize)
                }
                .pickerStyle(.segmented)
                if prefs.customPanelWidth != nil {
                    LabeledContent {
                        HStack(spacing: 10) {
                            Slider(value: customWidth, in: Preferences.customWidthRange, step: Preferences.customWidthStep)
                                .frame(width: 200)
                            Text(String(format: L("%d pt"), Int(customWidth.wrappedValue)))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                                .frame(width: 56, alignment: .trailing)
                        }
                    } label: {
                        Text("Largeur")
                    }
                }
                SettingsNote(L("En plein écran compact, le panneau garde sa demi-largeur."))
            }
            Section("Fond") {
                Picker("Couleur du fond", selection: $prefs.panelBackground) {
                    Text("Noir").tag(PanelBackground.black)
                    Text("Graphite").tag(PanelBackground.graphite)
                    Text("Bleu nuit").tag(PanelBackground.midnight)
                    Text("Personnalisé").tag(PanelBackground.custom)
                }
                .pickerStyle(.segmented)
                if prefs.panelBackground == .custom {
                    LabeledContent {
                        ColorPicker(selection: customBackground, supportsOpacity: false) {
                            Text("Fond libre")
                        }
                        .labelsHidden()
                    } label: {
                        Text("Fond libre")
                    }
                    SettingsNote(L("Une couleur claire est assombrie : le texte du panneau reste lisible."))
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: $prefs.backgroundOpacity, in: Preferences.opacityRange, step: 0.01)
                            .frame(width: 200)
                        Text(verbatim: "\(Int((prefs.backgroundOpacity * 100).rounded())) %")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                } label: {
                    Text("Opacité du fond")
                }
                Toggle("Ombre du panneau", isOn: $prefs.panelShadow)
            }
            Section("Animations") {
                Picker("Vitesse", selection: $prefs.animationSpeed) {
                    Text("Rapide").tag(AnimationSpeed.fast)
                    Text("Normale").tag(AnimationSpeed.normal)
                    Text("Douce").tag(AnimationSpeed.gentle)
                }
                .pickerStyle(.segmented)
                SettingsNote(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    ? L("« Réduire les animations » est activé dans macOS : simple fondu.")
                    : L("Ouverture, fermeture et changement d'onglet."))
            }
            Section("Notch repliée") {
                Toggle("Afficher les oreilles", isOn: $prefs.showEars)
                SettingsNote(claudeEnabled
                    ? L("Un intercalaire par activité, de part et d'autre de la notch : Claude (main levée, spinner, "
                        + "coche, sessions), lecture en cours, minuteur…")
                    : L("Un intercalaire par activité, de part et d'autre de la notch : ce qu'un onglet signale "
                        + "(minuteur, lecture en cours)."))
                Picker("Intercalaires", selection: $prefs.earTabsMode) {
                    Text("Rétractés").tag(EarTabsMode.retracted)
                    Text("Toujours visibles").tag(EarTabsMode.visible)
                }
                .pickerStyle(.segmented)
                .disabled(!prefs.showEars)
                SettingsNote(L("Les intercalaires s'empilent en éventail contre la notch. Toujours visibles : chacun "
                    + "montre son icône. Rétractés : une fine languette chacun. Dans les deux cas, passe la souris sur "
                    + "un intercalaire pour l'ouvrir, clique dessus pour ouvrir son onglet. Une alerte (Claude attend "
                    + "ta réponse) reste toujours visible."))
                Toggle("Teinter aussi la notch repliée", isOn: $prefs.tintCollapsed)
                SettingsNote(L("Écrans sans encoche seulement : sur une vraie encoche, elle reste noire."))
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        let selected = prefs.accentHex.uppercased() == hex
        return Button {
            prefs.accentHex = hex
        } label: {
            Circle()
                .fill(Color(hex: hex) ?? Palette.claudeOrange)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2)
                    .padding(-4))
        }
        .buttonStyle(.plain)
        .padding(4)
    }
}

/// Mini-rendu du panneau déplié avec les réglages courants : largeur, fond, opacité, ombre, accent. Sur un
/// dégradé, pour juger l'opacité ; la bande du haut reste opaque comme sur la vraie notch.
struct NotchAppearancePreview: View {
    @ObservedObject var prefs: Preferences
    /// Sans l'onglet Claude, l'onglet actif de l'aperçu est le lecteur.
    var claudeEnabled = true

    static let scale: CGFloat = 0.5
    static let height: CGFloat = 150
    private static let band: CGFloat = 12

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.36, blue: 0.66), Color(red: 0.8, green: 0.45, blue: 0.58)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Barre des menus du « bureau ».
            Color.white.opacity(0.22).frame(height: Self.band)
            panel
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Aperçu"))
    }

    private var panel: some View {
        let color = prefs.panelColor
        return VStack(alignment: .leading, spacing: 5) {
            Color.clear.frame(height: Self.band)
            header
            card(progress: 0.6)
            card(progress: 1)
        }
        .padding(.horizontal, 7)
        .padding(.bottom, 7)
        .frame(width: prefs.expandedWidth(compact: false) * Self.scale)
        .padding(.horizontal, 6)
        .background(ZStack(alignment: .top) {
            Rectangle().fill(color.opacity(prefs.backgroundOpacity))
            color.frame(height: Self.band)
        })
        .clipShape(NotchShape(topRadius: 6, bottomRadius: 12))
        .shadow(color: .black.opacity(prefs.panelShadow ? 0.45 : 0), radius: 7, y: 3)
    }

    private var header: some View {
        HStack(spacing: 5) {
            HStack(spacing: 3) {
                Image(systemName: claudeEnabled ? "sparkle" : "play.fill")
                    .foregroundColor(prefs.accent)
                if claudeEnabled { Text(verbatim: "Claude") }
            }
            .font(.system(size: 7, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .frame(height: 12)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            ForEach((claudeEnabled ? ["play.fill"] : []) + ["switch.2", "tray", "doc.on.clipboard", "timer"],
                    id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer(minLength: 4)
            Image(systemName: "ellipsis")
                .font(.system(size: 7, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
        }
    }

    private func card(progress: CGFloat) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(progress < 1 ? prefs.accent : Palette.green)
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(Color.white.opacity(0.8)).frame(width: 60, height: 3)
                Capsule().fill(Color.white.opacity(0.3)).frame(width: 100, height: 3)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(prefs.accent).frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.card))
    }
}

// MARK: - Confidentialité

private struct PrivacySettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        SettingsPane {
            Section {
                Toggle("Invisible dans les captures et le partage d'écran", isOn: $prefs.hideFromCapture)
            } footer: {
                SettingsNote(L("Tu vois toujours la notch ; captures, enregistrements et partages d'écran ne la montrent "
                    + "pas (selon l'app qui capture)."))
            }
        }
    }
}

// MARK: - Mises à jour

private struct UpdateSettings: View {
    @ObservedObject var updater: Updater
    @ObservedObject var prefs: Preferences

    var body: some View {
        SettingsPane {
            Section {
                Text(updater.versionLine)
                if updater.isReleaseBuild {
                    switch updater.status {
                    case .available(let version, _):
                        LabeledContent(String(format: L("Version %@ disponible"), version)) {
                            if updater.canInstall {
                                Button("Installer", action: updater.installNow)
                            } else {
                                Button("Ouvrir la page de la release", action: updater.openReleasePage)
                            }
                        }
                    case .failed(let message):
                        Text(message).foregroundColor(Palette.amber)
                    case .idle, .checking, .installing:
                        EmptyView()
                    }
                    Toggle("Mises à jour automatiques", isOn: $prefs.autoUpdate)
                    HStack {
                        Spacer()
                        Button("Rechercher les mises à jour", action: updater.checkNow)
                            .disabled(updater.isWorking)
                    }
                } else {
                    Text("Build de développement : mises à jour désactivées")
                        .foregroundColor(.secondary)
                }
            } footer: {
                SettingsNote(L("Les nouvelles versions viennent des releases GitHub et ne sont installées que si "
                    + "leur signature est valide."))
            }
        }
    }
}

// MARK: - À propos

private struct AboutSettings: View {
    @ObservedObject var registry: ModuleRegistry
    @ObservedObject var updater: Updater

    static let repository = URL(string: "https://github.com/Slybald/oriel")!

    private var notices: [LicenseNotice] { registry.modules.flatMap { $0.licenseNotices } }

    var body: some View {
        SettingsPane {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Palette.accent.opacity(0.16))
                        Image(systemName: "rectangle.topthird.inset.filled")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(Palette.accent)
                    }
                    .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "Oriel")
                            .font(.system(size: 15, weight: .semibold))
                        Text(updater.versionLine)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Text(registry.isClaudeEnabled ? L("Tes sessions Claude Code, d'un coup d'œil.")
                     : L("Des onglets utiles, dans la notch."))
                Link(destination: Self.repository) {
                    Text(verbatim: "github.com/Slybald/oriel")
                }
                SettingsNote(L("Projet indépendant, ni affilié ni approuvé par Anthropic. Claude est une marque "
                    + "d'Anthropic."))
            }
            Section("Licences") {
                LabeledContent {
                    Text(verbatim: "MIT")
                } label: {
                    Text(verbatim: "Oriel")
                }
                if notices.isEmpty {
                    SettingsNote(L("Aucun composant tiers."))
                }
                ForEach(notices) { notice in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notice.name).font(.system(size: 12, weight: .semibold))
                        Text(notice.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
