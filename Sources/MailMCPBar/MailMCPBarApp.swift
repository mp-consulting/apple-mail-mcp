import AppKit
import SwiftUI

/// Menu bar agent: status, send approvals, Claude setup, skills, activity and settings for the MCP server.
@main
struct MailMCPBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

struct MenuBarIcon: View {
    @Bindable var model: AgentModel

    var body: some View {
        Image(systemName: model.pending.isEmpty
            ? (model.hasProblem ? "envelope.badge.shield.half.filled" : "envelope")
            : "envelope.badge.fill")
    }
}

/// Starts the background work at launch (not when the menu first opens) and owns the AppKit
/// windows that must appear on their own: the floating approval panel and the preview window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AgentModel()
    private var approvalPanel: NSPanel?
    private var previewWindows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.openApprovalWindow = { [weak self] in self?.showApprovals() }
        model.closeApprovalWindow = { [weak self] in self?.approvalPanel?.orderOut(nil) }
        model.start()
        if CommandLine.arguments.contains("--preview") { showPreview() }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let folder = URL(filePath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                // Let the model load status, activity and approvals first.
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                Snapshots.render(model: model, to: folder)
                NSApp.terminate(nil)
            }
        }
    }

    /// A floating panel above other windows, so a send request is never missed.
    func showApprovals() {
        if approvalPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "Approve Email"
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.contentViewController = NSHostingController(rootView: ApprovalWindow(model: model))
            approvalPanel = panel
        }
        approvalPanel?.center()
        approvalPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// `--preview`: the panel's three tabs as ordinary windows (for screenshots and design work).
    private func showPreview() {
        func window(_ title: String, _ view: some View, at origin: NSPoint) {
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = title
            window.setFrameOrigin(origin)
            window.makeKeyAndOrderFront(nil)
            previewWindows.append(window)
        }
        window("Apple Mail MCP — Mail", MenuContent(model: model, fixedTab: .mail), at: NSPoint(x: 60, y: 120))
        window("Apple Mail MCP — Claude", MenuContent(model: model, fixedTab: .claude), at: NSPoint(x: 480, y: 120))
        window("Apple Mail MCP — Settings", MenuContent(model: model, fixedTab: .settings), at: NSPoint(x: 900, y: 120))
        NSApp.activate()
    }
}

/// `--snapshot DIR`: renders each tab and the approval window to PNG without a screen (for the README).
@MainActor
enum Snapshots {
    static func render(model: AgentModel, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var windows: [NSWindow] = []
        // Dark images keep the plain names; light ones get a "-light" suffix (the README picks per reader).
        for (appearanceName, suffix) in [(NSAppearance.Name.darkAqua, ""), (.aqua, "-light")] {
            NSApp.appearance = NSAppearance(named: appearanceName)
            func save(_ view: some View, _ name: String) {
                // AppKit draws the hosted view into a bitmap: real controls and scroll views, no screen needed.
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: appearanceName)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearanceName)
                window.contentView = host
                window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                window.orderFrontRegardless()
                windows.append(window)
                host.layoutSubtreeIfNeeded()
                host.display()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: folder.appending(path: "\(name)\(suffix).png"))
                }
            }
            save(MenuContent(model: model, fixedTab: .mail), "tab-mail")
            save(MenuContent(model: model, fixedTab: .claude), "tab-claude")
            save(MenuContent(model: model, fixedTab: .settings), "tab-settings")
            save(ApprovalWindow(model: model), "approval")
            if model.settings.remoteAccess {
                save(Form { RemoteSection(model: model) }.formStyle(.grouped).frame(width: 540), "settings-remote")
                if let connect = model.pending.first(where: { $0.action == .connect }) {
                    save(ApprovalBlock(request: connect) { _ in }.padding(16).frame(width: 460), "approval-connect")
                }
            }
        }
    }
}
