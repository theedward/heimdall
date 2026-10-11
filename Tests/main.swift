import Foundation
import Darwin
var checks = 0
func expect(_ condition: @autoclosure () -> Bool,_ message: String) {
    checks += 1
    guard condition() else { fatalError(message) }
}
var tracker = AlertTracker()
let start = Date(timeIntervalSince1970: 1_000_000)
func sample(_ free: Double,_ seconds: Double = 0,_ id: String = "internal",baseline: Bool = false) -> Int? {
    tracker.sample(id: id,freeGB: free,warning: 60,critical: 25,now: start.addingTimeInterval(seconds),baseline: baseline)
}
expect(sample(100) == nil,"Initial readings are quiet")
expect(sample(60) == nil,"Exact warning threshold is healthy")
expect(sample(59) == 1,"Crossing warning alerts")
expect(sample(58) == nil,"Stable warning does not repeat")
expect(sample(60.5) == nil,"Small recovery is quiet")
expect(sample(59,1900) == nil,"Hysteresis prevents boundary churn even after cooldown")
expect(sample(24,1901) == 2,"Critical escalation alerts immediately")
expect(sample(25.5,1902) == nil,"Small critical recovery is quiet")
expect(sample(24,3800) == nil,"Critical hysteresis prevents repeat")
expect(sample(100,3801) == nil,"Full recovery rearms alerts")
expect(sample(59,3802) == 1,"Warning after recovery and cooldown alerts")
expect(sample(100,3803) == nil,"Recovery")
expect(sample(59,3804) == nil,"Cooldown limits repeated warnings")
expect(sample(24,3805) == 2,"Critical escalation bypasses warning cooldown")
expect(sample(10,0,"external") == nil,"New low-space disk starts quietly")
expect(sample(5,1,"external") == nil,"Stable low-space disk stays quiet")
expect(sample(100,2,"external",baseline: true) == nil,"Permission or preset changes reset baseline")
expect(sample(59,3,"external") == 1,"Each disk has independent alerts")
let saved = try JSONEncoder().encode(tracker)
let restored = try JSONDecoder().decode(AlertTracker.self,from: saved)
expect(restored.entries["external"]?.level == 1,"Tracker persists levels")
expect(restored.entries["external"]?.lastAlert == start.addingTimeInterval(3),"Tracker persists cooldown")
expect(ReleaseVersion("v1.10.0")! > ReleaseVersion("1.2.0")!,"Versions compare numerically")
expect(ReleaseVersion("1.2.0")! == ReleaseVersion("v1.2.0")!,"Tag prefix accepted")
for raw in ["1.2","1.2.3.4","1.2.-1","1.2.3-beta","1..2","1.2.9999999","１.2.3"] {
    expect(ReleaseVersion(raw) == nil,"Malformed version rejected: \(raw)")
}
func release(_ url: String = "https://github.com/theedward/heimdall/releases/tag/v1.2.0",draft: Bool = false,prerelease: Bool = false) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["tag_name":"v1.2.0","html_url":url,"draft":draft,"prerelease":prerelease])
}
expect((try? GitHubRelease.parse(release()))?.1 == "v1.2.0","Valid stable release accepted")
for url in ["http://github.com/theedward/heimdall/releases/tag/v1.2.0","https://evil.example/theedward/heimdall/releases/tag/v1.2.0","https://github.com/other/project/releases/tag/v1.2.0","https://user@github.com/theedward/heimdall/releases/tag/v1.2.0","https://github.com/theedward/heimdall/releases/tag/v9.0.0","https://github.com/theedward/heimdall/releases/tag/v1.2.0?redirect=evil"] {
    expect((try? GitHubRelease.parse(release(url))) == nil,"Unexpected release URL rejected")
}
expect((try? GitHubRelease.parse(release(draft: true))) == nil,"Draft rejected")
expect((try? GitHubRelease.parse(release(prerelease: true))) == nil,"Prerelease rejected")
expect((try? GitHubRelease.parse(Data("{}".utf8))) == nil,"Missing fields rejected")
expect((try? GitHubRelease.parse(Data(repeating: 32,count: 524289))) == nil,"Oversized response rejected")
expect((try? DiskReading.read(path: "/nonexistent-heimdall-test-volume")) == nil,"Missing disk must not fall back to internal storage")
print("Passed \(checks) checks: alert transitions, recovery, cooldown, persistence, versions and release validation.")

// Cleanup tests use a disposable home and an injected Trash destination.
// They never scan or remove anything from the real user's folders or Trash.
let fixtureAlias = FileManager.default.temporaryDirectory.appendingPathComponent("heimdall-fixture-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: fixtureAlias,withIntermediateDirectories: true)
let canonicalFixture = realpath(fixtureAlias.path,nil)!
let fixture = URL(fileURLWithPath: String(cString: canonicalFixture))
free(canonicalFixture)
defer { try? FileManager.default.removeItem(at: fixture) }
let fixtureNow = Date().addingTimeInterval(45 * 86400)
func fixtureFile(_ path: String,_ recent: Bool = false) throws -> URL {
    let url = fixture.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true)
    try Data(repeating: 42,count: 1024).write(to: url)
    if recent { try FileManager.default.setAttributes([.modificationDate: fixtureNow],ofItemAtPath: url.path) }
    return url
}
let oldInstaller = try fixtureFile("Downloads/old.dmg")
let currentInstaller = try fixtureFile("Downloads/current.pkg",true)
let archive = try fixtureFile("Downloads/books.zip")
let document = try fixtureFile("Downloads/important.txt")
let nestedInstaller = try fixtureFile("Downloads/keep/nested.dmg")
let log = try fixtureFile("Library/Logs/app/old.log")
_ = try fixtureFile("Library/Logs/app/current.log",true)
_ = try fixtureFile("Library/Logs/app/config.json")
let buildFile = try fixtureFile("Library/Developer/Xcode/DerivedData/TestProject/Build/output")
let activeBuild = try fixtureFile("Library/Developer/Xcode/DerivedData/ActiveProject/Build/output",true)
_ = try fixtureFile("Projects/MyProject/source.swift")
let outside = try fixtureFile("Other/do-not-touch.dmg")
let symlink = fixture.appendingPathComponent("Downloads/linked.dmg")
try FileManager.default.createSymbolicLink(at: symlink,withDestinationURL: outside)
let hardlink = fixture.appendingPathComponent("Downloads/hardlink.dmg")
try FileManager.default.linkItem(at: outside,to: hardlink)
var cleaner = CleanupEngine(home: fixture,now: fixtureNow,minimumBytes: 1)
let initialScan = cleaner.scan()
expect(initialScan.candidates.count == 3,"Only one old installer, one old log and inactive build folder are eligible")
expect(initialScan.candidates.contains { $0.url == oldInstaller },"Old installer included")
expect(initialScan.candidates.contains { $0.url == log },"Nested old log included")
expect(!initialScan.candidates.contains { $0.url == currentInstaller || $0.url == archive || $0.url == document || $0.url == nestedInstaller || $0.url == symlink || $0.url == hardlink },"Recent files, archives, documents, nested downloads and links excluded")
expect(!initialScan.candidates.contains { $0.url.path.contains("ActiveProject") },"A recent descendant makes build data ineligible")
let candidate = initialScan.candidates.first { $0.url == oldInstaller }!
try cleaner.revalidate(candidate)
expect(true,"Unchanged candidate revalidates")
try Data(repeating: 12,count: 2048).write(to: oldInstaller)
expect((try? cleaner.revalidate(candidate)) == nil,"Content changes invalidate a reviewed item")
var attemptedTrash = false
expect((try? cleaner.moveToTrash(candidate,using: { _ in attemptedTrash = true })) == nil && !attemptedTrash,"Changed candidate never reaches Trash")
let forged = CleanupCandidate(url: outside,rule: .installers,bytes: 1024,modified: Date(),snapshot: [])
expect((try? cleaner.revalidate(forged)) == nil,"Forged out-of-scope candidate rejected")
cleaner.xcodeRunning = { true }
expect(!cleaner.scan().candidates.contains { $0.rule == .derivedData },"Running Xcode prevents build-data candidates")
let buildCandidate = initialScan.candidates.first { $0.rule == .derivedData }!
expect((try? cleaner.revalidate(buildCandidate)) == nil,"Xcode launch after scan prevents moving build data")
cleaner.xcodeRunning = { false }
try FileManager.default.createSymbolicLink(at: buildFile.deletingLastPathComponent().appendingPathComponent("link"),withDestinationURL: outside)
expect((try? cleaner.revalidate(buildCandidate)) == nil,"A new symlink in build data invalidates the item")
let unchangedLog = initialScan.candidates.first { $0.url == log }!
let fakeTrash = fixture.appendingPathComponent("TestTrash")
try FileManager.default.createDirectory(at: fakeTrash,withIntermediateDirectories: true)
try cleaner.moveToTrash(unchangedLog) { url in try FileManager.default.moveItem(at: url,to: fakeTrash.appendingPathComponent(url.lastPathComponent)) }
expect(!FileManager.default.fileExists(atPath: log.path) && FileManager.default.fileExists(atPath: fakeTrash.appendingPathComponent("old.log").path),"Approved unchanged file moves using injected Trash operation")
let savedDownloads = fixture.appendingPathComponent("SavedDownloads")
try FileManager.default.moveItem(at: fixture.appendingPathComponent("Downloads"),to: savedDownloads)
try FileManager.default.createSymbolicLink(at: fixture.appendingPathComponent("Downloads"),withDestinationURL: savedDownloads)
expect(!cleaner.scan().candidates.contains { $0.rule == .installers },"Linked cleanup root is skipped")
expect((try? cleaner.revalidate(candidate)) == nil,"Ancestor replacement prevents removal")
var limited = CleanupEngine(home: fixture,now: fixtureNow,minimumBytes: 1,maximumEntries: 1)
expect(!limited.scan().candidates.contains { $0.rule == .derivedData },"Oversized folders are skipped rather than partially removed")
limited.cancelled = { true }
expect(limited.scan().candidates.isEmpty,"Cancellation stops scanning")
expect(FileManager.default.fileExists(atPath: archive.path.replacingOccurrences(of: "/Downloads/",with: "/SavedDownloads/")),"Book archive survives all cleanup tests")
print("Passed \(checks) total checks, including cleanup scope, age, symlinks, hard links, busy Xcode, changed items, cancellation and review-to-Trash validation.")

let realTimeCleaner = CleanupEngine(home: fixture,minimumBytes: 1)
try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86400)],ofItemAtPath: activeBuild.path)
expect(realTimeCleaner.scan().candidates.isEmpty,"Newly created files stay excluded even with ancient modification timestamps")
let rotatedLog = try fixtureFile("Library/Logs/app/old.log.1")
let misleadingLog = try fixtureFile("Library/Logs/app/important.log.json")
expect(cleaner.scan().candidates.contains { $0.url.path == rotatedLog.path },"Numbered rotated log included")
expect(!cleaner.scan().candidates.contains { $0.url.path == misleadingLog.path },"A log-like name does not make JSON configuration eligible")
print("Passed \(checks) total checks.")

// General storage behavior is tested on a Mac-shaped fixture, with no external drive.
let genericHome = fixture.appendingPathComponent("GenericHome")
try FileManager.default.createDirectory(at: genericHome,withIntermediateDirectories: true)
func storageFile(_ relative: String,_ bytes: Int = 2048) throws -> URL {
    let url = genericHome.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true)
    try Data(repeating: 17,count: bytes).write(to: url)
    return url
}
let largeArchive = try storageFile("Downloads/valuable-library.zip")
_ = try storageFile(".npm/_cacache/content-v2/cache")
_ = try storageFile("Library/Caches/Homebrew/downloads/bottle")
_ = try storageFile("Library/Caches/org.swift.swiftpm/repositories/cache")
_ = try storageFile(".gradle/caches/modules-2/dependency")
_ = try storageFile("Library/Caches/JetBrains/ExampleIDE/cache")
_ = try storageFile("Applications/Example.app/Contents/binary")
_ = try storageFile("Applications/Unity/Hub/Editor/ExampleVersion/Unity.app/Contents/binary")
_ = try storageFile("Documents/Project/.git/objects/object")
let extraRoot = fixture.appendingPathComponent("AnyChosenLocation")
try FileManager.default.createDirectory(at: extraRoot,withIntermediateDirectories: true)
let extraFile = extraRoot.appendingPathComponent("movie.mp4")
try Data(repeating: 55,count: 2048).write(to: extraFile)
var inventoryScanner = StorageScanner(home: genericHome,applicationRoots: [genericHome.appendingPathComponent("Applications")],additionalRoots: [extraRoot],minimumLargeBytes: 128,minimumAppBytes: 128,minimumCacheBytes: 128)
var inventory = inventoryScanner.scan()
expect(inventory.items.contains { $0.url.path == largeArchive.path && $0.category == .downloads },"Large archive is offered for relocation, not classified as disposable")
expect(inventory.items.contains { $0.url.path == extraFile.path },"User-selected location works without an external SSD")
expect(inventory.items.contains { $0.name == "Gradle cache" },"Gradle cache discovered")
expect(inventory.items.contains { $0.name.hasPrefix("JetBrains:") },"JetBrains cache discovered")
expect(inventory.items.contains { $0.name == "Unity editor ExampleVersion" },"Unity editor version discovered")
expect(inventory.items.contains { $0.name == "Example" && $0.category == .applications },"Installed app inventoried without claiming unused")
expect(inventory.items.contains { $0.name == "Project" && $0.category == .folders },"Large source project is review-only inventory")
let cacheWithoutTool = inventory.items.first { $0.name == "npm cache" }!
if case .reveal = cacheWithoutTool.action { expect(true,"Missing tool falls back to Finder review") } else { expect(false,"Missing tool must not expose a cleanup command") }
let runtimeJSON = Data("""
{"12345678-1234-1234-1234-123456789ABC":{"runtimeBundlePath":"/Library/Developer/Example.simruntime","version":"1.0","sizeBytes":8000000000,"platformIdentifier":"com.apple.platform.example","lastUsedAt":"2026-01-01T00:00:00Z"}}
""".utf8)
let runtimeItems = try StorageScanner.simulatorItems(runtimeJSON)
expect(runtimeItems.count == 1 && runtimeItems[0].bytes == 8_000_000_000,"Simulator metadata preserves reported size")
expect(runtimeItems[0].explanation.contains("Last used:"),"Last-use evidence displayed without guessing inactivity")
expect((try? StorageScanner.simulatorItems(Data("[]".utf8))) == nil,"Unknown runtime JSON format rejected")
inventoryScanner.tools = ToolDiscovery(npm: URL(fileURLWithPath: "/usr/bin/true"),homebrew: nil,swift: URL(fileURLWithPath: "/usr/bin/true"))
inventoryScanner.simulatorInventory = { runtimeJSON }
inventory = inventoryScanner.scan()
expect(inventory.items.contains { $0.name.contains("runtime") },"Installed simulator inventory integrated")
let npmItem = inventory.items.first { $0.name == "npm cache" }!
if case .cache(.npm,_) = npmItem.action { expect(true,"Installed tool enables tool-supported cache action") } else { expect(false,"Tool action missing") }
let oddCache = URL(fileURLWithPath: genericHome.appendingPathComponent("cache with spaces;$(touch no)").path)
let npmPlan = ToolCleanupPlan(tool: .npm,executable: URL(fileURLWithPath: "/usr/bin/true"),cache: oddCache)
expect(npmPlan.command()!.arguments == ["cache","clean","--force","--cache",oddCache.path],"Cache path is one structured argument, never shell code")
expect(npmPlan.command(dryRun: true) == nil,"npm does not invent a dry-run")
let brewPlan = ToolCleanupPlan(tool: .homebrew,executable: URL(fileURLWithPath: "/usr/bin/true"),cache: oddCache)
expect(brewPlan.command(dryRun: true)!.arguments.contains("--dry-run"),"Homebrew preview uses the supported dry-run")
expect(brewPlan.command()!.environment["HOMEBREW_CACHE"] == oddCache.path,"Homebrew cleanup scoped to reviewed cache location")
expect(!brewPlan.command()!.arguments.contains("--prune=all"),"Homebrew uses age retention, not blanket pruning")
let swiftPlan = ToolCleanupPlan(tool: .swift,executable: URL(fileURLWithPath: "/usr/bin/xcrun"),cache: oddCache)
expect(swiftPlan.command()!.arguments == ["swift","package","--cache-path",oddCache.path,"purge-cache"],"Swift repository purge keeps project reset out of scope")
let smallOutput = try ToolRunner().run(ToolCommand(executable: URL(fileURLWithPath: "/usr/bin/printf"),arguments: ["fixture-output"],environment: [:]))
expect(smallOutput.status == 0 && smallOutput.text == "fixture-output","Tool runner captures process output")
let truncatedOutput = try ToolRunner(maximumOutputBytes: 4).run(ToolCommand(executable: URL(fileURLWithPath: "/usr/bin/printf"),arguments: ["long-output"],environment: [:]))
expect(truncatedOutput.truncated && truncatedOutput.text.count == 4,"Tool preview output has a bound")
expect((try? ToolRunner(timeout: 0.05).run(ToolCommand(executable: URL(fileURLWithPath: "/bin/sleep"),arguments: ["1"],environment: [:]))) == nil,"Tool runner enforces a timeout")
let moveItem = inventory.items.first { $0.url.path == largeArchive.path }!
let destination = fixture.appendingPathComponent("ChosenDestination")
try FileManager.default.createDirectory(at: destination,withIntermediateDirectories: true)
var relocator = FileRelocator(allowedRoots: [genericHome.appendingPathComponent("Downloads")],freeBytes: { _ in 10_000_000_000 })
expect((try? relocator.relocate(moveItem,to: genericHome.appendingPathComponent("Downloads"),trash: { _ in })) == nil,"Same folder is not a relocation destination")
relocator.freeBytes = { _ in 0 }
expect((try? relocator.relocate(moveItem,to: destination,trash: { _ in })) == nil,"Insufficient destination space leaves source intact")
expect(FileManager.default.fileExists(atPath: largeArchive.path),"Original survives failed relocation")
relocator.freeBytes = { _ in 10_000_000_000 }
let collision = destination.appendingPathComponent(largeArchive.lastPathComponent)
try Data("keep me".utf8).write(to: collision)
expect((try? relocator.relocate(moveItem,to: destination,trash: { _ in })) == nil,"Relocation refuses destination collision")
expect((try? Data(contentsOf: collision)) == Data("keep me".utf8),"Existing destination is never overwritten")
try FileManager.default.removeItem(at: collision)
var unauthorized = relocator
unauthorized = FileRelocator(allowedRoots: [],freeBytes: { _ in 10_000_000_000 })
expect((try? unauthorized.relocate(moveItem,to: destination,trash: { _ in })) == nil,"Relocation requires an approved scan root")
let movedResult = try relocator.relocate(moveItem,to: destination) { source in try FileManager.default.moveItem(at: source,to: fakeTrash.appendingPathComponent(source.lastPathComponent)) }
expect(movedResult.sameVolume,"An internal same-volume destination is recognized")
expect((try? Data(contentsOf: movedResult.destination)) == Data(repeating: 17,count: 2048),"Relocated copy has verified original bytes")
expect(FileManager.default.fileExists(atPath: fakeTrash.appendingPathComponent(largeArchive.lastPathComponent).path),"Original remains recoverable in injected Trash")
let retainedSource = try storageFile("Downloads/retain.zip")
let retainedItem = inventoryScanner.scan().items.first { $0.url.path == retainedSource.path }!
expect((try? relocator.relocate(retainedItem,to: destination,trash: { _ in throw StorageFailure.changed })) == nil,"Failure to trash original is reported")
expect(FileManager.default.fileExists(atPath: retainedSource.path) && FileManager.default.fileExists(atPath: destination.appendingPathComponent("retain.zip").path),"Both verified copy and original are kept when Trash fails")
let changedSource = try storageFile("Downloads/changed.zip")
let changedItem = inventoryScanner.scan().items.first { $0.url.path == changedSource.path }!
try Data(repeating: 99,count: 4096).write(to: changedSource)
expect((try? relocator.relocate(changedItem,to: destination,trash: { _ in })) == nil,"Changed source cannot be relocated from a stale review")
var partialScanner = inventoryScanner; partialScanner.maximumEntries = 1
expect(partialScanner.measure(genericHome.appendingPathComponent("Documents/Project")).incomplete,"Large folder inventory reports partial measurements")
let emptyHome = fixture.appendingPathComponent("EmptyHome")
try FileManager.default.createDirectory(at: emptyHome,withIntermediateDirectories: true)
expect(StorageScanner(home: emptyHome,applicationRoots: []).scan().items.isEmpty,"Mac with no tools or matching files has an empty inventory")
print("Passed \(checks) total checks, including generic inventory, missing tools, structured commands, runtime evidence and verified relocation.")

expect(FileRelocator.isSameVolume(moveItem,destination: destination) == true,"Destination volume check works independently of directory ownership")
let configuredCache = fixture.appendingPathComponent("CustomCache")
try FileManager.default.createDirectory(at: configuredCache,withIntermediateDirectories: true)
try Data(repeating: 3,count: 2048).write(to: configuredCache.appendingPathComponent("entry"))
inventoryScanner.reportedCacheLocations[.npm] = configuredCache
expect(inventoryScanner.scan().items.contains { $0.url.path == configuredCache.path && $0.name == "npm configured cache" },"Tool-reported custom cache location is inventoried")
let customApp = extraRoot.appendingPathComponent("Custom.app/Contents")
try FileManager.default.createDirectory(at: customApp,withIntermediateDirectories: true)
try Data(repeating: 3,count: 2048).write(to: customApp.appendingPathComponent("binary"))
expect(inventoryScanner.scan().items.contains { $0.name == "Custom" && $0.category == .applications },"Apps in user-chosen locations are discovered")
print("Passed \(checks) total checks.")
