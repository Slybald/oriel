import AppKit
import SwiftUI

// MARK: - Onglet

/// Grille de tuiles (Wi-Fi, Bluetooth, Concentration, économie d'énergie, caféine, batterie), ventilateurs, durée
/// de la caféine, batteries des accessoires, scènes, et le message d'erreur éventuel.
struct QuickSettingsView: View {
    @ObservedObject var module: QuickSettingsModule

    private enum Entry: Hashable {
        case wifi, bluetooth, focus, lowPower, caffeine, battery
    }

    /// Une tuile n'apparaît que si elle sert à quelque chose sur ce Mac (pas de Wi-Fi, pas d'économie d'énergie…).
    private var entries: [Entry] {
        var result: [Entry] = []
        if module.wifi != nil { result.append(.wifi) }
        if module.bluetooth != nil { result.append(.bluetooth) }
        result.append(.focus)
        if module.lowPowerSupported { result.append(.lowPower) }
        result.append(.caffeine)
        result.append(.battery)
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ExpandedPanel.spacing) {
            grid
            FanCard(fans: module.fans)
            caffeineRow
            if !module.accessories.isEmpty { AccessoriesCard(accessories: module.accessories) }
            scenes
            if let issue = module.issue {
                IssueBanner(issue: issue, perform: { module.perform(issue) }, dismiss: module.dismissIssue)
                    .transition(.opacity)
            }
        }
        .animation(notchSpring, value: module.issue)
        .onAppear { module.viewAppeared() }
        .onDisappear { module.viewDisappeared() }
    }

    // MARK: Tuiles

    private var grid: some View {
        let rows = stride(from: 0, to: entries.count, by: 3).map { Array(entries[$0..<min($0 + 3, entries.count)]) }
        return VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    ForEach(rows[index], id: \.self) { tile($0) }
                    ForEach(0..<(3 - rows[index].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
    }

    @ViewBuilder
    private func tile(_ entry: Entry) -> some View {
        switch entry {
        case .wifi:
            let on = module.wifi == true
            TileView(icon: AnyView(Image(systemName: on ? "wifi" : "wifi.slash")), title: L("Wi-Fi", table: "QuickSettings"),
                      detail: !on ? L("Désactivé", table: "QuickSettings")
                          : module.wifiConnected ? L("Connecté", table: "QuickSettings") : L("Non connecté", table: "QuickSettings"),
                      isOn: on, isBusy: module.busy.contains(.wifi), action: module.toggleWiFi)
        case .bluetooth:
            let on = module.bluetooth == true
            TileView(icon: AnyView(BluetoothGlyph().frame(width: 11, height: 15)), title: L("Bluetooth", table: "QuickSettings"),
                      detail: on ? L("Activé", table: "QuickSettings") : L("Désactivé", table: "QuickSettings"),
                      isOn: on, isBusy: module.busy.contains(.bluetooth), action: module.toggleBluetooth)
        case .focus:
            TileView(icon: AnyView(Image(systemName: "moon.fill")), title: L("Concentration", table: "QuickSettings"),
                      detail: focusDetail, isOn: module.focus, isBusy: module.busy.contains(.focus),
                      action: module.toggleFocus)
                .help(L("Réglée par un raccourci : macOS ne permet pas de lire son état, celui du dernier clic est affiché.",
                        table: "QuickSettings"))
        case .lowPower:
            TileView(icon: AnyView(Image(systemName: "leaf.fill")), title: L("Économie", table: "QuickSettings"),
                      detail: module.lowPower ? L("Activée", table: "QuickSettings") : L("Désactivée", table: "QuickSettings"),
                      isOn: module.lowPower, isBusy: module.busy.contains(.lowPower),
                      isLocked: Self.asksPassword(module.authorization), action: module.toggleLowPower)
                .help(Self.lowPowerHelp(module.authorization))
        case .caffeine:
            TileView(icon: AnyView(Image(systemName: "cup.and.saucer.fill")), title: L("Caféine", table: "QuickSettings"),
                      detail: caffeineDetail, isOn: module.caffeine != nil, isBusy: false, action: module.toggleCaffeine)
                .help(L("Empêche la mise en veille du Mac.", table: "QuickSettings"))
        case .battery:
            batteryTile
        }
    }

    private var focusDetail: String {
        let configured = module.prefs.shortcut(turningOn: true) != nil || module.prefs.shortcut(turningOn: false) != nil
        if !configured { return L("À configurer", table: "QuickSettings") }
        return module.focus ? L("Activé", table: "QuickSettings") : L("Désactivé", table: "QuickSettings")
    }

    private var caffeineDetail: String {
        guard let session = module.caffeine else { return L("Désactivée", table: "QuickSettings") }
        guard let minutes = QuickSettingsFormat.remainingMinutes(of: session, now: module.now) else {
            return L("Sans limite", table: "QuickSettings")
        }
        return String(format: L("Encore %@", table: "QuickSettings"), QuickSettingsFormat.duration(minutes: minutes))
    }

    private var batteryTile: some View {
        guard let mac = module.mac else {
            return TileView(icon: AnyView(Image(systemName: "powerplug.fill")), title: L("Secteur", table: "QuickSettings"),
                             detail: L("Pas de batterie", table: "QuickSettings"), isOn: false, isBusy: false, action: nil)
        }
        return TileView(icon: AnyView(BatteryGlyph(source: mac)), title: QuickSettingsFormat.percent(mac.percent),
                         detail: Self.batteryDetail(mac), isOn: false, isBusy: false, action: nil)
    }

    /// « En charge · 1 h 12 », « Il reste 3 h 47 », « Branchée », « Chargée ».
    static func batteryDetail(_ mac: PowerSourceInfo) -> String {
        if mac.isCharging {
            let charging = L("En charge", table: "QuickSettings")
            return mac.minutes.map { "\(charging) · \(QuickSettingsFormat.duration(minutes: $0))" } ?? charging
        }
        if mac.isPluggedIn {
            return mac.percent >= 100 ? L("Chargée", table: "QuickSettings") : L("Branchée", table: "QuickSettings")
        }
        if let minutes = mac.minutes {
            return String(format: L("Il reste %@", table: "QuickSettings"), QuickSettingsFormat.duration(minutes: minutes))
        }
        return L("Sur batterie", table: "QuickSettings")
    }

    // MARK: Durée de la caféine

    private var caffeineRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("Durée de la caféine", tableName: "QuickSettings")
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 8)
            ForEach(CaffeineDuration.allCases) { duration in
                let selected = module.prefs.caffeineDuration == duration
                Button {
                    module.selectCaffeineDuration(duration)
                } label: {
                    Text(duration.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(selected ? Palette.accent.onFill : Palette.primary)
                        .frame(minWidth: 26)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(selected ? Palette.accent : Color.white.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .foregroundColor(Palette.secondary)
        .padding(.horizontal, 2)
        .animation(notchSpring, value: module.prefs.caffeineDuration)
    }

    // MARK: Scènes

    private var scenes: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Scènes", tableName: "QuickSettings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                if module.busy.contains(.scene) {
                    Spinner()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            HStack(spacing: 8) {
                ForEach(QuickScene.allCases) { scene in
                    SceneButton(scene: scene, subtitle: sceneSubtitle(scene), isActive: module.isSceneActive(scene),
                                isEnabled: scene != .normal || module.canRestoreNormal,
                                action: { module.applyScene(scene) })
                }
            }
        }
    }

    /// Le mot de passe est-il demandé à chaque bascule ? Cadenas de la tuile et note de pied n'existent que dans ce
    /// cas.
    static func asksPassword(_ authorization: LowPowerAuthorizationState) -> Bool { authorization != .granted }

    /// Le premier clic pose la règle dans la même fenêtre d'autorisation : pas de note à lire avant.
    static func lowPowerHelp(_ authorization: LowPowerAuthorizationState) -> String {
        switch authorization {
        case .granted: return L("Active ou coupe l'économie d'énergie, sans mot de passe.", table: "QuickSettings")
        case .onFirstUse, .refused: return L("Touch ID ou ton mot de passe une seule fois, au premier changement.",
                                             table: "QuickSettings")
        case .none: return L("Demande Touch ID ou ton mot de passe à chaque changement.", table: "QuickSettings")
        }
    }

    private func sceneSubtitle(_ scene: QuickScene) -> String {
        Self.sceneSubtitle(scene, lowPowerSupported: module.lowPowerSupported,
                           noBluetooth: module.prefs.autonomyBluetoothOff, withFocus: module.prefs.presentationFocus,
                           canRestore: module.canRestoreNormal)
    }

    /// Ce que fait la scène, en une ligne : le panneau « Compact » (480 pt) laisse environ 100 pt au texte.
    static func sceneSubtitle(_ scene: QuickScene, lowPowerSupported: Bool, noBluetooth: Bool, withFocus: Bool,
                              canRestore: Bool) -> String {
        switch scene {
        case .autonomy:
            if lowPowerSupported {
                return noBluetooth ? L("Économie, sans BT", table: "QuickSettings")
                    : L("Économie d'énergie", table: "QuickSettings")
            }
            return noBluetooth ? L("Sans BT, sans caféine", table: "QuickSettings")
                : L("Caféine coupée", table: "QuickSettings")
        case .normal:
            return canRestore ? L("Retour à l'état d'avant", table: "QuickSettings")
                : L("Rien à restaurer", table: "QuickSettings")
        case .presentation:
            return withFocus ? L("Écran + Concentration", table: "QuickSettings")
                : L("Écran allumé", table: "QuickSettings")
        }
    }
}

// MARK: - Composants

/// Réaction au clic : léger enfoncement.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(ModuleStyle.hover, value: configuration.isPressed)
    }
}

struct Spinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.6)
            .frame(width: 12, height: 12)
            .environment(\.colorScheme, .dark)
    }
}

/// Une tuile : pastille d'icône (couleur d'accent quand c'est actif), titre, état. Sans action, c'est une simple
/// information (batterie).
struct TileView: View {
    let icon: AnyView
    let title: String
    let detail: String
    let isOn: Bool
    let isBusy: Bool
    var isLocked = false
    let action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(PressStyle())
                .disabled(isBusy)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(title), \(detail)"))
                .accessibilityAddTraits(isOn ? .isSelected : [])
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(title), \(detail)"))
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(isOn ? Palette.accent : Color.white.opacity(0.1))
                if isBusy {
                    Spinner()
                } else {
                    icon
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(isOn ? Palette.accent.onFill : Palette.primary.opacity(0.85))
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(verbatim: detail)
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
            ModuleStyle.shape(ModuleStyle.cardRadius)
                .fill(isOn ? Palette.accent.opacity(0.16) : Palette.card)
        )
        .overlay(
            ModuleStyle.shape(ModuleStyle.cardRadius)
                .strokeBorder(Palette.accent.opacity(isOn ? 0.55 : 0), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 7.5))
                    .foregroundColor(Palette.secondary.opacity(0.7))
                    .padding(6)
            }
        }
        .contentShape(ModuleStyle.shape(ModuleStyle.cardRadius))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isOn)
    }
}

/// Bouton d'une scène : icône, nom, ce qu'elle fait.
struct SceneButton: View {
    let scene: QuickScene
    let subtitle: String
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: scene.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isActive ? Palette.accent : Palette.primary.opacity(0.85))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: scene.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Palette.primary)
                        .lineLimit(1)
                    Text(verbatim: subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                ModuleStyle.shape(ModuleStyle.cardRadius)
                    .fill(isActive ? Palette.accent.opacity(0.16) : Palette.card)
            )
            .overlay(
                ModuleStyle.shape(ModuleStyle.cardRadius)
                    .strokeBorder(Palette.accent.opacity(isActive ? 0.55 : 0), lineWidth: 1)
            )
            .contentShape(ModuleStyle.shape(ModuleStyle.cardRadius))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(PressStyle())
        .disabled(!isEnabled)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Batterie des accessoires (AirPods, boîtier, clavier…) : une ligne chacun, trois au plus. S'il y en a davantage,
/// la dernière ligne devient « +N autres » : le panneau doit rester sous 460 pt.
struct AccessoriesCard: View {
    static let maxRows = 3
    let accessories: [PowerSourceInfo]

    private var shown: [PowerSourceInfo] {
        accessories.count > Self.maxRows ? Array(accessories.prefix(Self.maxRows - 1)) : accessories
    }

    var body: some View {
        let hidden = accessories.count - shown.count
        VStack(spacing: 6) {
            ForEach(shown) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11.5))
                        .foregroundColor(Palette.secondary)
                        .frame(width: 18)
                    Text(verbatim: item.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Palette.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(verbatim: QuickSettingsFormat.percent(item.percent))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(Palette.primary)
                    BatteryGlyph(source: item)
                }
            }
            if hidden > 0 {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 18, height: 1)
                    Text(verbatim: String(format: L(hidden, one: "+%d autre", other: "+%d autres", table: "QuickSettings"),
                                          hidden))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Palette.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ModuleStyle.shape(ModuleStyle.cardRadius).fill(Palette.card))
    }
}

/// Message d'erreur sous la grille : texte, action éventuelle (ouvrir Réglages Système), fermeture.
struct IssueBanner: View {
    let issue: QuickSettingsIssue
    let perform: () -> Void
    let dismiss: () -> Void

    var body: some View {
        ModuleBanner(symbol: "exclamationmark.triangle.fill", text: issue.message, lines: 2,
                     action: issue.actionTitle.flatMap { title in
                         issue.actionURL == nil ? nil : ModuleAction(title: title, style: .warning, run: perform)
                     },
                     dismiss: (L("Fermer", table: "QuickSettings"), dismiss))
    }
}

// MARK: - Glyphes

/// Petite batterie dessinée : remplissage proportionnel, éclair en charge, rouge/ambre quand elle est faible.
struct BatteryGlyph: View {
    let source: PowerSourceInfo

    private var tint: Color {
        if source.isCharging { return Palette.green }
        if source.percent <= 10 { return Palette.red }
        if source.percent <= 20 { return Palette.amber }
        return Palette.primary.opacity(0.9)
    }

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(Palette.primary.opacity(0.55), lineWidth: 1)
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint)
                        .frame(width: max(2, (proxy.size.width - 4) * CGFloat(min(max(source.percent, 0), 100)) / 100))
                        .padding(2)
                }
                if source.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundColor(.black.opacity(0.75))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 21, height: 10.5)
            RoundedRectangle(cornerRadius: 0.8)
                .fill(Palette.primary.opacity(0.55))
                .frame(width: 1.8, height: 4)
        }
    }
}

/// Rune Bluetooth (pas de symbole SF).
struct BluetoothGlyph: View {
    var body: some View {
        Canvas { context, size in
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }
            var path = Path()
            path.move(to: point(0.08, 0.28))
            path.addLine(to: point(0.92, 0.72))
            path.addLine(to: point(0.5, 1))
            path.addLine(to: point(0.5, 0))
            path.addLine(to: point(0.92, 0.28))
            path.addLine(to: point(0.08, 0.72))
            context.stroke(path, with: .foreground,
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Plein écran compact

/// Batterie et caféine sur une ligne. Un clic sur la caféine l'active ou l'arrête.
struct QuickSettingsCompactView: View {
    @ObservedObject var module: QuickSettingsModule

    var body: some View {
        ModuleSummaryRow {
            if let mac = module.mac {
                BatteryGlyph(source: mac).frame(width: 20)
                Text(verbatim: QuickSettingsFormat.percent(mac.percent))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(Palette.primary)
            } else {
                ModuleSummaryIcon(symbol: "powerplug.fill", tint: Palette.secondary)
                Text("Secteur", tableName: "QuickSettings")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Palette.primary)
            }
            Spacer(minLength: 4)
            caffeineButton
        }
    }

    private var caffeineButton: some View {
        let active = module.caffeine != nil
        let text = module.caffeine.map {
            QuickSettingsFormat.earsDuration(minutes: QuickSettingsFormat.remainingMinutes(of: $0, now: module.now))
        }
        return Button {
            module.toggleCaffeine()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                if let text {
                    Text(verbatim: text)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundColor(active ? Palette.accent.onFill : Palette.primary.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(active ? Palette.accent : Color.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help(L("Caféine : empêche la mise en veille du Mac.", table: "QuickSettings"))
        .accessibilityLabel(Text("Caféine", tableName: "QuickSettings"))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Réglages

/// Réglages › Réglages rapides : raccourcis de la Concentration, caféine, économie d'énergie, scènes, passage
/// automatique.
struct QuickSettingsSettingsView: View {
    @ObservedObject var module: QuickSettingsModule
    @ObservedObject var prefs: QuickSettingsPrefs

    /// Ce que fait la règle, dite avant de la demander (aussi en info-bulle dans l'onglet).
    static var authorizationNote: String {
        L("Ajoute une règle système limitée à l'activation et la désactivation de l'économie d'énergie.",
          table: "QuickSettings")
    }

    var body: some View {
        SettingsPane {
            Section {
                TextField(L("Raccourci « activer »", table: "QuickSettings"), text: $prefs.focusOnShortcut)
                TextField(L("Raccourci « désactiver »", table: "QuickSettings"), text: $prefs.focusOffShortcut)
                HStack(spacing: 14) {
                    Button { module.openURL(SystemPane.newShortcut) } label: {
                        Text("Créer un raccourci…", tableName: "QuickSettings")
                    }
                    Link(destination: SystemPane.shortcutsHelp) {
                        Text("Aide sur Raccourcis", tableName: "QuickSettings")
                    }
                }
                DisclosureGroup {
                    SettingsNote(L("1. Dans Raccourcis, crée un nouveau raccourci.\n"
                        + "2. Ajoute l'action « Définir la concentration » : choisis la concentration (par exemple "
                        + "Ne pas déranger) et « Activer ».\n"
                        + "3. Donne-lui un nom, puis écris ce nom ci-dessus.\n"
                        + "4. Fais pareil avec « Désactiver » pour le second raccourci.", table: "QuickSettings"))
                } label: {
                    Text("Comment créer le raccourci « Définir la concentration »", tableName: "QuickSettings")
                }
            } header: {
                Text("Concentration", tableName: "QuickSettings")
            } footer: {
                SettingsNote(L("Un raccourci l'active ou la coupe ; l'état affiché est celui de ton dernier clic.",
                               table: "QuickSettings"))
            }

            Section {
                Picker(selection: $prefs.caffeineDuration) {
                    ForEach(CaffeineDuration.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Durée proposée", tableName: "QuickSettings")
                }
                Toggle(isOn: $prefs.caffeineKeepsDisplayOn) {
                    Text("Garder aussi l'écran allumé", tableName: "QuickSettings")
                }
            } header: {
                Text("Caféine", tableName: "QuickSettings")
            } footer: {
                SettingsNote(L("La caféine est visible dans les oreilles de la notch tant qu'elle est active.",
                               table: "QuickSettings"))
            }

            if module.lowPowerSupported { lowPowerSection }

            if module.fans.status?.supportsManual == true || module.fans.authorization != .notInstalled {
                FanSettingsSection(fans: module.fans)
            }

            Section {
                Toggle(isOn: $prefs.autonomyBluetoothOff) {
                    Text("Autonomie : couper aussi le Bluetooth", tableName: "QuickSettings")
                }
                Toggle(isOn: $prefs.presentationFocus) {
                    Text("Présentation : activer la Concentration", tableName: "QuickSettings")
                }
            } header: {
                Text("Scènes", tableName: "QuickSettings")
            } footer: {
                SettingsNote(QuickSettingsView.asksPassword(module.authorization)
                    ? L("Normal rétablit l'état d'avant les scènes ; l'économie d'énergie demande Touch ID.",
                        table: "QuickSettings")
                    : L("Normal rétablit l'état d'avant les scènes.", table: "QuickSettings"))
            }

            Section {
                Toggle(isOn: $prefs.autoAutonomy) {
                    Text("Passer en Autonomie quand la batterie baisse", tableName: "QuickSettings")
                }
                Stepper(value: $prefs.autoThreshold, in: QuickSettingsPrefs.thresholdRange, step: 5) {
                    Text(String(format: L("Seuil : %d %%", table: "QuickSettings"), prefs.autoThreshold))
                }
                .disabled(!prefs.autoAutonomy)
            } header: {
                Text("Passage automatique", tableName: "QuickSettings")
            } footer: {
                SettingsNote(L("Une seule fois par descente, sur batterie. Désactivé par défaut.", table: "QuickSettings"))
            }
        }
        .onAppear {
            module.refreshAuthorization()
            module.fans.refreshAuthorization()
            module.fans.read()
        }
    }

    // MARK: Économie d'énergie

    /// Mot de passe à chaque fois, ou règle sudoers posée une fois. Une règle que sudo refuse (autre utilisateur…)
    /// se redonne ou se retire.
    private var lowPowerSection: some View {
        Section {
            Text(verbatim: Self.authorizationState(module.authorization))
            HStack(spacing: 10) {
                if module.busy.contains(.authorization) {
                    ProgressView().controlSize(.small)
                } else {
                    ForEach(Self.authorizationActions(module.authorization), id: \.self) { action in
                        Button(action: { run(action) }) { Text(verbatim: action.title) }
                    }
                }
                Spacer(minLength: 0)
            }
        } header: {
            Text("Économie d'énergie", tableName: "QuickSettings")
        } footer: {
            SettingsNote(Self.authorizationNote)
        }
    }

    private func run(_ action: AuthorizationAction) {
        switch action {
        case .grant, .regrant: module.grantLowPowerAuthorization()
        case .revoke: module.revokeLowPowerAuthorization()
        }
    }

    enum AuthorizationAction: Hashable {
        case grant, regrant, revoke

        var title: String {
            switch self {
            case .grant: return L("Ne plus demander le mot de passe", table: "QuickSettings")
            case .regrant: return L("Redonner l'autorisation", table: "QuickSettings")
            case .revoke: return L("Retirer l'autorisation", table: "QuickSettings")
            }
        }
    }

    /// Les boutons de la section : poser la règle, la redonner si sudo la refuse, la retirer.
    static func authorizationActions(_ state: LowPowerAuthorizationState) -> [AuthorizationAction] {
        switch state {
        case .none, .onFirstUse: return [.grant]
        case .granted: return [.revoke]
        case .refused: return [.regrant, .revoke]
        }
    }

    static func authorizationState(_ state: LowPowerAuthorizationState) -> String {
        switch state {
        case .onFirstUse: return L("Mot de passe demandé une seule fois, au premier changement", table: "QuickSettings")
        case .none: return L("Mot de passe demandé à chaque fois", table: "QuickSettings")
        case .granted: return L("Autorisé sans mot de passe", table: "QuickSettings")
        case .refused: return L("L'autorisation ne marche plus (mot de passe demandé)", table: "QuickSettings")
        }
    }
}
