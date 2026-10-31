import AppKit
import SwiftUI

enum StorageSheet: Identifiable {
    case file(StorageOpportunity), move(StorageOpportunity), trash, installers
    case tool(StorageOpportunity,CacheTool,ToolCommand,CleanupStamp,String?)
    var id: String {
        switch self {
        case .file(let item): return "file:" + item.id
        case .move(let item): return "move:" + item.id
        case .trash: return "trash"
        case .installers: return "installers"
        case .tool(let item,_,_,_,_): return "tool:" + item.id
        }
    }
}
final class StorageHubModel: ObservableObject {
    @Published var page = "recommendations"
    @Published var recommendations: [Recommendation] = []
    @Published var destinations: [StorageDestination] = []
    @Published var sourceGroup: String?
    @Published var choices: [SuggestionChoice] = []
    @Published var moves: [MoveRecord] = []
    @Published var scanning = false
    @Published var busy = false
    @Published var scanned = false
    @Published var lastScan: Date?
    @Published var message = "Looking for ways to make room…"
    @Published var notice: String?
    @Published var sheet: StorageSheet?
    @Published var destinationID = ""
    @Published var progress: Double?
    @Published var trash = TrashEstimate()
    @Published var search = ""
    var action: (Recommendation) -> Void = { _ in }
    var remember: (Recommendation,SuggestionChoice.Decision) -> Void = { _,_ in }
    var restoreChoice: (String) -> Void = { _ in }
    var refreshAction: () -> Void = {}
    var cleanAction: () -> Void = {}
    var confirmMove: (StorageOpportunity,String) -> Void = { _,_ in }
    var undoMove: (MoveRecord) -> Void = { _ in }
    var runTool: (ToolCommand,URL,CleanupStamp,ToolCleanupPlan,String?) -> Void = { _,_,_,_,_ in }
    var emptyTrash: () -> Void = {}
    var openTrash: () -> Void = {}
    var freeBytes: Int64?
    func destinations(for item: StorageOpportunity) -> [StorageDestination] {
        destinations.filter { $0.fits(item.bytes ?? 0,sourceGroup: sourceGroup) }
    }
}

struct StorageRecommendationCard: View {
    let recommendation: Recommendation
    var compact = false
    var disabled = false
    var action: () -> Void
    var remember: (SuggestionChoice.Decision) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var showingOptions = false
    var body: some View {
        VStack(alignment: .leading,spacing: compact ? 9 : 12) {
            HStack(alignment: .top,spacing: 10) {
                VStack(alignment: .leading,spacing: 5) {
                    Text(recommendation.title).font(.system(size: compact ? 13 : 15,weight: .semibold)).lineLimit(2)
                    Text(recommendation.detail).font(.system(size: compact ? 11 : 12)).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
                }
                Spacer(minLength: 0)
                if !compact { Text(recommendation.sizeLabel).font(.system(size: 13,weight: .medium)).monospacedDigit() }
            }
            HStack {
                if compact { Text(recommendation.sizeLabel).font(.system(size: 12,weight: .medium)); Spacer(minLength: 4) }
                Button(recommendation.actionTitle,action: action).controlSize(compact ? .small : .regular)
                if !compact { Spacer() }
                Button { showingOptions.toggle() } label: { Image(systemName: "ellipsis").frame(width: 25,height: 22) }
                    .buttonStyle(.plain).accessibilityLabel("Suggestion options")
                    .popover(isPresented: $showingOptions,arrowEdge: .bottom) {
                        VStack(alignment: .leading,spacing: 8) {
                            if recommendation.item != nil { Button("Keep here") { remember(.keepHere); showingOptions = false } }
                            Button("Don’t suggest again") { remember(.dismissed); showingOptions = false }
                        }.buttonStyle(.plain).padding(16)
                    }
            }
        }.padding(compact ? 14 : 18)
            .background(scheme == .dark ? Color(white: 0.20) : .white,in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07),lineWidth: 1))
            .disabled(disabled)
    }
}

struct StorageHub: View {
    @ObservedObject var hub: StorageHubModel
    @ObservedObject var cleanup: CleanupModel
    @ObservedObject var beacon: BeaconModel
    var preview = false
    @State private var category = "all"
    @Environment(\.colorScheme) private var scheme
    private var canvas: Color { scheme == .dark ? Color(white: 0.145) : Color(white: 0.965) }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading,spacing: 8) {
                Label("Heimdall",systemImage: "shield.lefthalf.filled").font(.system(size: 18,weight: .semibold)).padding(.bottom,24)
                navigation("Recommendations","sparkles","recommendations")
                navigation("Files & apps","folder","files")
                navigation("Moves","arrow.left.arrow.right","moves")
                Spacer()
                navigation("Preferences","slider.horizontal.3","preferences")
            }.padding(18).frame(width: 218).background(Color.primary.opacity(0.025))
            Divider()
            VStack(alignment: .leading,spacing: 0) {
                HStack {
                    VStack(alignment: .leading,spacing: 5) {
                        Text(title).font(.system(size: 25,weight: .semibold))
                        if hub.page != "preferences" || hub.busy {
                            Text(hub.page == "files" && !hub.busy ? "\(cleanup.opportunities.count) files and apps" : hub.message).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    Spacer()
                    if hub.scanning { ProgressView().controlSize(.small) }
                    Button { hub.refreshAction() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh suggestions").disabled(hub.busy || hub.scanning)
                }.padding(24)
                if hub.busy {
                    VStack(alignment: .leading,spacing: 8) {
                        if let progress = hub.progress { ProgressView(value: progress) }
                        else { ProgressView().controlSize(.small) }
                    }.padding(.horizontal,24).padding(.bottom,16)
                }
                Group {
                    if preview { content }
                    else { ScrollView { content } }
                }
            }.frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)
        }.background(canvas).foregroundStyle(.primary)
            .sheet(item: $hub.sheet) { sheet in
                switch sheet {
                case .move(let item): MoveReview(hub: hub,item: item)
                case .file(let item): fileDetails(item)
                case .trash: trashReview
                case .installers: installerReview
                case .tool(let item,let kind,let command,let stamp,let preview): toolReview(item,kind: kind,command: command,stamp: stamp,preview: preview)
                }
            }
    }
    private var title: String {
        switch hub.page {
        case "files": return "Files & apps"
        case "moves": return "Moves"
        case "preferences": return "Preferences"
        default: return "Make room"
        }
    }
    private func navigation(_ title: String,_ icon: String,_ page: String) -> some View {
        Button { hub.page = page } label: {
            HStack(spacing: 10) { Image(systemName: icon).frame(width: 18); Text(title).lineLimit(1); Spacer() }
                .font(.system(size: 12,weight: hub.page == page ? .semibold : .medium)).padding(11)
                .background(hub.page == page ? Color.primary.opacity(0.07) : .clear,in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(FluidPress()).accessibilityAddTraits(hub.page == page ? .isSelected : [])
    }
    private var content: some View {
        VStack(alignment: .leading,spacing: 18) {
            if let notice = hub.notice {
                surface {
                    HStack(alignment: .top) {
                        Text(notice).font(.system(size: 12)).textSelection(.enabled)
                        Spacer()
                        Button { hub.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss result")
                    }
                }
            }
            switch hub.page {
            case "files": files
            case "moves": moves
            case "preferences": preferences
            default: recommendations
            }
        }.padding(.horizontal,24).padding(.bottom,24).frame(maxWidth: .infinity,alignment: .leading)
    }
    private var recommendations: some View {
        VStack(alignment: .leading,spacing: 18) {
            ForEach([RecommendationEffort.easy,.worthwhile],id: \.rawValue) { effort in
                let items = hub.recommendations.filter { $0.effort == effort }
                if !items.isEmpty {
                    Text(effort == .easy ? "Easy wins" : "Worth considering").font(.system(size: 14,weight: .semibold))
                    ForEach(items) { item in
                        StorageRecommendationCard(recommendation: item,disabled: hub.busy || hub.scanning,action: { hub.action(item) },remember: { hub.remember(item,$0) })
                    }
                }
            }
            if hub.scanned && hub.recommendations.isEmpty {
                surface {
                    Text("No new suggestions right now.").font(.system(size: 16,weight: .medium))
                    Text("You can still explore files and apps.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Explore files") { hub.page = "files" }
                }
            }
            if !cleanup.notes.isEmpty {
                DisclosureGroup("Some locations couldn’t be checked") {
                    ForEach(Array(cleanup.notes.enumerated()),id: \.offset) { _,note in Text(note).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity,alignment: .leading) }
                    Button("Open Privacy settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!) }
                }.font(.system(size: 12))
            }
        }
    }
    private var files: some View {
        VStack(alignment: .leading,spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    if preview {
                        Text(hub.search.isEmpty ? "Find a file or app" : hub.search).foregroundStyle(.secondary).frame(maxWidth: .infinity,alignment: .leading)
                    } else {
                        TextField("Find a file or app",text: $hub.search).textFieldStyle(.plain)
                    }
                }.font(.system(size: 12)).padding(10).background(Color.primary.opacity(0.045),in: RoundedRectangle(cornerRadius: 9))
                Picker("Category",selection: $category) {
                    Text("All").tag("all")
                    ForEach(StorageCategory.allCases,id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().frame(width: 145)
                Button("Add location…",action: cleanup.addFolderAction).disabled(hub.busy || hub.scanning)
            }
            let items = cleanup.opportunities.filter { (category == "all" || $0.category.rawValue == category) && (hub.search.isEmpty || $0.name.localizedCaseInsensitiveContains(hub.search)) }
            if items.isEmpty && hub.scanned { Text("No matching files.").foregroundStyle(.secondary) }
            ForEach(items) { item in
                Button { hub.sheet = .file(item) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.category == .applications ? "app" : item.category == .folders ? "folder" : "doc").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 25)
                        VStack(alignment: .leading,spacing: 4) {
                            Text(item.name).font(.system(size: 13,weight: .medium)).lineLimit(1)
                            Text(shortPath(item.url.deletingLastPathComponent())).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(item.bytes.map { (item.incomplete ? "At least " : "") + CleanupModel.size($0) } ?? "—").font(.system(size: 12)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(14).background(scheme == .dark ? Color(white: 0.20) : .white,in: RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(FluidPress()).disabled(hub.busy || hub.scanning)
            }
            if cleanup.candidates.contains(where: { $0.rule == .installers }) { Button("Review old installers…") { hub.sheet = .installers } }
        }
    }
    private var moves: some View {
        VStack(alignment: .leading,spacing: 14) {
            if hub.moves.isEmpty { Text("Completed moves will appear here.").font(.system(size: 13)).foregroundStyle(.secondary) }
            ForEach(hub.moves.reversed()) { record in
                surface {
                    HStack { Text(record.name).font(.system(size: 15,weight: .semibold)); Spacer(); Text(CleanupModel.size(record.bytes)).font(.system(size: 12)) }
                    Text(shortPath(record.destination)).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(FileManager.default.fileExists(atPath: record.source.path) ? "Verified copy · original retained" : record.date.formatted(date: .abbreviated,time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack {
                        Button("Move back…") { hub.undoMove(record) }.disabled(hub.busy || hub.scanning || FileManager.default.fileExists(atPath: record.source.path) || !FileManager.default.fileExists(atPath: record.destination.path))
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.destination]) }
                        if !FileManager.default.fileExists(atPath: record.destination.path) { Text("Disk offline or file unavailable").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
    private var preferences: some View {
        VStack(alignment: .leading,spacing: 18) {
            surface {
                Toggle("Launch at login",isOn: Binding(get: { beacon.login },set: { _ in beacon.loginAction() })).toggleStyle(FluidToggle(label: "Launch at login"))
                Toggle("Low-space notifications",isOn: Binding(get: { beacon.alerts },set: beacon.alertAction)).toggleStyle(FluidToggle(label: "Low-space notifications"))
                Button("Send test notification",action: beacon.testAlertAction)
                HStack { Text("Warn below"); Spacer(); Text("\(beacon.warning) GB · Critical below \(beacon.critical) GB").foregroundStyle(.secondary) }.font(.system(size: 12))
                HStack {
                    Button("Relaxed") { beacon.presetAction(30,10) }
                    Button("Balanced") { beacon.presetAction(60,25) }
                    Button("Early") { beacon.presetAction(100,50) }
                }
                Button("macOS Storage settings",action: cleanup.settingsAction)
            }
            Text("Remembered choices").font(.system(size: 14,weight: .semibold))
            if hub.choices.isEmpty { Text("Nothing hidden.").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(hub.choices) { choice in
                surface {
                    HStack {
                        VStack(alignment: .leading,spacing: 4) {
                            Text(choice.name).font(.system(size: 13,weight: .medium))
                            Text(choice.decision == .keepHere ? "Keep here" : "Don’t suggest again").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Suggest again") { hub.restoreChoice(choice.key) }
                    }
                }
            }
        }
    }
    private func fileDetails(_ item: StorageOpportunity) -> some View {
        VStack(alignment: .leading,spacing: 18) {
            HStack { Image(systemName: "doc").font(.system(size: 25)); Text(item.name).font(.system(size: 21,weight: .semibold)).lineLimit(2) }
            Text(item.bytes.map(CleanupModel.size) ?? "Size unavailable").font(.system(size: 16,weight: .medium))
            Text(item.explanation).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(shortPath(item.url)).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Spacer()
                Button("Done") { hub.sheet = nil }.keyboardShortcut(.cancelAction)
                if item.sourceStamp != nil {
                    Button("Move…") { hub.destinationID = hub.destinations(for: item).first?.id ?? ""; hub.sheet = .move(item) }
                    Button("Move to Trash…") { hub.sheet = nil; cleanup.fileTrashAction(item) }.disabled(hub.busy)
                } else { Button(item.action.title) { hub.sheet = nil; cleanup.opportunityAction(item) }.disabled(hub.busy) }
            }
        }.padding(26).frame(width: 570)
    }
    private var trashReview: some View {
        VStack(alignment: .leading,spacing: 18) {
            Label("Empty Trash",systemImage: "trash").font(.system(size: 23,weight: .semibold))
            Text(hub.trash.bytes.map { (hub.trash.incomplete ? "At least " : "") + CleanupModel.size($0) } ?? "Size unavailable").font(.system(size: 18,weight: .medium))
            Text("Permanently deletes everything in Trash on connected disks, including files removed outside Heimdall. These files cannot be restored from Trash.").font(.system(size: 13)).foregroundStyle(.secondary)
            HStack {
                Button("Open Trash",action: hub.openTrash)
                Spacer()
                Button("Cancel") { hub.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Empty Trash",role: .destructive) { hub.sheet = nil; hub.emptyTrash() }
            }
        }.padding(26).frame(width: 540)
    }
    private func toolReview(_ item: StorageOpportunity,kind: CacheTool,command: ToolCommand,stamp: CleanupStamp,preview: String?) -> some View {
        let plan = ToolCleanupPlan(tool: kind,executable: command.executable,cache: item.url)
        return VStack(alignment: .leading,spacing: 18) {
            Text("Clean up \(item.name)").font(.system(size: 23,weight: .semibold))
            Text(plan.explanation).font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Close active builds and installs first.").font(.system(size: 12))
            if let preview {
                ScrollView { Text(preview).font(.system(size: 11,design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading) }.frame(height: 210)
            }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Spacer()
                Button("Cancel") { hub.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Clean up") { hub.sheet = nil; hub.runTool(command,item.url,stamp,plan,preview) }
            }
        }.padding(26).frame(width: 580)
    }
    private var installerReview: some View {
        VStack(alignment: .leading,spacing: 18) {
            Text("Old installers").font(.system(size: 23,weight: .semibold))
            Text("Select the installers you no longer need.").font(.system(size: 13)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(cleanup.candidates.filter { $0.rule == .installers }) { item in
                        HStack {
                            Toggle(item.name,isOn: Binding(get: { cleanup.selection.contains(item.id) },set: { if $0 { cleanup.selection.insert(item.id) } else { cleanup.selection.remove(item.id) } })).toggleStyle(.checkbox)
                            Spacer(); Text(CleanupModel.size(item.bytes)).font(.system(size: 12)).foregroundStyle(.secondary)
                            Button { cleanup.reveal(item) } label: { Image(systemName: "magnifyingglass") }.help("Show in Finder")
                        }
                    }
                }.padding(4)
            }.frame(maxHeight: 280)
            HStack {
                Text(CleanupModel.size(cleanup.selectedBytes)).font(.system(size: 12)); Spacer()
                Button("Cancel") { cleanup.selection = []; hub.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Move to Trash…") { hub.sheet = nil; cleanup.trashAction() }.disabled(cleanup.selected.isEmpty)
            }
        }.padding(26).frame(width: 590)
    }
    private func surface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading,spacing: 12,content: content).padding(18).frame(maxWidth: .infinity,alignment: .leading)
            .background(scheme == .dark ? Color(white: 0.20) : .white,in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07),lineWidth: 1))
    }
}

func shortPath(_ url: URL) -> String {
    url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/",with: "~/")
}
struct MoveReview: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var hub: StorageHubModel
    let item: StorageOpportunity
    var body: some View {
        VStack(alignment: .leading,spacing: 18) {
            Text("Move \(item.name)").font(.system(size: 22,weight: .semibold)).lineLimit(2)
            Text(item.bytes.map { CleanupModel.size($0) + " on your current disk" } ?? "Size unavailable").font(.system(size: 13)).foregroundStyle(.secondary)
            let disks = hub.destinations(for: item)
            if disks.isEmpty {
                Text("Connect a separate disk with enough free space.").font(.system(size: 14))
            } else {
                Text("Destination").font(.system(size: 12,weight: .semibold))
                ForEach(disks) { disk in
                    Button { hub.destinationID = disk.id } label: {
                        HStack(spacing: 12) {
                            Image(systemName: hub.destinationID == disk.id ? "largecircle.fill.circle" : "circle")
                            VStack(alignment: .leading,spacing: 4) {
                                Text(disk.name).font(.system(size: 14,weight: .medium))
                                Text(shortPath(disk.folder(for: item))).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(); Text(CleanupModel.size(disk.freeBytes) + " free").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(14).background(Color.primary.opacity(hub.destinationID == disk.id ? 0.07 : 0.03),in: RoundedRectangle(cornerRadius: 11))
                    }.buttonStyle(FluidPress())
                }
                Text("The copy is checked before the original is removed. Keep the destination disk connected to use the file. You can move it back from Moves.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Show original") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Spacer()
                Button("Cancel") { hub.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Move file") { hub.confirmMove(item,hub.destinationID) }
                    .disabled(!disks.contains { $0.id == hub.destinationID } || hub.busy)
            }
        }.padding(26).frame(width: 580).background(scheme == .dark ? Color(white: 0.20) : .white).foregroundStyle(.primary)
    }
}

func exampleRecommendations() -> [Recommendation] {
    let disk = StorageDestination(id: "example-secondary",name: "Archive disk",root: URL(fileURLWithPath: "/Volumes/Archive disk"),freeBytes: 640_000_000_000,storageGroup: "example-secondary")
    let item = StorageOpportunity(url: URL(fileURLWithPath: "/Users/example/Movies/Travel video.mov"),category: .documents,name: "Travel video.mov",bytes: 24_000_000_000,incomplete: false,explanation: "Video.",action: .relocate)
    return [
        Recommendation(id: "cleanup",kind: .cleanup,effort: .easy,title: "Clear old caches and logs",detail: "Old logs, cached downloads and inactive build files.",bytes: 3_200_000_000),
        Recommendation(id: "trash",kind: .trash,effort: .easy,title: "Empty Trash",detail: "Permanently remove files already in Trash.",bytes: 5_100_000_000),
        Recommendation(id: "example-move",kind: .move,effort: .worthwhile,title: "Move Travel video.mov",detail: "To Archive disk. Keep it connected to use this file.",bytes: 24_000_000_000,item: item,destination: disk),
        Recommendation(id: "example-steam",kind: .manage,effort: .worthwhile,title: "Review Steam games",detail: "Move games through Steam’s Storage settings.",bytes: 42_000_000_000)
    ]
}
@MainActor
func renderHubPreviews(to directory: String) throws {
    for (theme,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
        let hub = StorageHubModel(); let cleanup = CleanupModel(); let beacon = BeaconModel(); beacon.login = true; beacon.alerts = true
        hub.recommendations = exampleRecommendations(); hub.message = "4 ways to make room"; hub.scanned = true
        hub.destinations = [hub.recommendations[2].destination!]; hub.sourceGroup = "example-primary"; hub.trash = TrashEstimate(bytes: 5_100_000_000)
        let movie = hub.recommendations[2].item!
        cleanup.opportunities = [movie,StorageOpportunity(url: URL(fileURLWithPath: "/Users/example/Downloads/Book collection.zip"),category: .downloads,name: "Book collection.zip",bytes: 8_500_000_000,incomplete: false,explanation: "Archive. May be your only copy.",action: .relocate)]
        hub.choices = [SuggestionChoice(key: "example-choice",name: "Family photos",decision: .keepHere)]
        for page in ["recommendations","files","preferences"] {
            hub.page = page
            let renderer = ImageRenderer(content: StorageHub(hub: hub,cleanup: cleanup,beacon: beacon,preview: true).frame(width: 1000,height: page == "recommendations" ? 830 : 650).environment(\.colorScheme,scheme)); renderer.scale = 2
            guard let cg = renderer.cgImage,let data = NSBitmapImageRep(cgImage: cg).representation(using: .png,properties: [:]) else { throw NSError(domain: "HeimdallRender",code: 7) }
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("hub-\(page)-\(theme).png"))
        }
        hub.destinationID = hub.destinations[0].id
        let renderer = ImageRenderer(content: MoveReview(hub: hub,item: movie).environment(\.colorScheme,scheme)); renderer.scale = 2
        guard let cg = renderer.cgImage,let data = NSBitmapImageRep(cgImage: cg).representation(using: .png,properties: [:]) else { throw NSError(domain: "HeimdallRender",code: 8) }
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("move-review-\(theme).png"))
    }
}
