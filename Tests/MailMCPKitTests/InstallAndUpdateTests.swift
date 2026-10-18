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

    func writeExtension(enabled: Bool?) throws {
        let support = desktopConfig.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: support.appending(path: "Claude Extensions Settings"), withIntermediateDirectories: true)
        let id = "local.mcpb.mickael-palma.apple-mail-mcp"
        try Data(#"{"extensions":{"other.ext":{"manifest":{"name":"other"}},"\#(id)":{"version":"0.4.0","manifest":{"name":"apple-mail-mcp","version":"0.4.0"}}}}"#.utf8)
            .write(to: support.appending(path: "extensions-installations.json"))
        if let enabled {
            try Data(#"{"isEnabled":\#(enabled)}"#.utf8).write(to: support.appending(path: "Claude Extensions Settings/\(id).json"))
        }
    }

    @Test func noticesTheServerSetUpTwiceInTheClaudeApp() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = installer()
        #expect(installer.desktopExtension == nil && !installer.isSetUpTwiceInClaudeDesktop)
        try writeExtension(enabled: nil)
        #expect(installer.desktopExtension == .init(id: "local.mcpb.mickael-palma.apple-mail-mcp", version: "0.4.0", enabled: true))
        #expect(!installer.isSetUpTwiceInClaudeDesktop)  // the extension alone is fine
        try installer.install(.claudeDesktop)
        #expect(installer.isSetUpTwiceInClaudeDesktop)
        try writeExtension(enabled: false)
        #expect(!installer.isSetUpTwiceInClaudeDesktop)  // switched off in Claude
        try writeExtension(enabled: true)
        try installer.uninstall(.claudeDesktop)
        #expect(!installer.isSetUpTwiceInClaudeDesktop)
    }

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
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appending(path: ".claude.json").path)
        try installer().install(.claudeCode)
        #expect(installer().status(.claudeCode) == .installed)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appending(path: ".claude.json"))) as? [String: Any]
        #expect(root?["numStartups"] as? Int == 3)
        for name in [".claude.json", ".claude.json.bak"] {
            let mode = try FileManager.default.attributesOfItem(atPath: home.appending(path: name).path)[.posixPermissions] as? Int
            #expect(mode == 0o600, "\(name)")
        }
    }

    @Test func claudeCodeFallsBackWhenTheCLIDoesNotLaunch() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let cli = home.appending(path: "claude")
        try Data([0, 1, 2, 3]).write(to: cli)  // "executable", but not a program
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let installer = ClientInstaller(serverPath: "/Applications/Apple Mail MCP.app/Contents/MacOS/apple-mail-mcp", home: home, claudeCLI: cli.path)
        #expect(installer.locateClaudeCLI() == cli.path)
        try installer.install(.claudeCode)
        #expect(installer.status(.claudeCode) == .installed)
        try installer.uninstall(.claudeCode)
        #expect(installer.status(.claudeCode) == .notInstalled)
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
