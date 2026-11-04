import SwiftUI

/// Le pop-up qui descend sous la notch repliée : icône, titre, une ligne. Même fond que les intercalaires (noir, teinte
/// choisie, ou flou pour le caméléon). Un clic ouvre l'onglet de la source ; le survol (suivi par le contrôleur) le garde ouvert.
struct NotchPopupView: View {
    let event: PopupEvent
    let fill: Color
    /// Caméléon : flou dépoli à la place du fond.
    let glass: Bool
    let open: () -> Void

    private var accent: Color { event.accentHex.flatMap { Color(hex: $0) } ?? Palette.accent }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PopupLayout.cornerRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .lineLimit(1)
                Text(verbatim: event.text)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if event.extra > 0 {
                Text(verbatim: "+\(event.extra)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
        }
        .padding(.horizontal, 14)
        .frame(width: PopupLayout.width, height: PopupLayout.height)
        .background(ZStack {
            if glass {
                NotchGlass().clipShape(shape)
            } else {
                shape.fill(fill)
            }
        })
        .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .contentShape(shape)
        .onTapGesture(perform: open)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.title), \(event.text)")
        .accessibilityHint(L("Ouvre l'onglet correspondant"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
    }
}
