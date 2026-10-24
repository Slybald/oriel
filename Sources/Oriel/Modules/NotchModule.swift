import AppKit
import Combine
import SwiftUI

/// Intercalaire proposé par un module quand la notch est repliée (minuteur, lecture en cours…).
struct ModuleEars: Equatable {
    /// Icône : SF Symbol, teinté de la couleur de l'activité.
    var symbol: String
    /// Information très courte à côté de l'icône (« 4:59 »).
    var text: String
    /// Départage les modules entre eux : le plus grand gagne, à égalité l'ordre des onglets.
    var priority: Int = 0
    /// Icône : image à la place du symbole (pochette), petite et arrondie.
    var image: NSImage? = nil
    /// Barres d'égaliseur animées à la place du texte.
    var bars = false
    /// Le module attend l'utilisateur : son intercalaire reste déployé, même en mode « Rétractés ».
    var alert = false
    /// Couleur d'accent (hex) à la place de celle du module : intercalaires de l'API locale, ou activité dont la couleur
    /// change avec son état (agenda : discret, ambre, vert). nil = celle du module.
    var accentHex: String? = nil
}

/// Notice d'un composant tiers, affichée dans Réglages › À propos › Licences.
struct LicenseNotice: Identifiable, Equatable {
    var name: String
    var text: String
    var id: String { name }
}

/// Contrat d'un onglet de la notch (voir docs/ARCHITECTURE.md, « Modules »).
///
/// - Cycle de vie : `start()` quand le module est activé ET utile (panneau déplié, ou
///   `keepsRunningWhenCollapsed`), `stop()` dès que ce n'est plus le cas. Arrêté, un module ne fait rien :
///   ni timer, ni observateur, ni lecture de fichier.
/// - Les vues sont construites à la demande (onglet affiché, mode compact, réglages) puis jetées : l'état qui
///   doit survivre vit dans le module (propriétés `@Published`).
/// - Textes : table de traduction du module, `L("…", table: "<Module>")` ou `Text("…", tableName: "<Module>")`.
protocol NotchModule: CommandSource, ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    /// Identifiant stable (« media ») : clé des réglages (ordre, activation, onglet par défaut). Ne change jamais.
    var id: String { get }
    /// Titre localisé : onglet actif, réglages.
    var title: String { get }
    /// SF Symbol de l'onglet et de la barre latérale des réglages.
    var symbol: String { get }
    /// Activé tant que l'utilisateur n'a rien choisi dans Réglages › Onglets.
    var isEnabledByDefault: Bool { get }
    /// Le module doit tourner panneau replié (ses oreilles changent, un minuteur tourne…).
    /// Relu après chaque `objectWillChange` du module.
    var keepsRunningWhenCollapsed: Bool { get }
    /// Oreilles quand la notch est repliée ; nil = rien. Lu seulement quand le module tourne.
    var ears: ModuleEars? { get }
    /// Composants tiers embarqués par le module.
    var licenseNotices: [LicenseNotice] { get }

    func start()
    func stop()

    /// Contenu de l'onglet. Largeur : `\.notchContentWidth` ; hauteur maximale : `\.notchContentMaxHeight`.
    func makeView() -> AnyView
    /// Résumé du mode compact (plein écran, demi-largeur) ; nil = absent du mode compact.
    func makeCompactView() -> AnyView?
    /// Volet de la fenêtre de réglages (un `SettingsPane`) ; nil = pas d'entrée dans la barre latérale.
    func makeSettingsView() -> AnyView?
    /// Icône d'onglet animée ; nil = `symbol`.
    func makeTabIcon() -> AnyView?
    /// Contenu à droite de la barre d'onglets quand le module est l'onglet actif.
    func makeHeaderAccessory() -> AnyView?
    /// Contenu de l'intercalaire déployé (survol de son intercalaire, notch repliée) ; par défaut le résumé compact.
    /// Largeur : `\.notchContentWidth`.
    func makeTabDetailView() -> AnyView?
}

/// Ce que la barre de commande interroge : un module, ou l'API locale (intercalaires des scripts).
protocol CommandSource: AnyObject {
    /// Verbe de la barre de commande (« t » pour le minuteur) ; nil = pas de commande ici.
    var commandVerb: CommandVerb? { get }
    /// Actions proposées pour cette saisie (voir `CommandBarModel`). Pure : rien ne s'exécute ici, seulement dans
    /// `NotchCommand.run`, appelé quand l'utilisateur valide. Sans verbe tapé (`query.verb == nil`), ne répondre
    /// qu'à une saisie sans ambiguïté. Lue seulement quand le module tourne : la recherche ne réveille aucun module.
    func commands(for query: CommandQuery) -> [NotchCommand]
}

extension NotchModule {
    var isEnabledByDefault: Bool { true }
    var keepsRunningWhenCollapsed: Bool { false }
    var ears: ModuleEars? { nil }
    var licenseNotices: [LicenseNotice] { [] }
    func start() {}
    func stop() {}
    func makeCompactView() -> AnyView? { nil }
    func makeSettingsView() -> AnyView? { nil }
    func makeTabIcon() -> AnyView? { nil }
    func makeHeaderAccessory() -> AnyView? { nil }
    func makeTabDetailView() -> AnyView? { makeCompactView() }
    var commandVerb: CommandVerb? { nil }
    func commands(for query: CommandQuery) -> [NotchCommand] { [] }
}

// MARK: - Environnement des vues de module

private struct ContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = PanelSize.standard.width - 2 * ExpandedPanel.horizontalPadding
}

private struct ContentMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 380
}

extension EnvironmentValues {
    /// Largeur utile du panneau (marges déduites).
    var notchContentWidth: CGFloat {
        get { self[ContentWidthKey.self] }
        set { self[ContentWidthKey.self] = newValue }
    }

    /// Hauteur maximale du contenu sous l'en-tête : au-delà, le panneau sortirait de sa fenêtre.
    var notchContentMaxHeight: CGFloat {
        get { self[ContentMaxHeightKey.self] }
        set { self[ContentMaxHeightKey.self] = newValue }
    }
}

// MARK: - Onglet pas encore codé

/// Vue des modules vides : symbole, titre, une phrase, « Bientôt disponible ».
struct ComingSoonView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(Palette.accent)
                .frame(height: 28)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Palette.primary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(Palette.secondary)
                .multilineTextAlignment(.center)
            Text("Bientôt disponible")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
