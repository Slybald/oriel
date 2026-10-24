import Foundation

/// Valeur JSON qui garde l'ordre des clés et le texte exact des nombres.
///
/// JSONSerialization perd l'ordre des clés : réécrire `settings.json` avec lui mélangerait le fichier
/// de l'utilisateur. Lecture et écriture suivent `json.load` et `json.dump(indent=2, ensure_ascii=False)`
/// de Python, pour qu'un fichier écrit par `scripts/hooks_config.py` ressorte identique octet pour octet.
indirect enum OrderedJSON {
    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /// Texte du nombre tel qu'il est dans le fichier (`1.50`, `-0`, `1e5`, `NaN`…).
    case number(String)
    case bool(Bool)
    case null

    struct Member {
        var key: String
        var value: OrderedJSON
    }

    struct ParseError: Error, CustomStringConvertible {
        let message: String
        let line: Int
        let column: Int

        var description: String { String(format: L("%@, ligne %d, colonne %d"), message, line, column) }
    }

    /// Clés comparées point de code par point de code, comme Python (pas d'équivalence Unicode canonique).
    static func sameKey(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    // MARK: - Accès

    var members: [Member]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var items: [OrderedJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// Valeur d'une clé d'objet. En écriture, une clé existante garde sa place ; une nouvelle va à la fin.
    subscript(key: String) -> OrderedJSON? {
        get {
            members?.first { Self.sameKey($0.key, key) }?.value
        }
        set {
            guard case .object(var members) = self else { return }
            let index = members.firstIndex { Self.sameKey($0.key, key) }
            switch (index, newValue) {
            case let (index?, value?): members[index].value = value
            case let (index?, nil): members.remove(at: index)
            case let (nil, value?): members.append(Member(key: key, value: value))
            case (nil, nil): return
            }
            self = .object(members)
        }
    }

    // MARK: - Lecture

    /// Texte UTF-8 complet (sans BOM, comme `json.loads` de Python).
    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    static func parse(_ text: String) throws -> OrderedJSON {
        try parse(Data(text.utf8))
    }

    // MARK: - Écriture

    /// Même sortie que `json.dumps(value, indent=2, ensure_ascii=False)` : sans saut de ligne final.
    func serialized() -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(4096)
        Self.write(self, level: 0, into: &out)
        return Data(out)
    }

    private static func write(_ value: OrderedJSON, level: Int, into out: inout [UInt8]) {
        switch value {
        case .object(let members):
            if members.isEmpty {
                out.append(contentsOf: Array("{}".utf8))
                return
            }
            out.append(UInt8(ascii: "{"))
            for (index, member) in members.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                newline(level + 1, into: &out)
                writeString(member.key, into: &out)
                out.append(contentsOf: Array(": ".utf8))
                write(member.value, level: level + 1, into: &out)
            }
            newline(level, into: &out)
            out.append(UInt8(ascii: "}"))
        case .array(let items):
            if items.isEmpty {
                out.append(contentsOf: Array("[]".utf8))
                return
            }
            out.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                newline(level + 1, into: &out)
                write(item, level: level + 1, into: &out)
            }
            newline(level, into: &out)
            out.append(UInt8(ascii: "]"))
        case .string(let text):
            writeString(text, into: &out)
        case .number(let text):
            out.append(contentsOf: Array(text.utf8))
        case .bool(let flag):
            out.append(contentsOf: Array((flag ? "true" : "false").utf8))
        case .null:
            out.append(contentsOf: Array("null".utf8))
        }
    }

    private static func newline(_ level: Int, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\n"))
        out.append(contentsOf: repeatElement(UInt8(ascii: " "), count: 2 * level))
    }

    /// Échappements de Python avec `ensure_ascii=False` : `"`, `\`, les caractères de contrôle ;
    /// ni `/` ni le non-ASCII.
    private static func writeString(_ text: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out.append(contentsOf: Array("\\\"".utf8))
            case UInt8(ascii: "\\"): out.append(contentsOf: Array("\\\\".utf8))
            case 0x0A: out.append(contentsOf: Array("\\n".utf8))
            case 0x0D: out.append(contentsOf: Array("\\r".utf8))
            case 0x09: out.append(contentsOf: Array("\\t".utf8))
            case 0x08: out.append(contentsOf: Array("\\b".utf8))
            case 0x0C: out.append(contentsOf: Array("\\f".utf8))
            case 0x00..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                out.append(contentsOf: Array("\\u00".utf8))
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            default:
                out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

extension OrderedJSON: Equatable {
    /// Égalité stricte : même ordre des clés, mêmes textes de nombres, chaînes comparées point de code par point de code.
    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { sameKey($0.key, $1.key) && $0.value == $1.value }
        case let (.array(a), .array(b)):
            return a == b
        case let (.string(a), .string(b)):
            return sameKey(a, b)
        case let (.number(a), .number(b)):
            return a == b
        case let (.bool(a), .bool(b)):
            return a == b
        case (.null, .null):
            return true
        default:
            return false
        }
    }
}

// MARK: - Analyseur

private struct Parser {
    let bytes: [UInt8]
    var index = 0
    private static let maxDepth = 512

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> OrderedJSON {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { throw error(L("BOM UTF-8 inattendu"), at: 0) }
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw error(L("texte qui n'est pas de l'UTF-8 valide"), at: 0)
        }
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw error(L("contenu en trop après la valeur")) }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> OrderedJSON {
        guard depth < Self.maxDepth else { throw error(L("imbrication trop profonde")) }
        guard index < bytes.count else { throw error(L("valeur attendue")) }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "n"): return try literal("null", .null)
        // Python accepte NaN et Infinity (hors norme) et les réécrit tels quels.
        case UInt8(ascii: "N"): return try literal("NaN", .number("NaN"))
        case UInt8(ascii: "I"): return try literal("Infinity", .number("Infinity"))
        case UInt8(ascii: "-") where matches("-Infinity"): return try literal("-Infinity", .number("-Infinity"))
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw error(L("valeur attendue"))
        }
    }

    private mutating func parseObject(depth: Int) throws -> OrderedJSON {
        index += 1
        var members: [OrderedJSON.Member] = []
        // Clé en double : la dernière valeur gagne, à la place de la première (comme un dict Python).
        var positions: [[UInt8]: Int] = [:]
        skipWhitespace()
        if peek == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            guard peek == UInt8(ascii: "\"") else { throw error(L("clé entre guillemets attendue")) }
            let keyBytes = try parseStringBytes()
            let key = String(decoding: keyBytes, as: UTF8.self)
            skipWhitespace()
            guard peek == UInt8(ascii: ":") else { throw error(L("« : » attendu")) }
            index += 1
            skipWhitespace()
            let value = try parseValue(depth: depth + 1)
            if let position = positions[keyBytes] {
                members[position].value = value
            } else {
                positions[keyBytes] = members.count
                members.append(OrderedJSON.Member(key: key, value: value))
            }
            skipWhitespace()
            switch peek {
            case UInt8(ascii: ","):
                index += 1
                skipWhitespace()
            case UInt8(ascii: "}"):
                index += 1
                return .object(members)
            default:
                throw error(L("« , » ou « } » attendu"))
            }
        }
    }

    private mutating func parseArray(depth: Int) throws -> OrderedJSON {
        index += 1
        var items: [OrderedJSON] = []
        skipWhitespace()
        if peek == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            switch peek {
            case UInt8(ascii: ","):
                index += 1
                skipWhitespace()
            case UInt8(ascii: "]"):
                index += 1
                return .array(items)
            default:
                throw error(L("« , » ou « ] » attendu"))
            }
        }
    }

    private mutating func parseString() throws -> String {
        String(decoding: try parseStringBytes(), as: UTF8.self)
    }

    /// Octets UTF-8 de la chaîne, échappements résolus. Un caractère de contrôle brut est refusé (mode strict
    /// de Python) ; une moitié de paire de substitution isolée aussi (Swift ne sait pas la représenter).
    private mutating func parseStringBytes() throws -> [UInt8] {
        let start = index
        index += 1
        var out: [UInt8] = []
        while true {
            guard index < bytes.count else { throw error(L("chaîne non terminée"), at: start) }
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return out
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw error(L("chaîne non terminée"), at: start) }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    out.append(contentsOf: Array(String(try parseUnicodeEscape()).utf8))
                default:
                    throw error(L("échappement invalide"), at: index - 2)
                }
            case 0x00..<0x20:
                throw error(L("caractère de contrôle dans une chaîne"))
            default:
                out.append(byte)
                index += 1
            }
        }
    }

    /// `\uXXXX` déjà entamé (après le `u`), paire de substitution comprise.
    private mutating func parseUnicodeEscape() throws -> Character {
        let escapeStart = index - 2
        let first = try hex4()
        var code = first
        if (0xD800...0xDBFF).contains(first) {
            guard matches("\\u") else { throw error(L("moitié de paire de substitution isolée"), at: escapeStart) }
            index += 2
            let second = try hex4()
            guard (0xDC00...0xDFFF).contains(second) else {
                throw error(L("moitié de paire de substitution isolée"), at: escapeStart)
            }
            code = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
        } else if (0xDC00...0xDFFF).contains(first) {
            throw error(L("moitié de paire de substitution isolée"), at: escapeStart)
        }
        guard let scalar = Unicode.Scalar(code) else { throw error(L("échappement \\u invalide"), at: escapeStart) }
        return Character(scalar)
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error(L("échappement \\u incomplet")) }
        var value: UInt32 = 0
        for byte in bytes[index..<index + 4] {
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw error(L("échappement \\u invalide"))
            }
            value = value << 4 | UInt32(digit)
        }
        index += 4
        return value
    }

    /// Grammaire de Python : `-?(0|[1-9]\d*)(\.\d+)?([eE][-+]?\d+)?`, texte gardé tel quel.
    private mutating func parseNumber() throws -> OrderedJSON {
        let start = index
        if peek == UInt8(ascii: "-") { index += 1 }
        if peek == UInt8(ascii: "0") {
            index += 1
        } else if isDigit(peek) {
            while isDigit(peek) { index += 1 }
        } else {
            throw error(L("nombre invalide"), at: start)
        }
        if peek == UInt8(ascii: "."), index + 1 < bytes.count, isDigit(bytes[index + 1]) {
            index += 1
            while isDigit(peek) { index += 1 }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            var probe = index + 1
            if probe < bytes.count, bytes[probe] == UInt8(ascii: "+") || bytes[probe] == UInt8(ascii: "-") { probe += 1 }
            if probe < bytes.count, isDigit(bytes[probe]) {
                index = probe
                while isDigit(peek) { index += 1 }
            }
        }
        return .number(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    private mutating func literal(_ word: String, _ value: OrderedJSON) throws -> OrderedJSON {
        guard matches(word) else { throw error(L("valeur attendue")) }
        index += word.utf8.count
        return value
    }

    private func matches(_ word: String) -> Bool {
        let expected = Array(word.utf8)
        return index + expected.count <= bytes.count && Array(bytes[index..<index + expected.count]) == expected
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    private func isDigit(_ byte: UInt8?) -> Bool {
        guard let byte else { return false }
        return byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    /// Espaces de la norme JSON uniquement (comme Python) : espace, tabulation, retour chariot, saut de ligne.
    private mutating func skipWhitespace() {
        while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
    }

    private func error(_ message: String, at offset: Int? = nil) -> OrderedJSON.ParseError {
        let position = min(offset ?? index, bytes.count)
        var line = 1
        var lineStart = 0
        for (offset, byte) in bytes[0..<position].enumerated() where byte == 0x0A {
            line += 1
            lineStart = offset + 1
        }
        let column = String(decoding: bytes[lineStart..<position], as: UTF8.self).count + 1
        return OrderedJSON.ParseError(message: message, line: line, column: column)
    }
}
