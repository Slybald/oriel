import Foundation
import XCTest
@testable import Oriel

/// Traductions : chaque clé utilisée dans le code a sa traduction anglaise dans la bonne table (Localizable ou
/// celle d'un module), les fichiers .strings sont valides et un bundle assemblé comme par scripts/build.sh rend
/// l'anglais ou le français selon la langue demandée.
/// (Les autres tests tournent avec Bundle.main = xctest, sans traduction : ils voient le français.)
final class LocalizationTests: XCTestCase {
    private static let resources = repositoryRoot.appendingPathComponent("Resources")
    private static let sources = repositoryRoot.appendingPathComponent("Sources/Oriel")
    private static let usageKeys = ["NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription",
                                    "NSDownloadsFolderUsageDescription", "NSCalendarsFullAccessUsageDescription",
                                    "NSCalendarsUsageDescription", "NSAppleEventsUsageDescription",
                                    "NSBluetoothAlwaysUsageDescription", "NSContactsUsageDescription"]

    /// Tables des textes de l'interface : Localizable et une par module (tout .strings sauf InfoPlist).
    private static func tables(_ language: String = "en") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: resources.appendingPathComponent("\(language).lproj").path)
            .filter { $0.hasSuffix(".strings") && $0 != "InfoPlist.strings" }
            .map { String($0.dropLast(".strings".count)) }
            .sorted()
    }

    // MARK: - Clés du code

    func testEveryKeyUsedInCodeHasAnEnglishTranslation() throws {
        let used = try Self.keysUsedInSources()
        XCTAssertGreaterThan(used["Localizable"]?.count ?? 0, 100, "extraction des clés cassée ?")
        let tables = try Self.tables()
        XCTAssertEqual(Set(used.keys).subtracting(tables).sorted(), [], "table de traduction absente")
        for table in tables {
            let english = try Self.strings("en", table)
            let keys = used[table] ?? [:]
            for (key, file) in keys.sorted(by: { $0.key < $1.key }) {
                XCTAssertNotNil(english[key], "traduction anglaise manquante (\(file), \(table)) : « \(key) »")
            }
            XCTAssertEqual(Set(english.keys).subtracting(keys.keys).sorted(), [], "clés inutilisées dans \(table)")
        }
    }

    /// Une table par module, les mêmes en anglais et en français.
    func testModuleTablesExist() throws {
        let tables = try Self.tables()
        for table in ["Localizable", "Media", "Agenda", "QuickSettings", "Shelf", "Clipboard", "Timer", "Notes", "Messages", "Mail"] {
            XCTAssertTrue(tables.contains(table), table)
        }
        XCTAssertEqual(try Self.tables("fr"), tables)
    }

    func testTranslationsKeepFormatSpecifiers() throws {
        for table in try Self.tables() {
            for (key, value) in try Self.strings("en", table) {
                XCTAssertEqual(Self.specifiers(value), Self.specifiers(key), "\(table) : « \(key) » → « \(value) »")
            }
        }
    }

    func testFrenchTableIsIdentity() throws {
        for table in try Self.tables() {
            let english = try Self.strings("en", table)
            let french = try Self.strings("fr", table)
            XCTAssertEqual(Set(french.keys).symmetricDifference(english.keys).sorted(), [],
                           "clés différentes en/fr dans \(table)")
            for (key, value) in french { XCTAssertEqual(value, key, table) }
        }
    }

    func testStringsFilesHaveNoDuplicateKeys() throws {
        let entry = try NSRegularExpression(pattern: #"^"((?:[^"\\]|\\.)*)"\s*="#, options: .anchorsMatchLines)
        for language in ["en", "fr"] {
            for table in try Self.tables(language) + ["InfoPlist"] {
                let text = try String(contentsOf: Self.stringsURL(language, table), encoding: .utf8)
                let keys = entry.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                    Range($0.range(at: 1), in: text).map { String(text[$0]) }
                }
                let duplicates = Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.keys
                XCTAssertEqual(duplicates.sorted(), [], "\(language).lproj/\(table).strings")
                XCTAssertEqual(keys.count, try Self.strings(language, table).count, "\(language).lproj/\(table).strings")
            }
        }
    }

    // MARK: - Info.plist

    func testInfoPlistDeclaresEnglishAndFrench() throws {
        let data = try Data(contentsOf: Self.resources.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "en")
        XCTAssertEqual(plist["CFBundleLocalizations"] as? [String], ["en", "fr"])
        for language in ["en", "fr"] {
            let table = try Self.strings(language, "InfoPlist")
            XCTAssertEqual(Set(table.keys), Set(Self.usageKeys), language)
            for key in Self.usageKeys {
                let text = try XCTUnwrap(table[key], "\(language) \(key)")
                XCTAssertFalse(text.contains("git-radar") || text.contains("course-sorter"), "texte générique attendu")
                XCTAssertNotNil(plist[key], key)
            }
        }
    }

    // MARK: - Bundle assemblé comme l'app

    func testAppBundleLooksUpTheRequestedLanguage() throws {
        let app = try makeTemporaryDirectory(self).appendingPathComponent("Oriel.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.resources.appendingPathComponent("Info.plist"),
                                         to: contents.appendingPathComponent("Info.plist"))
        for language in ["en", "fr"] {
            try FileManager.default.copyItem(at: Self.resources.appendingPathComponent("\(language).lproj"),
                                             to: contents.appendingPathComponent("Resources/\(language).lproj"))
        }
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertEqual(Set(bundle.localizations), ["en", "fr"])
        XCTAssertEqual(bundle.developmentLocalization, "en")
        XCTAssertEqual(Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: ["fr-FR"]).first, "fr")
        XCTAssertEqual(Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: ["en-GB"]).first, "en")

        let english = try Self.lproj(bundle, "en")
        let french = try Self.lproj(bundle, "fr")
        let samples = ["Prête": "Ready", "Attend ta permission": "Needs your permission",
                       "Installer les hooks Claude Code": "Install Claude Code Hooks", "il y a %d min": "%dm ago"]
        for (key, value) in samples {
            XCTAssertEqual(english.localizedString(forKey: key, value: nil, table: nil), value)
            XCTAssertEqual(french.localizedString(forKey: key, value: nil, table: nil), key)
        }
        XCTAssertEqual(english.localizedString(forKey: "Lecteur", value: nil, table: "Media"), "Player")
        XCTAssertEqual(french.localizedString(forKey: "Lecteur", value: nil, table: "Media"), "Lecteur")
        XCTAssertEqual(english.localizedString(forKey: "Lecteur", value: nil, table: nil), "Lecteur",
                       "une clé de module n'est pas dans Localizable")
        let desktop = english.localizedString(forKey: "NSDesktopFolderUsageDescription", value: nil, table: "InfoPlist")
        XCTAssertTrue(desktop.contains("optional companion tools"), desktop)
        let bureau = french.localizedString(forKey: "NSDesktopFolderUsageDescription", value: nil, table: "InfoPlist")
        XCTAssertTrue(bureau.contains("outils compagnons optionnels"), bureau)
    }

    func testPluralRules() {
        XCTAssertTrue(Localization.usesSingular(0, english: false), "« 0 session » en français")
        XCTAssertFalse(Localization.usesSingular(0, english: true), "« 0 sessions » en anglais")
        XCTAssertTrue(Localization.usesSingular(1, english: false))
        XCTAssertTrue(Localization.usesSingular(1, english: true))
        XCTAssertFalse(Localization.usesSingular(2, english: false))
        XCTAssertFalse(Localization.usesSingular(2, english: true))
        // Sans traduction (tests), la clé française est rendue telle quelle.
        XCTAssertEqual(String(format: L(2, one: "%d agent", other: "%d agents"), 2), "2 agents")
    }

    // MARK: - Outils

    private static func stringsURL(_ language: String, _ table: String) -> URL {
        resources.appendingPathComponent("\(language).lproj/\(table).strings")
    }

    /// Lu par PropertyListSerialization : échoue si le fichier n'est pas un .strings valide.
    private static func strings(_ language: String, _ table: String) throws -> [String: String] {
        let data = try Data(contentsOf: stringsURL(language, table))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(object as? [String: String], "\(language).lproj/\(table).strings")
    }

    private static func lproj(_ bundle: Bundle, _ language: String) throws -> Bundle {
        let path = try XCTUnwrap(bundle.path(forResource: language, ofType: "lproj"), language)
        return try XCTUnwrap(Bundle(path: path), language)
    }

    /// Clés littérales du code, par table : Text("…"), Button("…"), Toggle("…"), Picker("…"), .help("…"),
    /// L("…" + "…") et les deux formes du pluriel L(n, one: "…", other: "…"). `table: "X"` ou `tableName: "X"`
    /// désigne la table d'un module, sinon Localizable. Sous-dossiers compris, commentaires ignorés.
    private static func keysUsedInSources() throws -> [String: [String: String]] {
        let literal = #""(?:[^"\\\n]|\\.)*""#
        let joined = "(\(literal)(?:\\s*\\+\\s*\(literal))*)"
        let table = #"(?:\s*,\s*(?:table|tableName):\s*"(\w+)")?"#
        // Groupes : 1 = clé (ou forme « one »), 2 = forme « other » ou vide, 3 = table.
        let patterns = [
            #"\b(?:Text|Button|Toggle|Menu|Label|Section|Picker|LabeledContent|help)\(\s*"# + "(\(literal))()" + table,
            #"\bL\(\s*"# + joined + "()" + table,
            #"\bone:\s*"# + joined + #"\s*,\s*other:\s*"# + joined + table,
        ].map { try! NSRegularExpression(pattern: $0) }
        let part = try NSRegularExpression(pattern: literal)

        var keys: [String: [String: String]] = [:]
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertTrue(files.contains { $0.path.contains("/Modules/") }, "dossiers des modules parcourus")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for pattern in patterns {
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    let tableName = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? "Localizable"
                    for group in [1, 2] {
                        guard let range = Range(match.range(at: group), in: text), !range.isEmpty else { continue }
                        let expression = String(text[range])
                        XCTAssertFalse(expression.contains("\\("),
                                       "interpolation dans une clé (\(file.lastPathComponent)) : \(expression)")
                        let parts = part.matches(in: expression,
                                                 range: NSRange(expression.startIndex..., in: expression))
                        let key = parts.compactMap { Range($0.range, in: expression) }
                            .map { unescape(expression[$0].dropFirst().dropLast()) }
                            .joined()
                        keys[tableName, default: [:]][key] = file.lastPathComponent
                    }
                }
            }
        }
        return keys
    }

    /// Échappements Swift d'un littéral simple : \\, \", \n, \t.
    private static func unescape(_ body: Substring) -> String {
        let escapes: [Character: Character] = ["n": "\n", "t": "\t"]
        var result = ""
        var escaping = false
        for character in body {
            if escaping {
                result.append(escapes[character] ?? character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Conversions de format (%d, %@, %02d → d, @, d), dans l'ordre, sans les %%.
    private static func specifiers(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(
            pattern: #"%(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?([@a-zA-Z%])"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }.filter { $0 != "%" }
    }
}
