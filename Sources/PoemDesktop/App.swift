import AppKit
import CoreGraphics
import ServiceManagement
import PoemCore

@MainActor
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        title = "Poem Desktop Overlay"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        setAccessibilityElement(false)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var overlay: DesktopWindow?
    private(set) var poemView: PoemView?
    private var settingsWindow: NSWindow?
    private var reader: PoemReader?
    private var statusLabel: NSTextField?
    private var loginButton: NSButton?
    private var visibilityButton: NSButton?
    private var updateButton: NSButton?
    private var updateLabel: NSTextField?
    private var typographyPreview: TypographyPreview?
    private lazy var updater = AppUpdater()
    private var refreshTimer: Timer?
    private var retryTimer: Timer?
    private var failureCount = 0
    private var fetchTask: Task<Void, Never>?
    private var lastAttempt: Date?
    private var observers: [NSObjectProtocol] = []
    private var latestPoem: Poem?
    private var isHidden = false
    private var status = "Checking for the latest poem…"
    private var loginIssue: String?
    private let defaults = UserDefaults.standard
    private static let textSizes: [(title: String, scale: Double)] = [
        ("Smallest", 0.7), ("Smaller", 0.85), ("Comfortable", 1),
        ("Larger", 1.15), ("Largest", 1.3)
    ]
    private let typefaces = PoemTypeface.available
    private var selectedTypeface: PoemTypeface {
        let saved = PoemTypeface(rawValue: defaults.string(forKey: "typeface") ?? "") ?? .georgia
        return typefaces.contains(saved) ? saved : (typefaces.first ?? .georgia)
    }
    private let args = ProcessInfo.processInfo.arguments
    private lazy var service = PoemService(cacheDirectory: Self.supportDirectory)

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Poem Desktop", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let index = args.firstIndex(of: "--validate-update"), args.indices.contains(index + 1),
           let tagIndex = args.firstIndex(of: "--expected-tag"), args.indices.contains(tagIndex + 1) {
            do {
                print(try AppUpdater.validateCandidate(at: URL(fileURLWithPath: args[index + 1]),
                    expectedTag: args[tagIndex + 1], currentVersion: "0.0.0"))
                NSApp.terminate(nil)
            } catch {
                fputs("UPDATE VALIDATION FAILED: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if args.contains("--status") {
            print("Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown"))")
            print("Login item status: \(SMAppService.mainApp.status.rawValue) (1 = enabled)")
            let instances = NSRunningApplication.runningApplications(withBundleIdentifier: "local.poemdesktop.app")
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            print("Running instances: \(instances.count)")
            print("Cached poem available: \(service.loadCached() != nil)")
            NSApp.terminate(nil)
            return
        }
        if args.contains("--quit-existing") {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("local.poemdesktop.quit"), object: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        if !args.contains("--smoke-test") && !args.contains("--fetch-test") && !args.contains("--audit-archive") &&
            NSRunningApplication.runningApplications(withBundleIdentifier: "local.poemdesktop.app")
                .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("local.poemdesktop.settings"), object: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        if args.contains("--fetch-test") {
            runFetchTest()
            return
        }
        if args.contains("--audit-archive") {
            ArchiveAudit.run(arguments: args)
            return
        }
        latestPoem = service.loadCached()
        rebuildOverlay()
        if args.contains("--smoke-test") {
            Task { @MainActor in await SmokeTest.run(delegate: self, arguments: args) }
            return
        }
        installObservers()
        // Low frequency polling catches the site's afternoon posts as well as a new workday.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
        refreshTimer?.tolerance = 60
        if args.contains("--enable-login") { setLoginEnabled(true) }
        updater.busyHandler = { [weak self] busy in
            self?.updateButton?.isEnabled = !busy
            self?.updateButton?.title = busy ? "Checking for updates…" : "Check for updates"
        }
        updater.statusHandler = { [weak self] status in self?.updateLabel?.stringValue = status }
        updater.start()
        refresh(force: true)
        if args.contains("--settings") { showSettings() }
        if args.contains("--check-updates") { updater.checkManually() }
        AppUpdater.acknowledgeSuccessfulRelaunch(arguments: args)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        fetchTask?.cancel()
        refreshTimer?.invalidate()
        retryTimer?.invalidate()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildOverlay() }
        })
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.refresh(force: false)
                    }
                })
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(showSettings),
                                name: NSNotification.Name("local.poemdesktop.settings"), object: nil)
        distributed.addObserver(self, selector: #selector(quit),
                                name: NSNotification.Name("local.poemdesktop.quit"), object: nil)
    }

    func rebuildOverlay() {
        // screens.first is the menu-bar display; NSScreen.main follows the focused window.
        guard let screen = NSScreen.screens.first else { return }
        let fontScale = CGFloat(defaults.object(forKey: "fontScale") as? Double ?? 1)
        let typeface = selectedTypeface
        let frame = Self.overlayFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                      poem: latestPoem, fontScale: fontScale, typeface: typeface)
        let window = overlay ?? DesktopWindow(frame: frame)
        let view = poemView ?? PoemView(frame: NSRect(origin: .zero, size: frame.size))
        window.setFrame(frame, display: false)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.fontScale = fontScale
        view.typeface = typeface
        view.usesReadingVeil = defaults.bool(forKey: "readingVeil")
        view.poem = latestPoem
        window.contentView = view
        overlay = window
        poemView = view
        if !isHidden { window.orderFrontRegardless() }
    }

    static func overlayFrame(screenFrame: NSRect, visibleFrame: NSRect,
                             poem: Poem? = nil, fontScale: CGFloat = 1,
                             typeface: PoemTypeface = .georgia) -> NSRect {
        let width = min(1700, screenFrame.width - 112)
        let top = min(screenFrame.maxY - 36, visibleFrame.maxY - 14)
        let targetHeight = max(130, top - (screenFrame.maxY - screenFrame.height / 3))
        let maximumHeight = max(targetHeight, top - max(screenFrame.minY + 40, visibleFrame.minY + 20))
        let height = PoemView.preferredHeight(for: poem, width: width, targetHeight: targetHeight,
                                             maximumHeight: maximumHeight, fontScale: fontScale, typeface: typeface)
        return NSRect(x: screenFrame.midX - width / 2, y: top - height, width: width, height: height)
    }

    func setPoem(_ poem: Poem) {
        if latestPoem != poem {
            latestPoem = poem
            rebuildOverlay()
        }
    }

    func refresh(force: Bool) {
        guard fetchTask == nil else { return }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 60 { return }
        lastAttempt = Date()
        retryTimer?.invalidate()
        retryTimer = nil
        status = "Checking for the latest poem…"
        updateStatus()
        fetchTask = Task { [weak self] in
            guard let self else { return }
            defer { self.fetchTask = nil }
            do {
                let poem = try await self.service.fetchLatest()
                guard !Task.isCancelled else { return }
                self.setPoem(poem)
                self.failureCount = 0
                self.status = "Up to date · Published \(poem.publishedAt.formatted(date: .abbreviated, time: .omitted))"
            } catch {
                self.status = self.latestPoem == nil
                    ? "The poem couldn’t be reached. It will retry automatically."
                    : "Offline · Keeping your last poem. It will retry automatically."
                NSLog("Poem Desktop refresh: %@", error.localizedDescription)
                self.failureCount += 1
                let delay = min(300.0, 15.0 * pow(2.0, Double(min(self.failureCount - 1, 5))))
                self.retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.refresh(force: true) }
                }
            }
            self.updateStatus()
        }
    }

    @objc func showSettings() {
        if settingsWindow == nil { makeSettingsWindow() }
        updateStatus()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeSettingsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Poem Desktop"
        window.isReleasedWhenClosed = false
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: "A poem for your workday.")
        heading.font = NSFont(name: "Georgia", size: 27)
        stack.addArrangedSubview(heading)
        let intro = NSTextField(wrappingLabelWithString: "The latest poem from A Poem A Day, quietly on your desktop. Open this app again whenever you want these controls.")
        intro.font = .systemFont(ofSize: 13)
        intro.textColor = .secondaryLabelColor
        stack.addArrangedSubview(intro)
        let statusField = NSTextField(wrappingLabelWithString: status)
        statusField.font = .systemFont(ofSize: 12)
        statusLabel = statusField
        stack.addArrangedSubview(statusField)

        let login = NSButton(checkboxWithTitle: "Start automatically when I log in", target: self, action: #selector(toggleLogin(_:)))
        loginButton = login
        stack.addArrangedSubview(login)
        let veil = NSButton(checkboxWithTitle: "Soft paper backing for a busy wallpaper", target: self, action: #selector(toggleVeil(_:)))
        veil.state = defaults.bool(forKey: "readingVeil") ? .on : .off
        stack.addArrangedSubview(veil)

        let sizeRow = NSStackView()
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 16
        sizeRow.addArrangedSubview(NSTextField(labelWithString: "Text size"))
        let size = NSPopUpButton()
        size.setAccessibilityLabel("Text size")
        size.addItems(withTitles: Self.textSizes.map(\.title))
        let savedScale = defaults.object(forKey: "fontScale") as? Double ?? 1
        let scale = savedScale.isFinite ? savedScale : 1
        let selected = Self.textSizes.indices.min {
            abs(Self.textSizes[$0].scale - scale) < abs(Self.textSizes[$1].scale - scale)
        } ?? 2
        size.selectItem(at: selected)
        size.target = self
        size.action = #selector(changeSize(_:))
        sizeRow.addArrangedSubview(size)
        stack.addArrangedSubview(sizeRow)

        let typefaceRow = NSStackView()
        typefaceRow.orientation = .horizontal
        typefaceRow.spacing = 16
        typefaceRow.addArrangedSubview(NSTextField(labelWithString: "Typeface"))
        let typeface = NSPopUpButton()
        typeface.setAccessibilityLabel("Typeface")
        for choice in typefaces {
            typeface.addItem(withTitle: choice.displayName)
            typeface.lastItem?.attributedTitle = NSAttributedString(
                string: choice.displayName, attributes: [.font: choice.font(size: 15)])
        }
        typeface.selectItem(at: typefaces.firstIndex(of: selectedTypeface) ?? 0)
        typeface.target = self
        typeface.action = #selector(changeTypeface(_:))
        typefaceRow.addArrangedSubview(typeface)
        stack.addArrangedSubview(typefaceRow)

        let preview = TypographyPreview(frame: .zero)
        preview.translatesAutoresizingMaskIntoConstraints = false
        typographyPreview = preview
        stack.addArrangedSubview(preview)
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(equalToConstant: 82)
        ])
        updateTypographyPreview()

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        for (title, action) in [("Refresh", #selector(refreshNow)), ("Read larger", #selector(openReader)),
                                ("Read on the site", #selector(openSource))] {
            actions.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(actions)
        let updates = NSStackView()
        updates.orientation = .horizontal
        updates.spacing = 10
        let update = NSButton(title: "Check for updates", target: self, action: #selector(checkForUpdates))
        updateButton = update
        updates.addArrangedSubview(update)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let updateStatus = NSTextField(wrappingLabelWithString: "Version \(version) · Updates automatically")
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.textColor = .secondaryLabelColor
        updateLabel = updateStatus
        updates.addArrangedSubview(updateStatus)
        stack.addArrangedSubview(updates)
        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.spacing = 10
        let visibility = NSButton(title: "Hide poem", target: self, action: #selector(toggleVisibility))
        visibilityButton = visibility
        bottom.addArrangedSubview(visibility)
        bottom.addArrangedSubview(NSButton(title: "Quit", target: self, action: #selector(quit)))
        stack.addArrangedSubview(bottom)
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
        settingsWindow = window
    }

    private func updateStatus() {
        let readingNote = poemView?.needsLargerReadingView == true
            ? "Long poem: the full desktop version uses smaller type. Choose Read larger for comfortable reading."
            : nil
        statusLabel?.stringValue = [status, loginIssue, readingNote].compactMap { $0 }.joined(separator: "\n")
        let loginStatus = SMAppService.mainApp.status
        loginButton?.state = loginStatus == .enabled ? .on : .off
        loginButton?.title = loginStatus == .requiresApproval
            ? "Allow startup in System Settings…" : "Start automatically when I log in"
        visibilityButton?.title = isHidden ? "Show poem" : "Hide poem"
    }

    private func setLoginEnabled(_ enabled: Bool) {
        loginIssue = nil
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    loginIssue = "Allow Poem Desktop in System Settings → General → Login Items."
                }
            } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginIssue = "Couldn’t change startup: \(error.localizedDescription)"
        }
        updateStatus()
        NSLog("Poem Desktop login item status: %ld", SMAppService.mainApp.status.rawValue)
        if loginIssue != nil { showSettings() }
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        } else { setLoginEnabled(sender.state == .on) }
    }
    @objc private func toggleVeil(_ sender: NSButton) {
        let enabled = sender.state == .on
        defaults.set(enabled, forKey: "readingVeil")
        poemView?.usesReadingVeil = enabled
    }
    @objc private func changeSize(_ sender: NSPopUpButton) {
        guard Self.textSizes.indices.contains(sender.indexOfSelectedItem) else { return }
        let scale = Self.textSizes[sender.indexOfSelectedItem].scale
        defaults.set(scale, forKey: "fontScale")
        rebuildOverlay()
        updateTypographyPreview()
        updateStatus()
    }
    @objc private func changeTypeface(_ sender: NSPopUpButton) {
        guard typefaces.indices.contains(sender.indexOfSelectedItem) else { return }
        defaults.set(typefaces[sender.indexOfSelectedItem].rawValue, forKey: "typeface")
        rebuildOverlay()
        updateTypographyPreview()
        if let poem = latestPoem { reader?.prepare(poem, typeface: selectedTypeface) }
        updateStatus()
    }
    private func updateTypographyPreview() {
        let scale = CGFloat(defaults.object(forKey: "fontScale") as? Double ?? 1)
        typographyPreview?.configure(typeface: selectedTypeface, fontSize: PoemView.preferredFontSize(scale))
    }
    @objc private func refreshNow() { refresh(force: true) }
    @objc private func checkForUpdates() { updater.checkManually() }
    @objc private func openReader() {
        guard let poem = latestPoem else { return }
        if reader == nil { reader = PoemReader() }
        reader?.show(poem, typeface: selectedTypeface)
    }
    @objc private func openSource() {
        NSWorkspace.shared.open(latestPoem?.url ?? URL(string: "https://apoemaday.tumblr.com/")!)
    }
    @objc private func toggleVisibility() {
        isHidden.toggle()
        if isHidden { overlay?.orderOut(nil) } else { overlay?.orderFrontRegardless() }
        updateStatus()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func runFetchTest() {
        Task {
            do {
                let poem = try await service.fetchLatest()
                guard service.loadCached() == poem else { throw CocoaError(.fileReadCorruptFile) }
                print("LIVE FETCH PASS: \(poem.title) — \(poem.author); \(poem.body.count) characters; cache round trip passed")
                NSApp.terminate(nil)
            } catch {
                fputs("LIVE FETCH FAILED: \(error)\n", stderr)
                exit(1)
            }
        }
    }
}

@main
struct PoemDesktopApp {
    @MainActor static func main() {
        let arguments = ProcessInfo.processInfo.arguments
        if AppUpdater.runHelperIfRequested(arguments) { return }
        if let index = arguments.firstIndex(of: "--validate-update-archive"), arguments.indices.contains(index + 1) {
            do {
                try UpdateArchiveValidator.validate(Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])))
                print("UPDATE ARCHIVE VALIDATION PASS")
                return
            } catch {
                fputs("UPDATE ARCHIVE VALIDATION FAILED: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
