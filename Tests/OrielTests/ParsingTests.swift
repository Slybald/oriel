import XCTest
@testable import Oriel

final class ParsingTests: XCTestCase {
    func testHTTPRequestNeedsFullBody() {
        let body = #"{"hook_event_name":"Stop"}"#
        let head = "POST /hook HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\nX-Claude-PPID: 42\r\n\r\n"
        let full = Data((head + body).utf8)

        guard case .needMore = HTTPRequest.parse(full.prefix(full.count - 3), maxBody: 1024) else {
            return XCTFail("corps incomplet attendu")
        }
        guard case .complete(let request) = HTTPRequest.parse(full, maxBody: 1024) else {
            return XCTFail("requête complète attendue")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/hook")
        XCTAssertEqual(HookHeaders(request.headers).ppid, 42)
        XCTAssertEqual(HookEvent(data: request.body)?.name, "Stop")
    }

    func testHTTPRequestTooLarge() {
        let head = Data("POST /hook HTTP/1.1\r\nContent-Length: 99999\r\n\r\n".utf8)
        guard case .tooLarge = HTTPRequest.parse(head, maxBody: 1000) else {
            return XCTFail("413 attendu")
        }
    }

    func testToolDescriptions() {
        XCTAssertEqual(ToolDescriber.describe(tool: "Bash", input: ["command": "npm test\nnpm run lint"]).text,
                       "Terminal · npm test")
        XCTAssertEqual(ToolDescriber.describe(tool: "Bash", input: ["command": "ls", "description": "Liste"]).text,
                       "Terminal · Liste")
        XCTAssertEqual(ToolDescriber.describe(tool: "Edit", input: ["file_path": "/a/b/App.swift"]).text,
                       "Édition · App.swift")
        XCTAssertEqual(ToolDescriber.describe(tool: "WebFetch", input: ["url": "https://example.com/x"]).text,
                       "Web · example.com")
        XCTAssertEqual(ToolDescriber.describe(tool: "mcp__github__create_issue", input: nil).text,
                       "github · create_issue")
    }

    func testCleanMarkdown() {
        XCTAssertEqual(ToolDescriber.cleanMarkdown("\n## **Fini** : voir [le fichier](a.md)\nsuite"),
                       "Fini : voir le fichier")
        XCTAssertEqual(ToolDescriber.cleanMarkdown("```\ncode\n```\n- `x` modifié"), "x modifié")
    }

    func testProcessNames() {
        XCTAssertTrue(ProcessInspector.isVersionName("2.1.296"))
        XCTAssertFalse(ProcessInspector.isVersionName("Claude"))
        XCTAssertFalse(ProcessInspector.isVersionName("2."))
        XCTAssertEqual(ProcessInspector.outermostBundlePath(
            "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
            "/Applications/Visual Studio Code.app")
    }

    func testDesktopSessionLink() {
        let id = "local_00000000-1111-4222-8333-444444444444"
        XCTAssertEqual(HookHeaders(["x-host-session-id": id]).hostSessionId, id)
        XCTAssertNil(HookHeaders(["x-host-session-id": "local_x&evil=1"]).hostSessionId)
        XCTAssertNil(HookHeaders(["x-host-session-id": "cse_abc"]).hostSessionId)
        XCTAssertEqual(NotchController.desktopSessionURL(id)?.absoluteString, "claude://code/continue?session=\(id)")
        XCTAssertNil(NotchController.desktopSessionURL("local_"))

        let store = SessionStore()
        store.handle(HookEvent(raw: ["hook_event_name": "SessionStart", "session_id": "s", "cwd": "/p"]),
                     context: ProcessContext(source: .desktop, desktopSessionId: id))
        XCTAssertEqual(store.sessions["s"]?.desktopSessionId, id)
        XCTAssertEqual(store.sessions["s"]?.sourceLabel, "Claude Code (app)")
    }

    func testInterruptLine() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        XCTAssertTrue(SessionStore.isInterruptLine(Data(line.utf8)))
        let quoted = #"{"type":"assistant","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        XCTAssertFalse(SessionStore.isInterruptLine(Data(quoted.utf8)))
    }
}
