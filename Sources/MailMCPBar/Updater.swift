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
        case installing(Release, InstallProgress)
        /// Another account installed this version over the running one.
        case installedElsewhere(AppVersion)
        case failed(String)
    }

    /// Where an install is, for the progress bar: a step and how far along the whole install is (0…1).
    struct InstallProgress: Equatable, Sendable {
        var step: String
        var fraction: Double
    }

    private(set) var state: State = .idle
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

    var installing: (release: Release, progress: InstallProgress)? {
        if case let .installing(release, progress) = state { (release, progress) } else { nil }
    }

    var installedElsewhere: AppVersion? {
        if case let .installedElsewhere(version) = state { version } else { nil }
    }

    /// Checks now if a day has passed, then looks again every hour (a Mac that slept through the
    /// due time catches up within the hour).
    func start() {
        guard isEnabled, schedule == nil else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                if self?.noticeNewerInstall() != true { await self?.checkIfDue() }
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
        guard isEnabled, !noticeNewerInstall() else { return }
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
        if app.path.contains("/AppTranslocation/") {
            return "Move Apple Mail MCP to the Applications folder to install updates from here."
        }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return "Apple Mail MCP is running from a read-only disk. Copy it to Applications first."
        }
        return nil
    }

    /// Whether installing asks for an administrator's password: the app was installed by another account
    /// (or by hand from the disk image), so this account can't replace it.
    var needsAdministrator: Bool { !Self.canReplace(Bundle.main.bundleURL) }

    func install(_ release: Release) async {
        guard installBlocker == nil else { return }
        state = .installing(release, InstallProgress(step: "Starting the download…", fraction: 0))
        // Reports arrive from the download's threads; a late one never moves the bar back.
        let report: @Sendable (InstallProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, let current = self.installing, progress.fraction >= current.progress.fraction else { return }
                self.state = .installing(current.release, progress)
            }
        }
        do {
            try await Self.installUpdate(release, over: Bundle.main.bundleURL, report: report)
            state = .installing(release, InstallProgress(step: "Relaunching…", fraction: 1))
            relaunch()
        } catch {
            state = .failed("Couldn't install Apple Mail MCP \(release.version): \(error.localizedDescription)")
        }
    }

    /// The version in the app's folder now. Newer than the one running when another account updated the app.
    private nonisolated static func installedVersion(of app: URL) -> AppVersion? {
        (NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String)
            .flatMap(AppVersion.init)
    }

    /// Another account updated the app under this one: offer a relaunch instead of the same update again.
    /// Returns whether a newer copy is installed.
    @discardableResult func noticeNewerInstall() -> Bool {
        guard let currentVersion, let installed = Self.installedVersion(of: Bundle.main.bundleURL), installed > currentVersion
        else { return false }
        switch state {
        case .installing: break  // our own install, about to relaunch
        default: state = .installedElsewhere(installed)
        }
        return true
    }

    /// Opens the copy another account installed, once this one has quit.
    func relaunchIntoInstalledVersion() {
        relaunch()
    }

    // MARK: Installing

    private struct InstallError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// The download is most of the time an install takes: it fills the bar up to here, the checks and the copy the rest.
    private nonisolated static let downloadShare = 0.8

    /// Downloads, checks and swaps the app: `diskutil` and the copy block, so this never runs on the main actor
    /// (under Swift 6.2's approachable concurrency a plain `nonisolated async` would run on its caller).
    #if compiler(>=6.2)
    @concurrent
    #endif
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

        if canReplace(app) {
            report(InstallProgress(step: "Installing…", fraction: 0.97))
            _ = try files.replaceItemAt(app, withItemAt: staged)
            shareWithAdministrators(app)
        } else {
            report(InstallProgress(step: "Waiting for an administrator's password…", fraction: 0.97))
            try installAsAdministrator(staged, over: app)
        }
    }

    /// Replacing the app means moving its folder and deleting what's inside, so every folder in it must be
    /// writable, not just the one it sits in. A copy another account installed (or updated) isn't.
    private nonisolated static func canReplace(_ app: URL) -> Bool {
        let files = FileManager.default
        var folders = [app.deletingLastPathComponent(), app]
        if let walk = files.enumerator(at: app, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walk where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                folders.append(url)
            }
        }
        return folders.allSatisfy { files.isWritableFile(atPath: $0.path) }
    }

    /// Lets every administrator account on the Mac update the app next time, not only this one. Code signatures
    /// don't cover permissions, so this leaves the signature intact.
    private nonisolated static func shareWithAdministrators(_ app: URL) {
        try? run("/usr/sbin/chown", "-R", ":admin", app.path)
        try? run("/bin/chmod", "-R", "g+w", app.path)
    }

    /// Swaps the app as root, after the macOS administrator prompt. The signature is checked again on a copy
    /// only root can change, so nothing can swap the staged app between the check above and the install.
    private nonisolated static func installAsAdministrator(_ staged: URL, over app: URL) throws {
        let script = #"""
            set -e
            app="$1"; staged="$2"; requirement="$3"
            new="$(dirname "$app")/.$(basename "$app").new"; old="$(dirname "$app")/.$(basename "$app").old"
            rm -rf "$new" "$old"
            trap 'rm -rf "$new"' EXIT
            /usr/bin/ditto "$staged" "$new"
            /usr/sbin/chown -R root:admin "$new"
            /usr/bin/codesign --verify --deep --strict -R "=$requirement" "$new"
            mv "$app" "$old"
            mv "$new" "$app"
            rm -rf "$old"
            /bin/chmod -R g+w "$app"
            """#
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", #"do shell script "/bin/sh -c " & quoted form of item 1 of argv & " sh " & quoted form of item 2 of argv & " " & quoted form of item 3 of argv & " " & quoted form of item 4 of argv with administrator privileges"#,
            "-e", "end run",
            script, app.path, staged.path, appRequirement,
        ]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        if message.contains("-128") { throw InstallError("the administrator password was cancelled.") }
        throw InstallError("installing as an administrator failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
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
