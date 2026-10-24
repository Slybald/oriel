import AppKit
import SwiftUI

// MARK: - Onglet

/// Carte du minuteur : mode et sessions en haut, puis l'anneau et les commandes de l'état courant.
struct TimerPanel: View {
    @ObservedObject var module: TimerModule

    static let presets = [1, 5, 10, 15, 25, 45]

    private var state: TimerState { module.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 18) {
                TimerDial(module: module)
                controls
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ModuleStyle.shape(ModuleStyle.cardRadius).fill(Palette.card))
        .animation(notchSpring, value: state.status)
        .animation(notchSpring, value: state.mode)
    }

    // MARK: En-tête

    private var header: some View {
        HStack(spacing: 8) {
            if state.isActive {
                TimerLabel(symbol: module.phaseSymbol, text: module.label)
            } else {
                modePicker
            }
            Spacer(minLength: 0)
            if state.mode == .pomodoro {
                SessionDots(module: module)
            }
        }
        .frame(height: 22)
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            modeButton(.simple, L("Minuteur", table: "Timer"), "timer")
            modeButton(.pomodoro, L("Pomodoro", table: "Timer"), "brain.head.profile")
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private func modeButton(_ mode: TimerMode, _ title: String, _ symbol: String) -> some View {
        let selected = state.mode == mode
        return Button {
            module.setMode(mode)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(selected ? Palette.primary : Palette.secondary)
            .padding(.horizontal, 9)
            .frame(height: 18)
            .background(Capsule().fill(selected ? Color.white.opacity(0.14) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Commandes

    @ViewBuilder
    private var controls: some View {
        switch state.status {
        case .idle: idleControls
        case .running, .paused: runningControls
        case .finished: finishedControls
        }
    }

    @ViewBuilder
    private var idleControls: some View {
        if state.mode == .simple {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    ForEach(Self.presets, id: \.self) { minutes in
                        TimerChip(minutes: minutes, selected: Int(state.simpleDuration) == minutes * 60) {
                            module.startSimple(minutes: minutes)
                        }
                    }
                    Text("min", tableName: "Timer")
                        .font(.system(size: 10.5))
                        .foregroundColor(Palette.secondary)
                }
                HStack(spacing: 10) {
                    DurationControl(module: module)
                    Spacer(minLength: 0)
                    TimerPill(title: L("Démarrer", table: "Timer"), symbol: "play.fill", prominent: true,
                              action: module.startTimer)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(format: L("%@ de concentration, pause de %@", table: "Timer"),
                            TimerFormat.duration(module.config.focus), TimerFormat.duration(module.config.shortBreak)))
                    .font(.system(size: 11.5))
                    .foregroundColor(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TimerPill(title: L("Démarrer", table: "Timer"), symbol: "play.fill", prominent: true,
                              action: module.startTimer)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var runningControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TimerRoundButton(symbol: state.status == .running ? "pause.fill" : "play.fill",
                                 label: state.status == .running ? L("Pause", table: "Timer")
                                     : L("Reprendre", table: "Timer"),
                                 size: 34, prominent: true, action: module.togglePause)
                TimerPill(title: L("+1 min", table: "Timer"), symbol: nil, prominent: false, action: module.addMinute)
                TimerRoundButton(symbol: "stop.fill", label: L("Arrêter", table: "Timer"), action: module.stopTimer)
                if state.mode == .pomodoro {
                    TimerRoundButton(symbol: "forward.end.fill", label: L("Passer à la phase suivante", table: "Timer"),
                                     action: module.skip)
                }
            }
            if state.status == .running, let end = state.endDate {
                Text(String(format: L("Fin à %@", table: "Timer"), TimerFormat.time(end)))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
            }
        }
    }

    private var finishedControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: L("Terminé à %@", table: "Timer"), TimerFormat.time(state.finishedAt ?? module.now)))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Palette.primary)
            if state.mode == .pomodoro {
                Text(String(format: L("Ensuite : %@, %@", table: "Timer"), module.phaseName(state.phase),
                            TimerFormat.duration(state.remaining)))
                    .font(.system(size: 11.5))
                    .foregroundColor(Palette.secondary)
            }
            HStack(spacing: 8) {
                TimerPill(title: module.restartTitle, symbol: "play.fill", prominent: true, action: module.startTimer)
                TimerPill(title: L("OK", table: "Timer"), symbol: nil, prominent: false, action: module.stopTimer)
            }
        }
    }
}

// MARK: - Anneau

/// Anneau de progression et grand chiffre.
struct TimerDial: View {
    @ObservedObject var module: TimerModule

    static let size: CGFloat = 108

    private var state: TimerState { module.state }

    private var tint: Color {
        switch state.status {
        case .paused: return Palette.amber
        case .finished: return Palette.green
        case .idle, .running: return state.mode == .pomodoro && state.phase.isBreak ? Palette.green : Palette.accent
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 5)
            Circle()
                .trim(from: 0, to: module.progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                if state.status == .finished {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(Palette.green)
                } else {
                    Text(TimerFormat.clock(module.displayedSeconds))
                        .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(state.status == .paused ? Palette.secondary : Palette.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                if !module.caption.isEmpty {
                    Text(module.caption)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(width: Self.size, height: Self.size)
        .padding(3)
    }
}

/// Symbole et libellé de la phase en cours.
struct TimerLabel: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Palette.accent)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.primary)
                .lineLimit(1)
        }
    }
}

/// Points de la série en cours (pause longue après le dernier) et sessions du jour.
struct SessionDots: View {
    @ObservedObject var module: TimerModule

    var body: some View {
        let state = module.state
        let total = module.sessionsBeforeLongBreak
        let today = state.sessions(on: module.now, calendar: module.calendar)
        let current = state.isActive && state.phase == .focus ? state.cycle : -1
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<total, id: \.self) { index in
                    Circle()
                        .fill(index < state.cycle ? Palette.accent : Color.white.opacity(0.16))
                        .overlay(Circle().stroke(Palette.accent, lineWidth: index == current ? 1.5 : 0))
                        .frame(width: 7, height: 7)
                }
            }
            if today > 0 {
                Text(String(format: L(today, one: "%d session aujourd'hui", other: "%d sessions aujourd'hui",
                                      table: "Timer"), today))
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.secondary)
            }
        }
    }
}

// MARK: - Éléments

/// Préréglage : un clic lance le minuteur.
struct TimerChip: View {
    let minutes: Int
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: "\(minutes)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(selected ? Palette.accent.onFill : Palette.primary.opacity(0.9))
                .frame(width: 34, height: 24)
                .background(Capsule().fill(selected ? Palette.accent.opacity(0.85)
                                           : Color.white.opacity(hovering ? 0.16 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: hovering)
        .help(String(format: L("Lancer %d min", table: "Timer"), minutes))
        .accessibilityLabel(String(format: L("Lancer %d min", table: "Timer"), minutes))
    }
}

struct TimerRoundButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 28
    var prominent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundColor(prominent ? Palette.accent.onFill : .white)
                .frame(width: size, height: size)
                .background(Circle().fill(prominent ? Palette.accent.opacity(hovering ? 1 : 0.85)
                                          : Color.white.opacity(hovering ? 0.18 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct TimerPill: View {
    let title: String
    let symbol: String?
    let prominent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundColor(prominent ? Palette.accent.onFill : .white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(prominent ? Palette.accent.opacity(hovering ? 1 : 0.85)
                                       : Color.white.opacity(hovering ? 0.18 : 0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: hovering)
    }
}

/// Durée libre : flèches, molette ou saisie (le clavier passe par `NotchKeyboard`, le panneau ne s'active jamais).
struct DurationControl: View {
    @ObservedObject var module: TimerModule

    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var hovering = false

    private var minutes: Int { Int((module.state.simpleDuration / 60).rounded()) }
    private static let range = 1...1440

    var body: some View {
        HStack(spacing: 2) {
            step("minus", -1, label: L("Diminuer la durée", table: "Timer"))
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(Palette.primary)
                .frame(width: 38)
                .accessibilityLabel(L("Durée libre : flèches, molette ou saisie", table: "Timer"))
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand {
                    draft = String(minutes)
                    focused = false
                    NotchKeyboard.release(force: true)
                }
            Text("min", tableName: "Timer")
                .font(.system(size: 11))
                .foregroundColor(Palette.secondary)
                .padding(.trailing, 4)
            step("plus", 1, label: L("Augmenter la durée", table: "Timer"))
        }
        .padding(.horizontal, 3)
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(hovering || focused ? 0.12 : 0.07)))
        .overlay(ScrollWheelCatcher { change in adjust(change) })
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: hovering)
        .onAppear { draft = String(minutes) }
        .onChange(of: minutes) { value in if !focused { draft = String(value) } }
        .onChange(of: draft) { value in
            let digits = String(value.filter(\.isNumber).prefix(4))
            guard digits == value else { draft = digits; return }
            // Retenu au fil de la frappe : « Démarrer » part avec ce que le champ affiche, sans Entrée.
            if let typed = Int(digits) {
                let clamped = min(max(typed, Self.range.lowerBound), Self.range.upperBound)
                if clamped != minutes { module.setSimpleMinutes(clamped) }
            }
        }
        .onChange(of: focused) { isFocused in
            if isFocused {
                NotchKeyboard.take()
            } else {
                commit()
                NotchKeyboard.release()
            }
        }
        .onDisappear { NotchKeyboard.release() }
        .help(L("Durée libre : flèches, molette ou saisie", table: "Timer"))
    }

    private func step(_ symbol: String, _ delta: Int, label: String) -> some View {
        Button {
            adjust(delta)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Palette.primary.opacity(0.85))
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func adjust(_ delta: Int) {
        let value = min(max(minutes + delta, Self.range.lowerBound), Self.range.upperBound)
        module.setSimpleMinutes(value)
        draft = String(value)
    }

    private func commit() {
        guard let value = Int(draft) else { draft = String(minutes); return }
        let clamped = min(max(value, Self.range.lowerBound), Self.range.upperBound)
        module.setSimpleMinutes(clamped)
        draft = String(clamped)
    }
}

/// Reçoit la molette au-dessus de son parent sans gêner les clics : `hitTest` ne répond que pendant un défilement.
struct ScrollWheelCatcher: NSViewRepresentable {
    let onChange: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.onChange = onChange }

    final class CatcherView: NSView {
        var onChange: (Int) -> Void = { _ in }
        private var accumulated: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }

        /// Un cran de molette = 1 min ; au pavé tactile, un pas tous les 8 points.
        override func scrollWheel(with event: NSEvent) {
            let unit: CGFloat = event.hasPreciseScrollingDeltas ? 8 : 1
            accumulated += event.scrollingDeltaY
            let steps = Int(accumulated / unit)
            guard steps != 0 else { return }
            accumulated -= CGFloat(steps) * unit
            onChange(steps)
        }
    }
}

// MARK: - Mode compact (plein écran)

/// Une ligne : phase, temps restant, pause ou reprise.
struct TimerCompactView: View {
    @ObservedObject var module: TimerModule

    var body: some View {
        let state = module.state
        ModuleSummaryRow {
            ModuleSummaryIcon(symbol: state.status == .finished ? "checkmark.circle.fill" : module.phaseSymbol,
                              tint: state.status == .finished ? Palette.green : Palette.accent)
            if state.status == .finished {
                Text(String(format: L("Terminé à %@", table: "Timer"), TimerFormat.time(state.finishedAt ?? module.now)))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Palette.primary)
                    .lineLimit(1)
            } else {
                Text(TimerFormat.clock(module.displayedSeconds))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(state.status == .paused ? Palette.secondary : Palette.primary)
                Text(module.label)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if state.isActive {
                TimerRoundButton(symbol: state.status == .running ? "pause.fill" : "play.fill",
                                 label: state.status == .running ? L("Pause", table: "Timer")
                                     : L("Reprendre", table: "Timer"),
                                 size: 22, action: module.togglePause)
            }
        }
        .onAppear { DispatchQueue.main.async { module.viewAppeared() } }
        .onDisappear { module.viewDisappeared() }
    }
}

/// Icône de l'onglet : la phase en cours. Elle n'est à l'écran que panneau déplié, ce qui sert de signal d'ouverture
/// (l'oreille « Terminé » a fait son office).
struct TimerTabIcon: View {
    @ObservedObject var module: TimerModule

    var body: some View {
        Image(systemName: module.state.isActive ? module.phaseSymbol : module.symbol)
            .font(.system(size: 12, weight: .semibold))
            .onAppear { DispatchQueue.main.async { module.viewAppeared() } }
            .onDisappear { module.viewDisappeared() }
    }
}

// MARK: - Textes et valeurs dérivées

extension TimerModule {
    /// Secondes affichées : arrondi au-dessus tant que ça court.
    var displayedSeconds: TimeInterval {
        state.status == .running ? state.remaining(at: now) : state.remaining
    }

    var progress: Double { state.progress(at: now) }

    func phaseName(_ phase: TimerPhase) -> String {
        switch phase {
        case .focus: return L("Concentration", table: "Timer")
        case .shortBreak: return L("Pause courte", table: "Timer")
        case .longBreak: return L("Pause longue", table: "Timer")
        }
    }

    /// « Concentration » ou « Minuteur · 10 min ».
    var label: String {
        state.mode == .pomodoro ? phaseName(state.phase)
            : String(format: L("Minuteur · %@", table: "Timer"), TimerFormat.duration(state.duration))
    }

    /// Sous le grand chiffre ; rien pendant le décompte, l'en-tête dit déjà la phase.
    var caption: String {
        switch state.status {
        case .paused: return L("En pause", table: "Timer")
        case .finished: return L("Terminé", table: "Timer")
        case .idle: return state.mode == .pomodoro ? phaseName(state.phase) : L("Prêt", table: "Timer")
        case .running: return ""
        }
    }

    /// Bouton principal de l'état « terminé ».
    var restartTitle: String {
        guard state.mode == .pomodoro else { return L("Recommencer", table: "Timer") }
        return state.phase.isBreak ? L("Démarrer la pause", table: "Timer") : L("Démarrer la concentration", table: "Timer")
    }
}

// MARK: - Réglages

/// Réglages › Minuteur : Pomodoro, son et notification de fin.
struct TimerSettingsView: View {
    @ObservedObject var module: TimerModule

    var body: some View {
        SettingsPane {
            Section {
                MinutesStepper(title: L("Concentration", table: "Timer"), value: $module.focusMinutes,
                               range: TimerModule.focusRange)
                MinutesStepper(title: L("Pause courte", table: "Timer"), value: $module.shortBreakMinutes,
                               range: TimerModule.shortBreakRange)
                MinutesStepper(title: L("Pause longue", table: "Timer"), value: $module.longBreakMinutes,
                               range: TimerModule.longBreakRange)
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(verbatim: "\(module.sessionsBeforeLongBreak)").monospacedDigit().foregroundColor(.secondary)
                        Stepper("", value: $module.sessionsBeforeLongBreak, in: TimerModule.sessionsRange)
                            .labelsHidden()
                    }
                } label: {
                    Text("Sessions avant la pause longue", tableName: "Timer")
                }
                Toggle(isOn: $module.autoStartBreaks) { Text("Lancer les pauses automatiquement", tableName: "Timer") }
            } header: {
                Text("Pomodoro", tableName: "Timer")
            } footer: {
                SettingsNote(L("Les pauses démarrent seules ; la concentration attend que tu la lances.", table: "Timer"))
            }
            Section {
                Picker(selection: $module.soundName) {
                    Text("Aucun", tableName: "Timer").tag("")
                    ForEach(TimerSound.names, id: \.self) { name in
                        Text(verbatim: name).tag(name)
                    }
                } label: {
                    Text("Son de fin", tableName: "Timer")
                }
                Button(action: module.previewSound) { Text("Écouter le son", tableName: "Timer") }
                    .disabled(module.soundName.isEmpty)
                Toggle(isOn: $module.notifyOnEnd) { Text("Notification à la fin", tableName: "Timer") }
                if module.notifyOnEnd, module.notificationAccess == .denied {
                    LabeledContent {
                        Button(action: Self.openNotificationSettings) {
                            Text("Ouvrir Réglages Système", tableName: "Timer")
                        }
                    } label: {
                        Text("Notifications refusées", tableName: "Timer").foregroundColor(Palette.amber)
                    }
                }
            } header: {
                Text("Fin du minuteur", tableName: "Timer")
            } footer: {
                SettingsNote(L("Notifications : l'autorisation est demandée au premier minuteur lancé.", table: "Timer"))
            }
        }
        .onAppear(perform: module.refreshNotificationAccess)
    }

    private static func openNotificationSettings() {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            .map { _ = NSWorkspace.shared.open($0) }
    }
}

/// Durée en minutes d'un réglage.
private struct MinutesStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(TimerFormat.duration(TimeInterval(value * 60))).monospacedDigit().foregroundColor(.secondary)
                Stepper("", value: $value, in: range).labelsHidden()
            }
        } label: {
            Text(title)
        }
    }
}
