import AppKit
import SwiftUI

final class BeaconModel: ObservableObject {
    @Published var disk: DiskReading?
    @Published var warning = 60
    @Published var critical = 25
    @Published var login = false
    @Published var updated = Date()
    @Published var error = false
    @Published var targets: [DiskTarget] = [.internalDisk]
    @Published var selectedID = "internal"
    @Published var selectedName = "Internal disk"
    @Published var disconnected = false
    @Published var alerts = false
    @Published var alertNote = ""
    @Published var checkingUpdate = false
    @Published var updateNote = "Version 2.0.0"
    @Published var releaseURL: URL?
    var selectAction: (String) -> Void = { _ in }
    var alertAction: (Bool) -> Void = { _ in }
    var testAlertAction: () -> Void = {}
    var updateAction: () -> Void = {}
    var openReleaseAction: () -> Void = {}
    var refreshAction: () -> Void = {}
    var presetAction: (Int,Int) -> Void = { _,_ in }
    var loginAction: () -> Void = {}
    @Published var cleaning = false
    @Published var cleanNote = ""
    @Published var recommendations: [Recommendation] = []
    @Published var discovering = false
    var hub: StorageHubModel?
    var preferencesAction: () -> Void = {}
    var freeSpaceAction: () -> Void = {}
    var cleanupAction: () -> Void = {}
    var storageAction: () -> Void = {}
    var quitAction: () -> Void = {}
    var freeGB: Double { Double(disk?.free ?? 0) / 1e9 }
    var fraction: Double { disk?.fraction ?? 0 }
    var state: String { disconnected ? "Offline" : error ? "Unavailable" : freeGB < Double(critical) ? "Critical" : freeGB < Double(warning) ? "Getting tight" : "Healthy" }
    var tint: Color { error ? .gray : freeGB < Double(critical) ? Color(red: 0.88,green: 0.23,blue: 0.25) : freeGB < Double(warning) ? Color(red: 0.84,green: 0.43,blue: 0.08) : Color.gray }
}

struct FluidPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.98 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25,dampingFraction: 0.8), value: configuration.isPressed)
    }
}


struct FluidToggle: ToggleStyle {
    var label = "Launch at login"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            Button { configuration.isOn.toggle() } label: {
                Capsule().fill(configuration.isOn ? Color.primary.opacity(0.65) : Color.primary.opacity(0.15))
                    .frame(width: 36,height: 22)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Color.white).frame(width: 18,height: 18).padding(2)
                    }.frame(width: 44,height: 44)
            }.buttonStyle(FluidPress()).accessibilityLabel(label)
                .accessibilityValue(configuration.isOn ? "On" : "Off")
                .animation(reduceMotion ? nil : .spring(response: 0.25,dampingFraction: 0.8),value: configuration.isOn)
        }
    }
}

struct BeaconPanel: View {
    @ObservedObject var model: BeaconModel
    @Environment(\.colorScheme) private var scheme
    private var canvas: Color { scheme == .dark ? Color(white: 0.145) : Color(white: 0.965) }
    private var surface: Color { scheme == .dark ? Color(white: 0.20) : .white }
    private var border: Color { scheme == .dark ? .white.opacity(0.08) : .black.opacity(0.07) }
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(16).frame(maxWidth: .infinity,alignment: .leading)
            .background(surface,in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(border,lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.10 : 0.04),radius: 6,x: 0,y: 2)
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 22,weight: .medium))
                    .frame(width: 38,height: 38).background(surface,in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading,spacing: 3) {
                    Text("Heimdall").font(.system(size: 17,weight: .semibold))
                }
                Spacer()
                Button(action: model.refreshAction) { Image(systemName: "arrow.clockwise").frame(width: 36,height: 36).background(surface,in: RoundedRectangle(cornerRadius: 10)) }
                    .buttonStyle(FluidPress()).help("Refresh disk usage").accessibilityLabel("Refresh disk usage")
            }
            Picker("Disk",selection: Binding(get: { model.selectedID },set: model.selectAction)) {
                ForEach(model.targets) { target in Text(target.name).tag(target.id) }
                if model.disconnected { Text("\(model.selectedName) · offline").tag(model.selectedID) }
            }.pickerStyle(.menu).font(.system(size: 12)).padding(.horizontal,2)
            panel {
                VStack(alignment: .leading,spacing: 14) {
                    HStack {
                        Text("AVAILABLE SPACE").font(.system(size: 10,weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 5) { Circle().fill(model.tint).frame(width: 6,height: 6); Text(model.state).font(.system(size: 11,weight: .medium)) }
                            .foregroundStyle(model.tint).padding(.horizontal,8).padding(.vertical,5).background(model.tint.opacity(0.09),in: Capsule())
                    }
                    HStack(alignment: .firstTextBaseline,spacing: 5) {
                        Text(model.error ? "—" : String(format: "%.1f",model.freeGB)).font(.system(size: 46,weight: .semibold,design: .rounded)).monospacedDigit()
                        Text("GB free").font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    if !model.error {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(model.tint).frame(width: max(0,geo.size.width * model.fraction))
                        }
                    }.frame(height: 7).accessibilityLabel("Disk occupancy").accessibilityValue("\(Int((model.fraction * 100).rounded())) percent")
                    HStack {
                        Text("\(Int((model.fraction * 100).rounded()))% occupied").font(.system(size: 12,weight: .medium))
                        Spacer()
                        Text(String(format: "%.0f GB total",Double(model.disk?.total ?? 0) / 1e9)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    }
                    if model.error {
                        Text(model.disconnected ? "Reconnect this disk or select another." : "Couldn’t read disk usage. Try refreshing.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text("Make room on this Mac").font(.system(size: 14,weight: .semibold))
                Spacer()
                if model.discovering { ProgressView().controlSize(.small) }
            }
            let easy = model.recommendations.filter { $0.effort == .easy }
            let worthwhile = model.recommendations.filter { $0.effort == .worthwhile }
            if !easy.isEmpty {
                Text("Easy wins").font(.system(size: 10,weight: .semibold)).foregroundStyle(.secondary)
                ForEach(Array(easy.prefix(2))) { rec in compactRecommendation(rec) }
            }
            if !worthwhile.isEmpty {
                Text("Worth considering").font(.system(size: 10,weight: .semibold)).foregroundStyle(.secondary)
                ForEach(Array(worthwhile.prefix(1))) { rec in compactRecommendation(rec) }
            }
            if model.recommendations.isEmpty {
                Text(model.discovering ? "Finding useful next steps…" : "No new suggestions right now.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button(model.cleaning ? "Cleaning…" : "Free up space",action: model.freeSpaceAction).disabled(model.cleaning || model.discovering)
            }
            if let hub = model.hub,hub.busy {
                Text(hub.message).font(.system(size: 12)).foregroundStyle(.secondary)
                if let progress = hub.progress { ProgressView(value: progress) }
            } else if let notice = model.hub?.notice { Text(notice).font(.system(size: 12)).foregroundStyle(.secondary) }
            else if !model.cleanNote.isEmpty { Text(model.cleanNote).font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack {
                Button("All recommendations…",action: model.cleanupAction)
                Spacer()
                Button(action: model.preferencesAction) { Image(systemName: "slider.horizontal.3") }.help("Preferences")
            }.font(.system(size: 12))
            VStack(alignment: .leading,spacing: 6) {
                HStack {
                    Button(model.checkingUpdate ? "Checking…" : "Check for updates",action: model.updateAction)
                        .disabled(model.checkingUpdate).buttonStyle(.plain)
                    Spacer()
                    if model.releaseURL != nil { Button("View release",action: model.openReleaseAction).buttonStyle(.plain) }
                }.font(.system(size: 11,weight: .medium))
                Text(model.updateNote).font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal,2)
            HStack {
                Text("Updated \(model.updated,style: .time)").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit",action: model.quitAction).font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.plain)
            }.padding(.horizontal,2)
        }
        .padding(18).frame(width: 360).background(canvas).foregroundStyle(.primary)
    }
    private func compactRecommendation(_ rec: Recommendation) -> some View {
        StorageRecommendationCard(recommendation: rec,compact: true,disabled: model.cleaning || model.discovering || model.hub?.busy == true,action: { model.hub?.action(rec) },remember: { model.hub?.remember(rec,$0) })
    }
    private func preset(_ label: String,_ warn: Int,_ crit: Int) -> some View {
        let selected = model.warning == warn && model.critical == crit
        return Button { model.presetAction(warn,crit) } label: {
            Text(label).font(.system(size: 11,weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.primary : .secondary)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(selected ? surface : .clear,in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? border : .clear,lineWidth: 1))
        }.buttonStyle(FluidPress()).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
func renderPreviews(to directory: String) {
    do {
        try FileManager.default.createDirectory(atPath: directory,withIntermediateDirectories: true)
        let live = DiskReading(total: 512_000_000_000,free: 128_000_000_000)
        for (name,free) in [("healthy",live.free),("warning",Int64(42_000_000_000)),("critical",Int64(18_000_000_000))] {
            for (theme,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
                let model = BeaconModel(); model.disk = DiskReading(total: live.total,free: free); model.login = true; model.alerts = true; model.recommendations = exampleRecommendations()
                let renderer = ImageRenderer(content: BeaconPanel(model: model).environment(\.colorScheme,scheme))
                renderer.scale = 2
                guard let image = renderer.cgImage else { throw NSError(domain: "HeimdallRender",code: 1) }
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let data = bitmap.representation(using: .png,properties: [:]) else { throw NSError(domain: "HeimdallRender",code: 2) }
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(theme).png"))
            }
        }
        for offline in [false,true] {
            for (theme,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
                let model = BeaconModel()
                model.selectedID = "example-external"; model.selectedName = "External SSD"
                model.targets.append(DiskTarget(id: "example-external",name: "External SSD",path: "/Volumes/Example"))
                model.login = true; model.alerts = true
                model.disconnected = offline; model.error = offline
                model.disk = offline ? nil : DiskReading(total: 1_000_000_000_000,free: 768_000_000_000)
                if offline { model.targets = [.internalDisk] }
                let renderer = ImageRenderer(content: BeaconPanel(model: model).environment(\.colorScheme,scheme)); renderer.scale = 2
                guard let image = renderer.cgImage,let data = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) else { throw NSError(domain: "HeimdallRender",code: 4) }
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(offline ? "offline" : "external")-\(theme).png"))
            }
        }
        for (theme,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
            let models = [live.free,Int64(42_000_000_000),Int64(18_000_000_000)].map { free -> BeaconModel in
                let model = BeaconModel(); model.disk = DiskReading(total: live.total,free: free); model.login = true; model.alerts = true; model.recommendations = exampleRecommendations(); return model
            }
            let presentation = VStack(alignment: .leading,spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Heimdall").font(.system(size: 26,weight: .semibold))
                    Text("A quiet watch on your storage").font(.system(size: 13)).foregroundStyle(.secondary)
                }.padding(.horizontal,4)
                HStack(alignment: .top,spacing: 18) {
                    ForEach(Array(models.enumerated()),id: \.offset) { index,model in
                        VStack(alignment: .leading,spacing: 12) {
                            HStack(spacing: 8) {
                                Text(index == 0 ? "NORMAL" : index == 1 ? "WARNING" : "CRITICAL").font(.system(size: 10,weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int((model.fraction * 100).rounded()))% · \(Int(model.freeGB.rounded(.down))) GB")
                                    .font(.system(size: 12,weight: .medium)).monospacedDigit()
                                    .foregroundStyle(index == 0 ? Color.primary : model.tint)
                            }.padding(.horizontal,8).frame(height: 30)
                            BeaconPanel(model: model).clipShape(RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.07),lineWidth: 1))
                        }.frame(width: 360)
                    }
                }
                Text("Rendered from the app’s shared interface. All disk readings in these pictures are made-up examples.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal,4)
            }.padding(28).background(scheme == .dark ? Color(white: 0.09) : Color(white: 0.92)).environment(\.colorScheme,scheme)
            let renderer = ImageRenderer(content: presentation); renderer.scale = 2
            guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) else { throw NSError(domain: "HeimdallRender",code: 3) }
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("overview-\(theme).png"))
        }
        try renderHubPreviews(to: directory)
        try renderCleanupPreviews(to: directory)
        try renderStoragePreviews(to: directory)
        print("Rendered shared app UI to \(directory). All readings use example values.")
    } catch { fputs("Preview failed: \(error)\n",stderr); exit(1) }
}
