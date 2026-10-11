import Foundation
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
