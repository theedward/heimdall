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
    @Published var status = "Ready to scan."
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
                if model.section == "cleanup" {
                    Text("\(model.selected.count) selected · \(CleanupModel.size(model.selectedBytes))").font(.system(size: 13,weight: .medium))
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
                    HStack(spacing: 9) {
                        Text(model.status).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
                        if model.scanning { ProgressView().controlSize(.small) }
                    }.padding(.horizontal,4)
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
                            card { Text("No cleanup items found.").font(.system(size: 13)).foregroundStyle(.secondary) }
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
                                                        Text("Last changed \(item.modified.formatted(date: .abbreviated,time: .omitted))").font(.system(size: 10)).foregroundStyle(.secondary)
                                                    }
                                                    Spacer(minLength: 6)
                                                    VStack(alignment: .trailing,spacing: 7) {
                                                        Text(CleanupModel.size(item.bytes)).font(.system(size: 12,weight: .medium)).monospacedDigit()
                                                        Button("Show in Finder") { model.reveal(item) }.font(.system(size: 11)).buttonStyle(.plain)
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
                                Text("Details").font(.system(size: 13,weight: .semibold))
                                ForEach(Array(model.notes.enumerated()),id: \.offset) { _,note in Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    card {
                        HStack {
                            Text("Trash").font(.system(size: 14,weight: .semibold))
                            Spacer()
                            Button("Open Trash",action: model.openTrashAction)
                            Button("Empty Trash…",action: model.emptyTrashAction)
                        }.disabled(model.busy)
                    }
                    card {
                        DisclosureGroup("Settings") {
                            VStack(alignment: .leading,spacing: 10) {
                                setting("Launch at login",model.login ? "On" : "Off","On")
                                setting("Low-space notifications",model.alerts ? "On" : "Off","On")
                                setting("Warning thresholds",model.balanced ? "60 / 25 GB" : "Custom preset","60 / 25 GB")
                                Button("Review recommended changes",action: model.recommendedAction).disabled(model.busy)
                                Divider()
                                Button("Open macOS Storage settings",action: model.settingsAction)
                            }.padding(.top,12)
                        }.font(.system(size: 13,weight: .medium))
                    }
                }.padding(.horizontal,22).padding(.bottom,18)
    }
    private var opportunityCards: some View {
        VStack(alignment: .leading,spacing: 14) {
            let items = model.opportunities.filter { $0.category.rawValue == model.section }
            if model.scanned && items.isEmpty {
                card { Text("No items found.").font(.system(size: 12)).foregroundStyle(.secondary) }
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
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }.disabled(model.busy)
                            }
                        }.font(.system(size: 11))
                        if item.incomplete { Text("Size is incomplete.").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
    private func setting(_ name: String,_ current: String,_ recommended: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(current == recommended ? current : "\(current) → \(recommended)").foregroundStyle(.secondary)
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
        model.status = "3 cleanup items found."
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
                StorageOpportunity(url: URL(fileURLWithPath: "/Users/example/.npm"),category: .developer,name: "npm cache",bytes: 3_200_000_000,incomplete: false,explanation: "Cached packages. Future installs may download them again.",action: .cache(.npm,URL(fileURLWithPath: "/example/bin/npm"))),
                StorageOpportunity(url: URL(fileURLWithPath: "/Users/example/Library/Caches/Homebrew"),category: .developer,name: "Homebrew cache",bytes: 1_700_000_000,incomplete: false,explanation: "Cached downloads and old package versions.",action: .cache(.homebrew,URL(fileURLWithPath: "/example/bin/brew"))),
                StorageOpportunity(url: URL(fileURLWithPath: "/Applications/Unity/Hub/Editor/ExampleVersion"),category: .developer,name: "Unity editor ExampleVersion",bytes: 12_000_000_000,incomplete: false,explanation: "Check which version your projects need.",action: .manager(.unity)),
                StorageOpportunity(url: URL(fileURLWithPath: "/Users/example/Downloads/Example library.zip"),category: .downloads,name: "Example library.zip",bytes: 18_400_000_000,incomplete: false,explanation: "Archive. May be your only copy.",action: .relocate),
                StorageOpportunity(url: URL(fileURLWithPath: "/Users/example/Documents/Holidays/Example video.mov"),category: .documents,name: "Example video.mov",bytes: 1_800_000_000,incomplete: false,explanation: "Video.",action: .relocate),
                StorageOpportunity(url: URL(fileURLWithPath: "/Users/example/Documents/ExampleProject"),category: .folders,name: "ExampleProject",bytes: 5_600_000_000,incomplete: true,explanation: "Project folder. Moving it may break links in its app.",action: .reveal)
            ]
            // Synthetic identity only for displaying the same personal-file controls; no real file is inspected.
            model.opportunities = model.opportunities.map { item in
                var previewItem = item
                if case .relocate = item.action {
                    previewItem.sourceStamp = CleanupStamp(path: item.url.path,inode: 1,device: 1,mode: UInt16(0o100644),owner: 0,links: 1,size: item.bytes ?? 0,modifiedSeconds: 0,modifiedNanos: 0,createdSeconds: 0,changedSeconds: 0,changedNanos: 0)
                }
                return previewItem
            }
            model.status = section == "empty" ? "No items found." : "Scan complete."
            let renderer = ImageRenderer(content: CleanupPanel(model: model,preview: true).frame(width: 760).fixedSize(horizontal: false,vertical: true).environment(\.colorScheme,scheme)); renderer.scale = 2
            guard let image = renderer.cgImage,let data = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) else { throw NSError(domain: "HeimdallRender",code: 6) }
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("storage-\(section)-\(theme).png"))
        }
    }
}
