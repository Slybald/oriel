import AppKit
import XCTest
@testable import Oriel

/// Onglet Messages : décodage du texte, lecture d'une base factice, cycle de vie du module. Aucune fenêtre ;
/// la vraie `chat.db`, Contacts et l'envoi ne sont jamais touchés (doubles dans MessagesMailSupport).
final class MessagesTests: XCTestCase {
    // MARK: - attributedBody (typedstream)

    func testTypedStreamDecodesImmutableString() {
        XCTAssertEqual(TypedStreamText.string(from: TypedStreamFixtures.short), "Salut, on se voit ce soir ?")
    }

    func testTypedStreamDecodesMutableStringWithAccentsAndEmoji() {
        XCTAssertEqual(TypedStreamText.string(from: TypedStreamFixtures.mutable), "Ça marche, à demain 😀")
    }

    func testTypedStreamReadsTwoByteLength() {
        XCTAssertEqual(TypedStreamText.string(from: TypedStreamFixtures.long200),
                       String(repeating: "abcdefghij", count: 20), "longueur 200 : 81 c8 00")
    }

    func testTypedStreamReadsFourByteLength() throws {
        // Même en-tête que l'échantillon court, longueur codée `82` + 4 octets, 70 000 caractères.
        let short = [UInt8](TypedStreamFixtures.short)
        let plus = try XCTUnwrap(short.firstIndex(of: 0x2b))
        let payload = [UInt8](repeating: UInt8(ascii: "a"), count: 70_000)
        var blob = Array(short[...plus]) + [0x82, 0x70, 0x11, 0x01, 0x00] + payload
        blob += [0x86, 0x84]
        XCTAssertEqual(TypedStreamText.string(from: Data(blob))?.count, 70_000)
    }

    func testTypedStreamRefusesWhatIsNotTypedStream() {
        XCTAssertNil(TypedStreamText.string(from: Data()))
        XCTAssertNil(TypedStreamText.string(from: Data("bplist00....................".utf8)))
        // Tronqué au milieu du texte : jamais de lecture hors des octets.
        XCTAssertNil(TypedStreamText.string(from: TypedStreamFixtures.short.prefix(85)))
        // Longueur annoncée plus grande que les octets restants.
        var broken = [UInt8](TypedStreamFixtures.short)
        let plus = broken.firstIndex(of: 0x2b)!
        broken[plus + 1] = 0x7f
        XCTAssertNil(TypedStreamText.string(from: Data(broken.prefix(plus + 10))))
    }

    func testPlainTextPrefersTextThenBodyAndCleansUp() {
        XCTAssertEqual(MessageText.plain(text: "Salut", attributedBody: TypedStreamFixtures.mutable), "Salut")
        XCTAssertEqual(MessageText.plain(text: nil, attributedBody: TypedStreamFixtures.short), "Salut, on se voit ce soir ?")
        XCTAssertEqual(MessageText.plain(text: "", attributedBody: TypedStreamFixtures.short), "Salut, on se voit ce soir ?")
        XCTAssertEqual(MessageText.plain(text: "\u{FFFC}", attributedBody: nil), "", "pièce jointe seule")
        XCTAssertEqual(MessageText.plain(text: "a\n\n  b\t c \u{FFFC}", attributedBody: nil), "a b c", "une ligne")
        XCTAssertEqual(MessageText.plain(text: String(repeating: "x", count: 500), attributedBody: nil).count,
                       MessageText.maxLength)
        XCTAssertEqual(MessageText.plain(text: nil, attributedBody: Data([1, 2, 3])), "")
    }

    func testAppleDatesHandleNanosecondsAndSeconds() {
        let date = Date(timeIntervalSinceReferenceDate: 790_000_000)
        XCTAssertEqual(MessageDates.date(fromAppleTime: MessageDates.appleTime(date, nanoseconds: true)), date)
        XCTAssertEqual(MessageDates.date(fromAppleTime: MessageDates.appleTime(date, nanoseconds: false)), date)
        XCTAssertTrue(MessageDates.usesNanoseconds(790_000_000_000_000_000))
        XCTAssertFalse(MessageDates.usesNanoseconds(790_000_000))
    }

    func testContactBookMatchesPhoneFormatsAndEmails() {
        var book = ContactBook()
        book.phones[ContactBook.phoneKey("06 12 34 56 78")!] = "Camille"
        book.emails["alex@example.com"] = "Alex"
        XCTAssertEqual(book.name(for: "+33612345678"), "Camille", "+33 6… et 06… ont les mêmes 9 derniers chiffres")
        XCTAssertEqual(book.name(for: "+33 6 12 34 56 78"), "Camille")
        XCTAssertEqual(book.name(for: "Alex@Example.com"), "Alex")
        XCTAssertNil(book.name(for: "+33699999999"))
        XCTAssertNil(book.name(for: "12"), "trop court pour être un numéro")
    }

    // MARK: - Base factice

    private func readSnapshot(_ database: FakeChatDatabase, now: Date = MessagesFixtures.now) throws -> MessagesSnapshot {
        guard case .snapshot(let snapshot) = SQLiteMessagesDatabase(path: database.url.path).read(now: now) else {
            throw XCTSkip("lecture refusée")
        }
        return snapshot
    }

    func testDatabaseListsThreadsNewestFirstWithUnreadCounts() throws {
        let db = try FakeChatDatabase(self)
        let now = MessagesFixtures.now
        let a = try db.addChat("iMessage;-;+15550100", identifier: "+15550100")
        let b = try db.addChat("iMessage;+;chat1", identifier: "chat1", name: "Week-end ski", group: true)
        try db.addMessage(a, text: "ancien", date: now.addingTimeInterval(-3_600), read: true)
        try db.addMessage(a, text: "un", date: now.addingTimeInterval(-600), read: false)
        try db.addMessage(a, text: "deux", date: now.addingTimeInterval(-300), read: false)
        try db.addMessage(b, text: "salut le groupe", date: now.addingTimeInterval(-60), read: false)
        try db.addMessage(b, text: "ma réponse", date: now.addingTimeInterval(-30), fromMe: true)

        let snapshot = try readSnapshot(db)
        XCTAssertEqual(snapshot.rows.map { $0.guid }, ["iMessage;+;chat1", "iMessage;-;+15550100"], "le plus récent d'abord")
        XCTAssertEqual(snapshot.rows[0].text, "ma réponse")
        XCTAssertTrue(snapshot.rows[0].fromMe)
        XCTAssertTrue(snapshot.rows[0].isGroup)
        XCTAssertEqual(snapshot.rows[0].displayName, "Week-end ski")
        XCTAssertEqual(snapshot.rows[0].unread, 1)
        XCTAssertEqual(snapshot.rows[1].text, "deux")
        XCTAssertEqual(snapshot.rows[1].unread, 2)
        XCTAssertEqual(snapshot.unread, 3)
        XCTAssertEqual(snapshot.rows[1].date, now.addingTimeInterval(-300))
    }

    func testDatabaseDecodesAttributedBodyWhenTextIsNull() throws {
        let db = try FakeChatDatabase(self)
        let chat = try db.addChat("iMessage;-;+15550100", identifier: "+15550100")
        try db.addMessage(chat, text: nil, body: TypedStreamFixtures.mutable, date: MessagesFixtures.now.addingTimeInterval(-10),
                          read: false)
        XCTAssertEqual(try readSnapshot(db).rows.first?.text, "Ça marche, à demain 😀")
    }

    func testDatabaseIgnoresTapbacksSystemItemsAndBlankMessages() throws {
        let db = try FakeChatDatabase(self)
        let now = MessagesFixtures.now
        let chat = try db.addChat("iMessage;-;+15550100", identifier: "+15550100")
        try db.addMessage(chat, text: "vrai message", date: now.addingTimeInterval(-100), read: false)
        try db.addMessage(chat, text: "A aimé « vrai message »", date: now.addingTimeInterval(-50), read: false, tapback: true)
        try db.addMessage(chat, text: nil, date: now.addingTimeInterval(-40), read: false, systemItem: true)
        try db.addMessage(chat, text: nil, date: now.addingTimeInterval(-30), read: false)
        let snapshot = try readSnapshot(db)
        XCTAssertEqual(snapshot.rows.map { $0.text }, ["vrai message"], "ni réaction, ni ligne système, ni message vide")
        XCTAssertEqual(snapshot.rows.first?.unread, 1)
        XCTAssertEqual(snapshot.unread, 1)
    }

    func testDatabaseFlagsAttachmentOnlyMessages() throws {
        let db = try FakeChatDatabase(self)
        let chat = try db.addChat("iMessage;-;+15550100", identifier: "+15550100")
        try db.addMessage(chat, text: "\u{FFFC}", date: MessagesFixtures.now.addingTimeInterval(-10), attachment: true)
        let row = try XCTUnwrap(try readSnapshot(db).rows.first)
        XCTAssertEqual(row.text, "")
        XCTAssertTrue(row.hasAttachment)
    }

    func testOldUnreadMessagesAreNotCounted() throws {
        let db = try FakeChatDatabase(self)
        let now = MessagesFixtures.now
        let chat = try db.addChat("iMessage;-;+15550100", identifier: "+15550100")
        try db.addMessage(chat, text: "coincé non lu depuis des mois", date: now.addingTimeInterval(-90 * 86_400), read: false)
        try db.addMessage(chat, text: "récent", date: now.addingTimeInterval(-86_400), read: false)
        XCTAssertEqual(try readSnapshot(db).unread, 1, "fenêtre de 30 jours")
    }

    func testDatabaseReadsDatesInSecondsLikeOlderMacOS() throws {
        let db = try FakeChatDatabase(self)
        let now = MessagesFixtures.now
        let chat = try db.addChat("iMessage;-;+15550100", identifier: "+15550100")
        try db.addMessage(chat, text: "ancien format", date: now.addingTimeInterval(-120), read: false, seconds: true)
        let snapshot = try readSnapshot(db)
        XCTAssertEqual(snapshot.rows.first?.date, now.addingTimeInterval(-120))
        XCTAssertEqual(snapshot.unread, 1)
    }

    func testUnnamedGroupGetsItsParticipants() throws {
        let db = try FakeChatDatabase(self)
        let group = try db.addChat("iMessage;+;chat9", identifier: "chat9", group: true)
        try db.addParticipant(group, "+15550101")
        try db.addParticipant(group, "sam@example.com")
        try db.addMessage(group, text: "coucou", date: MessagesFixtures.now.addingTimeInterval(-10))
        XCTAssertEqual(try readSnapshot(db).rows.first?.participants, ["+15550101", "sam@example.com"])
    }

    func testDatabaseKeepsEightThreads() throws {
        let db = try FakeChatDatabase(self)
        for index in 0..<12 {
            let chat = try db.addChat("iMessage;-;+1555020\(index)", identifier: "+1555020\(index)")
            try db.addMessage(chat, text: "m\(index)", date: MessagesFixtures.now.addingTimeInterval(Double(-index) * 60))
        }
        let rows = try readSnapshot(db).rows
        XCTAssertEqual(rows.count, SQLiteMessagesDatabase.maxThreads)
        XCTAssertEqual(rows.first?.text, "m0")
    }

    func testDatabaseToleratesMissingOptionalColumns() throws {
        let db = try FakeChatDatabase(self, omitting: ["attributedBody", "item_type", "associated_message_type",
                                                        "cache_has_attachments"])
        let chat = try db.addChat("iMessage;-;+15550100", identifier: "+15550100")
        try db.addMessage(chat, text: "bonjour", date: MessagesFixtures.now.addingTimeInterval(-10), read: false)
        let snapshot = try readSnapshot(db)
        XCTAssertEqual(snapshot.rows.first?.text, "bonjour")
        XCTAssertEqual(snapshot.unread, 1)
    }

    func testDatabaseWithUnknownSchemaIsUnsupported() throws {
        let db = try FakeChatDatabase(self)
        try db.exec("DROP TABLE chat_message_join")
        XCTAssertEqual(SQLiteMessagesDatabase(path: db.url.path).read(now: MessagesFixtures.now), .unavailable(.unsupported))
    }

    func testEmptyDatabaseGivesNoThreads() throws {
        let db = try FakeChatDatabase(self)
        XCTAssertEqual(SQLiteMessagesDatabase(path: db.url.path).read(now: MessagesFixtures.now),
                       .snapshot(MessagesSnapshot(rows: [], unread: 0)))
    }

    /// Messages garde ses écritures dans le fichier -wal tant qu'il tourne : une lecture seule doit les voir.
    func testReadOnlyConnectionSeesWriterInWalMode() throws {
        let db = try FakeChatDatabase(self, wal: true)
        let chat = try db.addChat("iMessage;-;+15550100", identifier: "+15550100")
        try db.addMessage(chat, text: "écrit dans le journal", date: MessagesFixtures.now.addingTimeInterval(-10), read: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.url.path + "-wal"), "le journal existe")
        XCTAssertEqual(try readSnapshot(db).rows.first?.text, "écrit dans le journal")
    }

    func testReadOnlyConnectionNeverWrites() throws {
        let db = try FakeChatDatabase(self)
        let before = try Data(contentsOf: db.url)
        _ = SQLiteMessagesDatabase(path: db.url.path).read(now: MessagesFixtures.now)
        XCTAssertEqual(try Data(contentsOf: db.url), before)
        let reader = try XCTUnwrap(ReadOnlySQLite(path: db.url.path))
        XCTAssertFalse(reader.query("INSERT INTO chat (guid) VALUES ('x')") { _ in }, "écriture refusée")
    }

    // MARK: - Accès au fichier

    func testMissingDatabaseMeansMessagesIsNotSetUp() throws {
        let missing = try makeTemporaryDirectory(self).appendingPathComponent("chat.db").path
        XCTAssertEqual(SQLiteMessagesDatabase(path: missing).read(now: MessagesFixtures.now), .unavailable(.noDatabase))
    }

    /// Même cas que l'Accès complet au disque absent : `open` refuse alors que `stat` réussit (EPERM mesuré sur
    /// macOS 27.0.1 ; ici EACCES, obtenu sans droits spéciaux).
    func testUnreadableDatabaseMeansFullDiskAccessIsNeeded() throws {
        try XCTSkipIf(getuid() == 0, "root lit tout")
        let db = try FakeChatDatabase(self)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: db.url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: db.url.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.url.path), "visible, mais pas lisible")
        XCTAssertEqual(SQLiteMessagesDatabase(path: db.url.path).read(now: MessagesFixtures.now), .unavailable(.needsFullDiskAccess))
    }

    func testPrivacyPaneLinksTargetTheRightPanes() {
        XCTAssertEqual(PrivacyPane.fullDiskAccess.url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        XCTAssertEqual(PrivacyPane.automation.url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        XCTAssertEqual(PrivacyPane.contacts.url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
    }

    // MARK: - Suivi du fichier (FSEvents, pour de vrai)

    func testFSEventsWatcherReportsOnlyTheWatchedFiles() throws {
        let dir = try makeTemporaryDirectory(self)
        let watcher = FSEventsWatcher(latency: 0.2)
        addTeardownBlock { watcher.stop() }
        var hits = 0
        let changed = expectation(description: "chat.db-wal écrit")
        watcher.start(directory: dir.path, fileNames: MessagesModule.watchedFiles) {
            hits += 1
            if hits == 1 { changed.fulfill() }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        try "autre".write(to: dir.appendingPathComponent("other.txt"), atomically: false, encoding: .utf8)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(hits, 0, "un autre fichier du dossier ne réveille rien")
        try "journal".write(to: dir.appendingPathComponent("chat.db-wal"), atomically: false, encoding: .utf8)
        wait(for: [changed], timeout: 8)
        watcher.stop()
        let after = hits
        try "encore".write(to: dir.appendingPathComponent("chat.db-wal"), atomically: false, encoding: .utf8)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(hits, after, "arrêté : plus rien")
    }

    // MARK: - Module : repos

    func testModuleIsOffByDefaultAndDoesNothingUntilStarted() {
        let rig = MessagesRig(self)
        let module = rig.makeModule()
        XCTAssertFalse(module.isEnabledByDefault)
        XCTAssertFalse(module.keepsRunningWhenCollapsed, "jamais lu : ne tourne pas replié")
        XCTAssertNil(module.ears)
        XCTAssertEqual(rig.database.reads, 0)
        XCTAssertEqual(rig.contacts.requests, 0)
        XCTAssertTrue(rig.watcher.starts.isEmpty)
        XCTAssertEqual(module.access, .unknown)
    }

    func testRegistryKeepsMessagesAndMailDisabledAndStopped() {
        let notch = NotchHarness(self)
        for id in ["messages", "mail"] {
            XCTAssertFalse(notch.registry.isEnabled(id), id)
            XCTAssertFalse(notch.registry.running.contains(id), id)
        }
        notch.registry.setPanelOpen(true)
        XCTAssertFalse(notch.registry.running.contains("messages"), "désactivé : même panneau ouvert, il ne tourne pas")
        XCTAssertFalse(notch.registry.running.contains("mail"))
    }

    func testStartReadsAndShowsThreadsUnreadAndEars() {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        XCTAssertEqual(module.access, .ready)
        XCTAssertEqual(module.unread, 3)
        XCTAssertEqual(module.threads.count, 5)
        XCTAssertEqual(module.ears, ModuleEars(symbol: "message.fill", text: "3", priority: MessagesModule.earsPriority))
        XCTAssertLessThan(MessagesModule.earsPriority, TimerModule.earsPriority, "priorité basse")
        XCTAssertTrue(module.keepsRunningWhenCollapsed)
    }

    func testEarsCapAtNinetyNineAndDisappearWithoutUnreadOrBadge() {
        let rig = MessagesRig(self)
        var snapshot = MessagesFixtures.sample
        snapshot.unread = 250
        let module = rig.startedModule(.snapshot(snapshot))
        XCTAssertEqual(module.ears?.text, "99+")
        module.showBadge = false
        XCTAssertNil(module.ears)
        XCTAssertFalse(module.keepsRunningWhenCollapsed, "pastille coupée : rien ne tourne replié")
        module.showBadge = true
        rig.database.result = .snapshot(MessagesSnapshot(rows: [], unread: 0))
        module.refresh()
        XCTAssertNil(module.ears, "rien de non lu : pas d'oreille")
    }

    func testArmedModuleRunsCollapsedOnNextLaunchButNotWithoutAccess() {
        let rig = MessagesRig(self)
        _ = rig.startedModule()
        let relaunched = rig.makeModule()
        XCTAssertTrue(relaunched.keepsRunningWhenCollapsed, "la base a déjà pu être lue : il tourne dès le lancement")

        rig.database.result = .unavailable(.needsFullDiskAccess)
        relaunched.start()
        XCTAssertEqual(relaunched.access, .needsFullDiskAccess)
        XCTAssertFalse(relaunched.keepsRunningWhenCollapsed, "accès retiré : il s'arrête")
        XCTAssertFalse(rig.makeModule().keepsRunningWhenCollapsed, "et ne se réarme pas tout seul")
    }

    func testLossOfAccessClearsEverythingAndStopsWatching() {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        XCTAssertEqual(rig.watcher.starts.count, 1)
        rig.database.result = .unavailable(.needsFullDiskAccess)
        module.refresh()
        XCTAssertEqual(module.access, .needsFullDiskAccess)
        XCTAssertTrue(module.threads.isEmpty)
        XCTAssertEqual(module.unread, 0)
        XCTAssertNil(module.ears)
        XCTAssertEqual(rig.watcher.stops, 1)
    }

    func testEachUnavailableStateIsReported() {
        for state in [MessagesAccess.noDatabase, .unsupported, .needsFullDiskAccess] {
            let rig = MessagesRig(self)
            let module = rig.startedModule(.unavailable(state))
            XCTAssertEqual(module.access, state)
            XCTAssertTrue(rig.watcher.starts.isEmpty, "rien à suivre sans accès")
        }
    }

    // MARK: - Module dans le registre : cycle de vie et oreilles

    /// Activé : rien tant que l'onglet n'a pas été ouvert ; ouvert, il lit ; replié, il continue (écoute des fichiers)
    /// et sa pastille entre dans l'alternance des oreilles avec Claude.
    func testRegistryStartsItOnOpenKeepsItCollapsedAndRotatesItsBadge() {
        let rig = MessagesRig(self)
        rig.database.result = .snapshot(MessagesFixtures.sample)
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.tabEnabled["messages"] = true
        let module = rig.makeModule()
        let registry = ModuleRegistry(modules: [FakeModule(id: "claude"), module], prefs: prefs)
        XCTAssertFalse(registry.running.contains("messages"), "jamais ouvert : rien ne tourne")
        XCTAssertEqual(rig.database.reads, 0)

        registry.setPanelOpen(true)
        XCTAssertTrue(registry.running.contains("messages"))
        XCTAssertEqual(rig.database.reads, 1)

        registry.setPanelOpen(false)
        XCTAssertTrue(registry.running.contains("messages"), "replié : l'écoute des fichiers continue")
        XCTAssertEqual(registry.earsEntries.map { $0.id }, ["messages"])
        XCTAssertEqual(registry.moduleEars?.text, "3")
        let tabs = EarTabs.tabs(claude: .working, claudeEars: nil, modules: registry.earsEntries, showEars: true)
        XCTAssertEqual(tabs.map { $0.id }, ["claude", "messages"], "un intercalaire chacun")
        XCTAssertEqual(EarTabs.tabs(claude: .attention, claudeEars: nil, modules: registry.earsEntries, showEars: true)
            .map { $0.id }, ["claude", "messages"], "Claude qui attend n'efface plus les autres")

        registry.setEnabled("messages", false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(registry.running.contains("messages"), "désactivé : arrêté, rien ne tourne")
        XCTAssertEqual(rig.watcher.stops, 1)
        XCTAssertTrue(registry.earsEntries.isEmpty)
    }

    // MARK: - Module : suivi de chat.db

    func testWatcherStartsOnceOnTheMessagesFolderAndTriggersReads() {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        XCTAssertEqual(rig.watcher.starts.count, 1)
        XCTAssertEqual(rig.watcher.starts.first?.directory, "/fake/Messages")
        XCTAssertEqual(rig.watcher.starts.first?.fileNames, ["chat.db", "chat.db-wal"])
        module.refresh()
        XCTAssertEqual(rig.watcher.starts.count, 1, "un seul suivi, même après plusieurs lectures")

        let reads = rig.database.reads
        var more = MessagesFixtures.sample
        more.unread = 4
        rig.database.result = .snapshot(more)
        rig.watcher.fire()
        XCTAssertEqual(rig.database.reads, reads + 1, "chat.db change : une lecture")
        XCTAssertEqual(module.unread, 4)
    }

    func testStopCancelsWatchingAndIgnoresLateResults() {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        module.stop()
        XCTAssertEqual(rig.watcher.stops, 1)
        XCTAssertEqual(rig.contacts.releases, 1)
        let reads = rig.database.reads
        rig.watcher.fire()
        XCTAssertEqual(rig.database.reads, reads, "arrêté : un changement de fichier ne lit rien")
        module.refresh()
        XCTAssertEqual(rig.database.reads, reads)
    }

    func testNoTimerIsEverScheduledForReading() {
        let rig = MessagesRig(self)
        _ = rig.startedModule()
        XCTAssertEqual(rig.schedule.pendingDelays, [], "aucun minuteur : seulement l'écoute des fichiers")
    }

    // MARK: - Module : contacts

    func testContactsAreNotRequestedUntilTheUserAsks() {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        module.tabAppeared()
        XCTAssertEqual(rig.contacts.requests, 0, "ouvrir l'onglet ne pose aucune question")
        XCTAssertEqual(rig.contacts.loads, 0)
        XCTAssertEqual(module.contactsAccess, .notDetermined)
        XCTAssertEqual(module.threads.first?.title, "+15550100", "sans contacts : le numéro")
    }

    func testGrantedContactsNameThreadsAndGroups() {
        let rig = MessagesRig(self)
        rig.contacts.book = MessagesFixtures.book
        let module = rig.startedModule()
        module.requestContacts()
        XCTAssertEqual(rig.contacts.requests, 1)
        XCTAssertEqual(module.contactsAccess, .granted)
        let titles = module.threads.map { $0.title }
        XCTAssertEqual(titles[0], "Camille Martin")
        XCTAssertEqual(titles[1], "Week-end ski", "un groupe nommé garde son nom")
        XCTAssertEqual(titles[2], "Alex Durand", "par adresse e-mail")
        XCTAssertEqual(titles[3], "Noé, +15550102, sam@example.com", "groupe sans nom : ses participants")
    }

    func testDeniedContactsKeepRawHandles() {
        let rig = MessagesRig(self)
        rig.contacts.grantOnRequest = false
        let module = rig.startedModule()
        module.requestContacts()
        XCTAssertEqual(module.contactsAccess, .denied)
        XCTAssertEqual(rig.contacts.loads, 0)
        XCTAssertEqual(module.threads.first?.title, "+15550100")
    }

    func testGrantedContactsAreLoadedWhenTheTabOpens() {
        let rig = MessagesRig(self)
        rig.contacts.access = .granted
        rig.contacts.book = MessagesFixtures.book
        let module = rig.startedModule()
        module.tabAppeared()
        XCTAssertEqual(rig.contacts.loads, 1)
        XCTAssertEqual(module.threads.first?.title, "Camille Martin")
        module.tabAppeared()
        XCTAssertEqual(rig.contacts.loads, 1, "déjà chargés")
    }

    // MARK: - Module : liste

    func testSnippetsShowAttachmentAndOwnReplies() {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        XCTAssertEqual(module.threads[0].snippet, "On se retrouve à 19 h devant le cinéma ?")
        XCTAssertEqual(module.threads[2].snippet, "Vous : Merci pour le coup de main !")
        XCTAssertEqual(module.threads[3].snippet, "Pièce jointe")
        XCTAssertEqual(module.threads[3].title, "+15550101, +15550102, sam@example.com", "groupe sans nom ni contacts")
    }

    func testHidingTheTextKeepsNamesAndTimes() {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        module.showText = false
        XCTAssertTrue(module.threads.allSatisfy { $0.snippet.isEmpty })
        XCTAssertEqual(module.threads.first?.title, "+15550100")
        XCTAssertEqual(module.threads.first?.unread, 2)
        module.showText = true
        XCTAssertFalse(module.threads[0].snippet.isEmpty)
    }

    func testOpenLinksForOneToOneAndGroups() {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        XCTAssertEqual(module.threads[0].openURL?.absoluteString, "imessage://+15550100")
        XCTAssertEqual(module.threads[2].openURL?.absoluteString, "imessage://alex@example.com")
        XCTAssertNil(module.threads[1].openURL, "un groupe n'a pas de lien")
        XCTAssertEqual(module.threads[4].openURL?.absoluteString, "sms://+15550103")
        module.openConversation(module.threads[0])
        module.openConversation(module.threads[1])
        module.openPrivacy(.fullDiskAccess)
        XCTAssertEqual(rig.opened.map { $0.absoluteString }, [
            "imessage://+15550100", MessagesModule.appURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ])
    }

    func testCompactViewOnlyWhenSomethingIsUnread() {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        XCTAssertNotNil(module.makeCompactView())
        rig.database.result = .snapshot(MessagesSnapshot(rows: MessagesFixtures.sample.rows, unread: 0))
        module.refresh()
        XCTAssertNil(module.makeCompactView())
    }

    // MARK: - Module : réponse rapide (envoi simulé)

    func testQuickReplySendsThroughTheSenderDouble() throws {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        let thread = module.threads[0]
        module.select(thread.id)
        XCTAssertEqual(module.composing, thread.id)
        module.draft = "  Oui, à 19 h !  "
        module.sendDraft()
        XCTAssertEqual(rig.sender.sent.count, 1)
        XCTAssertEqual(rig.sender.sent.first?.guid, "iMessage;-;+15550100")
        XCTAssertEqual(rig.sender.sent.first?.text, "Oui, à 19 h !", "texte nettoyé")
        XCTAssertEqual(module.sendState, .sent)
        XCTAssertEqual(module.draft, "", "le brouillon est vidé")
        XCTAssertEqual(rig.schedule.pendingDelays, [3, 1.5], "retour à l'état normal puis relecture")
        let reads = rig.database.reads
        rig.schedule.runPending()
        XCTAssertEqual(module.sendState, .idle)
        XCTAssertEqual(rig.database.reads, reads + 1)
    }

    func testQuickReplyIgnoresEmptyDraftsAndNoSelection() {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        module.draft = "sans conversation"
        module.sendDraft()
        module.select(module.threads[0].id)
        module.draft = "   \n "
        module.sendDraft()
        XCTAssertTrue(rig.sender.sent.isEmpty)
        XCTAssertEqual(module.sendState, .idle)
    }

    func testQuickReplyFailuresAreReportedAndKeepTheDraft() {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        module.select(module.threads[0].id)
        for failure in [AppleScriptFailure.notAuthorized, .timedOut, .failed(code: -1728)] {
            rig.sender.result = .failure(failure)
            module.draft = "à renvoyer"
            module.sendDraft()
            XCTAssertEqual(module.sendState, .failed(failure))
            XCTAssertEqual(module.draft, "à renvoyer", "le texte n'est pas perdu")
        }
    }

    func testSelectingAnotherThreadResetsTheReplyArea() {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        rig.sender.result = .failure(.timedOut)
        module.select(module.threads[0].id)
        module.draft = "brouillon"
        module.sendDraft()
        module.select(module.threads[1].id)
        XCTAssertEqual(module.composing, module.threads[1].id)
        XCTAssertEqual(module.draft, "")
        XCTAssertEqual(module.sendState, .idle)
        module.select(module.threads[1].id)
        XCTAssertNil(module.composing, "un second clic referme")
    }

    func testStopForgetsTheDraft() {
        let rig = MessagesRig(self)
        let module = rig.startedModule()
        module.select(module.threads[0].id)
        module.draft = "à moitié écrit"
        module.stop()
        XCTAssertNil(module.composing)
        XCTAssertEqual(module.draft, "")
    }

    // MARK: - AppleScript d'envoi

    func testSendScriptPassesTextAsArgumentNeverInTheScript() {
        final class Spy: AppleScriptRunner {
            var calls: [(script: String, arguments: [String])] = []
            func run(_ script: String, arguments: [String], timeout: TimeInterval,
                     _ done: @escaping (Result<String, AppleScriptFailure>) -> Void) {
                calls.append((script, arguments))
                done(.success(""))
            }
        }
        let spy = Spy()
        let hostile = "\" & (do shell script \"echo pwned\") & \""
        var result: Result<Void, AppleScriptFailure>?
        AppleScriptMessageSender(runner: spy).send(hostile, toChat: "iMessage;-;+15550100") { result = $0 }
        XCTAssertEqual(spy.calls.first?.arguments, ["iMessage;-;+15550100", hostile])
        XCTAssertFalse(spy.calls.first?.script.contains("pwned") ?? true)
        XCTAssertTrue(spy.calls.first?.script.contains("com.apple.MobileSMS") ?? false)
        XCTAssertNotNil(result)
    }

    func testOsascriptErrorCodesAreMappedWhateverTheLanguage() {
        let denied = "execution error: Not authorized to send Apple events to Messages. (-1743)\n"
        XCTAssertEqual(OsascriptRunner.failure(fromErrorOutput: denied), .notAuthorized)
        XCTAssertEqual(OsascriptRunner.failure(fromErrorOutput: "erreur d’exécution : L’événement AppleEvent a dépassé le délai. (-1712)"),
                       .timedOut)
        XCTAssertEqual(OsascriptRunner.failure(fromErrorOutput: "Messages got an error: Can’t get chat id \"x\". (-1728)"),
                       .failed(code: -1728))
        XCTAssertEqual(OsascriptRunner.failure(fromErrorOutput: "quelque chose d'inattendu"), .failed(code: nil))
        XCTAssertEqual(OsascriptRunner.failure(fromErrorOutput: ""), .failed(code: nil))
    }

    /// Les scripts se compilent avec les dictionnaires d'Apple Mail et de Messages. `osacompile` n'exécute rien et ne
    /// lance aucune app (vérifié : Mail reste fermé).
    func testAppleScriptsCompile() throws {
        let compiler = "/usr/bin/osacompile"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: compiler), "osacompile absent")
        let dir = try makeTemporaryDirectory(self)
        for (name, source) in [("send", AppleScriptMessageSender.script), ("mail", MailScript.source)] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: compiler)
            process.arguments = ["-e", source, "-o", dir.appendingPathComponent("\(name).scpt").path]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, "\(name) : \(message)")
        }
    }
}
