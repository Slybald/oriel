import AppKit
import CoreWLAN
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

// Accès au système du module « Réglages rapides ». Chaque accès est derrière un protocole : le module ne parle
// qu'à ces protocoles, les tests y glissent des doubles (aucune bascule réelle). Les rappels (`completion`,
// `onChange`) arrivent toujours sur le fil principal.

protocol WiFiBackend: AnyObject {
    /// nil : pas d'interface Wi-Fi.
    func isPoweredOn() -> Bool?
    /// Associé à un réseau. Le nom du réseau demande l'autorisation de localisation : on ne le lit pas.
    func isAssociated() -> Bool
    func setPower(_ on: Bool, completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void)
    func startMonitoring(_ onChange: @escaping () -> Void)
    func stopMonitoring()
}

protocol BluetoothBackend: AnyObject {
    /// nil : API absente ou inutilisable.
    func isPoweredOn() -> Bool?
    /// false : l'appel n'a pas pu partir. Le changement lui-même est asynchrone.
    func setPower(_ on: Bool) -> Bool
}

protocol PowerModeBackend: AnyObject {
    /// Ce Mac a-t-il un mode économie d'énergie réglable ?
    func checkSupport(completion: @escaping (Bool) -> Void)
    var isLowPowerEnabled: Bool { get }
    /// Écriture avec droits administrateur : sans mot de passe si la règle sudoers est en place, sinon (ou si elle
    /// ne marche plus) Touch ID ou le mot de passe.
    func setLowPower(_ on: Bool, completion: @escaping (Result<LowPowerWrite, QuickSettingsFailure>) -> Void)
    var authorization: LowPowerAuthorizationState { get }
    /// Pose la règle sudoers (un mot de passe administrateur, une fois).
    func authorize(completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void)
    /// Retire la règle sudoers (un mot de passe administrateur).
    func revokeAuthorization(completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void)
    func startMonitoring(_ onChange: @escaping () -> Void)
    func stopMonitoring()
}

protocol BatteryBackend: AnyObject {
    /// IOPS : synchrone et léger.
    func readIOPS() -> [PowerSourceInfo]
    /// `pmset -g accps` analysé, hors du fil principal.
    func readPmset(completion: @escaping ([PowerSourceInfo]) -> Void)
    func startMonitoring(_ onChange: @escaping () -> Void)
    func stopMonitoring()
}

protocol CaffeineBackend: AnyObject {
    func acquire(keepDisplayOn: Bool) -> Bool
    func release()
}

protocol ShortcutBackend: AnyObject {
    func run(_ name: String, completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void)
}

struct QuickSettingsBackends {
    var wifi: WiFiBackend
    var bluetooth: BluetoothBackend
    var power: PowerModeBackend
    var battery: BatteryBackend
    var caffeine: CaffeineBackend
    var shortcuts: ShortcutBackend
    var fans: FanBackend

    /// Les vrais accès. Créer ces objets ne touche à rien : le système n'est appelé qu'à l'usage.
    static func system() -> QuickSettingsBackends {
        QuickSettingsBackends(wifi: SystemWiFi(), bluetooth: SystemBluetooth(), power: SystemPowerMode(),
                              battery: SystemBattery(), caffeine: SystemCaffeine(), shortcuts: SystemShortcuts(),
                              fans: SystemFans())
    }
}

// MARK: - Processus

/// Lance un programme et attend sa fin (à appeler hors du fil principal). Aucun shell : les arguments passent
/// tels quels.
enum SystemProcess {
    /// La forme de `run`, pour que les tests y glissent un double.
    typealias Runner = (_ path: String, _ arguments: [String], _ timeout: TimeInterval) -> Output?

    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool

        /// Première ligne non vide de stderr, pour un message court.
        var errorLine: String? {
            String(decoding: stderr, as: UTF8.self)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
        }
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timedOut = TimedOutFlag()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                timedOut.set()
                process.terminate()
            }
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut.value)
    }

    private final class TimedOutFlag {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}

// MARK: - Wi-Fi (CoreWLAN)

final class SystemWiFi: NSObject, WiFiBackend, CWEventDelegate {
    private var onChange: (() -> Void)?

    private var interface: CWInterface? { CWWiFiClient.shared().interface() }

    func isPoweredOn() -> Bool? { interface?.powerOn() }

    /// 0 dBm / 0 Mb/s : pas associé.
    func isAssociated() -> Bool {
        guard let interface else { return false }
        return interface.rssiValue() != 0 || interface.transmitRate() > 0
    }

    /// `setPower` peut demander un mot de passe administrateur : jamais sur le fil principal.
    func setPower(_ on: Bool, completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, QuickSettingsFailure>
            if let interface = self?.interface {
                do {
                    try interface.setPower(on)
                    result = .success(())
                } catch {
                    result = .failure(Self.failure(error))
                }
            } else {
                result = .failure(QuickSettingsFailure(.failed))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Refus d'autorisation : POSIX EPERM/EACCES, ou kCWOperationNotPermittedErr de CoreWLAN (« le processus n'a
    /// pas la permission »). Le message brut du système, en anglais, n'est gardé que pour les autres échecs.
    static func failure(_ error: Error) -> QuickSettingsFailure {
        let nsError = error as NSError
        let posixDenied = nsError.domain == NSPOSIXErrorDomain
            && (nsError.code == Int(EPERM) || nsError.code == Int(EACCES))
        let coreWLANDenied = nsError.domain == CWErrorDomain && nsError.code == Int(CWErr.cwOperationNotPermittedErr.rawValue)
        if posixDenied || coreWLANDenied { return QuickSettingsFailure(.denied) }
        return QuickSettingsFailure(.failed, nsError.localizedDescription)
    }

    func startMonitoring(_ onChange: @escaping () -> Void) {
        stopMonitoring()
        self.onChange = onChange
        let client = CWWiFiClient.shared()
        client.delegate = self
        try? client.startMonitoringEvent(with: .powerDidChange)
        try? client.startMonitoringEvent(with: .linkDidChange)
    }

    func stopMonitoring() {
        guard onChange != nil else { return }
        onChange = nil
        let client = CWWiFiClient.shared()
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
    }

    // CWEventDelegate : appelé sur une file du système.
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { notify() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { notify() }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    deinit { stopMonitoring() }
}

// MARK: - Bluetooth (API privée d'IOBluetooth, chargée à l'exécution)

final class SystemBluetooth: BluetoothBackend {
    private typealias GetState = @convention(c) () -> Int32
    private typealias SetState = @convention(c) (Int32) -> Void

    private lazy var functions: (get: GetState, set: SetState)? = {
        // Hors de l'app, IOBluetooth fait avorter le processus (signal 6, mesuré) : `swift run` n'a pas la clé de
        // l'Info.plist, et le xctest d'Xcode l'a mais l'appel avorte quand même. On ne l'appelle donc que depuis
        // l'app elle-même.
        guard Bundle.main.bundleIdentifier == AppIdentity.bundleId,
              Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil,
              let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY),
              let get = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState"),
              let set = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else { return nil }
        return (unsafeBitCast(get, to: GetState.self), unsafeBitCast(set, to: SetState.self))
    }()

    func isPoweredOn() -> Bool? { functions.map { $0.get() != 0 } }

    func setPower(_ on: Bool) -> Bool {
        guard let functions else { return false }
        functions.set(on ? 1 : 0)
        return true
    }
}

// MARK: - Économie d'énergie

final class SystemPowerMode: PowerModeBackend {
    private var observer: NSObjectProtocol?
    private let run: SystemProcess.Runner
    private let ruleExists: () -> Bool
    private let userName: () -> String
    private let defaults: UserDefaults
    /// sudo a refusé la règle pendant cette session : on ne l'essaie plus avant qu'elle soit reposée.
    private var ruleRefused = false

    /// Les paramètres servent aux tests : aucun processus, aucun fichier système réels.
    init(run: @escaping SystemProcess.Runner = { SystemProcess.run($0, $1, timeout: $2) },
         ruleExists: @escaping () -> Bool = { LowPowerAuthorization.isInstalled },
         userName: @escaping () -> String = NSUserName,
         defaults: UserDefaults = .standard) {
        self.run = run
        self.ruleExists = ruleExists
        self.userName = userName
        self.defaults = defaults
    }

    /// Poser la règle à la prochaine bascule (vrai tant que l'utilisateur ne l'a pas retirée).
    private var autoAuthorize: Bool {
        get { defaults.object(forKey: LowPowerAuthorization.autoAuthorizeKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: LowPowerAuthorization.autoAuthorizeKey) }
    }

    var isLowPowerEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    var authorization: LowPowerAuthorizationState {
        guard ruleExists() else { return autoAuthorize ? .onFirstUse : .none }
        return ruleRefused ? .refused : .granted
    }

    /// `pmset -g custom` liste `lowpowermode` seulement sur les Mac qui le gèrent.
    func checkSupport(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async { [run] in
            let output = run("/usr/bin/pmset", ["-g", "custom"], 5)
            let supported = output.map { String(decoding: $0.stdout, as: UTF8.self).contains("lowpowermode") } ?? false
            DispatchQueue.main.async { completion(supported) }
        }
    }

    /// `pmset` exige root. Avec la règle sudoers : `sudo -n`, sans fenêtre. Sinon, AppleScript affiche la fenêtre
    /// d'autorisation du système (Touch ID ou mot de passe), qui pose aussi la règle (sauf si l'utilisateur l'a
    /// retirée) : un mot de passe au premier clic, plus jamais ensuite. Les commandes sont des constantes, sans texte
    /// venu de l'extérieur (le nom d'utilisateur est validé par `ruleContents`).
    func setLowPower(_ on: Bool, completion: @escaping (Result<LowPowerWrite, QuickSettingsFailure>) -> Void) {
        let useRule = authorization == .granted
        let rule = autoAuthorize ? LowPowerAuthorization.ruleContents(forUser: userName()) : nil
        let shell = rule.map { LowPowerAuthorization.pmsetAndInstallShellCommand(lowPower: on, ruleContents: $0) }
            ?? LowPowerAuthorization.pmsetShellCommand(lowPower: on)
        let prompt = rule == nil
            ? L("Oriel veut changer l'économie d'énergie.", table: "QuickSettings")
            : L("Oriel veut changer l'économie d'énergie. Ton mot de passe ne sera plus demandé pour ce réglage.",
                table: "QuickSettings")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if useRule {
                let output = run(LowPowerAuthorization.sudoPath, LowPowerAuthorization.sudoArguments(lowPower: on), 15)
                if let output, output.status == 0 {
                    return DispatchQueue.main.async { completion(.success(.done)) }
                }
            }
            let result = runAsAdministrator(shell, prompt: prompt)
            DispatchQueue.main.async { [self] in
                guard case .success = result else { return completion(result.map { .done }) }
                // Règle (re)posée dans la même fenêtre : sudo sera réessayé à la prochaine bascule. Sans pose, une
                // règle que sudo a refusée est à redonner à la main.
                ruleRefused = rule == nil && useRule
                completion(.success(ruleRefused ? .authorizationRefused : .done))
            }
        }
    }

    func authorize(completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void) {
        guard let contents = LowPowerAuthorization.ruleContents(forUser: userName()) else {
            return completion(.failure(QuickSettingsFailure(.invalidUser)))
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = runAsAdministrator(LowPowerAuthorization.installShellCommand(ruleContents: contents))
            DispatchQueue.main.async { [self] in
                if case .success = result { ruleRefused = false; autoAuthorize = true }
                completion(result)
            }
        }
    }

    func revokeAuthorization(completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = runAsAdministrator(LowPowerAuthorization.removeShellCommand)
            DispatchQueue.main.async { [self] in
                if case .success = result { ruleRefused = false; autoAuthorize = false }
                completion(result)
            }
        }
    }

    /// La fenêtre d'autorisation du système, via AppleScript (hors du fil principal).
    private func runAsAdministrator(_ shell: String, prompt: String? = nil) -> Result<Void, QuickSettingsFailure> {
        let script = LowPowerAuthorization.administratorScript(running: shell, prompt: prompt)
        guard let output = run("/usr/bin/osascript", ["-e", script], 120) else {
            return .failure(QuickSettingsFailure(.failed))
        }
        return output.status == 0 ? .success(()) : .failure(Self.failure(output))
    }

    /// osascript : « execution error: User canceled. (-128) » quand on ferme la fenêtre d'autorisation.
    static func failure(_ output: SystemProcess.Output) -> QuickSettingsFailure {
        let line = output.errorLine
        if output.timedOut { return QuickSettingsFailure(.timeout) }
        if line?.contains("(-128)") == true { return QuickSettingsFailure(.cancelled) }
        if line?.contains("(-60005)") == true || line?.contains("(-60007)") == true {
            return QuickSettingsFailure(.denied, line)
        }
        return QuickSettingsFailure(.failed, line)
    }

    func startMonitoring(_ onChange: @escaping () -> Void) {
        stopMonitoring()
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                          queue: .main) { _ in onChange() }
    }

    func stopMonitoring() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    deinit { stopMonitoring() }
}

// MARK: - Batterie (IOPS, repli pmset)

final class SystemBattery: BatteryBackend {
    private var source: CFRunLoopSource?
    fileprivate var onChange: (() -> Void)?

    func readIOPS() -> [PowerSourceInfo] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return list.compactMap { source in
            IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        }.compactMap { PowerSourceInfo(iops: $0) }
    }

    func readPmset(completion: @escaping ([PowerSourceInfo]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let sources = SystemProcess.run("/usr/bin/pmset", ["-g", "accps"], timeout: 5)
                .map { PmsetBatteryParser.parse($0.stdout) } ?? []
            DispatchQueue.main.async { completion(sources) }
        }
    }

    /// Notification IOPS sur la boucle principale : aucun polling.
    func startMonitoring(_ onChange: @escaping () -> Void) {
        stopMonitoring()
        self.onChange = onChange
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            Unmanaged<SystemBattery>.fromOpaque(context).takeUnretainedValue().onChange?()
        }
        guard let created = IOPSNotificationCreateRunLoopSource(
            callback, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        source = created
    }

    func stopMonitoring() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        source = nil
        onChange = nil
    }

    deinit { stopMonitoring() }
}

// MARK: - Caféine (assertion d'énergie)

final class SystemCaffeine: CaffeineBackend {
    private var assertion = IOPMAssertionID(0)

    /// Écran allumé (empêche aussi la veille du Mac) ou seulement Mac éveillé. Libérée par le noyau si l'app
    /// quitte.
    func acquire(keepDisplayOn: Bool) -> Bool {
        release()
        let type = keepDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var created = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Oriel : caféine" as CFString, &created)
        guard status == kIOReturnSuccess else { return false }
        assertion = created
        return true
    }

    func release() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    deinit { release() }
}

// MARK: - Raccourcis (Concentration)

final class SystemShortcuts: ShortcutBackend {
    /// `shortcuts run "<nom>"`. Le nom est un argument, jamais du texte de shell.
    func run(_ name: String, completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let output = SystemProcess.run("/usr/bin/shortcuts", ["run", name], timeout: 30)
            let result: Result<Void, QuickSettingsFailure>
            if let output, output.status == 0 {
                result = .success(())
            } else if let output {
                result = .failure(QuickSettingsFailure(output.timedOut ? .timeout : .failed, output.errorLine))
            } else {
                result = .failure(QuickSettingsFailure(.failed))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
