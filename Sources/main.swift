import AppKit
import SwiftUI
import Darwin
import UserNotifications
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    private var status: NSStatusItem!
    private let model = BeaconModel()
    private let popover = NSPopover()
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private var tracker = AlertTracker()
    private var activeDisks: Set<String> = []
    private var baselineAlerts = true
    private var cleanupWindow: NSWindow?
    private let cleanupModel = CleanupModel()
    private let hub = StorageHubModel()
    private var lastRecommendationScan: Date?
    private var journalHealthy = true
    private var hubObservation: AnyCancellable?
    private var moveStore: MoveStore { MoveStore(url: FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().appendingPathComponent("Library/Application Support/Heimdall/moves.json")) }
    private var cleanupCancellation: CleanupCancellation?
    private var cleanupGeneration = UUID()
    private var updateSession: URLSession?

    private var loginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/io.github.theedward.heimdall.plist")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["warningGB": 60, "criticalGB": 25])
        if let saved = defaults.data(forKey: "alertTracker"),let restored = try? JSONDecoder().decode(AlertTracker.self,from: saved) { tracker = restored }
        model.selectedID = defaults.string(forKey: "selectedDiskID") ?? "internal"
        model.selectedName = defaults.string(forKey: "selectedDiskName") ?? "Internal disk"
        model.alerts = defaults.bool(forKey: "alertsEnabled")
        UNUserNotificationCenter.current().delegate = self
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.target = self
        status.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 615)
        model.refreshAction = { [weak self] in self?.refresh(); self?.scanCleanup() }
        model.presetAction = { [weak self] warn, crit in
            self?.defaults.set(warn, forKey: "warningGB")
            self?.defaults.set(crit, forKey: "criticalGB")
            self?.baselineAlerts = true
            self?.refresh()
        }
        model.loginAction = { [weak self] in self?.toggleLogin() }
        model.storageAction = { [weak self] in
            guard let self else { return }
            if self.model.selectedID == "internal" { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!) }
            else if let target = self.model.targets.first(where: { $0.id == self.model.selectedID }) { NSWorkspace.shared.open(URL(fileURLWithPath: target.path)) }
        }
        model.selectAction = { [weak self] id in
            guard let self,let target = self.model.targets.first(where: { $0.id == id }) else { return }
            self.model.selectedID = id; self.model.selectedName = target.name
            self.defaults.set(id,forKey: "selectedDiskID"); self.defaults.set(target.name,forKey: "selectedDiskName")
            self.refresh()
        }
        model.alertAction = { [weak self] enabled in self?.configureAlerts(enabled) }
        model.testAlertAction = { [weak self] in self?.configureAlerts(true,test: true) }
        model.updateAction = { [weak self] in self?.checkUpdates() }
        model.openReleaseAction = { [weak self] in if let url = self?.model.releaseURL { NSWorkspace.shared.open(url) } }
        configureStorageHub()
        model.freeSpaceAction = { [weak self] in self?.freeUpSpace() }
        model.cleanupAction = { [weak self] in self?.showCleanup() }
        model.quitAction = { [weak self] in if self?.model.cleaning != true && self?.hub.busy != true { NSApplication.shared.terminate(nil) } }
        let panelHeight = min(CGFloat(850),(NSScreen.main?.visibleFrame.height ?? 900) - 80)
        let hosting = NSHostingController(rootView: ScrollView { BeaconPanel(model: model) }.frame(width: 360,height: panelHeight))
        popover.contentViewController = hosting
        hosting.view.layoutSubtreeIfNeeded()
        let height = hosting.view.fittingSize.height
        if height > 0 { popover.contentSize = NSSize(width: 360,height: ceil(height)) }
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.scanCleanup() }
        syncNotificationPermission()
        if defaults.object(forKey: "alertsEnabled") == nil { configureAlerts(true) }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        for name in [NSWorkspace.didMountNotification,NSWorkspace.didUnmountNotification,NSWorkspace.didRenameVolumeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self,selector: #selector(refresh),name: name,object: nil)
        }
    }
    @objc private func togglePanel() {
        guard let button = status.button else { return }
        if popover.isShown { popover.performClose(nil) } else {
            refresh()
            if lastRecommendationScan == nil || Date().timeIntervalSince(lastRecommendationScan!) > 900 { scanCleanup() }
            syncNotificationPermission()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    @objc private func refresh() {
        model.warning = defaults.integer(forKey: "warningGB")
        model.critical = defaults.integer(forKey: "criticalGB")
        model.login = FileManager.default.fileExists(atPath: loginURL.path)
        model.targets = DiskTarget.available()
        let present = Set(model.targets.map(\.id))
        for target in model.targets {
            guard let reading = try? DiskReading.read(path: target.path) else { continue }
            let level = tracker.sample(id: target.id,freeGB: Double(reading.free) / 1e9,warning: model.warning,critical: model.critical,baseline: baselineAlerts || !activeDisks.contains(target.id) || !model.alerts)
            if model.alerts,let level { sendAlert(target: target,reading: reading,level: level) }
        }
        let mountsChanged = !activeDisks.isEmpty && activeDisks != present
        activeDisks = present; baselineAlerts = false
        if !hub.busy && !cleanupModel.busy && (mountsChanged || lastRecommendationScan.map { Date().timeIntervalSince($0) > 900 } == true) { scanCleanup() }
        if let saved = try? JSONEncoder().encode(tracker) { defaults.set(saved,forKey: "alertTracker") }
        model.disconnected = !present.contains(model.selectedID)
        do {
            guard let target = model.targets.first(where: { $0.id == model.selectedID }) else { throw URLError(.resourceUnavailable) }
            let disk = try DiskReading.read(path: target.path)
            model.selectedName = target.name
            model.disk = disk; model.updated = Date(); model.error = false
            let freeGB = Double(disk.free) / 1e9
            let color: NSColor = freeGB < Double(model.critical) ? .systemRed : freeGB < Double(model.warning) ? .systemOrange : .labelColor
            let percent = Int((disk.fraction * 100).rounded())
            status.button?.attributedTitle = NSAttributedString(
                string: "\(percent)% · \(Int(freeGB.rounded(.down))) GB",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: color]
            )
            status.button?.image = nil
            status.button?.toolTip = "\(model.selectedName): \(percent)% occupied, \(String(format: "%.1f", freeGB)) GB free · \(model.state)"
            status.button?.setAccessibilityLabel(status.button?.toolTip)
        } catch {
            model.error = true; model.disk = nil
            status.button?.attributedTitle = NSAttributedString(
                string: model.disconnected ? "Disk offline" : "Disk ?", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
            )
            status.button?.image = nil
            status.button?.toolTip = model.disconnected ? "\(model.selectedName) is disconnected" : "Unable to read disk usage"
        }
    }
    private func syncNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.alertNote = settings.authorizationStatus == .denied ? "Blocked in macOS Notifications settings" : ""
                if settings.authorizationStatus == .denied { self.model.alerts = false; self.defaults.set(false,forKey: "alertsEnabled") }
                self.syncCleanupSettings()
            }
        }
    }
    private func configureAlerts(_ enabled: Bool,test: Bool = false) {
        defaults.set(false,forKey: "alertsEnabled"); model.alerts = false
        baselineAlerts = true
        guard enabled else { refresh(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted,error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.alerts = granted; self.defaults.set(granted,forKey: "alertsEnabled")
                self.model.alertNote = error != nil ? "Couldn’t request notification permission. Try again." : granted ? "" : "Allow Heimdall in macOS Notifications settings"
                self.baselineAlerts = true; self.refresh(); self.syncCleanupSettings()
                if granted && test {
                    let content = UNMutableNotificationContent(); content.title = "Heimdall test notification"; content.body = "Low-space alerts are ready. This is a test, not a disk warning."
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "heimdall-test",content: content,trigger: nil))
                }
            }
        }
    }
    private func sendAlert(target: DiskTarget,reading: DiskReading,level: Int) {
        let content = UNMutableNotificationContent()
        content.title = level == 2 ? "Critical space on \(target.name)" : "Space getting low on \(target.name)"
        content.body = String(format: "%.1f GB free. %@",Double(reading.free) / 1e9,level == 2 ? "Make room before your next install or update." : "A good time to offload files.")
        content.userInfo = ["diskID": target.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "heimdall-\(target.id)",content: content,trigger: nil)) { [weak self] error in
            if error != nil { DispatchQueue.main.async { self?.model.alertNote = "Notification delivery failed. Check macOS permissions." } }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,willPresent notification: UNNotification,withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner,.list]) }
    func userNotificationCenter(_ center: UNUserNotificationCenter,didReceive response: UNNotificationResponse,withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let id = response.notification.request.content.userInfo["diskID"] as? String { self.model.selectAction(id) }
            if !self.popover.isShown { self.togglePanel() }
        }
        completionHandler()
    }
    private func checkUpdates() {
        guard !model.checkingUpdate else { return }
        model.checkingUpdate = true; model.updateNote = "Checking GitHub…"; model.releaseURL = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration); updateSession = session
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/theedward/heimdall/releases/latest")!)
        request.setValue("application/vnd.github+json",forHTTPHeaderField: "Accept")
        request.setValue("Heimdall/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")",forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data,response,error in
            var note = "Couldn’t check for updates. Try again."
            var releaseURL: URL?
            if let http = response as? HTTPURLResponse,http.statusCode == 403 || http.statusCode == 429 { note = "Updates are temporarily unavailable. Try later." }
            else if error == nil,let http = response as? HTTPURLResponse,http.statusCode == 200,let data,
                    let (latest,tag,url) = try? GitHubRelease.parse(data),
                    let installed = ReleaseVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0") {
                if latest > installed { note = "\(tag) is available"; releaseURL = url } else { note = "You’re up to date" }
            }
            DispatchQueue.main.async { self?.model.checkingUpdate = false; self?.model.updateNote = note; self?.model.releaseURL = releaseURL; self?.updateSession = nil }
            session.finishTasksAndInvalidate()
        }.resume()
    }
    private func freeUpSpace() {
        guard !model.cleaning,!cleanupModel.busy,!hub.busy else { return }
        cleanupCancellation?.cancel(); cleanupGeneration = UUID()
        cleanupModel.scanning = false; cleanupModel.working = true
        model.cleaning = true; model.cleanNote = ""; hub.busy = true; hub.message = "Freeing up space…"; hub.notice = nil
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let before = try? DiskReading.read(path: home.path).free
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let deadline = Date().addingTimeInterval(120)
            func buildersRunning() -> Bool {
                let command = ToolCommand(executable: URL(fileURLWithPath: "/bin/ps"),arguments: ["-axo","comm="],environment: [:])
                guard let output = try? ToolRunner(timeout: 3).run(command),output.status == 0,!output.truncated else { return true }
                let active: Set<String> = ["Xcode","xcodebuild","swift","swift-build","swift-package","swift-frontend","clang","clang++","ninja","make","cmake","node","npm","brew","ruby","Unity","Unity Hub","java","gradle"]
                return output.text.split(separator: "\n").contains { active.contains(URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)).lastPathComponent) }
            }
            var engine = CleanupEngine(home: home)
            engine.cancelled = { Date() > deadline }
            engine.xcodeRunning = buildersRunning
            let result = AutomaticCleanup(engine: engine,buildersRunning: buildersRunning,remove: { try FileManager.default.removeItem(at: $0) }).run()
            let after = try? DiskReading.read(path: home.path).free
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.cleaning = false; self.cleanupModel.working = false; self.hub.busy = false
                let bytes = ByteCountFormatter.string(fromByteCount: result.removedBytes,countStyle: .file)
                if result.removedCount > 0 {
                    if let before,let after,after > before {
                        self.model.cleanNote = "\(ByteCountFormatter.string(fromByteCount: after - before,countStyle: .file)) more available."
                    } else { self.model.cleanNote = "Removed \(bytes) of cached files and old logs." }
                } else if result.busyCount > 0 {
                    self.model.cleanNote = "Close your development tools and try again."
                } else if result.skippedCount > 0 || !result.notes.isEmpty {
                    self.model.cleanNote = "Some locations couldn’t be cleaned. Review files for more options."
                } else { self.model.cleanNote = "Nothing more to clean automatically." }
                if result.removedCount > 0 && (result.skippedCount > 0 || !result.notes.isEmpty) { self.model.cleanNote += " Some items were skipped." }
                self.cleanupModel.status = self.model.cleanNote
                // Invalidate review snapshots affected by this run.
                self.cleanupModel.candidates = []; self.cleanupModel.opportunities = []; self.cleanupModel.selection = []; self.cleanupModel.scanned = false
                self.hub.message = self.model.cleanNote; self.hub.notice = self.model.cleanNote
                self.refresh(); self.scanCleanup()
            }
        }
    }
    private func syncCleanupSettings() {
        cleanupModel.login = FileManager.default.fileExists(atPath: loginURL.path)
        cleanupModel.alerts = model.alerts
        cleanupModel.balanced = defaults.integer(forKey: "warningGB") == 60 && defaults.integer(forKey: "criticalGB") == 25
    }
    private func showCleanup() {
        popover.performClose(nil)
        syncNotificationPermission()
        syncCleanupSettings()
        cleanupModel.scanAction = { [weak self] in self?.scanCleanup() }
        cleanupModel.addFolderAction = { [weak self] in self?.addScanFolder() }
        cleanupModel.opportunityAction = { [weak self] item in self?.actOnOpportunity(item) }
        cleanupModel.trashAction = { [weak self] in self?.reviewTrash() }
        cleanupModel.fileTrashAction = { [weak self] item in self?.reviewFileRemoval(item) }
        cleanupModel.openTrashAction = { [weak self] in self?.finderTrash(empty: false) }
        cleanupModel.emptyTrashAction = { [weak self] in self?.reviewEmptyTrash() }
        cleanupModel.recommendedAction = { [weak self] in self?.reviewRecommendedSettings() }
        cleanupModel.settingsAction = { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!) }
        cleanupModel.finderSettingsAction = { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser) }
        cleanupModel.closeAction = { [weak self] in self?.cleanupWindow?.performClose(nil) }
        if cleanupWindow == nil {
            let height = min(CGFloat(800),(NSScreen.main?.visibleFrame.height ?? 900) - 80)
            let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 960,height: height),styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
            window.title = "Heimdall — Make room"; window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 900,height: 540)
            window.contentViewController = NSHostingController(rootView: StorageHub(hub: hub,cleanup: cleanupModel,beacon: model))
            window.delegate = self; window.center(); cleanupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        cleanupWindow?.makeKeyAndOrderFront(nil)
        if !cleanupModel.scanned && !cleanupModel.busy { scanCleanup() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !cleanupModel.working && !hub.busy }
    func windowWillClose(_ notification: Notification) {
        cleanupWindow = nil
    }
    private func scanCleanup() {
        guard !cleanupModel.busy,!hub.busy else { return }
        if let _ = hub.sheet { return }
        cleanupCancellation?.cancel()
        let token = CleanupCancellation(); cleanupCancellation = token
        let generation = UUID(); cleanupGeneration = generation
        cleanupModel.scanning = true; cleanupModel.selection = []
        cleanupModel.status = "Scanning…"; cleanupModel.scanned = false
        hub.scanning = true; model.discovering = true
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let xcodeBusy = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.dt.Xcode" }
        let additionalRoots = cleanupModel.additionalRoots
        let deadline = Date().addingTimeInterval(60)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var engine = CleanupEngine(home: home)
            engine.xcodeRunning = { xcodeBusy }
            engine.cancelled = { token.isCancelled || Date() > deadline }
            var result = engine.scan()
            var scanner = StorageScanner(home: home)
            scanner.additionalRoots = additionalRoots
            scanner.tools = ToolDiscovery.detect(home: home)
            scanner.cancelled = { token.isCancelled || Date() > deadline }
            for (kind,executable,arguments) in [(CacheTool.npm,scanner.tools.npm,["config","get","cache"]),(CacheTool.homebrew,scanner.tools.homebrew,["--cache"])] {
                guard !scanner.cancelled(),let executable else { continue }
                let command = ToolCommand(executable: executable,arguments: arguments,environment: ["HOMEBREW_NO_AUTO_UPDATE":"1","HOMEBREW_NO_ANALYTICS":"1"])
                if let output = try? ToolRunner(timeout: 5).run(command),output.status == 0,!output.truncated,
                   let path = output.text.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("/") }) {
                    scanner.reportedCacheLocations[kind] = URL(fileURLWithPath: path)
                }
            }
            scanner.simulatorInventory = {
                let command = ToolCommand(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),arguments: ["simctl","runtime","list","-j"],environment: [:])
                let output = try ToolRunner(timeout: 8,maximumOutputBytes: 2_000_000).run(command)
                guard output.status == 0,!output.truncated else { throw CleanupFailure.unsupported }
                return Data(output.text.utf8)
            }
            let topology = StorageDestination.discover(home: home,cancelled: scanner.cancelled)
            let trash = TrashEstimate.scan(home: home,destinations: topology.1,cancelled: scanner.cancelled)
            let inventory = scanner.scan()
            result.notes += inventory.notes
            if Date() > deadline { result.notes.append("Some locations weren’t fully checked.") }
            DispatchQueue.main.async {
                guard let self,self.cleanupGeneration == generation,!token.isCancelled else { return }
                self.cleanupModel.scanning = false; self.cleanupModel.scanned = true
                self.cleanupModel.candidates = result.candidates; self.cleanupModel.opportunities = inventory.items; self.cleanupModel.notes = result.notes
                self.cleanupModel.status = "\(result.candidates.count) cleanup items · \(inventory.items.count) files and folders"
                self.hub.destinations = topology.1; self.hub.sourceGroup = topology.0; self.hub.trash = trash
                self.hub.scanning = false; self.hub.scanned = true; self.model.discovering = false
                self.hub.lastScan = Date(); self.lastRecommendationScan = Date()
                self.publishRecommendations()
                self.syncCleanupSettings()
            }
        }
    }
    private func addScanFolder() {
        guard !cleanupModel.busy else { return }
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = true
        picker.message = "Choose extra locations to inspect. Any accessible volume can be used; no files are changed by scanning."
        picker.prompt = "Add locations"
        guard picker.runModal() == .OK else { return }
        for url in picker.urls {
            if !cleanupModel.additionalRoots.contains(where: { $0.path == url.path }) { cleanupModel.additionalRoots.append(url) }
        }
        scanCleanup()
    }
    private func actOnOpportunity(_ item: StorageOpportunity) {
        guard !cleanupModel.busy else { return }
        switch item.action {
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([item.url])
        case .relocate: reviewRelocation(item)
        case .cache(let kind,let executable): reviewToolCleanup(item,kind: kind,executable: executable)
        case .manager(let manager):
            let bundle: String?
            let documentation: String
            switch manager {
            case .unity: bundle = "com.unity3d.unityhub"; documentation = "https://docs.unity.com/en-us/hub/add-editor"
            case .xcode: bundle = "com.apple.dt.Xcode"; documentation = "https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components"
            case .jetBrains: bundle = "com.jetbrains.toolbox"; documentation = "https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html"
            case .steam: bundle = "com.valvesoftware.steam"; documentation = "https://help.steampowered.com/en/faqs/view/4BD4-4528-6B2E-8327"
            case .gradle: bundle = nil; documentation = "https://docs.gradle.org/current/userguide/directory_layout.html"
            }
            if manager == .steam,let url = URL(string: "steam://open/settings/storage") { NSWorkspace.shared.open(url); return }
            let alert = NSAlert(); alert.messageText = "Review in the component’s manager"
            alert.informativeText = item.explanation
            alert.addButton(withTitle: bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } == nil ? "Open guide" : "Open manager")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if let bundle,let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) { NSWorkspace.shared.open(app) }
            else if let url = URL(string: documentation) { NSWorkspace.shared.open(url) }
        }
    }
    private func reviewToolCleanup(_ item: StorageOpportunity,kind: CacheTool,executable: URL) {
        let plan = ToolCleanupPlan(tool: kind,executable: executable,cache: item.url)
        guard let rootStamp = try? CleanupStamp.read(item.url),rootStamp.isDirectory,
              item.url.resolvingSymlinksInPath().path == item.url.path,FileManager.default.isExecutableFile(atPath: executable.path) else {
            cleanupModel.notes = ["Tool or cache location changed, is linked, or is unavailable. Scan again."]; return
        }
        if kind == .swift && NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.dt.Xcode" }) {
            cleanupModel.notes = ["Close Xcode before purging Swift package caches."]; return
        }
        guard let command = plan.command() else { return }
        cleanupModel.working = true; cleanupModel.status = "Preparing cleanup…"
        hub.busy = true; hub.message = "Preparing cleanup…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var preview = "This tool does not provide a dry-run. You are reviewing a purge of the named recreatable cache."
            do {
                if let dryRun = plan.command(dryRun: true) {
                    let result = try ToolRunner().run(dryRun)
                    guard result.status == 0,!result.truncated else { throw CleanupFailure.unsupported }
                    preview = result.text.isEmpty ? "Homebrew reports no cleanup items." : result.text
                }
                let text = preview
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.cleanupModel.working = false; self.hub.busy = false
                    self.hub.sheet = .tool(item,kind,command,rootStamp,kind == .homebrew ? text : nil)
                }
            } catch {
                DispatchQueue.main.async { self?.cleanupModel.working = false; self?.hub.busy = false; self?.hub.message = "Couldn’t prepare cleanup."; self?.cleanupModel.notes = ["Couldn’t prepare the cleanup preview: \(error.localizedDescription). No cleanup was run."] }
            }
        }
    }
    private func runToolCleanup(_ command: ToolCommand,cache: URL,stamp: CleanupStamp,plan: ToolCleanupPlan,expectedDryRun: String?) {
        if plan.tool == .swift && NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.dt.Xcode" }) {
            cleanupModel.working = false; hub.busy = false; hub.message = "Close Xcode before cleaning this cache."; cleanupModel.notes = ["Xcode started during review. Close it before purging Swift package caches."]; return
        }
        cleanupModel.status = "Cleaning cache…"; hub.message = "Cleaning cache…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var message: String
            do {
                let current = try CleanupStamp.read(cache)
                guard current.inode == stamp.inode,current.device == stamp.device,cache.resolvingSymlinksInPath().path == cache.path else { throw StorageFailure.changed }
                if let expectedDryRun,let dryRun = plan.command(dryRun: true) {
                    let currentPlan = try ToolRunner().run(dryRun)
                    let text = currentPlan.text.isEmpty ? "Homebrew reports no cleanup items." : currentPlan.text
                    guard currentPlan.status == 0,!currentPlan.truncated,text == expectedDryRun else { throw StorageFailure.changed }
                }
                let result = try ToolRunner(timeout: 90).run(command)
                message = result.status == 0 ? "Cache cleanup finished." : "Cleanup couldn’t finish. Some items may have been removed; scan again before retrying."
            } catch { message = "Tool cleanup failed: \(error.localizedDescription). Check the tool’s state and scan again before retrying." }
            let resultMessage = message
            DispatchQueue.main.async { self?.cleanupModel.working = false; self?.hub.busy = false; self?.hub.message = resultMessage; self?.hub.notice = resultMessage; self?.cleanupModel.status = resultMessage; self?.refresh(); self?.scanCleanup() }
        }
    }
    private func reviewRelocation(_ item: StorageOpportunity) {
        hub.destinationID = hub.destinations(for: item).first?.id ?? ""
        showCleanup()
        hub.sheet = .move(item)
    }
    private var reviewedFileRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        return ["Downloads","Documents","Desktop","Movies","Music","Pictures"].map { home.appendingPathComponent($0) } + cleanupModel.additionalRoots
    }
    private func reviewFileRemoval(_ item: StorageOpportunity) {
        guard !cleanupModel.busy else { return }
        let alert = NSAlert(); alert.messageText = "Move \(item.name) to Trash?"
        alert.informativeText = "\(item.url.path)\n\nYou can restore this file from Trash until Trash is emptied."
        alert.addButton(withTitle: "Keep file"); alert.addButton(withTitle: "Move to Trash")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let roots = reviewedFileRoots
        do {
            try ReviewedFile.moveToTrash(item,roots: roots) { try FileManager.default.trashItem(at: $0,resultingItemURL: nil) }
            cleanupModel.opportunities.removeAll { $0.url.path == item.url.path }
            cleanupModel.candidates.removeAll { $0.url.path == item.url.path }; cleanupModel.selection.remove(item.url.path)
            cleanupModel.status = "Moved \(item.name) to Trash."
        } catch { cleanupModel.notes = [error.localizedDescription] }
        hub.notice = cleanupModel.status
        refresh(); scanCleanup()
    }
    private func reviewEmptyTrash() {
        guard !cleanupModel.busy else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Permanently empty all Trash?"
        alert.informativeText = "This permanently deletes everything in Trash on connected disks, including files removed by other apps. You won’t be able to restore these files from Trash.\n\nmacOS may ask permission to control Finder."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Empty Trash permanently")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        finderTrash(empty: true)
    }
    private func finderTrash(empty: Bool) {
        guard !cleanupModel.busy else { return }
        cleanupModel.working = true; hub.busy = true
        hub.message = empty ? "Emptying Trash…" : "Opening Trash…"
        cleanupModel.status = empty ? "Emptying Trash…" : "Opening Trash…"
        // A fixed Finder command; no file paths or user text are evaluated as script.
        let script = empty ? "tell application \"Finder\" to empty trash" : "tell application \"Finder\"\nactivate\nopen trash\nend tell"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let message: String
            do {
                let result = try ToolRunner(timeout: 90).run(ToolCommand(executable: URL(fileURLWithPath: "/usr/bin/osascript"),arguments: ["-e",script],environment: [:]))
                if result.status == 0 {
                    message = empty ? "Empty Trash finished." : "Trash opened in Finder."
                } else {
                    message = "Finder couldn’t complete the request. Check Trash in Finder. If access was denied, allow Heimdall in System Settings → Privacy & Security → Automation."
                }
            } catch { message = "Finder’s result could not be confirmed. Check Trash in Finder before retrying: " + error.localizedDescription }
            DispatchQueue.main.async { self?.cleanupModel.working = false; self?.cleanupModel.status = message; self?.hub.busy = false; self?.hub.message = message; self?.hub.notice = message; self?.refresh(); self?.scanCleanup() }
        }
    }
    private func reviewTrash() {
        guard !cleanupModel.busy,!cleanupModel.selected.isEmpty else { return }
        let selected = cleanupModel.selected
        let alert = NSAlert(); alert.messageText = "Move \(selected.count) selected items to Trash?"
        alert.informativeText = "\(CleanupModel.size(cleanupModel.selectedBytes)). You can restore these items from Trash until Trash is emptied.\n\n" + selected.prefix(8).map { $0.url.path }.joined(separator: "\n") + (selected.count > 8 ? "\n…and \(selected.count - 8) more selected items from your review list." : "")
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cleanupModel.working = true; cleanupModel.status = "Moving selected items…"; hub.busy = true; hub.message = "Moving selected items…"
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var engine = CleanupEngine(home: home)
            engine.xcodeRunning = { DispatchQueue.main.sync { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.dt.Xcode" } } }
            engine.cancelled = { false }
            var moved: Set<String> = []; var failures: [String] = []
            for item in selected {
                do {
                    try engine.moveToTrash(item) { url in try FileManager.default.trashItem(at: url,resultingItemURL: nil) }
                    moved.insert(item.id)
                } catch { failures.append("\(item.name): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.cleanupModel.working = false; self.hub.busy = false
                self.hub.message = "Moved \(moved.count) installers to Trash."; self.hub.notice = self.hub.message
                self.cleanupModel.candidates.removeAll { moved.contains($0.id) }
                self.cleanupModel.selection = []
                self.cleanupModel.notes = failures
                self.cleanupModel.status = "Moved \(moved.count) items to Trash. \(failures.count) skipped."
                self.refresh(); self.scanCleanup()
            }
        }
    }
    private func reviewRecommendedSettings() {
        syncCleanupSettings()
        var changes: [String] = []
        if !cleanupModel.login { changes.append("Turn on Launch at login") }
        if !cleanupModel.alerts { changes.append("Request/enable low-space notifications") }
        if !cleanupModel.balanced { changes.append("Use Balanced thresholds: amber below 60 GB, red below 25 GB") }
        let alert = NSAlert()
        alert.messageText = changes.isEmpty ? "Heimdall already uses the recommended settings" : "Apply these Heimdall settings?"
        alert.informativeText = changes.isEmpty ? "Launch at login, low-space notifications and Balanced thresholds are enabled." : changes.joined(separator: "\n")
        alert.addButton(withTitle: changes.isEmpty ? "OK" : "Apply settings")
        if !changes.isEmpty { alert.addButton(withTitle: "Cancel") }
        guard alert.runModal() == .alertFirstButtonReturn,!changes.isEmpty else { return }
        if !cleanupModel.login { toggleLogin() }
        defaults.set(60,forKey: "warningGB"); defaults.set(25,forKey: "criticalGB"); baselineAlerts = true
        if !cleanupModel.alerts { configureAlerts(true) }
        refresh(); syncCleanupSettings()
    }
    private func toggleLogin() {
        do {
            if FileManager.default.fileExists(atPath: loginURL.path) {
                try FileManager.default.removeItem(at: loginURL)
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["bootout", "gui/\(getuid())/io.github.theedward.heimdall"]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try? process.run()
            } else {
                try FileManager.default.createDirectory(at: loginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let plist: [String: Any] = ["Label": "io.github.theedward.heimdall", "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath], "RunAtLoad": true]
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: loginURL, options: .atomic)
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "Couldn’t update launch at login"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
        refresh()
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated { renderPreviews(to: CommandLine.arguments[index + 1]) }
} else if CommandLine.arguments.contains("--list-disks") {
    print(DiskTarget.available().map { "\($0.name) | \($0.id) | \($0.path)" }.joined(separator: "\n"))
} else if CommandLine.arguments.contains("--recommendations-check") {
    let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
    let deadline = Date().addingTimeInterval(60)
    let cancelled = { Date() > deadline }
    var engine = CleanupEngine(home: home); engine.cancelled = cancelled
    let candidates = engine.scan()
    var scanner = StorageScanner(home: home); scanner.cancelled = cancelled
    scanner.tools = ToolDiscovery.detect(home: home)
    let topology = StorageDestination.discover(home: home,cancelled: cancelled)
    let trash = TrashEstimate.scan(home: home,destinations: topology.1,cancelled: cancelled)
    let inventory = scanner.scan()
    var homeInfo = stat(); _ = stat(home.path,&homeInfo)
    let suggestions = RecommendationBuilder(sourceGroup: topology.0,destinations: topology.1,choices: [],sourceDevice: homeInfo.st_dev).build(candidates: candidates.candidates,items: inventory.items,trashBytes: trash.bytes,trashIncomplete: trash.incomplete)
    let output: [String: Any] = ["readOnly":true,"sourceStorageKnown":topology.0 != nil,"destinations":topology.1.count,"cleanupCandidates":candidates.candidates.count,"inventoryItems":inventory.items.count,"recommendations":suggestions.map { ["kind":$0.kind.rawValue,"effort":$0.effort.rawValue,"bytes":$0.bytes as Any] },"notes":inventory.notes.count + candidates.notes.count,"incomplete":cancelled()]
    if let data = try? JSONSerialization.data(withJSONObject: output,options: [.prettyPrinted]),let text = String(data: data,encoding: .utf8) { print(text) }
} else if CommandLine.arguments.contains("--check") {
    do {
        let disk = try DiskReading.read()
        let output: [String: Any] = ["totalBytes": disk.total, "freeBytes": disk.free, "occupiedBytes": disk.occupied, "usedPercent": disk.fraction * 100, "path": "/System/Volumes/Data"]
        print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted,.sortedKeys]), encoding: .utf8)!)
    } catch { fputs("Disk reading failed: \(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

extension AppDelegate {
    private func configureStorageHub() {
        if let data = defaults.data(forKey: "suggestionChoices"),let saved = try? JSONDecoder().decode([SuggestionChoice].self,from: data) { hub.choices = saved }
        do { hub.moves = try moveStore.load() }
        catch { journalHealthy = false; hub.message = "Move history couldn’t be opened. Moving files is unavailable." }
        model.hub = hub
        hubObservation = hub.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.model.objectWillChange.send() }
        model.preferencesAction = { [weak self] in self?.showCleanup(); self?.hub.page = "preferences" }
        hub.refreshAction = { [weak self] in self?.scanCleanup() }
        hub.cleanAction = { [weak self] in self?.freeUpSpace() }
        hub.action = { [weak self] rec in self?.actOnRecommendation(rec) }
        hub.remember = { [weak self] rec,decision in
            guard let self else { return }
            self.hub.choices.removeAll { $0.key == rec.id }
            self.hub.choices.append(SuggestionChoice(key: rec.id,name: rec.item?.name ?? rec.title,decision: decision))
            self.saveChoices(); self.publishRecommendations()
        }
        hub.restoreChoice = { [weak self] key in
            guard let self else { return }
            self.hub.choices.removeAll { $0.key == key }; self.saveChoices(); self.publishRecommendations()
        }
        hub.runTool = { [weak self] command,cache,stamp,plan,preview in
            guard let self,!self.hub.busy,!self.cleanupModel.busy else { return }
            self.hub.busy = true; self.cleanupModel.working = true
            self.runToolCleanup(command,cache: cache,stamp: stamp,plan: plan,expectedDryRun: preview)
        }
        hub.confirmMove = { [weak self] item,id in self?.performRecommendedMove(item,destinationID: id) }
        hub.undoMove = { [weak self] record in self?.moveBack(record) }
        hub.openTrash = { [weak self] in self?.finderTrash(empty: false) }
        hub.emptyTrash = { [weak self] in self?.finderTrash(empty: true) }
    }
    private func saveChoices() {
        if let data = try? JSONEncoder().encode(hub.choices) { defaults.set(data,forKey: "suggestionChoices") }
    }
    private func publishRecommendations() {
        var homeInfo = stat(); _ = stat(FileManager.default.homeDirectoryForCurrentUser.path,&homeInfo)
        let builder = RecommendationBuilder(sourceGroup: hub.sourceGroup,destinations: hub.destinations,choices: hub.choices,sourceDevice: homeInfo.st_dev)
        hub.recommendations = builder.build(candidates: cleanupModel.candidates,items: cleanupModel.opportunities,trashBytes: hub.trash.bytes,trashIncomplete: hub.trash.incomplete)
        model.recommendations = hub.recommendations
        if !hub.busy {
            hub.message = hub.recommendations.isEmpty ? "No new suggestions right now." : "\(hub.recommendations.count) ways to make room"
        }
    }
    private func actOnRecommendation(_ rec: Recommendation) {
        guard !hub.busy,!cleanupModel.working else { return }
        switch rec.kind {
        case .cleanup: freeUpSpace()
        case .trash: showCleanup(); hub.sheet = .trash
        case .installers: showCleanup(); cleanupModel.selection = []; hub.sheet = .installers
        case .move: if let item = rec.item { reviewRelocation(item) }
        case .manage: if let item = rec.item { showCleanup(); hub.sheet = .file(item) }
        }
    }
    private func performRecommendedMove(_ item: StorageOpportunity,destinationID: String) {
        guard !hub.busy,!cleanupModel.busy,journalHealthy,
              let disk = hub.destinations.first(where: { $0.id == destinationID }),disk.fits(item.bytes ?? 0,sourceGroup: hub.sourceGroup) else {
            hub.message = "Destination unavailable. Refresh suggestions and try again."; hub.notice = hub.message; return
        }
        hub.sheet = nil; hub.busy = true; cleanupModel.working = true; hub.progress = 0; hub.notice = nil
        hub.message = "Moving \(item.name)…"
        let roots = reviewedFileRoots; let sourceGroup = hub.sourceGroup; let store = moveStore
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                // Never recreate a missing mountpoint. The same UUID and storage group must still be online.
                guard let diskInfo = StorageDestination.diskInfo(disk.root),diskInfo["VolumeUUID"] as? String == disk.id,
                      StorageDestination.group(diskInfo) == disk.storageGroup,
                      let liveSource = StorageDestination.diskInfo(item.url),let group = StorageDestination.group(liveSource),group == sourceGroup,group != disk.storageGroup else { throw StorageFailure.invalidDestination }
                try ReviewedFile.validate(item,roots: roots)
                let folder = disk.folder(for: item)
                guard ReviewedFile.canonicalPath(disk.root) == disk.root.path else { throw StorageFailure.invalidDestination }
                for part in [folder.deletingLastPathComponent(),folder] {
                    var value = stat()
                    if lstat(part.path,&value) == 0 {
                        guard value.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR),ReviewedFile.canonicalPath(part) == part.path else { throw StorageFailure.invalidDestination }
                    } else {
                        guard errno == ENOENT else { throw StorageFailure.invalidDestination }
                        try FileManager.default.createDirectory(at: part,withIntermediateDirectories: false)
                    }
                }
                var relocator = FileRelocator(allowedRoots: roots)
                var lastUpdate = Date.distantPast
                relocator.progress = { completed,total in
                    guard Date().timeIntervalSince(lastUpdate) > 0.15 || completed == total else { return }; lastUpdate = Date()
                    DispatchQueue.main.async { self?.hub.progress = total > 0 ? Double(completed) / Double(total) : 0 }
                }
                let destination = folder.appendingPathComponent(item.name)
                let result = try relocator.relocate(item,to: folder) { original in
                    let record = MoveRecord(id: UUID(),name: item.name,source: original,destination: destination,stamp: try CleanupStamp.read(destination),bytes: item.bytes ?? 0,date: Date())
                    var records = try store.load(); records.append(record)
                    // Persist the way back before removing the source, including if the app is interrupted.
                    try store.save(records)
                    try FileManager.default.removeItem(at: original)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.hub.message = "Moved \(item.name) to \(disk.name)."; self.model.cleanNote = self.hub.message; self.hub.notice = self.hub.message; self.finishMove()
                    self.cleanupModel.opportunities.removeAll { $0.url.path == item.url.path }
                    self.hub.moves = (try? store.load()) ?? self.hub.moves
                    self.hub.recommendations.removeAll { $0.item?.url.path == item.url.path }; self.model.recommendations = self.hub.recommendations
                    self.refresh(); self.scanCleanup()
                    NSWorkspace.shared.noteFileSystemChanged(result.destination.path)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finishMove(); self.hub.message = error.localizedDescription; self.hub.notice = error.localizedDescription
                    self.hub.moves = (try? store.load()) ?? self.hub.moves
                }
            }
        }
    }
    private func finishMove() {
        hub.busy = false; cleanupModel.working = false; hub.progress = nil
    }
    private func moveBack(_ record: MoveRecord) {
        guard !hub.busy,!cleanupModel.busy,journalHealthy else { return }
        let alert = NSAlert(); alert.messageText = "Move \(record.name) back?"
        alert.informativeText = "Restore to \(shortPath(record.source.deletingLastPathComponent())). This uses \(CleanupModel.size(record.bytes)) on the original disk. The current copy is removed only after verification."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Move back")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        hub.busy = true; cleanupModel.working = true; hub.progress = 0; hub.message = "Moving \(record.name) back…"
        let store = moveStore
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                guard try CleanupStamp.read(record.destination) == record.stamp else { throw StorageFailure.changed }
                let originalParent = record.source.deletingLastPathComponent()
                guard ReviewedFile.canonicalPath(originalParent) == originalParent.path,FileManager.default.fileExists(atPath: originalParent.path),!FileManager.default.fileExists(atPath: record.source.path) else { throw StorageFailure.collision }
                let item = StorageOpportunity(url: record.destination,category: .downloads,name: record.name,bytes: record.bytes,incomplete: false,explanation: "",action: .relocate,sourceStamp: record.stamp)
                var relocator = FileRelocator(allowedRoots: [record.destination.deletingLastPathComponent()])
                var last = Date.distantPast
                relocator.progress = { completed,total in
                    guard Date().timeIntervalSince(last) > 0.15 || completed == total else { return }; last = Date()
                    DispatchQueue.main.async { self?.hub.progress = total > 0 ? Double(completed) / Double(total) : 0 }
                }
                _ = try relocator.relocate(item,to: originalParent) { try FileManager.default.removeItem(at: $0) }
                var records = try store.load(); records.removeAll { $0.id == record.id }; try store.save(records)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finishMove(); self.hub.moves = (try? store.load()) ?? self.hub.moves
                    self.hub.message = "Moved \(record.name) back."; self.model.cleanNote = self.hub.message; self.hub.notice = self.hub.message; self.refresh(); self.scanCleanup()
                }
            } catch { DispatchQueue.main.async { self?.finishMove(); self?.hub.message = error.localizedDescription } }
        }
    }
}
