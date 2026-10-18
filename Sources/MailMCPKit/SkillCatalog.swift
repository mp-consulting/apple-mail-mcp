import Foundation

/// A Claude skill shipped with the server (source: `Skills/<name>/SKILL.md`).
public struct MailSkill: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    /// The frontmatter description: what the skill does and when Claude should use it.
    public var description: String
    /// The full SKILL.md.
    public var content: String

    /// One short line for people (the description is written for Claude).
    public var summary: String {
        if let blurb = SkillCatalog.blurbs[name] { return blurb }
        guard let end = description.firstIndex(of: ".") else { return description }
        return String(description[...end])
    }

    /// Human title from the name: `mail-reply-writer` → "Reply writer".
    public var title: String {
        let words = name.split(separator: "-").dropFirst(name.hasPrefix("mail-") ? 1 : 0)
        let text = words.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

public enum SkillCatalog {
    /// Marker line every shipped skill ends with; only marked skills are ever removed.
    public static let marker = "<!-- Installed by Apple Mail MCP"

    /// UI copy for each shipped skill.
    static let blurbs: [String: String] = [
        "mail-triage": "Daily review: what needs a reply, what to read, what can go.",
        "mail-reply-writer": "Drafts replies in your voice after reading the whole thread.",
        "mail-follow-up": "Finds mail nobody answered and drafts polite nudges.",
        "mail-inbox-zero": "Clears the inbox in previewed batches, archive before trash.",
        "mail-newsletter-cleanup": "Finds bulk senders, archives them, surfaces unsubscribe links.",
        "mail-research": "Answers questions from your mail, with links to the messages.",
        "mail-attachments": "Finds and saves invoices, contracts and files people sent.",
        "mail-weekly-report": "Volume, open replies, who you're waiting on, and the noise.",
    ]

    public static let all: [MailSkill] = embedded.compactMap { folder, content in
        let fields = frontmatter(content)
        guard let name = fields["name"], let description = fields["description"] else { return nil }
        assert(name == folder, "skill \(folder) declares name \(name)")
        return MailSkill(name: name, description: description, content: content)
    }

    /// Parses the simple `key: value` frontmatter of a SKILL.md.
    public static func frontmatter(_ content: String) -> [String: String] {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        return fields
    }
}

/// Installs skills where Claude finds them, and exports them for the Claude apps.
public struct SkillInstaller: Sendable {
    public enum State: String, Sendable {
        case notInstalled
        case installed
        /// A different version of our skill is installed.
        case updateAvailable
        /// A skill with this name exists but was not installed by us; it is never overwritten or removed.
        case foreign
    }

    /// Claude Code's personal skills folder (`~/.claude/skills`).
    public var directory: URL

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills")) {
        self.directory = directory
    }

    func file(_ skill: MailSkill) -> URL { directory.appending(path: "\(skill.name)/SKILL.md") }

    public func state(of skill: MailSkill) -> State {
        guard let existing = try? String(contentsOf: file(skill), encoding: .utf8) else { return .notInstalled }
        if existing == skill.content { return .installed }
        return existing.contains(SkillCatalog.marker) ? .updateAvailable : .foreign
    }

    /// Installs or updates skills. Foreign skills with the same name are skipped; returns those installed.
    @discardableResult
    public func install(_ skills: [MailSkill]) throws -> [MailSkill] {
        var done: [MailSkill] = []
        for skill in skills where state(of: skill) != .foreign {
            try FileManager.default.createDirectory(at: file(skill).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(skill.content.utf8).write(to: file(skill), options: .atomic)
            done.append(skill)
        }
        return done
    }

    /// Brings every installed skill of ours up to date (after an app update). Skills the user never
    /// installed, removed, or that belong to someone else are left alone. Returns those updated.
    @discardableResult
    public func refreshInstalled(_ skills: [MailSkill] = SkillCatalog.all) throws -> [MailSkill] {
        try install(skills.filter { state(of: $0) == .updateAvailable })
    }

    /// Removes skills this app installed (identified by the marker); leaves anything else alone.
    @discardableResult
    public func uninstall(_ skills: [MailSkill]) throws -> [MailSkill] {
        var removed: [MailSkill] = []
        for skill in skills {
            let state = state(of: skill)
            guard state == .installed || state == .updateAvailable else { continue }
            let folder = file(skill).deletingLastPathComponent()
            try FileManager.default.removeItem(at: file(skill))
            // Remove the folder only if nothing else lives in it.
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty ?? false {
                try? FileManager.default.removeItem(at: folder)
            }
            removed.append(skill)
        }
        return removed
    }

    /// Writes `<name>.zip` files (a `<name>/SKILL.md` folder each) for uploading in the Claude apps
    /// (Settings → Capabilities → Skills). Returns the zip paths.
    public static func exportZips(_ skills: [MailSkill], to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = FileManager.default.temporaryDirectory.appending(path: "skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        var zips: [URL] = []
        for skill in skills {
            let source = staging.appending(path: skill.name)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(skill.content.utf8).write(to: source.appending(path: "SKILL.md"))
            let zip = folder.appending(path: "\(skill.name).zip")
            try? FileManager.default.removeItem(at: zip)
            let ditto = Process()
            ditto.executableURL = URL(filePath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                throw ToolError("Could not create \(zip.lastPathComponent) (ditto exited with \(ditto.terminationStatus))")
            }
            zips.append(zip)
        }
        return zips
    }
}
