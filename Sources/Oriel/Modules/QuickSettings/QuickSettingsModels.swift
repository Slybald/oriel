import Foundation

// Types du module « Réglages rapides » : tuiles, scènes, batteries, erreurs, réglages du module.
// Rien ici ne touche au système : tout est testable sans matériel.

/// Une tuile de la grille (sert aussi de clé « en cours » pour le retour visuel).
enum QuickTile: Hashable {
    case wifi, bluetooth, focus, lowPower, caffeine, scene
    /// Pose ou retrait de l'autorisation sans mot de passe.
    case authorization
}

/// Durée de la caféine.
enum CaffeineDuration: String, CaseIterable, Identifiable {
    case oneHour, twoHours, indefinite

    var id: String { rawValue }

    /// nil = sans limite.
    var seconds: TimeInterval? {
        switch self {
        case .oneHour: return 3600
        case .twoHours: return 7200
        case .indefinite: return nil
        }
    }

    var label: String {
        switch self {
        case .oneHour: return L("1 h", table: "QuickSettings")
        case .twoHours: return L("2 h", table: "QuickSettings")
        case .indefinite: return "∞"
        }
    }
}

/// Les trois scènes. « Normal » restaure l'instantané pris avant les scènes (repris si les réglages ont changé
/// à la main depuis la dernière).
enum QuickScene: String, Codable, CaseIterable, Identifiable {
    case autonomy, normal, presentation

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .autonomy: return "leaf.fill"
        case .normal: return "arrow.uturn.backward"
        case .presentation: return "play.rectangle.fill"
        }
    }

    var title: String {
        switch self {
        case .autonomy: return L("Autonomie", table: "QuickSettings")
        case .normal: return L("Normal", table: "QuickSettings")
        case .presentation: return L("Présentation", table: "QuickSettings")
        }
    }
}

/// État du Mac avant les scènes, pour que « Normal » le restaure. Rangé dans UserDefaults : il survit à
/// un redémarrage de l'app (mise à jour automatique comprise).
struct SceneSnapshot: Codable, Equatable {
    /// Dernière scène appliquée (le reste de l'instantané ne bouge pas quand on passe d'une scène à l'autre).
    var scene: QuickScene
    var lowPower: Bool
    var bluetooth: Bool?
    var caffeine: Bool
    /// Fin de la caféine si elle tournait (nil + `caffeine` = sans limite).
    var caffeineEnd: Date?
    var focus: Bool
}

/// Ce qu'une scène demande ; nil = ne pas toucher.
struct SceneTargets: Equatable {
    enum Caffeine: Equatable {
        case off
        /// `until` nil = sans limite.
        case on(until: Date?)
    }

    var lowPower: Bool?
    var bluetooth: Bool?
    var caffeine: Caffeine?
    var focus: Bool?
}

/// Caféine en cours.
struct CaffeineSession: Equatable {
    var start: Date
    /// nil = sans limite.
    var end: Date?
}

// MARK: - Erreurs

/// Échec d'une action système, avant mise en forme pour l'utilisateur.
struct QuickSettingsFailure: Error, Equatable {
    enum Kind: Equatable {
        /// L'utilisateur a fermé la fenêtre d'autorisation : pas une erreur à afficher.
        case cancelled
        /// Droits refusés par le système.
        case denied
        case timeout
        case failed
        /// L'écriture a réussi mais l'état relu n'a pas changé.
        case unchanged
        /// Le nom d'utilisateur ne peut pas être écrit sans risque dans la règle sudoers : rien n'est installé.
        case invalidUser
    }

    var kind: Kind
    var detail: String?

    init(_ kind: Kind, _ detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

/// Message affiché sous la grille, avec une action facultative (ouvrir Réglages Système, Raccourcis…).
struct QuickSettingsIssue: Equatable {
    var message: String
    var actionTitle: String?
    var actionURL: URL?
}

/// Volets de Réglages Système proposés dans les messages d'erreur.
enum SystemPane {
    static let wifi = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!
    static let bluetooth = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!
    static let battery = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
    static let bluetoothPrivacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
    static let shortcuts = URL(string: "shortcuts://")!
    /// Ouvre l'app Raccourcis sur un nouveau raccourci.
    static let newShortcut = URL(string: "shortcuts://create-shortcut")!
    static let shortcutsHelp = URL(string: "https://support.apple.com/guide/shortcuts-mac/")!
}

// MARK: - Batterie

/// Une source d'énergie : la batterie du Mac, ou un accessoire (AirPods, boîtier).
struct PowerSourceInfo: Equatable, Identifiable {
    enum Kind: Equatable {
        case mac, accessory, chargingCase
    }

    var name: String
    var kind: Kind
    var percent: Int
    var isCharging: Bool
    /// Mac : branché sur le secteur.
    var isPluggedIn: Bool = false
    /// Minutes avant la décharge complète (sur batterie) ou la charge complète (en charge) ; nil = inconnu.
    var minutes: Int?

    var id: String { kind == .mac ? "mac" : name }

    /// Icône de la ligne : boîtier, casque (AirPods, Beats), sinon un accessoire sans fil quelconque (clavier,
    /// souris…).
    var symbol: String {
        if kind == .chargingCase { return "airpods.chargingcase" }
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.contains("airpods") || folded.contains("beats") ? "headphones" : "dot.radiowaves.left.and.right"
    }

    /// Mots qui désignent un boîtier de charge dans le nom d'un accessoire (comparés sans accents ni casse).
    private static let caseWords = ["case", "etui", "boitier", "estuche", "custodia", "caixa", "hulle"]

    static func kind(ofAccessory name: String) -> Kind {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return caseWords.contains { folded.contains($0) } ? .chargingCase : .accessory
    }

    /// Source lue par IOPS (clés de `IOPSGetPowerSourceDescription`). nil : source absente ou sans intérêt.
    init?(iops description: [String: Any]) {
        if let present = description["Is Present"] as? Bool, !present { return nil }
        let type = description["Type"] as? String
        guard type != "UPS" else { return nil }
        let name = description["Name"] as? String ?? ""
        let current = (description["Current Capacity"] as? NSNumber)?.doubleValue ?? 0
        let maximum = (description["Max Capacity"] as? NSNumber)?.doubleValue ?? 100
        guard maximum > 0, current >= 0 else { return nil }
        let isMac = type == "InternalBattery"
        let charging = description["Is Charging"] as? Bool ?? false
        let plugged = (description["Power Source State"] as? String) == "AC Power"
        func minutes(_ key: String) -> Int? {
            let value = (description[key] as? NSNumber)?.intValue ?? -1
            return value > 0 ? value : nil
        }
        self.init(name: name, kind: isMac ? .mac : Self.kind(ofAccessory: name),
                  percent: min(100, Int((current / maximum * 100).rounded())), isCharging: charging,
                  isPluggedIn: isMac && plugged,
                  minutes: isMac ? minutes(charging ? "Time to Full Charge" : "Time to Empty") : nil)
    }

    init(name: String, kind: Kind, percent: Int, isCharging: Bool, isPluggedIn: Bool = false, minutes: Int? = nil) {
        self.name = name
        self.kind = kind
        self.percent = percent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.minutes = minutes
    }
}

/// Lecture de `pmset -g accps` (repli et accessoires que IOPS ne liste pas).
///
///     Now drawing from 'Battery Power'
///      -InternalBattery-0 (id=1)\t49%; discharging; 3:47 remaining present: true
///      -AirPods Pro de Zoé (id=2)\t36%; charging; 0:00 remaining present: true
///
/// pmset écrit les noms en MacRoman quand ils ne sont pas de l'UTF-8 valide (« Boîtier » = 0x94) : on essaie
/// l'UTF-8, puis MacRoman.
enum PmsetBatteryParser {
    static func parse(_ data: Data) -> [PowerSourceInfo] {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .macOSRoman) ?? ""
        let pluggedIn = text.contains("'AC Power'")
        var result: [PowerSourceInfo] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-"), let idRange = line.range(of: " (id="),
                  let tab = line.firstIndex(of: "\t") else { continue }
            let name = String(line[line.index(after: line.startIndex)..<idRange.lowerBound])
            let fields = line[line.index(after: tab)...].components(separatedBy: ";")
            guard let first = fields.first, first.hasSuffix("%"), let percent = Int(first.dropLast()) else { continue }
            let state = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces).lowercased() : ""
            let charging = state == "charging" || state == "finishing charge"
            let isMac = name.hasPrefix("InternalBattery")
            result.append(PowerSourceInfo(
                name: name, kind: isMac ? .mac : PowerSourceInfo.kind(ofAccessory: name),
                percent: min(100, max(0, percent)), isCharging: charging, isPluggedIn: isMac && pluggedIn,
                minutes: isMac ? remainingMinutes(in: fields.dropFirst(2).joined(separator: ";")) : nil))
        }
        return result
    }

    /// « 3:47 remaining » → 227 ; « 0:00 remaining » et « (no estimate) » → nil.
    private static func remainingMinutes(in text: String) -> Int? {
        guard let range = text.range(of: #"\d+:\d{2} remaining"#, options: .regularExpression) else { return nil }
        let parts = text[range].split(separator: " ")[0].split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        let total = hours * 60 + minutes
        return total > 0 ? total : nil
    }
}

// MARK: - Réglages du module

/// Réglages du module, rangés dans UserDefaults sous `quicksettings.<nom>`.
final class QuickSettingsPrefs: ObservableObject {
    static let thresholdRange = 5...50

    private enum Key {
        static let focusOn = "quicksettings.focus.onShortcut"
        static let focusOff = "quicksettings.focus.offShortcut"
        static let focusState = "quicksettings.focus.state"
        static let duration = "quicksettings.caffeine.duration"
        static let keepsDisplayOn = "quicksettings.caffeine.keepsDisplayOn"
        static let autonomyBluetoothOff = "quicksettings.scene.autonomyBluetoothOff"
        static let presentationFocus = "quicksettings.scene.presentationFocus"
        static let autoAutonomy = "quicksettings.auto.enabled"
        static let autoThreshold = "quicksettings.auto.threshold"
        static let snapshot = "quicksettings.scene.snapshot"
    }

    private let defaults: UserDefaults

    /// Nom du raccourci (app Raccourcis) qui active la Concentration.
    @Published var focusOnShortcut: String {
        didSet { defaults.set(focusOnShortcut, forKey: Key.focusOn) }
    }

    @Published var focusOffShortcut: String {
        didSet { defaults.set(focusOffShortcut, forKey: Key.focusOff) }
    }

    /// Durée proposée par défaut au clic sur la tuile Caféine.
    @Published var caffeineDuration: CaffeineDuration {
        didSet { defaults.set(caffeineDuration.rawValue, forKey: Key.duration) }
    }

    /// Caféine : garder aussi l'écran allumé (sinon seulement le Mac éveillé).
    @Published var caffeineKeepsDisplayOn: Bool {
        didSet { defaults.set(caffeineKeepsDisplayOn, forKey: Key.keepsDisplayOn) }
    }

    /// Scène Autonomie : couper aussi le Bluetooth.
    @Published var autonomyBluetoothOff: Bool {
        didSet { defaults.set(autonomyBluetoothOff, forKey: Key.autonomyBluetoothOff) }
    }

    /// Scène Présentation : activer la Concentration (raccourci).
    @Published var presentationFocus: Bool {
        didSet { defaults.set(presentationFocus, forKey: Key.presentationFocus) }
    }

    /// Passer en Autonomie sous un seuil de batterie. Désactivé par défaut.
    @Published var autoAutonomy: Bool {
        didSet { defaults.set(autoAutonomy, forKey: Key.autoAutonomy) }
    }

    /// Seuil en pourcentage, borné à `thresholdRange`.
    @Published var autoThreshold: Int {
        didSet { defaults.set(autoThreshold, forKey: Key.autoThreshold) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        focusOnShortcut = defaults.string(forKey: Key.focusOn) ?? ""
        focusOffShortcut = defaults.string(forKey: Key.focusOff) ?? ""
        caffeineDuration = defaults.string(forKey: Key.duration).flatMap(CaffeineDuration.init) ?? .oneHour
        caffeineKeepsDisplayOn = defaults.object(forKey: Key.keepsDisplayOn) as? Bool ?? true
        autonomyBluetoothOff = defaults.bool(forKey: Key.autonomyBluetoothOff)
        presentationFocus = defaults.bool(forKey: Key.presentationFocus)
        autoAutonomy = defaults.bool(forKey: Key.autoAutonomy)
        let threshold = defaults.object(forKey: Key.autoThreshold) as? Int ?? 20
        autoThreshold = min(max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
    }

    /// Nom de raccourci utilisable : sans espaces autour, non vide, sans tiret initial (ce serait une option).
    static func usable(_ shortcut: String) -> String? {
        let name = shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.hasPrefix("-") ? nil : name
    }

    func shortcut(turningOn: Bool) -> String? {
        Self.usable(turningOn ? focusOnShortcut : focusOffShortcut)
    }

    // MARK: États gardés entre deux lancements

    /// Dernier état de la Concentration demandé par l'app (macOS ne permet pas de le lire).
    var focusState: Bool {
        get { defaults.bool(forKey: Key.focusState) }
        set { defaults.set(newValue, forKey: Key.focusState) }
    }

    var snapshot: SceneSnapshot? {
        get { defaults.data(forKey: Key.snapshot).flatMap { try? JSONDecoder().decode(SceneSnapshot.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.snapshot)
            } else {
                defaults.removeObject(forKey: Key.snapshot)
            }
        }
    }
}

// MARK: - Mise en forme

enum QuickSettingsFormat {
    /// « 78 % ».
    static func percent(_ value: Int) -> String {
        String(format: L("%d %%", table: "QuickSettings"), value)
    }

    /// « 3 h 47 » ou « 45 min » (durée de batterie, détail de la caféine).
    static func duration(minutes: Int) -> String {
        if minutes >= 60 {
            return String(format: L("%d h %02d", table: "QuickSettings"), minutes / 60, minutes % 60)
        }
        return String(format: L("%d min", table: "QuickSettings"), max(minutes, 1))
    }

    /// Forme très courte des oreilles : « 1h12 », « 45m », « ∞ ».
    static func earsDuration(minutes: Int?) -> String {
        guard let minutes else { return "∞" }
        if minutes >= 60 {
            return String(format: L("%dh%02d", table: "QuickSettings"), minutes / 60, minutes % 60)
        }
        return String(format: L("%dm", table: "QuickSettings"), max(minutes, 1))
    }

    /// Oreilles de la vitesse fixe : « 4,2k » (milliers de tours par minute).
    static func earsRPM(_ rpm: Int) -> String {
        String(format: L("%.1fk", table: "QuickSettings"), Double(rpm) / 1000)
    }

    /// « 2317 · 2320 tr/min ».
    static func rpm(_ fans: [Double]) -> String {
        String(format: L("%@ tr/min", table: "QuickSettings"), fans.map { String(Int($0.rounded())) }.joined(separator: " · "))
    }

    /// « 62 °C ».
    static func celsius(_ value: Double) -> String {
        String(format: L("%d °C", table: "QuickSettings"), Int(value.rounded()))
    }

    /// Minutes restantes arrondies au-dessus (jamais « 0 » tant que la caféine tourne) ; nil = sans limite.
    static func remainingMinutes(of session: CaffeineSession, now: Date) -> Int? {
        guard let end = session.end else { return nil }
        return max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
    }
}
