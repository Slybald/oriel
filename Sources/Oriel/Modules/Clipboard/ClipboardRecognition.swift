import Foundation
import ImageIO
import Vision

// Reconnaissances faites à la demande sur une copie : couleur écrite en texte, texte d'une image, QR code.
// Tout se passe sur le Mac (framework Vision, aucune permission, aucun réseau) ; rien n'est journalisé.

/// Couleur sRGB reconnue dans un texte ou venue d'un sélecteur de couleur.
struct ClipboardRGB: Equatable {
    var red: Int
    var green: Int
    var blue: Int

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var css: String { "rgb(\(red), \(green), \(blue))" }

    /// Reconnus, le texte entier seulement : « #RGB », « #RRGGBB » et « rgb(r, g, b) » (entiers de 0 à 255).
    /// Pas reconnus : avec transparence (« #RRGGBBAA », « rgba() »), « hsl() », pourcentages, noms (« red »),
    /// hex sans « # ».
    static func parse(_ text: String) -> ClipboardRGB? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 40 else { return nil }
        if trimmed.hasPrefix("#") {
            let digits = Array(trimmed.dropFirst())
            guard digits.count == 3 || digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
            let expanded = digits.count == 3 ? digits.flatMap { [$0, $0] } : digits
            let value = UInt32(String(expanded), radix: 16)!
            return ClipboardRGB(red: Int(value >> 16 & 0xFF), green: Int(value >> 8 & 0xFF), blue: Int(value & 0xFF))
        }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("rgb("), lower.hasSuffix(")") else { return nil }
        let inner = lower.dropFirst(4).dropLast()
        let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard parts.count == 3 else { return nil }
        let values = parts.compactMap { part in part.allSatisfy(\.isASCII) ? Int(part) : nil }
        guard values.count == 3, values.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return ClipboardRGB(red: values[0], green: values[1], blue: values[2])
    }
}

enum ClipboardColorFormat { case hex, rgb }

extension ClipboardItem {
    /// Couleur d'un texte copié (« #FF8800 ») ou d'un sélecteur de couleur ; nil pour tout le reste.
    var recognizedColor: ClipboardRGB? {
        switch content {
        case .text(let text): return ClipboardRGB.parse(text)
        case .color(let hex): return ClipboardRGB.parse("#" + hex)
        default: return nil
        }
    }
}

/// Ce qu'on lit dans une image.
enum ClipboardImageReading { case text, qr }

enum ClipboardImageReader {
    /// Une image plus grande est réduite avant l'analyse : le temps de calcul reste borné.
    static let maxPixels = 4096

    /// Lignes lues (vide : rien trouvé ou image illisible). Synchrone et lourd : à appeler hors du fil principal.
    /// L'OCR peut se tromper sur du texte petit, flou ou manuscrit ; un QR code abîmé peut ne pas être lu.
    static func read(_ data: Data, _ reading: ClipboardImageReading) -> [String] {
        guard let image = decode(data) else { return [] }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        switch reading {
        case .text:
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            guard (try? handler.perform([request])) != nil else { return [] }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        case .qr:
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            guard (try? handler.perform([request])) != nil else { return [] }
            var seen = Set<String>()
            return (request.results ?? []).compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
        }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
