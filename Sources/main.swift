import AppKit
import SwiftUI
import Darwin

struct DiskReading {
    let total: Int64
    let free: Int64
    var occupied: Int64 { total - free }
    var fraction: Double { Double(occupied) / Double(total) }
    static func read() throws -> DiskReading {
        var info = statfs()
        guard statfs("/System/Volumes/Data", &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let total = Int64(info.f_blocks) * Int64(info.f_bsize)
        let free = Int64(info.f_bavail) * Int64(info.f_bsize)
        guard total > 0, free >= 0, free <= total else { throw NSError(domain: "Heimdall", code: 1) }
        return DiskReading(total: total, free: free)
    }
}


final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private let model = BeaconModel()
    private let popover = NSPopover()
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private var loginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/io.github.theedward.heimdall.plist")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["warningGB": 60, "criticalGB": 25])
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.target = self
        status.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 615)
        model.refreshAction = { [weak self] in self?.refresh() }
        model.presetAction = { [weak self] warn, crit in
            self?.defaults.set(warn, forKey: "warningGB")
            self?.defaults.set(crit, forKey: "criticalGB")
            self?.refresh()
        }
        model.loginAction = { [weak self] in self?.toggleLogin() }
        model.storageAction = { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!) }
        model.quitAction = { NSApplication.shared.terminate(nil) }
        let hosting = NSHostingController(rootView: BeaconPanel(model: model))
        popover.contentViewController = hosting
        hosting.view.layoutSubtreeIfNeeded()
        let height = hosting.view.fittingSize.height
        if height > 0 { popover.contentSize = NSSize(width: 360,height: ceil(height)) }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    }
    @objc private func togglePanel() {
        guard let button = status.button else { return }
        if popover.isShown { popover.performClose(nil) } else {
            refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    @objc private func refresh() {
        model.warning = defaults.integer(forKey: "warningGB")
        model.critical = defaults.integer(forKey: "criticalGB")
        model.login = FileManager.default.fileExists(atPath: loginURL.path)
        do {
            let disk = try DiskReading.read()
            model.disk = disk; model.updated = Date(); model.error = false
            let freeGB = Double(disk.free) / 1e9
            let color: NSColor = freeGB < Double(model.critical) ? .systemRed : freeGB < Double(model.warning) ? .systemOrange : .labelColor
            let percent = Int((disk.fraction * 100).rounded())
            status.button?.attributedTitle = NSAttributedString(
                string: "\(percent)% · \(Int(freeGB.rounded(.down))) GB",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: color]
            )
            status.button?.image = nil
            status.button?.toolTip = "Internal disk: \(percent)% occupied, \(String(format: "%.1f", freeGB)) GB free · \(model.state)"
            status.button?.setAccessibilityLabel(status.button?.toolTip)
        } catch {
            model.error = true
            status.button?.attributedTitle = NSAttributedString(
                string: "Disk ?", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
            )
            status.button?.image = nil
            status.button?.toolTip = "Unable to read internal disk usage"
        }
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
