import Foundation
@testable import Oriel

/// Fichiers CF1 / CF3 / CF4 dans un dossier temporaire, pour les tests et les captures.
struct ToolsFixtures {
    let directory: URL
    let paths: ToolsFeed.Paths

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriel-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        paths = ToolsFeed.Paths(files: directory.appendingPathComponent("files.jsonl"),
                                gitState: directory.appendingPathComponent("state.json"),
                                usage: directory.appendingPathComponent("today.json"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func writeLines(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func writeJSON(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    static func fileLine(_ path: String, ago: TimeInterval, now: Date, project: String? = nil,
                         session: String = "s1", source: String = "live") -> String {
        var record: [String: Any] = [
            "ts": ISODate.string(now.addingTimeInterval(-ago)), "path": path, "tool": "Edit",
            "session_id": session, "cwd": (path as NSString).deletingLastPathComponent, "source": source,
        ]
        record["project"] = project
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Jeu de données réaliste : fichiers récents, git avec deux dépôts à traiter, usage du jour.
    func writeSample(now: Date, gitClean: Bool = false) throws {
        let base = "/Users/x/Projets"
        try writeLines([
            Self.fileLine("\(base)/mon-app/Sources/Parser.swift", ago: 180, now: now, project: "mon-app"),
            Self.fileLine("\(base)/mon-app/README.md", ago: 1500, now: now, project: "mon-app"),
            Self.fileLine("\(base)/api/src/routes/login.ts", ago: 3000, now: now, project: "api"),
            Self.fileLine("\(base)/mon-app/Sources/Parser.swift", ago: 40, now: now, project: "mon-app"),
            Self.fileLine("\(base)/site/content/blog/notes-de-version-octobre.md", ago: 7200, now: now, project: "site"),
            Self.fileLine("\(base)/api/src/old-config.ts", ago: 9000, now: now, project: "api"),
            Self.fileLine("/private/tmp/brouillon.txt", ago: 5, now: now, project: "tmp"),
            "{ ligne invalide",
            Self.fileLine("\(base)/site/index.html", ago: 86_400 * 3, now: now, project: "site"),
        ], to: paths.files)

        var repos: [[String: Any]] = [
            ["path": "\(base)/mon-app", "name": "mon-app", "branch": "main", "dirty": 3, "untracked": 1,
             "ahead": 2, "behind": 0, "no_upstream": false, "stashes": 0, "last_commit": ISODate.string(now),
             "fetched": true, "error": NSNull(), "needs_attention": true],
            ["path": "\(base)/api", "name": "api", "branch": "feature/login-oauth", "dirty": 0, "untracked": 0,
             "ahead": 0, "behind": 4, "no_upstream": false, "stashes": 1, "last_commit": ISODate.string(now),
             "fetched": true, "error": NSNull(), "needs_attention": true],
            ["path": "\(base)/site", "name": "site", "branch": "main", "dirty": 0, "untracked": 0,
             "ahead": 0, "behind": 0, "no_upstream": false, "stashes": 0, "last_commit": ISODate.string(now),
             "fetched": true, "error": NSNull(), "needs_attention": false],
        ]
        if gitClean {
            for index in repos.indices { repos[index]["needs_attention"] = false }
        }
        let attention = repos.filter { ($0["needs_attention"] as? Bool) == true }.count
        try writeJSON([
            "version": 1, "generated_at": ISODate.string(now.addingTimeInterval(-300)), "machine": "mac",
            "repos": repos,
            "summary": ["total": repos.count, "needs_attention": attention, "unpushed": 1, "behind": 1, "dirty": 1],
        ], to: paths.gitState)

        try writeJSON([
            "version": 1, "date": ToolsFeed.localDay(now), "generated_at": ISODate.string(now),
            "active_minutes": 130, "sessions": 6, "turns": 41,
            "top_projects": [["name": "mon-app", "minutes": 80], ["name": "api", "minutes": 35]],
        ], to: paths.usage)
    }
}
