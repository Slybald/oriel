import AppKit
import ApplicationServices

// Briques communes aux modules qui parlent à une autre app (Messages, Mail) : état de l'autorisation
// « Automatisation » lu sans jamais poser la question, exécution d'AppleScript hors du main thread avec délai,
// volets de Réglages Système. Tout est derrière un protocole : les tests n'exécutent jamais osascript.

// MARK: - Sous XCTest

enum ModuleEnvironment {
    /// Sous XCTest, les modules qui parlent à d'autres apps (Messages, Mail) ont des accès inertes par défaut : un test
    /// qui affiche leur onglet ne lit jamais les vrais messages et ne lance pas osascript. Les tests branchent des doubles.
    static let isTesting = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

// MARK: - Autorisation

/// Autorisation « Automatisation » de Oriel vers une autre app.
enum AutomationStatus: Equatable {
    case granted
    case denied
    /// Jamais demandée (ou pas lisible) : le premier envoi d'un événement fera poser la question par macOS.
    case notDetermined
    /// L'app visée est fermée : macOS ne répond pas sans la lancer, donc on ne sait pas.
    case targetNotRunning
}

protocol AutomationProbe {
    func status(of bundleIdentifier: String) -> AutomationStatus
}

/// `AEDeterminePermissionToAutomateTarget` avec `askUserIfNeeded: false` : lit l'état, n'ouvre aucune fenêtre et
/// ne lance pas l'app visée. Mesuré sur macOS 27.0.1 : app ouverte et jamais demandée → -1744, app fermée → -600.
struct SystemAutomationProbe: AutomationProbe {
    func status(of bundleIdentifier: String) -> AutomationStatus {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
            return .targetNotRunning
        }
        var target = AEAddressDesc()
        let made = bundleIdentifier.withCString {
            AECreateDesc(DescType(typeApplicationBundleID), $0, strlen($0), &target)
        }
        guard made == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) {
        case noErr: return .granted
        case -1743: return .denied  // errAEEventNotPermitted
        default: return .notDetermined  // -1744 : il faudrait demander
        }
    }
}

// MARK: - Réglages Système

/// Volets de « Confidentialité et sécurité » (les trois ancres existent dans l'extension Réglages de macOS 27).
enum PrivacyPane: String {
    case fullDiskAccess = "Privacy_AllFiles"
    case automation = "Privacy_Automation"
    case contacts = "Privacy_Contacts"

    var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")! }
}

// MARK: - AppleScript

enum AppleScriptFailure: Error, Equatable {
    /// Code -1743 : l'utilisateur a refusé (ou retiré) l'Automatisation.
    case notAuthorized
    /// Code -1712 ou délai dépassé : l'app visée ne répond pas.
    case timedOut
    /// Autre erreur ; le texte de l'erreur n'est jamais gardé (il peut citer un message).
    case failed(code: Int?)
}

protocol AppleScriptRunner: AnyObject {
    /// Exécute `script` (qui définit `on run argv`) hors du main thread ; `done` est rappelé sur le main thread.
    /// Le contenu variable (texte d'un message) passe toujours par `arguments`, jamais dans le script.
    func run(_ script: String, arguments: [String], timeout: TimeInterval,
             _ done: @escaping (Result<String, AppleScriptFailure>) -> Void)
}

/// `/usr/bin/osascript` en processus fils : un Mail qui ne répond pas se tue au délai sans figer la notch, et la
/// fenêtre d'autorisation de macOS s'attache à Oriel (processus responsable), comme pour `CalendarOpener`.
final class OsascriptRunner: AppleScriptRunner {
    func run(_ script: String, arguments: [String], timeout: TimeInterval,
             _ done: @escaping (Result<String, AppleScriptFailure>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = Self.execute(script, arguments: arguments, timeout: timeout)
            DispatchQueue.main.async { done(result) }
        }
    }

    private static func execute(_ script: String, arguments: [String],
                                timeout: TimeInterval) -> Result<String, AppleScriptFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // « -- » : un argument qui commence par « - » n'est jamais pris pour une option.
        process.arguments = ["-e", script, "--"] + arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return .failure(.failed(code: nil)) }
        let expired = Flag()
        let killer = DispatchWorkItem {
            expired.raise()
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        if expired.isRaised { return .failure(.timedOut) }
        if process.terminationStatus == 0 {
            return .success(String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .newlines))
        }
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return .failure(failure(fromErrorOutput: stderr))
    }

    private final class Flag {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    /// Le code entre parenthèses en fin de message (« … (-1743) ») ne dépend pas de la langue du système.
    static func failure(fromErrorOutput text: String) -> AppleScriptFailure {
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close,
              let code = Int(line[line.index(after: open)..<close]) else { return .failed(code: nil) }
        switch code {
        case -1743: return .notAuthorized
        case -1712: return .timedOut
        default: return .failed(code: code)
        }
    }
}

/// Exécuteur qui échoue aussitôt (sous XCTest, voir `ModuleEnvironment`).
final class InertAppleScriptRunner: AppleScriptRunner {
    func run(_ script: String, arguments: [String], timeout: TimeInterval,
             _ done: @escaping (Result<String, AppleScriptFailure>) -> Void) {
        done(.failure(.failed(code: nil)))
    }
}
