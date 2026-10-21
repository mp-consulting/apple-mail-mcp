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
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .help(detail)
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
    /// One selection pill that slides from tab to tab, like a segmented control.
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                Button { select(tab) } label: {
                    HStack(spacing: 5) {
                        Text(tab.rawValue)
                        if tab == .mail, !model.pending.isEmpty {
                            Text("\(model.pending.count)")
                                .contentTransition(.numericText(value: Double(model.pending.count)))
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
                    .background {
                        if selected == tab {
                            RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.14))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityAddTraits(selected == tab ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
        .animatesChanges(of: selected)
        .animatesChanges(of: model.pending.count)
    }
}

struct MailTab: View {
    @Bindable var model: AgentModel

    /// Rows that come and go while the panel is open slide into place. The approval queue sits outside
    /// both animated groups: it appears and leaves at once, so a Send button never lingers on screen.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { update }
            .animatesChanges(of: [model.updater.availableRelease?.version.description, model.updater.installing != nil,
                                model.updater.installedElsewhere?.description] as [AnyHashable])
        if !model.pending.isEmpty {
            ApprovalQueue(model: model).padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 4).neverAnimated()
        }
        VStack(alignment: .leading, spacing: 0) { status }
            .animatesChanges(of: [
                model.attention.map(\.id), model.snoozedCount, model.scheduledSends.count, model.needsReply.count,
                model.activity.first?.id,
            ] as [AnyHashable])
    }

    @ViewBuilder private var update: some View {
        if let (release, progress) = model.updater.installing {
            Row(
                systemImage: "arrow.down.circle.fill", iconColor: .accentColor,
                title: "Updating to version \(release.version.description)", detail: progress.step)
            {
                ProgressView(value: progress.fraction).frame(width: 110)
                    .accessibilityLabel("Update progress")
            }
        } else if let version = model.updater.installedElsewhere {
            Row(
                systemImage: "arrow.clockwise.circle.fill", iconColor: .accentColor,
                title: "Version \(version.description) is installed",
                detail: "Another account on this Mac updated Apple Mail MCP. Relaunch to use it.")
            {
                Button("Relaunch") { model.updater.relaunchIntoInstalledVersion() }.glassButton(prominent: true).controlSize(.small)
            }
        } else if let release = model.updater.availableRelease {
            Row(
                systemImage: "arrow.down.circle.fill", iconColor: .accentColor,
                title: "Version \(release.version.description) is available",
                detail: model.updater.installBlocker
                    ?? (model.updater.needsAdministrator
                        ? "Asks for an administrator's password, then relaunches."
                        : "Installs and relaunches in a few seconds."))
            {
                if model.updater.installBlocker == nil {
                    Button("Update") { Task { await model.updater.install(release) } }.glassButton(prominent: true).controlSize(.small)
                } else {
                    Link("Download", destination: release.pageURL).controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if !model.attention.isEmpty {
            SectionHeader("Needs attention")
            ForEach(model.attention) { item in
                Row(systemImage: item.icon, iconColor: .orange, title: item.title, detail: item.detail) {
                    Button(item.action) { model.perform(item) }.glassButton().controlSize(.small)
                }
            }
        }
        if model.snoozedCount > 0 || !model.scheduledSends.isEmpty {
            let parts = [
                model.snoozedCount > 0 ? "\(model.snoozedCount) snoozed" : nil,
                model.scheduledSends.isEmpty ? nil : "\(model.scheduledSends.count) to send later",
            ].compactMap { $0 }
            Row(
                systemImage: "clock", iconColor: .secondary, title: parts.joined(separator: " · "),
                detail: model.scheduledSends.first.map { "Next: \($0.subject) · \($0.sendAt.formatted(date: .abbreviated, time: .shortened))" }
                    ?? "They come back on time while this app runs.")
            {
                EmptyView()
            }
        }
        if !model.needsReply.isEmpty {
            let count = model.needsReply.count
            Row(
                systemImage: "arrowshape.turn.up.left", iconColor: .accentColor,
                title: count == 1 ? "1 email waits for your reply" : "\(count) emails wait for your reply",
                detail: model.needsReply.prefix(3).map { $0.sender.name ?? $0.sender.address }.joined(separator: ", "))
            {
                Button("Open Mail") { model.openMail() }.glassButton().controlSize(.small)
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
        SettingRow("Ask me before changing more than") {
            Stepper(model.settings.approveChangesAbove == 0 ? "never ask" : "\(model.settings.approveChangesAbove)",
                    value: $model.settings.approveChangesAbove, in: 0...500, step: 5).fixedSize()
        }
        SettingRow("Notify me when mail waits for a reply") { Toggle("", isOn: $model.settings.notifyNeedsReply).labelsHidden() }
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

    /// A shape as well as a colour, so the state reads without telling green from orange.
    private var status: (symbol: String, color: Color, label: String) {
        if entry.running == true { return ("circle.dotted", .secondary, "Running") }
        if !entry.ok { return ("xmark.circle.fill", .red, "Failed") }
        return entry.isWrite ? ("diamond.fill", .orange, "Changed mail") : ("circle.fill", .green, "Read mail")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(status.color)
                .frame(width: 10).accessibilityLabel(status.label)
            // Words, not the identifier: the longest name (extract invoice fields) fits the column.
            Text(entry.tool.replacingOccurrences(of: "_", with: " ")).font(.caption).lineLimit(1)
                .frame(width: 132, alignment: .leading)
            // A failure is the one summary worth a second line.
            Text(entry.summary).font(.caption).foregroundStyle(entry.ok ? .secondary : .primary).lineLimit(entry.ok ? 1 : 2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let link = entry.link, let url = URL(string: link) {
                ShowInMailButton(url: url, compact: true)
            }
            // The time alone reads as today: older entries show their day.
            Text(entry.date, format: Calendar.current.isDateInToday(entry.date) ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated))
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .frame(minHeight: 22)
        .help("\(entry.summary)\n\(entry.client ?? "unknown client") · \(entry.milliseconds) ms\(entry.ok ? "" : " · failed")")
    }
}

/// An address kept left to right inside right-to-left text, so `name@example.com` never reads `example.com@name`.
func isolatedLTR(_ text: String) -> String { "\u{2066}\(text)\u{2069}" }

/// Opens a message in Mail through its `message://` link (no Apple Events, no permission needed).
struct ShowInMailButton: View {
    let url: URL
    var compact: Bool
    var title = "Show in Mail"

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            if compact {
                Image(systemName: "arrow.up.forward.app").font(.caption)
            } else {
                Label(title, systemImage: "arrow.up.forward.app").font(.caption)
            }
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
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
                let others = model.pending.filter { $0.id != focused.id }
                ForEach(others.prefix(Self.visibleOthers)) { other in
                    Button {
                        model.focusedApproval = other.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope").foregroundStyle(.orange).frame(width: 16)
                            Text(other.subject.isEmpty ? "(no subject)" : other.subject).lineLimit(1)
                            Spacer(minLength: 6)
                            // Addresses on one domain differ at the start and the end: cut the middle.
                            Text(other.to.first.map(isolatedLTR) ?? (other.action == .change ? "change" : "")).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                if others.count > Self.visibleOthers {
                    Text("\(others.count - Self.visibleOthers) more waiting · the arrows above go through all of them")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
            }
        }
    }

    /// Keeps the panel and the approval window to a height that fits any screen, however many requests wait.
    static let visibleOthers = 5
}

struct ApprovalBlock: View {
    let request: ApprovalRequest
    @Environment(\.colorSchemeContrast) private var contrast
    /// (index, count) when several emails wait; shows the pager.
    var position: (Int, Int)?
    var page: (Int) -> Void = { _ in }
    let decide: (Bool) -> Void
    /// The lists (To, Cc, Bcc, Files) shown in full.
    @State private var expanded: Set<String> = []

    init(request: ApprovalRequest, position: (Int, Int)? = nil, page: @escaping (Int) -> Void = { _ in }, decide: @escaping (Bool) -> Void) {
        self.request = request
        self.position = position
        self.page = page
        self.decide = decide
    }

    /// The question and the two answers, by what is asked.
    var wording: (question: String, yes: String, no: String) {
        switch request.action {
        case .send: (request.sendAt == nil ? "SEND THIS EMAIL?" : "SEND THIS EMAIL LATER?", request.sendAt == nil ? "Send" : "Schedule", "Don't Send")
        case .change: ("CHANGE THESE MESSAGES?", "Go Ahead", "Don't")
        case .unsubscribe: ("UNSUBSCRIBE?", "Unsubscribe", "Don't")
        case .rule: ("ALLOW THIS MAIL RULE?", "Allow", "Don't")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(wording.question).font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.orange)
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
                let origin = [request.client, request.tool.replacingOccurrences(of: "_", with: " ")].compactMap { $0 }.joined(separator: " · ")
                Text(origin).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(origin)
            }
            // In full: the subject is part of what is approved.
            Text(request.subject.isEmpty ? "(no subject)" : request.subject).font(.headline).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                listRow("To", request.to.map(isolatedLTR))
                if let sendAt = request.sendAt {
                    GridRow {
                        Text("When").foregroundStyle(.secondary)
                        Text(sendAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                listRow("Cc", request.cc.map(isolatedLTR))
                listRow("Bcc", request.bcc.map(isolatedLTR))
                listRow("Files", request.attachments)
            }
            .font(.caption)
            Divider()
            // The whole preview the server sent (it keeps 600 characters); long ones scroll inside the block.
            ScrollView {
                Text(request.bodyPreview).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            if request.bodyPreview.hasSuffix("…") {
                Text("Preview: the first 600 characters of the message.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                if let link = request.originalLink, let url = URL(string: link) {
                    ShowInMailButton(url: url, compact: false, title: "Show original in Mail")
                }
                Spacer()
                Button(wording.no, role: .cancel) { decide(false) }.glassButton()
                Button(wording.yes) { decide(true) }.glassButton(prominent: true).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(contrast == .increased ? 0.18 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(contrast == .increased ? 0.9 : 0.35),
                                                                 lineWidth: contrast == .increased ? 1.5 : 1))
        .onChange(of: request.id) { expanded = [] }
    }

    /// A list never cut silently: its count, the first three, and the rest one click away.
    @ViewBuilder
    private func listRow(_ label: String, _ values: [String]) -> some View {
        if !values.isEmpty {
            let shown = 3
            let open = expanded.contains(label)
            GridRow(alignment: .firstTextBaseline) {
                Text(values.count > 1 ? "\(label) (\(values.count))" : label).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text((open ? values : Array(values.prefix(shown))).joined(separator: ", "))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if values.count > shown {
                        Button(open ? "Show fewer" : "and \(values.count - shown) more") {
                            if open { expanded.remove(label) } else { expanded.insert(label) }
                        }
                        .buttonStyle(.link)
                        .focusable(false)  // keyboard focus belongs to Send / Don't Send
                    }
                }
            }
        }
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
            Text("Nothing is sent, unsubscribed or changed in bulk without your OK. Requests cancel after \(Int(model.settings.approvalTimeout)) seconds.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    SlashCommand(name: skill.name)
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

/// `/mail-triage`: how to run a skill in Claude Code. Click copies it.
struct SlashCommand: View {
    let name: String
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("/\(name)", forType: .string)
            copied = true
            // A second click restarts the wait instead of being cut short by the first one.
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if !Task.isCancelled { copied = false }
            }
        } label: {
            Text(copied ? "Copied /\(name)" : "/\(name)")
                .font(.callout.monospaced())
                .foregroundStyle(copied ? Color.green : Color.orange)
                .contentTransition(.opacity)
        }
        .buttonStyle(.borderless)
        .animatesChanges(of: copied)
        .help("Type /\(name) in Claude Code to run this skill. Click to copy.")
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
                Stepper(
                    model.settings.approveChangesAbove == 0
                        ? "Never ask before moving or trashing" : "Ask me before moving or trashing more than \(model.settings.approveChangesAbove)",
                    value: $model.settings.approveChangesAbove, in: 0...500, step: 5)
            }
            Section("Notifications") {
                Toggle("Notify me when mail from a person waits for my reply", isOn: $model.settings.notifyNeedsReply)
            }
            Section("Search") {
                Toggle("Keep the body index up to date", isOn: $model.settings.autoUpdateBodyIndex)
                Button("Rebuild body index") { Task { await model.rebuildIndex() } }.disabled(model.isIndexing)
            }
            Section("Files and addresses") {
                TextField("Save attachments only into (folders, comma-separated)", text: list(\.writeDirectories))
                TextField("Attach files only from (folders, comma-separated)", text: list(\.attachDirectories))
                TextField("My other addresses (comma-separated)", text: list(\.ownAddresses))
                TextField("Names I send as, e.g. my company (comma-separated)", text: list(\.ownNames))
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
                    case .installing(_, let progress):
                        ProgressView(value: progress.fraction).frame(width: 120).help(progress.step)
                    case .installedElsewhere(let version):
                        Button("Relaunch to Use \(version.description)") { model.updater.relaunchIntoInstalledVersion() }
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
