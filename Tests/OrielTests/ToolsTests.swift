import XCTest
@testable import Oriel

/// Registres CF1 / CF2 écrits par l'app, lecture tolérante de CF1 / CF3 / CF4.
final class ToolsTests: XCTestCase {
    private var fixtures: ToolsFixtures!
    /// 2026-10-19 10:34:56 UTC
    private let now = Date(timeIntervalSince1970: 1_792_406_096)

    override func setUpWithError() throws {
        fixtures = try ToolsFixtures()
    }

    override func tearDown() {
        fixtures.remove()
    }

    private func event(_ name: String, _ extra: [String: Any] = [:]) -> HookEvent {
        var raw: [String: Any] = ["hook_event_name": name, "session_id": "sess-1", "cwd": "/Users/x/Projets/mon-app"]
        raw.merge(extra) { $1 }
        return HookEvent(raw: raw)
    }

    private func readLines(_ url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"), "chaque ligne se termine par un saut de ligne")
        return try text.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    // MARK: - CF1

    func testFilesLogFormat() throws {
        let directory = fixtures.directory.appendingPathComponent("Oriel")   // créé à la première écriture
        let log = ActivityLog(directory: directory)
        let session = Session(id: "sess-1", cwd: "/Users/x/Projets/mon-app")

        log.record(event("PostToolUse", ["tool_name": "Write", "tool_use_id": "t1",
                                         "tool_input": ["file_path": "/Users/x/Projets/mon-app/a.swift", "content": "x"]]),
                   session: session, now: now)
        log.record(event("PostToolUseFailure", ["tool_name": "Edit",
                                                "tool_input": ["file_path": "/Users/x/Projets/mon-app/b.swift"]]),
                   session: session, now: now)
        log.record(event("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "touch c"]]),
                   session: session, now: now)
        log.record(event("PreToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/Users/x/d.swift"]]),
                   session: session, now: now)
        log.record(event("PostToolUse", ["tool_name": "NotebookEdit",
                                         "tool_input": ["notebook_path": "/Users/x/Projets/mon-app/nb.ipynb"]]),
                   session: session, now: now)
        log.record(event("PostToolUse", ["tool_name": "MultiEdit", "tool_input": ["file_path": "src/rel.ts"]]),
                   session: nil, now: now)
        log.record(event("PostToolUse", ["tool_name": "Edit", "tool_input": ["file_path": ""]]),
                   session: session, now: now)
        log.flush()

        let lines = try readLines(log.filesURL)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(log.filesLogged, 3)
        XCTAssertEqual(Set(lines[0].keys), ["ts", "path", "tool", "session_id", "project", "cwd", "source"])
        XCTAssertEqual(lines[0]["ts"] as? String, "2026-10-19T10:34:56Z")
        XCTAssertEqual(lines[0]["path"] as? String, "/Users/x/Projets/mon-app/a.swift")
        XCTAssertEqual(lines[0]["tool"] as? String, "Write")
        XCTAssertEqual(lines[0]["session_id"] as? String, "sess-1")
        XCTAssertEqual(lines[0]["project"] as? String, "mon-app")
        XCTAssertEqual(lines[0]["cwd"] as? String, "/Users/x/Projets/mon-app")
        XCTAssertEqual(lines[0]["source"] as? String, "live")
        XCTAssertEqual(lines[1]["path"] as? String, "/Users/x/Projets/mon-app/nb.ipynb")
        XCTAssertEqual(lines[1]["tool"] as? String, "NotebookEdit")
        // Chemin relatif résolu depuis le cwd de l'événement (pas de session connue).
        XCTAssertEqual(lines[2]["path"] as? String, "/Users/x/Projets/mon-app/src/rel.ts")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.permissionsURL.path))

        // Les lignes s'ajoutent, rien n'est réécrit.
        log.record(event("PostToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/Users/x/e.swift"]]),
                   session: session, now: now)
        log.flush()
        XCTAssertEqual(try readLines(log.filesURL).count, 4)
        XCTAssertEqual(log.failedWrites, 0)
    }

    // MARK: - CF2

    func testPermissionsLogFormat() throws {
        let log = ActivityLog(directory: fixtures.directory)
        let session = Session(id: "sess-1", cwd: "/Users/x/Projets/mon-app")
        let long = "echo " + String(repeating: "a", count: 300)

        log.record(event("PermissionRequest", ["tool_name": "Bash",
                                               "tool_input": ["command": "\n  rm -rf build\nnpm test", "description": "x"]]),
                   session: session, now: now)
        log.record(event("PermissionRequest", ["tool_name": "Edit", "tool_input": ["file_path": "/etc/hosts"]]),
                   session: session, now: now)
        log.record(event("PermissionRequest", ["tool_name": "WebFetch", "tool_input": ["url": "https://example.com/a"]]),
                   session: session, now: now)
        log.record(event("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": long]]),
                   session: session, now: now)
        log.record(event("PermissionRequest", ["tool_name": "mcp__github__create_issue"]), session: nil, now: now)
        log.record(event("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "ls"]]), session: session, now: now)
        log.flush()

        let lines = try readLines(log.permissionsURL)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(log.permissionsLogged, 5)
        XCTAssertEqual(Set(lines[0].keys), ["ts", "session_id", "project", "tool", "detail"])
        XCTAssertEqual(lines[0]["ts"] as? String, "2026-10-19T10:34:56Z")
        XCTAssertEqual(lines[0]["session_id"] as? String, "sess-1")
        XCTAssertEqual(lines[0]["project"] as? String, "mon-app")
        XCTAssertEqual(lines[0]["tool"] as? String, "Bash")
        XCTAssertEqual(lines[0]["detail"] as? String, "rm -rf build")
        XCTAssertEqual(lines[1]["detail"] as? String, "/etc/hosts")
        XCTAssertEqual(lines[2]["detail"] as? String, "Web · example.com")
        let truncated = try XCTUnwrap(lines[3]["detail"] as? String)
        XCTAssertEqual(truncated.count, 200)
        XCTAssertTrue(truncated.hasPrefix("echo aaa"))
        XCTAssertEqual(lines[4]["detail"] as? String, "github · create_issue")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.filesURL.path))
    }

    func testISODates() {
        XCTAssertEqual(ISODate.string(now), "2026-10-19T10:34:56Z")
        XCTAssertEqual(ISODate.parse("2026-10-19T10:34:56Z"), now)
        XCTAssertEqual(ISODate.parse("2026-10-19T10:34:56+00:00"), now)
        XCTAssertEqual(ISODate.parse("2026-10-19T12:34:56+02:00"), now)
        XCTAssertEqual(ISODate.parse("2026-10-19T10:34:56.123Z")?.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970 + 0.123, accuracy: 0.001)
        // Microsecondes à la Python : la fraction est ignorée si le format strict échoue.
        XCTAssertEqual(ISODate.parse("2026-10-19T10:34:56.123456+00:00")?.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(ISODate.parse("hier"))
        XCTAssertNil(ISODate.parse(""))
    }

    // MARK: - Lecture CF1

    func testFileProjectFollowsTheFileNotAStaleCwd() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("Oriel")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        let other = root.appendingPathComponent("claude-usage").path

        // Après un `cd` ailleurs : le dépôt du fichier, pas le cwd.
        XCTAssertEqual(ActivityLog.projectName(forFile: repo.appendingPathComponent("Sources/App/x.swift").path, cwd: other),
                       "Oriel")
        // Sous le cwd : le projet du cwd, même dans un sous-dépôt.
        XCTAssertEqual(ActivityLog.projectName(forFile: other + "/README.md", cwd: other), "claude-usage")
        // Ni sous le cwd ni dans un dépôt : le dossier parent.
        XCTAssertEqual(ActivityLog.projectName(forFile: root.appendingPathComponent("notes/a.md").path, cwd: other), "notes")
    }

    func testRecentFilesParsing() throws {
        try fixtures.writeSample(now: now)
        let data = try Data(contentsOf: fixtures.paths.files)
        let files = ToolsFeed.recentFiles(from: data)

        // Doublon fusionné (le plus récent gagne), /private/tmp exclu, ligne invalide ignorée, 5 au plus.
        XCTAssertEqual(files.map(\.name), ["Parser.swift", "README.md", "login.ts",
                                           "notes-de-version-octobre.md", "old-config.ts"])
        XCTAssertEqual(files[0].date, now.addingTimeInterval(-40))
        XCTAssertEqual(files[0].project, "mon-app")
        XCTAssertEqual(Set(files.map(\.path)).count, files.count)
    }

    func testRecentFilesOrderedByTimestampNotByLine() {
        // Un rattrapage (backfill) ajoute des lignes anciennes après les lignes en direct.
        let lines = [
            ToolsFixtures.fileLine("/Users/x/p/live.swift", ago: 60, now: now),
            ToolsFixtures.fileLine("/Users/x/p/old.swift", ago: 86_400, now: now, source: "backfill"),
            ToolsFixtures.fileLine("/Users/x/p/live.swift", ago: 7200, now: now, source: "backfill"),
            #"{"ts": "2026-10-19T10:00:00Z", "path": "relatif.txt"}"#,
            #"{"ts": 12, "path": "/Users/x/p/sans-date.txt"}"#,
            #"{"path": "/Users/x/p/sans-ts.txt"}"#,
            #"["pas", "un", "objet"]"#,
            #"{"ts": "2026-10-19T10:00:00Z", "path": "/var/folders/ab/T/x.txt"}"#,
            #"{"ts": "2026-10-19T10:00:00Z", "path": "/Users/x/Library/Application Support/Claude/scratch-workspaces/a/b.md"}"#,
            #"{"ts": "2026-10-19T10:00:00Z", "path": "/Users/x/proj/sans-projet.md"}"#,
            #"{"ts": "2026-10-19T09:00:00Z", "path": "/Users/x/Notes/plan.md", "project": "scratch-2026-10-19-ab12", "cwd": "/Users/x/Library/Application Support/Claude/scratch-workspaces/u/v/scratch-2026-10-19-ab12"}"#,
        ]
        let files = ToolsFeed.recentFiles(from: Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(files.map(\.name), ["live.swift", "sans-projet.md", "plan.md", "old.swift"])
        XCTAssertEqual(files[0].date, now.addingTimeInterval(-60))
        XCTAssertEqual(files[0].project, "p")
        XCTAssertEqual(files[1].project, "proj", "projet absent : dossier parent")
        XCTAssertEqual(files[2].project, "Notes", "cwd jetable : dossier parent du fichier")
        XCTAssertTrue(ToolsFeed.isTemporary("/tmp/a"))
        XCTAssertTrue(ToolsFeed.isTemporary("/Users/x/.claude/scratchpad/a"))
        XCTAssertFalse(ToolsFeed.isTemporary("/Users/x/Projets/tmp/a"))
    }

    func testIncrementalReadOfFilesLog() throws {
        let url = fixtures.paths.files
        var lines: [String] = []
        for index in 0..<200 {
            lines.append(ToolsFixtures.fileLine("/Users/x/p/f\(index).swift", ago: TimeInterval(10_000 - index), now: now))
        }
        try fixtures.writeLines(lines, to: url)
        XCTAssertNil(ToolsFeed.updateFiles(fixtures.directory.appendingPathComponent("absent.jsonl"), cache: nil))

        // Premier passage limité à la fin du fichier : la ligne coupée au début est écartée.
        let tail = try XCTUnwrap(ToolsFeed.updateFiles(url, cache: nil, initialLimit: 1000))
        XCTAssertEqual(tail.candidates.first?.name, "f199.swift")
        XCTAssertLessThan(tail.candidates.count, 10)

        let full = try XCTUnwrap(ToolsFeed.updateFiles(url, cache: nil))
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
        XCTAssertEqual(full.offset, size.uint64Value)
        XCTAssertEqual(full.candidates.count, ToolsFeed.keptCandidates)
        XCTAssertEqual(ToolsFeed.updateFiles(url, cache: full)?.offset, full.offset, "inchangé : rien relu")

        // Ajout d'un gros rattrapage ancien puis d'une ligne en cours d'écriture (sans saut de ligne).
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        var backfill = ""
        for index in 0..<300 {
            backfill += ToolsFixtures.fileLine("/Users/x/vieux/v\(index).md", ago: 90 * 86_400, now: now,
                                               source: "backfill") + "\n"
        }
        handle.write(Data(backfill.utf8))
        handle.write(Data(ToolsFixtures.fileLine("/Users/x/p/en-cours.swift", ago: 1, now: now).utf8))
        let grown = try XCTUnwrap(ToolsFeed.updateFiles(url, cache: full))
        XCTAssertEqual(grown.candidates.prefix(2).map(\.name), ["f199.swift", "f198.swift"],
                       "le rattrapage ancien ne chasse pas les fichiers récents")
        XCTAssertFalse(grown.candidates.contains { $0.name == "en-cours.swift" })

        handle.write(Data("\n".utf8))
        try handle.close()
        let completed = try XCTUnwrap(ToolsFeed.updateFiles(url, cache: grown))
        XCTAssertEqual(completed.candidates.first?.name, "en-cours.swift")

        // Fichier remplacé (plus petit) : relu depuis le début.
        try fixtures.writeLines([ToolsFixtures.fileLine("/Users/x/p/seul.swift", ago: 5, now: now)], to: url)
        let replaced = try XCTUnwrap(ToolsFeed.updateFiles(url, cache: completed))
        XCTAssertEqual(replaced.candidates.map(\.name), ["seul.swift"])
    }

    // MARK: - Lecture CF3

    func testGitState() throws {
        try fixtures.writeSample(now: now)
        let git = try XCTUnwrap(ToolsFeed.gitStatus(at: fixtures.paths.gitState, now: now))
        XCTAssertEqual(git.total, 3)
        XCTAssertEqual(git.needsAttention, 2)
        XCTAssertEqual(git.repos.map(\.name), ["mon-app", "api"])
        XCTAssertEqual(git.repos[0].ahead, 2)
        XCTAssertEqual(git.repos[0].dirty, 3)
        XCTAssertEqual(git.repos[1].behind, 4)
        XCTAssertEqual(git.text, "Git · 2 dépôts à traiter")

        // Périmé (plus de 2 h) : rien.
        XCTAssertNil(ToolsFeed.gitStatus(at: fixtures.paths.gitState, now: now.addingTimeInterval(2 * 3600)))

        // Tout est poussé.
        try fixtures.writeSample(now: now, gitClean: true)
        let clean = try XCTUnwrap(ToolsFeed.gitStatus(at: fixtures.paths.gitState, now: now))
        XCTAssertEqual(clean.needsAttention, 0)
        XCTAssertEqual(clean.text, "Git · tout est poussé")

        // Tolérance : champs manquants, résumé absent, dépôt sans chemin.
        try fixtures.writeJSON(["generated_at": ISODate.string(now), "repos": [
            ["path": "/r/one", "needs_attention": true, "ahead": "x"],
            ["name": "sans-chemin", "needs_attention": true],
        ]], to: fixtures.paths.gitState)
        let partial = try XCTUnwrap(ToolsFeed.gitStatus(at: fixtures.paths.gitState, now: now))
        XCTAssertEqual(partial.total, 1)
        XCTAssertEqual(partial.repos.first?.name, "one")
        XCTAssertEqual(partial.repos.first?.ahead, 0)
        XCTAssertEqual(partial.text, "Git · 1 dépôt à traiter")

        try "{ pas du json".write(to: fixtures.paths.gitState, atomically: true, encoding: .utf8)
        XCTAssertNil(ToolsFeed.gitStatus(at: fixtures.paths.gitState, now: now))
        try fixtures.writeJSON(["generated_at": "n'importe quoi", "repos": "non"], to: fixtures.paths.gitState)
        XCTAssertNil(ToolsFeed.gitStatus(at: fixtures.paths.gitState, now: now))
        XCTAssertNil(ToolsFeed.gitStatus(at: fixtures.directory.appendingPathComponent("absent.json"), now: now))
    }

    // MARK: - Lecture CF4

    func testUsage() throws {
        try fixtures.writeSample(now: now)
        let usage = try XCTUnwrap(ToolsFeed.usage(at: fixtures.paths.usage, now: now))
        XCTAssertEqual(usage.activeMinutes, 130)
        XCTAssertEqual(usage.sessions, 6)
        XCTAssertEqual(usage.text, "Aujourd'hui · 2 h 10 · 6 sessions")
        XCTAssertEqual(usage.topProjectsText, "mon-app 1 h 20 · api 35 min")

        // Un autre jour : rien.
        XCTAssertNil(ToolsFeed.usage(at: fixtures.paths.usage, now: now.addingTimeInterval(86_400)))

        XCTAssertEqual(ToolsFeed.Usage.duration(minutes: 45), "45 min")
        XCTAssertEqual(ToolsFeed.Usage.duration(minutes: 120), "2 h")
        XCTAssertEqual(ToolsFeed.Usage.duration(minutes: 125), "2 h 05")
        XCTAssertEqual(ToolsFeed.Usage(activeMinutes: 0, sessions: 1, turns: 0, topProjects: []).text,
                       "Aujourd'hui · 0 min · 1 session")

        try fixtures.writeJSON(["date": ToolsFeed.localDay(now)], to: fixtures.paths.usage)
        XCTAssertEqual(ToolsFeed.usage(at: fixtures.paths.usage, now: now)?.sessions, 0)
        try "[]".write(to: fixtures.paths.usage, atomically: true, encoding: .utf8)
        XCTAssertNil(ToolsFeed.usage(at: fixtures.paths.usage, now: now))
        XCTAssertNil(ToolsFeed.usage(at: fixtures.directory.appendingPathComponent("absent.json"), now: now))
    }

    // MARK: - Flux

    func testFeedReadsOnlyWhileActive() throws {
        let realNow = Date()
        try fixtures.writeSample(now: realNow)
        let feed = ToolsFeed(paths: fixtures.paths) { !$0.hasSuffix("old-config.ts") }
        XCTAssertFalse(feed.hasContent)

        // Replié : aucune lecture.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(feed.refreshCount, 0)

        feed.setActive(true)
        let deadline = Date().addingTimeInterval(5)
        while feed.refreshCount == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(feed.refreshCount, 1)
        XCTAssertTrue(feed.hasContent)
        XCTAssertEqual(feed.recentFiles.count, 5)
        XCTAssertEqual(feed.recentFiles.filter { !$0.exists }.map(\.name), ["old-config.ts"])
        XCTAssertEqual(feed.git?.needsAttention, 2)
        XCTAssertEqual(feed.usage?.sessions, 6)

        let summary = feed.debugSummary
        XCTAssertEqual(summary["active"] as? Bool, true)
        XCTAssertEqual(summary["recentFiles"] as? Int, 5)
        XCTAssertEqual(summary["missingFiles"] as? Int, 1)
        XCTAssertEqual((summary["git"] as? [String: Any])?["needsAttention"] as? Int, 2)
        XCTAssertEqual((summary["usage"] as? [String: Any])?["sessions"] as? Int, 6)
        XCTAssertNotNil(summary["lastRefresh"] as? String)
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: summary), "sérialisable pour GET /state")

        feed.setActive(false)
        XCTAssertFalse(feed.isActive)

        // Fichiers supprimés : la section disparaît à la lecture suivante.
        fixtures.remove()
        feed.refreshNow()
        XCTAssertFalse(feed.hasContent)
    }

    /// Bout en bout : payloads réels envoyés au serveur de hooks, registres écrits, compteurs dans `GET /state`.
    func testHookServerWritesRegistriesAndState() throws {
        let log = ActivityLog(directory: fixtures.directory.appendingPathComponent("Oriel"))
        let core = AppCore(tools: ToolsFeed(paths: fixtures.paths), activityLog: log)
        let port = UInt16.random(in: 49_200...60_000)
        // Jeton en mémoire seulement : jamais le fichier de l'app installée.
        let access = HookAccess(file: nil)
        let server = HookServer(port: port, access: access, handler: AppCore.hookHandler(store: core.store, log: log))
        server.stateProvider = { core.debugState() }
        try server.start()
        defer { server.stop() }

        // Le serveur répond depuis sa queue et `GET /state` passe par le main thread : on fait tourner la boucle.
        func request(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> (Int, Data) {
            var url = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            url.httpMethod = method
            url.setValue(access.token, forHTTPHeaderField: HookAccess.headerName)
            url.httpBody = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            var result: (Int, Data)?
            let deadline = Date().addingTimeInterval(5)
            while result == nil, Date() < deadline {
                var done = false
                URLSession.shared.dataTask(with: url) { data, response, _ in
                    if let status = (response as? HTTPURLResponse)?.statusCode { result = (status, data ?? Data()) }
                    done = true
                }.resume()
                while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                if result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            }
            return result ?? (0, Data())
        }

        let base: [String: Any] = ["session_id": "f34e31e3-eb3c-43d5-ae38-2a4738e4b486", "cwd": "/Users/x/Projets/mon-app",
                                   "transcript_path": "/nonexistent/projects/p/x.jsonl", "permission_mode": "default"]
        var write = base
        write.merge(["hook_event_name": "PostToolUse", "tool_name": "Write", "tool_use_id": "toolu_01",
                     "tool_input": ["file_path": "/Users/x/Projets/mon-app/Sources/App.swift", "content": "x"],
                     "tool_response": ["type": "create", "filePath": "/Users/x/Projets/mon-app/Sources/App.swift"]]) { $1 }
        var failed = base
        failed.merge(["hook_event_name": "PostToolUseFailure", "tool_name": "Edit", "tool_use_id": "toolu_02",
                      "tool_input": ["file_path": "/Users/x/Projets/mon-app/b.swift"], "error": "String not found"]) { $1 }
        var permission = base
        permission.merge(["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                          "tool_input": ["command": "rm -rf build\necho fini", "description": "Supprime build"],
                          "permission_suggestions": []]) { $1 }
        XCTAssertEqual(request("POST", "/hook", write).0, 204)
        XCTAssertEqual(request("POST", "/hook", failed).0, 204)
        XCTAssertEqual(request("POST", "/hook", permission).0, 204)

        let deadline = Date().addingTimeInterval(5)
        while log.filesLogged + log.permissionsLogged < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        log.flush()
        let files = try readLines(log.filesURL)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?["path"] as? String, "/Users/x/Projets/mon-app/Sources/App.swift")
        XCTAssertEqual(files.first?["project"] as? String, "mon-app")
        let permissions = try readLines(log.permissionsURL)
        XCTAssertEqual(permissions.count, 1)
        XCTAssertEqual(permissions.first?["detail"] as? String, "rm -rf build")

        let (status, body) = request("GET", "/state")
        XCTAssertEqual(status, 200)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try XCTUnwrap(state["tools"] as? [String: Any])
        XCTAssertEqual(tools["filesLogged"] as? Int, 1)
        XCTAssertEqual(tools["permissionsLogged"] as? Int, 1)
        XCTAssertEqual(tools["failedWrites"] as? Int, 0)
        XCTAssertEqual(tools["active"] as? Bool, false)
        XCTAssertEqual(tools["recentFiles"] as? Int, 0)
        XCTAssertEqual(tools["logDirectory"] as? String, log.directory.path)
    }

    /// Rejoue les payloads réels capturés (`ORIEL_REPLAY_LOG`) vers des registres temporaires.
    func testReplayCapturedLogIntoRegistries() throws {
        guard let path = ProcessInfo.processInfo.environment["ORIEL_REPLAY_LOG"] else {
            throw XCTSkip("ORIEL_REPLAY_LOG non défini")
        }
        let store = SessionStore()
        let log = ActivityLog(directory: fixtures.directory)
        var expectedFiles = 0, expectedPermissions = 0
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            let event = HookEvent(raw: payload)
            if event.name == "PostToolUse", ActivityLog.fileTools.contains(event.toolName ?? "") { expectedFiles += 1 }
            if event.name == "PermissionRequest" { expectedPermissions += 1 }
            store.handle(event, context: ProcessContext())
            log.record(event, session: event.sessionId.flatMap { store.sessions[$0] })
        }
        log.flush()
        let files = (try? readLines(log.filesURL)) ?? []
        let permissions = (try? readLines(log.permissionsURL)) ?? []
        XCTAssertEqual(files.count, expectedFiles)
        XCTAssertEqual(permissions.count, expectedPermissions)
        for line in files {
            XCTAssertEqual(Set(line.keys), ["ts", "path", "tool", "session_id", "project", "cwd", "source"])
            XCTAssertTrue((line["path"] as? String)?.hasPrefix("/") ?? false)
            XCTAssertFalse((line["session_id"] as? String)?.isEmpty ?? true)
        }
        for line in permissions {
            XCTAssertEqual(Set(line.keys), ["ts", "session_id", "project", "tool", "detail"])
            XCTAssertLessThanOrEqual((line["detail"] as? String)?.count ?? 999, 200)
        }
        print("REPLAY registres : CF1 \(files.count) lignes (\(Set(files.compactMap { $0["tool"] as? String }).sorted())), "
              + "CF2 \(permissions.count) lignes (\(Set(permissions.compactMap { $0["tool"] as? String }).sorted()))")
    }

    func testRevealTargetFallsBackToParent() throws {
        let file = fixtures.directory.appendingPathComponent("present.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(NotchController.revealTarget(for: file.path)?.lastPathComponent, "present.txt")
        let missing = fixtures.directory.appendingPathComponent("disparu/sous/fichier.txt")
        XCTAssertEqual(NotchController.revealTarget(for: missing.path)?.standardizedFileURL.path,
                       fixtures.directory.standardizedFileURL.path)
    }
}
