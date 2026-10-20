import Foundation
import Testing

@testable import MailMCPKit

@Suite("Claude skills")
struct SkillTests {
    static let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func embeddedCatalogMatchesSkillsFolder() throws {
        let folder = Self.repository.appending(path: "Skills")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
        #expect(SkillCatalog.all.map(\.name).sorted() == names)
        for skill in SkillCatalog.all {
            let source = try String(contentsOf: folder.appending(path: "\(skill.name)/SKILL.md"), encoding: .utf8)
            #expect(skill.content == source, "Run Scripts/embed-skills.sh: \(skill.name) is out of date")
        }
    }

    @Test func everySkillIsWellFormed() {
        #expect(SkillCatalog.all.count >= 8)
        for skill in SkillCatalog.all {
            #expect(skill.name.hasPrefix("mail-"))
            #expect(skill.description.count > 60 && skill.description.count < 1024, "\(skill.name) description length")
            #expect(skill.description.contains("Use when"), "\(skill.name) should say when to use it")
            #expect(skill.content.contains(SkillCatalog.marker))
            #expect(!skill.title.isEmpty && !skill.summary.isEmpty)
            #expect(SkillCatalog.blurbs[skill.name] != nil, "\(skill.name) needs a one-line blurb for the app")
        }
    }

    /// Every `snake_case` tool or parameter named in a skill must exist on the server.
    @Test func skillsOnlyReferenceRealTools() throws {
        let h = try Harness()
        defer { h.remove() }
        let tools = Set(h.toolbox.definitions.map(\.tool.name))
        // Parameters come from the tools' own schemas; output keys skills may mention are listed by hand.
        var parameters: Set<String> = [
            "new_ids", "has_more", "body_search", "not_found", "collateral_suspected", "with_amount", "amount_confidence",
            "remaining_ids", "one_click", "pending_rules", "strays_restored", "stray_change_id", "resume_ids", "retry_one_by_one",
        ]
        for definition in h.toolbox.definitions {
            if case .object(let schema) = definition.tool.inputSchema, case .object(let properties)? = schema["properties"] {
                parameters.formUnion(properties.keys)
            }
        }
        let regex = try NSRegularExpression(pattern: "`([a-z]+(?:_[a-z]+)+)`")
        for skill in SkillCatalog.all {
            let text = skill.content as NSString
            for match in regex.matches(in: skill.content, range: NSRange(location: 0, length: text.length)) {
                let token = text.substring(with: match.range(at: 1))
                #expect(tools.contains(token) || parameters.contains(token), "\(skill.name) mentions unknown `\(token)`")
            }
        }
    }

    @Test func installUpdateAndUninstall() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = SkillInstaller(directory: directory)
        let skill = SkillCatalog.all[0]
        #expect(installer.state(of: skill) == .notInstalled)
        try installer.install([skill])
        #expect(installer.state(of: skill) == .installed)
        // An older version of ours: update available, and install replaces it.
        try Data((skill.content + "\nold").utf8).write(to: directory.appending(path: "\(skill.name)/SKILL.md"))
        #expect(installer.state(of: skill) == .updateAvailable)
        try installer.install([skill])
        #expect(installer.state(of: skill) == .installed)
        try installer.uninstall([skill])
        #expect(installer.state(of: skill) == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: skill.name).path))
    }

    @Test func refreshUpdatesOnlyOutdatedInstalledSkills() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = SkillInstaller(directory: directory)
        let (outdated, current, absent) = (SkillCatalog.all[0], SkillCatalog.all[1], SkillCatalog.all[2])
        try installer.install([outdated, current])
        try Data((outdated.content + "\nolder version").utf8).write(to: directory.appending(path: "\(outdated.name)/SKILL.md"))
        #expect(try installer.refreshInstalled().map(\.name) == [outdated.name])
        #expect(installer.state(of: outdated) == .installed)
        #expect(installer.state(of: absent) == .notInstalled)  // never installed, so not added
    }

    @Test func foreignSkillsAreNeverTouched() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = SkillInstaller(directory: directory)
        let skill = SkillCatalog.all[0]
        let mine = directory.appending(path: "\(skill.name)/SKILL.md")
        try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nname: \(skill.name)\ndescription: the user's own\n---\n".utf8).write(to: mine)
        #expect(installer.state(of: skill) == .foreign)
        #expect(try installer.install([skill]).isEmpty)
        #expect(try installer.uninstall([skill]).isEmpty)
        #expect(try String(contentsOf: mine, encoding: .utf8).contains("the user's own"))
    }

    @Test func exportsZips() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zips-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let zips = try SkillInstaller.exportZips(Array(SkillCatalog.all.prefix(2)), to: folder)
        #expect(zips.count == 2)
        let listing = Process()
        let pipe = Pipe()
        listing.executableURL = URL(filePath: "/usr/bin/zipinfo")
        listing.arguments = ["-1", zips[0].path]
        listing.standardOutput = pipe
        try listing.run()
        listing.waitUntilExit()
        let entries = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(entries.contains("\(SkillCatalog.all[0].name)/SKILL.md"))
    }
}
