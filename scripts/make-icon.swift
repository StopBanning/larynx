// Draws the Larynx app icon and the pictures made from it. Run from the repo root after changing the design:
//
//     swift scripts/make-icon.swift
//
// Writes packaging/Larynx.icns (copied into the app by make-app.sh), docs/images/icon.png (README) and
// docs/images/social-preview.png (the repo's link preview, uploaded by hand in the repo settings).
//
// The mark: voice bars that end in a text cursor. Sound goes in on the left, text comes out on the right. The tile
// is dark glass like the pill; the cursor is the one spot of colour. Sizes up to 64 px use three fatter bars.
import AppKit

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func capsule(_ r: CGRect) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: min(r.width, r.height) / 2, cornerHeight: min(r.width, r.height) / 2, transform: nil)
}
func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}
func gradient(_ g: CGContext, _ colors: [CGColor], from a: CGPoint, to b: CGPoint, in path: CGPath) {
    g.saveGState(); g.addPath(path); g.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    g.drawLinearGradient(grad, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    g.restoreGState()
}

/// The icon on a 1024 grid, scaled into `rect` of the current context.
func drawIcon(_ g: CGContext, in rect: CGRect, pixels: Int) {
    g.saveGState()
    g.translateBy(x: rect.minX, y: rect.minY)
    g.scaleBy(x: rect.width / 1024, y: rect.height / 1024)
    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)   // the macOS icon tile
    let tile = CGPath(roundedRect: tileRect, cornerWidth: 186, cornerHeight: 186, transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -12 * rect.height / 1024), blur: 28 * rect.height / 1024, color: rgb(0x000000, 0.32))
    g.addPath(tile); g.setFillColor(rgb(0x0D0E18)); g.fillPath()
    g.restoreGState()
    gradient(g, [rgb(0x2E3350), rgb(0x0D0E18)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100), in: tile)
    // Glass: a light band across the top and a thin bright rim.
    gradient(g, [rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 560), in: tile)
    g.saveGState(); g.addPath(tile); g.clip()
    g.addPath(CGPath(roundedRect: tileRect.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil))
    g.setStrokeColor(rgb(0xFFFFFF, 0.16)); g.setLineWidth(6); g.strokePath()
    g.restoreGState()

    let small = pixels <= 64
    let heights: [CGFloat] = small ? [200, 400, 280] : [150, 300, 440, 250]
    let barW: CGFloat = small ? 96 : 66, gap: CGFloat = small ? 60 : 46
    let caretH: CGFloat = small ? 500 : 470, stem: CGFloat = small ? 56 : 34, serif: CGFloat = small ? 150 : 124
    var x = 512 - (CGFloat(heights.count) * (barW + gap) + serif) / 2
    for h in heights {
        let r = CGRect(x: x, y: 512 - h / 2, width: barW, height: h)
        gradient(g, [rgb(0xFFFFFF), rgb(0xD9DCF5)], from: CGPoint(x: r.midX, y: r.maxY), to: CGPoint(x: r.midX, y: r.minY), in: capsule(r))
        x += barW + gap
    }
    let cx = x + serif / 2   // the I-beam: a stem with a short bar at each end
    g.setFillColor(rgb(0x4DA3FF))
    g.addPath(capsule(CGRect(x: cx - stem / 2, y: 512 - caretH / 2, width: stem, height: caretH)))
    g.addPath(capsule(CGRect(x: cx - serif / 2, y: 512 + caretH / 2 - stem, width: serif, height: stem)))
    g.addPath(capsule(CGRect(x: cx - serif / 2, y: 512 - caretH / 2, width: serif, height: stem)))
    g.fillPath()
    g.restoreGState()
}

func png(_ w: Int, _ h: Int, to path: String, _ draw: (CGContext) -> Void) {
    let rep = bitmap(w, h)
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.current?.flushGraphics()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let iconset = NSTemporaryDirectory() + "Larynx.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    png(px, px, to: "\(iconset)/icon_\(name).png") { drawIcon($0, in: CGRect(x: 0, y: 0, width: px, height: px), pixels: px) }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "packaging/Larynx.icns"]
try! iconutil.run(); iconutil.waitUntilExit()
try? fm.removeItem(atPath: iconset)

png(256, 256, to: "docs/images/icon.png") { drawIcon($0, in: CGRect(x: 0, y: 0, width: 256, height: 256), pixels: 256) }

// Link preview, 1280 x 640: the icon, the name, the line.
png(1280, 640, to: "docs/images/social-preview.png") { g in
    let all = CGRect(x: 0, y: 0, width: 1280, height: 640)
    gradient(g, [rgb(0x1B1E33), rgb(0x090A12)], from: CGPoint(x: 0, y: 640), to: CGPoint(x: 1280, y: 0), in: CGPath(rect: all, transform: nil))
    drawIcon(g, in: CGRect(x: 90, y: 130, width: 380, height: 380), pixels: 380)
    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
        (s as NSString).draw(at: NSPoint(x: 520, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
    text("Larynx", size: 104, weight: .bold, color: .white, y: 360)
    text("Think out loud. Larynx writes it down.", size: 36, weight: .medium, color: NSColor(white: 1, alpha: 0.92), y: 288)
    text("Free, private dictation for the Mac.", size: 30, weight: .regular, color: NSColor(white: 1, alpha: 0.62), y: 228)
    text("Open source  ·  works offline  ·  no account", size: 24, weight: .regular, color: NSColor(calibratedRed: 0.30, green: 0.64, blue: 1, alpha: 1), y: 170)
}
print("wrote packaging/Larynx.icns, docs/images/icon.png, docs/images/social-preview.png")
