import FanControl
import Foundation

// Accès système des ventilateurs : lecture du SMC (sans droits), installation de l'outil `fanctl`, tenue d'une
// vitesse fixe par `sudo -n fanctl hold`. Comme les autres accès du module, derrière un protocole ; les rappels
// arrivent sur le fil principal.

/// Ce que la tuile affiche.
struct FanStatus: Equatable {
    var fans: [FanReading]
    var temperatures: Thermals.Reading
    /// Le mode manuel est possible sur ce Mac (Apple Silicon, clés `F<n>Md` et `F<n>Tg`).
    var supportsManual: Bool
}

protocol FanBackend: AnyObject {
    /// Lecture hors du fil principal (un appel SMC coûte environ 1 ms) ; nil : pas de SMC ou pas de ventilateur.
    func read(completion: @escaping (FanStatus?) -> Void)
    var authorization: FanAuthorizationState { get }
    /// L'outil est livré avec l'app (sinon la vitesse fixe n'est pas proposée).
    var canInstall: Bool { get }
    /// Copie l'outil et pose la règle (un mot de passe administrateur, une fois).
    func install(completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void)
    /// Rend les ventilateurs à macOS, retire la règle et l'outil (un mot de passe administrateur).
    func uninstall(completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void)
    /// Lance la tenue. `onMessage` : chaque ligne de l'outil ; `onEnd` : fin du processus (code, première ligne
    /// d'erreur). false : impossible de lancer.
    func startHold(onMessage: @escaping (String) -> Void, onEnd: @escaping (Int32, String?) -> Void) -> Bool
    func send(_ line: String)
    /// Ferme l'entrée de l'outil : il remet l'automatique et s'arrête.
    func endHold()
    /// `sudo -n fanctl auto`, sans tenue en cours (reprise après un arrêt anormal).
    func resetToAutomatic(completion: @escaping (Bool) -> Void)
}

final class SystemFans: FanBackend {
    private let queue = DispatchQueue(label: "oriel.fans", qos: .utility)
    /// Créés sur `queue` au premier usage, utilisés seulement depuis elle.
    private var smc: SMCConnection??
    private var thermals: Thermals?
    private let run: SystemProcess.Runner
    private let userName: () -> String
    private let bundledHelper: URL?
    private var process: Process?
    private var input: FileHandle?

    /// Les paramètres servent aux tests : aucun processus réel, un outil d'essai.
    init(run: @escaping SystemProcess.Runner = { SystemProcess.run($0, $1, timeout: $2) },
         userName: @escaping () -> String = NSUserName, bundledHelper: URL? = FanAuthorization.bundledHelper()) {
        self.run = run
        self.userName = userName
        self.bundledHelper = bundledHelper
    }

    func read(completion: @escaping (FanStatus?) -> Void) {
        queue.async { [self] in
            if smc == nil {
                smc = .some(SMCConnection())
                thermals = (smc ?? nil).map { Thermals(smc: $0) }
            }
            var status: FanStatus?
            if let device = smc ?? nil, let thermals {
                let fans = Fans.read(device)
                if !fans.isEmpty {
                    status = FanStatus(fans: fans, temperatures: thermals.read(),
                                       supportsManual: fans.allSatisfy { Fans.supportsManualMode(device, fan: $0.index) })
                }
            }
            DispatchQueue.main.async { completion(status) }
        }
    }

    private lazy var bundledHash = bundledHelper.flatMap(FanAuthorization.sha256)

    var canInstall: Bool { bundledHash != nil }

    var authorization: FanAuthorizationState {
        guard FanAuthorization.isInstalled else { return .notInstalled }
        guard let bundledHash else { return .installed }
        return FanAuthorization.sha256(of: URL(fileURLWithPath: FanAuthorization.helperPath)) == bundledHash
            ? .installed : .outdated
    }

    func install(completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void) {
        guard let rule = FanAuthorization.ruleContents(forUser: userName()) else {
            return completion(.failure(QuickSettingsFailure(.invalidUser)))
        }
        guard let helper = bundledHelper, let hash = bundledHash,
              let shell = FanAuthorization.installShellCommand(helperSource: helper.path, sha256: hash, ruleContents: rule) else {
            return completion(.failure(QuickSettingsFailure(.failed)))
        }
        let prompt = L("Oriel veut installer son outil de pilotage des ventilateurs. Ton mot de passe ne sera plus demandé pour ce réglage.",
                       table: "QuickSettings")
        runAsAdministrator(shell, prompt: prompt, completion: completion)
    }

    func uninstall(completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void) {
        runAsAdministrator(FanAuthorization.removeShellCommand,
                           prompt: L("Oriel veut retirer son outil de pilotage des ventilateurs.", table: "QuickSettings"),
                           completion: completion)
    }

    private func runAsAdministrator(_ shell: String, prompt: String,
                                    completion: @escaping (Result<Void, QuickSettingsFailure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [run] in
            let script = LowPowerAuthorization.administratorScript(running: shell, prompt: prompt)
            let result: Result<Void, QuickSettingsFailure>
            if let output = run("/usr/bin/osascript", ["-e", script], 120) {
                result = output.status == 0 ? .success(()) : .failure(SystemPowerMode.failure(output))
            } else {
                result = .failure(QuickSettingsFailure(.failed))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Tenue

    func startHold(onMessage: @escaping (String) -> Void, onEnd: @escaping (Int32, String?) -> Void) -> Bool {
        endHold()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: LowPowerAuthorization.sudoPath)
        process.arguments = FanAuthorization.sudoArguments("hold")
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Écrire après la fin de l'outil rend EPIPE au lieu de tuer l'app par SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { return false }
        self.process = process
        input = stdin.fileHandleForWriting
        // Un fil lit les lignes jusqu'à la fin de l'outil, puis annonce la fin : sur la file principale, toutes les
        // lignes (dont le `auto <raison>` final) passent avant `onEnd`.
        Thread {
            let reader = stdout.fileHandleForReading
            var pending = Data()
            while case let data = reader.availableData, !data.isEmpty {
                pending.append(data)
                while let newline = pending.firstIndex(of: 0x0a) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    DispatchQueue.main.async { onMessage(line) }
                }
            }
            process.waitUntilExit()
            let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .components(separatedBy: .newlines).first { !$0.isEmpty }
            DispatchQueue.main.async { onEnd(process.terminationStatus, error) }
        }.start()
        return true
    }

    func send(_ line: String) {
        try? input?.write(contentsOf: Data((line + "\n").utf8))
    }

    func endHold() {
        try? input?.close()
        input = nil
        process = nil
    }

    func resetToAutomatic(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [run] in
            let ok = run(LowPowerAuthorization.sudoPath, FanAuthorization.sudoArguments("auto"), 15)?.status == 0
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
