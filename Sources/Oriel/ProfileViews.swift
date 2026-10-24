import SwiftUI

// Vues des profils : la carte de l'assistant de configuration (première étape) et la fenêtre « Changer de profil »
// de Réglages › Général. La logique est dans Profiles.swift ; textes dans la table « Profiles ».

/// Carte d'un profil : icône, nom, ses onglets en une ligne, case ronde. Toute la carte se clique.
struct SetupProfileCard: View {
    let profile: NotchProfile
    /// Les onglets que ce profil affichera sur ce Mac, séparés par des virgules.
    let summary: String
    let isOn: Bool
    var badge: String?
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isOn ? Palette.accent.opacity(0.18) : Color.white.opacity(0.06))
                    Image(systemName: profile.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isOn ? Palette.accent : Palette.secondary)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: profile.title)
                            .font(.system(size: 13, weight: .semibold))
                        if let badge {
                            Text(verbatim: badge)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.8))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                        }
                    }
                    Text(verbatim: summary)
                        .font(.system(size: 11.5))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isOn ? Palette.accent : Color.white.opacity(0.25))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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

// MARK: - Changer de profil (Réglages › Général)

/// Le choix d'un profil depuis les réglages : rien n'est écrit avant « Appliquer le profil ».
final class ProfileChangeModel: ObservableObject {
    /// Les onglets de l'app (titre, icône), dans l'ordre des réglages.
    let tabs: [SetupTab]
    /// Le profil dont les onglets sont les tiens, nil = « Personnalisé ».
    let current: NotchProfile?
    @Published var selected: NotchProfile?

    private let registry: ModuleRegistry
    private let prefs: Preferences
    private let offered: [String]
    private let enabledNow: [String]
    private let close: () -> Void

    /// `detected` : les assistants (Claude, Codex) trouvés sur le Mac. Un assistant absent n'est proposé que si son
    /// onglet est déjà activé.
    init(registry: ModuleRegistry, prefs: Preferences, detected: Set<String>, close: @escaping () -> Void) {
        self.registry = registry
        self.prefs = prefs
        self.close = close
        tabs = registry.ordered.map { SetupTab($0) }
        offered = NotchProfile.offered(order: registry.ordered.map { $0.id }, detected: detected,
                                       isEnabled: { registry.isEnabled($0) })
        enabledNow = registry.enabled.map { $0.id }
        current = NotchProfile.matching(enabled: enabledNow, known: registry.modules.map { $0.id })
    }

    var plan: ProfilePlan? {
        selected.map { ProfilePlan($0, current: registry.ordered.map { $0.id }, offered: offered) }
    }

    /// Les onglets que `profile` affichera ici, séparés par des virgules.
    func summary(of profile: NotchProfile) -> String {
        titles(ProfilePlan(profile, current: offered, offered: offered).shown).joined(separator: ", ")
    }

    func titles(_ ids: [String]) -> [String] {
        ids.compactMap { id in tabs.first { $0.id == id }?.title }
    }

    /// Titres des onglets aujourd'hui affichés que `plan` masque.
    func hiddenTitles(_ plan: ProfilePlan) -> [String] {
        titles(plan.newlyHidden(enabled: enabledNow))
    }

    func shownTabs(_ plan: ProfilePlan) -> [SetupTab] {
        plan.shown.compactMap { id in tabs.first { $0.id == id } }
    }

    func apply() {
        plan?.apply(to: registry, prefs: prefs)
        close()
    }

    func cancel() { close() }
}

struct ProfileChangeView: View {
    @ObservedObject var model: ProfileChangeModel

    static let size = CGSize(width: 480, height: 584)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: L("Changer de profil", table: "Profiles"))
                    .font(.system(size: 18, weight: .semibold))
                Text(verbatim: L("Un profil règle tes onglets, leur ordre, l'ouverture du panneau et les oreilles. "
                                 + "Tes données et tes hooks ne changent pas.", table: "Profiles"))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                ForEach(NotchProfile.allCases) { profile in
                    SetupProfileCard(profile: profile, summary: model.summary(of: profile),
                                     isOn: model.selected == profile,
                                     badge: model.current == profile ? L("Actuel", table: "Profiles") : nil) {
                        model.selected = profile
                    }
                }
            }
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 10) {
                Spacer()
                Button("Annuler") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Appliquer le profil", table: "Profiles")) { model.apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .disabled(model.selected == nil)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Color.black)
        .foregroundColor(Palette.primary)
        .environment(\.colorScheme, .dark)
    }

    /// Ce qui va changer : la barre d'onglets telle qu'elle sera, puis les réglages touchés.
    @ViewBuilder
    private var preview: some View {
        if let plan = model.plan {
            let hidden = model.hiddenTitles(plan)
            VStack(alignment: .leading, spacing: 10) {
                SetupTabBarPreview(tabs: model.shownTabs(plan))
                VStack(alignment: .leading, spacing: 8) {
                    line("rectangle.split.3x1", L("Onglets affichés", table: "Profiles"),
                         model.titles(plan.shown).joined(separator: ", "))
                    if !hidden.isEmpty {
                        line("eye.slash", L("Onglets masqués", table: "Profiles"),
                             hidden.joined(separator: ", ") + " — "
                             + L("ils s'arrêtent mais gardent leurs données.", table: "Profiles"))
                    }
                    line("hand.point.up.left", L("Ouverture et oreilles", table: "Profiles"),
                         (plan.profile.openTrigger == .hover ? L("Au survol") : L("Au clic")) + " · "
                         + (plan.profile.showEars ? L("Oreilles affichées", table: "Profiles")
                            : L("Oreilles masquées", table: "Profiles")))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
        } else {
            Text(verbatim: L("Choisis un profil pour voir ce qui change.", table: "Profiles"))
                .font(.system(size: 12))
                .foregroundColor(Palette.secondary)
        }
    }

    private func line(_ icon: String, _ title: String, _ detail: String) -> some View {
        InfoRow(icon: icon, title: title, detail: detail)
    }
}

/// La barre d'onglets telle qu'elle sera (icônes de la notch), sans faux bureau.
struct SetupTabBarPreview: View {
    let tabs: [SetupTab]

    var body: some View {
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tabs.map { $0.title }.joined(separator: ", ")))
    }
}

/// Fenêtre « Changer de profil » (même style que l'assistant) : une seule à la fois, libérée à la fermeture.
final class ProfileWindow {
    static let shared = ProfileWindow()

    private var controller: OnboardingWindowController?

    func show(registry: ModuleRegistry, prefs: Preferences) {
        if let controller {
            controller.showWindow(nil)
            HookSetup.activateApp()
            return
        }
        let model = ProfileChangeModel(registry: registry, prefs: prefs, detected: NotchProfile.agentsOnThisMac(),
                                       close: { [weak self] in self?.controller?.close() })
        let controller = OnboardingWindowController(rootView: ProfileChangeView(model: model))
        controller.onClose = { [weak self] in self?.controller = nil }
        self.controller = controller
        controller.window?.center()
        controller.showWindow(nil)
        HookSetup.activateApp()
    }
}
