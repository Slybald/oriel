import SwiftUI

/// Le vrai Liquid Glass d'Apple (`glassEffect`, macOS 26 et plus). Il n'existe que dans le SDK de Swift 6.2 (Xcode 26) :
/// avec un SDK plus ancien, `#if compiler(>=6.2)` le retire sans erreur, et `release.yml` vérifie que le binaire publié
/// le contient. Avant macOS 26, ou sans ce SDK, `isAvailable` est faux et les vues gardent le flou (`NotchGlass`).
enum LiquidGlass {
    /// Teinte sombre dans le matériau (pas un voile par-dessus : la lentille et les reflets restent). Mesuré sur le rendu
    /// réel, texte blanc sur le pire fond d'écran (blanc pur) : 3,2 sans teinte, 4,0 à 0,15, 5,3 à 0,3 (WCAG AA : 4,5).
    /// Le repli flou, lui, a besoin de 0,55 (`PanelGlass.fallbackScrim`).
    static let tintOpacity = 0.3
    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }
}

/// Où dessiner le fond plein de la notch repliée. Dans la vue qui porte le verre, un fond inséré à la fermeture restait sur
/// la gauche jusqu'à 1 s avant de revenir au centre (3.3.0, vidéo de l'écran réel) : le vrai verre n'en a donc jamais dans cette vue.
enum CollapsedFill {
    /// Dans la vue de la notch : tous les fonds sauf le vrai verre, rendu inchangé.
    case inNotchView
    /// Derrière le conteneur de verre, hors de son système : encoche virtuelle, pilule, perle.
    case behindGlass
    /// Aucun : une vraie encoche est noire d'elle-même, le caméléon est en verre, le panneau déplié aussi.
    case absent

    static func choose(liquidGlass: Bool, expanded: Bool, hasNotch: Bool, chameleon: Bool) -> CollapsedFill {
        guard liquidGlass else { return .inNotchView }
        return expanded || hasNotch || chameleon ? .absent : .behindGlass
    }
}

extension View {
    /// Le verre sous cette vue, à sa forme exacte : la lentille, la réfraction et les reflets du bord viennent du matériau
    /// (teinte interne légère, pas de voile ni de flou ajouté), qui adapte lui-même sa teinte à ce qu'il y a derrière.
    /// À appliquer à la vue elle-même et non en `background` d'une autre : le contenu reste net au-dessus (un `glassEffect`
    /// sur un fond le recouvrait et le floutait). À poser après le `clipShape` du contenu, sans masque sur le verre, qui
    /// couperait les reflets du bord.
    /// `enabled` : ce choix de fond utilise le verre (et `LiquidGlass.isAvailable`) ; faux, la vue est rendue telle quelle,
    /// même hors écran (un `Glass.identity` change déjà le rendu). `active` : le verre est visible maintenant ; faux, c'est
    /// `Glass.identity` : la vue garde son identité (pas de fondu de tout le panneau à l'ouverture).
    func liquidGlass<S: Shape>(enabled: Bool, active: Bool, in shape: S) -> some View {
        modifier(LiquidGlassModifier(enabled: enabled, active: active, shape: shape))
    }
}

private struct LiquidGlassModifier<S: Shape>: ViewModifier {
    let enabled: Bool
    let active: Bool
    let shape: S

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *), enabled {
            content.glassEffect(active ? .regular.tint(.black.opacity(LiquidGlass.tintOpacity)) : .identity, in: shape)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Fait fusionner comme du liquide les verres voisins (le panneau, la notch et les intercalaires). Sans effet avant
/// macOS 26, et sans `enabled` (choix de fond autre que Verre : le rendu ne change pas du tout).
struct LiquidGlassGroup<Content: View>: View {
    let enabled: Bool
    let content: Content
    init(enabled: Bool, @ViewBuilder _ content: () -> Content) {
        self.enabled = enabled
        self.content = content()
    }

    @ViewBuilder var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *), enabled {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
