import AppKit
import CryptoKit
import Darwin
import PoemCore
import Security
import ServiceManagement

@MainActor
final class AppUpdater {
    var busyHandler: ((Bool) -> Void)?
    var statusHandler: ((String) -> Void)?
    private(set) var isBusy = false
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let lastCheckKey = "PoemDesktopLastUpdateCheck"
    private let interval: TimeInterval = 24 * 60 * 60
    private let policy = UpdateDownloadPolicy()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: policy, delegateQueue: nil)
    }()

    func start() {
        guard timer == nil else { return }
        let elapsed = Date().timeIntervalSince(defaults.object(forKey: lastCheckKey) as? Date ?? .distantPast)
        if elapsed >= interval { check(manual: false) }
        scheduleCheck()
    }

    func checkManually() { check(manual: true) }

    private func scheduleCheck() {
        timer?.invalidate()
        let elapsed = Date().timeIntervalSince(defaults.object(forKey: lastCheckKey) as? Date ?? Date())
        timer = Timer.scheduledTimer(withTimeInterval: max(60, interval - max(0, elapsed)), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.check(manual: false) }
        }
        timer?.tolerance = 60
    }

    private func check(manual: Bool) {
        guard !isBusy else { return }
        isBusy = true
        busyHandler?(true)
        statusHandler?("Checking for app updates…")
        defaults.set(Date(), forKey: lastCheckKey)
        scheduleCheck()
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.busyHandler?(false); self.task = nil }
            do {
                var request = URLRequest(url: ReleaseUpdate.endpoint)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("PoemDesktop/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
                request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                let (data, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.url == ReleaseUpdate.endpoint else {
                    throw ReleaseUpdateError.invalid("The update server returned an unexpected address.")
                }
                guard http.statusCode == 200 else {
                    throw ReleaseUpdateError.invalid("GitHub returned HTTP \(http.statusCode) while checking for updates.")
                }
                let release = try ReleaseUpdate(data: data)
                let current = try ReleaseVersion(Self.currentVersion)
                guard release.version > current else {
                    self.statusHandler?("Poem Desktop \(Self.currentVersion) is up to date.")
                    if manual { self.alert(title: "Poem Desktop is up to date", message: "You’re running version \(Self.currentVersion).") }
                    return
                }
                self.statusHandler?("Downloading Poem Desktop \(release.version)…")
                var download = URLRequest(url: release.downloadURL)
                download.setValue("PoemDesktop/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
                let (file, downloadResponse) = try await self.session.download(for: download)
                guard let downloadHTTP = downloadResponse as? HTTPURLResponse, downloadHTTP.statusCode == 200,
                      let finalURL = downloadHTTP.url, ReleaseUpdate.isAllowedDownloadURL(finalURL) else {
                    throw ReleaseUpdateError.invalid("GitHub returned an invalid app download.")
                }
                self.statusHandler?("Verifying the signed update…")
                let currentURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
                let currentVersion = Self.currentVersion
                let prepared = try await Task.detached(priority: .utility) {
                    try Self.prepare(download: file, release: release, currentURL: currentURL, currentVersion: currentVersion)
                }.value
                try self.launchInstaller(prepared, release: release)
            } catch {
                self.statusHandler?("App update failed: \(error.localizedDescription)")
                NSLog("Poem Desktop updater: %@", error.localizedDescription)
                if manual { self.alert(title: "Poem Desktop could not update", message: error.localizedDescription) }
            }
        }
    }

    private func alert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static let identifier = "local.poemdesktop.app"
    private static let team = "VSVHNQP588"
    private nonisolated static var signingRequirement: String {
        "anchor apple generic and identifier \"local.poemdesktop.app\" and " +
        "certificate 1[field.1.2.840.113635.100.6.2.6] exists and " +
        "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and " +
        "certificate leaf[subject.OU] = \"VSVHNQP588\""
    }

    /// Read and authenticate a candidate without executing it. A version override
    /// supports release QA against an older baseline; it also disables the local build comparison.
    nonisolated static func validateCandidate(at url: URL, expectedTag: String,
                                             currentVersion: String? = nil) throws -> String {
        let expected = try ReleaseVersion(expectedTag)
        let current = try ReleaseVersion(currentVersion ?? Self.currentVersion)
        guard expected > current else { throw ReleaseUpdateError.invalid("The update is not newer than the installed app.") }
        let app = url.standardizedFileURL
        let info = try readInfo(app)
        guard app.pathExtension == "app", app == app.resolvingSymlinksInPath(),
              info["CFBundleIdentifier"] as? String == "local.poemdesktop.app",
              info["CFBundleShortVersionString"] as? String == expected.description,
              let build = info["CFBundleVersion"] as? String,
              let buildNumber = UInt(build), buildNumber > 0,
              info["CFBundleExecutable"] as? String == "PoemDesktop",
              info["CFBundlePackageType"] as? String == "APPL" else {
            throw ReleaseUpdateError.invalid("The downloaded app’s identity, version, or build does not match the release.")
        }
        if currentVersion == nil,
           let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           let currentBuildNumber = UInt(currentBuild), buildNumber <= currentBuildNumber {
            throw ReleaseUpdateError.invalid("The update build must be newer than the installed build.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw ReleaseUpdateError.invalid("The downloaded app has no readable code signature.")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(signingRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw ReleaseUpdateError.invalid("The app signing requirement could not be created.") }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures |
            kSecCSCheckNestedCode | kSecCSRestrictSymlinks)
        var signatureError: Unmanaged<CFError>?
        let result = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &signatureError)
        guard result == errSecSuccess else {
            let detail = signatureError?.takeRetainedValue().localizedDescription ?? "Security status \(result)"
            throw ReleaseUpdateError.invalid("The update must have a valid Apple Developer ID signature from team VSVHNQP588 in every architecture. \(detail)")
        }
        return "VALID UPDATE: \(expected.description) (\(build)); local.poemdesktop.app; Developer ID team VSVHNQP588; all architectures and sealed resources verified."
    }

    private struct Prepared: Sendable {
        let transaction: URL
        let candidate: URL
        let current: URL
        let currentVersion: String
    }

    private nonisolated static func prepare(download: URL, release: ReleaseUpdate, currentURL: URL,
                                            currentVersion: String) throws -> Prepared {
        let fm = FileManager.default
        guard currentURL.pathExtension == "app", try readInfo(currentURL)["CFBundleIdentifier"] as? String == "local.poemdesktop.app",
              fm.isWritableFile(atPath: currentURL.deletingLastPathComponent().path) else {
            throw ReleaseUpdateError.invalid("Move Poem Desktop to a writable Applications folder before updating it.")
        }
        let transaction = currentURL.deletingLastPathComponent()
            .appendingPathComponent(".poemdesktop-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: transaction, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? fm.removeItem(at: transaction) } }
        let archive = transaction.appendingPathComponent(ReleaseUpdate.assetName)
        try fm.moveItem(at: download, to: archive)
        let fileSize = (try fm.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue
        guard fileSize == release.size else { throw ReleaseUpdateError.invalid("The archive size does not match GitHub’s release metadata.") }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        if let expectedDigest = release.sha256 {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expectedDigest else { throw ReleaseUpdateError.invalid("The downloaded archive failed its SHA-256 check.") }
        }
        try UpdateArchiveValidator.validate(data)
        let unpacked = transaction.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: false)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let source = unpacked.appendingPathComponent(ReleaseUpdate.appName, isDirectory: true)
        let candidate = transaction.appendingPathComponent(ReleaseUpdate.appName, isDirectory: true)
        try fm.moveItem(at: source, to: candidate)
        // The archive format is deliberately symlink-free. Check the extracted tree too.
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard let entries = fm.enumerator(at: candidate, includingPropertiesForKeys: keys) else {
            throw ReleaseUpdateError.invalid("The extracted update could not be inspected.")
        }
        for case let entry as URL in entries {
            if try entry.resourceValues(forKeys: Set(keys)).isSymbolicLink == true {
                throw ReleaseUpdateError.invalid("The update contains an unexpected symbolic link.")
            }
        }
        _ = try validateCandidate(at: candidate, expectedTag: release.tag)
        completed = true
        return Prepared(transaction: transaction, candidate: candidate, current: currentURL, currentVersion: currentVersion)
    }

    private struct Transaction: Codable {
        let currentPath: String
        let version: String
        let previousVersion: String
        let previousPID: Int32
        let previousExecutableDigest: String
        let nonce: String
        let loginEnabled: Bool
    }

    private func launchInstaller(_ prepared: Prepared, release: ReleaseUpdate) throws {
        let fm = FileManager.default
        do {
            let config = Transaction(currentPath: prepared.current.path, version: release.version.description,
                                     previousVersion: prepared.currentVersion,
                                     previousPID: ProcessInfo.processInfo.processIdentifier,
                                     previousExecutableDigest: try Self.executableDigest(prepared.current),
                                     nonce: UUID().uuidString, loginEnabled: SMAppService.mainApp.status == .enabled)
            let request = prepared.transaction.appendingPathComponent("request.json")
            try JSONEncoder().encode(config).write(to: request, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
            // Keep the complete signed bundle: a detached app executable loses
            // access to its sealed Info.plist and is rejected by macOS at launch.
            let helperBundle = prepared.transaction.appendingPathComponent("Updater Helper.app", isDirectory: true)
            try fm.copyItem(at: prepared.current, to: helperBundle)
            let helper = helperBundle.appendingPathComponent("Contents/MacOS/PoemDesktop")
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--update-helper", prepared.transaction.path]
            process.standardInput = FileHandle.nullDevice
            let log = prepared.transaction.appendingPathComponent("installer.log")
            fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: log)
            process.standardOutput = output
            process.standardError = output
            try process.run()
            statusHandler?("Installing Poem Desktop \(release.version)…")
            NSApp.terminate(nil)
        } catch {
            try? fm.removeItem(at: prepared.transaction)
            throw error
        }
    }

    /// Called before NSApplication is created. This process is a copy of the old
    /// executable and survives the atomic bundle exchange without running new code.
    static func runHelperIfRequested(_ arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: "--update-helper") else { return false }
        var recovery: Transaction?
        var exchanged = false
        var handledRelaunch = false
        do {
            guard arguments.count == index + 2 else { throw ReleaseUpdateError.invalid("Invalid updater helper arguments.") }
            let transaction = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
            let config = try readTransaction(transaction)
            let current = URL(fileURLWithPath: config.currentPath, isDirectory: true)
            let candidate = transaction.appendingPathComponent(ReleaseUpdate.appName, isDirectory: true)
            let info = try readInfo(current)
            guard current.deletingLastPathComponent() == transaction.deletingLastPathComponent(),
                  info["CFBundleIdentifier"] as? String == "local.poemdesktop.app",
                  info["CFBundleShortVersionString"] as? String == config.previousVersion,
                  try executableDigest(current) == config.previousExecutableDigest else {
                throw ReleaseUpdateError.invalid("The installed app changed before the update was applied.")
            }
            recovery = config
            let deadline = Date().addingTimeInterval(60)
            while kill(config.previousPID, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            guard kill(config.previousPID, 0) != 0 else { throw ReleaseUpdateError.invalid("The app did not quit in time to update.") }
            _ = try validateCandidate(at: candidate, expectedTag: config.version, currentVersion: config.previousVersion)
            try exchange(candidate, current)
            exchanged = true
            do {
                // Reauthenticate at its final path immediately before it may execute.
                _ = try validateCandidate(at: current, expectedTag: config.version, currentVersion: config.previousVersion)
                var launch = ["-g", "-n", current.path, "--args", "--update-transaction", transaction.path, "--update-token", config.nonce]
                if config.loginEnabled { launch.append("--enable-login") }
                try run("/usr/bin/open", launch)
                let receipt = transaction.appendingPathComponent("launch-receipt")
                let launchDeadline = Date().addingTimeInterval(30)
                var acknowledged = false
                while Date() < launchDeadline {
                    if (try? String(contentsOf: receipt, encoding: .utf8)) == config.nonce { acknowledged = true; break }
                    Thread.sleep(forTimeInterval: 0.25)
                }
                guard acknowledged else { throw ReleaseUpdateError.invalid("The updated app did not finish starting; restoring the previous version.") }
                try? FileManager.default.removeItem(at: transaction)
                print("Update installed and relaunch acknowledged.")
            } catch {
                // Avoid letting a failed new process continue after restoring the old app.
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: "local.poemdesktop.app")
                    where app.bundleURL?.standardizedFileURL == current.standardizedFileURL {
                    _ = app.forceTerminate()
                }
                try exchange(candidate, current)
                exchanged = false
                var launch = ["-g", "-n", current.path]
                if config.loginEnabled { launch += ["--args", "--enable-login"] }
                try? run("/usr/bin/open", launch)
                handledRelaunch = true
                // Keep the failed candidate and installer log for diagnosis, rather than deleting the backup before success.
                throw error
            }
        } catch {
            // A validation or swap error can occur after the old process has quit.
            // Restore service by reopening only the unchanged executable we started from.
            if !exchanged, !handledRelaunch, let config = recovery, kill(config.previousPID, 0) != 0 {
                let current = URL(fileURLWithPath: config.currentPath)
                if (try? executableDigest(current)) == config.previousExecutableDigest,
                   (try? readInfo(current)["CFBundleIdentifier"] as? String) == "local.poemdesktop.app" {
                    var launch = ["-g", "-n", current.path]
                    if config.loginEnabled { launch += ["--args", "--enable-login"] }
                    try? run("/usr/bin/open", launch)
                }
            }
            fputs("Poem Desktop updater failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        return true
    }

    /// Call after normal app initialization. The helper only commits cleanup once
    /// the newly signed app has reached this point successfully.
    static func acknowledgeSuccessfulRelaunch(arguments: [String]) {
        guard let pathIndex = arguments.firstIndex(of: "--update-transaction"), arguments.count > pathIndex + 1,
              let tokenIndex = arguments.firstIndex(of: "--update-token"), arguments.count > tokenIndex + 1 else { return }
        do {
            let directory = URL(fileURLWithPath: arguments[pathIndex + 1], isDirectory: true).standardizedFileURL
            let config = try readTransaction(directory)
            guard config.nonce == arguments[tokenIndex + 1], config.version == currentVersion,
                  config.currentPath == Bundle.main.bundleURL.resolvingSymlinksInPath().path else { return }
            if config.loginEnabled, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
            try config.nonce.write(to: directory.appendingPathComponent("launch-receipt"), atomically: true, encoding: .utf8)
        } catch { NSLog("Poem Desktop update acknowledgment failed: %@", error.localizedDescription) }
    }

    private nonisolated static func readTransaction(_ directory: URL) throws -> Transaction {
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard directory.lastPathComponent.hasPrefix(".poemdesktop-update-"),
              directory == directory.resolvingSymlinksInPath(),
              attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
            throw ReleaseUpdateError.invalid("The update transaction directory is not private or valid.")
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("request.json"))
        guard data.count < 16_384 else { throw ReleaseUpdateError.invalid("Invalid update transaction.") }
        let config = try JSONDecoder().decode(Transaction.self, from: data)
        guard config.previousPID > 1, UUID(uuidString: config.nonce) != nil else {
            throw ReleaseUpdateError.invalid("Invalid update transaction identity.")
        }
        return config
    }

    private nonisolated static func readInfo(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard data.count < 1_048_576,
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ReleaseUpdateError.invalid("The app’s Info.plist is invalid.")
        }
        return info
    }

    private nonisolated static func executableDigest(_ app: URL) throws -> String {
        let bytes = try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/PoemDesktop"), options: .mappedIfSafe)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func exchange(_ first: URL, _ second: URL) throws {
        guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ReleaseUpdateError.invalid("\(URL(fileURLWithPath: executable).lastPathComponent) failed with status \(process.terminationStatus).")
        }
    }
}

private final class UpdateDownloadPolicy: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, task.originalRequest?.url != ReleaseUpdate.endpoint,
              ReleaseUpdate.isAllowedDownloadURL(url) else { completionHandler(nil); return }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > ReleaseUpdate.maximumArchiveSize || totalBytesExpectedToWrite > ReleaseUpdate.maximumArchiveSize {
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
