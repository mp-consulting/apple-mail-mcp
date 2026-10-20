import Foundation

/// Registers the server with Claude Code and Claude Desktop.
///
/// Claude Code goes through its own CLI (`claude mcp add --scope user`), falling back to
/// `~/.claude.json` when the CLI is missing or cannot be launched. Claude Desktop's
/// `claude_desktop_config.json` is edited in place: other servers and settings are kept,
/// and a `.bak` copy is written first.
public struct ClientInstaller: Sendable {
    public enum Client: String, CaseIterable, Sendable, Identifiable {
        case claudeCode = "claude-code"
        case claudeDesktop = "claude-desktop"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .claudeDesktop: "Claude Desktop"
            }
        }
    }

    public enum Status: Equatable, Sendable {
        /// Registered with this server binary.
        case installed
        /// Registered, but pointing at another command (an older build or the Python server).
        case otherCommand(String)
        case notInstalled
        /// The client itself does not seem to be installed.
        case clientMissing
    }

    public static let serverName = "apple-mail"

    public var serverPath: String
    public var home: URL
    /// Explicit `claude` CLI; found automatically when nil.
    public var claudeCLI: String?

    public init(serverPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser, claudeCLI: String? = nil) {
        self.serverPath = serverPath
        self.home = home
        self.claudeCLI = claudeCLI
    }

    var claudeCodeConfig: URL { home.appending(path: ".claude.json") }
    var desktopConfig: URL { home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json") }
    public var desktopConfigPath: String { desktopConfig.path }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    // MARK: Status

    public func status(_ client: Client) -> Status {
        switch client {
        case .claudeCode:
            guard locateClaudeCLI() != nil || FileManager.default.fileExists(atPath: claudeCodeConfig.path) else { return .clientMissing }
            return status(inConfig: claudeCodeConfig)
        case .claudeDesktop:
            let appInstalled = ["/Applications/Claude.app", home.appending(path: "Applications/Claude.app").path]
                .contains { FileManager.default.fileExists(atPath: $0) }
            guard appInstalled || FileManager.default.fileExists(atPath: desktopConfig.deletingLastPathComponent().path) else {
                return .clientMissing
            }
            return status(inConfig: desktopConfig)
        }
    }

    private func status(inConfig url: URL) -> Status {
        guard let root = readJSON(url),
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[Self.serverName] as? [String: Any]
        else { return .notInstalled }
        let command = entry["command"] as? String ?? ""
        return command == serverPath ? .installed : .otherCommand(([command] + (entry["args"] as? [String] ?? [])).joined(separator: " "))
    }

    /// Where this app's server was before 0.6, next to the menu bar app in Contents/MacOS; nil when `serverPath` is not
    /// the server of an app bundle.
    var formerServerPath: String? {
        guard serverPath.hasSuffix("/" + Self.helperExecutable) else { return nil }
        return serverPath.dropLast(Self.helperExecutable.count) + "Contents/MacOS/apple-mail-mcp"
    }

    /// The server inside the app: its own bundle, so it can claim the Keychain group (see `Scripts/build-app.sh`).
    public static let helperExecutable = "Contents/Helpers/Apple Mail MCP Server.app/Contents/MacOS/apple-mail-mcp"

    /// Points the clients set up with this app's former server path at the current one, keeping their arguments.
    /// Returns the clients changed.
    @discardableResult
    public func repointFormerServerPath() -> [Client] {
        guard let former = formerServerPath else { return [] }
        return Client.allCases.filter { client in
            let url = client == .claudeCode ? claudeCodeConfig : desktopConfig
            guard var entry = (readJSON(url)?["mcpServers"] as? [String: Any])?[Self.serverName] as? [String: Any],
                entry["command"] as? String == former
            else { return false }
            entry["command"] = serverPath
            return (try? setServerEntry(entry, in: url)) != nil
        }
    }

    /// The Apple Mail extension (`.mcpb`) as the Claude app recorded it.
    public struct DesktopExtension: Equatable, Sendable {
        public var id: String
        public var version: String?
        public var enabled: Bool
    }

    var claudeSupport: URL { home.appending(path: "Library/Application Support/Claude") }

    /// The Claude app's Apple Mail extension, when installed (`extensions-installations.json`; on or off per
    /// `Claude Extensions Settings/<id>.json`, on when that file says nothing).
    public var desktopExtension: DesktopExtension? {
        guard let root = readJSON(claudeSupport.appending(path: "extensions-installations.json")),
              let extensions = root["extensions"] as? [String: Any]
        else { return nil }
        for (id, value) in extensions.sorted(by: { $0.key < $1.key }) {
            guard let entry = value as? [String: Any], let manifest = entry["manifest"] as? [String: Any],
                  manifest["name"] as? String == "apple-mail-mcp"
            else { continue }
            let settings = readJSON(claudeSupport.appending(path: "Claude Extensions Settings/\(id).json"))
            return DesktopExtension(
                id: id, version: entry["version"] as? String ?? manifest["version"] as? String,
                enabled: settings?["isEnabled"] as? Bool ?? true)
        }
        return nil
    }

    /// The Claude app runs the server twice: through the extension and through its config file. Claude then
    /// lists every tool twice and starts twice the processes.
    public var isSetUpTwiceInClaudeDesktop: Bool {
        guard desktopExtension?.enabled == true else { return false }
        switch status(.claudeDesktop) {
        case .installed, .otherCommand: return true
        case .notInstalled, .clientMissing: return false
        }
    }

    // MARK: Install

    /// Installs (or repoints) the server for `client`; returns a message for the user.
    @discardableResult
    public func install(_ client: Client) throws -> String {
        switch client {
        case .claudeCode:
            // Re-adding fails if the name exists, so remove first (ignore "not found").
            if let cli = locateClaudeCLI(), (try? run(cli, ["mcp", "remove", "--scope", "user", Self.serverName])) != nil {
                let output = try run(cli, ["mcp", "add", "--scope", "user", Self.serverName, "--", serverPath])
                guard output.status == 0 else { throw Failure(description: "claude mcp add failed: \(output.text)") }
            } else {
                // No CLI, or one that does not launch (a Homebrew install can lose its execute bit while an ACL
                // still makes it look executable): Claude Code reads the same entry from ~/.claude.json.
                try setServerEntry(["type": "stdio", "command": serverPath, "args": [String](), "env": [String: String]()], in: claudeCodeConfig)
            }
            return "Added to Claude Code for all projects. Start a new Claude Code session to use it."
        case .claudeDesktop:
            try setServerEntry(["command": serverPath], in: desktopConfig)
            return "Added to Claude Desktop. Quit and reopen Claude to load it."
        }
    }

    public func uninstall(_ client: Client) throws {
        switch client {
        case .claudeCode:
            let removedByCLI = locateClaudeCLI().flatMap { try? run($0, ["mcp", "remove", "--scope", "user", Self.serverName]) }?.status == 0
            if !removedByCLI {
                try setServerEntry(nil, in: claudeCodeConfig)
            }
        case .claudeDesktop:
            try setServerEntry(nil, in: desktopConfig)
        }
    }

    // MARK: Helpers

    public func locateClaudeCLI() -> String? {
        if let claudeCLI { return FileManager.default.isExecutableFile(atPath: claudeCLI) ? claudeCLI : nil }
        let candidates = [
            home.appending(path: ".claude/local/claude").path, home.appending(path: ".local/bin/claude").path,
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Sets (or with nil removes) our entry under `mcpServers`, keeping everything else in the file.
    private func setServerEntry(_ entry: [String: Any]?, in url: URL) throws {
        try editJSON(url, backup: true) { root in
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers[Self.serverName] = entry
            root["mcpServers"] = servers
        }
    }

    private func editJSON(_ url: URL, backup: Bool, _ change: (inout [String: Any]) -> Void) throws {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if !data.isEmpty {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw Failure(description: "\(url.path) is not a JSON object; not touching it.")
                }
                root = parsed
            }
            if backup {
                // The config can hold MCP server secrets: the copy gets the original's owner-only permissions.
                let copy = url.appendingPathExtension("bak")
                try data.write(to: copy, options: .atomic)
                let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int ?? 0o600
                try FileManager.default.setAttributes([.posixPermissions: mode & 0o700], ofItemAtPath: copy.path)
            }
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        change(&root)
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int ?? 0o600
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // An atomic write makes a new file with default permissions; keep the original's (owner-only for ~/.claude.json).
        try output.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, text: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
