import AppKit
import XCTest
@testable import Oriel

/// Onglet Mail : décodage de la réponse du script, états, autorisations, rythme de lecture. Mail n'est jamais
/// lancé ni interrogé (script factice) ; le seul vrai `osascript` lancé ici est celui de la garde « Mail fermé ».
final class MailTests: XCTestCase {
    private let sample: [FakeMail] = [
        FakeMail(sender: "Camille Martin <camille@example.com>", subject: "Facture de   septembre", age: 300,
                 id: "<abc123@mail.example.com>", unread: false, snippet: "Bonjour,\n\nVoici la facture."),
        FakeMail(sender: "\"Durand, Alex\" <alex@example.com>", subject: "Réunion\njeudi", age: 120,
                 id: "def456@mail.example.com", snippet: "Jeudi 14 h, salle 2."),
        FakeMail(sender: "newsletter@example.com", subject: "", age: 7_200, id: "ghi789@example.com"),
    ]

    /// Une boîte de réception inventée de `count` mails, du plus récent au plus ancien.
    private func inbox(_ count: Int) -> [FakeMail] {
        (0..<count).map { FakeMail(sender: "s\($0)", subject: "o\($0)", age: $0 * 60, id: "id\($0)@example.com") }
    }

    // MARK: - Décodage

    func testParsesCountersOnly() {
        XCTAssertEqual(MailScript.parse(MailRig.answer(unread: 7), now: MessagesFixtures.now),
                       .reading(MailReading(unread: 7, accounts: 1, messages: [])))
    }

    func testParsesNotRunning() {
        XCTAssertEqual(MailScript.parse("NOTRUNNING", now: MessagesFixtures.now), .notRunning)
    }

    func testParsesMessagesNewestFirstWithCleanNamesAndDates() throws {
        let now = MessagesFixtures.now
        guard case .reading(let reading)? = MailScript.parse(MailRig.answer(unread: 9, messages: sample), now: now) else {
            return XCTFail("réponse illisible")
        }
        XCTAssertEqual(reading.unread, 9)
        XCTAssertEqual(reading.messages.map { $0.sender }, ["Durand, Alex", "Camille Martin", "newsletter@example.com"],
                       "triés du plus récent au plus ancien, noms sans guillemets ni adresse")
        XCTAssertEqual(reading.messages.map { $0.subject }, ["Réunion jeudi", "Facture de septembre", ""],
                       "objet sur une ligne")
        XCTAssertEqual(reading.messages[0].date, now.addingTimeInterval(-120))
        XCTAssertEqual(reading.messages.map { $0.id }, ["def456@mail.example.com", "abc123@mail.example.com", "ghi789@example.com"],
                       "Message-ID sans chevrons")
        XCTAssertEqual(reading.messages.map { $0.snippet }, ["Jeudi 14 h, salle 2.", "Bonjour, Voici la facture.", ""],
                       "début du texte sur une ligne")
        XCTAssertEqual(reading.messages.map { $0.isUnread }, [true, false, true], "lus et non lus ensemble")
    }

    func testSnippetIsOneCleanCappedLine() {
        XCTAssertEqual(MailScript.snippet(from: "Bonjour\n\nNicolas,   \u{FFFC}  merci\t!"), "Bonjour Nicolas, merci !")
        let long = String(repeating: "mot ", count: 300)
        XCTAssertEqual(MailScript.snippet(from: long).count, MailScript.snippetCharacters)
        // Un séparateur dans le texte ne fait pas perdre le message : le texte est le dernier champ.
        let us = String(MailScript.unitSeparator)
        let answer = MailRig.answer(unread: 1, messages: [FakeMail(sender: "a", subject: "b", age: 5, id: "i@e.fr",
                                                                    snippet: "avant\(us)après")])
        guard case .reading(let reading)? = MailScript.parse(answer, now: MessagesFixtures.now) else { return XCTFail() }
        XCTAssertEqual(reading.messages.first?.snippet, "avant\(us)après")
    }

    func testTheSameMessageInTwoFoldersAppearsOnce() {
        let twice = [FakeMail(sender: "a", subject: "x", age: 10, id: "dup@example.com"),
                     FakeMail(sender: "a", subject: "x", age: 10, id: "<dup@example.com>")]
        guard case .reading(let reading)? = MailScript.parse(MailRig.answer(unread: 1, messages: twice),
                                                              now: MessagesFixtures.now) else { return XCTFail() }
        XCTAssertEqual(reading.messages.count, 1)
    }

    func testReplyOutcomes() {
        XCTAssertNil(MailScript.replyFailure(.success("OK")))
        XCTAssertEqual(MailScript.replyFailure(.success("NOTRUNNING")), .notRunning)
        XCTAssertEqual(MailScript.replyFailure(.success("NOTFOUND")), .notFound)
        XCTAssertEqual(MailScript.replyFailure(.success("FAILED")), .failed)
        XCTAssertEqual(MailScript.replyFailure(.success("")), .failed, "une réponse vide ne vaut pas succès")
        XCTAssertEqual(MailScript.replyFailure(.failure(.notAuthorized)), .notAuthorized)
        XCTAssertEqual(MailScript.replyFailure(.failure(.timedOut)), .timedOut)
        XCTAssertEqual(MailScript.replyFailure(.failure(.failed(code: 5))), .failed)
    }

    func testRefusesUnreadableAnswers() {
        for output in ["", "OK", "OK\u{1F}x\u{1F}1", "OK\u{1F}1", "erreur", "OK\u{1F}1\u{1F}1\u{1E}seulement\u{1F}trois\u{1F}champs"] {
            let parsed = MailScript.parse(output, now: MessagesFixtures.now)
            if output.hasSuffix("champs") {
                XCTAssertEqual(parsed, .reading(MailReading(unread: 1, accounts: 1, messages: [])), "enregistrement bancal ignoré")
            } else {
                XCTAssertNil(parsed, output)
            }
        }
    }

    func testOpenLinkIsTheMessageURLMailUnderstands() {
        let message = MailMessage(id: "abc123@mail.example.com", sender: "x", subject: "y", date: .distantPast)
        XCTAssertEqual(message.openURL?.absoluteString, "message://%3Cabc123%40mail.example.com%3E")
        XCTAssertNil(MailMessage(id: "", sender: "", subject: "", date: .distantPast).openURL)
    }

    func testSenderNames() {
        XCTAssertEqual(MailScript.displayName(of: "Prénom Nom <a@b.c>"), "Prénom Nom")
        XCTAssertEqual(MailScript.displayName(of: "<a@b.c>"), "a@b.c")
        XCTAssertEqual(MailScript.displayName(of: "a@b.c"), "a@b.c")
        XCTAssertEqual(MailScript.displayName(of: "  \"Nom\" <a@b.c> "), "Nom")
    }

    // MARK: - Garde « Mail fermé » (vrai osascript)

    /// Le script commence par `application id … is not running` : fermé, il répond NOTRUNNING sans lancer Mail et
    /// sans autorisation. Sauté si Mail tourne (on ne l'interroge jamais en test).
    func testRealScriptDoesNotLaunchMailWhenItIsClosed() throws {
        let bundle = MailScript.bundleIdentifier
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript"), "osascript absent")
        try XCTSkipUnless(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty,
                          "Mail tourne : on ne l'interroge pas en test")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", MailScript.source, "--", "0"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .newlines), "NOTRUNNING")
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty, "Mail n'a pas été lancé")
    }

    /// Même garde pour la réponse : Mail fermé, aucun message sortant n'est créé et Mail n'est pas lancé. Sauté si
    /// Mail tourne (on ne lui envoie jamais de réponse en test, même avec un faux identifiant).
    func testRealReplyScriptDoesNotLaunchMailWhenItIsClosed() throws {
        let bundle = MailScript.bundleIdentifier
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript"), "osascript absent")
        try XCTSkipUnless(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty,
                          "Mail tourne : on ne lui envoie rien en test")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", MailScript.replySource, "--", "absent@example.com", "texte", "send"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .newlines), "NOTRUNNING")
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty, "Mail n'a pas été lancé")
    }

    /// Les deux scripts se compilent (vocabulaire de Mail : `reply … opening window`, `send`, `content`,
    /// `messages 1 thru N of inbox`). Compiler ne les exécute pas et ne lance pas Mail.
    func testScriptsCompile() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/osacompile"), "osacompile absent")
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: MailScript.bundleIdentifier).isEmpty
        let directory = try makeTemporaryDirectory(self)
        for (name, source) in [("lecture", MailScript.source), ("reponse", MailScript.replySource)] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = ["-e", source, "-o", directory.appendingPathComponent("\(name).scpt").path]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0,
                           "\(name) : \(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        }
        if !wasRunning {
            XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: MailScript.bundleIdentifier).isEmpty,
                          "compiler n'a pas lancé Mail")
        }
    }

    /// Le texte de l'utilisateur ne passe jamais dans le script (injection) : seulement en argument.
    func testScriptsTakeUserTextAsArgumentsOnly() {
        XCTAssertTrue(MailScript.replySource.contains("item 2 of argv"))
        XCTAssertFalse(MailScript.replySource.contains("\\("), "aucune interpolation restante")
        XCTAssertFalse(MailScript.source.contains("\\("))
        XCTAssertTrue(MailScript.replySource.contains("is not running then return \"NOTRUNNING\""))
    }

    // MARK: - Module : repos

    func testModuleIsOffByDefaultAndDoesNothingUntilStarted() {
        let rig = MailRig(self)
        let module = rig.makeModule()
        XCTAssertFalse(module.isEnabledByDefault)
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
        XCTAssertNil(module.ears)
        XCTAssertTrue(rig.runner.calls.isEmpty)
        XCTAssertEqual(rig.schedule.pendingDelays, [])
    }

    func testMailIsNeverLaunchedWhenClosed() {
        let rig = MailRig(self)
        rig.running = false
        let module = rig.makeModule()
        module.start()
        XCTAssertEqual(module.state, .notRunning)
        XCTAssertTrue(rig.runner.calls.isEmpty, "Mail fermé : aucun script, donc aucun lancement")
        XCTAssertEqual(rig.schedule.pendingDelays, [], "aucun minuteur tant que Mail est fermé")
        module.tabAppeared()
        module.authorize()
        XCTAssertTrue(rig.runner.calls.isEmpty, "même sur un clic")
        XCTAssertEqual(module.state, .notRunning)
    }

    func testNotDeterminedAsksOnlyOnClick() {
        let rig = MailRig(self)
        rig.probeStatus = .notDetermined
        rig.runner.answers = [.success(MailRig.answer(unread: 2))]
        let module = rig.makeModule()
        module.start()
        module.tabAppeared()
        XCTAssertEqual(module.state, .needsPermission)
        XCTAssertTrue(rig.runner.calls.isEmpty, "ouvrir l'onglet ne fait pas apparaître la fenêtre de macOS")
        XCTAssertFalse(module.keepsRunningWhenCollapsed)

        module.authorize()
        XCTAssertEqual(rig.runner.calls.count, 1)
        XCTAssertEqual(rig.runner.calls.first?.timeout, 60, "le temps de répondre à la fenêtre")
        XCTAssertEqual(module.state, .ready)
        XCTAssertEqual(module.unread, 2)
        XCTAssertTrue(module.keepsRunningWhenCollapsed, "un script a réussi : il peut tourner replié")
    }

    func testDeniedNeverRunsAndDisarms() {
        let rig = MailRig(self)
        rig.probeStatus = .denied
        let module = rig.makeModule()
        module.start()
        XCTAssertEqual(module.state, .denied)
        XCTAssertTrue(rig.runner.calls.isEmpty)
        module.authorize()
        XCTAssertTrue(rig.runner.calls.isEmpty, "refusé : seul Réglages Système peut le changer")
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
    }

    func testRevokedAfterSuccessGoesBackToDenied() {
        let rig = MailRig(self)
        rig.runner.answers = [.success(MailRig.answer(unread: 1)), .failure(.notAuthorized)]
        let module = rig.makeModule()
        module.start()
        XCTAssertEqual(module.state, .ready)
        module.refresh()
        XCTAssertEqual(module.state, .denied)
        XCTAssertFalse(module.keepsRunningWhenCollapsed, "désarmé")
        XCTAssertNil(module.ears)
    }

    // MARK: - Module : lecture

    func testCollapsedAsksCountersOnlyAndOpenTabAsksTheList() {
        let rig = MailRig(self)
        rig.runner.answers = [.success(MailRig.answer(unread: 3)), .success(MailRig.answer(unread: 3, messages: sample))]
        let module = rig.makeModule()
        module.start()
        XCTAssertEqual(rig.runner.calls.first?.arguments, ["0"], "replié : les compteurs seulement")
        XCTAssertEqual(rig.runner.calls.first?.timeout, 20)
        XCTAssertTrue(module.messages.isEmpty)
        module.tabAppeared()
        XCTAssertEqual(rig.runner.calls.last?.arguments, ["5"], "5 derniers mails par défaut")
        XCTAssertEqual(module.messages.count, 3)
        XCTAssertEqual(module.messages.first?.sender, "Durand, Alex")
        XCTAssertEqual(module.unread, 3)
        XCTAssertTrue(module.listLoaded)
    }

    func testListShowsTheLatestReceivedReadOrNot() {
        let rig = MailRig(self)
        let module = rig.readyModule(unread: 0, messages: sample)
        XCTAssertEqual(module.unread, 0)
        XCTAssertEqual(module.messages.count, 3, "même sans non-lu, les derniers reçus sont là")
        XCTAssertEqual(module.messages.filter(\.isUnread).count, 2)
    }

    func testListIsCappedAtTheChosenCountBetweenThreeAndFive() {
        let rig = MailRig(self)
        rig.runner.answers = [.success(MailRig.answer(unread: 7, messages: inbox(7)))]
        let module = rig.makeModule()
        module.tabAppeared()
        module.start()
        XCTAssertEqual(MailModule.recentRange, 3...5)
        XCTAssertEqual(module.recentCount, 5)
        XCTAssertEqual(module.messages.count, 5)
        XCTAssertEqual(module.messages.first?.sender, "s0", "les plus récents")

        rig.runner.answers = [.success(MailRig.answer(unread: 7, messages: inbox(3)))]
        module.recentCount = 3
        XCTAssertEqual(rig.runner.calls.last?.arguments, ["3"], "le réglage change ce que le script détaille")
        XCTAssertEqual(module.messages.count, 3)
        XCTAssertEqual(rig.defaults.integer(forKey: "mail.recentCount"), 3)

        module.recentCount = 9
        XCTAssertEqual(module.recentCount, 5, "borné à 5")
        module.recentCount = 1
        XCTAssertEqual(module.recentCount, 3, "borné à 3")
        rig.defaults.set(42, forKey: "mail.recentCount")
        XCTAssertEqual(rig.makeModule().recentCount, 5, "réglage hors bornes ramené dans les bornes")
    }

    func testHiddenTextMeansTheListIsNeverRead() {
        let rig = MailRig(self)
        rig.defaults.set(false, forKey: "mail.showSubjects")
        rig.runner.answers = [.success(MailRig.answer(unread: 4))]
        let module = rig.makeModule()
        module.tabAppeared()
        module.start()
        XCTAssertEqual(rig.runner.calls.first?.arguments, ["0"], "texte masqué : on ne lit pas les messages")
        XCTAssertTrue(module.messages.isEmpty)
    }

    func testEarsAreALowPriorityBadge() {
        let rig = MailRig(self)
        rig.runner.answers = [.success(MailRig.answer(unread: 5))]
        let module = rig.makeModule()
        module.start()
        XCTAssertEqual(module.ears, ModuleEars(symbol: "envelope.fill", text: "5", priority: MailModule.earsPriority))
        XCTAssertLessThan(MailModule.earsPriority, MessagesModule.earsPriority, "après une conversation")
        module.showBadge = false
        XCTAssertNil(module.ears)
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
    }

    func testNoUnreadMeansNoEars() {
        let rig = MailRig(self)
        rig.runner.answers = [.success(MailRig.answer(unread: 0))]
        let module = rig.makeModule()
        module.start()
        XCTAssertEqual(module.state, .ready)
        XCTAssertNil(module.ears)
        XCTAssertNil(module.makeCompactView())
    }

    func testMailWithoutAccountIsReported() {
        let rig = MailRig(self)
        rig.runner.answers = [.success(MailRig.answer(unread: 0, accounts: 0))]
        let module = rig.makeModule()
        module.start()
        XCTAssertEqual(module.state, .noAccount)
        XCTAssertEqual(rig.schedule.pendingDelays, [], "rien à relire en boucle")
    }

    func testTimeoutAndBrokenAnswersGiveFailedWithoutDisarming() {
        let rig = MailRig(self)
        rig.runner.answers = [.success(MailRig.answer(unread: 1)), .failure(.timedOut), .success("n'importe quoi")]
        let module = rig.makeModule()
        module.start()
        module.refresh()
        XCTAssertEqual(module.state, .failed)
        XCTAssertTrue(module.keepsRunningWhenCollapsed, "un délai dépassé n'est pas un refus")
        XCTAssertNil(module.ears)
        module.refresh()
        XCTAssertEqual(module.state, .failed)
    }

    func testNotRunningAnswerFromScriptWinsOverStaleData() {
        let rig = MailRig(self)
        rig.runner.answers = [.success(MailRig.answer(unread: 4)), .success("NOTRUNNING")]
        let module = rig.makeModule()
        module.start()
        module.refresh()
        XCTAssertEqual(module.state, .notRunning)
        XCTAssertEqual(module.unread, 0)
    }

    // MARK: - Module : rythme

    func testPollsEveryTwoMinutesOnlyWhileMailRunsAndAnswers() {
        let rig = MailRig(self)
        rig.runner.answers = [.success(MailRig.answer(unread: 1)), .success(MailRig.answer(unread: 2)), .success(MailRig.answer(unread: 2))]
        let module = rig.makeModule()
        module.start()
        XCTAssertEqual(rig.schedule.pendingDelays, [MailModule.pollInterval])
        XCTAssertEqual(MailModule.pollInterval, 120)
        rig.schedule.runPending()
        XCTAssertEqual(rig.runner.calls.count, 2)
        XCTAssertEqual(module.unread, 2)
        XCTAssertEqual(rig.schedule.pendingDelays, [120], "un seul rendez-vous à la fois")

        rig.running = false
        rig.schedule.runPending()
        XCTAssertEqual(module.state, .notRunning)
        XCTAssertEqual(rig.runner.calls.count, 2, "Mail fermé : pas de script")
        XCTAssertEqual(rig.schedule.pendingDelays, [], "ni de minuteur")
    }

    func testStopCancelsThePollAndIgnoresLateWork() {
        let rig = MailRig(self)
        rig.runner.answers = [.success(MailRig.answer(unread: 1)), .success(MailRig.answer(unread: 9))]
        let module = rig.makeModule()
        module.start()
        module.stop()
        XCTAssertEqual(rig.schedule.pendingDelays, [])
        module.refresh()
        XCTAssertEqual(rig.runner.calls.count, 1, "arrêté : plus de script")
    }

    func testMailLaunchAndQuitTriggerARead() {
        let rig = MailRig(self)
        rig.running = false
        let module = rig.makeModule()
        module.start()
        XCTAssertEqual(module.state, .notRunning)
        // Un autre programme qui se lance ou se ferme ne réveille rien.
        rig.workspace.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
                           userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        XCTAssertEqual(rig.schedule.pendingDelays, [])
        XCTAssertTrue(rig.runner.calls.isEmpty)
        module.stop()
        // Après l'arrêt, plus d'observateur.
        rig.workspace.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                           userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        XCTAssertTrue(rig.runner.calls.isEmpty)
    }

    // MARK: - Registre

    func testRegistryOnlyRunsMailOnceReadAndKeepsItsBadgeLowPriority() {
        let rig = MailRig(self)
        rig.runner.answers = [.success(MailRig.answer(unread: 4)), .success(MailRig.answer(unread: 4))]
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.tabEnabled["mail"] = true
        let registry = ModuleRegistry(modules: [FakeModule(id: "claude"), rig.makeModule()], prefs: prefs)
        XCTAssertFalse(registry.running.contains("mail"))
        XCTAssertTrue(rig.runner.calls.isEmpty, "activé mais jamais ouvert : aucun script")

        registry.setPanelOpen(true)
        XCTAssertEqual(rig.runner.calls.count, 1)
        registry.setPanelOpen(false)
        XCTAssertTrue(registry.running.contains("mail"), "un script a réussi : il continue replié")
        XCTAssertEqual(registry.moduleEars?.text, "4")
        let tabs = EarTabs.tabs(claude: .done, claudeEars: nil, modules: registry.earsEntries, showEars: true)
        XCTAssertEqual(tabs.map { $0.id }, ["claude", "mail"])

        registry.setEnabled("mail", false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(registry.running.contains("mail"))
        XCTAssertEqual(rig.schedule.pendingDelays, [], "arrêté : plus de minuteur")
    }

    // MARK: - Actions

    func testOpenActions() {
        let rig = MailRig(self)
        let module = rig.makeModule()
        module.openMail()
        module.openMessage(MailMessage(id: "abc@example.com", sender: "x", subject: "y", date: .distantPast))
        module.openMessage(MailMessage(id: "", sender: "x", subject: "y", date: .distantPast))
        module.openPrivacy(.automation)
        XCTAssertEqual(rig.opened.map { $0.absoluteString }, [
            MailScript.appURL.absoluteString, "message://%3Cabc%40example.com%3E", MailScript.appURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
        ])
    }

    func testCompactViewShowsSenderNeverSubject() {
        let rig = MailRig(self)
        rig.runner.answers = [.success(MailRig.answer(unread: 3, messages: sample))]
        let module = rig.makeModule()
        module.tabAppeared()
        module.start()
        XCTAssertNotNil(module.makeCompactView())
        XCTAssertEqual(MailPanel.unreadText(1), "1 message non lu")
        XCTAssertEqual(MailPanel.unreadText(3), "3 messages non lus")
    }

    // MARK: - Réponse : rien ne part sans un geste explicite

    private func readyForReply(_ rig: MailRig, count: Int = 5) -> MailModule {
        rig.readyModule(unread: count, messages: inbox(count))
    }

    func testOpeningTheReplyFieldTypingAndClosingNeverSend() throws {
        let rig = MailRig(self)
        let module = readyForReply(rig)
        let target = try XCTUnwrap(module.messages.first)
        module.beginReply(target)
        XCTAssertEqual(module.replyTarget?.id, target.id)
        module.draft = "Oui, jeudi me va."
        rig.runner.answers = [.success(MailRig.answer(unread: 5, messages: inbox(5)))]
        module.refresh()
        module.tabDisappeared()
        module.tabAppeared()
        rig.schedule.runPending()
        XCTAssertTrue(rig.runner.replyCalls.isEmpty, "ouvrir, taper et relire n'envoient rien")
        module.cancelReply()
        XCTAssertNil(module.replyTarget)
        XCTAssertEqual(module.draft, "")
        XCTAssertTrue(rig.runner.replyCalls.isEmpty, "Échap non plus")
        XCTAssertEqual(module.replyState, .idle)
    }

    func testSendRunsTheReplyScriptWithTheTextAsAnArgumentAndFlashesSent() throws {
        let rig = MailRig(self)
        let module = readyForReply(rig)
        let target = module.messages[2]
        module.beginReply(target)
        module.draft = "  Merci, à jeudi !\n"
        rig.runner.answers = [.success("OK")]
        module.sendReply()
        let call = try XCTUnwrap(rig.runner.replyCalls.first)
        XCTAssertEqual(rig.runner.replyCalls.count, 1)
        XCTAssertEqual(call.arguments, [target.id, "Merci, à jeudi !", "send"], "texte nettoyé, identifiant sans chevrons")
        XCTAssertEqual(call.timeout, 60)
        XCTAssertFalse(call.script.contains("Merci"), "le texte n'est jamais dans le script")
        XCTAssertEqual(module.replyState, .sent)
        XCTAssertEqual(module.draft, "", "texte parti : le champ est vidé")
        XCTAssertEqual(rig.schedule.pendingDelays.filter { $0 == MailModule.sentFlash }, [MailModule.sentFlash])
        rig.schedule.runPending()
        XCTAssertNil(module.replyTarget, "« Envoyé » puis le champ se ferme")
        XCTAssertEqual(module.replyState, .idle)
    }

    func testEmptyDraftNeverSendsAndSubmitTwiceSendsOnce() throws {
        let rig = MailRig(self)
        let module = readyForReply(rig)
        module.beginReply(module.messages[0])
        module.draft = " \n\t "
        module.sendReply()
        XCTAssertTrue(rig.runner.replyCalls.isEmpty, "rien à envoyer")

        module.draft = "Bien reçu"
        rig.runner.hold = true
        module.sendReply()
        module.sendReply()
        XCTAssertEqual(rig.runner.replyCalls.count, 1, "Entrée deux fois : un seul envoi")
        XCTAssertEqual(module.replyState, .sending)
        module.cancelReply()
        module.beginReply(module.messages[1])
        XCTAssertEqual(module.replyTarget?.id, module.messages[0].id, "pendant l'envoi, on ne change pas de champ")
        module.stop()
        rig.runner.complete(.success("OK"))
        XCTAssertNil(module.replyTarget, "arrêté : la fin tardive est ignorée")
        XCTAssertEqual(module.replyState, .idle)
    }

    func testEveryFailureIsExplicitAndKeepsTheText() throws {
        let cases: [(Result<String, AppleScriptFailure>, MailReplyFailure)] = [
            (.success("NOTRUNNING"), .notRunning), (.success("NOTFOUND"), .notFound), (.success("FAILED"), .failed),
            (.failure(.notAuthorized), .notAuthorized), (.failure(.timedOut), .timedOut),
            (.failure(.failed(code: 12)), .failed),
        ]
        for (answer, expected) in cases {
            let rig = MailRig(self)
            let module = readyForReply(rig)
            module.beginReply(module.messages[0])
            module.draft = "Mon texte"
            rig.runner.answers = [answer]
            module.sendReply()
            XCTAssertEqual(module.replyState, .failed(expected), "\(answer)")
            XCTAssertEqual(module.draft, "Mon texte", "le texte est gardé pour réessayer")
            XCTAssertEqual(module.replyTarget?.id, module.messages[0].id)
            XCTAssertTrue(rig.schedule.pendingDelays.filter { $0 == MailModule.sentFlash }.isEmpty, "pas de « Envoyé »")
            // Après une erreur, un nouvel appui sur Envoyer réessaie (et seulement lui).
            rig.runner.answers = [.success("OK")]
            module.sendReply()
            XCTAssertEqual(rig.runner.replyCalls.count, 2)
            XCTAssertEqual(module.replyState, .sent)
        }
    }

    func testClosedMailIsNeverLaunchedByAReply() throws {
        let rig = MailRig(self)
        let module = readyForReply(rig)
        module.beginReply(module.messages[0])
        module.draft = "Texte"
        rig.running = false
        module.sendReply()
        module.openReplyInMail()
        XCTAssertTrue(rig.runner.replyCalls.isEmpty, "Mail fermé : aucun script, donc aucun lancement")
        XCTAssertEqual(module.replyState, .failed(.notRunning))
        XCTAssertEqual(module.draft, "Texte")
        XCTAssertTrue(rig.opened.isEmpty, "et Mail n'est ouvert que sur un clic de l'utilisateur")
        module.openMail()
        XCTAssertEqual(rig.opened, [MailScript.appURL])
    }

    func testContinueInMailOpensTheReplyWindowWithTheTypedTextAndSendsNothing() throws {
        let rig = MailRig(self)
        let module = readyForReply(rig)
        let target = module.messages[1]
        module.beginReply(target)
        module.draft = "Je termine dans Mail"
        rig.runner.answers = [.success("OK")]
        module.openReplyInMail()
        XCTAssertEqual(rig.runner.replyCalls.first?.arguments, [target.id, "Je termine dans Mail", "draft"])
        XCTAssertNil(module.replyTarget, "la suite se passe dans Mail")
        XCTAssertEqual(module.draft, "")
        XCTAssertEqual(module.replyState, .idle)
        XCTAssertFalse(MailScript.replySource.isEmpty)
        // Texte vide : la fenêtre de réponse s'ouvre quand même (citation seule).
        module.beginReply(target)
        rig.runner.answers = [.success("OK")]
        module.openReplyInMail()
        XCTAssertEqual(rig.runner.replyCalls.last?.arguments, [target.id, "", "draft"])
    }

    func testReplyingToAMessageThatLeftTheListKeepsItThere() throws {
        let rig = MailRig(self)
        let module = readyForReply(rig)
        let target = module.messages[4]
        module.beginReply(target)
        module.draft = "En cours"
        // Cinq nouveaux mails arrivent : le mail visé sort des cinq derniers.
        let newer = (0..<5).map { FakeMail(sender: "n\($0)", subject: "x", age: $0, id: "new\($0)@example.com") }
        rig.runner.answers = [.success(MailRig.answer(unread: 9, messages: newer))]
        module.refresh()
        XCTAssertEqual(module.messages.count, 6, "le mail auquel on écrit reste affiché")
        XCTAssertEqual(module.messages.last?.id, target.id)
        XCTAssertEqual(module.draft, "En cours")
    }

    func testReplyToggleAndMessagesWithoutIdentifier() {
        let rig = MailRig(self)
        let module = readyForReply(rig)
        let first = module.messages[0]
        module.beginReply(first)
        module.draft = "x"
        module.beginReply(module.messages[1])
        XCTAssertEqual(module.replyTarget?.id, module.messages[1].id, "un autre mail : nouveau champ, texte jeté")
        XCTAssertEqual(module.draft, "")
        module.beginReply(module.messages[1])
        XCTAssertNil(module.replyTarget, "un second clic referme")
        module.beginReply(MailMessage(id: "", sender: "x", subject: "y", date: .distantPast))
        XCTAssertNil(module.replyTarget, "sans identifiant, pas de réponse possible")
    }

    func testCompactViewNamesTheLatestUnreadNotTheLatestMail() {
        let rig = MailRig(self)
        let module = rig.readyModule(unread: 1, messages: sample)
        XCTAssertEqual(module.messages.first(where: \.isUnread)?.sender, "Durand, Alex")
        XCTAssertNotNil(module.makeCompactView())
    }

    // MARK: - Barre de commande

    /// « m » cherche dans les mails déjà lus (aucun script de plus), ⏎ ouvre le mail dans Mail ; jamais de réponse.
    func testCommandBarSearchesTheLatestEmailsAndOpensOnlyOnRun() throws {
        let rig = MailRig(self)
        let module = rig.readyModule(unread: 2, messages: sample)
        let scripts = rig.runner.calls.count
        func ids(_ verb: String?, _ argument: String) -> [String] {
            module.commands(for: CommandQuery(verb: verb, argument: argument)).map(\.id)
        }
        XCTAssertEqual(ids("m", ""), module.messages.map { "mail.open.\($0.id)" } + ["mail.app"])
        XCTAssertEqual(ids("m", "facture"), ["mail.open.abc123@mail.example.com"])
        XCTAssertEqual(ids(nil, "fa"), [], "sans verbe, trois lettres au moins")
        XCTAssertEqual(ids(nil, "factu"), ["mail.open.abc123@mail.example.com"])
        let command = try XCTUnwrap(module.commands(for: CommandQuery(verb: "m", argument: "facture")).first)
        XCTAssertTrue(rig.opened.isEmpty, "rien ne s'ouvre avant ⏎")
        XCTAssertNil(command.run())
        XCTAssertEqual(rig.opened.map(\.scheme), ["message"])
        XCTAssertEqual(rig.runner.calls.count, scripts, "la recherche ne lance aucun script")
        XCTAssertNil(module.replyTarget)

        module.showSubjects = false
        XCTAssertEqual(ids("m", ""), ["mail.app"], "sujets masqués : aucun mail montré")
    }
}
