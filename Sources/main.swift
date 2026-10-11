import AppKit
import SwiftUI
import Darwin
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var status: NSStatusItem!
    private let model = BeaconModel()
    private let popover = NSPopover()
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private var tracker = AlertTracker()
    private var activeDisks: Set<String> = []
    private var baselineAlerts = true
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
        model.refreshAction = { [weak self] in self?.refresh() }
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
        model.quitAction = { NSApplication.shared.terminate(nil) }
        let panelHeight = min(CGFloat(850),(NSScreen.main?.visibleFrame.height ?? 900) - 80)
        let hosting = NSHostingController(rootView: ScrollView { BeaconPanel(model: model) }.frame(width: 360,height: panelHeight))
        popover.contentViewController = hosting
        hosting.view.layoutSubtreeIfNeeded()
        let height = hosting.view.fittingSize.height
        if height > 0 { popover.contentSize = NSSize(width: 360,height: ceil(height)) }
        refresh()
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
        activeDisks = present; baselineAlerts = false
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
                self.model.alertNote = settings.authorizationStatus == .denied ? "Blocked in macOS Notifications settings" : "One alert per worsening threshold · all listed disks"
                if settings.authorizationStatus == .denied { self.model.alerts = false; self.defaults.set(false,forKey: "alertsEnabled") }
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
                self.model.alertNote = error != nil ? "Couldn’t request notification permission. Try again." : granted ? "One alert per worsening threshold · all listed disks" : "Allow Heimdall in macOS Notifications settings"
                self.baselineAlerts = true; self.refresh()
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
            if let http = response as? HTTPURLResponse,http.statusCode == 403 || http.statusCode == 429 { note = "GitHub is rate-limiting checks. Try later." }
            else if error == nil,let http = response as? HTTPURLResponse,http.statusCode == 200,let data,
                    let (latest,tag,url) = try? GitHubRelease.parse(data),
                    let installed = ReleaseVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0") {
                if latest > installed { note = "\(tag) is available"; releaseURL = url } else { note = "You’re up to date" }
            }
            DispatchQueue.main.async { self?.model.checkingUpdate = false; self?.model.updateNote = note; self?.model.releaseURL = releaseURL; self?.updateSession = nil }
            session.finishTasksAndInvalidate()
        }.resume()
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
