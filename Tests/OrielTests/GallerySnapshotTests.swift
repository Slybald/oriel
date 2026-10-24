import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Galerie des onglets : chacun vide, rempli et en erreur ou autorisation refusée quand il en a, aux trois largeurs
/// du panneau (480, 540, 620 pt), puis le résumé compact du plein écran et le volet de réglages de chaque module.
/// Données factices, doubles partout : ni le vrai presse-papiers, ni le vrai calendrier, ni la vraie lecture.
///
/// Le panneau doit rester sous 460 pt dans chaque état : à 480 pt (la largeur la plus étroite, donc la plus haute)
/// toujours, aux trois largeurs quand `ORIEL_SNAPSHOT_DIR` est défini, car les PNG sont alors écrits :
/// `gallery-<onglet>-<état>-<largeur>.png`.
final class GallerySnapshotTests: XCTestCase {
    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["ORIEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    func testGallery() throws {
        try claude()
        try media()
        try quickSettings()
        try shelf()
        try clipboard()
        try timer()
        try notes()
        try messages()
        try mail()
        try fullScreenSummaries()
    }

    // MARK: - Moteur

    /// Notch dépliée sur `tab`, dont les modules de `replacing` prennent la place des modules par défaut.
    private func scene(_ tab: String, replacing: [any NotchModule] = [], store: SessionStore = SessionStore(),
                       fullScreen: Bool = false) -> (NotchHarness, ModuleRegistry) {
        let harness = NotchHarness(self, store: store)
        let modules = ModuleRegistry.standardModules(claude: harness.claude).map { standard in
            replacing.first { $0.id == standard.id } ?? standard
        }
        // Messages et Mail sont désactivés par défaut : la scène les active pour les mesurer.
        if ["messages", "mail"].contains(tab) { harness.prefs.tabEnabled[tab] = true }
        let registry = ModuleRegistry(modules: modules, prefs: harness.prefs)
        harness.model.isExpanded = true
        harness.model.isFullScreen = fullScreen
        harness.model.selectedTab = tab
        return (harness, registry)
    }

    /// Un état d'un onglet : mesure à 480 pt, et aux deux autres largeurs avec rendu si `ORIEL_SNAPSHOT_DIR`.
    private func shoot(_ tab: String, _ state: String, _ module: (any NotchModule)? = nil,
                       store: SessionStore = SessionStore()) throws {
        for size in outputDir == nil ? [PanelSize.compact] : PanelSize.allCases {
            try shoot(tab, state, size: size, replacing: module.map { [$0] } ?? [], store: store)
        }
    }

    private func shoot(_ tab: String, _ state: String, size: PanelSize?, replacing: [any NotchModule],
                       store: SessionStore = SessionStore(), fullScreen: Bool = false) throws {
        let pair = scene(tab, replacing: replacing, store: store, fullScreen: fullScreen)
        if let size { pair.0.prefs.panelSize = size }
        let root = NotchRootView(model: pair.0.model, store: pair.0.store, registry: pair.1, prefs: pair.0.prefs,
                                 actions: NotchActions())
        let name = "\(tab)-\(state)" + (size.map { "-\(Int($0.width))" } ?? "")
        let measured = measure(root, pair.0.model)
        XCTAssertLessThanOrEqual(measured.height, ExpandedPanel.maxPanelHeight + 1, name)
        guard let outputDir else { return }
        // Rogné sur le panneau : la hauteur mesurée, la largeur choisie et la place de l'ombre.
        let frame = CGSize(width: min(700, measured.width + 56), height: min(480, ceil(measured.height) + 24))
        try render(root, "gallery-\(name)", outputDir, size: frame)
    }

    /// Le volet de réglages d'un module, dans la fenêtre de réglages.
    private func settings(_ id: String, _ module: (any NotchModule)?) throws {
        guard let outputDir else { return }
        let pair = scene(id, replacing: module.map { [$0] } ?? [])
        let view = SettingsView(prefs: pair.0.prefs, registry: pair.1, updater: Updater(), selection: .module(id))
        try render(view, "gallery-settings-\(id)", outputDir, size: SettingsWindow.size, background: nil)
    }

    private func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: - Claude

    private func claude() throws {
        try shoot("claude", "empty")
        try shoot("claude", "filled", store: SnapshotTests.sampleStore())
        // Une session en erreur (API) à côté d'une qui travaille.
        let failing = SessionStore.working(1)
        failing.send("UserPromptSubmit", "api", ["prompt": "Déploie la version"])
        failing.send("StopFailure", "api", ["error": "rate_limit"])
        try shoot("claude", "error", store: failing)
        try settings("claude", nil)
    }

    // MARK: - Lecteur

    private func mediaEvents() -> [MediaEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ days: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(day: days, hour: hour, minute: minute), to: today)!
        }
        return MediaCalendarMath.sorted([
            MediaEvent(id: "1", title: "Point d'équipe", start: at(0, 9), end: at(0, 9, 30), isAllDay: false,
                       color: Color(red: 0.3, green: 0.55, blue: 1)),
            MediaEvent(id: "2", title: "Revue de design", start: at(0, 14, 30), end: at(0, 15, 30), isAllDay: false,
                       color: Palette.claudeOrange),
            MediaEvent(id: "3", title: "Formation", start: at(0, 0), end: at(1, 0), isAllDay: true,
                       color: Color(red: 0.3, green: 0.8, blue: 0.5)),
            MediaEvent(id: "4", title: "Sport", start: at(0, 18), end: at(0, 19), isAllDay: false,
                       color: Color(red: 0.7, green: 0.5, blue: 1)),
        ])
    }

    /// `lines` nil : adaptateur absent (lecture indisponible) ; vide : rien ne joue.
    private func mediaModule(lines: [String]?, access: CalendarAccess, events: [MediaEvent] = []) throws -> MediaModule {
        let calendar = FakeCalendar(access, events: events)
        calendar.list = [MediaCalendarInfo(id: "travail", title: "Travail", source: "iCloud", color: Palette.claudeOrange)]
        let adapter = try lines.map { try FakeAdapter(self, lines: $0).adapter }
        let module = MediaModule(defaults: makeEphemeralDefaults(self), adapter: adapter, calendar: calendar)
        module.start()
        if let lines { wait { module.playerStatus == .ready && (lines.isEmpty || module.nowPlaying != nil) } }
        addTeardownBlock { module.stop() }
        return module
    }

    private func playingLine() -> String {
        StreamLines.full(title: "Lumières de la ville", artist: "Les Fictifs", elapsed: 74, duration: 231,
                         artwork: StreamLines.artwork())
    }

    private func media() throws {
        let playing = try mediaModule(lines: [playingLine()], access: .granted, events: mediaEvents())
        try shoot("media", "playing", playing)
        try settings("media", playing)
        try shoot("media", "paused-empty-day",
                  try mediaModule(lines: [StreamLines.full(title: "Une très longue piste dont le titre déborde",
                                                           artist: "Quelqu'un avec un nom d'artiste très long",
                                                           playing: false)], access: .granted))
        try shoot("media", "idle-ask", try mediaModule(lines: [], access: .notDetermined))
        try shoot("media", "error-denied", try mediaModule(lines: nil, access: .denied))
        let calendarOnly = try mediaModule(lines: [playingLine()], access: .granted, events: mediaEvents())
        calendarOnly.showPlayer = false
        try shoot("media", "calendar-only", calendarOnly)
    }

    // MARK: - Réglages rapides

    private func quickFixture(_ prepare: (QuickSettingsFixture) -> Void = { _ in }) -> QuickSettingsFixture {
        let f = QuickSettingsFixture(self)
        f.module.prefs.focusOnShortcut = "Concentration activer"
        f.module.prefs.focusOffShortcut = "Concentration désactiver"
        prepare(f)
        f.startAndShow()
        addTeardownBlock { f.module.stop() }
        return f
    }

    private func quickSettings() throws {
        let idle = quickFixture { $0.battery.iops = [QSFakeBattery.mac(percent: 78)] }
        try shoot("quicksettings", "idle", idle.module)
        try settings("quicksettings", idle.module)

        // Tout actif, cinq accessoires : le pire cas en hauteur.
        let busy = quickFixture {
            $0.power.lowPower = true
            $0.battery.iops = [QSFakeBattery.mac(percent: 64, pluggedIn: true, charging: true, minutes: 72)]
            $0.battery.pmset = [FakeBatteryFixtures.pods, FakeBatteryFixtures.case,
                                PowerSourceInfo(name: "Magic Keyboard", kind: .accessory, percent: 82, isCharging: false),
                                PowerSourceInfo(name: "Magic Mouse", kind: .accessory, percent: 8, isCharging: true)]
        }
        busy.module.toggleFocus()
        busy.module.startCaffeine(until: busy.now.addingTimeInterval(72 * 60))
        try shoot("quicksettings", "busy", busy.module)

        // Erreur : l'autorisation du Wi-Fi est refusée, le message propose Réglages Système.
        let failing = quickFixture()
        failing.wifi.failure = QuickSettingsFailure(.denied)
        failing.module.toggleWiFi()
        try shoot("quicksettings", "error", failing.module)

        // Mac de bureau : ni Wi-Fi, ni Bluetooth, ni batterie.
        let desktop = quickFixture {
            $0.wifi.power = nil
            $0.bluetooth.power = nil
            $0.power.supported = false
            $0.battery.iops = []
        }
        try shoot("quicksettings", "desktop", desktop.module)
    }

    // MARK: - Étagère

    private static func fakeThumbnail(_ url: URL, _ done: @escaping (NSImage?) -> Void) {
        guard ["png", "jpg"].contains(url.pathExtension) else { return done(nil) }
        let colors = url.pathExtension == "jpg" ? [NSColor.systemOrange, .systemPink] : [NSColor.systemTeal, .systemIndigo]
        done(NSImage(size: NSSize(width: 64, height: 48), flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4), angle: 60)
            return true
        })
    }

    private static let shelfNames = ["Rapport annuel 2026 - version finale relue.pdf", "Maquette accueil.png",
                                     "Photo plage.jpg", "notes-reunion.md", "Projet Notch/", "Archive.zip",
                                     "Budget.numbers", "script.swift", "Présentation.key"]

    /// Étagère démarrée avec ces fichiers vides (un nom en « / » est un dossier), dans un dossier jetable.
    private func shelfModule(_ names: [String] = shelfNames) throws -> (ShelfModule, URL) {
        let dir = try makeTemporaryDirectory(self)
        let shelf = ShelfModule(defaults: makeEphemeralDefaults(self),
                                store: ShelfStore(file: dir.appendingPathComponent("support/shelf.json")),
                                thumbnailer: Self.fakeThumbnail, saveDelay: 0)
        addTeardownBlock { shelf.stop() }
        shelf.start()
        for name in names.reversed() {
            let url = dir.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: url)
            }
            let count = shelf.items.count
            shelf.add([url])
            wait { shelf.items.count == count + 1 }
        }
        return (shelf, dir)
    }

    private func shelf() throws {
        let (empty, _) = try shelfModule([])
        try shoot("shelf", "empty", empty)
        empty.isDropTargeted = true
        try shoot("shelf", "empty-drop", empty)

        let (filled, dir) = try shelfModule()
        try shoot("shelf", "filled", filled)
        try settings("shelf", filled)

        // Sélection, survol, et un fichier supprimé dans le dos de l'étagère (« Introuvable »).
        let ids = filled.items.map { $0.id }
        filled.click(ids[1])
        filled.click(ids[2], command: true)
        filled.hovered = ids[4]
        try FileManager.default.removeItem(at: dir.appendingPathComponent("notes-reunion.md"))
        filled.viewAppeared()
        wait { !filled.missing.isEmpty }
        filled.viewDisappeared()
        try shoot("shelf", "selected-missing", filled)

        // Plafond atteint : la grille défile et le bandeau le dit.
        let (full, fullDir) = try shelfModule((1...ShelfList.maxCount).map { "Capture \($0).png" })
        full.limit = 10
        let extra = fullDir.appendingPathComponent("Un de trop.txt")
        try Data().write(to: extra)
        full.add([extra])
        wait { full.notice != nil }
        try shoot("shelf", "full-notice", full)

        // Vidée : « Annuler ».
        let (cleared, _) = try shelfModule()
        cleared.clearAll()
        try shoot("shelf", "cleared-undo", cleared)
    }

    // MARK: - Presse-papiers

    private func clipboardRig(filled: Bool) throws -> ClipboardRig {
        let rig = try makeClipboardRig()
        guard filled else { return rig }
        let finder = ClipboardSource(bundleID: "com.apple.finder", name: "Finder")
        let terminal = ClipboardSource(bundleID: "com.apple.Terminal", name: "Terminal")
        let preview = ClipboardSource(bundleID: "com.apple.Preview", name: "Aperçu")
        func ago(_ seconds: TimeInterval) { rig.clock.now = Date().addingTimeInterval(-seconds - 1) }
        ago(2 * 86_400)
        rig.copy("Rendez-vous jeudi 14 h avec l'équipe produit pour la revue du lancement, salle Horizon.", from: .textEdit)
        rig.module.togglePin(rig.items[0].id)
        ago(3 * 3600)
        rig.copy("swift test --filter ClipboardSnapshotTests", from: terminal)
        ago(25 * 60)
        rig.copy(.color("D97757"), from: .safari)
        ago(7 * 60)
        rig.copy(.files([URL(fileURLWithPath: "/tmp/Rapport trimestriel.pdf"), URL(fileURLWithPath: "/tmp/Budget.xlsx")]),
                 from: finder)
        ago(90)
        rig.copy(.image(makeTestImage(width: 640, height: 400)), from: preview)
        ago(20)
        rig.copy(String(repeating: "Un très long paragraphe qui dépasse largement deux lignes de la liste. ", count: 400),
                 from: .textEdit)
        ago(3)
        rig.copy("https://www.swift.org/documentation/api-design-guidelines/#fundamentals", from: .safari)
        return rig
    }

    private func clipboard() throws {
        let empty = try clipboardRig(filled: false)
        try shoot("clipboard", "empty", empty.module)
        let filled = try clipboardRig(filled: true)
        try shoot("clipboard", "filled", filled.module)
        try settings("clipboard", filled.module)

        let suspended = try clipboardRig(filled: true)
        suspended.module.suspended = true
        try shoot("clipboard", "suspended", suspended.module)
        let suspendedEmpty = try clipboardRig(filled: false)
        suspendedEmpty.module.suspended = true
        try shoot("clipboard", "suspended-empty", suspendedEmpty.module)

        // macOS refuse la lecture : la ligne d'explication, sans et avec historique.
        let denied = try clipboardRig(filled: false)
        denied.pasteboard.access = .denied
        denied.module.refreshAccess()
        try shoot("clipboard", "error-denied-empty", denied.module)
        let deniedFilled = try clipboardRig(filled: true)
        deniedFilled.pasteboard.access = .denied
        deniedFilled.module.refreshAccess()
        try shoot("clipboard", "error-denied-filled", deniedFilled.module)

        // Image de plus de 5 Mo : non gardée, la ligne le dit.
        let large = try clipboardRig(filled: true)
        large.apps.current = .safari
        large.pasteboard.copyTooLargeImage()
        large.module.poll()
        try shoot("clipboard", "error-image-too-large", large.module)
    }

    // MARK: - Minuteur

    private func timerModule(_ prepare: (TimerRig, TimerModule) throws -> Void = { _, _ in }) throws -> TimerModule {
        let rig = try TimerRig(self)
        let module = rig.startedModule()
        addTeardownBlock { module.stop() }
        try prepare(rig, module)
        return module
    }

    private func pomodoro(_ rig: TimerRig, _ status: TimerState.Status, _ phase: TimerPhase, cycle: Int, left: TimeInterval,
                          finishedAgo: TimeInterval? = nil) throws -> TimerModule {
        var state = TimerState()
        state.mode = .pomodoro
        state.status = status
        state.phase = phase
        state.duration = phase == .focus ? 25 * 60 : phase == .shortBreak ? 5 * 60 : 15 * 60
        state.cycle = cycle
        state.sessionsToday = 5
        state.sessionsDay = rig.calendar.startOfDay(for: rig.clock.now)
        if status == .running { state.endDate = rig.clock.now.addingTimeInterval(left) } else { state.remaining = left }
        state.finishedAt = finishedAgo.map { rig.clock.now.addingTimeInterval(-$0) }
        try rig.preload(state)
        let module = rig.startedModule()
        addTeardownBlock { module.stop() }
        return module
    }

    private func timer() throws {
        let idle = try timerModule()
        try shoot("timer", "simple-idle", idle)
        try settings("timer", idle)
        try shoot("timer", "simple-running", try timerModule { rig, module in
            module.startSimple(minutes: 10)
            rig.clock.advance(328)
            module.tick()
        })
        try shoot("timer", "simple-paused", try timerModule { rig, module in
            module.startSimple(minutes: 25)
            rig.clock.advance(600)
            module.pause()
        })
        try shoot("timer", "simple-finished", try timerModule { rig, module in
            module.startSimple(minutes: 5)
            rig.clock.advance(300)
            module.tick()
            module.panelOpened()
        })
        try shoot("timer", "pomodoro-idle", try timerModule { _, module in module.setMode(.pomodoro) })
        let focusRig = try TimerRig(self)
        try shoot("timer", "pomodoro-focus", try pomodoro(focusRig, .running, .focus, cycle: 2, left: 18 * 60 + 12))
        let breakRig = try TimerRig(self)
        try shoot("timer", "pomodoro-break-paused", try pomodoro(breakRig, .paused, .longBreak, cycle: 4, left: 11 * 60 + 5))
    }

    // MARK: - Notes rapides

    private func notesModule(count: Int = 5) throws -> NotesModule {
        let rig = try NotesRig(self)
        let module = rig.startedModule()
        addTeardownBlock { module.stop() }
        let samples: [(String, TimeInterval)] = [
            ("Courses : lait, œufs, pain\ncitrons, basilic", 5 * 86_400),
            ("Réunion jeudi 14h, salle B\nPréparer les chiffres du trimestre\nDemander le budget formation", 2 * 86_400),
            ("docker compose up -d --build\ndocker logs -f api", 3 * 3_600),
            ("Code wifi invité : 4821-77", 25 * 60),
            ("Idée de nom pour l'app\nEncoche ? Notchbook ? Pocket ?", 40),
            ("Appeler le garage\nPneus d'hiver avant le 15", 9 * 86_400),
            ("Lire : article sur le Pomodoro", 11 * 86_400),
            ("Livre à rendre vendredi", 12 * 86_400),
            ("Mot de passe du routeur sur l'étiquette", 14 * 86_400),
            ("Gâteau pour l'anniversaire de samedi", 15 * 86_400),
        ]
        let now = Date()
        for (text, age) in samples.prefix(count).sorted(by: { $0.1 > $1.1 }) {
            rig.clock.now = Date(timeIntervalSince1970: (now.timeIntervalSince1970 - age).rounded())
            rig.write(module, text, after: 0)
        }
        rig.clock.now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded())
        return module
    }

    /// Messages : liste avec la zone de réponse ouverte (l'état le plus haut), erreur d'envoi, puis chaque accès refusé.
    private func messages() throws {
        MessagesFixtures.now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        func module(_ result: MessagesRead, contacts: ContactsAccess = .granted, rig: inout [MessagesRig]) -> MessagesModule {
            let fresh = MessagesRig(self)
            rig.append(fresh)
            fresh.contacts.access = contacts
            fresh.contacts.book = MessagesFixtures.book
            fresh.database.result = result
            let module = fresh.makeModule()
            module.start()
            module.tabAppeared()
            addTeardownBlock { module.stop() }
            return module
        }
        var rigs: [MessagesRig] = []
        addTeardownBlock { rigs.removeAll() }
        let list = module(.snapshot(MessagesFixtures.sample), rig: &rigs)
        try shoot("messages", "list", list)
        try settings("messages", list)
        let hint = module(.snapshot(MessagesFixtures.sample), contacts: .notDetermined, rig: &rigs)
        try shoot("messages", "contacts-hint", hint)
        let reply = module(.snapshot(MessagesFixtures.sample), rig: &rigs)
        reply.select(reply.threads[0].id)
        reply.draft = "Oui, à 19 h !"
        rigs.last?.sender.result = .failure(.notAuthorized)
        reply.sendDraft()
        try shoot("messages", "reply-denied", reply)
        try shoot("messages", "empty", module(.snapshot(MessagesSnapshot(rows: [], unread: 0)), rig: &rigs))
        try shoot("messages", "full-disk-access", module(.unavailable(.needsFullDiskAccess), rig: &rigs))
        try shoot("messages", "no-database", module(.unavailable(.noDatabase), rig: &rigs))
        try shoot("messages", "unsupported", module(.unavailable(.unsupported), rig: &rigs))
    }

    /// Mail : les derniers mails, tout lu, puis chaque état où Mail n'est pas lisible (fermé, pas autorisé, refusé, sans compte).
    private func mail() throws {
        MessagesFixtures.now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        var rigs: [MailRig] = []
        addTeardownBlock { rigs.removeAll() }
        func module(_ configure: (MailRig) -> Void) -> MailModule {
            let rig = MailRig(self)
            rigs.append(rig)
            rig.runner.repeatLast = true
            configure(rig)
            let module = rig.makeModule()
            module.tabAppeared()
            module.start()
            addTeardownBlock { module.stop() }
            return module
        }
        let sample: [FakeMail] = (0..<5).map {
            FakeMail(sender: "Expéditeur \($0 + 1) <exp\($0)@example.com>",
                     subject: "Objet du message numéro \($0 + 1), assez long pour être coupé en fin de ligne",
                     age: 300 + $0 * 1_800, id: "id\($0)@example.com", unread: $0 < 2,
                     snippet: "Début du texte du message numéro \($0 + 1) : une ou deux lignes suffisent pour savoir de quoi il s'agit, sans ouvrir Mail.")
        }
        let list = module { $0.runner.answers = [.success(MailRig.answer(unread: 21, messages: sample))] }
        try shoot("mail", "list", list)
        try settings("mail", list)
        var read = sample
        for index in read.indices { read[index].unread = false }
        try shoot("mail", "all-read", module { $0.runner.answers = [.success(MailRig.answer(unread: 0, messages: read))] })
        try shoot("mail", "not-running", module { $0.running = false })
        try shoot("mail", "needs-permission", module { $0.probeStatus = .notDetermined })
        try shoot("mail", "denied", module { $0.probeStatus = .denied })
        try shoot("mail", "no-account", module { $0.runner.answers = [.success(MailRig.answer(unread: 0, accounts: 0))] })
        try shoot("mail", "failed", module { $0.runner.answers = [.failure(.timedOut)] })
    }

    private func notes() throws {
        let rig = try NotesRig(self)
        rig.clock.now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let empty = rig.startedModule()
        addTeardownBlock { empty.stop() }
        try shoot("notes", "empty", empty)

        let filled = try notesModule()
        filled.togglePin(filled.notes[2].id)
        filled.select(filled.notes.first { $0.text.hasPrefix("Réunion") }!.id)
        try shoot("notes", "filled", filled)
        try settings("notes", filled)

        let many = try notesModule(count: 10)
        many.query = "réunion"
        try shoot("notes", "search", many)
        many.query = ""
        many.delete(many.notes[1].id)
        try shoot("notes", "undo", many)

        // Fichier en partie illisible : les bonnes notes, et où est la copie.
        let damaged = try NotesRig(self)
        let hourAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))
        let json = "{\"version\":1,\"notes\":[{\"id\":\"\(UUID().uuidString)\",\"text\":\"Courses : lait, œufs, pain\","
            + "\"updated\":\"\(hourAgo)\"},{\"id\":\"cassé\",\"text\":\"x\"}]}"
        try Data(json.utf8).write(to: damaged.fileURL)
        let salvaged = damaged.startedModule()
        addTeardownBlock { salvaged.stop() }
        try shoot("notes", "error-salvaged", salvaged)
    }

    // MARK: - Plein écran compact

    /// Le résumé de chaque module dans le panneau compact (270 pt), un seul rendu : tout rempli, puis tout vide.
    private func fullScreenSummaries() throws {
        let filled: [any NotchModule] = [
            try mediaModule(lines: [playingLine()], access: .granted, events: mediaEvents()),
            quickFixture { $0.battery.iops = [QSFakeBattery.mac(percent: 78)] }.module,
            try shelfModule(["Rapport.pdf", "Maquette.png", "Photo.jpg", "notes.md", "Archive.zip"]).0,
            try timerModule { rig, module in
                module.setMode(.pomodoro)
                module.startTimer()
                rig.clock.advance(7 * 60 + 13)
                module.tick()
            },
        ]
        try shoot("compact", "filled", size: nil, replacing: filled, store: .working(2), fullScreen: true)
        let quiet = quickFixture {
            $0.wifi.power = nil
            $0.battery.iops = []
        }
        try shoot("compact", "empty", size: nil, replacing: [try mediaModule(lines: [], access: .notDetermined), quiet.module,
                                                           try shelfModule([]).0, try timerModule()],
                  fullScreen: true)
    }

    // MARK: - Mesure et rendu

    /// Panneau hors écran : SwiftUI met la vue en page et la forme mesure sa taille.
    private func measure(_ root: NotchRootView, _ model: NotchViewModel, settle: TimeInterval = 0.35) -> CGSize {
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: NotchController.panelSize)
        let window = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        window.close()
        return model.contentSize
    }

    /// Fenêtre hors écran + rendu de l'arbre de calques (même méthode que SnapshotTests).
    private func render<V: View>(_ view: V, _ name: String, _ dir: URL, size: CGSize,
                                 background: Color? = Color(white: 0.85)) throws {
        let hosting = NSHostingView(rootView: view.background(background ?? Color(nsColor: .windowBackgroundColor)))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let layer = hosting.layer,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                            pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return XCTFail("rendu impossible") }
        context.cgContext.translateBy(x: 0, y: size.height * scale)
        context.cgContext.scaleBy(x: scale, y: -scale)
        layer.render(in: context.cgContext)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return XCTFail("PNG") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        window.close()
    }
}
