import AppKit
import SwiftUI

final class BeaconModel: ObservableObject {
    @Published var disk: DiskReading?
    @Published var warning = 60
    @Published var critical = 25
    @Published var login = false
    @Published var updated = Date()
    @Published var error = false
    var refreshAction: () -> Void = {}
    var presetAction: (Int,Int) -> Void = { _,_ in }
    var loginAction: () -> Void = {}
    var storageAction: () -> Void = {}
    var quitAction: () -> Void = {}
    var freeGB: Double { Double(disk?.free ?? 0) / 1e9 }
    var fraction: Double { disk?.fraction ?? 0 }
    var state: String { error ? "Unavailable" : freeGB < Double(critical) ? "Critical" : freeGB < Double(warning) ? "Getting tight" : "Healthy" }
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
            }.buttonStyle(FluidPress()).accessibilityLabel("Launch at login")
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
                    Text("Watching your internal disk").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.refreshAction) { Image(systemName: "arrow.clockwise").frame(width: 36,height: 36).background(surface,in: RoundedRectangle(cornerRadius: 10)) }
                    .buttonStyle(FluidPress()).help("Refresh disk usage").accessibilityLabel("Refresh disk usage")
            }
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
                    Text(model.error ? "Couldn’t read disk usage. Try refreshing." : model.freeGB < Double(model.critical) ? "Make room before your next install or update." : model.freeGB < Double(model.warning) ? "Space is getting low. A good time to offload files." : "Plenty of space available.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
                }
            }
            panel {
                VStack(alignment: .leading,spacing: 12) {
                    Text("Warn me when space gets low").font(.system(size: 13,weight: .semibold))
                    HStack(spacing: 5) {
                        preset("Relaxed",30,10)
                        preset("Balanced",60,25)
                        preset("Early",100,50)
                    }.padding(4).background(canvas,in: RoundedRectangle(cornerRadius: 11))
                    HStack(spacing: 6) {
                        Circle().fill(Color.orange).frame(width: 5,height: 5)
                        Text("Amber below \(model.warning) GB").font(.system(size: 10))
                        Spacer(minLength: 3)
                        Circle().fill(Color.red).frame(width: 5,height: 5)
                        Text("Red below \(model.critical) GB").font(.system(size: 10))
                    }.foregroundStyle(.secondary)
                }
            }
            panel {
                Toggle(isOn: Binding(get: { model.login },set: { _ in model.loginAction() })) {
                    VStack(alignment: .leading,spacing: 4) {
                        Text("Launch at login").font(.system(size: 13,weight: .medium))
                        Text("Keep a quiet eye on available space").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(FluidToggle())
            }
            Button(action: model.storageAction) {
                HStack { Image(systemName: "internaldrive"); Text("Open Storage Settings"); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 10,weight: .semibold)) }
                    .font(.system(size: 13,weight: .medium)).padding(.horizontal,14).frame(height: 42)
                    .background(surface,in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(border,lineWidth: 1))
            }.buttonStyle(FluidPress())
            HStack {
                Text("Updated \(model.updated,style: .time)").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit",action: model.quitAction).font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.plain)
            }.padding(.horizontal,2)
        }
        .padding(18).frame(width: 360).background(canvas).foregroundStyle(.primary)
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
        let live = try DiskReading.read()
        for (name,free) in [("healthy",live.free),("warning",Int64(42_000_000_000)),("critical",Int64(18_000_000_000))] {
            for (theme,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
                let model = BeaconModel(); model.disk = DiskReading(total: live.total,free: free); model.login = true
                let renderer = ImageRenderer(content: BeaconPanel(model: model).environment(\.colorScheme,scheme))
                renderer.scale = 2
                guard let image = renderer.cgImage else { throw NSError(domain: "HeimdallRender",code: 1) }
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let data = bitmap.representation(using: .png,properties: [:]) else { throw NSError(domain: "HeimdallRender",code: 2) }
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(theme).png"))
            }
        }
        for (theme,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
            let models = [live.free,Int64(42_000_000_000),Int64(18_000_000_000)].map { free -> BeaconModel in
                let model = BeaconModel(); model.disk = DiskReading(total: live.total,free: free); model.login = true; return model
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
                                Image(nsImage: diskStatusIcon(color: NSColor(model.tint),fraction: model.fraction))
                                Text("\(Int((model.fraction * 100).rounded()))% · \(Int(model.freeGB.rounded(.down))) GB")
                                    .font(.system(size: 12,weight: .medium)).monospacedDigit()
                            }.padding(.horizontal,8).frame(height: 30)
                            BeaconPanel(model: model).clipShape(RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.07),lineWidth: 1))
                        }.frame(width: 360)
                    }
                }
                Text("Rendered from the app’s shared interface. Normal shows the current disk reading; warning and critical show example values.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal,4)
            }.padding(28).background(scheme == .dark ? Color(white: 0.09) : Color(white: 0.92)).environment(\.colorScheme,scheme)
            let renderer = ImageRenderer(content: presentation); renderer.scale = 2
            guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) else { throw NSError(domain: "HeimdallRender",code: 3) }
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("overview-\(theme).png"))
        }
        print("Rendered shared app UI to \(directory). Warning and critical use example values.")
    } catch { fputs("Preview failed: \(error)\n",stderr); exit(1) }
}
