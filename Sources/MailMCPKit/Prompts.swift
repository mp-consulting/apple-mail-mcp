import Foundation
import MCP

/// The shipped skills as MCP prompts, so clients without skill support can still run them
/// (Claude Code lists them as `/mcp__apple-mail__mail-triage` and so on).
extension MailToolbox {
    public var prompts: [Prompt] {
        SkillCatalog.all.map { skill in
            Prompt(
                name: skill.name, title: skill.title, description: skill.summary,
                arguments: [.init(name: "request", title: "Request", description: "What you want, in your own words (optional)", required: false)])
        }
    }

    public func prompt(named name: String, arguments: [String: String]?) throws -> GetPrompt.Result {
        guard let skill = SkillCatalog.all.first(where: { $0.name == name }) else {
            throw MCPError.invalidParams("Unknown prompt \(name)")
        }
        var text = Self.instructions(of: skill)
        if let request = arguments?["request"]?.trimmingCharacters(in: .whitespacesAndNewlines), !request.isEmpty {
            text += "\n\n## The request\n\n\(request)"
        }
        return GetPrompt.Result(description: skill.summary, messages: [.user(.text(text: text))])
    }

    /// The SKILL.md body: no frontmatter, no install marker.
    static func instructions(of skill: MailSkill) -> String {
        var lines = skill.content.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(...end) }
        lines.removeAll { $0.hasPrefix(SkillCatalog.marker) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
