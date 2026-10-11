import Foundation
import Darwin

// Only these three explicit locations are eligible. No whole-disk or cache sweep.
enum CleanupRule: String, CaseIterable {
    case installers, logs, derivedData
    var title: String {
        switch self {
        case .installers: return "Old installers"
        case .logs: return "Old user logs"
        case .derivedData: return "Inactive Xcode build data"
        }
    }
    var reason: String {
        switch self {
        case .installers: return "DMG or PKG download created and modified at least 30 days ago. Keep installers you may need again."
        case .logs: return "User log created and modified at least 30 days ago. Keep logs you need for troubleshooting."
        case .derivedData: return "Xcode build data created and modified at least 30 days ago. Xcode must be closed; the next build recreates it."
        }
    }
    var rootPath: String {
        switch self {
        case .installers: return "Downloads"
        case .logs: return "Library/Logs"
        case .derivedData: return "Library/Developer/Xcode/DerivedData"
        }
    }
}

struct CleanupStamp: Equatable {
    let path: String
    let inode: UInt64
    let device: Int32
    let mode: UInt16
    let owner: UInt32
    let links: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let createdSeconds: Int64
    let changedSeconds: Int64
    let changedNanos: Int64
    var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    static func read(_ url: URL) throws -> Self {
        var value = stat()
        guard lstat(url.path,&value) == 0 else { throw CleanupFailure.changed }
        let kind = value.st_mode & UInt16(S_IFMT)
        guard kind == UInt16(S_IFREG) || kind == UInt16(S_IFDIR),value.st_uid == getuid(),value.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0 else { throw CleanupFailure.unsupported }
        guard kind != UInt16(S_IFREG) || value.st_nlink == 1 else { throw CleanupFailure.unsupported }
        return Self(path: url.path,inode: value.st_ino,device: value.st_dev,mode: value.st_mode,owner: value.st_uid,links: value.st_nlink,size: value.st_size,modifiedSeconds: Int64(value.st_mtimespec.tv_sec),modifiedNanos: Int64(value.st_mtimespec.tv_nsec),createdSeconds: Int64(value.st_birthtimespec.tv_sec),changedSeconds: Int64(value.st_ctimespec.tv_sec),changedNanos: Int64(value.st_ctimespec.tv_nsec))
    }
}

struct CleanupCandidate: Identifiable {
    var id: String { url.path }
    let url: URL
    let rule: CleanupRule
    let bytes: Int64
    let modified: Date
    let snapshot: [CleanupStamp]
    var name: String { url.lastPathComponent }
}
struct CleanupScan {
    var candidates: [CleanupCandidate] = []
    var notes: [String] = []
}
enum CleanupFailure: Error, LocalizedError {
    case changed, unsupported, outsideScope, busy, limit
    var errorDescription: String? {
        switch self {
        case .changed: return "This item changed after scanning. Scan again before removing it."
        case .unsupported: return "This item contains a link, protected file or unsupported entry. It was skipped."
        case .outsideScope: return "This item is outside the approved cleanup locations."
        case .busy: return "Close Xcode before removing its build data."
        case .limit: return "This folder exceeds the scan limit. Review it in Finder."
        }
    }
}

struct CleanupEngine {
    let home: URL
    var now = Date()
    var ageDays = 30
    var minimumBytes: Int64 = 1_000_000
    var maximumEntries = 20_000
    var xcodeRunning: () -> Bool = { false }
    var cancelled: () -> Bool = { false }
    var cutoff: Date { now.addingTimeInterval(-Double(ageDays) * 86400) }
    private func root(_ rule: CleanupRule) -> URL { home.appendingPathComponent(rule.rootPath,isDirectory: true).standardizedFileURL }
    private func validateLocation(_ url: URL,_ rule: CleanupRule) throws {
        let base = root(rule)
        let item = url.standardizedFileURL
        guard item.path.hasPrefix(base.path + "/"),item.path != base.path else { throw CleanupFailure.outsideScope }
        // Resolving every ancestor prevents an approved-looking path from escaping via links.
        guard base.resolvingSymlinksInPath().path == base.path,item.resolvingSymlinksInPath().path == item.path else { throw CleanupFailure.outsideScope }
        if rule != .logs && item.deletingLastPathComponent().path != base.path { throw CleanupFailure.outsideScope }
        if rule == .installers && !["dmg","pkg"].contains(item.pathExtension.lowercased()) { throw CleanupFailure.outsideScope }
        if rule == .logs {
            let suffix = item.pathExtension
            let rotated = !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber } && item.deletingPathExtension().pathExtension.lowercased() == "log"
            guard suffix.lowercased() == "log" || rotated else { throw CleanupFailure.outsideScope }
        }
    }
    private func snapshot(_ url: URL,directory: Bool) throws -> [CleanupStamp] {
        let first = try CleanupStamp.read(url)
        guard first.isDirectory == directory else { throw CleanupFailure.unsupported }
        var result = [first]
        if directory {
            var failed = false
            guard let walk = FileManager.default.enumerator(at: url,includingPropertiesForKeys: nil,options: [],errorHandler: { _,_ in failed = true; return false }) else { throw CleanupFailure.unsupported }
            for case let child as URL in walk {
                guard !cancelled(),result.count < maximumEntries else { throw CleanupFailure.limit }
                guard ![".git",".svn",".hg"].contains(child.lastPathComponent) else { throw CleanupFailure.unsupported }
                let stamp = try CleanupStamp.read(child)
                guard stamp.device == first.device else { throw CleanupFailure.unsupported }
                result.append(stamp)
            }
            guard !failed else { throw CleanupFailure.unsupported }
        }
        return result.sorted { $0.path < $1.path }
    }
    private func candidate(_ url: URL,_ rule: CleanupRule) throws -> CleanupCandidate? {
        try validateLocation(url,rule)
        let stamps = try snapshot(url,directory: rule == .derivedData)
        let latest = stamps.map { Date(timeIntervalSince1970: max(Double($0.modifiedSeconds) + Double($0.modifiedNanos) / 1e9,Double($0.createdSeconds))) }.max() ?? now
        guard latest < cutoff else { return nil }
        let bytes = stamps.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
        guard bytes >= minimumBytes else { return nil }
        return CleanupCandidate(url: url,rule: rule,bytes: bytes,modified: latest,snapshot: stamps)
    }
    func scan() -> CleanupScan {
        var result = CleanupScan()
        for rule in CleanupRule.allCases {
            if cancelled() { break }
            let base = root(rule)
            guard FileManager.default.fileExists(atPath: base.path) else { continue }
            guard base.resolvingSymlinksInPath().path == base.path else { result.notes.append("\(rule.title): linked location skipped."); continue }
            if rule == .derivedData && xcodeRunning() { result.notes.append("Xcode is running. Its build data was skipped."); continue }
            do {
                let urls: [URL]
                if rule == .logs {
                    var failed = false
                    guard let walk = FileManager.default.enumerator(at: base,includingPropertiesForKeys: [.isSymbolicLinkKey,.isDirectoryKey],options: [.skipsHiddenFiles],errorHandler: { _,_ in failed = true; return false }) else { throw CleanupFailure.unsupported }
                    var found: [URL] = []
                    var count = 0
                    for case let url as URL in walk {
                        count += 1
                        guard !cancelled(),count <= maximumEntries else { result.notes.append("Log scan stopped at its limit."); break }
                        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey,.isDirectoryKey])
                        if values.isSymbolicLink == true { walk.skipDescendants(); continue }
                        if values.isDirectory != true { found.append(url) }
                    }
                    if failed { result.notes.append("Some user logs could not be read.") }
                    urls = found
                } else {
                    urls = try FileManager.default.contentsOfDirectory(at: base,includingPropertiesForKeys: nil,options: [.skipsHiddenFiles])
                }
                var skipped = 0
                for url in urls.prefix(maximumEntries) {
                    if cancelled() { break }
                    do { if let item = try candidate(url,rule) { result.candidates.append(item) } }
                    catch CleanupFailure.outsideScope { continue }
                    catch { skipped += 1 }
                }
                if urls.count > maximumEntries { result.notes.append("\(rule.title): scan limited to \(maximumEntries) items.") }
                if skipped > 0 { result.notes.append("\(rule.title): \(skipped) unreadable, linked or unsupported items skipped.") }
            } catch { result.notes.append("\(rule.title): access unavailable. Grant access only if macOS asks.") }
        }
        result.candidates.sort { $0.bytes > $1.bytes }
        return result
    }
    func revalidate(_ item: CleanupCandidate) throws {
        try validateLocation(item.url,item.rule)
        if item.rule == .derivedData && xcodeRunning() { throw CleanupFailure.busy }
        guard let fresh = try candidate(item.url,item.rule),fresh.snapshot == item.snapshot else { throw CleanupFailure.changed }
    }
    func moveToTrash(_ item: CleanupCandidate,using trash: (URL) throws -> Void) throws {
        try revalidate(item)
        try trash(item.url)
    }
}
