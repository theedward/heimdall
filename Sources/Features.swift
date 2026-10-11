import Foundation
import Darwin

struct DiskReading {
    let total: Int64
    let free: Int64
    var occupied: Int64 { total - free }
    var fraction: Double { Double(occupied) / Double(total) }
    static func read(path: String = "/System/Volumes/Data") throws -> DiskReading {
        var info = statfs()
        guard statfs(path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain,code: Int(errno)) }
        let total = Int64(info.f_blocks) * Int64(info.f_bsize)
        let free = Int64(info.f_bavail) * Int64(info.f_bsize)
        guard total > 0, free >= 0, free <= total else { throw NSError(domain: "Heimdall",code: 1) }
        return DiskReading(total: total,free: free)
    }
}

struct DiskTarget: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    static let internalDisk = DiskTarget(id: "internal",name: "Internal disk",path: "/System/Volumes/Data")
    static func available() -> [DiskTarget] {
        let keys: Set<URLResourceKey> = [.volumeNameKey,.volumeUUIDStringKey,.volumeIsInternalKey,.volumeIsLocalKey,.volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),options: [.skipHiddenVolumes]) ?? []
        let external = urls.compactMap { url -> DiskTarget? in
            guard let v = try? url.resourceValues(forKeys: keys),v.volumeIsInternal == false,v.volumeIsLocal == true,v.volumeIsReadOnly != true else { return nil }
            return DiskTarget(id: v.volumeUUIDString ?? url.path,name: v.volumeName ?? url.lastPathComponent,path: url.path)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return [.internalDisk] + external
    }
}

struct AlertTracker: Codable {
    struct Entry: Codable { var level: Int; var lastAlert: Date? }
    var entries: [String: Entry] = [:]
    mutating func sample(id: String,freeGB: Double,warning: Int,critical: Int,now: Date = Date(),baseline: Bool = false) -> Int? {
        let current = freeGB < Double(critical) ? 2 : freeGB < Double(warning) ? 1 : 0
        guard !baseline,var entry = entries[id] else { entries[id] = Entry(level: current,lastAlert: nil); return nil }
        if freeGB >= Double(warning) + 2 { entry.level = 0 }
        else if entry.level == 2 && freeGB >= Double(critical) + 2 { entry.level = 1 }
        var result: Int?
        if current > entry.level {
            let previous = entry.level
            entry.level = current
            // Escalation to critical is immediate. Repeated threshold churn is quiet.
            if entry.lastAlert == nil || now.timeIntervalSince(entry.lastAlert!) >= 1800 || (current == 2 && previous == 1) {
                entry.lastAlert = now; result = current
            }
        }
        entries[id] = entry
        return result
    }
}

struct ReleaseVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ raw: String) {
        let value = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let fields = value.split(separator: ".",omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        parts = fields.map { Int($0)! }
    }
    static func < (lhs: Self,rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}
struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    let draft: Bool
    let prerelease: Bool
    static func parse(_ data: Data) throws -> (ReleaseVersion,String,URL) {
        guard data.count <= 524288 else { throw URLError(.dataLengthExceedsMaximum) }
        let release = try JSONDecoder().decode(Self.self,from: data)
        guard !release.draft,!release.prerelease,let version = ReleaseVersion(release.tag_name),
              let url = URL(string: release.html_url),let parts = URLComponents(url: url,resolvingAgainstBaseURL: false),
              parts.scheme == "https",parts.host == "github.com",parts.user == nil,parts.password == nil,parts.port == nil,
              parts.path == "/theedward/heimdall/releases/tag/\(release.tag_name)",parts.query == nil,parts.fragment == nil else { throw URLError(.badServerResponse) }
        return (version,release.tag_name,url)
    }
}
