import Foundation
import MCP
import Testing

@testable import MailMCPKit

@Suite("Path guard")
struct PathGuardTests {
    let home: String
    let guardian: PathGuard

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)").path
        for sub in ["Downloads", ".ssh", "Library/LaunchAgents", "Library/Mail/V10", "code/.git/hooks", "Documents"] {
            try FileManager.default.createDirectory(atPath: home + "/" + sub, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: home + "/.ssh/id_ed25519", contents: Data("key".utf8))
        FileManager.default.createFile(atPath: home + "/Documents/report.pdf", contents: Data("pdf".utf8))
        FileManager.default.createFile(atPath: home + "/Documents/.env", contents: Data("SECRET=1".utf8))
        guardian = PathGuard(home: home)
    }

    @Test func writesAllowedInOrdinaryFolders() throws {
        #expect(try guardian.checkWrite(home + "/Downloads").hasSuffix("/Downloads"))
        #expect(try guardian.checkWrite(home + "/Downloads/new/folder/file.txt").hasSuffix("/new/folder/file.txt"))
    }

    @Test func writesRefusedInDangerousPlaces() {
        for path in [
            "/.zshrc", "/.ssh/authorized_keys", "/Library/LaunchAgents/x.plist", "/code/.git/hooks/pre-commit",
            "/Downloads/../.zprofile", "/Library/Mail/V10/x", "/project/.envrc",
        ] {
            #expect(throws: PathGuard.Denied.self, "\(path)") { try guardian.checkWrite(home + path) }
        }
        #expect(throws: PathGuard.Denied.self) { try guardian.checkWrite("/etc/hosts") }
        #expect(throws: PathGuard.Denied.self) { try guardian.checkWrite("/usr/local/bin/tool") }
    }

    @Test func symlinksCannotEscape() throws {
        let link = home + "/Downloads/sneaky"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home + "/Library/LaunchAgents")
        #expect(throws: PathGuard.Denied.self) { try guardian.checkWrite(link + "/evil.plist") }
    }

    @Test func caseInsensitiveMatching() {
        #expect(throws: PathGuard.Denied.self) { try guardian.checkWrite(home + "/library/launchagents/x.plist") }
    }

    @Test func writeAllowlist() throws {
        let restricted = PathGuard(writeAllowlist: [home + "/Downloads"], home: home)
        #expect(throws: Never.self) { try restricted.checkWrite(home + "/Downloads/a.txt") }
        #expect(throws: PathGuard.Denied.self) { try restricted.checkWrite(home + "/Documents/a.txt") }
    }

    @Test func attachments() throws {
        #expect(try guardian.checkAttachment(home + "/Documents/report.pdf").hasSuffix("report.pdf"))
        for path in ["/.ssh/id_ed25519", "/Documents/.env", "/Library/Mail/V10", "/Documents/missing.pdf", "/Documents"] {
            #expect(throws: PathGuard.Denied.self, "\(path)") { try guardian.checkAttachment(home + path) }
        }
        let restricted = PathGuard(attachAllowlist: [home + "/Downloads"], home: home)
        #expect(throws: PathGuard.Denied.self) { try restricted.checkAttachment(home + "/Documents/report.pdf") }
    }
}

@Suite("Arguments and JSON")
struct ArgumentTests {
    @Test func tolerantParsing() throws {
        let args = Arguments([
            "ids": .array([1, "2", 2, 3.0]), "csv": "a@x, b@y;c@z", "flag": "yes", "n": "12", "list": .array(["x", " "]),
            "day": "2026-03-04", "iso": "2026-03-04T10:00:00Z", "blank": "  ",
        ])
        #expect(try args.ids("ids") == [1, 2, 3])
        #expect(try args.strings("csv") == ["a@x", "b@y", "c@z"])
        #expect(try args.strings("list") == ["x"])
        #expect(try args.bool("flag") == true)
        #expect(try args.int("n") == 12)
        #expect(try args.string("blank") == nil)
        #expect(try args.string("missing") == nil)
        #expect(try args.date("iso") == ISO8601DateFormatter().date(from: "2026-03-04T10:00:00Z"))
        let start = try #require(try args.date("day"))
        let end = try #require(try args.date("day", endOfDay: true))
        #expect(end.timeIntervalSince(start) == 86_399)
        #expect(throws: ToolError.self) { try Arguments(["n": "x"]).int("n") }
        #expect(throws: ToolError.self) { try Arguments(["ids": .array(["abc"])]).ids("ids") }
        #expect(throws: ToolError.self) { try args.requiredString("missing") }
    }

    @Test func jsonKeepsOrderAndEscapes() {
        let json = JSON.obj([("id", .int(1)), ("skip", nil), ("text", .string("a\"b\\c\nd\u{1}é")), ("list", .array([.bool(true), .null]))])
        #expect(json.serialized() == #"{"id":1,"text":"a\"b\\c\nd\u0001é","list":[true,null]}"#)
        #expect(JSON.object([]).serialized() == "{}")
    }
}

@Suite("Settings, approvals and activity")
struct SharedStateTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "shared-\(UUID().uuidString)")

    @Test func settingsDecodeWithDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "settings.json")
        try Data(#"{"sendPolicy":"confirm","unknownKey":1}"#.utf8).write(to: url)
        let settings = Settings.load(from: url)
        #expect(settings.sendPolicy == .confirm)
        #expect(settings.allowMailChanges)
        #expect(settings.maxBatchSize == 50)
        #expect(Settings.load(from: directory.appending(path: "missing.json")) == Settings())
    }

    @Test func settingsProviderAppliesOverridesAndReloads() throws {
        let url = directory.appending(path: "settings.json")
        var settings = Settings()
        settings.maxBatchSize = 5
        try settings.save(to: url)
        let provider = SettingsProvider(url: url) { $0.sendPolicy = .never }
        #expect(provider.current.maxBatchSize == 5)
        #expect(provider.current.sendPolicy == .never)
        settings.maxBatchSize = 9
        try settings.save(to: url)
        // Modification dates have one-second resolution on some file systems.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(provider.current.maxBatchSize == 9)
    }

    @Test func approvalTimesOut() async throws {
        let center = ApprovalCenter(directory: directory.appending(path: "approvals"), heartbeat: directory.appending(path: "hb"))
        #expect(!center.isAgentRunning())
        center.beat()
        #expect(center.isAgentRunning())
        let request = ApprovalRequest(
            id: UUID(), created: Date(), tool: "t", client: nil, from: nil, to: ["a@x"], cc: [], bcc: [], subject: "s",
            bodyPreview: "b", attachments: [], status: .pending, decided: nil)
        #expect(try await center.requestApproval(request, timeout: 0.3) == .pending)
        #expect(center.pending().isEmpty)  // cleaned up
    }

    @Test func activityLogRotatesAndReadsNewestFirst() throws {
        let log = ActivityLog(url: directory.appending(path: "activity.jsonl"), maxBytes: 600)
        for n in 0..<10 {
            log.append(ActivityEntry(date: Date(), pid: 1, client: "c", tool: "tool\(n)", ok: true, milliseconds: n, summary: "s", isWrite: false))
        }
        let recent = log.recent(limit: 3)
        #expect(recent.map(\.tool) == ["tool9", "tool8", "tool7"])
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "activity.jsonl.1").path))
    }
}

@Suite("MCP protocol")
struct ProtocolTests {
    @Test func endToEndOverInMemoryTransport() async throws {
        let h = try Harness()
        defer { h.remove() }
        let server = await MailMCPServer.make(toolbox: h.toolbox)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let toolbox = h.toolbox
        try await server.start(transport: serverTransport) { info, _ in toolbox.clientName = info.name }
        let client = Client(name: "test-client", version: "1.0")
        let initialized = try await client.connect(transport: clientTransport)
        #expect(initialized.serverInfo.name == "apple-mail")
        #expect(initialized.instructions?.contains("search_messages") == true)
        let (tools, _) = try await client.listTools()
        #expect(tools.count == h.toolbox.listedDefinitions.count)
        let (content, isError) = try await client.callTool(name: "search_messages", arguments: ["subject": "Invoice"])
        #expect(isError != true)
        guard case .text(let text, _, _) = content.first else {
            Issue.record("no text content")
            return
        }
        #expect(text.contains("\"subject\":\"Invoice 42\""))
        let (errorContent, errorFlag) = try await client.callTool(name: "get_message", arguments: ["id": 123_456])
        #expect(errorFlag == true)
        if case .text(let message, _, _) = errorContent.first { #expect(message.contains("No message with id 123456")) }
        #expect(h.toolbox.clientName == "test-client")
        await client.disconnect()
        await server.stop()
    }
}
