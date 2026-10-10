import AppKit
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
        guard total > 0, free >= 0, free <= total else { throw NSError(domain: "DiskBeacon", code: 1) }
        return DiskReading(total: total, free: free)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private var warning: Int { defaults.integer(forKey: "warningGB") }
    private var critical: Int { defaults.integer(forKey: "criticalGB") }
    private var loginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/io.github.theedward.disk-beacon.plist")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["warningGB": 60, "criticalGB": 25])
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.menu = menu
        menu.delegate = self
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    }
    func menuWillOpen(_ menu: NSMenu) { refresh() }
    private func item(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self
        return result
    }
    private func icon(color: NSColor, fraction: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            let outline = NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 20, height: 14), xRadius: 3, yRadius: 3)
            color.setStroke(); outline.lineWidth = 1.5; outline.stroke()
            color.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: NSRect(x: 4, y: 5, width: 14, height: 8), xRadius: 1, yRadius: 1).fill()
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 4, y: 5, width: max(1, 14 * fraction), height: 8), xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
    @objc private func refresh() {
        menu.removeAllItems()
        menu.addItem(item("Disk Beacon · Internal disk"))
        do {
            let disk = try DiskReading.read()
            let freeGB = Double(disk.free) / 1e9
            let state = freeGB < Double(critical) ? "Critical" : freeGB < Double(warning) ? "Getting tight" : "Healthy"
            let color: NSColor = freeGB < Double(critical) ? .systemRed : freeGB < Double(warning) ? .systemOrange : .systemGreen
            let percent = Int((disk.fraction * 100).rounded())
            status.button?.title = " \(percent)% · \(Int(freeGB.rounded(.down))) GB"
            status.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            status.button?.image = icon(color: color, fraction: disk.fraction)
            status.button?.imagePosition = .imageLeading
            status.button?.toolTip = "Internal disk: \(percent)% occupied, \(String(format: "%.1f", freeGB)) GB free · \(state)"
            status.button?.setAccessibilityLabel(status.button?.toolTip)
            menu.addItem(item("\(state) · \(String(format: "%.1f", freeGB)) GB free"))
            menu.addItem(item(String(format: "%.1f GB occupied / %.1f GB capacity", Double(disk.occupied) / 1e9, Double(disk.total) / 1e9)))
        } catch {
            status.button?.title = " Disk ?"
            status.button?.image = icon(color: .systemGray, fraction: 0)
            status.button?.toolTip = "Unable to read internal disk usage"
            menu.addItem(item("Disk reading unavailable. Try refreshing."))
        }
        menu.addItem(.separator())
        let thresholds = item("Color thresholds")
        let submenu = NSMenu()
        for (label, warn, crit) in [("Relaxed: amber < 30 GB, red < 10 GB",30,10), ("Balanced: amber < 60 GB, red < 25 GB",60,25), ("Early warning: amber < 100 GB, red < 50 GB",100,50)] {
            let choice = item(label, action: #selector(setThresholds(_:)))
            choice.representedObject = [warn,crit]
            choice.state = warning == warn && critical == crit ? .on : .off
            submenu.addItem(choice)
        }
        thresholds.submenu = submenu
        menu.addItem(thresholds)
        let login = item("Launch at login", action: #selector(toggleLogin))
        login.state = FileManager.default.fileExists(atPath: loginURL.path) ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Refresh now", action: #selector(refresh)))
        menu.addItem(item("Open Storage Settings…", action: #selector(openStorage)))
        menu.addItem(.separator())
        menu.addItem(item("About Disk Beacon…", action: #selector(about)))
        menu.addItem(item("Quit Disk Beacon", action: #selector(quit)))
    }
    @objc private func setThresholds(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [Int], values.count == 2 else { return }
        defaults.set(values[0], forKey: "warningGB")
        defaults.set(values[1], forKey: "criticalGB")
        refresh()
    }
    @objc private func toggleLogin() {
        do {
            if FileManager.default.fileExists(atPath: loginURL.path) {
                try FileManager.default.removeItem(at: loginURL)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["bootout", "gui/\(getuid())/io.github.theedward.disk-beacon"]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try? process.run()
            } else {
                try FileManager.default.createDirectory(at: loginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let plist: [String: Any] = ["Label": "io.github.theedward.disk-beacon", "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath], "RunAtLoad": true]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: loginURL, options: .atomic)
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "Couldn’t update launch at login"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
        refresh()
    }
    @objc private func openStorage() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(url) }
    }
    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "Disk Beacon"
        alert.informativeText = "Internal disk usage, refreshed every 30 seconds.\n\nGreen: enough room\nAmber: below \(warning) GB free\nRed: below \(critical) GB free\n\nIncludes space occupied across the APFS container. Uses available space reported by macOS without counting potentially purgeable files as free. All sizes use decimal GB.\n\nMIT License · © 2026 João Eduardo Seixas"
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "GitHub")
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(URL(string: "https://github.com/theedward/disk-beacon")!) }
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

if CommandLine.arguments.contains("--check") {
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
