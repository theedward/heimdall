import Foundation
import Darwin
import CryptoKit
import CoreServices

enum StorageCategory: String, CaseIterable {
    case downloads, documents, developer, applications, folders
    var title: String {
        switch self {
        case .developer: return "Developer tools"
        case .downloads: return "Downloads"
        case .documents: return "Documents"
        case .applications: return "Applications"
        case .folders: return "Large folders"
        }
    }
}
enum StorageManager: String { case gradle, jetBrains, unity, xcode }
enum CacheTool: String, Hashable { case npm, homebrew, swift }
enum StorageAction {
    case relocate
    case cache(CacheTool,URL)
    case manager(StorageManager)
    case reveal
    var title: String {
        switch self {
        case .relocate: return "Move file…"
        case .cache: return "Review tool cleanup…"
        case .manager: return "Manage…"
        case .reveal: return "Review in Finder"
        }
    }
}
struct StorageOpportunity: Identifiable {
    var id: String { category.rawValue + ":" + url.path }
    let url: URL
    let category: StorageCategory
    let name: String
    let bytes: Int64?
    let incomplete: Bool
    let explanation: String
    let action: StorageAction
    var sourceStamp: CleanupStamp? = nil
}
struct StorageInventory {
    var items: [StorageOpportunity] = []
    var notes: [String] = []
}
struct InventorySize {
    let bytes: Int64
    let incomplete: Bool
}

struct ToolDiscovery {
    var npm: URL?
    var homebrew: URL?
    var swift: URL?
    static func detect(home: URL) -> Self {
        let fm = FileManager.default
        func executable(_ paths: [String]) -> URL? {
            paths.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        }
        var npmPaths = ["/opt/homebrew/bin/npm","/usr/local/bin/npm",home.appendingPathComponent(".volta/bin/npm").path]
        let versions = home.appendingPathComponent(".nvm/versions/node")
        if let nodes = try? fm.contentsOfDirectory(at: versions,includingPropertiesForKeys: nil) {
            npmPaths += nodes.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }.map { $0.appendingPathComponent("bin/npm").path }
        }
        let selected = URL(fileURLWithPath: "/var/db/xcode_select_link").resolvingSymlinksInPath().appendingPathComponent("usr/bin/swift")
        let swiftAvailable = fm.isExecutableFile(atPath: selected.path) || fm.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/swift")
        return Self(npm: executable(npmPaths),homebrew: executable(["/opt/homebrew/bin/brew","/usr/local/bin/brew"]),swift: swiftAvailable ? executable(["/usr/bin/xcrun"]) : nil)
    }
}

struct StorageScanner {
    let home: URL
    var applicationRoots: [URL] = [URL(fileURLWithPath: "/Applications")]
    var additionalRoots: [URL] = []
    var tools = ToolDiscovery()
    var reportedCacheLocations: [CacheTool: URL] = [:]
    var minimumLargeBytes: Int64 = 500_000_000
    var minimumAppBytes: Int64 = 100_000_000
    var minimumCacheBytes: Int64 = 1_000_000
    var minimumDocumentBytes: Int64 = 100_000_000
    var minimumOldDownloadBytes: Int64 = 5_000_000
    var now = Date()
    var lastUsed: (URL) -> Date? = { file in
        MDItemCreate(kCFAllocatorDefault,file.path as CFString).flatMap { MDItemCopyAttribute($0,kMDItemLastUsedDate) as? Date }
    }
    var maximumEntries = 30_000
    var cancelled: () -> Bool = { false }
    // Supplied by the native app. Fixtures inject JSON, never invoke real cleanup commands.
    var simulatorInventory: () throws -> Data = { Data("{}".utf8) }

    func measure(_ url: URL) -> InventorySize {
        var bytes: Int64 = 0; var count = 0; var incomplete = false
        let keys: Set<URLResourceKey> = [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.isUbiquitousItemKey]
        do {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { return InventorySize(bytes: 0,incomplete: true) }
            if values.isRegularFile == true { return InventorySize(bytes: Int64(values.fileSize ?? 0),incomplete: false) }
            guard values.isDirectory == true else { return InventorySize(bytes: 0,incomplete: true) }
            guard let walker = FileManager.default.enumerator(at: url,includingPropertiesForKeys: Array(keys),options: [],errorHandler: { _,_ in incomplete = true; return true }) else { return InventorySize(bytes: 0,incomplete: true) }
            for case let child as URL in walker {
                count += 1
                guard count <= maximumEntries,!cancelled() else { incomplete = true; break }
                do {
                    let entry = try child.resourceValues(forKeys: keys)
                    if entry.isSymbolicLink == true { walker.skipDescendants(); continue }
                    if entry.isRegularFile == true {
                        let sum = bytes.addingReportingOverflow(Int64(entry.fileSize ?? 0))
                        guard !sum.overflow else { incomplete = true; break }
                        bytes = sum.partialValue
                    }
                } catch { incomplete = true; walker.skipDescendants() }
            }
        } catch { incomplete = true }
        return InventorySize(bytes: bytes,incomplete: incomplete)
    }
    static func simulatorItems(_ data: Data) throws -> [StorageOpportunity] {
        guard data.count <= 2_000_000,let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { throw CleanupFailure.unsupported }
        return dictionary.sorted { $0.key < $1.key }.compactMap { id,entry in
            guard UUID(uuidString: id) != nil,let path = entry["runtimeBundlePath"] as? String,path.hasPrefix("/"),let version = entry["version"] as? String else { return nil }
            let platform = (entry["platformIdentifier"] as? String ?? "Simulator").replacingOccurrences(of: "com.apple.platform.",with: "")
            let lastUsed = entry["lastUsedAt"] as? String
            let usage = lastUsed.map { "Last used: \($0)." } ?? "Last use is unknown."
            return StorageOpportunity(url: URL(fileURLWithPath: path),category: .developer,name: "\(platform) \(version) runtime",bytes: (entry["sizeBytes"] as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.int64Value : nil },incomplete: false,explanation: "Installed runtime. \(usage) Review project requirements before uninstalling in Xcode Settings → Components/Platforms. Simulator devices can depend on it.",action: .manager(.xcode))
        }
    }
    func scan() -> StorageInventory {
        var result = StorageInventory()
        let fm = FileManager.default
        func append(_ url: URL,_ category: StorageCategory,_ name: String,_ explanation: String,_ action: StorageAction,_ minimum: Int64) {
            guard !cancelled(),fm.fileExists(atPath: url.path) else { return }
            let size = measure(url)
            if size.incomplete && size.bytes == 0 { result.notes.append("\(name): size unavailable or scan limit reached."); return }
            guard size.bytes >= minimum || (size.incomplete && size.bytes > 0) else { return }
            result.items.append(StorageOpportunity(url: url,category: category,name: name,bytes: size.bytes,incomplete: size.incomplete,explanation: explanation,action: action))
        }
        let cacheLocations: [(String,String,CacheTool,URL?)] = [
            (".npm","npm cache",.npm,tools.npm),
            ("Library/Caches/Homebrew","Homebrew cache",.homebrew,tools.homebrew),
            ("Library/Caches/org.swift.swiftpm","Swift package cache",.swift,tools.swift),
            (".cache/org.swift.swiftpm","Swift package cache",.swift,tools.swift)
        ]
        var scannedCaches: Set<String> = []
        for (path,name,kind,tool) in cacheLocations {
            let url = home.appendingPathComponent(path)
            guard scannedCaches.insert(url.path).inserted else { continue }
            let action: StorageAction = tool.map { .cache(kind,$0) } ?? .reveal
            append(url,.developer,name,"Recreatable package cache. Cleanup requires its installed tool and your confirmation; later builds may download dependencies again. Reported folder size is not a promise of space reclaimed.",action,minimumCacheBytes)
        }
        for kind in [CacheTool.npm,.homebrew] {
            guard let url = reportedCacheLocations[kind],scannedCaches.insert(url.path).inserted else { continue }
            let tool = kind == .npm ? tools.npm : tools.homebrew
            append(url,.developer,"\(kind.rawValue) configured cache","Cache location reported by the installed tool. Cleanup requires your confirmation; reported size is not guaranteed reclaimable space.",tool.map { .cache(kind,$0) } ?? .reveal,minimumCacheBytes)
        }
        append(home.appendingPathComponent(".gradle/caches"),.developer,"Gradle cache","Gradle manages retention and cleanup in Gradle User Home. Review the documented policy instead of deleting cache internals during a build.",.manager(.gradle),minimumCacheBytes)
        let jetBrains = home.appendingPathComponent("Library/Caches/JetBrains")
        if let versions = try? fm.contentsOfDirectory(at: jetBrains,includingPropertiesForKeys: nil) {
            for version in versions.prefix(100) { append(version,.developer,"JetBrains: \(version.lastPathComponent)","IDE caches may include Local History. Review Help → Delete Leftover IDE Directories or File → Invalidate Caches in the IDE; usage is not inferred from folder age.",.manager(.jetBrains),minimumCacheBytes) }
        }
        // Typical locations are defaults. Add folder lets users scan custom installations or another volume.
        for root in applicationRoots {
            let unity = root.appendingPathComponent("Unity/Hub/Editor")
            if let editors = try? fm.contentsOfDirectory(at: unity,includingPropertiesForKeys: nil) {
                for editor in editors.prefix(100) { append(editor,.developer,"Unity editor \(editor.lastPathComponent)","Installed editor; usage is unknown. Check your projects' required versions and uninstall through Unity Hub → Installs.",.manager(.unity),minimumCacheBytes) }
            }
        }
        if !cancelled(),tools.swift != nil {
            do { result.items += try Self.simulatorItems(simulatorInventory()) }
            catch { result.notes.append("Simulator inventory unavailable. Use Xcode Settings to review installed runtimes.") }
        }
        let fileKeys: Set<URLResourceKey> = [.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.isPackageKey,.fileSizeKey,.creationDateKey,.contentModificationDateKey,.isUbiquitousItemKey,.ubiquitousItemDownloadingStatusKey]
        func inspectFile(_ file: URL,category: StorageCategory) throws {
            let values = try file.resourceValues(forKeys: fileKeys)
            guard values.isRegularFile == true,values.isSymbolicLink != true else { return }
            // Inventory must not materialize online-only iCloud documents or offer them for relocation.
            if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current { return }
            let bytes = Int64(values.fileSize ?? 0)
            let minimum = category == .documents ? minimumDocumentBytes : minimumLargeBytes
            guard bytes >= minimum || (category == .downloads && bytes >= minimumOldDownloadBytes) else { return }
            let dates = [values.creationDate,values.contentModificationDate].compactMap { $0 }
            // Finder's last-used metadata is optional. Missing evidence never means unused.
            let used = category == .downloads ? lastUsed(file) : nil
            let latest = (dates + [used].compactMap { $0 }).max()
            let old = category == .downloads && dates.count == 2 && latest.map { $0 < now.addingTimeInterval(-90 * 86400) } == true
            guard bytes >= minimum || (old && bytes >= minimumOldDownloadBytes) else { return }
            let kind: String
            switch file.pathExtension.lowercased() {
            case "dmg","pkg": kind = "Installer — keep it if you may need to reinstall."
            case "zip","rar","7z","tar","gz": kind = "Archive — it may contain your only copy of important files."
            case "mp4","mov","mkv","avi","m4v": kind = "Video — moving it to another disk may be useful."
            default: kind = "Personal file — check that you no longer need it before removing it."
            }
            var explanation = kind
            if old {
                explanation += " Created and modified over 90 days ago." + (used == nil ? " Last opened is unknown." : " No recorded opening in the last 90 days.") + " Age does not prove it is unused."
            }
            explanation += " Move it to another folder or review removal to Trash. Nothing is selected automatically."
            let stamp = try? CleanupStamp.read(file)
            result.items.append(StorageOpportunity(url: file,category: category,name: file.lastPathComponent,bytes: bytes,incomplete: false,explanation: explanation,action: stamp == nil ? .reveal : .relocate,sourceStamp: stamp))
        }
        var seenRoots: Set<String> = []
        for root in [home.appendingPathComponent("Downloads")] + additionalRoots {
            guard seenRoots.insert(root.standardizedFileURL.path).inserted,!cancelled(),fm.fileExists(atPath: root.path) else { continue }
            do {
                let entries = try fm.contentsOfDirectory(at: root,includingPropertiesForKeys: Array(fileKeys),options: [.skipsHiddenFiles])
                for file in entries.prefix(maximumEntries) {
                    guard !cancelled() else { break }
                    do { try inspectFile(file,category: .downloads) } catch { result.notes.append("Could not read \(file.lastPathComponent).") }
                }
                if entries.count > maximumEntries { result.notes.append("\(root.lastPathComponent): entry limit reached.") }
            } catch { result.notes.append("\(root.lastPathComponent): folder access unavailable.") }
        }
        let documents = home.appendingPathComponent("Documents")
        if fm.fileExists(atPath: documents.path),!cancelled() {
            var failed = false; var count = 0
            if let walker = fm.enumerator(at: documents,includingPropertiesForKeys: Array(fileKeys),options: [.skipsHiddenFiles,.skipsPackageDescendants],errorHandler: { _,_ in failed = true; return true }) {
                for case let file as URL in walker {
                    count += 1
                    guard count <= maximumEntries,!cancelled() else { result.notes.append("Documents scan stopped early. Some files may be missing from this list."); break }
                    do {
                        let values = try file.resourceValues(forKeys: fileKeys)
                        if values.isSymbolicLink == true || values.isPackage == true { walker.skipDescendants(); continue }
                        try inspectFile(file,category: .documents)
                    } catch { failed = true; walker.skipDescendants() }
                }
            } else { failed = true }
            if failed { result.notes.append("Some Documents folders could not be read. Check access in macOS Privacy & Security.") }
        }
        for root in applicationRoots + [home.appendingPathComponent("Applications")] + additionalRoots {
            guard !cancelled(),fm.fileExists(atPath: root.path) else { continue }
            if let apps = try? fm.contentsOfDirectory(at: root,includingPropertiesForKeys: nil,options: [.skipsHiddenFiles]) {
                for app in apps.prefix(300) where app.pathExtension.lowercased() == "app" {
                    append(app,.applications,app.deletingPathExtension().lastPathComponent,"Installed application; usage is unknown. Review in Finder or use the publisher's uninstaller. Removing an app may leave its data and subscriptions. Active games and personal apps are never selected automatically.",.reveal,minimumAppBytes)
                }
            } else { result.notes.append("Application folder access unavailable: \(root.path)") }
        }
        for root in additionalRoots {
            guard !cancelled(),let entries = try? fm.contentsOfDirectory(at: root,includingPropertiesForKeys: nil,options: [.skipsHiddenFiles]) else { continue }
            for entry in entries.prefix(100) where fm.fileExists(atPath: entry.appendingPathComponent("Unity.app/Contents/MacOS/Unity").path) {
                append(entry,.developer,"Unity editor \(entry.lastPathComponent)","Editor found in a user-selected location. Usage is unknown; review project requirements and uninstall through Unity Hub.",.manager(.unity),minimumCacheBytes)
            }
        }
        let folderRoots = ["Documents","Desktop","Downloads","Movies","Music","Pictures","Library/Application Support","Library/Caches"].map { home.appendingPathComponent($0) } + additionalRoots
        var seenFolders: Set<String> = []
        for root in folderRoots {
            guard !cancelled(),fm.fileExists(atPath: root.path) else { continue }
            do {
                let folders = try fm.contentsOfDirectory(at: root,includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey],options: [.skipsHiddenFiles])
                for folder in folders.prefix(300) {
                    guard !cancelled(),seenFolders.insert(folder.path).inserted else { continue }
                    let values = try folder.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
                    guard values.isDirectory == true,values.isSymbolicLink != true else { continue }
                    append(folder,.folders,folder.lastPathComponent,"Large folder for manual review. It may be a project, game, media library or managed app data. Moving it can break references; choose a supported relocation method in its app or review it in Finder.",.reveal,minimumLargeBytes)
                }
            } catch { result.notes.append("\(root.lastPathComponent): folder access unavailable.") }
        }
        var seen: Set<String> = []
        result.items = result.items.filter { seen.insert($0.id).inserted }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        if cancelled() { result.notes.append("Storage inventory stopped early; results may be incomplete.") }
        return result
    }
}

struct ToolCommand {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    var display: String { ([executable.path] + arguments).map { $0.debugDescription }.joined(separator: " ") }
}
struct ToolCleanupPlan {
    let tool: CacheTool
    let executable: URL
    let cache: URL
    var explanation: String {
        switch tool {
        case .npm: return "Permanently clears npm's recreatable package cache at this path. There is no dry-run or Trash recovery. Later installs may download packages again."
        case .homebrew: return "Homebrew removes old downloads (30 days) and old installed formula versions. The dry-run below covers a broader scope than just this cache folder. Tool cleanup is permanent and may require downloads later."
        case .swift: return "Purges SwiftPM's global repository cache at this path. It does not reset source projects; the tool may clear only part of the measured cache. Later builds may download dependencies again. There is no Trash recovery."
        }
    }
    func command(dryRun: Bool = false) -> ToolCommand? {
        guard cache.isFileURL,cache.path.hasPrefix("/"),!dryRun || tool == .homebrew else { return nil }
        var arguments: [String]
        var environment: [String: String] = [:]
        switch tool {
        case .npm: arguments = ["cache","clean","--force","--cache",cache.path]
        case .homebrew:
            arguments = ["cleanup","--prune=30"] + (dryRun ? ["--dry-run"] : [])
            environment = ["HOMEBREW_NO_AUTO_UPDATE":"1","HOMEBREW_NO_ANALYTICS":"1","HOMEBREW_CACHE":cache.path]
        case .swift: arguments = ["swift","package","--cache-path",cache.path,"purge-cache"]
        }
        return ToolCommand(executable: executable,arguments: arguments,environment: environment)
    }
}
struct ToolOutput { let status: Int32; let text: String; let truncated: Bool }
struct ToolRunner {
    var timeout: TimeInterval = 30
    var maximumOutputBytes = 262144
    func run(_ command: ToolCommand) throws -> ToolOutput {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heimdall-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output.txt")
        FileManager.default.createFile(atPath: output.path,contents: nil)
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let process = Process(); process.executableURL = command.executable; process.arguments = command.arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment.merge(command.environment) { _,new in new }
        environment["PATH"] = command.executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment; process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.2); if process.isRunning { kill(process.processIdentifier,SIGKILL) }; throw StorageFailure.timeout }
        process.waitUntilExit(); try handle.synchronize()
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        let reader = try FileHandle(forReadingFrom: output); defer { try? reader.close() }
        let data = try reader.read(upToCount: maximumOutputBytes) ?? Data()
        return ToolOutput(status: process.terminationStatus,text: String(decoding: data,as: UTF8.self),truncated: size > maximumOutputBytes)
    }
}
enum StorageFailure: Error, LocalizedError {
    case changed, invalidDestination, collision, insufficientSpace, timeout, copyKept(String)
    var errorDescription: String? {
        switch self {
        case .changed: return "The file or destination changed. Scan and choose a destination again."
        case .invalidDestination: return "Choose an accessible folder separate from the source folder."
        case .collision: return "A file with this name already exists at the destination. Nothing was overwritten."
        case .insufficientSpace: return "The destination does not have enough available space for the copy and a 256 MB margin."
        case .timeout: return "The tool exceeded its time limit. Review its state before retrying."
        case .copyKept(let path): return "Verified copy kept at \(path). The original could not be moved to Trash and remains in place."
        }
    }
}
struct RelocationResult { let destination: URL; let sameVolume: Bool }
enum ReviewedFile {
    static func canonicalPath(_ url: URL) -> String? {
        guard let pointer = realpath(url.path,nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
    static func validate(_ item: StorageOpportunity,roots: [URL]) throws {
        guard case .relocate = item.action,let stamp = item.sourceStamp,!stamp.isDirectory,
              canonicalPath(item.url) == item.url.path,
              try CleanupStamp.read(item.url) == stamp else { throw StorageFailure.changed }
        let allowed = roots.contains { root in
            guard let base = canonicalPath(root) else { return false }
            return item.url.path.hasPrefix(base + "/")
        }
        guard allowed else { throw CleanupFailure.outsideScope }
    }
    static func moveToTrash(_ item: StorageOpportunity,roots: [URL],using trash: (URL) throws -> Void) throws {
        try validate(item,roots: roots)
        try trash(item.url)
    }
}
struct FileRelocator {
    let allowedRoots: [URL]
    var freeBytes: (URL) throws -> Int64 = { try DiskReading.read(path: $0.path).free }
    var cancelled: () -> Bool = { false }
    static func isSameVolume(_ item: StorageOpportunity,destination: URL) -> Bool? {
        var info = stat()
        guard stat(destination.path,&info) == 0,let stamp = item.sourceStamp else { return nil }
        return info.st_dev == stamp.device
    }
    private func canonical(_ url: URL) throws -> URL {
        guard let pointer = realpath(url.path,nil) else { throw StorageFailure.changed }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer))
    }
    func relocate(_ item: StorageOpportunity,to folder: URL,trash: (URL) throws -> Void) throws -> RelocationResult {
        guard case .relocate = item.action,let stamp = item.sourceStamp,!stamp.isDirectory else { throw StorageFailure.changed }
        let source = try canonical(item.url)
        try ReviewedFile.validate(item,roots: allowedRoots)
        guard source.path == item.url.path,try CleanupStamp.read(source) == stamp else { throw StorageFailure.changed }
        let destinationFolder = try canonical(folder)
        var parent = stat()
        guard lstat(destinationFolder.path,&parent) == 0,parent.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR),destinationFolder.path != source.deletingLastPathComponent().path else { throw StorageFailure.invalidDestination }
        let target = destinationFolder.appendingPathComponent(source.lastPathComponent)
        var targetInfo = stat()
        guard !FileManager.default.fileExists(atPath: target.path),lstat(target.path,&targetInfo) != 0 else { throw StorageFailure.collision }
        guard try freeBytes(destinationFolder) >= stamp.size + 256_000_000 else { throw StorageFailure.insufficientSpace }
        let temporary = destinationFolder.appendingPathComponent(".heimdall-copy-\(UUID().uuidString)")
        var promoted = false
        defer { if !promoted { try? FileManager.default.removeItem(at: temporary) } }
        // Foundation copies native file metadata as well as the data fork.
        try FileManager.default.copyItem(at: source,to: temporary)
        let inputFD = open(source.path,O_RDONLY | O_NOFOLLOW)
        guard inputFD >= 0 else { throw StorageFailure.changed }
        let reader = FileHandle(fileDescriptor: inputFD,closeOnDealloc: true); defer { try? reader.close() }
        var inputInfo = stat()
        guard fstat(inputFD,&inputInfo) == 0,inputInfo.st_ino == stamp.inode,inputInfo.st_dev == stamp.device else { throw StorageFailure.changed }
        var hash = SHA256(); var copied: Int64 = 0
        while let chunk = try reader.read(upToCount: 4 * 1024 * 1024),!chunk.isEmpty {
            guard !cancelled() else { throw StorageFailure.changed }
            hash.update(data: chunk); copied += Int64(chunk.count)
        }
        let verificationFD = open(temporary.path,O_RDONLY | O_NOFOLLOW)
        guard verificationFD >= 0 else { throw StorageFailure.changed }
        let verification = FileHandle(fileDescriptor: verificationFD,closeOnDealloc: true); defer { try? verification.close() }
        var verifiedHash = SHA256()
        while let chunk = try verification.read(upToCount: 4 * 1024 * 1024),!chunk.isEmpty {
            guard !cancelled() else { throw StorageFailure.changed }
            verifiedHash.update(data: chunk)
        }
        var freshParent = stat()
        guard copied == stamp.size,hash.finalize() == verifiedHash.finalize(),try CleanupStamp.read(source) == stamp,lstat(destinationFolder.path,&freshParent) == 0,freshParent.st_ino == parent.st_ino,freshParent.st_dev == parent.st_dev else { throw StorageFailure.changed }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw StorageFailure.collision }
        guard renamex_np(temporary.path,target.path,UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw StorageFailure.collision }
            throw NSError(domain: NSPOSIXErrorDomain,code: Int(errno))
        }
        promoted = true
        do { guard try CleanupStamp.read(source) == stamp else { throw StorageFailure.changed }; try trash(source) }
        catch { throw StorageFailure.copyKept(target.path) }
        return RelocationResult(destination: target,sameVolume: parent.st_dev == stamp.device)
    }
}
