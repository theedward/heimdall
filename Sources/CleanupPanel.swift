import AppKit
import SwiftUI

final class CleanupCancellation {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

final class CleanupModel: ObservableObject {
    @Published var scanning = false
    @Published var working = false
    @Published var scanned = false
    @Published var candidates: [CleanupCandidate] = []
    @Published var selection: Set<String> = []
    @Published var notes: [String] = []
    @Published var status = "Scan your user folders for cleanup candidates."
    @Published var login = false
    @Published var alerts = false
    @Published var balanced = true
    var scanAction: () -> Void = {}
    var trashAction: () -> Void = {}
    var recommendedAction: () -> Void = {}
    var settingsAction: () -> Void = {}
    var finderSettingsAction: () -> Void = {}
    var closeAction: () -> Void = {}
    var selected: [CleanupCandidate] { candidates.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.bytes } }
    var busy: Bool { scanning || working }
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes,countStyle: .file) }
    func reveal(_ item: CleanupCandidate) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
}

struct CleanupPanel: View {
    @ObservedObject var model: CleanupModel
    var preview = false
    @Environment(\.colorScheme) private var scheme
    private var canvas: Color { scheme == .dark ? Color(white: 0.145) : Color(white: 0.965) }
    private var surface: Color { scheme == .dark ? Color(white: 0.20) : .white }
    private var border: Color { Color.primary.opacity(0.07) }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(16).frame(maxWidth: .infinity,alignment: .leading)
            .background(surface,in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(border,lineWidth: 1))
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 0) {
            HStack {
                VStack(alignment: .leading,spacing: 4) {
                    Text("Cleanup review").font(.system(size: 23,weight: .semibold))
                    Text("Scan → review → move selected items to Trash").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.scanning ? "Scanning…" : "Scan user folders",action: model.scanAction).disabled(model.busy)
            }.padding(22)
            Group {
                if preview { reviewContent } else { ScrollView { reviewContent } }
            }
            Divider()
            HStack {
                VStack(alignment: .leading,spacing: 3) {
                    Text("\(model.selected.count) selected · \(CleanupModel.size(model.selectedBytes))").font(.system(size: 13,weight: .medium))
                    Text("Nothing moves until you confirm the selected list.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close",action: model.closeAction).disabled(model.working)
                Button(model.working ? "Moving…" : "Review & move to Trash",action: model.trashAction)
                    .disabled(model.selected.isEmpty || model.busy)
            }.padding(18)
        }.background(canvas).foregroundStyle(.primary)
    }
    private var reviewContent: some View {
                VStack(alignment: .leading,spacing: 14) {
                    card {
                        VStack(alignment: .leading,spacing: 9) {
                            Text("Three basic rules").font(.system(size: 14,weight: .semibold))
                            Text("Installers in Downloads, user logs, and inactive Xcode build data. Items must be at least 30 days old; files must total at least 1 MB.").font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("Games, projects, documents, archives, app data and general caches are outside these rules. Xcode build data is skipped while Xcode is running.").font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(model.status).font(.system(size: 12,weight: .medium)).fixedSize(horizontal: false,vertical: true)
                            if model.scanning { ProgressView().controlSize(.small) }
                        }
                    }
                    if model.scanned {
                        if model.candidates.isEmpty {
                            card { Text("No eligible items found in the accessible locations.").font(.system(size: 13)).foregroundStyle(.secondary) }
                        } else {
                            ForEach(CleanupRule.allCases,id: \.self) { rule in
                                let items = model.candidates.filter { $0.rule == rule }
                                if !items.isEmpty {
                                    card {
                                        VStack(alignment: .leading,spacing: 12) {
                                            HStack { Text(rule.title).font(.system(size: 14,weight: .semibold)); Spacer(); Text("\(items.count) \(items.count == 1 ? "item" : "items")").font(.system(size: 11)).foregroundStyle(.secondary) }
                                            Text(rule.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                                            ForEach(items) { item in
                                                HStack(alignment: .top,spacing: 10) {
                                                    Toggle(isOn: Binding(get: { model.selection.contains(item.id) },set: { value in
                                                        if value { model.selection.insert(item.id) } else { model.selection.remove(item.id) }
                                                    })) { Text(item.name).lineLimit(2) }.toggleStyle(.checkbox).labelsHidden()
                                                        .accessibilityLabel("Select \(item.name)").disabled(model.busy)
                                                    VStack(alignment: .leading,spacing: 5) {
                                                        Text(item.name).font(.system(size: 13,weight: .medium)).textSelection(.enabled)
                                                        Text(item.url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/",with: "~/")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                                                        Text("Last created or modified \(item.modified.formatted(date: .abbreviated,time: .omitted))").font(.system(size: 10)).foregroundStyle(.secondary)
                                                    }
                                                    Spacer(minLength: 6)
                                                    VStack(alignment: .trailing,spacing: 7) {
                                                        Text(CleanupModel.size(item.bytes)).font(.system(size: 12,weight: .medium)).monospacedDigit()
                                                        Button("Reveal") { model.reveal(item) }.font(.system(size: 11)).buttonStyle(.plain)
                                                    }
                                                }
                                                if item.id != items.last?.id { Divider() }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !model.notes.isEmpty {
                        card {
                            VStack(alignment: .leading,spacing: 7) {
                                Text("Scan notes").font(.system(size: 13,weight: .semibold))
                                ForEach(Array(model.notes.enumerated()),id: \.offset) { _,note in Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    card {
                        VStack(alignment: .leading,spacing: 10) {
                            Text("Recommended Heimdall settings").font(.system(size: 14,weight: .semibold))
                            setting("Launch at login",model.login ? "On" : "Off","On")
                            setting("Low-space notifications",model.alerts ? "On" : "Off","On")
                            setting("Warning thresholds",model.balanced ? "Balanced" : "Custom preset","60 / 25 GB")
                            Button("Review recommended changes",action: model.recommendedAction).disabled(model.busy)
                            Divider()
                            Text("macOS storage settings").font(.system(size: 13,weight: .semibold))
                            Text("Review Apple’s storage recommendations in System Settings. Keep automatic 30-day Trash removal off if you want every permanent deletion reviewed. Finder → Settings → Advanced controls automatic Trash removal. These macOS settings are reviewed in their native screens; Heimdall does not inspect or change private preferences.").font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack {
                                Button("Open Storage settings",action: model.settingsAction)
                                Button("Open Finder",action: model.finderSettingsAction)
                            }.font(.system(size: 11))
                        }
                    }
                    Text("Moving items to Trash preserves recovery and does not release their disk space. Review and empty Trash in Finder when ready. Sizes are logical estimates; APFS shared storage and compression can affect space reclaimed.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal,4)
                }.padding(.horizontal,22).padding(.bottom,18)
    }
    private func setting(_ name: String,_ current: String,_ recommended: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text("\(current) → \(recommended)").foregroundStyle(.secondary)
        }.font(.system(size: 11))
    }
}

@MainActor
func renderCleanupPreviews(to directory: String) throws {
    for (theme,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
        let model = CleanupModel()
        model.scanned = true; model.login = true; model.alerts = true
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        model.candidates = [
            CleanupCandidate(url: URL(fileURLWithPath: "/Users/example/Downloads/Example Installer.dmg"),rule: .installers,bytes: 2_400_000_000,modified: date,snapshot: []),
            CleanupCandidate(url: URL(fileURLWithPath: "/Users/example/Library/Logs/ExampleApp/old.log"),rule: .logs,bytes: 280_000_000,modified: date,snapshot: []),
            CleanupCandidate(url: URL(fileURLWithPath: "/Users/example/Library/Developer/Xcode/DerivedData/ExampleProject"),rule: .derivedData,bytes: 9_200_000_000,modified: date,snapshot: [])
        ]
        model.selection = [model.candidates[0].id,model.candidates[2].id]
        model.status = "3 candidates · 11.88 GB to review. Nothing selected automatically."
        let renderer = ImageRenderer(content: CleanupPanel(model: model,preview: true).frame(width: 760).fixedSize(horizontal: false,vertical: true).environment(\.colorScheme,scheme))
        renderer.scale = 2
        guard let image = renderer.cgImage,let data = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) else { throw NSError(domain: "HeimdallRender",code: 5) }
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("cleanup-\(theme).png"))
    }
}
