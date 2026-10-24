import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendus PNG des onglets Messages et Mail (états, autorisations refusées, réponse rapide, compact, réglages).
/// Sans fenêtre : la vue est dessinée dans une `NSHostingView` qui n'est jamais affichée. Ne fait rien sans
/// `ORIEL_SNAPSHOT_DIR`.
final class MessagesMailSnapshotTests: XCTestCase {
    /// Les doubles prêtent leurs fermetures aux modules : ils vivent jusqu'à la fin du test.
    private var rigs: [AnyObject] = []

    private var dir: URL? { ProcessInfo.processInfo.environment["ORIEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) } }

    override func setUp() {
        super.setUp()
        // Dates relatives justes dans les images : les doubles partent de l'heure réelle.
        let saved = MessagesFixtures.now
        MessagesFixtures.now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        addTeardownBlock { MessagesFixtures.now = saved }
    }

    /// Le contenu d'un onglet dans le panneau de la notch : marges et largeur utile standard (fond noir ajouté par `render`).
    private func tab<V: View>(_ view: V) -> some View {
        view
            .environment(\.notchContentWidth, PanelSize.standard.width - 2 * ExpandedPanel.horizontalPadding)
            .padding(.horizontal, ExpandedPanel.horizontalPadding)
            .padding(.vertical, 12)
            .environment(\.colorScheme, .dark)
    }

    private func render<V: View>(_ view: V, _ name: String, height: CGFloat = 200, dark: Bool = true) throws {
        guard let dir else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let size = CGSize(width: PanelSize.standard.width, height: height)
        let hosting = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(dark ? Color.black : Color(white: 0.93)))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        let scale = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                         pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return XCTFail("rendu impossible") }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("PNG") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    // MARK: - Messages

    private func messages(_ rig: MessagesRig, result: MessagesRead = .snapshot(MessagesFixtures.sample),
                          contacts: ContactsAccess = .granted) -> MessagesModule {
        rigs.append(rig)
        rig.contacts.access = contacts
        rig.contacts.book = MessagesFixtures.book
        let module = rig.startedModule(result)
        module.tabAppeared()
        addTeardownBlock { module.stop() }
        return module
    }

    func testRenderMessages() throws {
        try XCTSkipIf(dir == nil, "ORIEL_SNAPSHOT_DIR non défini")
        let rig = MessagesRig(self)
        let module = messages(rig)
        try render(tab(MessagesPanel(module: module)), "messages-list", height: 330)

        module.select(module.threads[0].id)
        module.draft = "Oui, à 19 h devant l'entrée !"
        try render(tab(MessagesPanel(module: module)), "messages-reply", height: 330)

        rig.sender.result = .failure(.notAuthorized)
        module.sendDraft()
        try render(tab(MessagesPanel(module: module)), "messages-reply-denied", height: 330)

        let rig2 = MessagesRig(self)
        let hinted = messages(rig2, contacts: .notDetermined)
        try render(tab(MessagesPanel(module: hinted)), "messages-contacts-hint", height: 330)
        let rig3 = MessagesRig(self)
        try render(tab(MessagesPanel(module: messages(rig3, contacts: .denied))), "messages-contacts-denied", height: 330)

        let quiet = messages(MessagesRig(self))
        quiet.showText = false
        try render(tab(MessagesPanel(module: quiet)), "messages-text-hidden", height: 330)

        try render(tab(MessagesPanel(module: messages(MessagesRig(self), result: .snapshot(MessagesSnapshot(rows: [], unread: 0))))),
                   "messages-empty", height: 150)
        try render(tab(MessagesPanel(module: messages(MessagesRig(self), result: .unavailable(.needsFullDiskAccess)))),
                   "messages-full-disk-access", height: 200)
        try render(tab(MessagesPanel(module: messages(MessagesRig(self), result: .unavailable(.noDatabase)))),
                   "messages-no-database", height: 170)
        try render(tab(MessagesPanel(module: messages(MessagesRig(self), result: .unavailable(.unsupported)))),
                   "messages-unsupported", height: 150)
        let loadingRig = MessagesRig(self)
        rigs.append(loadingRig)
        try render(tab(MessagesPanel(module: loadingRig.makeModule())), "messages-loading", height: 110)

        try render(tab(MessagesCompactView(module: module)), "messages-compact", height: 60)
        try render(MessagesSettingsView(module: module).environment(\.colorScheme, .light), "messages-settings", height: 340, dark: false)
    }

    // MARK: - Mail

    private func mail(_ configure: (MailRig) -> Void, openTab: Bool = true) -> MailModule {
        mailWithRig(configure, openTab: openTab).module
    }

    private func mailWithRig(_ configure: (MailRig) -> Void, openTab: Bool = true) -> (module: MailModule, rig: MailRig) {
        let rig = MailRig(self)
        rigs.append(rig)
        configure(rig)
        rig.runner.repeatLast = true
        let module = rig.makeModule()
        if openTab { module.tabAppeared() }
        module.start()
        addTeardownBlock { module.stop() }
        return (module, rig)
    }

    /// Des mails inventés (example.com), du plus récent au plus ancien : non lus et lus, avec un début de texte.
    private let mails: [FakeMail] = [
        FakeMail(sender: "Camille Martin <camille@example.com>", subject: "Facture de septembre", age: 300,
                 id: "a1@example.com",
                 snippet: "Bonjour Nicolas, voici la facture du mois, avec le détail des heures et le récapitulatif des déplacements. Dis-moi si tout te va."),
        FakeMail(sender: "Alex Durand <alex@example.com>", subject: "Réunion jeudi 14 h : ordre du jour et documents à relire avant la séance",
                 age: 1_500, id: "a2@example.com", unread: false,
                 snippet: "Salut, je t'envoie l'ordre du jour. Pense à relire les deux documents avant jeudi, on ne les parcourra pas en séance."),
        FakeMail(sender: "Boutique en ligne", subject: "", age: 7_200, id: "a3@example.com", unread: false),
        FakeMail(sender: "noreply@example.com", subject: "Votre colis a été expédié", age: 90_000, id: "a4@example.com",
                 snippet: "Votre commande est en route. Livraison prévue demain entre 9 h et 13 h."),
        FakeMail(sender: "Équipe Exemple", subject: "Bienvenue", age: 200_000, id: "a5@example.com", unread: false,
                 snippet: "Merci de nous avoir rejoints. Voici trois choses à essayer pour bien démarrer."),
    ]

    private func replyContext(_ configure: (MailModule, MailRig) -> Void) -> MailModule {
        let (module, rig) = mailWithRig { $0.runner.answers = [.success(MailRig.answer(unread: 14, messages: mails))] }
        configure(module, rig)
        return module
    }

    func testRenderMail() throws {
        try XCTSkipIf(dir == nil, "ORIEL_SNAPSHOT_DIR non défini")
        let ready = mail { $0.runner.answers = [.success(MailRig.answer(unread: 14, messages: mails))] }
        try render(tab(MailPanel(module: ready)), "mail-list", height: 400)
        try render(tab(MailPanel(module: ready, hoverPreview: "a2@example.com")), "mail-list-hover", height: 400)
        try render(tab(MailCompactView(module: ready)), "mail-compact", height: 60)
        try render(MailSettingsView(module: ready).environment(\.colorScheme, .light), "mail-settings", height: 400, dark: false)

        let three = mail { $0.runner.answers = [.success(MailRig.answer(unread: 14, messages: Array(mails.prefix(3))))] }
        try render(tab(MailPanel(module: three)), "mail-list-3", height: 280)

        // Réponse : champ ouvert, texte tapé, envoi, « Envoyé », erreurs.
        let writing = replyContext { module, _ in
            module.beginReply(module.messages[0])
            module.draft = "Merci Camille, c'est bon pour moi. Je te règle cette semaine."
        }
        try render(tab(MailPanel(module: writing)), "mail-reply", height: 470)

        let empty = replyContext { module, _ in module.beginReply(module.messages[1]) }
        try render(tab(MailPanel(module: empty)), "mail-reply-empty", height: 470)

        let sent = replyContext { module, rig in
            module.beginReply(module.messages[0])
            module.draft = "Merci Camille, c'est bon pour moi."
            rig.runner.answers = [.success("OK")]
            module.sendReply()
            rig.runner.answers = [.success(MailRig.answer(unread: 14, messages: mails))]
        }
        XCTAssertEqual(sent.replyState, .sent)
        try render(tab(MailPanel(module: sent)), "mail-reply-sent", height: 470)

        let failures: [(String, Result<String, AppleScriptFailure>)] = [
            ("denied", .failure(.notAuthorized)), ("closed", .success("NOTRUNNING")), ("timeout", .failure(.timedOut)),
            ("gone", .success("NOTFOUND")), ("failed", .success("FAILED")),
        ]
        for (name, answer) in failures {
            let module = replyContext { module, rig in
                module.beginReply(module.messages[0])
                module.draft = "Merci Camille, c'est bon pour moi."
                rig.runner.answers = [answer]
                module.sendReply()
                rig.runner.answers = [.success(MailRig.answer(unread: 14, messages: mails))]
            }
            try render(tab(MailPanel(module: module)), "mail-reply-error-\(name)", height: 470)
        }

        let zero = mail { $0.runner.answers = [.success(MailRig.answer(unread: 0, messages: Array(mails.suffix(3))))] }
        try render(tab(MailPanel(module: zero)), "mail-all-read", height: 280)

        let emptyInbox = mail { $0.runner.answers = [.success(MailRig.answer(unread: 0))] }
        try render(tab(MailPanel(module: emptyInbox)), "mail-empty-inbox", height: 140)

        let hidden = mail { $0.runner.answers = [.success(MailRig.answer(unread: 6))] }
        hidden.showSubjects = false
        try render(tab(MailPanel(module: hidden)), "mail-counters-only", height: 150)

        let closed = mail { $0.running = false }
        try render(tab(MailPanel(module: closed)), "mail-not-running", height: 170)
        let ask = mail { $0.probeStatus = .notDetermined }
        try render(tab(MailPanel(module: ask)), "mail-needs-permission", height: 200)
        let denied = mail { $0.probeStatus = .denied }
        try render(tab(MailPanel(module: denied)), "mail-denied", height: 190)
        let none = mail { $0.runner.answers = [.success(MailRig.answer(unread: 0, accounts: 0))] }
        try render(tab(MailPanel(module: none)), "mail-no-account", height: 170)
        let failed = mail { $0.runner.answers = [.failure(.timedOut)] }
        try render(tab(MailPanel(module: failed)), "mail-failed", height: 170)
    }
}
