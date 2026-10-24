import Foundation
import XCTest

/// Racine du dépôt (Tests/OrielTests/<fichier> → ../..).
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Dossier temporaire neuf, supprimé à la fin du test.
func makeTemporaryDirectory(_ testCase: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("oriel-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

/// Domaine UserDefaults jetable, supprimé à la fin du test : jamais les vrais réglages de l'app.
func makeEphemeralDefaults(_ testCase: XCTestCase) -> UserDefaults {
    let name = "oriel-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    testCase.addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    return defaults
}

/// /usr/bin/python3 en mode isolé, pour comparer avec hooks_config.py et json.dump.
enum Python {
    static let path = "/usr/bin/python3"

    static func requireAvailable() throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("\(path) absent : comparaison avec Python impossible")
        }
    }

    /// Lance `python3 -I <arguments>`. HOME pointe vers un dossier jetable : jamais le vrai ~/.claude.
    @discardableResult
    static func run(_ arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-I"] + arguments
        var env = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                   "HOME": FileManager.default.temporaryDirectory.appendingPathComponent("oriel-no-home").path]
        env.merge(environment) { $1 }
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// `json.load` puis `json.dump(indent=2, ensure_ascii=False)` + saut de ligne, de `source` vers `destination`.
    static func normalize(_ source: URL, to destination: URL) throws {
        let script = """
        import json, sys
        with open(sys.argv[1], encoding="utf-8") as f:
            data = json.load(f)
        with open(sys.argv[2], "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\\n")
        """
        let result = try run(["-c", script, source.path, destination.path])
        guard result.status == 0 else { throw NSError(domain: "Python", code: Int(result.status)) }
    }

    /// scripts/hooks_config.py avec CLAUDE_CONFIG_DIR = `configDirectory`.
    @discardableResult
    static func hooksConfig(_ arguments: [String], configDirectory: URL) throws -> Int32 {
        let script = repositoryRoot.appendingPathComponent("scripts/hooks_config.py").path
        return try run([script] + arguments, environment: ["CLAUDE_CONFIG_DIR": configDirectory.path]).status
    }
}
