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
