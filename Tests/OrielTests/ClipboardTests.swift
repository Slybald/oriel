import AppKit
import XCTest
@testable import Oriel

// MARK: - Doubles

/// Presse-papiers factice : compte les lectures, garde les écritures. `copy` simule la copie d'une app.
final class FakePasteboard: ClipboardPasteboard {
    var changeCount = 0
    var access = ClipboardAccess.allowed
    private(set) var typesReads = 0
    private(set) var contentReads = 0
    private(set) var written: [(content: ClipboardContent, rich: ClipboardRichText?, plainText: Bool)] = []
    private var declared: [String] = []
    private var content: ClipboardContent?
    private var rich: ClipboardRichText?
    private var tooLarge = false

    var types: [String] {
        typesReads += 1
        return declared
    }

    func read() -> ClipboardRead {
        contentReads += 1
        return ClipboardRead(content: content, rich: rich, imageTooLarge: tooLarge)
    }

    func write(_ content: ClipboardContent, rich: ClipboardRichText?, plainText: Bool) -> Int {
        written.append((content, rich, plainText))
        self.content = content
        self.rich = rich
        tooLarge = false
        changeCount += 1
        return changeCount
    }

    func copy(_ content: ClipboardContent, rich: ClipboardRichText? = nil, types: [String] = ["public.utf8-plain-text"]) {
        self.content = content
        self.rich = rich
        tooLarge = false
        declared = types
        changeCount += 1
    }

    func copy(_ text: String, rich: ClipboardRichText? = nil, types: [String] = ["public.utf8-plain-text"]) {
        copy(ClipboardContent.classify(text: text), rich: rich, types: types)
    }

    /// Une image de plus de 5 Mo : le presse-papiers la signale sans la livrer.
    func copyTooLargeImage() {
        content = nil
        rich = nil
        tooLarge = true
        declared = ["public.png"]
        changeCount += 1
    }
}

final class FakeFrontApps: ClipboardFrontApps {
    var current: ClipboardSource?
    /// Apps passées devant depuis le dernier tic (en plus de l'app actuelle).
    var visited: [ClipboardSource] = []
    private(set) var starts = 0
    private(set) var stops = 0

    func start() { starts += 1 }
    func stop() { stops += 1 }

    func drain() -> [ClipboardSource] {
        let apps = visited + (current.map { [$0] } ?? [])
        visited = []
        return apps
    }
}

extension ClipboardSource {
    static let safari = ClipboardSource(bundleID: "com.apple.Safari", name: "Safari")
    static let textEdit = ClipboardSource(bundleID: "com.apple.TextEdit", name: "TextEdit")
    static let onePassword = ClipboardSource(bundleID: "com.1password.1password", name: "1Password")
    static let keychain = ClipboardSource(bundleID: "com.apple.keychainaccess", name: "Trousseaux d'accès")
}

/// Horloge réglable.
final class ClipboardClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval = 1) { now = now.addingTimeInterval(seconds) }
}

/// Module sur doubles, dossier de données et réglages jetables, démarré.
struct ClipboardRig {
    let module: ClipboardModule
    let pasteboard: FakePasteboard
    let apps: FakeFrontApps
    let storage: ClipboardStorage
    let directory: URL
    let defaults: UserDefaults
    let clock: ClipboardClock

    /// Une copie par une app, puis un tic ; l'horloge avance d'une seconde.
    func copy(_ text: String, from source: ClipboardSource? = .textEdit, rich: ClipboardRichText? = nil,
              types: [String] = ["public.utf8-plain-text"]) {
        apps.current = source
        pasteboard.copy(text, rich: rich, types: types)
        clock.advance()
        module.poll()
    }

    func copy(_ content: ClipboardContent, from source: ClipboardSource? = .textEdit) {
        apps.current = source
        pasteboard.copy(content)
        clock.advance()
        module.poll()
    }

    var items: [ClipboardItem] { module.history.items }
    var texts: [String] {
        items.compactMap { item in
            if case .text(let text) = item.content { return text }
            if case .url(let url) = item.content { return url.absoluteString }
            return nil
        }
    }
    var file: URL { storage.url }
}

extension XCTestCase {
    func makeClipboardRig(keepsHistory: Bool = false, directory: URL? = nil, defaults: UserDefaults? = nil,
                          start: Bool = true) throws -> ClipboardRig {
        let directory = try directory ?? makeTemporaryDirectory(self)
        let defaults = defaults ?? makeEphemeralDefaults(self)
        if keepsHistory { defaults.set(true, forKey: "clipboard.keepsHistory") }
        let pasteboard = FakePasteboard()
        let apps = FakeFrontApps()
        let storage = ClipboardStorage(directory: directory)
        let clock = ClipboardClock()
        let module = ClipboardModule(defaults: defaults, pasteboard: pasteboard, frontApps: apps, storage: storage,
                                     clock: { clock.now }, saveDelay: 0.05)
        if start { module.start() }
        addTeardownBlock { module.stop() }
        return ClipboardRig(module: module, pasteboard: pasteboard, apps: apps, storage: storage, directory: directory,
                            defaults: defaults, clock: clock)
    }
}

/// PNG de test : dégradé, ou bruit (incompressible, donc lourd).
func makeTestPNG(width: Int, height: Int, noise: Bool = false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let pixels = rep.bitmapData!
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * rep.bytesPerRow + x * 4
            if noise {
                for channel in 0..<4 { pixels[offset + channel] = channel == 3 ? 255 : UInt8.random(in: 0...255) }
            } else {
                pixels[offset] = UInt8(255 * x / max(width - 1, 1))
                pixels[offset + 1] = UInt8(255 * y / max(height - 1, 1))
                pixels[offset + 2] = 160
                pixels[offset + 3] = 255
            }
        }
    }
    return rep.representation(using: .png, properties: [:])!
}

func makeTestImage(width: Int = 80, height: Int = 50) -> ClipboardImage {
    ClipboardImage.make(data: makeTestPNG(width: width, height: height), type: "public.png")!
}

// MARK: - Tests

final class ClipboardTests: XCTestCase {
    private func wait(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: Capture

    func testCapturesTextAndLinksNewestFirstWithTheirSource() throws {
        let rig = try makeClipboardRig()
        rig.copy("premier")
        rig.copy("https://www.example.com/page?x=1", from: .safari)
        rig.copy("troisième")
        XCTAssertEqual(rig.texts, ["troisième", "https://www.example.com/page?x=1", "premier"])
        guard case .url(let url) = rig.items[1].content else { return XCTFail("un lien est attendu") }
        XCTAssertEqual(url.host, "www.example.com")
        XCTAssertEqual(rig.items[1].source, .safari)
        XCTAssertEqual(rig.items[0].source, .textEdit)
        XCTAssertGreaterThan(rig.items[0].date, rig.items[2].date)
    }

    func testNothingButTheChangeCountIsReadWhenNothingChanged() throws {
        let rig = try makeClipboardRig()
        rig.copy("a")
        let (types, contents) = (rig.pasteboard.typesReads, rig.pasteboard.contentReads)
        for _ in 0..<5 { rig.module.poll() }
        XCTAssertEqual(rig.pasteboard.typesReads, types)
        XCTAssertEqual(rig.pasteboard.contentReads, contents)
        XCTAssertEqual(rig.items.count, 1)
    }

    func testStartingDoesNotCaptureWhatWasAlreadyInThePasteboard() throws {
        let rig = try makeClipboardRig(start: false)
        rig.pasteboard.copy("déjà là")
        rig.module.start()
        rig.module.poll()
        XCTAssertTrue(rig.items.isEmpty)
        XCTAssertEqual(rig.pasteboard.contentReads, 0)
    }

    func testBlankTextIsIgnored() throws {
        let rig = try makeClipboardRig()
        rig.copy("  \n\t ")
        rig.copy("")
        XCTAssertTrue(rig.items.isEmpty)
    }

    func testOnlyWebLinksBecomeLinks() {
        func isLink(_ text: String) -> Bool {
            if case .url = ClipboardContent.classify(text: text) { return true }
            return false
        }
        XCTAssertTrue(isLink("https://example.com"))
        XCTAssertTrue(isLink("  http://example.com/a/b?c=d#e \n"))
        XCTAssertFalse(isLink("voir https://example.com"))
        XCTAssertFalse(isLink("mailto:moi@example.com"))
        XCTAssertFalse(isLink("https://"))
        XCTAssertFalse(isLink("example.com"))
        XCTAssertFalse(isLink("https://example.com\nhttps://example.org"))
    }

    // MARK: Confidentialité

    func testEveryIgnoredTypeIsNeverRecordedNorRead() throws {
        let rig = try makeClipboardRig()
        let types = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                     "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
                     "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping", "Pasteboard generator type"]
        XCTAssertEqual(ClipboardPrivacy.ignoredTypes.count, types.count)
        for type in types {
            rig.copy("mot de passe \(type)", types: ["public.utf8-plain-text", type])
            XCTAssertTrue(rig.items.isEmpty, type)
        }
        // Casse différente : un type est un identifiant sans casse.
        rig.copy("secret", types: ["ORG.NSPasteboard.ConcealedType"])
        XCTAssertTrue(rig.items.isEmpty)
        XCTAssertEqual(rig.pasteboard.contentReads, 0, "le contenu d'un élément ignoré n'est jamais lu")
        // Un élément sans ces types passe.
        rig.copy("normal")
        XCTAssertEqual(rig.texts, ["normal"])
    }

    func testExcludedAppsAreNeverRecordedNorRead() throws {
        let rig = try makeClipboardRig()
        let ids = ["com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
                   "com.agilebits.onepassword7", "com.bitwarden.desktop", "org.keepassxc.keepassxc"]
        for id in ids {
            XCTAssertTrue(rig.module.excludedApps.contains(id), id)
            rig.copy("secret", from: ClipboardSource(bundleID: id, name: id))
        }
        XCTAssertTrue(rig.module.excludedApps.contains { $0.lowercased().contains("dashlane") })
        XCTAssertTrue(rig.items.isEmpty)
        XCTAssertEqual(rig.pasteboard.contentReads, 0)
        // Comparaison sans casse.
        rig.copy("secret", from: ClipboardSource(bundleID: "COM.1PASSWORD.1PASSWORD", name: "x"))
        XCTAssertTrue(rig.items.isEmpty)
        rig.copy("public", from: .safari)
        XCTAssertEqual(rig.texts, ["public"])
    }

    /// Copie dans le gestionnaire de mots de passe puis changement d'app avant le tic suivant : ignorée.
    func testACopyBeforeSwitchingAwayFromAnExcludedAppIsIgnored() throws {
        let rig = try makeClipboardRig()
        rig.apps.visited = [.keychain]
        rig.copy("secret", from: .safari)
        XCTAssertTrue(rig.items.isEmpty)
        rig.copy("suite", from: .safari)
        XCTAssertEqual(rig.texts, ["suite"], "l'intervalle suivant n'est plus concerné")
    }

    /// Copie dans Safari puis Cmd-Tab vers TextEdit avant le tic : la copie vient de Safari, l'app de devant au
    /// début de l'intervalle (copier puis changer d'app est le geste courant ; l'inverse prend plus d'une seconde).
    func testASwitchRightAfterACopyKeepsTheAppThatCopied() throws {
        let rig = try makeClipboardRig()
        rig.apps.visited = [.safari]
        rig.copy("depuis safari", from: .textEdit)
        XCTAssertEqual(rig.items[0].source, .safari)
        rig.copy("sans changement", from: .textEdit)
        XCTAssertEqual(rig.items[0].source, .textEdit)
    }

    func testExcludedAppsAreEditableAndRemembered() throws {
        let rig = try makeClipboardRig()
        rig.module.exclude("com.example.coffre")
        rig.module.exclude("COM.EXAMPLE.COFFRE")
        XCTAssertEqual(rig.module.excludedApps.filter { $0.lowercased() == "com.example.coffre" }.count, 1)
        rig.copy("secret", from: ClipboardSource(bundleID: "com.example.coffre", name: "Coffre"))
        XCTAssertTrue(rig.items.isEmpty)

        rig.module.excludedApps.removeAll { $0 == "com.example.coffre" }
        rig.copy("ok", from: ClipboardSource(bundleID: "com.example.coffre", name: "Coffre"))
        XCTAssertEqual(rig.texts, ["ok"])

        rig.module.excludedApps = ["com.example.seul"]
        let again = try makeClipboardRig(defaults: rig.defaults)
        XCTAssertEqual(again.module.excludedApps, ["com.example.seul"])
        again.module.resetExcludedApps()
        XCTAssertEqual(again.module.excludedApps, ClipboardPrivacy.defaultExcludedApps.map(\.id))
    }

    // MARK: Doublons et recopie

    func testSameContentMovesToTheTopWithoutDuplicate() throws {
        let rig = try makeClipboardRig()
        rig.copy("a")
        rig.copy("b")
        let firstID = rig.items[1].id
        rig.copy("a", from: .safari)
        XCTAssertEqual(rig.texts, ["a", "b"])
        XCTAssertEqual(rig.items[0].id, firstID, "même élément, pas un nouveau")
        XCTAssertEqual(rig.items[0].source, .safari)
    }

    func testRecopyingFromTheListIsNotCapturedAgainAndMovesToTheTop() throws {
        let rig = try makeClipboardRig()
        rig.copy("un")
        rig.copy("deux")
        rig.copy("trois")
        let oldest = rig.items[2]
        rig.module.copy(oldest.id)
        XCTAssertEqual(rig.pasteboard.written.count, 1)
        XCTAssertEqual(rig.pasteboard.written[0].content.key, oldest.content.key)
        XCTAssertFalse(rig.pasteboard.written[0].plainText)
        rig.module.poll()
        XCTAssertEqual(rig.texts, ["un", "trois", "deux"], "remonté en tête, sans doublon")
        XCTAssertEqual(rig.items[0].id, oldest.id)
        XCTAssertEqual(rig.pasteboard.contentReads, 3, "la recopie n'est pas relue")
        XCTAssertEqual(rig.module.copiedID, oldest.id)

        // Une copie d'une autre app juste après est bien capturée.
        rig.copy("quatre")
        XCTAssertEqual(rig.texts.first, "quatre")
    }

    func testCopiedFeedbackDisappears() throws {
        let rig = try makeClipboardRig()
        rig.copy("a")
        rig.module.copy(rig.items[0].id)
        XCTAssertNotNil(rig.module.copiedID)
        wait(until: { rig.module.copiedID == nil }, timeout: ClipboardModule.copiedFeedback + 1)
        XCTAssertNil(rig.module.copiedID)
    }

    func testPlainTextCopyOfEachKind() throws {
        let rig = try makeClipboardRig()
        let image = makeTestImage()
        rig.copy(ClipboardContent.url(URL(string: "https://example.com/a")!))
        rig.copy(.files([URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]))
        rig.copy(.color("D97757"))
        rig.copy(.image(image))
        XCTAssertEqual(rig.items.map { $0.content.plainText },
                       [nil, "#D97757", "/tmp/a.txt\n/tmp/b.txt", "https://example.com/a"])
        rig.module.copy(rig.items[3].id, plainText: true)
        XCTAssertEqual(rig.pasteboard.written.last?.plainText, true)
    }

    // MARK: Plafond et épinglés

    func testLimitKeepsTheNewestAndPinnedItemsAreNeverEvicted() throws {
        let rig = try makeClipboardRig()
        XCTAssertEqual(rig.module.limit, 50)
        rig.module.limit = 25
        rig.copy("épinglé")
        let pinned = rig.items[0].id
        rig.module.togglePin(pinned)
        for index in 0..<40 { rig.copy("texte \(index)") }
        XCTAssertEqual(rig.items.count, 26, "25 non épinglés + l'épinglé")
        XCTAssertTrue(rig.items.contains { $0.id == pinned })
        XCTAssertEqual(rig.texts.first, "texte 39")
        XCTAssertFalse(rig.texts.contains("texte 14"))
        XCTAssertTrue(rig.texts.contains("texte 15"))
        // Épinglés d'abord à l'affichage, le reste du plus récent au plus ancien.
        let ordered = rig.module.history.ordered
        XCTAssertEqual(ordered.first?.id, pinned)
        XCTAssertEqual(ordered[1].content.plainText, "texte 39")
    }

    func testLoweringTheLimitTrimsAndUnpinningRespectsTheLimit() throws {
        let rig = try makeClipboardRig()
        for index in 0..<60 { rig.copy("t\(index)") }
        XCTAssertEqual(rig.items.count, 50)
        rig.module.limit = 25
        XCTAssertEqual(rig.items.count, 25)
        XCTAssertEqual(rig.defaults.integer(forKey: "clipboard.limit"), 25)

        rig.copy("à garder")
        rig.module.togglePin(rig.items[0].id)
        for index in 0..<30 { rig.copy("u\(index)") }
        XCTAssertEqual(rig.items.count, 26)
        rig.clock.advance()
        rig.module.togglePin(rig.module.history.ordered[0].id)
        XCTAssertEqual(rig.items.count, 25, "désépingler ne dépasse pas le plafond")
        XCTAssertEqual(rig.texts.first, "à garder", "l'élément désépinglé remonte en tête : il n'est pas évincé")
        XCTAssertFalse(rig.texts.contains("u5"), "c'est le plus ancien des autres qui part")
        XCTAssertGreaterThan(rig.items[0].date, rig.items[1].date)

        rig.module.limit = 7
        XCTAssertEqual(rig.module.limit, 50, "valeur inconnue : retour au défaut")
    }

    func testRemoveAndClear() throws {
        let rig = try makeClipboardRig()
        rig.copy("a")
        rig.copy("b")
        rig.copy("c")
        rig.module.togglePin(rig.items[2].id)
        rig.module.remove(rig.items[0].id)
        XCTAssertEqual(rig.texts, ["b", "a"])
        rig.module.clearHistory()
        XCTAssertTrue(rig.items.isEmpty, "épinglés compris")
    }

    func testUnpinningAVeryOldItemDoesNotDeleteIt() throws {
        let rig = try makeClipboardRig()
        rig.copy("à garder")
        rig.module.togglePin(rig.items[0].id)
        for index in 0..<50 { rig.copy("t\(index)") }
        XCTAssertEqual(rig.items.count, 51, "50 non épinglés + l'épinglé")
        let kept = try XCTUnwrap(rig.items.first { $0.content.plainText == "à garder" })
        rig.clock.advance()
        rig.module.togglePin(kept.id)
        XCTAssertEqual(rig.items.count, 50)
        XCTAssertEqual(rig.texts.first, "à garder", "désépinglé, il redevient le plus récent")
        XCTAssertFalse(rig.texts.contains("t0"), "le plus ancien des autres part, pas l'élément choisi")
        XCTAssertFalse(rig.items[0].pinned)
        XCTAssertGreaterThan(rig.items[0].date, rig.items[1].date)
    }

    // MARK: Types de contenu

    func testLongTextIsCutAtTwentyThousandCharacters() throws {
        let rig = try makeClipboardRig()
        rig.copy(String(repeating: "é", count: 25_000))
        guard case .text(let text) = rig.items[0].content else { return XCTFail("texte attendu") }
        XCTAssertEqual(text.count, 20_000)
        XCTAssertTrue(rig.items[0].truncated)

        rig.copy(String(repeating: "e", count: 20_000))
        XCTAssertFalse(rig.items[0].truncated, "pile 20 000 : rien n'est coupé")
        // Les caractères composés comptent pour un.
        rig.copy(String(repeating: "👩🏽‍💻", count: 20_001))
        XCTAssertTrue(rig.items[0].truncated)
        guard case .text(let emoji) = rig.items[0].content else { return XCTFail("texte attendu") }
        XCTAssertEqual(emoji.count, 20_000)
    }

    func testAHugeLinkIsCutLikeAnyText() throws {
        let rig = try makeClipboardRig()
        let link = "https://example.com/" + String(repeating: "a", count: 100_000)
        rig.copy(link)
        guard case .text(let text) = rig.items[0].content else { return XCTFail("trop long pour un lien : du texte") }
        XCTAssertEqual(text.count, ClipboardItem.maxTextCharacters)
        XCTAssertTrue(rig.items[0].truncated)
        rig.copy("https://example.com/" + String(repeating: "b", count: 100))
        guard case .url = rig.items[0].content else { return XCTFail("un lien court reste un lien") }
        XCTAssertFalse(rig.items[0].truncated)
    }

    func testImagesAreKeptUpToFiveMegabytesAndLargerOnesAreIgnored() throws {
        let rig = try makeClipboardRig()
        let small = makeTestPNG(width: 300, height: 200)
        let image = try XCTUnwrap(ClipboardImage.make(data: small, type: "public.png"))
        XCTAssertEqual(image.pixelSize, CGSize(width: 300, height: 200))
        XCTAssertLessThanOrEqual(max(image.thumbnail.size.width, image.thumbnail.size.height), 96)
        XCTAssertEqual(image.data, small, "données d'origine gardées")
        rig.copy(.image(image))
        XCTAssertEqual(rig.items.count, 1)
        rig.copy(.image(image))
        XCTAssertEqual(rig.items.count, 1, "même image : pas de doublon")

        let heavy = Data(count: ClipboardImage.maxBytes + 1)
        XCTAssertNil(ClipboardImage.make(data: heavy, type: "public.png"))
        XCTAssertNil(ClipboardImage.make(data: Data("pas une image".utf8), type: "public.png"))
        let forced = ClipboardImage(data: heavy, type: "public.png", thumbnail: image.thumbnail,
                                    pixelSize: image.pixelSize, digest: "x")
        rig.copy(.image(forced))
        XCTAssertEqual(rig.items.count, 1, "au-delà de 5 Mo l'image est ignorée")
    }

    func testImageBudgetEvictsTheOldestUnpinnedImages() throws {
        // Des images fictives de 4 Mo : dix dépassent le budget de 40 Mo.
        let thumbnail = makeTestImage().thumbnail
        func fake(_ index: Int) -> ClipboardContent {
            .image(ClipboardImage(data: Data(count: 4 * 1_048_576), type: "public.png", thumbnail: thumbnail,
                                  pixelSize: CGSize(width: 10, height: 10), digest: "d\(index)"))
        }
        var history = ClipboardHistory()
        let start = Date()
        for index in 0..<11 {
            let item = try XCTUnwrap(ClipboardItem(fake(index), date: start.addingTimeInterval(Double(index))))
            history.add(item, limit: 50)
            if index == 0 { history.togglePin(item.id, limit: 50, at: start.addingTimeInterval(Double(index))) }
        }
        let bytes = history.items.reduce(0) { $0 + $1.content.imageBytes }
        XCTAssertLessThanOrEqual(bytes, ClipboardHistory.imageBudget)
        XCTAssertEqual(history.items.count, 10)
        XCTAssertTrue(history.items.contains { $0.pinned }, "l'image épinglée reste")
        XCTAssertFalse(history.items.contains { $0.content.key == "i:d1" }, "la plus ancienne non épinglée est partie")
    }

    func testFilesAndColors() throws {
        let rig = try makeClipboardRig()
        rig.copy(.files([]))
        XCTAssertTrue(rig.items.isEmpty)
        rig.copy(.files([URL(fileURLWithPath: "/tmp/a.txt")]))
        rig.copy(.files([URL(fileURLWithPath: "/tmp/a.txt")]))
        rig.copy(.color("112233"))
        XCTAssertEqual(rig.items.count, 2)
    }

    // MARK: Mise en forme (RTF, HTML)

    private let rtf = Data(#"{\rtf1\ansi {\b gras} et normal}"#.utf8)
    private let html = Data("<b>gras</b> et normal".utf8)

    func testFormattedTextIsRestoredByCopyAndDroppedByPlainCopy() throws {
        let rig = try makeClipboardRig()
        let rich = ClipboardRichText(rtf: rtf, html: html)
        rig.copy("gras et normal", rich: rich)
        XCTAssertEqual(rig.items[0].rich, rich)
        XCTAssertTrue(rig.items[0].offersPlainCopy)

        rig.module.copy(rig.items[0].id)
        XCTAssertEqual(rig.pasteboard.written.last?.rich, rich, "Copier restitue la mise en forme")
        XCTAssertEqual(rig.pasteboard.written.last?.plainText, false)
        rig.module.copy(rig.items[0].id, plainText: true)
        XCTAssertEqual(rig.pasteboard.written.last?.plainText, true, "Copier en texte brut est une écriture à part")
    }

    func testPlainCopyIsOfferedOnlyWhenItChangesSomething() throws {
        let rig = try makeClipboardRig()
        rig.copy("texte nu")
        XCTAssertFalse(rig.items[0].offersPlainCopy, "un texte sans mise en forme : identique à Copier")
        rig.copy("https://example.com/a")
        XCTAssertTrue(rig.items[0].offersPlainCopy, "un lien : l'adresse seule, sans objet lien")
        rig.copy(.color("112233"))
        XCTAssertTrue(rig.items[0].offersPlainCopy)
        rig.copy(.image(makeTestImage()))
        XCTAssertFalse(rig.items[0].offersPlainCopy)
    }

    func testRichTextIsBoundedAndNeverKeptForCutTextOrOtherKinds() throws {
        XCTAssertNil(ClipboardRichText.make(rtf: nil, html: nil))
        XCTAssertNil(ClipboardRichText.make(rtf: Data(), html: Data()))
        let heavy = Data(count: ClipboardRichText.maxBytes + 1)
        XCTAssertNil(ClipboardRichText.make(rtf: heavy, html: heavy), "au-delà de 100 Ko : texte seul")
        let light = ClipboardRichText.make(rtf: rtf, html: heavy)
        XCTAssertEqual(light?.rtf, rtf)
        XCTAssertNil(light?.html, "le budget de 100 Ko vaut pour les deux ensemble")

        let rig = try makeClipboardRig()
        let rich = ClipboardRichText(rtf: rtf, html: nil)
        rig.copy(String(repeating: "x", count: 20_500), rich: rich)
        XCTAssertTrue(rig.items[0].truncated)
        XCTAssertNil(rig.items[0].rich, "la mise en forme d'un texte coupé ne correspondrait plus")
        let item = try XCTUnwrap(ClipboardItem(.color("112233"), date: Date(), rich: rich))
        XCTAssertNil(item.rich)
    }

    func testCopyingTheSameTextAgainReplacesItsFormatting() throws {
        let rig = try makeClipboardRig()
        rig.copy("gras et normal", rich: ClipboardRichText(rtf: rtf, html: nil))
        rig.copy("gras et normal")
        XCTAssertEqual(rig.items.count, 1)
        XCTAssertNil(rig.items[0].rich, "la dernière copie fait foi")
    }

    func testFormattingIsNeverWrittenToDisk() throws {
        let rig = try makeClipboardRig(keepsHistory: true)
        rig.copy("gras et normal", rich: ClipboardRichText(rtf: rtf, html: html))
        rig.module.flushPersistence()
        let raw = try String(contentsOf: rig.file, encoding: .utf8)
        XCTAssertTrue(raw.contains("gras et normal"))
        XCTAssertFalse(raw.contains("rtf") || raw.contains("html") || raw.contains("<b>"))
    }

    // MARK: Accès au presse-papiers (macOS 15.4 et après)

    func testTheAccessMacOSGrantsIsReadAtStartAndAtEachCopy() throws {
        let rig = try makeClipboardRig(start: false)
        rig.pasteboard.access = .denied
        rig.module.start()
        XCTAssertEqual(rig.module.access, .denied)
        rig.pasteboard.access = .ask
        rig.module.poll()
        XCTAssertEqual(rig.module.access, .denied, "rien n'est relu tant qu'aucune copie n'a lieu")
        rig.copy("a")
        XCTAssertEqual(rig.module.access, .ask)
        rig.pasteboard.access = .allowed
        rig.module.refreshAccess()
        XCTAssertEqual(rig.module.access, .allowed)
        XCTAssertNil(rig.module.access.message)
        XCTAssertNotNil(ClipboardAccess.ask.message)
        XCTAssertNotNil(ClipboardAccess.denied.message)
    }

    func testTheAccessNoticeShowsTheRefusalAlwaysAndTheAlertUntilSomethingWasKept() {
        let show = ClipboardPanel.showsAccessNotice
        XCTAssertFalse(show(.allowed, false))
        XCTAssertTrue(show(.denied, false))
        XCTAssertTrue(show(.denied, true))
        XCTAssertTrue(show(.ask, false))
        XCTAssertFalse(show(.ask, true), "des copies ont été gardées : l'alerte est réglée")
    }

    func testTheRealPasteboardReportsAccessAllowedOnAPrivatePasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("oriel-access-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        XCTAssertEqual(SystemPasteboard(pasteboard: pasteboard).access, .allowed)
    }

    // MARK: Retours à l'utilisateur

    func testAnImageOverFiveMegabytesLeavesANoticeUntilTheNextKeptCopy() throws {
        let rig = try makeClipboardRig()
        rig.copy("avant")
        rig.apps.current = .textEdit
        rig.pasteboard.copyTooLargeImage()
        rig.clock.advance()
        rig.module.poll()
        XCTAssertEqual(rig.module.notice, .imageTooLarge)
        XCTAssertEqual(rig.texts, ["avant"], "rien n'est gardé")

        rig.module.dismissNotice()
        XCTAssertNil(rig.module.notice)
        rig.pasteboard.copyTooLargeImage()
        rig.module.poll()
        XCTAssertEqual(rig.module.notice, .imageTooLarge)
        rig.copy("  ")
        XCTAssertEqual(rig.module.notice, .imageTooLarge, "un texte vide n'efface pas l'explication")
        rig.copy("après")
        XCTAssertNil(rig.module.notice, "une copie gardée l'efface")
    }

    func testStoppingTheModuleDropsTheHistoryFromMemoryButNotWhenOnlyCapturePaused() throws {
        let rig = try makeClipboardRig()
        rig.copy("a")
        rig.copy(.image(makeTestImage()))
        rig.module.stop()
        XCTAssertTrue(rig.items.isEmpty, "désactivé : plus rien en mémoire")
        rig.module.start()
        XCTAssertTrue(rig.items.isEmpty)
        rig.copy("b")
        XCTAssertEqual(rig.texts, ["b"])

        // Capture suspendue : le repli panneau fermé n'efface rien.
        rig.module.suspended = true
        rig.module.stop()
        XCTAssertEqual(rig.texts, ["b"])
    }

    func testStoppingAndRestartingBringsTheSavedHistoryBack() throws {
        let rig = try makeClipboardRig(keepsHistory: true)
        rig.copy("sur disque")
        rig.copy(.image(makeTestImage()))
        rig.module.stop()
        XCTAssertTrue(rig.items.isEmpty)
        rig.module.start()
        XCTAssertEqual(rig.texts, ["sur disque"], "le fichier est relu à la réactivation ; l'image, jamais écrite, est perdue")
        rig.copy("neuf")
        rig.module.flushPersistence()
        XCTAssertEqual(rig.storage.load().map(\.value), ["neuf", "sur disque"], "le fichier n'a pas été vidé par l'arrêt")
    }

    // MARK: Recherche

    func testSearchIsInstantCaseAndAccentInsensitiveAndAllWordsMustMatch() throws {
        let rig = try makeClipboardRig()
        rig.copy("Réunion équipe lundi")
        rig.copy("https://swift.org/documentation", from: .safari)
        rig.copy(.files([URL(fileURLWithPath: "/tmp/Rapport final.pdf")]))
        func search(_ query: String) -> [String] {
            ClipboardHistory.filter(rig.module.history.ordered, query: query).map { $0.content.plainText ?? "" }
        }
        XCTAssertEqual(search("").count, 3)
        XCTAssertEqual(search("   ").count, 3)
        XCTAssertEqual(search("REUNION"), ["Réunion équipe lundi"])
        XCTAssertEqual(search("equipe lundi"), ["Réunion équipe lundi"])
        XCTAssertEqual(search("equipe mardi"), [])
        XCTAssertEqual(search("swift"), ["https://swift.org/documentation"])
        XCTAssertEqual(search("rapport pdf"), ["/tmp/Rapport final.pdf"])
        XCTAssertEqual(search("safari"), ["https://swift.org/documentation"], "l'app source se cherche aussi")
    }

    // MARK: Suspension et cycle de vie

    func testSuspendedCaptureReadsNothingAndResumesFromAFreshBaseline() throws {
        let rig = try makeClipboardRig()
        XCTAssertTrue(rig.module.keepsRunningWhenCollapsed)
        XCTAssertTrue(rig.module.isPolling)
        rig.copy("avant")

        rig.module.suspended = true
        XCTAssertFalse(rig.module.keepsRunningWhenCollapsed, "suspendu : il n'a plus besoin de tourner replié")
        XCTAssertFalse(rig.module.isPolling)
        rig.pasteboard.copy("pendant la pause")
        rig.module.poll()
        XCTAssertEqual(rig.texts, ["avant"])

        rig.module.suspended = false
        XCTAssertTrue(rig.module.isPolling)
        rig.module.poll()
        XCTAssertEqual(rig.texts, ["avant"], "ce qui a été copié pendant la pause n'est jamais enregistré")
        rig.copy("après")
        XCTAssertEqual(rig.texts, ["après", "avant"])
    }

    func testTimerAndObserverExistOnlyWhileStartedAndNotSuspended() throws {
        let rig = try makeClipboardRig(start: false)
        XCTAssertFalse(rig.module.isPolling)
        XCTAssertEqual(rig.apps.starts, 0)
        rig.module.start()
        XCTAssertTrue(rig.module.isPolling)
        XCTAssertEqual(rig.apps.starts, 1)
        rig.module.start()
        XCTAssertEqual(rig.apps.starts, 1, "démarrer deux fois ne double rien")
        rig.module.stop()
        XCTAssertFalse(rig.module.isPolling)
        XCTAssertEqual(rig.apps.stops, 1)
        rig.module.suspended = true
        rig.module.start()
        XCTAssertFalse(rig.module.isPolling, "suspendu : démarré mais sans timer")
        XCTAssertEqual(rig.apps.starts, 1)
        rig.module.stop()
    }

    func testTheRealTimerCapturesACopyWithinTwoSeconds() throws {
        let rig = try makeClipboardRig()
        rig.apps.current = .textEdit
        rig.pasteboard.copy("par le timer")
        wait(until: { !rig.items.isEmpty }, timeout: 3)
        XCTAssertEqual(rig.texts, ["par le timer"])
    }

    func testContractHasNoEarsAndNoCompactSummary() throws {
        let rig = try makeClipboardRig()
        XCTAssertNil(rig.module.ears)
        XCTAssertNil(rig.module.makeCompactView())
        XCTAssertNotNil(rig.module.makeSettingsView())
        XCTAssertNotNil(rig.module.makeHeaderAccessory())
        XCTAssertEqual(rig.module.id, "clipboard")
        XCTAssertTrue(rig.module.isEnabledByDefault)
    }

    func testRegistryKeepsItRunningCollapsedUnlessSuspended() throws {
        let rig = try makeClipboardRig(start: false)
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let modules: [any NotchModule] = [FakeModule(id: "claude"), rig.module]
        let registry = ModuleRegistry(modules: modules, prefs: prefs)
        XCTAssertTrue(registry.running.contains("clipboard"), "replié, la capture continue")
        XCTAssertTrue(rig.module.isPolling)

        rig.module.suspended = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(registry.running.contains("clipboard"))
        XCTAssertFalse(rig.module.isPolling)

        registry.setPanelOpen(true)
        XCTAssertTrue(registry.running.contains("clipboard"), "panneau ouvert : démarré pour l'affichage")
        XCTAssertFalse(rig.module.isPolling, "mais toujours sans timer")

        rig.module.suspended = false
        registry.setPanelOpen(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(rig.module.isPolling)

        prefs.tabEnabled["clipboard"] = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(rig.module.isPolling, "désactivé : plus rien ne tourne")
    }

    // MARK: Presse-papiers réel (privé)

    /// L'adaptateur du vrai NSPasteboard sur un presse-papiers privé : jamais celui de l'utilisateur.
    func testSystemPasteboardRoundTripOnAPrivatePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("oriel-tests-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        let system = SystemPasteboard(pasteboard: pasteboard)

        _ = system.write(.text("bonjour"), rich: nil, plainText: false)
        guard case .text("bonjour")? = system.read().content else { return XCTFail("texte") }

        let url = URL(string: "https://example.com/a")!
        _ = system.write(.url(url), rich: nil, plainText: false)
        guard case .url(let read)? = system.read().content else { return XCTFail("lien") }
        XCTAssertEqual(read, url)
        _ = system.write(.url(url), rich: nil, plainText: true)
        XCTAssertEqual(pasteboard.types?.map(\.rawValue).contains("public.url"), false, "texte brut : pas d'objet lien")

        let files = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]
        _ = system.write(.files(files), rich: nil, plainText: false)
        guard case .files(let readFiles)? = system.read().content else { return XCTFail("fichiers") }
        XCTAssertEqual(readFiles.map(\.path), files.map(\.path))

        _ = system.write(.color("D97757"), rich: nil, plainText: false)
        guard case .color("D97757")? = system.read().content else { return XCTFail("couleur") }

        let image = makeTestImage(width: 120, height: 80)
        let count = system.write(.image(image), rich: nil, plainText: false)
        XCTAssertEqual(count, system.changeCount)
        guard case .image(let readImage)? = system.read().content else { return XCTFail("image") }
        XCTAssertEqual(readImage.digest, image.digest)

        // Un texte mis en forme : RTF et HTML sont lus, restitués par « Copier », écartés par le texte brut.
        pasteboard.clearContents()
        pasteboard.setString("gras et normal", forType: .string)
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setData(html, forType: .html)
        let formatted = system.read()
        guard case .text("gras et normal")? = formatted.content else { return XCTFail("texte mis en forme") }
        XCTAssertEqual(formatted.rich, ClipboardRichText(rtf: rtf, html: html))
        _ = system.write(.text("gras et normal"), rich: formatted.rich, plainText: false)
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
        XCTAssertEqual(pasteboard.data(forType: .html), html)
        _ = system.write(.text("gras et normal"), rich: formatted.rich, plainText: true)
        XCTAssertNil(pasteboard.data(forType: .rtf), "texte brut : la mise en forme est écartée")
        XCTAssertEqual(pasteboard.string(forType: .string), "gras et normal")
        // Un lien n'emporte pas de mise en forme.
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/a", forType: .string)
        pasteboard.setData(rtf, forType: .rtf)
        XCTAssertNil(system.read().rich)

        // Une image de plus de 5 Mo est signalée, sans lire les formats suivants.
        pasteboard.clearContents()
        pasteboard.setData(Data(count: ClipboardImage.maxBytes + 1), forType: .png)
        let heavy = system.read()
        XCTAssertNil(heavy.content)
        XCTAssertTrue(heavy.imageTooLarge)

        // Un type confidentiel déclaré par une autre app est vu avant toute lecture du contenu.
        pasteboard.clearContents()
        pasteboard.setString("secret", forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        XCTAssertTrue(ClipboardPrivacy.hasIgnoredType(system.types))
    }
}
