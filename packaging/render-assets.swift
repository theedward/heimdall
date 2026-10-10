import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination,withIntermediateDirectories: true)
func save(_ name: String,_ width: Int,_ height: Int,draw: () -> Void) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: width,pixelsHigh: height,bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    draw(); NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png,properties: [:])!.write(to: destination.appendingPathComponent(name))
}
func text(_ value: String,x: CGFloat,y: CGFloat,size: CGFloat,weight: NSFont.Weight = .regular,color: NSColor = NSColor(white: 0.4,alpha: 1)) {
    (value as NSString).draw(at: NSPoint(x: x,y: y),withAttributes: [.font: NSFont.systemFont(ofSize: size,weight: weight),.foregroundColor: color])
}
try save("app-icon.png",1024,1024) {
    NSColor.clear.setFill(); NSRect(x: 0,y: 0,width: 1024,height: 1024).fill()
    NSColor(white: 0.13,alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 76,y: 76,width: 872,height: 872),xRadius: 200,yRadius: 200).fill()
    NSColor(white: 0.32,alpha: 1).setStroke()
    let border = NSBezierPath(roundedRect: NSRect(x: 77,y: 77,width: 870,height: 870),xRadius: 200,yRadius: 200); border.lineWidth = 2; border.stroke()
    let symbol = NSImage(systemSymbolName: "shield.lefthalf.filled",accessibilityDescription: nil)!
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 380,weight: .medium).applying(NSImage.SymbolConfiguration(paletteColors: [.white])))!
    symbol.draw(in: NSRect(x: 260,y: 235,width: 504,height: 554))
}
func background() {
    NSColor(white: 0.955,alpha: 1).setFill(); NSRect(x: 0,y: 0,width: 560,height: 360).fill()
    text("Install Heimdall",x: 38,y: 285,size: 28,weight: .semibold,color: NSColor(white: 0.14,alpha: 1))
    text("A quiet watch on your storage.",x: 39,y: 262,size: 13)
    for x in [CGFloat(48),CGFloat(322)] {
        let shape = NSBezierPath(roundedRect: NSRect(x: x,y: 86,width: 190,height: 152),xRadius: 20,yRadius: 20)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.035); shadow.shadowBlurRadius = 7; shadow.shadowOffset = NSSize(width: 0,height: -2)
        NSGraphicsContext.saveGraphicsState(); shadow.set(); NSColor.white.setFill(); shape.fill(); NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.06).setStroke(); shape.lineWidth = 1; shape.stroke()
    }
    let arrow = NSImage(systemSymbolName: "arrow.right",accessibilityDescription: nil)!.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26,weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 0.5,alpha: 1)])))!
    arrow.draw(in: NSRect(x: 264,y: 147,width: 32,height: 24))
    text("Drag Heimdall into Applications",x: 162,y: 51,size: 14,weight: .medium,color: NSColor(white: 0.22,alpha: 1))
    text("Then open it from Applications. Look for the disk in your menu bar.",x: 67,y: 26,size: 11)
}
try save("installer-background.png",560,360,draw: background)
try save("installer-preview.png",1120,720) {
    NSGraphicsContext.current!.cgContext.scaleBy(x: 2,y: 2)
    background()
    NSImage(contentsOf: destination.appendingPathComponent("app-icon.png"))!.draw(in: NSRect(x: 102,y: 132,width: 88,height: 88))
    NSWorkspace.shared.icon(forFile: "/Applications").draw(in: NSRect(x: 376,y: 132,width: 88,height: 88))
    text("Heimdall",x: 122,y: 110,size: 12,color: NSColor(white: 0.14,alpha: 1))
    text("Applications",x: 385,y: 110,size: 12,color: NSColor(white: 0.14,alpha: 1))
}
