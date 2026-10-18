import MailMCPKit
import MailStore
import SwiftUI

// One surface, sections and rows (no stacked cards). The send approval is the only emphasized block.

// MARK: Building blocks

struct SectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

/// A list row: icon, title, detail, trailing control.
struct Row<Trailing: View>: View {
    let systemImage: String
    var iconColor: Color = .secondary
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 15)).foregroundStyle(iconColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }
}

struct SectionDivider: View {
    var body: some View { Divider().padding(.horizontal, 16).padding(.top, 6) }
}

struct Checkmark: View {
    var body: some View {
        Image(systemName: "checkmark").font(.callout.weight(.bold)).foregroundStyle(.green).accessibilityLabel("Done")
    }
}

// MARK: Menu bar panel: one place, three tabs

enum PanelTab: String, CaseIterable, Identifiable {
    case mail = "Mail"
    case claude = "Claude"
    case settings = "Settings"

    var id: String { rawValue }
}

struct MenuContent: View {
    @Bindable var model: AgentModel
    /// Fixes the tab (preview windows); nil follows the model.
    var fixedTab: PanelTab?

    var tab: PanelTab { fixedTab ?? model.panelTab }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TabBar(model: model, selected: tab) { model.panelTab = $0 }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .mail: MailTab(model: model)
                    case .claude: ClaudeTab(model: model)
                    case .settings: SettingsTab(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 470)
            Divider()
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Apple Mail MCP").font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(model.headlineColor).frame(width: 7, height: 7)
                    Text(model.headline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            switch tab {
            case .claude:
                SkillActions(model: model)
            case .settings:
                SettingsLink { Text("More settings…") }.buttonStyle(.link)
                Spacer()
                Button("Check for Updates") { Task { await model.updater.check() } }
                    .disabled(!model.updater.isEnabled)
            case .mail:
                if model.isIndexing {
                    ProgressView().controlSize(.mini)
                    Text(model.indexProgress.map { "Indexing \($0.done.formatted())/\($0.total.formatted())" } ?? "Indexing…")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.footerLine).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit Apple Mail MCP")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Segmented tab bar with a count badge on Mail and a dot on Claude when something needs doing.
struct TabBar: View {
    @Bindable var model: AgentModel
    let selected: PanelTab
    let select: (PanelTab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                Button { select(tab) } label: {
                    HStack(spacing: 5) {
                        Text(tab.rawValue)
                        if tab == .mail, !model.pending.isEmpty {
                            Text("\(model.pending.count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Capsule().fill(Color.orange))
                        }
                        if tab == .claude, model.claudeNeedsAction {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                        }
                    }
                    .font(.callout.weight(selected == tab ? .semibold : .regular))
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 7).fill(selected == tab ? Color.primary.opacity(0.14) : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == tab ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
    }
}

struct MailTab: View {
    @Bindable var model: AgentModel

    var body: some View {
        if let release = model.updater.availableRelease {
            Row(
                systemImage: "arrow.down.circle.fill", iconColor: .accentColor,
                title: "Version \(release.version.description) is available",
                detail: model.updater.installBlocker ?? "Installs and relaunches in a few seconds.")
            {
                if model.updater.installBlocker == nil {
                    Button("Update") { Task { await model.updater.install(release) } }.glassButton(prominent: true).controlSize(.small)
                } else {
                    Link("Download", destination: release.pageURL).controlSize(.small)
                }
            }
        }
        if !model.pending.isEmpty {
            ApprovalQueue(model: model).padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 4)
        }
        if !model.attention.isEmpty {
            SectionHeader("Needs attention")
            ForEach(model.attention) { item in
                Row(systemImage: item.icon, iconColor: .orange, title: item.title, detail: item.detail) {
                    Button(item.action) { model.perform(item) }.glassButton().controlSize(.small)
                }
            }
        }
        SectionHeader("Activity")
        if model.activity.isEmpty {
            Text("No requests yet. Ask Claude about your mail.").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 6)
        } else {
            ForEach(model.activity.prefix(20)) { entry in ActivityRow(entry: entry).padding(.horizontal, 16) }
        }
    }
}

struct ClaudeTab: View {
    @Bindable var model: AgentModel

    var body: some View {
        SectionHeader("Connections")
        ClaudeRows(model: model)
        if let message = model.clientMessage {
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.bottom, 4)
        }
        SectionDivider()
        HStack {
            SectionHeader("Skills")
            Spacer()
            Picker("Skills for", selection: $model.skillTarget) {
                Text("Claude Code").tag(SkillTarget.claudeCode)
                Text("Claude app").tag(SkillTarget.claudeApp)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .padding(.trailing, 16)
            .padding(.top, 8)
        }
        Text(model.skillTarget.explanation).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.bottom, 4)
        ForEach(SkillCatalog.all) { skill in SkillRow(model: model, skill: skill) }
        if let message = model.skillsMessage {
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }
}

/// The Claude tab's footer: act on the selected skills.
struct SkillActions: View {
    @Bindable var model: AgentModel

    var body: some View {
        Text("\(model.selectedSkills.count) selected · \(model.installedSkillCount) in Claude Code")
            .font(.caption).foregroundStyle(.secondary)
        Spacer()
        if model.skillTarget == .claudeCode {
            if model.selectedSkills.contains(where: { [.installed, .updateAvailable].contains(model.skillStates[$0]) }) {
                Button("Remove") { model.uninstallSelectedSkills() }
            }
            Button("Add \(model.selectedSkills.count)") { model.installSelectedSkills() }
                .glassButton(prominent: true)
                .disabled(model.selectedSkills.isEmpty)
        } else {
            Button("Export \(model.selectedSkills.count)…") { model.exportSkillsForClaudeApp() }
                .glassButton(prominent: true)
                .disabled(model.selectedSkills.isEmpty)
        }
    }
}

struct SettingsTab: View {
    @Bindable var model: AgentModel

    var body: some View {
        SectionHeader("Sending")
        SettingRow("When Claude sends") {
            Picker("When Claude sends", selection: $model.settings.sendPolicy) {
                Text("Ask me first").tag(SendPolicy.confirm)
                Text("Send right away").tag(SendPolicy.allow)
                Text("Never (drafts only)").tag(SendPolicy.never)
            }
            .labelsHidden()
            .fixedSize()
        }
        SectionDivider()
        SectionHeader("Changes")
        SettingRow("Allow moving, flagging and Trash") { Toggle("", isOn: $model.settings.allowMailChanges).labelsHidden() }
        SettingRow("Messages per change, at most") {
            Stepper("\(model.settings.maxBatchSize)", value: $model.settings.maxBatchSize, in: 1...500).fixedSize()
        }
        SectionDivider()
        SectionHeader("Search and updates")
        SettingRow("Keep the search index up to date") { Toggle("", isOn: $model.settings.autoUpdateBodyIndex).labelsHidden() }
        SettingRow("Check for updates every day") {
            Toggle("", isOn: $model.settings.checkForUpdates).labelsHidden().disabled(!model.updater.isEnabled)
        }
        SettingRow("Update installed skills with the app") { Toggle("", isOn: $model.settings.updateInstalledSkills).labelsHidden() }
        SettingRow("Open at login") {
            Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })).labelsHidden()
        }
        Text("Version \(model.updater.currentVersion?.description ?? MailMCPVersion.current)\(model.updaterLine)")
            .font(.caption).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.top, 8)
        .onChange(of: model.settings) { model.save() }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            control.toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 34)
    }
}

struct ClaudeRows: View {
    @Bindable var model: AgentModel

    var body: some View {
        let code = model.clientStatus[.claudeCode] ?? .notInstalled
        Row(systemImage: "terminal", title: "Claude Code", detail: model.claudeCodeDetail) {
            switch code {
            case .installed:
                if model.installedSkillCount == 0 {
                    Button("Add skills") { model.installAllSkills() }.glassButton().controlSize(.small)
                } else {
                    Checkmark().contextMenu { Button("Remove from Claude Code") { model.uninstall(from: .claudeCode) } }
                }
            case .clientMissing:
                Text("Not installed").font(.caption).foregroundStyle(.tertiary)
            case .notInstalled, .otherCommand:
                Button("Connect") { model.connectClaudeCode() }.glassButton(prominent: true).controlSize(.small)
            }
        }
        let app = model.clientStatus[.claudeDesktop] ?? .notInstalled
        Row(systemImage: "macwindow", title: "Claude app", detail: model.claudeAppDetail) {
            switch app {
            case .installed:
                if model.claudeAppNeedsRestart {
                    Button("Restart Claude") { model.restartClaudeApp() }.glassButton(prominent: true).controlSize(.small)
                } else {
                    Checkmark().contextMenu { Button("Remove from the Claude app") { model.uninstall(from: .claudeDesktop) } }
                }
            case .clientMissing:
                Text("Not installed").font(.caption).foregroundStyle(.tertiary)
            case .notInstalled, .otherCommand:
                Button("Connect") { model.install(in: .claudeDesktop) }.glassButton(prominent: true).controlSize(.small)
            }
        }
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.ok ? (entry.isWrite ? Color.orange : Color.green) : Color.red)
                .frame(width: 6, height: 6)
            Text(entry.tool).font(.caption.monospaced()).frame(width: 120, alignment: .leading)
            Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(entry.date, format: .dateTime.hour().minute()).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .frame(height: 22)
        .help("\(entry.client ?? "unknown client") · \(entry.milliseconds) ms\(entry.ok ? "" : " · failed")")
    }
}

// MARK: Approval

/// Several waiting emails: one shown in full with a pager, the others as one-line rows.
struct ApprovalQueue: View {
    @Bindable var model: AgentModel

    var focused: ApprovalRequest? {
        model.pending.first { $0.id == model.focusedApproval } ?? model.pending.first
    }

    var body: some View {
        if let focused {
            let index = model.pending.firstIndex { $0.id == focused.id } ?? 0
            VStack(alignment: .leading, spacing: 6) {
                ApprovalBlock(request: focused, position: model.pending.count > 1 ? (index, model.pending.count) : nil) { step in
                    let next = (index + step + model.pending.count) % model.pending.count
                    model.focusedApproval = model.pending[next].id
                } decide: { approve in
                    model.decide(focused, approve: approve)
                }
                ForEach(model.pending.filter { $0.id != focused.id }) { other in
                    Button {
                        model.focusedApproval = other.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope").foregroundStyle(.orange).frame(width: 16)
                            Text(other.subject.isEmpty ? "(no subject)" : other.subject).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(other.to.first ?? "").foregroundStyle(.secondary).lineLimit(1)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct ApprovalBlock: View {
    let request: ApprovalRequest
    /// (index, count) when several emails wait; shows the pager.
    var position: (Int, Int)?
    var page: (Int) -> Void = { _ in }
    let decide: (Bool) -> Void

    init(request: ApprovalRequest, position: (Int, Int)? = nil, page: @escaping (Int) -> Void = { _ in }, decide: @escaping (Bool) -> Void) {
        self.request = request
        self.position = position
        self.page = page
        self.decide = decide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SEND THIS EMAIL?").font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.orange)
                if let (index, count) = position {
                    HStack(spacing: 2) {
                        Button { page(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous email")
                        Text("\(index + 1) of \(count)").font(.caption2.monospacedDigit())
                        Button { page(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next email")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)  // keyboard focus belongs to Send / Don't Send
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text([request.client, request.tool.replacingOccurrences(of: "_", with: " ")].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(request.subject.isEmpty ? "(no subject)" : request.subject).font(.headline).lineLimit(2)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                GridRow {
                    Text("To").foregroundStyle(.secondary)
                    Text(request.to.joined(separator: ", ")).lineLimit(2)
                }
                if !request.cc.isEmpty {
                    GridRow {
                        Text("Cc").foregroundStyle(.secondary)
                        Text(request.cc.joined(separator: ", ")).lineLimit(2)
                    }
                }
                if !request.bcc.isEmpty {
                    GridRow {
                        Text("Bcc").foregroundStyle(.secondary)
                        Text(request.bcc.joined(separator: ", ")).lineLimit(2)
                    }
                }
                if !request.attachments.isEmpty {
                    GridRow {
                        Text("Files").foregroundStyle(.secondary)
                        Text(request.attachments.joined(separator: ", ")).lineLimit(2)
                    }
                }
            }
            .font(.caption)
            Divider()
            Text(request.bodyPreview).font(.callout).lineLimit(10).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Don't Send", role: .cancel) { decide(false) }.glassButton()
                Button("Send") { decide(true) }.glassButton(prominent: true).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.35)))
    }
}

struct ApprovalWindow: View {
    @Bindable var model: AgentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.pending.isEmpty {
                Text("Nothing is waiting for approval.").foregroundStyle(.secondary)
            }
            if !model.pending.isEmpty { ApprovalQueue(model: model) }
            Text("Nothing is sent without your OK. Requests cancel after \(Int(model.settings.approvalTimeout)) seconds.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .padding(.top, 4)
        .frame(width: 460)
    }
}

// MARK: Skills

struct SkillRow: View {
    @Bindable var model: AgentModel
    let skill: MailSkill

    var state: SkillInstaller.State { model.skillStates[skill.name] ?? .notInstalled }

    var badge: (String, Color) {
        switch state {
        case .installed: ("Installed", .green)
        case .updateAvailable: ("Update", .orange)
        case .foreign: ("Name taken", .secondary)
        case .notInstalled: ("Not added", .secondary)
        }
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.selectedSkills.contains(skill.name) },
            set: { selected in
                if selected { model.selectedSkills.insert(skill.name) } else { model.selectedSkills.remove(skill.name) }
            }))
        {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(skill.title).font(.callout)
                    Text(skill.summary).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(badge.0).font(.caption).foregroundStyle(badge.1)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(state == .foreign)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: Settings

struct SettingsView: View {
    @Bindable var model: AgentModel

    var body: some View {
        Form {
            Section("Sending") {
                Picker("When asked to send", selection: $model.settings.sendPolicy) {
                    Text("Ask me first").tag(SendPolicy.confirm)
                    Text("Send right away").tag(SendPolicy.allow)
                    Text("Never send (drafts only)").tag(SendPolicy.never)
                }
                Stepper("Wait up to \(Int(model.settings.approvalTimeout)) s for my answer", value: $model.settings.approvalTimeout, in: 30...600, step: 30)
            }
            Section("Changes to mail") {
                Toggle("Allow moving, flagging, trashing and new mailboxes", isOn: $model.settings.allowMailChanges)
                Stepper("At most \(model.settings.maxBatchSize) messages per change", value: $model.settings.maxBatchSize, in: 1...500)
            }
            Section("Search") {
                Toggle("Keep the body index up to date", isOn: $model.settings.autoUpdateBodyIndex)
                Button("Rebuild body index") { Task { await model.rebuildIndex() } }.disabled(model.isIndexing)
            }
            Section("Files and addresses") {
                TextField("Save attachments only into (folders, comma-separated)", text: list(\.writeDirectories))
                TextField("Attach files only from (folders, comma-separated)", text: list(\.attachDirectories))
                TextField("My other addresses (comma-separated)", text: list(\.ownAddresses))
            }
            Section("Claude") {
                ClaudeRows(model: model)
                LabeledContent("Server") { Text(model.serverPath).font(.caption.monospaced()).textSelection(.enabled) }
                HStack {
                    Button("Copy Claude Code command") { model.copy(model.claudeCodeCommand) }
                    Button("Copy Claude app config") { model.copy(model.desktopConfig) }
                }
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
            Section("Updates") {
                Toggle("Check for updates every day", isOn: $model.settings.checkForUpdates)
                    .disabled(!model.updater.isEnabled)
                Toggle("Update installed Claude skills with the app", isOn: $model.settings.updateInstalledSkills)
                HStack {
                    Text("Version \(model.updater.currentVersion?.description ?? MailMCPVersion.current)")
                    Spacer()
                    switch model.updater.state {
                    case .checking: ProgressView().controlSize(.small)
                    case .upToDate: Text("Up to date").foregroundStyle(.secondary)
                    case .available(let release): Text("\(release.version.description) available").foregroundStyle(.tint)
                    case .installing: Text("Installing…").foregroundStyle(.secondary)
                    case .failed(let message): Text(message).foregroundStyle(.red).lineLimit(2)
                    case .idle: EmptyView()
                    }
                    Button("Check Now") { Task { await model.updater.check() } }.disabled(!model.updater.isEnabled)
                }
                if !model.updater.isEnabled {
                    Text("Updates are available in builds signed by the developer (from GitHub Releases).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .frame(minHeight: 680)
        .onChange(of: model.settings) { model.save() }
    }

    private func list(_ keyPath: WritableKeyPath<MailMCPKit.Settings, [String]>) -> Binding<String> {
        Binding(
            get: { model.settings[keyPath: keyPath].joined(separator: ", ") },
            set: { model.settings[keyPath: keyPath] = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }
}
