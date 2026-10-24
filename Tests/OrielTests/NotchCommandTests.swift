import Foundation
import XCTest
@testable import Oriel

/// La vraie commande hooks/notch (sh, awk et curl du système) contre un serveur local de test : HOME jetable (le
/// jeton de l'API y est écrit), port de test (`ORIEL_PORT`). Rien n'est installé hors des dossiers temporaires.
final class NotchCommandTests: XCTestCase {
    private static let script = repositoryRoot.appendingPathComponent("hooks/notch")

    /// Processus de la commande ; la boucle principale tourne pendant l'attente (le serveur passe par elle).
    final class Command {
        let process = Process()
        private let out = Pipe()
        private let err = Pipe()
        private(set) var stdout = ""
        private(set) var stderr = ""

        init(_ arguments: [String], home: URL, port: UInt16, environment: [String: String] = [:]) throws {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [NotchCommandTests.script.path] + arguments
            process.environment = ["HOME": home.path, "ORIEL_PORT": String(port), "PATH": "/usr/bin:/bin",
                                   "TMPDIR": home.path, "LANG": "en_US.UTF-8"].merging(environment) { $1 }
            process.currentDirectoryURL = home
            process.standardOutput = out
            process.standardError = err
            try process.run()
        }

        @discardableResult
        func finish(timeout: TimeInterval = 10) -> Bool {
            guard spin(timeout: timeout, until: { !process.isRunning }) else { return false }
            stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return true
        }

        var status: Int32 { process.terminationStatus }
    }

    @discardableResult
    private func notch(_ arguments: [String], _ fixture: LocalAPIServerFixture,
                       file: StaticString = #filePath, line: UInt = #line) throws -> Command {
        let command = try Command(arguments, home: fixture.home, port: fixture.port)
        XCTAssertTrue(command.finish(), "la commande se termine", file: file, line: line)
        return command
    }

    func testShowThenClear() throws {
        let fixture = try LocalAPIServerFixture(self)
        let shown = try notch(["show", "--id", "build", "--title", "Build fini", "--text", "2m14", "--detail", "42 tests",
                               "--icon", "checkmark.circle.fill", "--color", "green", "--ttl", "30",
                               "--app", "com.apple.Terminal", "--client", "make.sh"], fixture)
        XCTAssertEqual(shown.status, 0, shown.stderr)
        XCTAssertEqual(shown.stdout, "build\n", "affiche l'identifiant")
        let ear = try XCTUnwrap(fixture.api.items.first)
        XCTAssertEqual(ear.title, "Build fini")
        XCTAssertEqual(ear.text, "2m14")
        XCTAssertEqual(ear.detail, "42 tests")
        XCTAssertEqual(ear.icon, "checkmark.circle.fill")
        XCTAssertEqual(ear.color, "green")
        XCTAssertEqual(ear.appName, "Terminal")
        XCTAssertEqual(ear.client, "make.sh")
        XCTAssertEqual(ear.expires.timeIntervalSinceNow, 30, accuracy: 10)

        let generated = try notch(["show", "--title", "Sans identifiant"], fixture)
        XCTAssertEqual(generated.status, 0, generated.stderr)
        XCTAssertEqual(generated.stdout.trimmingCharacters(in: .newlines), fixture.api.items.last?.id)
        XCTAssertEqual(fixture.api.items.last?.client, "notch")

        XCTAssertEqual(try notch(["clear", "--id", "build"], fixture).status, 0)
        XCTAssertEqual(fixture.api.items.map(\.title), ["Sans identifiant"])
        let missing = try notch(["clear", "--id", "build"], fixture)
        XCTAssertEqual(missing.status, 1)
        XCTAssertEqual(missing.stderr, "notch: No ear with this id.\n")
        XCTAssertEqual(try notch(["clear"], fixture).status, 0)
        XCTAssertTrue(fixture.api.items.isEmpty)
    }

    /// Guillemets, barres obliques inverses, `$(…)`, retours à la ligne, émojis : du texte, arrivé tel quel (une
    /// seule ligne), jamais du JSON ni une commande.
    func testNoInjection() throws {
        let fixture = try LocalAPIServerFixture(self)
        let marker = fixture.home.appendingPathComponent("pwned")
        let title = "\"},\"app\":\"x $(touch pwned) `id` \\ é 🎉"
        let detail = "ligne 1\nligne 2\t\"fin\"\\"
        let shown = try notch(["show", "--id", "t", "--title", title, "--detail", detail], fixture)
        XCTAssertEqual(shown.status, 0, shown.stderr)
        XCTAssertEqual(fixture.api.items.first?.title, title)
        XCTAssertEqual(fixture.api.items.first?.detail, "ligne 1 ligne 2 \"fin\"\\")
        XCTAssertNil(fixture.api.items.first?.app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "rien n'est exécuté")

        // Ni la durée ni l'identifiant ne peuvent ajouter du JSON ou sortir du chemin.
        for arguments in [["--ttl", "1,\"app\":\"com.apple.Terminal\""], ["--ttl", "08"], ["--ttl", "-5"],
                          ["--id", "../state"], ["--id", "a b"]] {
            let refused = try notch(["show", "--title", "x"] + arguments, fixture)
            XCTAssertEqual(refused.status, 1, "\(arguments)")
            XCTAssertTrue(refused.stderr.hasPrefix("notch: --"), refused.stderr)
        }
        XCTAssertEqual(fixture.api.items.count, 1, "aucune requête envoyée")

        // Le port ne peut pas changer l'hôte : le jeton ne part jamais ailleurs que vers 127.0.0.1.
        let elsewhere = try Command(["show", "--title", "x"], home: fixture.home, port: fixture.port,
                                    environment: ["ORIEL_PORT": "80@example.com"])
        XCTAssertTrue(elsewhere.finish())
        XCTAssertEqual(elsewhere.status, 1)
        XCTAssertEqual(elsewhere.stderr, "notch: ORIEL_PORT: digits only\n")
    }

    /// Lancements rapprochés : le résultat refusé par la cadence est renvoyé une seconde plus tard, le sablier ne
    /// reste pas une heure.
    func testRunResultSurvivesRateLimit() throws {
        // Une requête d'affilée : le sablier passe, le résultat qui le suit aussitôt est d'abord refusé.
        let fixture = try LocalAPIServerFixture(self, limiter: RateLimiter(capacity: 1, perSecond: 1))
        let run = try notch(["run", "--id", "job", "--", "/usr/bin/true"], fixture)
        XCTAssertEqual(run.status, 0)
        // Machine chargée : le résultat peut passer du premier coup ; seul compte l'état final.
        XCTAssertEqual(fixture.api.items.first { $0.id == "job" }?.icon, "checkmark.circle.fill")
    }

    /// L'app refuse : le message de l'API, code 1.
    func testServerErrorsAreShown() throws {
        let fixture = try LocalAPIServerFixture(self)
        let icon = try notch(["show", "--title", "x", "--icon", "hand.raised.fill"], fixture)
        XCTAssertEqual(icon.status, 1)
        XCTAssertEqual(icon.stderr, "notch: icon: not in the list (see docs/API.md).\n")
        let long = try notch(["show", "--title", String(repeating: "a", count: 41)], fixture)
        XCTAssertEqual(long.stderr, "notch: title: 40 characters at most.\n")
        let ttl = try notch(["show", "--title", "x", "--ttl", "9999"], fixture)
        XCTAssertEqual(ttl.stderr, "notch: ttl: whole number of seconds, 1 to 3600.\n")
        let unknown = try notch(["show", "--title", "x", "--url", "https://example.com"], fixture)
        XCTAssertEqual(unknown.status, 1)
        XCTAssertTrue(unknown.stderr.contains("unknown option: --url"))
        XCTAssertEqual(try notch(["help"], fixture).status, 0)
        XCTAssertTrue(try notch(["help"], fixture).stdout.contains("notch show --title TEXT"))
        XCTAssertTrue(fixture.api.items.isEmpty)
    }

    /// API coupée (pas de jeton) ou app fermée : un message clair, code 1, rien d'autre.
    func testAPIOffOrAppClosed() throws {
        let off = try LocalAPIServerFixture(self, enabled: false)
        let refused = try notch(["show", "--title", "x"], off)
        XCTAssertEqual(refused.status, 1)
        XCTAssertEqual(refused.stderr,
                       "notch: the local API is off or Oriel is not running (Settings, Scripts).\n")

        let closed = try LocalAPIServerFixture(self)
        closed.server.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let unreachable = try notch(["show", "--title", "x"], closed)
        XCTAssertEqual(unreachable.status, 1)
        XCTAssertEqual(unreachable.stderr, "notch: Oriel is not running.\n")
    }

    /// `notch run` : sablier pendant la commande, puis ✓ ou ✗ avec la durée ; sort avec le code de la commande.
    func testRunShowsProgressThenResult() throws {
        let fixture = try LocalAPIServerFixture(self)
        let failing = try Command(["run", "--id", "job", "--", "/bin/sh", "-c", "sleep 1; exit 3"],
                                  home: fixture.home, port: fixture.port)
        XCTAssertTrue(spin { fixture.api.items.first?.icon == "hourglass" }, "sablier pendant la commande")
        XCTAssertEqual(fixture.api.items.first?.title, "sh")
        XCTAssertEqual(fixture.api.items.first?.color, "yellow")
        XCTAssertTrue(failing.process.isRunning)
        XCTAssertTrue(failing.finish())
        XCTAssertEqual(failing.status, 3, "code de sortie de la commande")
        let failed = try XCTUnwrap(fixture.api.items.first)
        XCTAssertEqual(failed.icon, "xmark.circle.fill")
        XCTAssertEqual(failed.color, "red")
        XCTAssertEqual(failed.detail, "exit code 3")
        XCTAssertNotNil(failed.text.range(of: "^[0-9]+s$", options: .regularExpression), failed.text)
        XCTAssertEqual(failed.expires.timeIntervalSinceNow, 60, accuracy: 10)
        XCTAssertEqual(fixture.api.items.count, 1, "le même intercalaire, remplacé")

        let passing = try notch(["run", "--title", "Tests", "--id", "job", "/bin/echo", "bonjour"], fixture)
        XCTAssertEqual(passing.status, 0)
        XCTAssertEqual(passing.stdout, "bonjour\n", "sortie de la commande intacte")
        XCTAssertEqual(fixture.api.items.first?.icon, "checkmark.circle.fill")
        XCTAssertEqual(fixture.api.items.first?.color, "green")
        XCTAssertEqual(fixture.api.items.first?.title, "Tests")
        XCTAssertEqual(fixture.api.items.first?.detail, "")

        let absent = try notch(["run", "--", "/nonexistent/tool"], fixture)
        XCTAssertEqual(absent.status, 127)
    }

    /// API coupée : la commande tourne quand même, avec son code de sortie.
    func testRunWithoutAPIStillRunsTheCommand() throws {
        let off = try LocalAPIServerFixture(self, enabled: false)
        let marker = off.home.appendingPathComponent("ran")
        let run = try notch(["run", "--", "/usr/bin/touch", marker.path], off)
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(run.stderr.contains("the local API is off"))
    }

    // MARK: - Installation

    func testInstallOnlyOverOurOwnCommand() throws {
        let directory = try makeTemporaryDirectory(self)
        let destination = directory.appendingPathComponent(".local/bin/notch")
        let bundled = Self.script
        XCTAssertEqual(NotchCLI.status(bundled: nil, destination: destination), .unavailable)
        XCTAssertEqual(NotchCLI.status(bundled: bundled, destination: destination), .notInstalled)

        try NotchCLI.install(bundled: bundled, destination: destination)
        XCTAssertEqual(NotchCLI.status(bundled: bundled, destination: destination), .installed)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: bundled))

        // Une ancienne version de la nôtre : mise à jour.
        try Data("#!/bin/sh\n\(NotchCLI.marker)\necho old\n".utf8).write(to: destination)
        XCTAssertEqual(NotchCLI.status(bundled: bundled, destination: destination), .outdated)
        try NotchCLI.install(bundled: bundled, destination: destination)
        XCTAssertEqual(NotchCLI.status(bundled: bundled, destination: destination), .installed)
        try NotchCLI.remove(destination: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        // Un autre programme du même nom : jamais remplacé ni retiré.
        let foreign = Data("#!/bin/sh\necho someone else\n".utf8)
        try foreign.write(to: destination)
        XCTAssertEqual(NotchCLI.status(bundled: bundled, destination: destination), .foreign)
        XCTAssertThrowsError(try NotchCLI.install(bundled: bundled, destination: destination))
        XCTAssertThrowsError(try NotchCLI.remove(destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination), foreign)
    }

    /// Le script livré porte la marque, est exécutable et passe la vérification de syntaxe de sh.
    func testBundledScript() throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("#!/bin/sh\n\(NotchCLI.marker)\n"))
        let attributes = try FileManager.default.attributesOfItem(atPath: Self.script.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", Self.script.path]
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
        XCTAssertFalse(text.contains("Bearer"), "le jeton ne passe que par le fichier, jamais en argument")
        XCTAssertTrue(text.contains("-H @\"$TOKEN\""))
    }
}
