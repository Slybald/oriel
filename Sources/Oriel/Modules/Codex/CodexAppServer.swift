import AppKit
import Darwin
import Foundation

/// Un hook tel que Codex le décrit (`hooks/list`, app-server) : sa clé dans `hooks.state`, sa commande, et son avis.
struct CodexListedHook: Equatable {
    var key: String
    var command: String
    var sourcePath: String
    /// `trusted`, `untrusted` (jamais approuvé), `modified` (changé depuis l'approbation) ou `managed`.
    var trustStatus: String
    /// Hachage que Codex attend dans `trusted_hash` pour considérer ce hook comme approuvé.
    var currentHash: String
    var enabled: Bool

    /// Codex n'exécute le hook qu'une fois approuvé (ou géré par l'administrateur).
    var isTrusted: Bool { trustStatus == "trusted" || trustStatus == "managed" }
}

/// Ce que Oriel demande à Codex au sujet de ses hooks. Un protocole pour que les tests y mettent un double.
protocol CodexHooksService {
    /// Les hooks vus par Codex. Avec `approving`, ceux qui l'acceptent et ne sont pas approuvés le sont d'abord (même
    /// processus, donc avec les hachages qu'on vient de lire), puis la liste est relue.
    func hooks(approving: ((CodexListedHook) -> Bool)?) throws -> [CodexListedHook]
}

/// Le quota du compte ChatGPT, tel que Codex le donne. Un protocole pour que les tests y mettent un double.
protocol CodexQuotaService {
    func rateLimits() throws -> QuotaSnapshot
}

enum CodexServiceError: LocalizedError, Equatable {
    case noCodex
    case launch(String)
    case timeout
    case failure(String)
    /// Un autre niveau de configuration (administrateur, projet) impose sa valeur : l'écriture n'a pas d'effet.
    case overridden

    var errorDescription: String? {
        switch self {
        case .noCodex:
            return L("Codex est introuvable sur ce Mac (ni l'app, ni la commande codex).", table: "Codex")
        case .launch(let detail):
            return String(format: L("Impossible de lancer Codex (%@).", table: "Codex"), detail)
        case .timeout:
            return L("Codex n'a pas répondu à temps.", table: "Codex")
        case .failure(let detail):
            return String(format: L("Codex a refusé la demande (%@).", table: "Codex"), detail)
        case .overridden:
            return L("Un réglage plus prioritaire (administrateur, projet) impose l'état de ces hooks.", table: "Codex")
        }
    }
}

/// Où trouver un `codex` capable de parler `app-server` : celui de l'app (ChatGPT, bundle `com.openai.codex`) d'abord,
/// c'est lui qui exécute les hooks pour l'utilisateur de l'app ; sinon la commande `codex` à un endroit usuel.
enum CodexBinary {
    static let appBundleId = "com.openai.codex"

    static func candidates(appURL: URL?, home: URL) -> [URL] {
        var list: [URL] = []
        if let appURL {
            list.append(appURL.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
            list.append(appURL.appendingPathComponent("Contents/Resources/codex"))
        }
        list.append(home.appendingPathComponent(".local/bin/codex"))
        list.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
        list.append(URL(fileURLWithPath: "/usr/local/bin/codex"))
        return list
    }

    static func find(appURL: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleId),
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        candidates(appURL: appURL, home: home).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Client minimal de `codex app-server` (JSON-RPC, un message par ligne sur stdio). Lance un processus Codex le temps
/// d'une demande, puis l'arrête. Lit les hooks (`hooks/list`) et, sur demande explicite seulement, écrit leur
/// approbation par `config/batchWrite` : la requête même que le bouton « Review hooks » de l'app Codex envoie.
struct CodexAppServer: CodexHooksService, CodexQuotaService {
    let executable: URL
    /// `CODEX_HOME` : le dossier dont on veut lire les hooks.
    let home: URL
    /// Dossier pour lequel Codex liste les hooks. Les hooks de l'utilisateur valent pour tous ; la racine évite qu'un
    /// `.codex/` du dossier personnel soit lu aussi comme réglage de projet (le même hooks.json deux fois).
    var workingDirectory = "/"
    /// Un `CODEX_HOME` neuf met plus de dix secondes à répondre.
    var timeout: TimeInterval = 40

    func hooks(approving shouldApprove: ((CodexListedHook) -> Bool)? = nil) throws -> [CodexListedHook] {
        let session = try Session(executable: executable, home: home, timeout: timeout)
        defer { session.close() }
        try session.initialize()
        var listed = try Self.parse(session.request("hooks/list", ["cwds": [workingDirectory]]))
        if let shouldApprove {
            let wanted = listed.filter { !$0.isTrusted && shouldApprove($0) }
            if !wanted.isEmpty {
                let answer = try session.request("config/batchWrite", ["edits": Self.edits(trusting: wanted)])
                if answer["status"] as? String == "okOverridden" { throw CodexServiceError.overridden }
                listed = try Self.parse(session.request("hooks/list", ["cwds": [workingDirectory]]))
            }
        }
        return listed
    }

    /// `account/rateLimits/read` : les fenêtres du compte ChatGPT (5 h et 7 jours), lues par Codex avec sa
    /// propre connexion, comme le fait l'app Codex pour son écran d'usage. Avec une clé d'API (pas de compte ChatGPT),
    /// Codex répond par une erreur : pas de jauge.
    func rateLimits() throws -> QuotaSnapshot {
        let session = try Session(executable: executable, home: home, timeout: Self.quotaTimeout)
        defer { session.close() }
        try session.initialize()
        return try Self.parseRateLimits(session.request("account/rateLimits/read", [:]), now: Date())
    }

    /// Une lecture de quota qui ne répond pas en 15 s est abandonnée (mesuré : 1,2 s).
    static let quotaTimeout: TimeInterval = 15

    // MARK: - Messages (purs)

    /// Réponse de `account/rateLimits/read` : `rateLimits.primary` et `secondary` (`usedPercent`, `windowDurationMins`,
    /// `resetsAt` en secondes). Tolérant : une fenêtre sans pourcentage ou sans heure de remise à zéro est ignorée.
    static func parseRateLimits(_ result: [String: Any], now: Date) throws -> QuotaSnapshot {
        guard let limits = result["rateLimits"] as? [String: Any] else {
            throw CodexServiceError.failure(L("réponse inattendue", table: "Codex"))
        }
        let windows: [QuotaWindow] = ["primary", "secondary"].compactMap { key in
            guard let raw = limits[key] as? [String: Any], let used = (raw["usedPercent"] as? NSNumber)?.doubleValue,
                  let reset = (raw["resetsAt"] as? NSNumber)?.doubleValue, reset > 0 else { return nil }
            return QuotaWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: reset),
                               minutes: (raw["windowDurationMins"] as? NSNumber)?.intValue)
        }
        guard !windows.isEmpty else { throw CodexServiceError.failure(L("pas de quota pour ce compte", table: "Codex")) }
        return QuotaSnapshot(windows: windows.sorted { ($0.minutes ?? .max) < ($1.minutes ?? .max) }, updatedAt: now)
    }

    /// `hooks.state."<clé>".trusted_hash = "<hachage>"` pour chaque hook.
    static func edits(trusting hooks: [CodexListedHook]) -> [[String: Any]] {
        hooks.map { hook in
            ["keyPath": "hooks.state.\(tomlQuoted(hook.key)).trusted_hash", "value": hook.currentHash,
             "mergeStrategy": "upsert"]
        }
    }

    /// Clé TOML entre guillemets (chaîne de base : `\` et `"` échappés, pas `/`).
    static func tomlQuoted(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": quoted += "\\\\"
            case "\"": quoted += "\\\""
            case "\n": quoted += "\\n"
            case "\t": quoted += "\\t"
            case "\r": quoted += "\\r"
            default:
                if scalar.value < 0x20 { quoted += String(format: "\\u%04X", scalar.value) } else { quoted.unicodeScalars.append(scalar) }
            }
        }
        return quoted + "\""
    }

    /// Réponse de `hooks/list` : `data[].hooks[]`. Les entrées incomplètes sont ignorées (le format peut évoluer).
    static func parse(_ result: [String: Any]) throws -> [CodexListedHook] {
        guard let entries = result["data"] as? [[String: Any]] else {
            throw CodexServiceError.failure(L("réponse inattendue", table: "Codex"))
        }
        var seen = Set<String>()
        return entries.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { raw in
            guard let key = raw["key"] as? String, let command = raw["command"] as? String,
                  let status = raw["trustStatus"] as? String, let hash = raw["currentHash"] as? String,
                  seen.insert(key).inserted else { return nil }
            return CodexListedHook(key: key, command: command, sourcePath: raw["sourcePath"] as? String ?? "",
                                   trustStatus: status, currentHash: hash, enabled: raw["enabled"] as? Bool ?? true)
        }
    }

    // MARK: - Processus

    private final class Session {
        private static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private let watchdog: DispatchSourceTimer
        private var buffer = Data()
        private var nextId = 0
        private var timedOut = false

        init(executable: URL, home: URL, timeout: TimeInterval) throws {
            _ = Self.ignoreBrokenPipes
            process.executableURL = executable
            process.arguments = ["app-server"]
            // Un environnement minimal : rien de la session de l'utilisateur n'est transmis à Codex.
            process.environment = ["CODEX_HOME": home.path, "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            // Une source jamais démarrée ne peut pas être libérée : on la démarre avant de lancer Codex.
            watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            watchdog.schedule(deadline: .now() + timeout)
            watchdog.setEventHandler { [weak self] in
                self?.timedOut = true
                self?.process.terminate()
            }
            watchdog.resume()
            do {
                try process.run()
            } catch {
                watchdog.cancel()
                throw CodexServiceError.launch(error.localizedDescription)
            }
        }

        func initialize() throws {
            _ = try request("initialize", ["clientInfo": ["name": "oriel", "version": "1"]])
            try send(["method": "initialized"])
        }

        func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            nextId += 1
            let id = nextId
            try send(["id": id, "method": method, "params": params])
            while let line = readLine() {
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      message["id"] as? Int == id, message["method"] == nil else { continue }
                if let error = message["error"] as? [String: Any] {
                    throw CodexServiceError.failure(error["message"] as? String ?? method)
                }
                return message["result"] as? [String: Any] ?? [:]
            }
            throw timedOut ? CodexServiceError.timeout : CodexServiceError.failure(L("Codex s'est arrêté", table: "Codex"))
        }

        func close() {
            watchdog.setEventHandler {}
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        private func send(_ message: [String: Any]) throws {
            guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
            data.append(0x0A)
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
            } catch {
                throw timedOut ? CodexServiceError.timeout : CodexServiceError.failure(error.localizedDescription)
            }
        }

        private func readLine() -> Data? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    return line
                }
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { return nil }
                buffer.append(chunk)
            }
        }
    }
}
