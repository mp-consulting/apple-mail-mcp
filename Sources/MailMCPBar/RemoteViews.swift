import MailMCPKit
import SwiftUI

/// Settings › Remote access: serve claude.ai and the Claude apps through a tunnel, with OAuth.
struct RemoteSection: View {
    @Bindable var model: AgentModel
    @State private var passcode = ""
    @State private var copied = false

    private var remote: RemoteHost { model.remote }

    var body: some View {
        Section {
            Toggle("Let claude.ai and the Claude apps connect", isOn: $model.settings.remoteAccess)
            TextField("Public address", text: $model.settings.remoteAddress, prompt: Text(verbatim: "https://mcp.example.com/me/mail"))
            TextField("Port", value: $model.settings.remotePort, format: .number.grouping(.never))
            Picker("Listen on", selection: $model.settings.remoteListen) {
                Text("Every network (tunnel on another machine)").tag("")
                Text("This Mac only (tunnel on this Mac)").tag("127.0.0.1")
            }
            LabeledContent("Status") { statusText }
            if let address = RemoteServer.Address(model.settings.remoteAddress) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Connector URL")
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            model.copy(address.resource)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                    Text(verbatim: address.resource).font(.callout.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tunnel route")
                    Text(verbatim: "Hostname \(address.host), path \(Self.routePath(address))")
                        .font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                SecureField(remote.hasPasscode ? "New passcode" : "Passcode (8 characters or more)", text: $passcode)
                Button(remote.hasPasscode ? "Change" : "Set") {
                    remote.setPasscode(passcode)
                    passcode = ""
                }
                .disabled(passcode.count < 8)
                if remote.hasPasscode {
                    Button("Remove") { remote.setPasscode(nil) }
                }
            }
            if let message = remote.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Remote access")
        } footer: {
            Text("""
                In claude.ai, add a custom connector with the connector URL. Connecting asks for the passcode, or for Allow here. \
                Sending and big changes still ask here, as for Claude on this Mac. Publish the port with a tunnel (cloudflared) \
                whose route also carries the discovery documents, as shown.
                """)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Section("Connected apps") {
            if remote.apps.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            }
            ForEach(remote.apps) { app in
                HStack {
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

    @ViewBuilder
    private var statusText: some View {
        switch remote.status {
        case .off: Text("Off").foregroundStyle(.secondary)
        case .needsAddress: Text("Enter the public address").foregroundStyle(.orange)
        case .starting: Text("Starting…").foregroundStyle(.secondary)
        case .running: Text("Listening on port \(model.settings.remotePort.formatted(.number.grouping(.never)))").foregroundStyle(.green)
        case .failed(let message): Text(message).foregroundStyle(.red).lineLimit(3)
        }
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

    private var appsText: String {
        let count = model.remote.apps.count
        return count == 0 ? "no app connected" : count == 1 ? "1 app connected" : "\(count) apps connected"
    }
}
