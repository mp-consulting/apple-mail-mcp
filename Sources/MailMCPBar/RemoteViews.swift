import MailMCPKit
import SwiftUI

/// Settings › Remote access: serve claude.ai and the Claude apps through a tunnel, with OAuth.
struct RemoteSection: View {
    @Bindable var model: AgentModel
    @State private var passcode = ""
    @State private var copied: String?

    private var remote: RemoteHost { model.remote }

    var body: some View {
        Section {
            Toggle(isOn: $model.settings.remoteAccess) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let claude.ai and the Claude apps connect")
                    if model.settings.remoteAccess { statusLine } else {
                        Text("Use Apple Mail from Claude on the web and your phone, through a tunnel to this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Remote access")
        }
        if model.settings.remoteAccess {
            Section {
                TextField("Public address", text: $model.settings.remoteAddress, prompt: Text(verbatim: "https://mcp.example.com/me/mail"))
                TextField("Port", value: $model.settings.remotePort, format: .number.grouping(.never))
                Picker("Listen on", selection: $model.settings.remoteListen) {
                    Text("Every network (tunnel on another machine)").tag("")
                    Text("This Mac only (tunnel on this Mac)").tag("127.0.0.1")
                }
            } header: {
                Text("Connection")
            }
            if let address = RemoteServer.Address(model.settings.remoteAddress) {
                Section {
                    copyRow("Connector URL", value: address.resource, font: .callout.monospaced())
                    copyRow("Tunnel path", value: Self.routePath(address), font: .caption.monospaced())
                } header: {
                    Text("Connect from claude.ai")
                } footer: {
                    Text("In claude.ai: Settings › Connectors › Add custom connector, with the connector URL. In the tunnel, route \(address.host) with the tunnel path to this Mac's port.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                LabeledContent("Passcode") {
                    if remote.hasPasscode {
                        Label("Set", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
                    } else {
                        Text("Not set").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    SecureField(remote.hasPasscode ? "New passcode" : "8 characters or more", text: $passcode)
                        .onSubmit(savePasscode)
                    Button(remote.hasPasscode ? "Change" : "Set", action: savePasscode).disabled(passcode.count < 8)
                    if remote.hasPasscode {
                        Button("Remove", role: .destructive) { remote.setPasscode(nil) }
                    }
                }
                if let message = remote.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Approval")
            } footer: {
                Text("Connecting asks for the passcode, or for Allow here. Sending and big changes still ask here, as for Claude on this Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Connected apps") {
                if remote.apps.isEmpty {
                    Text("None yet. Apps you approve show here.").foregroundStyle(.secondary)
                }
                ForEach(remote.apps) { app in
                    HStack {
                        Image(systemName: app.readOnly ? "eye" : "square.and.pencil").foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name + (app.readOnly ? " · read only" : ""))
                            Text(Self.detail(app)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Disconnect") { remote.disconnect(app) }
                    }
                }
            }
        }
    }

    private func savePasscode() {
        guard passcode.count >= 8 else { return }
        remote.setPasscode(passcode)
        passcode = ""
    }

    /// A value to paste elsewhere, on its own line under its label, with a Copy button that says it worked.
    private func copyRow(_ title: String, value: String, font: Font) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Button(copied == title ? "Copied" : "Copy") {
                    model.copy(value)
                    copied = title
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if copied == title { copied = nil }
                    }
                }
                .controlSize(.small)
            }
            Text(verbatim: value).font(font).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The server's state, next to the switch it follows.
    private var statusLine: some View {
        let (color, text): (Color, String) = switch remote.status {
        case .off: (.secondary, "Off")
        case .needsAddress: (.orange, "Enter the public address below")
        case .starting: (.secondary, "Starting…")
        case .running: (.green, "Listening on port \(model.settings.remotePort.formatted(.number.grouping(.never))) · \(Self.appsText(remote.apps.count))")
        case .failed(let message): (.red, message)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    static func appsText(_ count: Int) -> String {
        count == 0 ? "no app connected" : count == 1 ? "1 app connected" : "\(count) apps connected"
    }

    static func detail(_ app: RemoteHost.App) -> String {
        let connected = "Connected \(app.created.formatted(date: .abbreviated, time: .omitted))"
        guard let lastUsed = app.lastUsed else { return connected }
        return connected + " · last used \(lastUsed.formatted(.relative(presentation: .named)))"
    }

    /// The path regex a cloudflared route needs: the endpoint and everything under it, and the discovery documents
    /// that RFC 9728 and RFC 8414 put at the root with this path appended.
    static func routePath(_ address: RemoteServer.Address) -> String {
        "^/(\\.well-known/[^/]+/)?\(regexEscaped(String(address.endpoint.dropFirst())))(/.*)?$"
    }

    static func regexEscaped(_ path: String) -> String {
        path.map { ".+*?()[]{}|^$\\".contains($0) ? "\\\($0)" : String($0) }.joined()
    }
}

/// The panel's one line about remote access; the details live in the Settings window.
struct RemoteRow: View {
    @Bindable var model: AgentModel

    var body: some View {
        SettingRow("Remote access for claude.ai") {
            Toggle("", isOn: $model.settings.remoteAccess).labelsHidden()
        }
        if model.settings.remoteAccess {
            Group {
                switch model.remote.status {
                case .running(let resource): Text(verbatim: "\(resource) · \(appsText)")
                case .needsAddress: Text("Set the public address in More settings…").foregroundStyle(.orange)
                case .failed(let message): Text(message).foregroundStyle(.red)
                default: Text("Starting…")
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            .padding(.horizontal, 16).padding(.bottom, 4)
        }
    }

    private var appsText: String { RemoteSection.appsText(model.remote.apps.count) }
}
