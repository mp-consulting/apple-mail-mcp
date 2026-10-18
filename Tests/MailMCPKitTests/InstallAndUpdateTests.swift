import Foundation
import Testing

@testable import MailMCPKit

@Suite("Updates")
struct UpdateTests {
    @Test func versionsCompareNumerically() throws {
        let v = { (s: String) in try #require(AppVersion(s)) }
        #expect(try v("1.10.0") > v("1.9.0"))
        #expect(try v("v1.2") == v("1.2.0"))
        #expect(try v("0.1.1") > v("0.1"))
        #expect(AppVersion("1.2.0-beta") == nil)
        #expect(AppVersion("") == nil)
    }

    func json(tag: String, asset: String, url: String) -> Data {
        Data("""
            {"tag_name":"\(tag)","html_url":"https://github.com/mp-consulting/apple-mail-mcp/releases/tag/\(tag)",
             "assets":[{"name":"\(asset)","browser_download_url":"\(url)"}]}
            """.utf8)
    }

    @Test func parsesTheReleaseImage() throws {
        let release = try Release(gitHubJSON: json(
            tag: "v1.2.0", asset: "AppleMailMCP-1.2.0.dmg",
            url: "https://github.com/mp-consulting/apple-mail-mcp/releases/download/v1.2.0/AppleMailMCP-1.2.0.dmg"))
        #expect(release.version.description == "1.2.0")
        #expect(release.diskImageURL.lastPathComponent == "AppleMailMCP-1.2.0.dmg")
    }

    @Test func refusesForeignOrMissingImages() {
        #expect(throws: Release.Failure.noDiskImage) {
            try Release(gitHubJSON: json(tag: "v1.2.0", asset: "AppleMailMCP-1.2.0.dmg", url: "https://evil.test/AppleMailMCP-1.2.0.dmg"))
        }
        #expect(throws: Release.Failure.noDiskImage) {
            try Release(gitHubJSON: json(
                tag: "v1.2.0", asset: "Other.dmg",
                url: "https://github.com/mp-consulting/apple-mail-mcp/releases/download/v1.2.0/Other.dmg"))
        }
        #expect(throws: Release.Failure.badVersion("nightly")) {
            try Release(gitHubJSON: json(tag: "nightly", asset: "x", url: "y"))
        }
        #expect(throws: Release.Failure.unreadable) { try Release(gitHubJSON: Data("{}".utf8)) }
    }

    @Test func dailySchedule() {
        let now = Date()
        #expect(UpdateSchedule.isDue(lastCheck: nil, now: now))
        #expect(!UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-90_000), now: now))
        #expect(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now))  // clock went back
    }
}

@Suite("Claude client installer")
struct ClientInstallerTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)")

    func installer() -> ClientInstaller {
        // A non-existent CLI path forces the JSON route for Claude Code.
        ClientInstaller(serverPath: "/Applications/Apple Mail MCP.app/Contents/MacOS/apple-mail-mcp", home: home, claudeCLI: "/nonexistent/claude")
    }

    var desktopConfig: URL { home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json") }

    @Test func desktopConfigKeepsOtherSettings() throws {
        try FileManager.default.createDirectory(at: desktopConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"preferences":{"x":1},"mcpServers":{"other":{"command":"/bin/other"}}}"#.utf8).write(to: desktopConfig)
        let installer = installer()
        #expect(installer.status(.claudeDesktop) == .notInstalled)
        try installer.install(.claudeDesktop)
        #expect(installer.status(.claudeDesktop) == .installed)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: desktopConfig)) as? [String: Any]
        #expect((root?["preferences"] as? [String: Int])?["x"] == 1)
        #expect((root?["mcpServers"] as? [String: Any])?["other"] != nil)
        #expect(FileManager.default.fileExists(atPath: desktopConfig.path + ".bak"))
        try installer.uninstall(.claudeDesktop)
        #expect(installer.status(.claudeDesktop) == .notInstalled)
        #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: desktopConfig)) as? [String: Any])?["mcpServers"] != nil)
    }

    @Test func detectsAnotherServerUnderOurName() throws {
        try FileManager.default.createDirectory(at: desktopConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"apple-mail":{"command":"uvx","args":["mcp-apple-mail"]}}}"#.utf8).write(to: desktopConfig)
        #expect(installer().status(.claudeDesktop) == .otherCommand("uvx mcp-apple-mail"))
        try installer().install(.claudeDesktop)
        #expect(installer().status(.claudeDesktop) == .installed)
    }

    @Test func claudeCodeJSONFallback() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"numStartups":3,"mcpServers":{}}"#.utf8).write(to: home.appending(path: ".claude.json"))
        try installer().install(.claudeCode)
        #expect(installer().status(.claudeCode) == .installed)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appending(path: ".claude.json"))) as? [String: Any]
        #expect(root?["numStartups"] as? Int == 3)
    }

    @Test func refusesToRewriteBrokenJSON() throws {
        try FileManager.default.createDirectory(at: desktopConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[1,2".utf8).write(to: desktopConfig)
        #expect(throws: (any Error).self) { try installer().install(.claudeDesktop) }
        #expect(try String(contentsOf: desktopConfig, encoding: .utf8) == "[1,2")
    }

    @Test func missingClients() {
        #expect(installer().status(.claudeDesktop) == .clientMissing || installer().status(.claudeDesktop) == .notInstalled)
    }
}
