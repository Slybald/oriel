import AppKit
import Foundation
import SQLite3
import XCTest
@testable import Oriel

// Doubles communs aux tests de Messages et de Mail : rien ne lit les vrais messages, ne lance osascript ni
// n'envoie quoi que ce soit.

// MARK: - Planificateur manuel

/// Rendez-vous en attente, joués à la main.
final class ManualSchedule {
    private final class Item {
        let delay: TimeInterval
        let work: () -> Void
        var cancelled = false
        var done = false
        init(delay: TimeInterval, work: @escaping () -> Void) {
            self.delay = delay
            self.work = work
        }
    }

    private var items: [Item] = []

    var scheduler: ModuleScheduler {
        ModuleScheduler { [self] delay, work in
            let item = Item(delay: delay, work: work)
            items.append(item)
            return { item.cancelled = true }
        }
    }

    /// Délais des rendez-vous ni annulés ni joués.
    var pendingDelays: [TimeInterval] { items.filter { !$0.cancelled && !$0.done }.map { $0.delay } }

    /// Joue ceux qui attendent (ceux qu'ils programment à leur tour restent en attente).
    func runPending() {
        for item in items where !item.cancelled && !item.done {
            item.done = true
            item.work()
        }
    }
}

// MARK: - Messages

final class FakeMessagesDatabase: MessagesDatabase {
    var result: MessagesRead
    private(set) var reads = 0

    init(_ result: MessagesRead = .unavailable(.noDatabase)) {
        self.result = result
    }

    func read(now: Date) -> MessagesRead {
        reads += 1
        return result
    }
}

final class FakeContacts: ContactNames {
    var access: ContactsAccess
    var grantOnRequest = true
    var book = ContactBook()
    private(set) var requests = 0
    private(set) var loads = 0
    private(set) var releases = 0

    init(_ access: ContactsAccess = .notDetermined) {
        self.access = access
    }

    func requestAccess(_ done: @escaping (ContactsAccess) -> Void) {
        requests += 1
        access = grantOnRequest ? .granted : .denied
        done(access)
    }

    func load(_ done: @escaping (ContactBook) -> Void) {
        loads += 1
        done(book)
    }

    func release() { releases += 1 }
}

final class FakeWatcher: ChangeWatcher {
    private(set) var starts: [(directory: String, fileNames: Set<String>)] = []
    private(set) var stops = 0
    private var onChange: (() -> Void)?

    func start(directory: String, fileNames: Set<String>, onChange: @escaping () -> Void) {
        starts.append((directory, fileNames))
        self.onChange = onChange
    }

    func stop() {
        stops += 1
        onChange = nil
    }

    /// Comme si Messages venait d'écrire dans chat.db-wal.
    func fire() { onChange?() }
}

/// Garde les envois demandés ; rien ne part.
final class FakeSender: MessageSender {
    var result: Result<Void, AppleScriptFailure> = .success(())
    private(set) var sent: [(text: String, guid: String)] = []

    func send(_ text: String, toChat guid: String, _ done: @escaping (Result<Void, AppleScriptFailure>) -> Void) {
        sent.append((text, guid))
        done(result)
    }
}

enum MessagesFixtures {
    /// L'instant de référence des doubles ; les rendus PNG le remplacent par l'heure réelle (dates relatives justes).
    static var now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func row(_ guid: String, _ identifier: String, text: String, minutesAgo: Double = 5, unread: Int = 0,
                    fromMe: Bool = false, group: Bool = false, name: String = "", attachment: Bool = false,
                    participants: [String] = []) -> ThreadRow {
        ThreadRow(guid: guid, identifier: identifier, displayName: name, isGroup: group, text: text,
                  hasAttachment: attachment, date: now.addingTimeInterval(-minutesAgo * 60), fromMe: fromMe,
                  unread: unread, participants: participants)
    }

    /// Des conversations inventées, sans donnée réelle (numéros du plan de test, adresses en example.com).
    static var sample: MessagesSnapshot {
        MessagesSnapshot(rows: [
            row("iMessage;-;+15550100", "+15550100", text: "On se retrouve à 19 h devant le cinéma ?", minutesAgo: 3, unread: 2),
            row("iMessage;+;chat1", "chat1", text: "Photo du week-end", minutesAgo: 40, unread: 1, group: true,
                name: "Week-end ski"),
            row("iMessage;-;alex@example.com", "alex@example.com", text: "Merci pour le coup de main !", minutesAgo: 190,
                fromMe: true),
            row("iMessage;+;chat2", "chat2", text: "", minutesAgo: 1_500, group: true, attachment: true,
                participants: ["+15550101", "+15550102", "sam@example.com"]),
            row("SMS;-;+15550103", "+15550103", text: "Votre colis arrive demain.", minutesAgo: 3_000),
        ], unread: 3)
    }

    static var book: ContactBook {
        var book = ContactBook()
        book.phones[ContactBook.phoneKey("+15550100")!] = "Camille Martin"
        book.phones[ContactBook.phoneKey("+15550101")!] = "Noé"
        book.emails["alex@example.com"] = "Alex Durand"
        return book
    }
}

/// Tout ce qu'il faut pour piloter un `MessagesModule` sans rien de réel : lectures et contacts synchrones.
final class MessagesRig {
    let defaults: UserDefaults
    let database = FakeMessagesDatabase()
    let contacts = FakeContacts()
    let watcher = FakeWatcher()
    let sender = FakeSender()
    let schedule = ManualSchedule()
    private(set) var opened: [URL] = []

    init(_ test: XCTestCase) {
        defaults = makeEphemeralDefaults(test)
    }

    func makeModule() -> MessagesModule {
        MessagesModule(defaults: defaults, database: database, contacts: contacts, watcher: watcher, sender: sender,
                       scheduler: schedule.scheduler, clock: { MessagesFixtures.now }, background: { $0() },
                       main: { $0() }, openURL: { [unowned self] in opened.append($0) }, directory: "/fake/Messages")
    }

    /// Un module démarré qui a déjà lu la base d'exemple.
    func startedModule(_ result: MessagesRead = .snapshot(MessagesFixtures.sample)) -> MessagesModule {
        database.result = result
        let module = makeModule()
        module.start()
        return module
    }
}

// MARK: - Mail

/// Exécuteur factice : garde les appels et rend les réponses prévues, dans l'ordre. Rien n'est jamais exécuté, donc
/// aucun mail n'est lu, envoyé ni déposé en brouillon.
final class FakeScriptRunner: AppleScriptRunner {
    var answers: [Result<String, AppleScriptFailure>] = []
    /// Rend toujours la dernière réponse prévue (les rendus PNG : la vue relit à son affichage).
    var repeatLast = false
    /// Garde la fin des appels au lieu de la jouer : `complete` la joue plus tard (un envoi encore en cours).
    var hold = false
    private(set) var calls: [(script: String, arguments: [String], timeout: TimeInterval)] = []
    private var held: [(Result<String, AppleScriptFailure>) -> Void] = []

    func run(_ script: String, arguments: [String], timeout: TimeInterval,
             _ done: @escaping (Result<String, AppleScriptFailure>) -> Void) {
        calls.append((script, arguments, timeout))
        if hold { held.append { done($0) }; return }
        if repeatLast, answers.count == 1, let last = answers.first { return done(last) }
        done(answers.isEmpty ? .failure(.failed(code: nil)) : answers.removeFirst())
    }

    /// Joue la fin du plus ancien appel gardé.
    func complete(_ result: Result<String, AppleScriptFailure>) {
        guard !held.isEmpty else { return }
        held.removeFirst()(result)
    }

    var heldCount: Int { held.count }

    /// Les appels de réponse (envoi ou brouillon), à part des lectures.
    var replyCalls: [(script: String, arguments: [String], timeout: TimeInterval)] {
        calls.filter { $0.script == MailScript.replySource }
    }
}

struct FakeAutomationProbe: AutomationProbe {
    var status: AutomationStatus
    func status(of bundleIdentifier: String) -> AutomationStatus { status }
}

final class MailRig {
    let defaults: UserDefaults
    let runner = FakeScriptRunner()
    let schedule = ManualSchedule()
    let workspace = NotificationCenter()
    var running = true
    var probeStatus = AutomationStatus.granted
    private(set) var opened: [URL] = []

    init(_ test: XCTestCase) {
        defaults = makeEphemeralDefaults(test)
    }

    func makeModule() -> MailModule {
        MailModule(defaults: defaults, runner: runner, probe: FakeAutomationProbe(status: probeStatus),
                   isMailRunning: { [unowned self] in running }, workspace: workspace, scheduler: schedule.scheduler,
                   clock: { MessagesFixtures.now }, openURL: { [unowned self] in opened.append($0) })
    }

    /// Réponse du script : compteurs, puis un enregistrement par message (âge en secondes).
    static func answer(unread: Int, accounts: Int = 1, messages: [FakeMail] = []) -> String {
        let us = String(MailScript.unitSeparator)
        let rs = String(MailScript.recordSeparator)
        return (["OK\(us)\(unread)\(us)\(accounts)"]
            + messages.map {
                [$0.sender, $0.subject, String($0.age), $0.id, $0.unread ? "1" : "0", $0.snippet].joined(separator: us)
            }).joined(separator: rs)
    }

    /// Un module démarré, onglet ouvert, qui a lu `messages` (rien de réel : le script est factice).
    func readyModule(unread: Int = 3, messages: [FakeMail]) -> MailModule {
        runner.answers = [.success(MailRig.answer(unread: unread, messages: messages))]
        let module = makeModule()
        module.tabAppeared()
        module.start()
        return module
    }
}

/// Un mail inventé (adresses en example.com) tel que le script le renverrait.
struct FakeMail {
    var sender: String
    var subject: String
    var age: Int
    var id: String
    var unread = true
    var snippet = ""
}

// MARK: - chat.db factice

/// Une base SQLite qui a les tables et colonnes de `chat.db` (schéma documenté dans `SQLiteMessagesDatabase`).
final class FakeChatDatabase {
    let url: URL
    private var db: OpaquePointer?

    /// `columns` : retire des colonnes optionnelles du schéma pour tester la tolérance au format.
    init(_ test: XCTestCase, wal: Bool = false, omitting omitted: Set<String> = []) throws {
        url = try makeTemporaryDirectory(test).appendingPathComponent("chat.db")
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        test.addTeardownBlock { [self] in sqlite3_close(db) }
        if wal { try exec("PRAGMA journal_mode=WAL") }
        let optional = ["attributedBody BLOB", "item_type INTEGER DEFAULT 0", "associated_message_type INTEGER DEFAULT 0",
                        "cache_has_attachments INTEGER DEFAULT 0"].filter { column in
            !omitted.contains(String(column.split(separator: " ")[0]))
        }
        try exec("""
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, text TEXT, handle_id INTEGER,
                date INTEGER, is_from_me INTEGER, is_read INTEGER\(optional.isEmpty ? "" : ", " + optional.joined(separator: ", ")));
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, style INTEGER, chat_identifier TEXT,
                display_name TEXT);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER DEFAULT 0);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE INDEX message_idx_date ON message(date);
            """)
    }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "?"
            sqlite3_free(message)
            throw NSError(domain: "FakeChatDatabase", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }
    }

    @discardableResult
    func addChat(_ guid: String, identifier: String, name: String = "", group: Bool = false) throws -> Int64 {
        try exec("INSERT INTO chat (guid, style, chat_identifier, display_name) VALUES ('\(guid)', \(group ? 43 : 45), '\(identifier)', '\(name)')")
        return sqlite3_last_insert_rowid(db)
    }

    func addParticipant(_ chat: Int64, _ handle: String) throws {
        try exec("INSERT INTO handle (id) VALUES ('\(handle)')")
        try exec("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (\(chat), \(sqlite3_last_insert_rowid(db)))")
    }

    /// `body` : l'`attributedBody` (le texte est alors NULL, comme sur macOS récent). `seconds` : dates à l'ancienne.
    func addMessage(_ chat: Int64, text: String?, body: Data? = nil, date: Date, fromMe: Bool = false, read: Bool = true,
                    attachment: Bool = false, tapback: Bool = false, systemItem: Bool = false,
                    seconds: Bool = false) throws {
        let columns = try messageColumns()
        var names = ["guid", "text", "date", "is_from_me", "is_read"]
        var values = ["'g-\(UUID().uuidString)'", text.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL",
                      String(MessageDates.appleTime(date, nanoseconds: !seconds)), fromMe ? "1" : "0", read ? "1" : "0"]
        if columns.contains("cache_has_attachments") { names.append("cache_has_attachments"); values.append(attachment ? "1" : "0") }
        if columns.contains("associated_message_type") { names.append("associated_message_type"); values.append(tapback ? "2000" : "0") }
        if columns.contains("item_type") { names.append("item_type"); values.append(systemItem ? "1" : "0") }
        if let body, columns.contains("attributedBody") {
            names.append("attributedBody")
            values.append("x'\(body.map { String(format: "%02x", $0) }.joined())'")
        }
        try exec("INSERT INTO message (\(names.joined(separator: ","))) VALUES (\(values.joined(separator: ",")))")
        try exec("INSERT INTO chat_message_join (chat_id, message_id) VALUES (\(chat), \(sqlite3_last_insert_rowid(db)))")
    }

    private func messageColumns() throws -> Set<String> {
        ReadOnlySQLite(path: url.path)?.columns(of: "message") ?? []
    }
}

/// Octets `attributedBody` produits par `NSArchiver` sur macOS 27.0.1.
enum TypedStreamFixtures {
    /// `NSAttributedString` « Salut, on se voit ce soir ? » (classe `NSString`).
    static let short = hex(
        "040b73747265616d747970656481e803840140848484124e5341747472696275746564537472696e67008484084e534f" +
        "626a656374008592848484084e53537472696e67019484012b1b53616c75742c206f6e20736520766f69742063652073" +
        "6f6972203f8684026949011b928484840c4e5344696374696f6e617279009484016901928496961d5f5f6b494d4d6573" +
        "73616765506172744174747269627574654e616d658692848484084e534e756d626572008484074e5356616c75650094" +
        "84012a848401719d00868686")
    /// `NSMutableAttributedString` « Ça marche, à demain 😀 » (classe `NSMutableString`).
    static let mutable = hex(
        "040b73747265616d747970656481e803840140848484194e534d757461626c6541747472696275746564537472696e67" +
        "008484124e5341747472696275746564537472696e67008484084e534f626a6563740085928484840f4e534d75746162" +
        "6c65537472696e67018484084e53537472696e67019584012b1ac38761206d61726368652c20c3a02064656d61696e20" +
        "f09f988086840269490116928484840c4e5344696374696f6e617279009584016901928498981d5f5f6b494d4d657373" +
        "616765506172744174747269627574654e616d658692848484084e534e756d626572008484074e5356616c7565009584" +
        "012a848401719f00868686")
    /// 200 caractères : la longueur passe par `81 c8 00`.
    static let long200 = hex(
        "040b73747265616d747970656481e803840140848484124e5341747472696275746564537472696e67008484084e534f" +
        "626a656374008592848484084e53537472696e67019484012b81c8006162636465666768696a6162636465666768696a" +
        "6162636465666768696a6162636465666768696a6162636465666768696a6162636465666768696a6162636465666768" +
        "696a6162636465666768696a6162636465666768696a6162636465666768696a6162636465666768696a616263646566" +
        "6768696a6162636465666768696a6162636465666768696a6162636465666768696a6162636465666768696a61626364" +
        "65666768696a6162636465666768696a6162636465666768696a6162636465666768696a86840269490181c800928484" +
        "840c4e5344696374696f6e617279009484016901928496961d5f5f6b494d4d6573736167655061727441747472696275" +
        "74654e616d658692848484084e534e756d626572008484074e5356616c7565009484012a848401719d00868686")

    private static func hex(_ text: String) -> Data {
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}
