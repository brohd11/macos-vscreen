// Regenerate VScreen's icons: Resources/AppIcon*.icns and the menu-bar template images, in two
// styles: the default "overlap" set (bundled) and an alternate "-Inset" set (not bundled).
// Outputs are checked in; run by hand after changing the drawing:
//
//     swift scripts/make-icons.swift
//
// The intermediate iconsets are left in build/ for inspection.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Renders `draw` (in a `canvas`-point coordinate space, origin bottom-left) into a PNG of `pixels` square.
func png(pixels: Int, canvas: CGFloat, to url: URL, draw: () -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let scale = CGFloat(pixels) / canvas
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: App icon (1024 canvas, macOS grid: 824pt tile centered)

let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
let tileGradient = NSGradient(starting: color(0x323C52), ending: color(0x141925))!
let screenGradient = NSGradient(starting: color(0x5AC8FA), ending: color(0x0A6CFF))!

func shadow(alpha: CGFloat, offset: CGFloat, blur: CGFloat) -> NSShadow {
    let s = NSShadow()
    s.shadowColor = color(0x000000, alpha)
    s.shadowOffset = NSSize(width: 0, height: -offset)
    s.shadowBlurRadius = blur
    return s
}

func drawTile() {
    NSGraphicsContext.saveGraphicsState()
    shadow(alpha: 0.35, offset: 12, blur: 24).set()
    color(0x1B2130).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    tileGradient.draw(in: tile, angle: -90)
}

/// "overlap": a back screen upper left, a smaller front screen overlapping it lower right.
func drawOverlapAppIcon() {
    drawTile()

    // Back screen: upper left, glassy.
    let back = NSBezierPath(roundedRect: NSRect(x: 214, y: 356, width: 440, height: 440), xRadius: 64, yRadius: 64)
    NSGradient(starting: color(0xFFFFFF, 0.22), ending: color(0xFFFFFF, 0.08))!.draw(in: back, angle: -90)
    color(0xFFFFFF, 0.55).setStroke()
    back.lineWidth = 14
    back.stroke()

    // Front screen: lower right, overlapping, with a tile-colored gap around it.
    let frontRect = NSRect(x: 470, y: 228, width: 326, height: 326)
    let gap = NSBezierPath(roundedRect: frontRect.insetBy(dx: -22, dy: -22), xRadius: 70, yRadius: 70)
    NSGraphicsContext.saveGraphicsState()
    gap.addClip()
    tileGradient.draw(in: tile.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let front = NSBezierPath(roundedRect: frontRect, xRadius: 50, yRadius: 50)
    screenGradient.draw(in: front, angle: -60)
    color(0xFFFFFF, 0.35).setStroke()
    front.lineWidth = 6
    front.stroke()
}

/// "inset": the tile is the big screen; a 75% screen sits inside its top-left corner.
func drawInsetAppIcon() {
    drawTile()
    let bezel = NSBezierPath(roundedRect: tile.bounds.insetBy(dx: 8, dy: 8), xRadius: 177, yRadius: 177)
    color(0xFFFFFF, 0.18).setStroke()
    bezel.lineWidth = 10
    bezel.stroke()

    let front = NSBezierPath(roundedRect: NSRect(x: 144, y: 262, width: 618, height: 618), xRadius: 141, yRadius: 141)
    NSGraphicsContext.saveGraphicsState()
    shadow(alpha: 0.45, offset: 14, blur: 36).set()
    color(0x0A6CFF).setFill()
    front.fill()
    NSGraphicsContext.restoreGraphicsState()
    screenGradient.draw(in: front, angle: -60)
    color(0xFFFFFF, 0.35).setStroke()
    front.lineWidth = 8
    front.stroke()
}

// MARK: Menu bar templates (18pt canvas, black on transparent)

func drawInsetMenuBarIcon() {
    let outer = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 1.75, width: 14.5, height: 14.5), xRadius: 3.25, yRadius: 3.25)
    outer.lineWidth = 1.5
    NSColor.black.setStroke()
    outer.stroke()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: 1, y: 5, width: 12, height: 12), xRadius: 4, yRadius: 4).fill()
}

func drawOverlapMenuBarIcon() {
    let back = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 5.75, width: 10.5, height: 10.5), xRadius: 2.25, yRadius: 2.25)
    back.lineWidth = 1.5
    NSColor.black.setStroke()
    back.stroke()

    let frontRect = NSRect(x: 7.5, y: 1.5, width: 9, height: 9)
    NSGraphicsContext.current!.compositingOperation = .clear
    NSBezierPath(roundedRect: frontRect.insetBy(dx: -1.5, dy: -1.5), xRadius: 3.25, yRadius: 3.25).fill()
    NSGraphicsContext.current!.compositingOperation = .sourceOver
    NSColor.black.setFill()
    NSBezierPath(roundedRect: frontRect, xRadius: 2, yRadius: 2).fill()
}

/// Writes <name>.icns and the menu-bar pair; the intermediate iconset stays in build/.
func writeSet(suffix: String, app: @escaping () -> Void, menuBar: @escaping () -> Void) throws {
    let iconset = root.appendingPathComponent("build/AppIcon\(suffix).iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        try png(pixels: size, canvas: 1024, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"), draw: app)
        try png(pixels: size * 2, canvas: 1024, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"), draw: app)
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon\(suffix).icns").path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

    try png(pixels: 18, canvas: 18, to: resources.appendingPathComponent("MenuBarIcon\(suffix).png"), draw: menuBar)
    try png(pixels: 36, canvas: 18, to: resources.appendingPathComponent("MenuBarIcon\(suffix)@2x.png"), draw: menuBar)
    print("wrote Resources/AppIcon\(suffix).icns, Resources/MenuBarIcon\(suffix).png, Resources/MenuBarIcon\(suffix)@2x.png")
}

try writeSet(suffix: "", app: drawOverlapAppIcon, menuBar: drawOverlapMenuBarIcon)
try writeSet(suffix: "-Inset", app: drawInsetAppIcon, menuBar: drawInsetMenuBarIcon)
