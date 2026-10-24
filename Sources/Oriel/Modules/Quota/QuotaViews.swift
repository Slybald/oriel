import SwiftUI

/// Anneau fin : la part consommée d'une fenêtre.
struct QuotaRing: View {
    let window: QuotaWindow
    var size: CGFloat = 13

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.16), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: window.usedPercent == 0 ? 0 : max(0.03, window.fraction))
                .stroke(QuotaGauge.color(window.level), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// « ◔ 5 h 19 % · 15:32 » : une fenêtre, discrète. Un seul élément pour VoiceOver.
struct QuotaGauge: View {
    let window: QuotaWindow
    let now: Date
    /// Faux dans un résumé étroit : pourcentage et anneau suffisent, l'heure de remise à zéro passe au survol.
    var showsReset = true

    static func color(_ level: QuotaWindow.Level) -> Color {
        switch level {
        case .normal: return Palette.accent
        case .high: return Palette.amber
        case .critical: return Palette.red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            QuotaRing(window: window)
            if !window.label.isEmpty {
                Text(verbatim: window.label)
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.secondary)
            }
            Text(Double(window.usedPercent) / 100, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(window.level == .normal ? Palette.primary : Self.color(window.level))
            if showsReset {
                Text(verbatim: "· " + window.resetText(now: now))
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.secondary)
            }
        }
        .help(String(format: L("remise à zéro %@", table: "Quota"), window.resetText(now: now)))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L("%@ : %@ utilisés, remise à zéro %@", table: "Quota"),
                                   window.label.isEmpty ? L("Quota", table: "Quota") : window.label,
                                   (Double(window.usedPercent) / 100).formatted(.percent.precision(.fractionLength(0))),
                                   window.resetText(now: now)))
    }
}

/// Les fenêtres d'un quota sur une ligne, sous la liste des sessions (onglets Claude et Codex) ou dans le résumé compact
/// (plein écran, carte de l'intercalaire), où `title` dit de quel agent il s'agit. Trop large : sans les heures.
struct QuotaStrip: View {
    let windows: [QuotaWindow]
    var title: String? = nil
    var now = Date()

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsReset: true)
            row(showsReset: false)
        }
        .padding(.horizontal, 4)
    }

    private func row(showsReset: Bool) -> some View {
        HStack(spacing: 14) {
            if let title {
                Text(verbatim: title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Palette.secondary)
            }
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                QuotaGauge(window: window, now: now, showsReset: showsReset)
            }
            Spacer(minLength: 0)
        }
    }
}
