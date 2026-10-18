import AppKit
import Foundation
import MCP
import MailAutomation
import MailStore

public typealias MCPValue = MCP.Value

/// Environment checks shared by `apple-mail-mcp doctor` and the menu bar app.
public enum Doctor {
    public struct Check: Sendable, Identifiable {
        public enum State: Sendable { case ok, warning, failed }
        public var id: String { name }
        public var name: String
        public var state: State
        public var detail: String
    }

    public static func checks(settings: Settings) async -> [Check] {
        var checks: [Check] = []
        var store: MailStore?
        do {
            let location = try MailLocation.discover()
            let opened = try MailStore(location: location)
            store = opened
            let count = try opened.messageCount()
            let path = location.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            checks.append(Check(name: "Mail data", state: .ok, detail: "\(count.formatted()) messages in \(path)"))
            let accounts = try opened.accounts()
            checks.append(Check(name: "Accounts", state: .ok, detail: accounts.map(\.name).joined(separator: ", ")))
        } catch let error as MailLocation.LocationError {
            let state: Check.State = .failed
            checks.append(Check(name: "Mail data", state: state, detail: error.description))
        } catch {
            checks.append(Check(name: "Mail data", state: .failed, detail: "\(error)"))
        }

        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
        checks.append(Check(name: "Mail app", state: running ? .ok : .warning, detail: running ? "running" : "not running (reads still work; it is launched for changes)"))
        if running {
            let status = MailAutomation().permissionStatus(askIfNeeded: false)
            switch status {
            case 0: checks.append(Check(name: "Automation", state: .ok, detail: "allowed to control Mail"))
            case -1744: checks.append(Check(name: "Automation", state: .warning, detail: "macOS will ask for permission on the first change"))
            case -1743: checks.append(Check(name: "Automation", state: .failed, detail: "denied; allow it in System Settings → Privacy & Security → Automation"))
            default: checks.append(Check(name: "Automation", state: .warning, detail: "status \(status)"))
            }
        }

        if let index = BodyIndex.openIfPresent(url: SharedPaths.bodyIndex), let status = try? index.status() {
            let behind = (try? store?.countMessages(after: status.coveredThrough)) ?? 0
            checks.append(Check(
                name: "Body index", state: behind > 500 ? .warning : .ok,
                detail: "\(status.indexedMessages) messages, \(status.sizeBytes / 1_048_576) MB, \(behind) not yet indexed"))
        } else {
            checks.append(Check(name: "Body index", state: .warning, detail: "not built; body searches scan files (run `apple-mail-mcp index`)"))
        }

        let agent = ApprovalCenter().isAgentRunning()
        checks.append(Check(
            name: "Menu bar app", state: agent || settings.sendPolicy != .confirm ? .ok : .failed,
            detail: agent ? "running" : (settings.sendPolicy == .confirm ? "not running, but send policy needs it for approvals" : "not running")))
        checks.append(Check(
            name: "Settings", state: .ok,
            detail: "send policy \(settings.sendPolicy.rawValue), mail changes \(settings.allowMailChanges ? "allowed" : "off"), batch limit \(settings.maxBatchSize)"))
        return checks
    }

    public static func report(settings: Settings) async throws -> String {
        await checks(settings: settings).map { check -> String in
            let mark = switch check.state {
            case .ok: "✓"
            case .warning: "!"
            case .failed: "✗"
            }
            return "\(mark) \(check.name): \(check.detail)"
        }.joined(separator: "\n")
    }
}
