import SwiftUI

/// Le vrai Liquid Glass d'Apple (`glassEffect`, macOS 26 et plus). Il n'existe que dans le SDK de Swift 6.2 (Xcode 26) :
/// avec un SDK plus ancien, `#if compiler(>=6.2)` le retire sans erreur, et `release.yml` vérifie que le binaire publié
/// le contient. Avant macOS 26, ou sans ce SDK, `isAvailable` est faux et les vues gardent le flou (`NotchGlass`).
enum LiquidGlass {
    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }
}

/// Le verre, sans voile ni flou ajouté : la lentille, la réfraction et les reflets du bord viennent du matériau, qui
/// adapte lui-même sa teinte à ce qu'il y a derrière. Il prend la forme exacte, sans masque (un masque couperait les
/// reflets du bord) : à poser en `background` APRÈS le `clipShape` du contenu. Vide si `LiquidGlass.isAvailable` est faux.
struct LiquidGlassFill<S: Shape>: View {
    let shape: S

    @ViewBuilder var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular, in: shape)
                .glassEffectTransition(.materialize)
        }
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
