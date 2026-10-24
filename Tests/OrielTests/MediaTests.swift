import AppKit
import EventKit
import SwiftUI
import XCTest
@testable import Oriel

/// Calendrier factice : compte les demandes d'accès et les lectures.
final class FakeCalendar: CalendarSource {
    var access: CalendarAccess
    var grantOnRequest = true
    var list: [MediaCalendarInfo] = []
    var all: [MediaEvent] = []
    private(set) var requests = 0
    private(set) var fetches: [Set<String>] = []
    private(set) var releases = 0

    init(_ access: CalendarAccess, events: [MediaEvent] = []) {
        self.access = access
        all = events
    }

    func requestAccess(_ done: @escaping (CalendarAccess) -> Void) {
        requests += 1
        access = grantOnRequest ? .granted : .denied
        done(access)
    }

    func calendars(_ done: @escaping ([MediaCalendarInfo]) -> Void) { done(list) }

    func events(from start: Date, to end: Date, hidden: Set<String>, _ done: @escaping ([MediaEvent]) -> Void) {
        fetches.append(hidden)
        done(MediaCalendarMath.sorted(all.filter { $0.start < end && $0.end > start }))
    }

    func release() { releases += 1 }
}

/// Faux mediaremote-adapter : un script shell qui répond aux mêmes commandes (jamais le vrai MediaRemote).
struct FakeAdapter {
    let adapter: MediaRemoteAdapter
    let dir: URL
    var log: URL { dir.appendingPathComponent("commands.log") }

    /// `stream` note son PID, écrit `lines` puis attend (ou s'arrête si `exitAfterStream`) ; `test` sort avec le
    /// code de `test.status` ; toutes les commandes sont notées.
    init(_ testCase: XCTestCase, testStatus: Int = 0, lines: [String] = [], exitAfterStream: Bool = false) throws {
        dir = try makeTemporaryDirectory(testCase)
        let script = dir.appendingPathComponent("adapter.sh")
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("stream.jsonl"),
                                                          atomically: true, encoding: .utf8)
        try """
        DIR="$(dirname "$0")"
        echo "$*" >> "$DIR/commands.log"
        case "$1" in
            test) exit "$(cat "$DIR/test.status")" ;;
            stream) echo $$ > "$DIR/stream.pid"; cat "$DIR/stream.jsonl"; \(exitAfterStream ? "exit 0" : "exec sleep 30") ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        adapter = MediaRemoteAdapter(executable: URL(fileURLWithPath: "/bin/sh"), baseArguments: [script.path])
        setTestStatus(testStatus)
    }

    func setTestStatus(_ status: Int) {
        try? "\(status)".write(to: dir.appendingPathComponent("test.status"), atomically: true, encoding: .utf8)
    }

    var commands: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// PID du dernier `stream` lancé.
    var streamPID: pid_t? {
        (try? String(contentsOf: dir.appendingPathComponent("stream.pid"), encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

/// Le processus existe encore (un zombie compte : il disparaît quand son parent l'a attendu).
func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// Lignes de `stream --micros` (charge complète puis différence).
enum StreamLines {
    static func full(title: String = "Morceau", artist: String? = "Artiste", playing: Bool = true,
                     elapsed: Double = 30, duration: Double = 200, artwork: String? = nil) -> String {
        var payload: [String: Any] = [
            "bundleIdentifier": "com.apple.Music", "title": title, "playing": playing,
            "durationMicros": duration * 1_000_000, "elapsedTimeMicros": elapsed * 1_000_000,
            "timestampEpochMicros": Date().timeIntervalSince1970 * 1_000_000, "playbackRate": 1,
        ]
        payload["artist"] = artist
        payload["artworkData"] = artwork
        return json(["type": "data", "diff": false, "payload": payload])
    }

    static func diff(_ payload: [String: Any]) -> String {
        json(["type": "data", "diff": true, "payload": payload])
    }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// PNG uni de `size` px, en base64 (pochette factice).
    static func artwork(size: Int = 600, color: NSColor = .systemPurple) -> String {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!.base64EncodedString()
    }
}

final class MediaTests: XCTestCase {
    private func wait(_ timeout: TimeInterval = 3, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func data(_ line: String) -> Data { Data(line.utf8) }

    // MARK: - Flux

    func testStreamLinesRebuildTheCurrentTrack() throws {
        var state = NowPlayingState()
        XCTAssertFalse(state.apply(data("pas du json")))
        XCTAssertTrue(state.apply(data(StreamLines.full(artwork: StreamLines.artwork()))))
        var info = try XCTUnwrap(state.info)
        XCTAssertEqual(info.title, "Morceau")
        XCTAssertEqual(info.artist, "Artiste")
        XCTAssertTrue(info.isPlaying)
        XCTAssertEqual(try XCTUnwrap(info.duration), 200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(info.elapsed), 30, accuracy: 0.001)
        XCTAssertTrue(info.canSeek)
        let artwork = try XCTUnwrap(state.artwork)
        let pixels = try XCTUnwrap(artwork.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), NowPlayingState.artworkPixels, "pochette réduite")

        // Différence : seules les clés présentes changent ; null retire la clé ; la pochette reste.
        state.apply(data(StreamLines.diff(["playing": false, "artist": NSNull()])))
        info = try XCTUnwrap(state.info)
        XCTAssertFalse(info.isPlaying)
        XCTAssertNil(info.artist)
        XCTAssertEqual(info.title, "Morceau")
        XCTAssertNotNil(state.artwork)

        state.apply(data(StreamLines.diff(["artworkData": NSNull()])))
        XCTAssertNil(state.artwork)

        // Charge complète : remplace tout, y compris la pochette absente.
        state.apply(data(StreamLines.full(title: "Autre", artist: nil, playing: true)))
        XCTAssertEqual(state.info?.title, "Autre")
        XCTAssertNil(state.artwork)

        // Plus rien ne joue : charge vide.
        state.apply(data(StreamLines.json(["type": "data", "diff": false, "payload": [String: Any]()])))
        XCTAssertNil(state.info)

        // Lecteur web : l'app parente l'emporte sur le processus qui publie.
        state.apply(data(StreamLines.json(["type": "data", "diff": false, "payload": [
            "bundleIdentifier": "com.apple.WebKit.GPU", "parentApplicationBundleIdentifier": "com.apple.Safari",
            "title": "Vidéo", "playing": true,
        ]])))
        XCTAssertEqual(state.info?.bundleIdentifier, "com.apple.Safari")
        XCTAssertNil(state.info?.duration)
        XCTAssertEqual(state.info?.canSeek, false)
    }

    func testPositionAndClock() {
        let now = Date()
        var info = NowPlaying(bundleIdentifier: "x", title: "t", isPlaying: true, duration: 100, elapsed: 10,
                              timestamp: now.addingTimeInterval(-5))
        XCTAssertEqual(info.position(at: now) ?? 0, 15, accuracy: 0.001)
        info.rate = 2
        XCTAssertEqual(info.position(at: now) ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(info.position(at: now.addingTimeInterval(1000)), 100, "bornée par la durée")
        info.isPlaying = false
        XCTAssertEqual(info.position(at: now) ?? 0, 10, accuracy: 0.001, "en pause : figée")
        XCTAssertEqual(MediaFormat.clock(0), "0:00")
        XCTAssertEqual(MediaFormat.clock(187.9), "3:07")
        XCTAssertEqual(MediaFormat.clock(3765), "1:02:45")
        XCTAssertEqual(MediaFormat.clock(-4), "0:00")
        XCTAssertEqual(MediaFormat.clock(.nan), "0:00")
    }

    /// Un direct qui annonce une durée démesurée : durée inconnue (pas de barre), jamais d'arrêt de l'app.
    func testAbsurdDurationIsIgnored() throws {
        var state = NowPlayingState()
        state.apply(data(StreamLines.json(["type": "data", "diff": false, "payload": [
            "bundleIdentifier": "com.example.live", "title": "Direct", "playing": true,
            "durationMicros": 1.7976931348623157e308, "elapsedTimeMicros": -5_000_000,
        ]])))
        let info = try XCTUnwrap(state.info)
        XCTAssertNil(info.duration)
        XCTAssertNil(info.elapsed)
        XCTAssertFalse(info.canSeek)
        XCTAssertEqual(MediaFormat.clock(1.7976931348623157e308), "277777:46:40", "borné, sans piège")
        XCTAssertEqual(MediaFormat.clock(-.infinity), "0:00")
    }

    // MARK: - Calendrier

    func testWeekAndDayEvents() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.firstWeekday = 2
        func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let week = MediaCalendarMath.week(containing: date(22, 15), calendar: calendar)
        XCTAssertEqual(week, (19...25).map { date($0) }, "du lundi au dimanche")

        func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> MediaEvent {
            MediaEvent(id: id, title: id, start: start, end: end, isAllDay: allDay, color: .blue)
        }
        let events = MediaCalendarMath.sorted([
            event("revue", date(22, 14), date(22, 15)),
            event("veille", date(21, 23), date(22, 1)),
            event("congé", date(22), date(23), allDay: true),
            event("passé", date(22, 8), date(22, 9)),
            event("demain", date(23, 9), date(23, 10)),
        ])
        XCTAssertEqual(MediaCalendarMath.events(events, on: date(22, 12), calendar: calendar).map { $0.id },
                       ["congé", "veille", "passé", "revue"], "journée entière d'abord, puis par heure")
        XCTAssertEqual(MediaCalendarMath.events(events, on: date(23), calendar: calendar).map { $0.id }, ["demain"])
        XCTAssertEqual(MediaCalendarMath.next(events, after: date(22, 9, 30))?.id, "revue",
                       "ni journée entière ni événement fini")
        XCTAssertEqual(MediaCalendarMath.next(events, after: date(22, 14, 30))?.id, "revue", "en cours compris")
        XCTAssertNil(MediaCalendarMath.next(events, after: date(24)))
    }

    /// Le jour est posé champ par champ, sans texte de date dépendant de la langue du Mac.
    func testCalendarScript() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 2, day: 28, hour: 10))!
        let script = CalendarOpener.script(for: day, calendar: calendar)
        XCTAssertTrue(script.contains("set day of d to 1\nset year of d to 2026\nset month of d to 2\nset day of d to 28"),
                      script)
        XCTAssertTrue(script.contains("tell application id \"com.apple.iCal\""))
        XCTAssertTrue(script.contains("view calendar at d"))
    }

    // MARK: - Processus de l'adaptateur

    func testAdapterTestStreamAndCommands() throws {
        let ok = try FakeAdapter(self, lines: [StreamLines.full()])
        var result: Bool?
        ok.adapter.test { result = $0 }
        wait { result != nil }
        XCTAssertEqual(result, true)

        let broken = try FakeAdapter(self, testStatus: 4)
        result = nil
        broken.adapter.test { result = $0 }
        wait { result != nil }
        XCTAssertEqual(result, false, "code de sortie ≠ 0 : indisponible")

        let lines = Lines()
        ok.adapter.startStream { lines.append($0) }
        wait { lines.count >= 1 }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(ok.adapter.isStreaming)
        let child = try XCTUnwrap(ok.streamPID)
        XCTAssertTrue(isAlive(child))
        ok.adapter.stopStream()
        XCTAssertFalse(ok.adapter.isStreaming)
        wait { !isAlive(child) }
        XCTAssertFalse(isAlive(child), "commande arrêtée avec le flux")

        ok.adapter.run(["send", "2"])
        ok.adapter.run(["seek", "42000000"])
        wait { ok.commands.count >= 4 }
        XCTAssertEqual(Array(ok.commands.prefix(2)), ["test", "stream --micros --debounce=100"])
        XCTAssertEqual(ok.commands.dropFirst(2).sorted(), ["seek 42000000", "send 2"], "lancées en parallèle")
    }

    /// Le flux meurt : relancé après 1 s ; arrêté, il ne revient plus.
    func testStreamRestartsAfterADeath() throws {
        let fake = try FakeAdapter(self, lines: [StreamLines.full()], exitAfterStream: true)
        let lines = Lines()
        fake.adapter.startStream { lines.append($0) }
        wait(4) { lines.count >= 2 }
        XCTAssertGreaterThanOrEqual(lines.count, 2, "relancé")
        fake.adapter.stopStream()
        let count = fake.commands.count
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        XCTAssertEqual(fake.commands.count, count, "plus de relance après l'arrêt")
    }

    /// L'app disparaît sans prévenir (SIGKILL, plantage, pkill) : le noyau ferme son bout du tube d'entrée et le
    /// chien de garde tue la commande, au lieu de la laisser vivre jusqu'à sa prochaine écriture.
    func testWatchdogKillsTheStreamWhenTheAppGoesAway() throws {
        let fake = try FakeAdapter(self, lines: [StreamLines.full()])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", MediaRemoteAdapter.watchdog, "sh", "/bin/sh"] + fake.adapter.baseArguments
            + ["stream"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        wait { fake.streamPID != nil }
        let child = try XCTUnwrap(fake.streamPID)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(isAlive(child), "la commande tourne tant que l'app est là")
        XCTAssertTrue(process.isRunning)

        try input.fileHandleForWriting.close()
        wait { !isAlive(child) && !process.isRunning }
        XCTAssertFalse(isAlive(child), "commande tuée")
        XCTAssertFalse(process.isRunning, "chien de garde terminé")
    }

    // MARK: - Module

    func testModulePlayerLifecycleAndEars() throws {
        let fake = try FakeAdapter(self, lines: [StreamLines.full()])
        let module = MediaModule(defaults: makeEphemeralDefaults(self), adapter: fake.adapter,
                                 calendar: FakeCalendar(.notDetermined))
        XCTAssertEqual(module.playerStatus, .checking)
        XCTAssertTrue(module.keepsRunningWhenCollapsed, "les oreilles ont besoin du flux")
        XCTAssertTrue(fake.commands.isEmpty, "rien avant start()")

        module.start()
        wait { module.nowPlaying != nil }
        XCTAssertEqual(module.playerStatus, .ready)
        XCTAssertEqual(module.nowPlaying?.title, "Morceau")
        XCTAssertEqual(module.ears, ModuleEars(symbol: "music.note", text: "", priority: 1, bars: true))

        module.playerEars = false
        XCTAssertNil(module.ears)
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
        module.playerEars = true

        module.send(.togglePlayPause)
        module.send(.next)
        module.send(.previous)
        module.seek(to: 1e308)
        XCTAssertEqual(module.nowPlaying?.elapsed ?? 0, 200, accuracy: 0.001, "borné par la durée")
        module.seek(to: 90)
        XCTAssertEqual(module.nowPlaying?.elapsed ?? 0, 90, accuracy: 0.001, "la barre reste où on l'a lâchée")
        wait { fake.commands.count >= 7 }
        XCTAssertEqual(fake.commands.dropFirst(2).sorted(),
                       ["seek 200000000", "seek 90000000", "send 2", "send 4", "send 5"])

        // Lecteur masqué : flux arrêté ; réaffiché : relancé sans refaire `test`.
        module.showPlayer = false
        XCTAssertNil(module.ears)
        module.showPlayer = true
        wait { fake.commands.filter { $0.hasPrefix("stream") }.count >= 2 }
        XCTAssertEqual(fake.commands.filter { $0 == "test" }.count, 1)

        XCTAssertTrue(fake.adapter.isStreaming)
        module.stop()
        XCTAssertFalse(fake.adapter.isStreaming, "arrêté avec le module")
    }

    /// Le flux meurt en boucle : `test` est relancé ; s'il échoue, indisponible, et le module ne tourne plus replié.
    func testStreamThatKeepsDyingIsRetested() throws {
        let fake = try FakeAdapter(self, lines: [StreamLines.full()], exitAfterStream: true)
        let module = MediaModule(defaults: makeEphemeralDefaults(self), adapter: fake.adapter,
                                 calendar: FakeCalendar(.notDetermined))
        module.start()
        wait { module.playerStatus == .ready }
        fake.setTestStatus(1)
        wait(8) { module.playerStatus == .unavailable }
        XCTAssertEqual(module.playerStatus, .unavailable)
        XCTAssertNil(module.nowPlaying)
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
        XCTAssertEqual(fake.commands.filter { $0.hasPrefix("stream") }.count, MediaRemoteAdapter.quickDeathLimit)
        XCTAssertEqual(fake.commands.filter { $0 == "test" }.count, 2)
        XCTAssertFalse(fake.adapter.isStreaming)
        module.stop()
    }

    /// Au lancement, notch repliée : le registre démarre le module sans attendre l'ouverture du panneau, et les
    /// oreilles montrent la pochette et l'égaliseur.
    func testCollapsedAtLaunchTheRegistryStartsTheStream() throws {
        let fake = try FakeAdapter(self, lines: [StreamLines.full(artwork: StreamLines.artwork())])
        let module = MediaModule(defaults: makeEphemeralDefaults(self), adapter: fake.adapter,
                                 calendar: FakeCalendar(.notDetermined))
        let registry = ModuleRegistry(modules: [FakeModule(id: "claude"), module],
                                      prefs: Preferences(defaults: makeEphemeralDefaults(self)))
        XCTAssertEqual(registry.running, ["media"])
        wait { registry.moduleEars?.image != nil }
        let ears = try XCTUnwrap(registry.moduleEars)
        XCTAssertNotNil(ears.image, "pochette dans l'oreille gauche")
        XCTAssertTrue(ears.bars, "égaliseur dans l'oreille droite")
        XCTAssertEqual(ears.priority, 1)
        XCTAssertEqual(Array(fake.commands.prefix(2)), ["test", "stream --micros --debounce=100"])
        module.stop()
    }

    /// La carte du lecteur tient dans la hauteur du panneau (sinon elle déborde et se désaligne du calendrier).
    func testPlayerCardFitsThePanel() throws {
        let fake = try FakeAdapter(self, lines: [StreamLines.full(artwork: StreamLines.artwork())])
        let module = MediaModule(defaults: makeEphemeralDefaults(self), adapter: fake.adapter,
                                 calendar: FakeCalendar(.notDetermined))
        module.start()
        wait { module.artwork != nil }
        let host = NSHostingView(rootView: PlayerCard(module: module).frame(width: 300))
        XCTAssertLessThanOrEqual(host.fittingSize.height, MediaPanel.height)
        module.stop()
    }

    func testModuleUnavailableAdapter() throws {
        let broken = try FakeAdapter(self, testStatus: 1)
        let module = MediaModule(defaults: makeEphemeralDefaults(self), adapter: broken.adapter,
                                 calendar: FakeCalendar(.notDetermined))
        module.start()
        wait { module.playerStatus != .checking }
        XCTAssertEqual(module.playerStatus, .unavailable)
        XCTAssertFalse(module.keepsRunningWhenCollapsed, "indisponible : ne tourne pas replié")
        XCTAssertFalse(broken.commands.contains { $0.hasPrefix("stream") })

        // Redémarrage rapproché : pas de nouveau `test` ; « Réessayer » le relance.
        module.stop()
        module.start()
        XCTAssertEqual(broken.commands, ["test"])
        module.retryPlayer()
        wait { broken.commands.count >= 2 }
        XCTAssertEqual(broken.commands, ["test", "test"])
        module.stop()

        let absent = MediaModule(defaults: makeEphemeralDefaults(self), adapter: nil,
                                 calendar: FakeCalendar(.notDetermined))
        XCTAssertEqual(absent.playerStatus, .unavailable, "hors de l'app : pas d'adaptateur")
    }

    func testCalendarIsReadOnlyWhileShownAndAskedOnlyOnRequest() {
        let defaults = makeEphemeralDefaults(self)
        let calendar = FakeCalendar(.notDetermined)
        let now = Date()
        calendar.all = [MediaEvent(id: "e", title: "Revue", start: now.addingTimeInterval(3600),
                                   end: now.addingTimeInterval(7200), isAllDay: false, color: .red)]
        let module = MediaModule(defaults: defaults, adapter: nil, calendar: calendar)
        module.start()
        module.calendarAppeared()
        XCTAssertEqual(calendar.requests, 0, "jamais de demande d'accès sans geste de l'utilisateur")
        XCTAssertTrue(calendar.fetches.isEmpty)

        module.requestCalendarAccess()
        XCTAssertEqual(calendar.requests, 1)
        XCTAssertEqual(module.calendarAccess, .granted)
        XCTAssertEqual(module.events.map { $0.id }, ["e"])
        XCTAssertEqual(MediaCalendarMath.next(module.events, after: now)?.title, "Revue")

        module.hiddenCalendars = ["perso"]
        XCTAssertEqual(calendar.fetches.last, ["perso"])
        XCTAssertEqual(MediaModule(defaults: defaults, adapter: nil, calendar: calendar).hiddenCalendars, ["perso"],
                       "réglage gardé")

        // Changement de la base : relu tant qu'une vue est là, ignoré ensuite.
        let count = calendar.fetches.count
        storeChanged()
        XCTAssertEqual(calendar.fetches.count, count + 1)
        module.calendarDisappeared()
        storeChanged()
        XCTAssertEqual(calendar.fetches.count, count + 1)

        // Autre semaine : relue ; même semaine : rien.
        module.calendarAppeared()
        let before = calendar.fetches.count
        module.selectedDay = Calendar.current.date(byAdding: .day, value: 14, to: module.selectedDay)!
        XCTAssertEqual(calendar.fetches.count, before + 1)

        module.stop()
        XCTAssertEqual(calendar.releases, 1, "base libérée à l'arrêt")
        storeChanged()
        XCTAssertEqual(calendar.fetches.count, before + 1)
    }

    private func storeChanged() {
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testSettingsPersistAndLicense() throws {
        let defaults = makeEphemeralDefaults(self)
        let module = MediaModule(defaults: defaults, adapter: nil, calendar: FakeCalendar(.denied))
        XCTAssertTrue(module.showPlayer && module.showCalendar && module.playerEars)
        module.showPlayer = false
        module.showCalendar = false
        module.playerEars = false
        let reloaded = MediaModule(defaults: defaults, adapter: nil, calendar: FakeCalendar(.denied))
        XCTAssertFalse(reloaded.showPlayer || reloaded.showCalendar || reloaded.playerEars)
        XCTAssertNotNil(reloaded.makeSettingsView())
        XCTAssertNotNil(reloaded.makeCompactView())

        let notice = try XCTUnwrap(module.licenseNotices.first)
        XCTAssertEqual(notice.name, "mediaremote-adapter")
        let license = try String(contentsOf: repositoryRoot.appendingPathComponent("Vendor/mediaremote-adapter/LICENSE"),
                                 encoding: .utf8)
        func words(_ text: String) -> [Substring] { text.split(whereSeparator: \.isWhitespace) }
        XCTAssertEqual(words(notice.text), words(license), "notice = LICENSE du dépôt vendorisé")
    }
}

/// Lignes reçues par le flux (file d'arrière-plan) ; lues depuis le test.
final class Lines {
    private let lock = NSLock()
    private var items: [Data] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    func append(_ line: Data) { lock.lock(); items.append(line); lock.unlock() }
}

/// Diagnostic sur le vrai adaptateur d'une app assemblée par scripts/build.sh, en lecture seule (`test`, puis
/// la première ligne de `stream`). Ne lance ni ne modifie aucune lecture.
/// `ORIEL_APP=build/Oriel.app swift test --filter MediaAdapterLiveTests`
final class MediaAdapterLiveTests: XCTestCase {
    func testBundledAdapter() throws {
        guard let path = ProcessInfo.processInfo.environment["ORIEL_APP"] else {
            throw XCTSkip("ORIEL_APP non défini")
        }
        let url = URL(fileURLWithPath: path, relativeTo: repositoryRoot)
        let adapter = try XCTUnwrap(MediaRemoteAdapter.bundled(try XCTUnwrap(Bundle(url: url))), "adaptateur absent")
        var ok: Bool?
        adapter.test { ok = $0 }
        let deadline = Date().addingTimeInterval(15)
        while ok == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(ok, true, "test")

        let lines = Lines()
        var state = NowPlayingState()
        let lock = NSLock()
        adapter.startStream { line in
            lock.lock()
            if state.apply(line) { lines.append(line) }
            lock.unlock()
        }
        let streamDeadline = Date().addingTimeInterval(10)
        while lines.count == 0, Date() < streamDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        adapter.stopStream()
        XCTAssertGreaterThan(lines.count, 0, "première ligne de stream")
        lock.lock()
        print("MEDIA stream : \(lines.count) ligne(s), lecture \(state.info == nil ? "aucune" : "en cours"), "
            + "pochette \(state.artwork == nil ? "non" : "oui")")
        lock.unlock()
    }
}
