import AppKit
import CoreImage
import XCTest
@testable import Oriel

// Presse-papiers plus malin : secrets, couleurs, texte d'image et QR code. Aucune fenêtre : les images sont
// dessinées en mémoire, les secrets sont assemblés à l'exécution (jamais une vraie clé dans le dépôt).

// MARK: - Images de test

/// QR code de `text` sur fond blanc (marge incluse), en PNG.
func makeQRPNG(_ text: String, scale: CGFloat = 8) -> Data {
    let filter = CIFilter(name: "CIQRCodeGenerator")!
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let cg = CIContext().createCGImage(qr, from: qr.extent)!
    let margin = 4 * Int(scale)
    return drawPNG(width: cg.width + 2 * margin, height: cg.height + 2 * margin) { context in
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: margin, y: margin, width: cg.width, height: cg.height))
    }
}

/// Texte noir sur fond blanc, en PNG.
func makeTextPNG(_ text: String, size: CGFloat = 56) -> Data {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.black,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let box = string.size()
    return drawPNG(width: Int(box.width) + 60, height: Int(box.height) + 60) { _ in
        string.draw(at: NSPoint(x: 30, y: 30))
    }
}

private func drawPNG(width: Int, height: Int, _ body: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    body(graphics.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Tests

final class ClipboardSmartTests: XCTestCase {
    private func wait(until condition: () -> Bool, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // Valeurs assemblées : aucun jeton réel (ni ressemblant à un jeton réel pour les scanneurs) dans le source.
    private let github = "gh" + "p_" + String(repeating: "aB3dE6", count: 6)
    private let aws = "AK" + "IA" + "ABCDEFGHIJKLMNOP"
    private var openAI: String { "sk" + "-" + "proj" + "-" + String(repeating: "aB3dE6gH", count: 6) }
    private let stripe = "sk" + "_live_" + String(repeating: "x7Yz", count: 6)
    private let slack = "xo" + "xb-" + "1234567890-abcdefghijklmnop"
    private var jwt: String { "eyJhbGciOiJIUzI1NiJ9" + "." + "eyJzdWIiOiIxMjM0NTY3ODkwIn0" + "." + "dBjftJeZ4CVPmB92K27uhbUJU1p1r" }

    // MARK: Secrets : reconnus

    func testRecognisesTheListedSecrets() {
        XCTAssertEqual(SecretDetector.detect(github), .githubToken)
        XCTAssertEqual(SecretDetector.detect("export GITHUB_TOKEN=\(github)\n"), .githubToken)
        XCTAssertEqual(SecretDetector.detect(aws), .awsKey)
        XCTAssertEqual(SecretDetector.detect(openAI), .apiKey)
        XCTAssertEqual(SecretDetector.detect(stripe), .stripeKey)
        XCTAssertEqual(SecretDetector.detect(slack), .slackToken)
        XCTAssertEqual(SecretDetector.detect(jwt), .jwt)
        XCTAssertEqual(SecretDetector.detect("-----BEGIN OPENSSH PRIVATE KEY-----\nabc"), .privateKey)
        XCTAssertEqual(SecretDetector.detect("-----BEGIN PRIVATE KEY-----"), .privateKey)
    }

    func testRecognisesCardNumbersOnlyWhenTheWholeTextIsOne() {
        for number in ["4111111111111111", "4111 1111 1111 1111", "4111-1111-1111-1111", "5555 5555 5555 4444",
                       "2223003122003222", "378282246310005", "6011111111111117", "4222222222222"] {
            XCTAssertEqual(SecretDetector.detect(number), .card, number)
        }
        XCTAssertEqual(SecretDetector.detect(" 4111 1111 1111 1111\n"), .card)
        XCTAssertNil(SecretDetector.detect("ma carte : 4111 1111 1111 1111"), "avec du texte autour : non reconnu")
    }

    // MARK: Secrets : faux positifs

    func testOrdinaryTextIsNeverASecret() {
        let samples = [
            "123e4567-e89b-12d3-a456-426614174000",                                   // UUID
            "9fceb02d0ae598e95dc970b74767f19372d61af8",                               // hash git
            String(repeating: "a1b2c3d4", count: 8),                                  // SHA-256
            "Rendez-vous demain à 14 h, salle B12, apporter le dossier.",
            "https://github.com/Slybald/oriel/pull/39",
            "https://example.com/?next=sk-learn",
            "sk-learn-is-a-python-library-for-machine-learning-tasks",               // slug, pas une clé
            "ghp_court",
            "AKIA court",
            "0612345678",                                                              // téléphone
            "4111 1111 1111 1112",                                                     // Luhn invalide
            "9111 1111 1111 1118",                                                     // Luhn valide, émetteur inconnu
            "2026-11-05 14:30:00",
            "1234567890123456",
            "eyJ.eyJ.x",
            "-----BEGIN CERTIFICATE-----",                                           // un certificat est public
            String(repeating: "x", count: SecretDetector.maxCharacters + 1),
        ]
        for text in samples { XCTAssertNil(SecretDetector.detect(text), text) }
    }

    func testTheDetectorFindsADefectWhenOneIsInjected() {
        // Un contrôle qui ne trouve rien ne prouve rien : le même texte avec un jeton collé dedans est reconnu.
        let clean = "Rendez-vous demain à 14 h, salle B12."
        XCTAssertNil(SecretDetector.detect(clean))
        XCTAssertEqual(SecretDetector.detect(clean + " " + github), .githubToken)
    }

    // MARK: Couleurs

    func testRecognisesColorsWrittenAsText() {
        XCTAssertEqual(ClipboardRGB.parse("#ff8800"), ClipboardRGB(red: 255, green: 136, blue: 0))
        XCTAssertEqual(ClipboardRGB.parse(" #F80\n"), ClipboardRGB(red: 255, green: 136, blue: 0))
        XCTAssertEqual(ClipboardRGB.parse("rgb(255, 136, 0)"), ClipboardRGB(red: 255, green: 136, blue: 0))
        XCTAssertEqual(ClipboardRGB.parse("RGB(0 0 255)"), ClipboardRGB(red: 0, green: 0, blue: 255))
        XCTAssertEqual(ClipboardRGB(red: 255, green: 136, blue: 0).hex, "#FF8800")
        XCTAssertEqual(ClipboardRGB(red: 255, green: 136, blue: 0).css, "rgb(255, 136, 0)")
    }

    func testDoesNotInventColors() {
        for text in ["ff8800", "#ff88", "#gg8800", "#ff8800aa", "rgb(256, 0, 0)", "rgb(1, 2)", "rgba(1, 2, 3, 0.5)",
                     "rgb(10%, 0%, 0%)", "hsl(30, 100%, 50%)", "red", "la couleur #ff8800 est jolie", ""] {
            XCTAssertNil(ClipboardRGB.parse(text), text)
        }
    }

    func testColorPickerCopiesAreRecognisedToo() {
        let item = ClipboardItem(.color("FF8800"), date: Date())!
        XCTAssertEqual(item.recognizedColor?.css, "rgb(255, 136, 0)")
        XCTAssertNil(ClipboardItem(.text("bonjour"), date: Date())!.recognizedColor)
    }

    // MARK: Images

    func testReadsAQRCode() {
        let url = "https://example.com/oriel?x=1"
        XCTAssertEqual(ClipboardImageReader.read(makeQRPNG(url), .qr), [url])
        XCTAssertEqual(ClipboardImageReader.read(makeQRPNG("Bonjour"), .qr), ["Bonjour"])
    }

    func testNoQRCodeInAPlainImageOrInGarbage() {
        XCTAssertEqual(ClipboardImageReader.read(makeTestPNG(width: 200, height: 200), .qr), [])
        XCTAssertEqual(ClipboardImageReader.read(Data("pas une image".utf8), .qr), [])
        XCTAssertEqual(ClipboardImageReader.read(Data(), .text), [])
    }

    func testReadsTheTextOfAnImage() {
        let lines = ClipboardImageReader.read(makeTextPNG("Bonjour Oriel 2026"), .text)
        XCTAssertTrue(lines.joined(separator: " ").lowercased().contains("oriel"), "lu : \(lines)")
        XCTAssertEqual(ClipboardImageReader.read(makeTestPNG(width: 200, height: 120), .text), [])
    }

    // MARK: Module : secrets

    func testASecretIsFlaggedMaskedAndErasedOnDeadline() throws {
        let rig = try makeClipboardRig()
        rig.copy("note normale")
        rig.copy(github)
        XCTAssertEqual(rig.items.first?.secret, .githubToken)
        XCTAssertNil(rig.items.last?.secret)
        XCTAssertEqual(rig.module.pendingSecretCount, 1)

        rig.module.eraseSecret(rig.items[0].id)
        XCTAssertEqual(rig.texts, ["note normale"])
        XCTAssertEqual(rig.module.notice, .secretErased(.githubToken))
        XCTAssertEqual(rig.module.pendingSecretCount, 0)
        XCTAssertTrue(rig.pasteboard.written.isEmpty, "le presse-papiers de macOS n'est jamais touché")
    }

    func testRealTimerErasesTheSecret() throws {
        let rig = try makeClipboardRig(secretDelay: 0.05)
        rig.copy(github)
        wait(until: { rig.items.isEmpty })
        XCTAssertTrue(rig.items.isEmpty)
    }

    func testASecretNeverReachesTheDiskUnlessPinned() throws {
        let rig = try makeClipboardRig(keepsHistory: true)
        rig.copy(github)
        rig.copy("texte ordinaire")
        rig.module.flushPersistence()
        let data = try String(contentsOf: rig.file, encoding: .utf8)
        XCTAssertFalse(data.contains(github))
        XCTAssertTrue(data.contains("texte ordinaire"))
    }

    func testPinningASecretKeepsItAndCancelsTheErasure() throws {
        let rig = try makeClipboardRig()
        rig.copy(github)
        let id = rig.items[0].id
        rig.module.togglePin(id)
        XCTAssertEqual(rig.module.pendingSecretCount, 0)
        XCTAssertNil(rig.items[0].secret)
        rig.module.eraseSecret(id)
        XCTAssertEqual(rig.texts, [github])
    }

    func testRecopyingASecretRestartsItsDelayOnTheSameLine() throws {
        let rig = try makeClipboardRig()
        rig.copy(github)
        rig.copy("autre")
        rig.copy(github)
        XCTAssertEqual(rig.items.count, 2)
        XCTAssertEqual(rig.module.pendingSecretCount, 1)
    }

    func testSettingOffKeepsEverythingAndSchedulesNothing() throws {
        let rig = try makeClipboardRig()
        rig.copy(github)
        rig.module.erasesSecrets = false
        XCTAssertEqual(rig.module.pendingSecretCount, 0)
        XCTAssertNil(rig.items[0].secret)
        rig.copy(aws)
        XCTAssertEqual(rig.module.pendingSecretCount, 0)
        XCTAssertEqual(rig.texts, [aws, github])
        XCTAssertFalse(rig.defaults.bool(forKey: "clipboard.erasesSecrets"))
    }

    func testDefaultIsOn() throws {
        XCTAssertTrue(try makeClipboardRig().module.erasesSecrets)
    }

    func testStoppingTheModuleLeavesNoTimerAndNoSecret() throws {
        let rig = try makeClipboardRig()
        rig.copy(github)
        rig.module.stop()
        XCTAssertEqual(rig.module.pendingSecretCount, 0)
        XCTAssertTrue(rig.items.isEmpty)
    }

    func testOrdinaryCopiesScheduleNothing() throws {
        let rig = try makeClipboardRig()
        rig.copy("bonjour")
        rig.copy("https://www.example.com")
        rig.copy("#ff8800")
        XCTAssertEqual(rig.module.pendingSecretCount, 0)
    }

    // MARK: Module : confidentialité

    func testExcludedContentIsNeverReadNorAnalysed() throws {
        let rig = try makeClipboardRig()
        let png = makeQRPNG("secret")
        let image = ClipboardImage.make(data: png, type: "public.png")!
        rig.copy(.image(image), from: .onePassword)
        XCTAssertEqual(rig.pasteboard.contentReads, 0)
        XCTAssertTrue(rig.items.isEmpty)

        rig.apps.current = .textEdit
        rig.pasteboard.copy(.image(image), types: ["public.png", "org.nspasteboard.ConcealedType"])
        rig.module.poll()
        XCTAssertEqual(rig.pasteboard.contentReads, 0)
        XCTAssertTrue(rig.items.isEmpty)
        rig.module.readImage(UUID(), .qr)
        XCTAssertNil(rig.module.reading, "rien à lire : l'élément n'existe pas")
    }

    // MARK: Module : actions sur une copie

    func testReadsAQRCodeFromTheHistoryWithoutReadingThePasteboardAgain() throws {
        let rig = try makeClipboardRig()
        let url = "https://example.com/oriel"
        rig.copy(.image(ClipboardImage.make(data: makeQRPNG(url), type: "public.png")!))
        let reads = rig.pasteboard.contentReads
        rig.module.readImage(rig.items[0].id, .qr)
        XCTAssertNotNil(rig.module.reading)
        wait(until: { rig.module.reading == nil })
        guard case .text(let written)? = rig.pasteboard.written.last?.content else { return XCTFail("texte attendu") }
        XCTAssertEqual(written, url)
        XCTAssertEqual(rig.module.notice, .readCopied(.qr, 1))
        XCTAssertEqual(rig.pasteboard.contentReads, reads)
        // Notre propre écriture n'est pas une nouvelle copie.
        rig.module.poll()
        XCTAssertEqual(rig.items.count, 1)
    }

    func testSaysSoWhenNothingIsRead() throws {
        let rig = try makeClipboardRig()
        rig.copy(.image(makeTestImage(width: 120, height: 120)))
        rig.module.readImage(rig.items[0].id, .qr)
        wait(until: { rig.module.reading == nil })
        XCTAssertEqual(rig.module.notice, .nothingRead(.qr))
        XCTAssertTrue(rig.pasteboard.written.isEmpty, "rien n'est écrit quand rien n'est lu")
    }

    func testOnlyOneReadAtATimeAndNoneAfterStop() throws {
        let rig = try makeClipboardRig()
        rig.copy(.image(ClipboardImage.make(data: makeQRPNG("a"), type: "public.png")!))
        let id = rig.items[0].id
        rig.module.readImage(id, .qr)
        rig.module.readImage(id, .text)
        XCTAssertEqual(rig.module.notice, .reading(.qr))
        rig.module.stop()
        XCTAssertNil(rig.module.reading)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(rig.pasteboard.written.isEmpty, "résultat jeté : le module est arrêté")
    }

    func testCopiesAColorInTheChosenFormat() throws {
        let rig = try makeClipboardRig()
        rig.copy("#ff8800")
        let id = rig.items[0].id
        rig.module.copyColor(id, as: .rgb)
        guard case .text(let rgb)? = rig.pasteboard.written.last?.content else { return XCTFail("texte attendu") }
        XCTAssertEqual(rgb, "rgb(255, 136, 0)")
        rig.module.copyColor(id, as: .hex)
        guard case .text(let hex)? = rig.pasteboard.written.last?.content else { return XCTFail("texte attendu") }
        XCTAssertEqual(hex, "#FF8800")
        rig.module.poll()
        XCTAssertEqual(rig.items.count, 1, "pas de doublon")
        rig.copy("bonjour")
        rig.module.copyColor(rig.items[0].id, as: .hex)
        XCTAssertEqual(rig.pasteboard.written.count, 2, "un texte qui n'est pas une couleur ne s'écrit pas")
    }

    // MARK: Module : cas relevés à la relecture d'intégration

    func testOverdueSecretIsErasedAtTheNextTickEvenIfTheTimerSleptWithTheMac() throws {
        let rig = try makeClipboardRig()
        rig.copy(github)
        rig.clock.advance(61)
        rig.module.poll()
        XCTAssertTrue(rig.items.isEmpty, "la veille arrête le minuteur, pas la date d'échéance")
        XCTAssertEqual(rig.module.pendingSecretCount, 0)
    }

    func testRecopyingAPinnedSecretDoesNotMarkItAgain() throws {
        let rig = try makeClipboardRig()
        rig.copy(github)
        rig.module.togglePin(rig.items[0].id)
        rig.copy(github)
        XCTAssertEqual(rig.items.count, 1)
        XCTAssertNil(rig.items[0].secret, "épinglé : plus de marque « sera effacé »")
        XCTAssertEqual(rig.module.pendingSecretCount, 0)
    }

    func testRemovingTheImageDuringAReadDiscardsTheResult() throws {
        let rig = try makeClipboardRig()
        rig.copy(.image(ClipboardImage.make(data: makeQRPNG("a"), type: "public.png")!))
        let id = rig.items[0].id
        rig.module.readImage(id, .qr)
        rig.module.remove(id)
        XCTAssertNil(rig.module.reading)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(rig.pasteboard.written.isEmpty, "l'image supprimée ne réécrit rien dans le presse-papiers")
    }

    func testACopyMadeDuringAReadIsNotOverwritten() throws {
        let rig = try makeClipboardRig()
        rig.copy(.image(ClipboardImage.make(data: makeQRPNG("a"), type: "public.png")!))
        rig.module.readImage(rig.items[0].id, .qr)
        rig.pasteboard.copy("copie faite pendant la lecture")
        wait(until: { rig.module.reading == nil })
        XCTAssertTrue(rig.pasteboard.written.isEmpty)
    }
}
