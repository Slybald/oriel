import AppKit
import SwiftUI

// Assistant de configuration : montré au premier lancement (voir `HookSetup.launchWindow`), relancé à la demande
// depuis Réglages › Général. Quatre étapes : bienvenue, onglets, comportement, fin. Rien n'est écrit avant
// « Appliquer » ; « Passer » laisse les réglages comme ils sont. Aucune autorisation macOS n'est demandée ici.

// MARK: - Onglets proposés

/// Une carte de l'étape « Onglets » : l'onglet et, en une ligne, à quoi il sert.
struct SetupTab: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let usage: String

    init(_ module: any NotchModule) {
        id = module.id
        title = module.title
        symbol = module.symbol
        usage = Self.usage(of: module.id)
    }

    /// Une ligne par onglet connu : un nouveau module en ajoute une ici (un test le rappelle).
    static func usage(of id: String) -> String {
        switch id {
        case ModuleRegistry.claudeId: return L("Tes sessions Claude Code : état, tâches et permissions.")
        case ModuleRegistry.codexId: return L("Tes sessions Codex : état et approbations.")
        case "media": return L("La musique en cours et ton calendrier de la semaine.")
        case "agenda": return L("Ton prochain rendez-vous, un compte à rebours et le bouton pour le rejoindre.")
        case "quicksettings": return L("Wi-Fi, Bluetooth, concentration, économie d'énergie, batterie.")
        case "shelf": return L("Dépose des fichiers sur la notch, reprends-les plus tard.")
        case "clipboard": return L("Tes dernières copies, à reprendre d'un clic.")
        case "timer": return L("Un minuteur, ou un cycle Pomodoro.")
        case "notes": return L("Des notes en texte brut, toujours à portée.")
        case "messages": return L("Tes conversations récentes et une réponse rapide.")
        case "mail": return L("Tes messages non lus d'Apple Mail.")
        default: return ""
        }
    }
}

// MARK: - Choix (logique pure)

/// Ce que propose l'étape « Onglets » pour les hooks Claude Code, selon leur état sur le Mac.
enum SetupHooksOffer: Equatable {
    /// L'onglet Claude n'est pas proposé : rien sur les hooks.
    case none
    case installed
    case install
    /// Posés par une version précédente.
    case update

    init(claudeOffered: Bool, status: HookInstaller.Status) {
        guard claudeOffered else { self = .none; return }
        switch status {
        case .installed: self = .installed
        case .outdated, .scriptOutdated: self = .update
        case .notInstalled, .unreadable: self = .install
        }
    }

    /// Case cochée au départ : une mise à jour (l'accord a déjà été donné), jamais une première installation.
    var checkedByDefault: Bool { self == .update }

    /// Il y a quelque chose à écrire dans ~/.claude.
    var canInstall: Bool { self == .install || self == .update }
}

/// Les choix de l'utilisateur. Logique pure : ni fenêtre, ni accès au Mac.
struct SetupChoices: Equatable {
    /// Onglets proposés, dans l'ordre des réglages. Claude n'en fait partie que si Claude Code est détecté, ou si son
    /// onglet est déjà activé (assistant relancé).
    let offered: [String]
    private(set) var tabs: Set<String>
    var openTrigger: OpenTrigger
    var toggleHotKey: HotKeyChoice
    var launchAtLogin: Bool
    var installHooks: Bool
    /// Profil pris à la première étape ; nil = pas de profil, les onglets restent comme ils sont.
    private(set) var profile: NotchProfile?

    /// `isEnabled` : l'état actuel des onglets (au premier lancement, leur activation par défaut, avec Claude décidé
    /// par la détection). Au moins un onglet reste coché, comme dans Réglages › Onglets et dans la notch.
    init(order: [String], claudeDetected: Bool, codexDetected: Bool = false, isEnabled: (String) -> Bool, openTrigger: OpenTrigger,
         toggleHotKey: HotKeyChoice, launchAtLogin: Bool, installHooks: Bool) {
        let claudeOffered = claudeDetected || isEnabled(ModuleRegistry.claudeId)
        // Codex comme Claude : proposé seulement s'il est détecté, ou si son onglet est déjà activé.
        let codexOffered = codexDetected || isEnabled(ModuleRegistry.codexId)
        offered = order.filter {
            ($0 != ModuleRegistry.claudeId || claudeOffered) && ($0 != ModuleRegistry.codexId || codexOffered)
        }
        var on = Set(offered.filter(isEnabled))
        if on.isEmpty, let first = offered.first { on = [first] }
        tabs = on
        self.openTrigger = openTrigger
        self.toggleHotKey = toggleHotKey
        self.launchAtLogin = launchAtLogin
        self.installHooks = installHooks
    }

    var claudeOffered: Bool { offered.contains(ModuleRegistry.claudeId) }
    var includesClaude: Bool { tabs.contains(ModuleRegistry.claudeId) }
    /// Onglets cochés, dans l'ordre des réglages (celui du profil, s'il y en a un).
    var selected: [String] {
        let on = offered.filter(tabs.contains)
        return profile?.arrange(on) ?? on
    }

    func isOn(_ id: String) -> Bool { tabs.contains(id) }

    /// Coche ou décoche un onglet proposé. Le dernier coché ne se décoche pas : la barre n'est jamais vide.
    @discardableResult
    mutating func set(_ id: String, _ isOn: Bool) -> Bool {
        guard offered.contains(id) else { return false }
        if isOn {
            tabs.insert(id)
            return true
        }
        guard tabs.count > 1 || !tabs.contains(id) else { return false }
        tabs.remove(id)
        return true
    }

    /// Prend un profil : ses onglets proposés cochés, les autres décochés, et son ouverture. Rien n'est écrit avant
    /// « Appliquer » ; les onglets et l'ouverture se règlent ensuite à la main.
    mutating func choose(_ profile: NotchProfile) {
        self.profile = profile
        tabs = Set(profile.shown(offered: offered))
        openTrigger = profile.openTrigger
    }

    /// Écrit les onglets (par le registre, comme Réglages › Onglets), l'ouverture et le raccourci, puis l'ordre et
    /// les oreilles du profil choisi. Un onglet non proposé (Claude sans Claude Code) n'est pas touché.
    func apply(to registry: ModuleRegistry, prefs: Preferences) {
        for id in offered { registry.setEnabled(id, tabs.contains(id)) }
        prefs.openTrigger = openTrigger
        prefs.toggleHotKey = toggleHotKey
        if let profile {
            prefs.tabOrder = ProfilePlan.order(shown: selected, current: registry.ordered.map { $0.id })
            prefs.showEars = profile.showEars
        }
    }
}

// MARK: - Modèle des étapes

final class SetupAssistantModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, tabs, behavior, done
    }

    /// Hooks demandés : posés, ou la raison de l'échec.
    enum HooksOutcome: Equatable {
        case success
        case failure(String)
    }

    let tabs: [SetupTab]
    let hooksOffer: SetupHooksOffer
    let inApplications: Bool
    @Published var step: Step
    @Published var choices: SetupChoices
    @Published private(set) var hooksOutcome: HooksOutcome?

    private let registry: ModuleRegistry
    private let prefs: Preferences
    private let installHooks: () -> String?
    private let applyLaunchAtLogin: (Bool) -> Void
    private let close: () -> Void

    /// `firstRun` : « Lancer à l'ouverture de session » est coché d'office (hors Applications, il ne l'est pas) ;
    /// relancé, l'assistant part des réglages actuels. `installHooks` rend le message d'erreur, nil si tout va bien.
    init(registry: ModuleRegistry, prefs: Preferences, claudeDetected: Bool, codexDetected: Bool = false,
         hookStatus: HookInstaller.Status, firstRun: Bool, inApplications: Bool, step: Step = .welcome, installHooks: @escaping () -> String?,
         applyLaunchAtLogin: @escaping (Bool) -> Void, close: @escaping () -> Void) {
        self.registry = registry
        self.prefs = prefs
        self.inApplications = inApplications
        self.installHooks = installHooks
        self.applyLaunchAtLogin = applyLaunchAtLogin
        self.close = close
        self.step = step
        var choices = SetupChoices(
            order: registry.ordered.map { $0.id }, claudeDetected: claudeDetected, codexDetected: codexDetected,
            isEnabled: { registry.isEnabled($0) }, openTrigger: prefs.openTrigger, toggleHotKey: prefs.toggleHotKey,
            launchAtLogin: inApplications && (firstRun || prefs.launchAtLogin), installHooks: false)
        let offer = SetupHooksOffer(claudeOffered: choices.claudeOffered, status: hookStatus)
        choices.installHooks = offer.checkedByDefault
        self.choices = choices
        hooksOffer = offer
        tabs = registry.ordered.filter { choices.offered.contains($0.id) }.map { SetupTab($0) }
    }

    /// Les cartes cochées, dans l'ordre (aperçu de la notch).
    var selectedTabs: [SetupTab] { choices.selected.compactMap { id in tabs.first { $0.id == id } } }

    func choose(_ profile: NotchProfile) { choices.choose(profile) }

    /// Les onglets que `profile` affichera ici (Claude seulement s'il est proposé), séparés par des virgules.
    func summary(of profile: NotchProfile) -> String {
        profile.shown(offered: choices.offered).compactMap { id in tabs.first { $0.id == id }?.title }
            .joined(separator: ", ")
    }

    var claudeOffered: Bool { choices.claudeOffered }
    var canGoBack: Bool { step == .tabs || step == .behavior }

    func next() {
        switch step {
        case .welcome: step = .tabs
        case .tabs: step = .behavior
        case .behavior: finish()
        case .done: close()
        }
    }

    func back() {
        guard canGoBack, let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// « Passer » : on ferme, les réglages restent comme ils sont.
    func skip() { close() }

    /// « Appliquer » : onglets, ouverture, raccourci, session, puis les hooks si demandés.
    private func finish() {
        choices.apply(to: registry, prefs: prefs)
        applyLaunchAtLogin(choices.launchAtLogin)
        if choices.includesClaude, choices.installHooks, hooksOffer.canInstall {
            hooksOutcome = installHooks().map(HooksOutcome.failure) ?? .success
        }
        step = .done
    }
}

// MARK: - Vues

struct SetupAssistantView: View {
    @ObservedObject var model: SetupAssistantModel

    static let size = CGSize(width: 520, height: 700)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            progress
                .padding(.bottom, 20)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
                .padding(.top, 14)
        }
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 22)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Color.black.ignoresSafeArea())
        .foregroundColor(Palette.primary)
        .environment(\.colorScheme, .dark)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(SetupAssistantModel.Step.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= model.step.rawValue ? Palette.accent : Color.white.opacity(0.14))
                    .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .tabs: tabs
        case .behavior: behavior
        case .done: done
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 21, weight: .semibold))
            Text(verbatim: subtitle)
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Étapes

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Palette.accent.opacity(0.16))
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(Palette.accent)
                }
                .frame(width: 44, height: 44)
                header(L("Bienvenue dans Oriel"),
                       L("Oriel transforme la notch de ton Mac en panneau d'outils : musique, calendrier, notes, "
                         + "presse-papiers et plus encore."))
            }
            Text("En trois étapes, choisis ce qui t'intéresse. Tu pourras tout changer ensuite.")
                .font(.system(size: 12.5))
                .foregroundColor(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: L("Pour commencer, un profil (facultatif)", table: "Profiles"))
                    .font(.system(size: 12, weight: .semibold))
                ForEach(NotchProfile.allCases) { profile in
                    SetupProfileCard(profile: profile, summary: model.summary(of: profile),
                                     isOn: model.choices.profile == profile) {
                        model.choose(profile)
                    }
                }
            }
            SetupNotchPreview(tabs: model.selectedTabs)
            if !model.inApplications { ApplicationsWarning() }
            Spacer(minLength: 0)
        }
    }

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(L("Choisis tes onglets"),
                   L("Chaque onglet est une fonction de la notch. Garde ceux qui t'intéressent : les autres ne font "
                     + "rien, même en arrière-plan."))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.tabs) { tab in
                        SetupTabCard(tab: tab, isOn: model.choices.isOn(tab.id)) {
                            model.choices.set(tab.id, !model.choices.isOn(tab.id))
                        }
                        if tab.id == ModuleRegistry.claudeId, model.choices.includesClaude { hooksOption }
                    }
                    if !model.claudeOffered { claudeHint }
                }
                .padding(.vertical, 2)
            }
            // Fondu en bas : la liste défile quand les hooks sont dépliés.
            .mask(VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
            })
            VStack(alignment: .leading, spacing: 3) {
                if model.choices.selected.count == 1 {
                    Text("Au moins un onglet reste activé.")
                }
                Text(L("macOS ne te demande une autorisation (calendrier, Bluetooth…) que lorsque tu utilises "
                       + "l'onglet concerné."))
            }
            .font(.system(size: 11))
            .foregroundColor(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Hooks Claude Code, sous la carte Claude : option, jamais posés sans accord.
    @ViewBuilder
    private var hooksOption: some View {
        switch model.hooksOffer {
        case .none: EmptyView()
        case .installed:
            Label("Hooks Claude Code installés ✓", systemImage: "checkmark.seal")
                .font(.system(size: 12))
                .foregroundColor(Palette.secondary)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .install, .update:
            VStack(alignment: .leading, spacing: 10) {
                Toggle(model.hooksOffer == .update ? L("Mettre à jour les hooks Claude Code")
                       : L("Installer les hooks Claude Code"), isOn: $model.choices.installHooks)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5, weight: .medium))
                Text(L("Sans eux, l'onglet Claude ne voit pas tes sessions. Rien n'est modifié avant « Appliquer »."))
                    .font(.system(size: 11.5))
                    .foregroundColor(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                InfoRow(icon: "doc.text", title: "~/.claude/settings.json", monospaced: true,
                        detail: L("Hooks ajoutés, sauvegarde horodatée ; les tiens restent."))
                InfoRow(icon: "terminal", title: "~/.claude/hooks/oriel-hook.sh", monospaced: true,
                        detail: L("Relaie les événements à l'app, en local (127.0.0.1)."))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
            .padding(.leading, 14)
        }
    }

    /// Sans Claude Code détecté, l'onglet n'est pas proposé : seulement où l'activer.
    private var claudeHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "✻")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Palette.accent)
            Text("Tu utilises Claude Code ? Active l'onglet Claude dans Réglages › Onglets.")
                .font(.system(size: 12))
                .foregroundColor(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var behavior: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(L("Comment l'ouvrir ?"), L("Tout se règle aussi plus tard dans Réglages."))
            card {
                Text("Ouvrir la notch")
                    .font(.system(size: 13, weight: .semibold))
                Picker("Ouvrir la notch", selection: $model.choices.openTrigger) {
                    Text("Au survol").tag(OpenTrigger.hover)
                    Text("Au clic").tag(OpenTrigger.click)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                note(model.choices.openTrigger == .hover
                     ? L("Le panneau s'ouvre dès que tu poses le pointeur sur la notch.")
                     : L("Le panneau s'ouvre quand tu cliques sur la notch."))
            }
            card {
                Text("Raccourci clavier (facultatif)")
                    .font(.system(size: 13, weight: .semibold))
                Picker("Ouvrir ou fermer le panneau", selection: $model.choices.toggleHotKey) {
                    ForEach(HotKeyChoice.pickable) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                note(L("Ouvre ou ferme le panneau de partout, sans autorisation."))
            }
            card {
                Toggle("Lancer à l'ouverture de session", isOn: $model.choices.launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13, weight: .semibold))
                    .disabled(!model.inApplications)
                note(model.inApplications ? L("La notch est là dès que tu ouvres ta session.")
                     : L("Disponible une fois l'app dans Applications."))
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            header(L("C'est prêt"), L("Voici ta notch avec les onglets choisis."))
            SetupNotchPreview(tabs: model.selectedTabs)
            hooksMessage
            VStack(alignment: .leading, spacing: 14) {
                InfoRow(icon: "ellipsis.circle", title: L("Menu « … »"),
                        detail: L("En haut à droite du panneau : réglages, mises à jour, quitter. Clic droit sur la "
                            + "notch pour la masquer."))
                InfoRow(icon: "hand.tap", title: L("Onglets"),
                        detail: L("Appui long sur la barre d'onglets : les déplacer, les masquer, en remettre."))
                InfoRow(icon: "gearshape", title: L("Réglages"),
                        detail: L("Onglets, apparence, raccourcis. Pour refaire cet assistant : Réglages › Général."))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
        }
    }

    @ViewBuilder
    private var hooksMessage: some View {
        switch model.hooksOutcome {
        case nil: EmptyView()
        case .success?:
            message(model.hooksOffer == .update
                    ? L("Hooks à jour. Les sessions déjà ouvertes apparaîtront à leur prochain message.")
                    : L("Hooks installés. Les sessions déjà ouvertes apparaîtront à leur prochain message."),
                    icon: "checkmark.circle.fill", color: Palette.green)
        case .failure(let text)?:
            message(L("Hooks non installés.") + " " + text + " " + L("Tu peux réessayer dans Réglages › Claude."),
                    icon: "xmark.octagon.fill", color: Palette.red)
        }
    }

    // MARK: Éléments

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11.5))
            .foregroundColor(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func message(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.step != .done {
                Button("Passer") { model.skip() }
                    .buttonStyle(.plain)
                    .foregroundColor(Palette.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if model.canGoBack {
                Button("Retour") { model.back() }
            }
            Button(primaryTitle) { model.next() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
        }
        .controlSize(.large)
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: return L("Commencer")
        case .tabs: return L("Continuer")
        case .behavior: return L("Appliquer")
        case .done: return L("C'est parti")
        }
    }
}

/// Carte d'un onglet : icône, nom, une ligne d'usage, case ronde. Toute la carte se clique.
struct SetupTabCard: View {
    let tab: SetupTab
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isOn ? Palette.accent.opacity(0.18) : Color.white.opacity(0.06))
                    Image(systemName: tab.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(isOn ? Palette.accent : Palette.secondary)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: tab.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: tab.usage)
                        .font(.system(size: 11.5))
                        .foregroundColor(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isOn ? Palette.accent : Color.white.opacity(0.25))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isOn ? Palette.accent.opacity(0.5) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Aperçu fixe de la notch dépliée : la barre d'onglets telle qu'elle sera, sur un faux bureau.
struct SetupNotchPreview: View {
    let tabs: [SetupTab]

    private static let band: CGFloat = 14

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.36, blue: 0.66), Color(red: 0.8, green: 0.45, blue: 0.58)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Color.white.opacity(0.22).frame(height: Self.band)
            panel
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tabs.map { $0.title }.joined(separator: ", ")))
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: Self.band - 4)
            HStack(spacing: 2) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(index == 0 ? Palette.primary : .white.opacity(0.5))
                        .frame(width: 17, height: 17)
                        .padding(.horizontal, 5)
                        .frame(height: 22)
                        .background {
                            if index == 0 { Capsule().fill(Color.white.opacity(0.12)) }
                        }
                }
                if let first = tabs.first {
                    Text(verbatim: first.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.primary)
                        .padding(.leading, 6)
                }
                Spacer(minLength: 8)
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
            }
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 8) {
                    Circle().fill(row == 0 ? Palette.accent : Palette.green).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(Color.white.opacity(0.8)).frame(width: 90, height: 4)
                        Capsule().fill(Color.white.opacity(0.3)).frame(width: 150, height: 4)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.card))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(width: 380)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: 8, bottomRadius: 18))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
    }
}
