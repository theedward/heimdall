import AppKit
import SwiftUI

final class CleanupCancellation {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

final class CleanupModel: ObservableObject {
    @Published var section = "downloads"
    @Published var opportunities: [StorageOpportunity] = []
    @Published var additionalRoots: [URL] = []
    var opportunityAction: (StorageOpportunity) -> Void = { _ in }
    var addFolderAction: () -> Void = {}
    var emptyTrashAction: () -> Void = {}
    var openTrashAction: () -> Void = {}
    var fileTrashAction: (StorageOpportunity) -> Void = { _ in }
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
                    Text("Find what takes space. Choose what to keep, move or remove.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add folder…",action: model.addFolderAction).disabled(model.busy)
                Button(model.scanning ? "Scanning…" : "Scan",action: model.scanAction).disabled(model.busy)
            }.padding(22)
            LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],spacing: 4) {
                categoryButton("Downloads","downloads")
                categoryButton("Documents","documents")
                categoryButton("Cleanup","cleanup")
                ForEach(StorageCategory.allCases.filter { $0 != .downloads && $0 != .documents },id: \.self) { categoryButton($0.title,$0.rawValue) }
            }.padding(4).background(surface,in: RoundedRectangle(cornerRadius: 11))
                .padding(.horizontal,22).padding(.bottom,16)
            Group {
                if preview { reviewContent } else { ScrollView { reviewContent } }
            }
            Divider()
            HStack {
                VStack(alignment: .leading,spacing: 3) {
                    Text(model.section == "cleanup" ? "\(model.selected.count) cleanup items selected · \(CleanupModel.size(model.selectedBytes))" : "Choose an action next to an item.").font(.system(size: 13,weight: .medium))
                    Text("Nothing moves until you confirm the selected list.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close",action: model.closeAction).disabled(model.working)
                if model.section == "cleanup" {
                    Button(model.working ? "Working…" : "Review & move to Trash",action: model.trashAction)
                        .disabled(model.selected.isEmpty || model.busy)
                }
            }.padding(18)
        }.background(canvas).foregroundStyle(.primary)
    }
    private func categoryButton(_ title: String,_ section: String) -> some View {
        let selected = model.section == section
        return Button { model.section = section } label: {
            Text(title).font(.system(size: 11,weight: selected ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(selected ? canvas : .clear,in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? border : .clear,lineWidth: 1))
        }.buttonStyle(FluidPress()).accessibilityLabel("Show \(title)").accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var reviewContent: some View {
                VStack(alignment: .leading,spacing: 14) {
                    card {
                        VStack(alignment: .leading,spacing: 9) {
                            Text("Storage review").font(.system(size: 14,weight: .semibold))
                            Text("Downloads: large files and files older than 90 days (5 MB or more). Documents: files of 100 MB or more, including inside folders. Cleanup: old installers, logs and Xcode build data.").font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("Start with Downloads and Documents. Open an item in Finder if you are unsure. Large or old does not mean safe to delete. Add folder checks another location.").font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(model.status).font(.system(size: 12,weight: .medium)).fixedSize(horizontal: false,vertical: true)
                            if model.scanning { ProgressView().controlSize(.small) }
                        }
                    }
                    if !model.additionalRoots.isEmpty {
                        VStack(alignment: .leading,spacing: 6) {
                            Text("Extra scan locations").font(.system(size: 11,weight: .medium))
                            ForEach(model.additionalRoots,id: \.path) { url in
                                HStack {
                                    Text(url.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                    Spacer()
                                    Button("Remove") { model.additionalRoots.removeAll { $0.path == url.path }; model.status = "Locations changed. Scan again to refresh results." }.font(.system(size: 10)).disabled(model.busy)
                                }
                            }
                        }.padding(.horizontal,4)
                    }
                    if model.section != "cleanup" {
                        opportunityCards
                    }
                    if model.scanned && model.section == "cleanup" {
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
                    card {
                        VStack(alignment: .leading,spacing: 9) {
                            Text("Trash").font(.system(size: 14,weight: .semibold))
                            Text("Files in Trash still take space. Open Trash to check for anything you want to keep, then empty it when ready. Emptying permanently removes all Trash contents on connected disks, including files removed outside Heimdall.").font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack {
                                Button("Open Trash",action: model.openTrashAction)
                                Button("Empty Trash…",action: model.emptyTrashAction)
                            }.disabled(model.busy)
                        }
                    }
                    Text("Moving items to Trash preserves recovery. Only emptying Trash releases their space. Sizes are estimates; shared APFS storage and compression can affect space reclaimed.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal,4)
                }.padding(.horizontal,22).padding(.bottom,18)
    }
    private var opportunityCards: some View {
        VStack(alignment: .leading,spacing: 14) {
            let items = model.opportunities.filter { $0.category.rawValue == model.section }
            if model.scanned && items.isEmpty {
                card { Text("Nothing found in this category in the scanned locations. Tools may not be installed, folders may be empty, or access may be unavailable.").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            ForEach(items) { item in
                card {
                    VStack(alignment: .leading,spacing: 10) {
                        HStack(alignment: .top) {
                            Text(item.name).font(.system(size: 14,weight: .semibold))
                            Spacer()
                            Text(item.bytes.map { (item.incomplete ? "At least " : "") + CleanupModel.size($0) } ?? "Size unavailable").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Text(item.url.path).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                        Text(item.explanation).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
                        HStack {
                            Button(item.action.title) { model.opportunityAction(item) }.disabled(model.busy)
                            if item.sourceStamp != nil { Button("Review removal…") { model.fileTrashAction(item) }.disabled(model.busy) }
                            if case .reveal = item.action {} else {
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }.disabled(model.busy)
                            }
                        }.font(.system(size: 11))
                        if item.incomplete { Text("Scan limit or access restriction: this is a partial size, not a cleanup estimate.").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                }
            }
        }
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
        model.scanned = true; model.login = true; model.alerts = true; model.section = "cleanup"
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

@MainActor
func renderStoragePreviews(to directory: String) throws {
    for section in ["developer","downloads","documents","folders","empty"] {
        for (theme,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
            let model = CleanupModel(); model.scanned = true; model.login = true; model.alerts = true
            model.section = section == "empty" ? "developer" : section
            model.opportunities = section == "empty" ? [] : [
                StorageOpportunity(url: URL(fileURLWithPath: "/Users/example/.npm"),category: .developer,name: "npm cache",bytes: 3_200_000_000,incomplete: false,explanation: "Recreatable package cache. Review a tool-supported purge; dependencies may be downloaded again.",action: .cache(.npm,URL(fileURLWithPath: "/example/bin/npm"))),
                StorageOpportunity(url: URL(fileURLWithPath: "/Users/example/Library/Caches/Homebrew"),category: .developer,name: "Homebrew cache",bytes: 1_700_000_000,incomplete: false,explanation: "Review Homebrew’s dry-run before cleanup. It can also remove old installed formula versions.",action: .cache(.homebrew,URL(fileURLWithPath: "/example/bin/brew"))),
                StorageOpportunity(url: URL(fileURLWithPath: "/Applications/Unity/Hub/Editor/ExampleVersion"),category: .developer,name: "Unity editor ExampleVersion",bytes: 12_000_000_000,incomplete: false,explanation: "Installed editor; usage is unknown. Review your projects’ required versions before uninstalling in Unity Hub.",action: .manager(.unity)),
                StorageOpportunity(url: URL(fileURLWithPath: "/Users/example/Downloads/Example library.zip"),category: .downloads,name: "Example library.zip",bytes: 18_400_000_000,incomplete: false,explanation: "A large archive, not assumed disposable. Choose any accessible destination. Copy verification precedes moving the original to Trash; same-volume relocation does not reduce volume usage.",action: .relocate),
                StorageOpportunity(url: URL(fileURLWithPath: "/Users/example/Documents/Holidays/Example video.mov"),category: .documents,name: "Example video.mov",bytes: 1_800_000_000,incomplete: false,explanation: "Video — moving it to another disk may be useful. Review it before removing it; this may be your only copy.",action: .relocate),
                StorageOpportunity(url: URL(fileURLWithPath: "/Users/example/Documents/ExampleProject"),category: .folders,name: "ExampleProject",bytes: 5_600_000_000,incomplete: true,explanation: "A large project folder for manual review. Moving it can break references; use its supported relocation method.",action: .reveal)
            ]
            // Synthetic identity only for displaying the same personal-file controls; no real file is inspected.
            model.opportunities = model.opportunities.map { item in
                var previewItem = item
                if case .relocate = item.action {
                    previewItem.sourceStamp = CleanupStamp(path: item.url.path,inode: 1,device: 1,mode: UInt16(0o100644),owner: 0,links: 1,size: item.bytes ?? 0,modifiedSeconds: 0,modifiedNanos: 0,createdSeconds: 0,changedSeconds: 0,changedNanos: 0)
                }
                return previewItem
            }
            model.status = section == "empty" ? "No matching tools or storage items found in these locations." : "Storage items found. Nothing selected automatically; category sizes may overlap."
            let renderer = ImageRenderer(content: CleanupPanel(model: model,preview: true).frame(width: 760).fixedSize(horizontal: false,vertical: true).environment(\.colorScheme,scheme)); renderer.scale = 2
            guard let image = renderer.cgImage,let data = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) else { throw NSError(domain: "HeimdallRender",code: 6) }
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("storage-\(section)-\(theme).png"))
        }
    }
}
