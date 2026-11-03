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

extension View {
    /// Le verre sous cette vue, à sa forme exacte : la lentille, la réfraction et les reflets du bord viennent du matériau
    /// (aucun voile ni flou ajouté), qui adapte lui-même sa teinte à ce qu'il y a derrière. À appliquer à la vue elle-même
    /// et non en `background` d'une autre : le contenu reste net au-dessus (un `glassEffect` sur un fond le recouvrait et le
    /// floutait). À poser après le `clipShape` du contenu, sans masque sur le verre, qui couperait les reflets du bord.
    /// `active` faux : pas de verre (`Glass.identity`), la vue garde son identité. Sans effet si `LiquidGlass.isAvailable` est faux.
    func liquidGlass<S: Shape>(_ active: Bool, in shape: S) -> some View {
        modifier(LiquidGlassModifier(active: active, shape: shape))
    }
}

private struct LiquidGlassModifier<S: Shape>: ViewModifier {
    let active: Bool
    let shape: S

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content.glassEffect(active ? .regular.tint(.black.opacity(LiquidGlass.tintOpacity)) : .identity, in: shape)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Fait fusionner comme du liquide les verres voisins (le panneau, la notch et les intercalaires). Sans effet avant macOS 26.
struct LiquidGlassGroup<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    @ViewBuilder var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
