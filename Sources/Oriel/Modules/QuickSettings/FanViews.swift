import FanControl
import SwiftUI

/// Carte « Ventilateurs » sous la grille : vitesses, températures, et la vitesse fixe. Absente sur un Mac sans
/// ventilateur. En vitesse fixe, « Rendre la main à macOS » reste toujours visible.
struct FanCard: View {
    @ObservedObject var fans: FanController
    /// Vitesse pendant un glissement du curseur (envoyée au relâchement seulement).
    @State private var dragRPM: Int?

    /// Une seule ligne dans les deux modes (44 pt) : le panneau doit rester sous 460 pt. En vitesse fixe, le curseur
    /// prend la place du détail, et un repère y montre la vitesse réelle.
    var body: some View {
        if let status = fans.status {
            HStack(spacing: 8) {
                icon
                if case .fixed(let rpm) = fans.mode, let range = fans.range {
                    speedControl(rpm: rpm, range: range, actual: status.fans.map(\.actual))
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: L("Ventilateurs", table: "QuickSettings"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(Palette.primary)
                        Text(verbatim: fans.notice ?? QuickSettingsFormat.rpm(status.fans.map(\.actual)))
                            .font(.system(size: 10.5))
                            .foregroundColor(fans.notice == nil ? Palette.secondary : Palette.amber)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    Spacer(minLength: 6)
                }
                temperatures(status.temperatures)
                action
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(ModuleStyle.shape(ModuleStyle.cardRadius).fill(fans.isFixed ? Palette.accent.opacity(0.16) : Palette.card))
            .overlay(ModuleStyle.shape(ModuleStyle.cardRadius).strokeBorder(Palette.accent.opacity(fans.isFixed ? 0.55 : 0)))
            .animation(notchSpring, value: fans.mode)
        }
    }

    private var icon: some View {
        ZStack {
            Circle().fill(fans.isFixed ? Palette.accent : Color.white.opacity(0.1))
            if fans.busy {
                Spinner()
            } else {
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(fans.isFixed ? Palette.accent.onFill : Palette.primary.opacity(0.85))
            }
        }
        .frame(width: 28, height: 28)
    }

    private func temperatures(_ reading: Thermals.Reading) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let cpu = reading.cpu { Text(verbatim: "CPU " + QuickSettingsFormat.celsius(cpu)) }
            if let gpu = reading.gpu { Text(verbatim: "GPU " + QuickSettingsFormat.celsius(gpu)) }
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundColor(Palette.secondary)
        .fixedSize()
    }

    @ViewBuilder
    private var action: some View {
        if fans.isFixed {
            capsule(L("Rendre la main à macOS", table: "QuickSettings"), prominent: true, locked: false,
                    run: fans.returnToAutomatic)
                .help(L("macOS reprend le pilotage automatique des ventilateurs.", table: "QuickSettings"))
        } else if fans.canFix {
            capsule(L("Vitesse fixe", table: "QuickSettings"), prominent: false,
                    locked: fans.authorization != .installed, run: fans.enableFixed)
                .disabled(fans.busy)
                .help(fans.authorization == .installed
                    ? L("Fixe la vitesse, jamais sous le minimum du Mac. macOS reprend la main si l'app quitte, en veille ou si la température monte trop.",
                        table: "QuickSettings")
                    : L("Le premier usage installe un petit outil (mot de passe administrateur, une seule fois) qui ne peut que fixer la vitesse entre le minimum et le maximum du Mac, ou la rendre à macOS.",
                        table: "QuickSettings"))
        }
    }

    private func capsule(_ title: String, prominent: Bool, locked: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 4) {
                if locked { Image(systemName: "lock.fill").font(.system(size: 8)) }
                Text(verbatim: title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(prominent ? Palette.accent.onFill : Palette.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(prominent ? Palette.accent : Color.white.opacity(0.1)))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(PressStyle())
    }

    /// « Vitesse fixe   4200 tr/min » et le curseur dessous, par pas de 100 tr/min, borné au minimum et au maximum
    /// du Mac. Le petit trait blanc : la vitesse réelle (moyenne des ventilateurs).
    private func speedControl(rpm: Int, range: ClosedRange<Int>, actual: [Double]) -> some View {
        let shown = dragRPM ?? rpm
        let span = Double(max(1, range.upperBound - range.lowerBound))
        func position(_ value: Double) -> Double { min(1, max(0, (value - Double(range.lowerBound)) / span)) }
        func snap(_ value: Int) -> Int { min(max((value + 50) / 100 * 100, range.lowerBound), range.upperBound) }
        let average = actual.isEmpty ? Double(rpm) : actual.reduce(0, +) / Double(actual.count)
        let value = String(format: L("%d tr/min", table: "QuickSettings"), shown)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: L("Vitesse fixe", table: "QuickSettings"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: value)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundColor(Palette.secondary)
                    .fixedSize()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(Palette.accent).frame(width: max(6, proxy.size.width * position(Double(shown))))
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: 2, height: 8)
                        .offset(x: max(0, proxy.size.width * position(average) - 1))
                }
                .frame(height: dragRPM == nil ? 4 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = min(1, max(0, drag.location.x / proxy.size.width))
                        dragRPM = snap(range.lowerBound + Int(fraction * span))
                    }
                    .onEnded { _ in
                        if let dragRPM { fans.setFixed(rpm: dragRPM) }
                        dragRPM = nil
                    })
            }
            .frame(height: 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Vitesse des ventilateurs", tableName: "QuickSettings"))
        .accessibilityValue(Text(verbatim: value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: fans.setFixed(rpm: snap(rpm + 100))
            case .decrement: fans.setFixed(rpm: snap(rpm - 100))
            @unknown default: break
            }
        }
        .animation(ModuleStyle.hover, value: dragRPM == nil)
    }
}

/// Réglages › Réglages rapides › Ventilateurs : outil installé ou non, le poser, le retirer.
struct FanSettingsSection: View {
    @ObservedObject var fans: FanController

    var body: some View {
        Section {
            Text(verbatim: Self.state(fans.authorization))
            HStack(spacing: 10) {
                if fans.busy {
                    ProgressView().controlSize(.small)
                } else if fans.authorization == .notInstalled {
                    Button(action: fans.install) { Text("Installer l'outil", tableName: "QuickSettings") }
                        .disabled(!fans.canFix)
                } else {
                    if fans.authorization == .outdated {
                        Button(action: fans.install) { Text("Mettre à jour l'outil", tableName: "QuickSettings") }
                    }
                    Button(action: fans.uninstall) { Text("Retirer l'autorisation", tableName: "QuickSettings") }
                }
                Spacer(minLength: 0)
            }
        } header: {
            Text("Ventilateurs", tableName: "QuickSettings")
        } footer: {
            SettingsNote(L("Installe dans /Library/PrivilegedHelperTools un outil qui ne peut que fixer la vitesse entre le minimum et le maximum du Mac, ou la rendre à macOS, et une règle système qui n'autorise que lui.",
                           table: "QuickSettings"))
        }
    }

    static func state(_ state: FanAuthorizationState) -> String {
        switch state {
        case .notInstalled: return L("Outil non installé : mot de passe demandé une fois, au premier passage en vitesse fixe",
                                     table: "QuickSettings")
        case .installed: return L("Outil installé : vitesse fixe sans mot de passe", table: "QuickSettings")
        case .outdated: return L("Outil d'une autre version : il sera remplacé au prochain passage en vitesse fixe",
                                 table: "QuickSettings")
        }
    }
}
