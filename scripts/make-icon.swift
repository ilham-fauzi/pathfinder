// Draws the Pathfinder app icon and writes design/AppIcon-1024.png.
// Run: swift scripts/make-icon.swift   (scripts/build-icon.sh then builds the .icns)
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS icon grid: 824 pt body centred in the 1024 canvas.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

// Soft shadow under the body.
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0x1B2A8A).setFill()
squircle.fill()
cg.restoreGState()

// Background gradient: bright blue (top) to deep indigo (bottom).
cg.saveGState()
squircle.addClip()
NSGradient(colors: [color(0x4C8DFF), color(0x2E4BDB), color(0x2A1B9E)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: body, angle: -90)
// Glossy highlight on the upper half.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)],
           atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(in: NSRect(x: body.minX, y: body.midY + 40, width: body.width, height: body.height / 2 - 40), angle: -90)
cg.restoreGState()

// Progress ring: faint track plus a bright three-quarter arc.
let center = CGPoint(x: 512, y: 512)
let radius: CGFloat = 268
let ringWidth: CGFloat = 56
func arc(from start: CGFloat, to end: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    p.lineWidth = ringWidth
    p.lineCapStyle = .round
    return p
}
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
NSColor.white.withAlphaComponent(0.25).setStroke()
arc(from: 90, to: 90 - 359.9).stroke()
NSColor.white.setStroke()
arc(from: 90, to: 90 - 270).stroke()     // starts at 12 o'clock, runs clockwise 75%
cg.restoreGState()

// Download arrow.
let arrow = NSBezierPath()
let shaftW: CGFloat = 92, headW: CGFloat = 250
let top: CGFloat = 690, headBase: CGFloat = 535, tip: CGFloat = 340
arrow.move(to: CGPoint(x: 512 - shaftW / 2, y: top))
arrow.line(to: CGPoint(x: 512 + shaftW / 2, y: top))
arrow.line(to: CGPoint(x: 512 + shaftW / 2, y: headBase))
arrow.line(to: CGPoint(x: 512 + headW / 2, y: headBase))
arrow.line(to: CGPoint(x: 512, y: tip))
arrow.line(to: CGPoint(x: 512 - headW / 2, y: headBase))
arrow.line(to: CGPoint(x: 512 - shaftW / 2, y: headBase))
arrow.close()
arrow.lineJoinStyle = .round
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: NSColor.black.withAlphaComponent(0.3).cgColor)
NSColor.white.setFill()
arrow.fill()
cg.restoreGState()
NSColor.white.setStroke()
arrow.lineWidth = 26
arrow.stroke()      // rounds the corners (no shadow, so it does not draw over the fill)

let data = rep.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: "design/AppIcon-1024.png"))
print("wrote design/AppIcon-1024.png")
