import XCTest
@testable import Oriel

final class OrderedJSONTests: XCTestCase {
    /// Texte au format exact de `json.dump(indent=2, ensure_ascii=False)` : échappements, non-ASCII,
    /// nombres au format `repr` de Python, conteneurs vides, imbrication.
    static let pythonFormatted = #"""
    {
      "$schema": "https://json.schemastore.org/claude-code-settings.json",
      "z": 1,
      "a": {
        "chemin": "/Users/me/Documents/projet",
        "texte": "guillemets \" barre \\ saut\nretour\r tab\t bs\b ff\f",
        "contrôle": "\u0000 \u0001 \u001b \u001f",
        "unicode": "é ü 中文 😀 \#u{2028} \#u{7F}",
        "vide": "",
        "objet vide": {},
        "liste vide": []
      },
      "nombres": [
        0,
        -0.0,
        42,
        -17,
        1.5,
        0.05,
        1e-07,
        1e+100,
        123456789012345678901234567890,
        NaN,
        Infinity,
        -Infinity
      ],
      "booleens": [
        true,
        false,
        null
      ],
      "imbrication": [
        [
          [
            {
              "k": [
                {}
              ]
            }
          ]
        ]
      ]
    }
    """# + "\n"

    // MARK: - Aller-retour

    func testRoundTripPythonFormattedText() throws {
        let text = Self.pythonFormatted
        var data = try OrderedJSON.parse(text).serialized()
        data.append(0x0A)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), text)
    }

    func testSerializationMatchesPython() throws {
        try Python.requireAvailable()
        let dir = try makeTemporaryDirectory(self)
        let source = dir.appendingPathComponent("source.json")
        let normalized = dir.appendingPathComponent("python.json")
        // Entrée compacte et échappée autrement : Python et nous devons réécrire la même chose.
        let compact = #"{"b":{"x":"\u00e9\/\ud83d\ude00","y":[1,-2,0.5,{},[]]},"a":"\t\"\\","é":null,"vide":{}}"#
        try Data(compact.utf8).write(to: source)
        try Python.normalize(source, to: normalized)
        var ours = try OrderedJSON.parse(Data(contentsOf: source)).serialized()
        ours.append(0x0A)
        XCTAssertEqual(String(decoding: ours, as: UTF8.self), try String(contentsOf: normalized, encoding: .utf8))

        // Et le texte de référence est bien celui que Python produit.
        try Data(Self.pythonFormatted.utf8).write(to: source)
        try Python.normalize(source, to: normalized)
        XCTAssertEqual(try String(contentsOf: normalized, encoding: .utf8), Self.pythonFormatted)
    }

    // MARK: - Ordre, nombres, chaînes

    func testKeyOrderIsPreserved() throws {
        let value = try OrderedJSON.parse(#"{"z": 1, "a": 2, "m": {"y": true, "b": false}}"#)
        XCTAssertEqual(value.members?.map(\.key), ["z", "a", "m"])
        XCTAssertEqual(value["m"]?.members?.map(\.key), ["y", "b"])
    }

    func testNumbersKeepTheirText() throws {
        let value = try OrderedJSON.parse(#"[1.50, -0, 1E+5, 2e-3, 10.0, 12345678901234567890123]"#)
        XCTAssertEqual(value.items, [.number("1.50"), .number("-0"), .number("1E+5"), .number("2e-3"),
                                     .number("10.0"), .number("12345678901234567890123")])
        XCTAssertEqual(String(decoding: value.serialized(), as: UTF8.self),
                       "[\n  1.50,\n  -0,\n  1E+5,\n  2e-3,\n  10.0,\n  12345678901234567890123\n]")
    }

    func testStringEscapes() throws {
        let value = try OrderedJSON.parse(#"["\u00e9\/\"\\\n\t\b\f\r\u0001\u001F\ud83d\ude00\u2028", "a/b"]"#)
        XCTAssertEqual(value.items?.first?.stringValue, "é/\"\\\n\t\u{08}\u{0C}\r\u{01}\u{1F}😀\u{2028}")
        // `/` et le non-ASCII ne sont pas échappés ; les contrôles le sont, en hexadécimal minuscule.
        XCTAssertEqual(String(decoding: value.serialized(), as: UTF8.self),
                       "[\n  \"é/\\\"\\\\\\n\\t\\b\\f\\r\\u0001\\u001f😀\u{2028}\",\n  \"a/b\"\n]")
    }

    func testEmptyContainersAndScalars() throws {
        XCTAssertEqual(String(decoding: try OrderedJSON.parse(" { } ").serialized(), as: UTF8.self), "{}")
        XCTAssertEqual(String(decoding: try OrderedJSON.parse("[ ]").serialized(), as: UTF8.self), "[]")
        XCTAssertEqual(try OrderedJSON.parse("\r\n\t true \n"), .bool(true))
        XCTAssertEqual(try OrderedJSON.parse("null"), .null)
        XCTAssertEqual(try OrderedJSON.parse("\"x\""), .string("x"))
        XCTAssertEqual(try OrderedJSON.parse("-Infinity"), .number("-Infinity"))
    }

    /// Comme un dict Python : la dernière valeur gagne, à la place de la première.
    func testDuplicateKeys() throws {
        let value = try OrderedJSON.parse(#"{"a": 1, "b": 2, "a": 3}"#)
        XCTAssertEqual(value.members?.map(\.key), ["a", "b"])
        XCTAssertEqual(value["a"], .number("3"))
    }

    /// Pas d'équivalence canonique : « é » précomposé et « e + accent » sont deux clés distinctes.
    func testKeysComparedByCodePoint() throws {
        let value = try OrderedJSON.parse("{\"\u{E9}\": 1, \"e\u{301}\": 2}")
        XCTAssertEqual(value.members?.count, 2)
        XCTAssertEqual(value["\u{E9}"], .number("1"))
        XCTAssertEqual(value["e\u{301}"], .number("2"))
        XCTAssertNotEqual(OrderedJSON.string("\u{E9}"), OrderedJSON.string("e\u{301}"))
    }

    func testSubscriptKeepsPositionAndAppends() throws {
        var value = try OrderedJSON.parse(#"{"a": 1, "b": 2, "c": 3}"#)
        value["b"] = .string("deux")
        value["d"] = .null
        value["a"] = nil
        XCTAssertEqual(value.members?.map(\.key), ["b", "c", "d"])
        XCTAssertEqual(value["b"], .string("deux"))
        var scalar = OrderedJSON.number("1")
        scalar["x"] = .null
        XCTAssertEqual(scalar, .number("1"), "un scalaire n'a pas de clés")
    }

    func testEqualityIsOrderSensitive() throws {
        XCTAssertEqual(try OrderedJSON.parse(#"{"a": [1, {"b": null}]}"#), try OrderedJSON.parse(#"{"a":[1,{"b":null}]}"#))
        XCTAssertNotEqual(try OrderedJSON.parse(#"{"a": 1, "b": 2}"#), try OrderedJSON.parse(#"{"b": 2, "a": 1}"#))
        XCTAssertNotEqual(try OrderedJSON.parse("1.0"), try OrderedJSON.parse("1"))
    }

    // MARK: - Erreurs

    func testInvalidDocumentsAreRejected() {
        let invalid = [
            "", "   ", "{", "}", "{\"a\"}", "{\"a\":}", "{\"a\":1,}", "[1,]", "[1 2]", "{'a': 1}", "{a: 1}",
            "01", "1.", ".5", "-", "+1", "1e", "0x10", "tru", "nul", "nan", "infinity", "{} x", "[] []",
            "\"non terminée", "\"\\x\"", "\"\\u12\"", "\"\\u12G4\"", "\"tab\tbrut\"", "\"saut\nbrut\"",
            "\"\\ud800\"", "\"\\udc00\"", "\"\\ud800\\u0041\"", "// commentaire\n{}",
        ]
        for text in invalid {
            XCTAssertThrowsError(try OrderedJSON.parse(text), "accepté à tort : \(text.debugDescription)")
        }
        XCTAssertThrowsError(try OrderedJSON.parse(Data([0xEF, 0xBB, 0xBF] + Array("{}".utf8))), "BOM")
        XCTAssertThrowsError(try OrderedJSON.parse(Data([0x22, 0xC3, 0x28, 0x22])), "UTF-8 invalide")
        XCTAssertThrowsError(try OrderedJSON.parse(String(repeating: "[", count: 5000)), "imbrication")
    }

    func testErrorReportsLineAndColumn() {
        XCTAssertThrowsError(try OrderedJSON.parse("{\n  \"a\": 1,\n  \"é\": ,\n}")) { error in
            guard let error = error as? OrderedJSON.ParseError else { return XCTFail("ParseError attendue") }
            XCTAssertEqual(error.line, 3)
            XCTAssertEqual(error.column, 8)
        }
    }
}
