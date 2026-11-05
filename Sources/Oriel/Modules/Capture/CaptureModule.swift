import AppKit
import SwiftUI

/// Onglet « Micro et caméra » (désactivé par défaut) : un intercalaire orange quand un micro tourne, vert pour une caméra,
/// comme les points du système. Textes dans Resources/{en,fr}.lproj/Capture.strings ; réglage « capture.ears ».
///
/// - Oriel n'ouvre jamais le micro ni la caméra et ne demande aucune autorisation : il lit seulement « en marche
///   quelque part » (`CaptureSource`). Rien n'est enregistré, rien ne va sur disque.
/// - Arrêté, aucun écouteur n'est posé. Allumé, seulement des événements : pas de timer, sauf un délai unique de
///   0,8 s avant un premier affichage (`CaptureRules.showDelay`), pour qu'un accès bref ne fasse pas clignoter la notch.
final class CaptureModule: NotchModule {
    let id = "capture"
    let symbol = "mic.fill"
    var title: String { L("Micro et caméra", table: "Capture") }
    var isEnabledByDefault: Bool { false }

    /// Au-dessus de l'agenda (2), sous le minuteur (5) et Claude / Codex.
    static let earsPriority = 4
    static let microphoneHex = "FF9F0A"
    static let cameraHex = "30D158"

    /// Intercalaire de la notch repliée. Éteint, le module ne tourne que panneau ouvert.
    @Published var showEars: Bool {
        didSet { defaults.set(showEars, forKey: Key.ears) }
    }

    /// Appareils en marche, délai d'affichage passé.
    @Published private(set) var state = CaptureState()

    private enum Key { static let ears = "capture.ears" }

    private let defaults: UserDefaults
    private let source: CaptureSource
    private let scheduler: ModuleScheduler
    private let opener: (URL) -> Void
    private var isRunning = false
    private var latest = CaptureState()
    private var cancelShow: (() -> Void)?

    init(defaults: UserDefaults = .standard, source: CaptureSource = SystemCaptureSource(),
         scheduler: ModuleScheduler = .system, opener: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.source = source
        self.scheduler = scheduler
        self.opener = opener
        showEars = defaults.object(forKey: Key.ears) as? Bool ?? true
    }

    // MARK: Contrat

    var keepsRunningWhenCollapsed: Bool { showEars }

    var ears: ModuleEars? {
        guard showEars, !state.isEmpty else { return nil }
        let camera = !state.cameras.isEmpty, microphone = !state.microphones.isEmpty
        let text = camera && microphone ? L("Micro + cam", table: "Capture")
            : camera ? L("Caméra", table: "Capture") : L("Micro", table: "Capture")
        return ModuleEars(symbol: camera ? "video.fill" : "mic.fill", text: text, priority: Self.earsPriority,
                          accentHex: microphone ? Self.microphoneHex : Self.cameraHex)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        source.start { [weak self] devices in self?.apply(devices) }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        source.stop()
        cancelShow?()
        cancelShow = nil
        latest = CaptureState()
        state = CaptureState()
    }

    func makeView() -> AnyView { AnyView(CapturePanel(module: self)) }
    func makeTabDetailView() -> AnyView? { AnyView(CapturePanel(module: self)) }
    func makeSettingsView() -> AnyView? { AnyView(CaptureSettingsView(module: self)) }

    // MARK: Règles

    /// Un changement du système : l'intercalaire visible suit tout de suite, un premier allumage attend `showDelay`.
    func apply(_ devices: [CaptureDevice]) {
        guard isRunning else { return }
        latest = CaptureRules.state(devices)
        if !state.isEmpty || latest.isEmpty {
            cancelShow?()
            cancelShow = nil
            if latest != state { state = latest }
            return
        }
        guard cancelShow == nil else { return }
        cancelShow = scheduler.after(CaptureRules.showDelay) { [weak self] in
            guard let self, isRunning else { return }
            cancelShow = nil
            if latest != state { state = latest }
        }
    }

    func openPrivacy(camera: Bool) {
        let pane = camera ? "Privacy_Camera" : "Privacy_Microphone"
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)").map(opener)
    }
}

// MARK: - Vues

struct CapturePanel: View {
    @ObservedObject var module: CaptureModule

    var body: some View {
        VStack(spacing: 6) {
            row(symbol: "mic.fill", tint: Color(hex: CaptureModule.microphoneHex) ?? Palette.amber, label: L("Micro", table: "Capture"),
                devices: module.state.microphones, camera: false)
            row(symbol: "video.fill", tint: Color(hex: CaptureModule.cameraHex) ?? Palette.accent, label: L("Caméra", table: "Capture"),
                devices: module.state.cameras, camera: true)
            Text("Oriel lit seulement l'état des appareils. Il n'ouvre jamais le micro ni la caméra.", tableName: "Capture")
                .font(.system(size: 10.5))
                .foregroundColor(Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    private func row(symbol: String, tint: Color, label: String, devices: [CaptureDevice], camera: Bool) -> some View {
        Button { module.openPrivacy(camera: camera) } label: {
            ModuleSummaryRow {
                ModuleSummaryIcon(symbol: symbol, tint: devices.isEmpty ? Palette.secondary : tint)
                Text(verbatim: label).font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.primary)
                Spacer(minLength: 4)
                Text(verbatim: devices.isEmpty ? L("Inactif", table: "Capture") : devices.map { $0.name }.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundColor(devices.isEmpty ? Palette.secondary : tint)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct CaptureSettingsView: View {
    @ObservedObject var module: CaptureModule

    var body: some View {
        SettingsPane {
            Section {
                Toggle(isOn: $module.showEars) { Text("Intercalaire quand le micro ou la caméra tourne", tableName: "Capture") }
            } header: {
                Text("Notch repliée", tableName: "Capture")
            } footer: {
                SettingsNote(L("Orange pour un micro, vert pour une caméra. Oriel ne demande aucune autorisation et n'ouvre jamais le micro ni la caméra : il lit seulement l'état « en marche » des appareils, sans dire quelle app s'en sert. Les casques et interfaces audio qui jouent aussi du son ne sont pas détectés.",
                               table: "Capture"))
            }
        }
    }
}
