import AppKit
import MailMCPKit
import Observation
import Security

/// Checks GitHub once a day for a newer release, and installs it when asked (same design as Panes).
///
/// A file downloaded here gets no quarantine flag, so Gatekeeper never looks at it: the signature
/// checks in `installUpdate` are the only gate. The disk image must be notarized and signed with the
/// team's Developer ID, and the app copied out of it must carry this app's identifier and that same
/// signature, which also keeps the Full Disk Access and Automation grants across the update.
@MainActor @Observable final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release)
        case failed(String)
    }

    /// Where an install is, for the progress bar: a step and how far along the whole install is (0…1).
    struct InstallProgress: Equatable, Sendable {
        var step: String
        var fraction: Double
    }

    private(set) var state: State = .idle
    /// Set while `state` is `.installing`.
    private(set) var installProgress: InstallProgress?
    /// Off for development builds: without the team's signature there is no safe way to replace them.
    let isEnabled: Bool
    let currentVersion: AppVersion?
    /// Whether the user wants daily checks (Settings → Updates).
    var automaticChecks: () -> Bool = { true }

    @ObservationIgnored private var schedule: Task<Void, Never>?

    nonisolated static let appName = "Apple Mail MCP.app"
    private static let lastCheckKey = "lastUpdateCheck"
    private nonisolated static let developerID = #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "4HWBUF2R8D""#
    private nonisolated static let appRequirement = #"identifier "com.mpconsulting.AppleMailMCP" and "# + developerID
    private nonisolated static let diskImageRequirement = "notarized and " + developerID

    init() {
        currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        isEnabled = Self.satisfies(Bundle.main.bundleURL, Self.appRequirement)
    }

    var availableRelease: Release? {
        if case let .available(release) = state { release } else { nil }
    }

    var installingRelease: Release? {
        if case let .installing(release) = state { release } else { nil }
    }

    /// Checks now if a day has passed, then looks again every hour (a Mac that slept through the
    /// due time catches up within the hour).
    func start() {
        guard isEnabled, schedule == nil else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
            }
        }
    }

    func checkIfDue() async {
        let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        guard automaticChecks(), UpdateSchedule.isDue(lastCheck: lastCheck) else { return }
        await check()
    }

    func check() async {
        switch state {
        case .checking, .installing: return
        default: break
        }
        guard isEnabled else { return }
        state = .checking
        do {
            var request = URLRequest(url: Release.latestURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("AppleMailMCP/\(currentVersion?.description ?? "dev")", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            // No published release yet: GitHub answers 404 for releases/latest.
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                UserDefaults.standard.set(Date.now, forKey: Self.lastCheckKey)
                state = .upToDate
                return
            }
            try Self.expectOK(response)
            let release = try Release(gitHubJSON: data)
            UserDefaults.standard.set(Date.now, forKey: Self.lastCheckKey)
            if let currentVersion, release.version > currentVersion {
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch Release.Failure.noDiskImage {
            // Published but still building: not an error, and the next check will see it.
            state = .upToDate
        } catch {
            state = .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    /// Why the app can't replace itself where it runs, if it can't; the release page is offered instead.
    var installBlocker: String? {
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        if app.path.contains("/AppTranslocation/") {
            return "Move Apple Mail MCP to the Applications folder to install updates from here."
        }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return "Apple Mail MCP is running from a read-only disk. Copy it to Applications first."
        }
        if !FileManager.default.isWritableFile(atPath: folder.path) {
            return "Your account can't write to \(folder.path(percentEncoded: false)). Download the update instead."
        }
        return nil
    }

    func install(_ release: Release) async {
        guard installBlocker == nil else { return }
        state = .installing(release)
        installProgress = InstallProgress(step: "Starting the download…", fraction: 0)
        // Reports arrive from the download's threads; a late one never moves the bar back.
        let report: @Sendable (InstallProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, let current = self.installProgress, progress.fraction >= current.fraction else { return }
                self.installProgress = progress
            }
        }
        do {
            try await Self.installUpdate(release, over: Bundle.main.bundleURL, report: report)
            installProgress = InstallProgress(step: "Relaunching…", fraction: 1)
            relaunch()
        } catch {
            installProgress = nil
            state = .failed("Couldn't install Apple Mail MCP \(release.version): \(error.localizedDescription)")
        }
    }

    // MARK: Installing

    private struct InstallError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// The download is most of the time an install takes: it fills the bar up to here, the checks and the copy the rest.
    private nonisolated static let downloadShare = 0.8

    private nonisolated static func installUpdate(
        _ release: Release, over app: URL, report: @escaping @Sendable (InstallProgress) -> Void
    ) async throws {
        let files = FileManager.default
        // On the app's volume, so the final swap is a rename rather than a copy. Resolved, because
        // diskutil only knows a mount point by its real path (/private/var/…, not /var/…).
        let work = realPath(try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true))
        defer { try? files.removeItem(at: work) }

        let observer = DownloadObserver { received, expected in
            let sizes = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                + (expected > 0 ? " of " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) : "")
            let share = expected > 0 ? Double(received) / Double(expected) : 0
            report(InstallProgress(step: "Downloading \(sizes)…", fraction: downloadShare * min(share, 1)))
        }
        let (download, response) = try await URLSession.shared.download(from: release.diskImageURL, delegate: observer)
        try expectOK(response)
        let image = work.appending(path: "AppleMailMCP.dmg")
        try files.moveItem(at: download, to: image)
        report(InstallProgress(step: "Checking the download's signature…", fraction: 0.82))
        guard satisfies(image, diskImageRequirement) else {
            throw InstallError("the download isn't a notarized disk image signed by Apple Mail MCP's developer.")
        }

        let mountPoint = work.appending(path: "image")
        report(InstallProgress(step: "Opening the disk image…", fraction: 0.86))
        try run("/usr/sbin/diskutil", "image", "attach", "--mountOptions", "nobrowse", "--readOnly",
                "--mountPoint", mountPoint.path, image.path)
        defer { eject(mountPoint) }

        // Checked after the copy: what gets installed is this copy, not what was on the image.
        let staged = work.appending(path: appName)
        report(InstallProgress(step: "Copying the new version…", fraction: 0.88))
        try files.copyItem(at: mountPoint.appending(path: appName), to: staged)
        report(InstallProgress(step: "Checking the app's signature…", fraction: 0.93))
        guard satisfies(staged, appRequirement, flags: [.checkNestedCode]) else {
            throw InstallError("the app in the download isn't signed by Apple Mail MCP's developer.")
        }
        let info = NSDictionary(contentsOf: staged.appending(path: "Contents/Info.plist"))
        guard let version = (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
              version == release.version
        else { throw InstallError("the download holds a different version than the release.") }

        report(InstallProgress(step: "Installing…", fraction: 0.97))
        _ = try files.replaceItemAt(app, withItemAt: staged)
    }

    /// Waits for this process to exit, then opens the new copy.
    private func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(filePath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                            "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        do {
            try waiter.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("Apple Mail MCP was updated. Quit and reopen it to finish.")
        }
    }

    private nonisolated static func expectOK(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw InstallError("GitHub answered with status \(status).") }
    }

    /// A plain eject first; a forced one if something (Spotlight, say) still has the volume open.
    private nonisolated static func eject(_ mountPoint: URL) {
        if (try? run("/usr/sbin/diskutil", "eject", mountPoint.path)) == nil {
            try? run("/usr/sbin/diskutil", "eject", "force", mountPoint.path)
        }
    }

    private nonisolated static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
    }

    private nonisolated static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError("\(URL(filePath: tool).lastPathComponent) failed with status \(process.terminationStatus).")
        }
    }

    private nonisolated static func satisfies(_ url: URL, _ requirement: String, flags: SecCSFlags = []) -> Bool {
        var code: SecStaticCode?
        var compiled: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled
        else { return false }
        let checks = flags.union([.checkAllArchitectures, .strictValidate])
        return SecStaticCodeCheckValidity(code, checks, compiled) == errSecSuccess
    }
}

/// Bytes received by the update's download, from the task the async `download` creates. Reports only when the
/// percentage moves, not for every chunk.
private final class DownloadObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var reportedPercent = -1

    init(report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observation = task.observe(\.countOfBytesReceived) { [weak self] task, _ in
            self?.received(task.countOfBytesReceived, of: task.countOfBytesExpectedToReceive)
        }
        lock.withLock { self.observation = observation }
    }

    private func received(_ bytes: Int64, of expected: Int64) {
        let percent = expected > 0 ? Int(bytes * 100 / expected) : Int(bytes >> 20)
        let changed = lock.withLock {
            defer { reportedPercent = max(reportedPercent, percent) }
            return percent > reportedPercent
        }
        if changed { report(bytes, expected) }
    }
}

extension SecCSFlags {
    static let checkAllArchitectures = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
    static let strictValidate = SecCSFlags(rawValue: kSecCSStrictValidate)
    static let checkNestedCode = SecCSFlags(rawValue: kSecCSCheckNestedCode)
}
