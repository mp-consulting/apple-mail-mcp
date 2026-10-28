import Foundation
import MailMCPKit
import Observation

/// Keeps `apple-mail-mcp remote` running while Settings › Remote access is on, with the settings it was started
/// with; restarts it when they change or it stops, and lists the connected apps from `remote-access.json`.
@MainActor
@Observable
final class RemoteHost {
    enum Status: Equatable {
        case off
        case needsAddress
        case starting
        case running(String)
        case failed(String)
    }

    struct App: Identifiable, Equatable {
        var id: String
        var name: String
        var readOnly: Bool
        var created: Date
        var lastUsed: Date?
    }

    private(set) var status: Status = .off
    private(set) var apps: [App] = []
    private(set) var hasPasscode = false
    var message: String?

    let access = RemoteAccess()
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var runningWith: (address: String, port: Int, listen: String)?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var lastError = ""
    @ObservationIgnored private var lastLaunch = Date.distantPast
    @ObservationIgnored private var lastSettings: (address: String, port: Int, listen: String)?

    /// Brings the process in line with the settings; called when they change and every few seconds.
    func apply(_ settings: Settings, serverPath: String) {
        refreshApps()
        guard settings.remoteAccess else {
            stop()
            status = .off
            return
        }
        guard let address = RemoteServer.Address(settings.remoteAddress) else {
            stop()
            status = .needsAddress
            return
        }
        let wanted = (settings.remoteAddress, settings.remotePort, settings.remoteListen)
        if let process, process.isRunning, let runningWith, runningWith == wanted { return }
        // A server that failed to start (the port is taken…) is tried again every half minute, not every tick.
        if process == nil, case .failed = status, Date().timeIntervalSince(lastLaunch) < 30, lastSettings.map({ $0 == wanted }) == true { return }
        stop()
        launch(serverPath: serverPath, settings: wanted, resource: address.resource)
    }

    private func launch(serverPath: String, settings: (address: String, port: Int, listen: String), resource: String) {
        let process = Process()
        process.executableURL = URL(filePath: serverPath)
        process.arguments = ["remote"]
        var environment = ProcessInfo.processInfo.environment
        environment["APPLE_MAIL_MCP_REMOTE_CHILD"] = "1"
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                if text.contains("serving") {
                    self.status = .running(resource)
                } else {
                    self.lastError = text.replacingOccurrences(of: "apple-mail-mcp: ", with: "")
                }
            }
        }
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self, self.process === ended else { return }
                self.process = nil
                self.runningWith = nil
                self.status = .failed(self.lastError.isEmpty ? "The server stopped." : self.lastError)
            }
        }
        lastLaunch = Date()
        lastSettings = settings
        do {
            try process.run()
            self.process = process
            runningWith = settings
            lastError = ""
            status = .starting
        } catch {
            status = .failed("Could not start the server: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let process else { return }
        self.process = nil
        runningWith = nil
        if process.isRunning { process.terminate() }
    }

    func refreshApps() {
        let state = access.state
        hasPasscode = state.passcode != nil
        let names = Dictionary(state.clients.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let current = state.grants.sorted { $0.created > $1.created }.map {
            App(id: $0.id, name: names[$0.clientID] ?? "An MCP client", readOnly: $0.readOnly, created: $0.created, lastUsed: $0.lastUsed)
        }
        if current != apps { apps = current }
    }

    func disconnect(_ app: App) {
        do {
            try access.revoke(grant: app.id)
            message = "Disconnected \(app.name)."
        } catch {
            message = "Could not disconnect: \(error.localizedDescription)"
        }
        refreshApps()
    }

    func setPasscode(_ passcode: String?) {
        do {
            try access.setPasscode(passcode)
            message = passcode == nil ? "Passcode removed: connections are approved here only." : "Passcode set."
        } catch {
            message = "\(error)"
        }
        refreshApps()
    }
}
