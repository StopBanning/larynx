import AppKit

/// App icons for the pill. A dark square tile (Claude, Terminal) reads as a black hole in clear glass, so when an
/// icon's tile is one flat dark colour, the tile is removed and only the mark on it is shown, scaled to fill the slot.
/// Coloured tiles (Messages, Mail) are part of the app's identity and are kept.
enum AppIcon {
    private nonisolated(unsafe) static var cache: [String: NSImage] = [:]

    static func forPill(_ app: NSRunningApplication?) -> NSImage? {
        guard let app, let icon = app.icon else { return nil }
        // Icons have dark and light variants, so the appearance is part of the key.
        let key = (app.bundleIdentifier ?? app.bundleURL?.path ?? "\(app.processIdentifier)") + "|" + NSApp.effectiveAppearance.name.rawValue
        if let hit = cache[key] { return hit }
        let result = withoutDarkTile(icon) ?? icon
        cache[key] = result
        return result
    }

    private static func insideRoundedRect(_ x: Double, _ y: Double, lo: Double, hi: Double, radius: Double) -> Bool {
        guard x >= lo, x <= hi, y >= lo, y <= hi else { return false }
        let cx = min(max(x, lo + radius), hi - radius), cy = min(max(y, lo + radius), hi - radius)
        return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius
    }

    /// The icon with its dark tile keyed out and cropped to the mark, or nil when the tile isn't flat and dark.
    static func withoutDarkTile(_ icon: NSImage, side: Int = 128) -> NSImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: side * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        func px(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let i = (y * side + x) * 4
            let a = Double(data[i + 3]) / 255
            guard a > 0 else { return (0, 0, 0, 0) }
            return (Double(data[i]) / 255 / a, Double(data[i + 1]) / 255 / a, Double(data[i + 2]) / 255 / a, a)
        }
        // The tile: a ring of points just inside the edge of a standard macOS icon (tile spans about 10%-90%).
        let s = Double(side)
        let ring = [(0.15, 0.5), (0.85, 0.5), (0.5, 0.15), (0.5, 0.85), (0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8),
                    (0.15, 0.3), (0.85, 0.7), (0.3, 0.85), (0.7, 0.15)].map { px(Int($0.0 * s), Int($0.1 * s)) }
        guard ring.allSatisfy({ $0.a > 0.95 }) else { return nil }
        let lum = ring.map { 0.2126 * $0.r + 0.7152 * $0.g + 0.0722 * $0.b }
        guard let lo = lum.min(), let hi = lum.max(), hi < 0.22, hi - lo < 0.1 else { return nil }
        let tile = (r: ring.map(\.r).reduce(0, +) / 12, g: ring.map(\.g).reduce(0, +) / 12, b: ring.map(\.b).reduce(0, +) / 12)

        // Key out everything close to the tile colour (and the dark drop shadow around it); keep the mark.
        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side {
                let p = px(x, y)
                let i = (y * side + x) * 4
                let d = max(abs(p.r - tile.r), abs(p.g - tile.g), abs(p.b - tile.b))
                // The tile's bright rim sits at the edge; the mark never reaches it, so only the inner area counts.
                let inner = insideRoundedRect(Double(x) + 0.5, Double(y) + 0.5, lo: 0.13 * s, hi: 0.87 * s, radius: 0.16 * s)
                let keep = inner ? min(1, max(0, (d - 0.08) / 0.17)) * p.a : 0
                let a = UInt8((keep * 255).rounded())
                data[i] = UInt8(min(255, (p.r * keep * 255).rounded()))
                data[i + 1] = UInt8(min(255, (p.g * keep * 255).rounded()))
                data[i + 2] = UInt8(min(255, (p.b * keep * 255).rounded()))
                data[i + 3] = a
                if a > 40 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        // Nothing left, or nearly all of it (a photo-like icon): keep the original.
        guard maxX > minX, maxY > minY, Double((maxX - minX) * (maxY - minY)) < 0.8 * s * s else { return nil }
        let crop = NSRect(x: minX, y: side - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
        let full = NSImage(size: NSSize(width: side, height: side))
        full.addRepresentation(rep)
        let edge = max(crop.width, crop.height)
        let out = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { _ in
            full.draw(in: NSRect(x: (edge - crop.width) / 2, y: (edge - crop.height) / 2, width: crop.width, height: crop.height),
                      from: crop, operation: .sourceOver, fraction: 1)
            return true
        }
        return out
    }
}
