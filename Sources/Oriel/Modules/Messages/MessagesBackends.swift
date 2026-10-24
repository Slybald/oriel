import AppKit
import Contacts
import CoreServices
import SQLite3

// Les accès système de l'onglet Messages, chacun derrière un protocole : la base de Messages, Contacts, le suivi
// des changements de fichier et l'envoi. Le module ne connaît que les protocoles ; les tests branchent des doubles.

// MARK: - Base de Messages

protocol MessagesDatabase {
    /// Appelé hors du main thread. `.unavailable` dit pourquoi la base n'a pas pu être lue.
    func read(now: Date) -> MessagesRead
}

/// Base absente (sous XCTest, voir `ModuleEnvironment`).
struct InertMessagesDatabase: MessagesDatabase {
    func read(now: Date) -> MessagesRead { .unavailable(.noDatabase) }
}

/// Lecture seule de `~/Library/Messages/chat.db` (SQLite, mode WAL). Une connexion par lecture, fermée aussitôt :
/// une connexion qui reste ouverte retiendrait le fichier -wal de Messages.
///
/// Tables et colonnes utilisées (schéma public de longue date, pas de documentation officielle) :
/// `message(text, attributedBody, date, is_from_me, is_read, item_type, associated_message_type,
/// cache_has_attachments)`, `chat(guid, chat_identifier, display_name, style)`, `chat_message_join(chat_id,
/// message_id)`, `chat_handle_join`, `handle(id)`. Les colonnes marquées optionnelles sont testées par
/// `PRAGMA table_info` : si l'une manque, la requête s'en passe.
final class SQLiteMessagesDatabase: MessagesDatabase {
    static let defaultPath = NSHomeDirectory() + "/Library/Messages/chat.db"
    /// Un non-lu plus vieux n'est plus compté : Messages en laisse traîner (conversations filtrées, anciens appareils).
    static let unreadWindow: TimeInterval = 30 * 86_400
    /// Derniers messages parcourus pour bâtir la liste des conversations.
    static let windowRows = 400
    static let maxThreads = 8
    static let groupParticipants = 6

    private let path: String

    init(path: String = SQLiteMessagesDatabase.defaultPath) {
        self.path = path
    }

    /// nil = le fichier s'ouvre. EPERM (Accès complet au disque absent) et ENOENT (pas de Messages) ont été
    /// mesurés sur macOS 27.0.1 : `stat` réussit même sans l'accès, seul `open` refuse.
    static func probe(_ path: String) -> MessagesAccess? {
        let descriptor = open(path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return nil
        }
        return errno == ENOENT || errno == ENOTDIR ? .noDatabase : .needsFullDiskAccess
    }

    func read(now: Date) -> MessagesRead {
        if let blocked = Self.probe(path) { return .unavailable(blocked) }
        guard let db = ReadOnlySQLite(path: path) else { return .unavailable(.unsupported) }
        let message = db.columns(of: "message")
        guard message.isSuperset(of: ["text", "date", "is_from_me", "is_read"]),
              db.columns(of: "chat").isSuperset(of: ["guid", "chat_identifier", "display_name", "style"]),
              db.columns(of: "chat_message_join").isSuperset(of: ["chat_id", "message_id"]) else {
            return .unavailable(.unsupported)
        }
        let body = message.contains("attributedBody") ? "m.attributedBody" : "NULL"
        let attachments = message.contains("cache_has_attachments") ? "m.cache_has_attachments" : "0"
        var filters = ""
        if message.contains("item_type") { filters += " AND m.item_type = 0" }
        if message.contains("associated_message_type") { filters += " AND m.associated_message_type = 0" }
        var hasContent = "m.text IS NOT NULL"
        if message.contains("attributedBody") { hasContent += " OR m.attributedBody IS NOT NULL" }
        if message.contains("cache_has_attachments") { hasContent += " OR m.cache_has_attachments = 1" }

        var newest: Int64?
        db.query("SELECT MAX(date) FROM message") { newest = $0.isNull(0) ? nil : $0.int(0) }
        guard let newest else { return .snapshot(MessagesSnapshot(rows: [], unread: 0)) }
        let cutoff = MessageDates.appleTime(now.addingTimeInterval(-Self.unreadWindow),
                                            nanoseconds: MessageDates.usesNanoseconds(newest))

        var unread = 0
        db.query("""
            SELECT COUNT(*) FROM message m
            WHERE m.is_from_me = 0 AND m.is_read = 0 AND m.date > ?1\(filters) AND (\(hasContent))
              AND EXISTS (SELECT 1 FROM chat_message_join j WHERE j.message_id = m.ROWID)
            """, binds: [cutoff]) { unread = Int($0.int(0)) }

        var order: [String] = []
        var rows: [String: ThreadRow] = [:]
        var chatIDs: [String: Int64] = [:]
        db.query("""
            SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.style,
                   m.text, \(body), m.date, m.is_from_me, m.is_read, \(attachments)
            FROM message m
            JOIN chat_message_join j ON j.message_id = m.ROWID
            JOIN chat c ON c.ROWID = j.chat_id
            WHERE (\(hasContent))\(filters)
            ORDER BY m.date DESC LIMIT \(Self.windowRows)
            """) { row in
            guard let guid = row.string(1) else { return }
            let isUnread = row.int(8) == 0 && row.int(9) == 0
            if rows[guid] == nil {
                order.append(guid)
                chatIDs[guid] = row.int(0)
                rows[guid] = ThreadRow(
                    guid: guid, identifier: row.string(2) ?? "", displayName: row.string(3) ?? "", isGroup: row.int(4) == 43,
                    text: MessageText.plain(text: row.string(5), attributedBody: row.data(6)),
                    hasAttachment: row.int(10) == 1, date: MessageDates.date(fromAppleTime: row.int(7)),
                    fromMe: row.int(8) == 1, unread: 0, participants: [])
            }
            if isUnread { rows[guid]?.unread += 1 }
        }

        var shown = order.prefix(Self.maxThreads).compactMap { rows[$0] }
        for index in shown.indices where shown[index].isGroup && shown[index].displayName.isEmpty {
            guard let chatID = chatIDs[shown[index].guid] else { continue }
            db.query("""
                SELECT h.id FROM chat_handle_join cj JOIN handle h ON h.ROWID = cj.handle_id
                WHERE cj.chat_id = ?1 LIMIT \(Self.groupParticipants)
                """, binds: [chatID]) { row in row.string(0).map { shown[index].participants.append($0) } }
        }
        return .snapshot(MessagesSnapshot(rows: shown, unread: unread))
    }
}

/// Enveloppe minimale de `sqlite3` en lecture seule (le module `SQLite3` du système, aucune dépendance).
final class ReadOnlySQLite {
    struct Row {
        fileprivate let statement: OpaquePointer

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func string(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        func data(_ column: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    private var db: OpaquePointer?

    /// `SQLITE_OPEN_READONLY` : jamais d'écriture, même par erreur. Un fichier -wal vivant se lit sans le toucher.
    init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 500)
    }

    deinit { sqlite3_close(db) }

    func columns(of table: String) -> Set<String> {
        var names: Set<String> = []
        query("PRAGMA table_info(\(table))") { row in row.string(1).map { _ = names.insert($0) } }
        return names
    }

    /// `false` si la requête échoue, à la préparation (table absente…) ou en route (base en lecture seule) ; les valeurs
    /// liées sont des entiers.
    @discardableResult
    func query(_ sql: String, binds: [Int64] = [], _ onRow: (Row) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return false
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in binds.enumerated() { sqlite3_bind_int64(statement, Int32(offset + 1), value) }
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            onRow(Row(statement: statement))
            step = sqlite3_step(statement)
        }
        return step == SQLITE_DONE
    }
}

// MARK: - Contacts

/// Noms des contacts : CNContactStore dans l'app, un double dans les tests. Résultats sur le main thread.
protocol ContactNames: AnyObject {
    var access: ContactsAccess { get }
    func requestAccess(_ done: @escaping (ContactsAccess) -> Void)
    func load(_ done: @escaping (ContactBook) -> Void)
    func release()
}

final class SystemContacts: ContactNames {
    private let queue = DispatchQueue(label: "oriel.messages.contacts", qos: .utility)
    private var store: CNContactStore?

    var access: ContactsAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccess(_ done: @escaping (ContactsAccess) -> Void) {
        // L'app n'a pas d'icône dans le Dock : sans activation, la demande s'ouvrirait derrière les fenêtres.
        HookSetup.activateApp()
        queue.async {
            let store = self.store ?? CNContactStore()
            self.store = store
            store.requestAccess(for: .contacts) { _, _ in DispatchQueue.main.async { done(self.access) } }
        }
    }

    /// Un seul passage sur les contacts, hors du main thread ; le carnet reste en mémoire, rien sur disque.
    func load(_ done: @escaping (ContactBook) -> Void) {
        guard access == .granted else { return done(ContactBook()) }
        queue.async {
            let store = self.store ?? CNContactStore()
            self.store = store
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                                           CNContactOrganizationNameKey, CNContactPhoneNumbersKey,
                                           CNContactEmailAddressesKey] as [CNKeyDescriptor]
            var book = ContactBook()
            try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let name = !contact.nickname.isEmpty ? contact.nickname : (full.isEmpty ? contact.organizationName : full)
                guard !name.isEmpty else { return }
                for phone in contact.phoneNumbers {
                    if let key = ContactBook.phoneKey(phone.value.stringValue) { book.phones[key] = name }
                }
                for email in contact.emailAddresses { book.emails[(email.value as String).lowercased()] = name }
            }
            DispatchQueue.main.async { done(book) }
        }
    }

    func release() {
        queue.async { self.store = nil }
    }
}

// MARK: - Suivi du fichier

/// Prévient quand des fichiers d'un dossier changent. FSEvents plutôt qu'une surveillance de dossier : Messages
/// écrit dans `chat.db-wal`, ce qui ne change pas le dossier lui-même. Rien ne tourne au repos : le noyau réveille
/// l'app seulement à l'écriture (regroupée sur `latency` secondes).
protocol ChangeWatcher: AnyObject {
    /// `onChange` est rappelé sur le main thread quand un des `fileNames` change.
    func start(directory: String, fileNames: Set<String>, onChange: @escaping () -> Void)
    func stop()
}

final class FSEventsWatcher: ChangeWatcher {
    private final class Box {
        let fileNames: Set<String>
        let onChange: () -> Void
        init(fileNames: Set<String>, onChange: @escaping () -> Void) {
            self.fileNames = fileNames
            self.onChange = onChange
        }
    }

    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "oriel.messages.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var box: Box?

    init(latency: TimeInterval = 1.5) {
        self.latency = latency
    }

    deinit { stop() }

    func start(directory: String, fileNames: Set<String>, onChange: @escaping () -> Void) {
        stop()
        let box = Box(fileNames: fileNames, onChange: onChange)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil,
                                           release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            if changed.contains(where: { box.fileNames.contains(($0 as NSString).lastPathComponent) }) {
                DispatchQueue.main.async(execute: box.onChange)
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [directory] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        self.box = box
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        box = nil
    }
}

// MARK: - Envoi

protocol MessageSender: AnyObject {
    /// Envoie `text` dans la conversation `guid`. `done` est rappelé sur le main thread.
    func send(_ text: String, toChat guid: String, _ done: @escaping (Result<Void, AppleScriptFailure>) -> Void)
}

/// AppleScript vers l'app Messages (`com.apple.MobileSMS`). Le dictionnaire de macOS 27 : `send` accepte un `chat`,
/// dont l'`id` est le `guid` de la base. Le script se compile (vérifié) ; l'envoi réel n'a PAS été essayé.
/// Le texte passe en argument (`argv`), jamais collé dans le script.
final class AppleScriptMessageSender: MessageSender {
    static let script = """
    on run argv
        tell application id "com.apple.MobileSMS" to send (item 2 of argv) to chat id (item 1 of argv)
    end run
    """
    /// Assez long pour que l'utilisateur réponde à la fenêtre d'autorisation de macOS.
    static let timeout: TimeInterval = 60

    private let runner: AppleScriptRunner

    init(runner: AppleScriptRunner = OsascriptRunner()) {
        self.runner = runner
    }

    func send(_ text: String, toChat guid: String, _ done: @escaping (Result<Void, AppleScriptFailure>) -> Void) {
        runner.run(Self.script, arguments: [guid, text], timeout: Self.timeout) { done($0.map { _ in () }) }
    }
}
