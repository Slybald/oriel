import AppKit
import SwiftUI

// Gabarit commun des vues de module : mêmes rayons, mêmes boutons, mêmes états vides, mêmes bandeaux, même
// fondu des listes qui défilent. Un module n'invente pas son propre style : il assemble ces pièces.
//
// Hiérarchie typographique : titre 13 semi-gras, corps 11–12, secondaire 11 en `Palette.secondary`.
// Couleurs : accent pour ce qui est actif ou cliquable, ambre pour un avertissement ou une autorisation refusée.

enum ModuleStyle {
    /// Cartes (lecteur, minuteur, notes, tuiles, scènes) : 12 pt.
    static let cardRadius: CGFloat = 12
    /// Lignes, bandeaux et résumés du mode compact : 10 pt.
    static let rowRadius: CGFloat = 10
    /// Éléments d'une liste placée dans une carte : 8 pt.
    static let itemRadius: CGFloat = 8
    /// Même retour au survol partout.
    static let hover = Animation.easeOut(duration: 0.12)

    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

extension Color {
    /// Texte ou symbole lisible sur cette couleur d'accent : noir sur les accents clairs, blanc sur les foncés.
    var onFill: Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance > 0.62 ? Color.black.opacity(0.85) : .white
    }
}

// MARK: - Boutons

/// Action secondaire d'un état vide ou d'un bandeau.
struct ModuleAction {
    let title: String
    var symbol: String?
    var style: ModuleCapsuleButton.Style = .soft
    let run: () -> Void
}

/// Bouton en capsule : plein (l'action principale), teinté (une action secondaire) ou ambre (un avertissement).
struct ModuleCapsuleButton: View {
    enum Style { case prominent, soft, warning }

    let title: String
    var symbol: String?
    var style: Style = .soft
    let action: () -> Void

    @State private var hovering = false

    private var tint: Color { style == .warning ? Palette.amber : Palette.accent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
                Text(verbatim: title).lineLimit(1).minimumScaleFactor(0.85)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(style == .prominent ? Palette.accent.onFill : tint)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(style == .prominent ? tint.opacity(hovering ? 1 : 0.85)
                                       : tint.opacity(hovering ? 0.24 : 0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: hovering)
    }
}

/// Bouton-icône : symbole seul, halo au survol, infobulle et étiquette VoiceOver.
struct ModuleIconButton: View {
    let symbol: String
    let label: String
    var box: CGFloat = 22
    var size: CGFloat = 11
    var weight: Font.Weight = .semibold
    /// Couleur fixe (ambre pour « reprendre ») ; sinon blanc, plus net au survol.
    var tint: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundColor(tint ?? .white.opacity(hovering ? 1 : 0.7))
                .frame(width: box, height: box)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - États vides et bandeaux

/// État vide ou d'erreur : symbole, titre, une phrase qui dit quoi faire, une action si elle aide.
/// À l'appelant de le placer (marge verticale, ou plein cadre dans une carte).
struct ModuleEmptyState: View {
    let symbol: String
    var tint: Color = Palette.accent
    let title: String
    var detail: String?
    var progress = false
    /// Dans une demi-carte (lecteur, calendrier) : un cran plus petit.
    var compact = false
    var action: ModuleAction?

    var body: some View {
        VStack(spacing: compact ? 5 : 6) {
            Group {
                if progress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: compact ? 18 : 22, weight: .medium))
                        .foregroundColor(tint)
                }
            }
            .frame(height: compact ? 22 : 28)
            Text(verbatim: title)
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .foregroundColor(Palette.primary)
            if let detail {
                Text(verbatim: detail)
                    .font(.system(size: compact ? 10.5 : 11))
                    .foregroundColor(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                ModuleCapsuleButton(title: action.title, symbol: action.symbol, style: action.style, action: action.run)
                    .padding(.top, 3)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// Bandeau d'une ligne (ou plus) sous ou sur le contenu : ambre pour un avertissement, neutre pour une information.
struct ModuleBanner: View {
    enum Tone { case warning, neutral }

    static let minHeight: CGFloat = 32

    /// nil dans une colonne étroite (la liste des notes), où l'icône prendrait la place du texte.
    let symbol: String?
    var tone: Tone = .warning
    let text: String
    var font = Font.system(size: 11.5, weight: .medium)
    var lines: Int? = 1
    /// Marge à gauche et à droite (8 dans une colonne étroite).
    var inset: CGFloat = 10
    var action: ModuleAction?
    var dismiss: (label: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tone == .warning ? Palette.amber : Palette.secondary)
            }
            Text(verbatim: text)
                .font(font)
                .foregroundColor(Palette.primary)
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                ModuleCapsuleButton(title: action.title, symbol: action.symbol, style: action.style, action: action.run)
            }
            if let dismiss {
                ModuleIconButton(symbol: "xmark", label: dismiss.label, box: 20, size: 9, weight: .bold,
                                 action: dismiss.run)
            }
        }
        .padding(.horizontal, inset)
        .padding(.vertical, 6)
        .frame(minHeight: Self.minHeight)
        .background(ModuleStyle.shape(ModuleStyle.rowRadius)
            .fill(tone == .warning ? Palette.amber.opacity(0.12) : Palette.card))
    }
}

// MARK: - Mode compact

/// Une ligne du résumé plein écran : marges et rayon communs à tous les modules.
struct ModuleSummaryRow<Content: View>: View {
    var fill = Palette.card
    /// Contour en tirets (zone de dépôt).
    var dashed: Color?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .frame(minHeight: 22)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(ModuleStyle.shape(ModuleStyle.rowRadius).fill(fill))
            .overlay(ModuleStyle.shape(ModuleStyle.rowRadius)
                .strokeBorder(dashed ?? .clear, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
            .contentShape(ModuleStyle.shape(ModuleStyle.rowRadius))
    }
}

/// Symbole qui ouvre une ligne du résumé compact.
struct ModuleSummaryIcon: View {
    let symbol: String
    var tint: Color = Palette.accent

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: 20)
    }
}

// MARK: - Défilement

extension View {
    /// Une liste qui défile s'estompe en bas au lieu de couper une ligne net.
    func bottomFade(_ active: Bool, height: CGFloat = 18) -> some View {
        mask(VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: active ? height : 0)
        })
    }
}

private struct ScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ScrollViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Liste verticale qui remplit la place donnée, sans barre, et qui s'estompe en bas quand elle déborde.
struct FadingScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    @State private var contentHeight: CGFloat = 0
    @State private var viewHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content.background(GeometryReader { proxy in
                Color.clear.preference(key: ScrollContentHeightKey.self, value: proxy.size.height)
            })
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ScrollViewHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(ScrollContentHeightKey.self) { contentHeight = $0 }
        .onPreferenceChange(ScrollViewHeightKey.self) { viewHeight = $0 }
        .bottomFade(contentHeight > viewHeight + 1)
    }
}
