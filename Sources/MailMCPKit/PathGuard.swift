import Foundation

/// Filesystem policy for tools that write files (saved attachments, exports)
/// or read them (outgoing attachments).
///
/// Attachment bytes come from whoever emailed the user and tool arguments can
/// be steered by prompt injection, so writes refuse locations that run code or
/// hold configuration, and attachments refuse secrets. Optional allowlists
/// narrow either side further. Paths are resolved (`~`, `..`, symlinks) and
/// compared case-insensitively, like APFS. The lists follow the Python
/// apple-mail-mcp project's `paths.py` (MIT), extended with Mail's own data.
public struct PathGuard: Sendable {
    public var writeAllowlist: [String]
    public var attachAllowlist: [String]
    public var home: String

    public init(writeAllowlist: [String] = [], attachAllowlist: [String] = [], home: String = NSHomeDirectory()) {
        self.home = (home as NSString).resolvingSymlinksInPath
        self.writeAllowlist = writeAllowlist.map { PathGuard.resolve($0) }
        self.attachAllowlist = attachAllowlist.map { PathGuard.resolve($0) }
    }

    public struct Denied: Error, CustomStringConvertible {
        public var description: String
    }

    static let deniedWriteHome: [[String]] = [
        ["bin"], ["Library", "LaunchAgents"], ["Library", "LaunchDaemons"], ["Library", "StartupItems"],
        ["Library", "Application Support"], ["Library", "Application Scripts"], ["Library", "Scripts"],
        ["Library", "Preferences"], ["Library", "Keychains"], ["Library", "Mail"], ["Library", "Services"],
        ["Library", "Containers"], ["Library", "Group Containers"], ["Library", "Input Methods"],
        ["Library", "PreferencePanes"], ["Library", "QuickLook"], ["Library", "Spotlight"],
    ]
    static let deniedWriteAbsolute = [
        "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/StartupItems", "/Library/Application Support",
        "/Library/Preferences", "/Library/Scripts", "/etc", "/private/etc", "/usr/local/bin", "/usr/local/sbin",
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/System", "/usr/bin", "/bin", "/sbin",
    ]
    static let deniedReadHome: [[String]] = [
        [".ssh"], [".gnupg"], [".aws"], [".azure"], [".kube"], [".docker"], [".netrc"], [".git-credentials"],
        [".npmrc"], [".pypirc"], [".password-store"], [".config", "gh"], [".config", "gcloud"],
        [".claude", ".credentials.json"], ["Library", "Keychains"], ["Library", "Cookies"], ["Library", "Safari"],
        ["Library", "Application Support", "Google", "Chrome"], ["Library", "Application Support", "Chromium"],
        ["Library", "Application Support", "BraveSoftware"], ["Library", "Application Support", "Microsoft Edge"],
        ["Library", "Application Support", "Arc"], ["Library", "Application Support", "Vivaldi"],
        ["Library", "Application Support", "Firefox"], ["Library", "Application Support", "1Password"],
        ["Library", "Group Containers", "2BUA8C4S2C.com.1password"], ["Library", "Containers", "com.apple.Safari"],
        // Whole-mailbox exfiltration: Mail's store, Messages, the accounts database, our own index.
        ["Library", "Mail"], ["Library", "Messages"], ["Library", "Accounts"],
        ["Library", "Application Support", "apple-mail-mcp"],
    ]

    static func resolve(_ path: String) -> String {
        let expanded = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        // resolvingSymlinksInPath only resolves components that exist; resolve the deepest existing parent.
        var existing = (absolute as NSString).standardizingPath
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            suffix.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let resolved = URL(filePath: existing).resolvingSymlinksInPath().path
        return suffix.reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
    }

    static func components(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }

    /// Components of `path` below `root`, or nil if `path` is not inside it.
    static func relative(_ path: String, to root: String) -> [String]? {
        let p = components(path), r = components(root)
        guard p.count >= r.count else { return nil }
        for (a, b) in zip(p, r) where a.compare(b, options: .caseInsensitive) != .orderedSame { return nil }
        return Array(p.dropFirst(r.count))
    }

    static func isUnder(_ path: String, _ roots: [String]) -> Bool {
        roots.contains { relative(path, to: $0) != nil }
    }

    private func homeRoots(_ subpaths: [[String]]) -> [String] {
        subpaths.flatMap { parts -> [String] in
            let path = ([home] + parts).joined(separator: "/")
            let resolved = URL(filePath: path).resolvingSymlinksInPath().path
            return resolved == path ? [path] : [path, resolved]
        }
    }

    private func writeDenialReason(_ path: String) -> String? {
        let parts = Self.components(path).map { $0.lowercased() }
        for (index, part) in parts.dropLast().enumerated() where part == ".git" {
            if ["hooks", "config"].contains(parts[index + 1]) { return "git hooks and git config run code" }
        }
        if parts.last == ".envrc" { return ".envrc files run code" }
        if let relative = Self.relative(path, to: home), let first = relative.first, first.hasPrefix(".") {
            return "shell startup, config and credential files in your home folder"
        }
        if Self.isUnder(path, homeRoots(Self.deniedWriteHome)) { return "autostart, app-config and Mail data folders" }
        let absolute = Self.deniedWriteAbsolute.flatMap { [$0, URL(filePath: $0).resolvingSymlinksInPath().path] }
        if Self.isUnder(path, absolute) { return "system autostart, config and PATH folders" }
        return nil
    }

    /// Validates a destination file or folder for writing; returns the resolved path.
    public func checkWrite(_ path: String) throws -> String {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { throw Denied(description: "A destination path is required.") }
        let requested = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        let resolved = Self.resolve(path)
        if let reason = writeDenialReason(requested) ?? writeDenialReason(resolved) {
            throw Denied(description: "Refusing to write to a protected location (\(reason)): \(resolved)")
        }
        if !writeAllowlist.isEmpty, !Self.isUnder(resolved, writeAllowlist) {
            throw Denied(description: "Destination is outside the allowed folders (\(writeAllowlist.joined(separator: ", "))): \(resolved)")
        }
        return resolved
    }

    /// Validates a file to attach to an outgoing message; returns the resolved path.
    public func checkAttachment(_ path: String) throws -> String {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { throw Denied(description: "A file path is required.") }
        let resolved = Self.resolve(path)
        if (resolved as NSString).lastPathComponent.lowercased() == ".env" {
            throw Denied(description: "Cannot attach .env secrets files: \(resolved)")
        }
        if Self.isUnder(resolved, homeRoots(Self.deniedReadHome)) {
            throw Denied(description: "Cannot attach protected files (keys, credentials, keychains, browser profiles, Mail data): \(resolved)")
        }
        if !attachAllowlist.isEmpty, !Self.isUnder(resolved, attachAllowlist) {
            throw Denied(description: "Attachment is outside the allowed folders (\(attachAllowlist.joined(separator: ", "))): \(resolved)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw Denied(description: "Attachment not found or is a folder: \(resolved)")
        }
        return resolved
    }
}
