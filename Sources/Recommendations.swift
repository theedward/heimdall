import Foundation
import Darwin

struct StorageDestination: Identifiable, Equatable {
    let id: String
    let name: String
    let root: URL
    let freeBytes: Int64
    let storageGroup: String
    var maximumFileBytes: Int64 = Int64.max
    static func group(_ info: [String: Any]) -> String? {
        (info["APFSContainerReference"] as? String) ?? (info["ParentWholeDisk"] as? String) ?? (info["DeviceIdentifier"] as? String)
    }
    static func mountPoint(_ url: URL) -> URL? {
        var value = statfs()
        guard statfs(url.path,&value) == 0 else { return nil }
        let path = withUnsafePointer(to: &value.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self,capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return URL(fileURLWithPath: path,isDirectory: true)
    }
    static func diskInfo(_ url: URL) -> [String: Any]? {
        guard let mount = mountPoint(url) else { return nil }
        let cmd = ToolCommand(executable: URL(fileURLWithPath: "/usr/sbin/diskutil"),arguments: ["info","-plist",mount.path],environment: [:])
        guard let result = try? ToolRunner(timeout: 4).run(cmd),result.status == 0,!result.truncated,
              let info = try? PropertyListSerialization.propertyList(from: Data(result.text.utf8),format: nil) as? [String: Any] else { return nil }
        return info
    }
    static func physicalDisks() -> Set<String> {
        let command = ToolCommand(executable: URL(fileURLWithPath: "/usr/sbin/diskutil"),arguments: ["list","-plist","physical"],environment: [:])
        guard let result = try? ToolRunner(timeout: 4).run(command),result.status == 0,!result.truncated,
              let plist = try? PropertyListSerialization.propertyList(from: Data(result.text.utf8),format: nil) as? [String: Any],let disks = plist["WholeDisks"] as? [String] else { return [] }
        return Set(disks)
    }
    static func isPhysical(_ info: [String: Any],disks: Set<String>) -> Bool {
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]] {
            return !stores.isEmpty && stores.allSatisfy { store in
                guard let part = store["APFSPhysicalStore"] as? String else { return false }
                return disks.contains { part == $0 || part.hasPrefix($0 + "s") }
            }
        }
        guard let parent = (info["ParentWholeDisk"] as? String) ?? (info["DeviceIdentifier"] as? String) else { return false }
        return disks.contains(parent)
    }
    static func discover(home: URL,cancelled: () -> Bool) -> (String?,[Self]) {
        let sourceGroup = diskInfo(home).flatMap(group)
        let physical = physicalDisks()
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey,.volumeIsReadOnlyKey,.volumeUUIDStringKey,.volumeNameKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),options: [.skipHiddenVolumes]) ?? []
        var result: [Self] = []
        for root in volumes {
            guard !cancelled(),root.path != "/",!root.path.hasPrefix("/System/"),!root.path.hasPrefix("/private/"),
                  let values = try? root.resourceValues(forKeys: keys),values.volumeIsLocal == true,values.volumeIsReadOnly == false,
                  let info = diskInfo(root),isPhysical(info,disks: physical),let storageGroup = group(info),storageGroup != sourceGroup,
                  let reading = try? DiskReading.read(path: root.path) else { continue }
            let fs = info["FilesystemName"] as? String ?? ""
            result.append(Self(id: values.volumeUUIDString ?? root.path,name: values.volumeName ?? root.lastPathComponent,root: root,freeBytes: reading.free,storageGroup: storageGroup,maximumFileBytes: fs.contains("FAT32") ? 4_294_967_295 : Int64.max))
        }
        return (sourceGroup,result.sorted { $0.freeBytes > $1.freeBytes })
    }
    func fits(_ bytes: Int64,sourceGroup: String?) -> Bool {
        guard let sourceGroup,storageGroup != sourceGroup,bytes >= 0,bytes <= maximumFileBytes else { return false }
        return freeBytes >= 256_000_000 && bytes <= freeBytes - 256_000_000
    }
    func folder(for item: StorageOpportunity) -> URL {
        let ext = item.url.pathExtension.lowercased()
        let category = ["mp4","mov","mkv","avi","m4v"].contains(ext) ? "Videos" : ["zip","rar","7z","tar","gz","dmg","pkg"].contains(ext) ? "Archives" : ["jpg","jpeg","png","heic","raw"].contains(ext) ? "Pictures" : "Documents"
        return root.appendingPathComponent("Heimdall",isDirectory: true).appendingPathComponent(category,isDirectory: true)
    }
}

enum RecommendationKind: String { case cleanup, trash, installers, move, manage }
enum RecommendationEffort: String { case easy, worthwhile }
struct Recommendation: Identifiable {
    let id: String
    let kind: RecommendationKind
    let effort: RecommendationEffort
    let title: String
    let detail: String
    let bytes: Int64?
    var incomplete = false
    var item: StorageOpportunity? = nil
    var destination: StorageDestination? = nil
    var actionTitle: String {
        switch kind {
        case .cleanup: return "Clean up"
        case .trash: return "Empty Trash…"
        case .installers: return "Review installers"
        case .move: return "Review move…"
        case .manage: if let item { return item.action.title }; return "Review"
        }
    }
    var sizeLabel: String {
        guard let bytes else { return "Size unavailable" }
        let size = ByteCountFormatter.string(fromByteCount: bytes,countStyle: .file)
        return (incomplete ? "At least " : "") + size + (kind == .manage || kind == .installers ? " to review" : "")
    }
}
struct SuggestionChoice: Codable, Identifiable {
    enum Decision: String, Codable { case keepHere, dismissed }
    var id: String { key }
    let key: String
    let name: String
    let decision: Decision
}
struct RecommendationBuilder {
    var sourceGroup: String?
    var destinations: [StorageDestination]
    var choices: [SuggestionChoice]
    var sourceDevice: Int32? = nil
    func build(candidates: [CleanupCandidate],items: [StorageOpportunity],trashBytes: Int64?,trashIncomplete: Bool) -> [Recommendation] {
        var result: [Recommendation] = []
        let clean = candidates.filter { $0.rule != .installers }
        if !clean.isEmpty {
            result.append(Recommendation(id: "cleanup",kind: .cleanup,effort: .easy,title: "Clear old caches and logs",detail: "Old logs, cached downloads and inactive build files.",bytes: clean.reduce(0) { $0 + $1.bytes }))
        }
        if trashBytes == nil || trashBytes! >= 1_000_000 {
            result.append(Recommendation(id: "trash",kind: .trash,effort: .easy,title: "Empty Trash",detail: "Permanently remove files already in Trash.",bytes: trashBytes,incomplete: trashIncomplete))
        }
        let installers = candidates.filter { $0.rule == .installers }
        if !installers.isEmpty {
            result.append(Recommendation(id: "installers",kind: .installers,effort: .easy,title: "Review old installers",detail: "Keep any you may need to reinstall.",bytes: installers.reduce(0) { $0 + $1.bytes }))
        }
        var seen: Set<String> = []
        let sorted = items.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        for item in sorted {
            guard seen.insert(item.url.path).inserted,let bytes = item.bytes,bytes >= 100_000_000 else { continue }
            let key = "item:" + item.url.path
            if choices.contains(where: { $0.key == key }) { continue }
            if case .relocate = item.action, item.sourceStamp != nil {
                let target = destinations.first { (sourceDevice == nil || item.sourceStamp?.device == sourceDevice) && $0.fits(bytes,sourceGroup: sourceGroup) && !FileManager.default.fileExists(atPath: $0.folder(for: item).appendingPathComponent(item.name).path) }
                if let target {
                    result.append(Recommendation(id: key,kind: .move,effort: .worthwhile,title: "Move \(item.name)",detail: "To \(target.name). Keep it connected to use this file.",bytes: bytes,item: item,destination: target))
                } else {
                    result.append(Recommendation(id: key,kind: .manage,effort: .worthwhile,title: "Review \(item.name)",detail: destinations.isEmpty ? "A large personal file. Connect another disk to move it." : "No separate disk has enough space for this file.",bytes: bytes,item: item))
                }
            } else if bytes >= 2_000_000_000 {
                // Avoid offering a broad parent folder alongside the specific files already recommended.
                if item.category == .folders && sorted.contains(where: { $0.sourceStamp != nil && $0.url.path.hasPrefix(item.url.path + "/") }) { continue }
                let detail: String
                switch item.action {
                case .cache: detail = "Cached packages. Future builds may download them again."
                case .manager: detail = item.explanation
                default: detail = item.category == .applications ? "Check whether you still use this application." : "Review what’s inside before removing or moving it."
                }
                result.append(Recommendation(id: key,kind: .manage,effort: .worthwhile,title: "Review \(item.name)",detail: detail,bytes: bytes,incomplete: item.incomplete,item: item))
            }
        }
        return result.filter { rec in !choices.contains { $0.key == rec.id } }.sorted {
            if $0.effort != $1.effort { return $0.effort == .easy }
            return ($0.bytes ?? 0) > ($1.bytes ?? 0)
        }
    }
}

struct MoveRecord: Codable, Identifiable {
    let id: UUID
    let name: String
    let source: URL
    let destination: URL
    let stamp: CleanupStamp
    let bytes: Int64
    let date: Date
}

struct TrashEstimate {
    var bytes: Int64? = 0
    var incomplete = false
    static func scan(home: URL,destinations: [StorageDestination],cancelled: @escaping () -> Bool) -> Self {
        var result = Self(); var total: Int64 = 0; var unknown = false
        let roots = [home.appendingPathComponent(".Trash")] + destinations.map { $0.root.appendingPathComponent(".Trashes/\(getuid())") }
        var scanner = StorageScanner(home: home); scanner.cancelled = cancelled
        for root in roots {
            guard !cancelled() else { unknown = true; break }
            var info = stat()
            if lstat(root.path,&info) != 0 {
                if errno != ENOENT { unknown = true }
                continue
            }
            let size = scanner.measure(root)
            total += size.bytes; unknown = unknown || size.incomplete
        }
        result.bytes = unknown && total == 0 ? nil : total
        result.incomplete = unknown
        return result
    }
}

struct MoveStore {
    let url: URL
    func load() throws -> [MoveRecord] {
        if !FileManager.default.fileExists(atPath: url.path) { return [] }
        _ = try CleanupStamp.read(url)
        let records = try JSONDecoder().decode([MoveRecord].self,from: Data(contentsOf: url))
        guard records.allSatisfy({ $0.source.isFileURL && $0.destination.isFileURL && $0.source.path.hasPrefix("/") && $0.destination.path.hasPrefix("/") && $0.stamp.path == $0.destination.path && $0.bytes == $0.stamp.size && $0.name == $0.source.lastPathComponent && $0.name == $0.destination.lastPathComponent }) else { throw StorageFailure.changed }
        return records
    }
    func save(_ records: [MoveRecord]) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent,withIntermediateDirectories: true)
        guard ReviewedFile.canonicalPath(parent) == parent.path,!url.hasDirectoryPath else { throw StorageFailure.changed }
        let data = try JSONEncoder().encode(records)
        try data.write(to: url,options: .atomic)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try handle.synchronize()
    }
}
