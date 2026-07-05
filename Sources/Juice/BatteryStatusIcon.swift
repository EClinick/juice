import AppKit

/// Draws the menu bar battery glyph in the style of the system status item:
/// a rounded-rect outline with a terminal nub, an interior fill whose width is
/// proportional to the charge percent, and a lightning bolt knocked out of the
/// fill while plugged in. Pure: the image depends only on the inputs.
enum BatteryStatusIcon {
    /// Glyph size in points; the drawing handler re-renders at each backing
    /// scale so retina menu bars stay crisp.
    static let size = NSSize(width: 26, height: 13)

    /// Convenience over the current reading; a missing reading renders as a
    /// full battery so the item never looks broken at startup.
    static func image(for reading: BatteryReading?) -> NSImage {
        guard let r = reading else {
            return image(percent: 100, isCharging: false, onAC: false)
        }
        return image(percent: r.percent, isCharging: r.isCharging, onAC: r.onAC)
    }

    static func image(percent: Int, isCharging: Bool, onAC: Bool) -> NSImage {
        let percent = min(max(percent, 0), 100)
        // Match the system's low-battery treatment: red fill, and the image is
        // no longer a template so the red survives menu bar tinting.
        let isLow = percent <= 20 && !onAC
        // Like the system icon, the bolt shows whenever the charger is
        // plugged in, including when the battery is full and merely held.
        let showBolt = isCharging || onAC
        let image = NSImage(size: size, flipped: false) { _ in
            draw(percent: percent, showBolt: showBolt, isLow: isLow)
            return true
        }
        image.isTemplate = !isLow
        return image
    }

    private static func draw(percent: Int, showBolt: Bool, isLow: Bool) {
        // Template images must be pure black; the non-template low-battery
        // variant uses labelColor so the outline still adapts to the menu
        // bar's appearance (the handler re-runs at every draw).
        let color = isLow ? NSColor.labelColor : NSColor.black

        // Body outline: geometry on half-points so the 1 pt stroke lands on
        // whole pixels at 1x (and pairs of pixels at 2x) instead of blurring.
        let bodyRect = NSRect(x: 0.5, y: 1.5, width: 21, height: 10)
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: 3, yRadius: 3)
        body.lineWidth = 1
        color.setStroke()
        body.stroke()

        // Terminal nub, vertically centered against the body.
        let nubRect = NSRect(x: 22.5, y: 4.75, width: 2, height: 3.5)
        color.setFill()
        NSBezierPath(roundedRect: nubRect, xRadius: 1, yRadius: 1).fill()

        // Interior fill: 1 pt gap inside the stroke, width proportional to
        // the charge with a minimum sliver so 1% never reads as empty-broken.
        let interior = NSRect(x: 2, y: 3, width: 18, height: 7)
        if percent > 0 {
            let width = max(1.5, interior.width * CGFloat(percent) / 100)
            let fillRect = NSRect(
                x: interior.minX, y: interior.minY,
                width: width, height: interior.height)
            (isLow ? NSColor.systemRed : color).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()
        }

        guard showBolt else { return }

        // First punch a bolt-shaped halo out of the fill (destinationOut) so
        // the glyph stays legible over it, then draw the bolt itself in the
        // template color.
        let bolt = boltPath()
        if let context = NSGraphicsContext.current {
            context.saveGraphicsState()
            context.compositingOperation = .destinationOut
            bolt.lineWidth = 2.5
            bolt.lineJoinStyle = .round
            color.setStroke()
            color.setFill()
            bolt.stroke()
            bolt.fill()
            context.restoreGraphicsState()
        }
        color.setFill()
        bolt.fill()
    }

    /// Six-point lightning bolt centered on the battery body, slightly taller
    /// than the interior so the tips touch the outline like the system glyph.
    private static func boltPath() -> NSBezierPath {
        let frame = NSRect(x: 7.5, y: 1.5, width: 7, height: 10)
        // Unit coordinates (origin bottom-left) traced clockwise from the top tip.
        let points: [(CGFloat, CGFloat)] = [
            (0.62, 1.00), (0.08, 0.45), (0.46, 0.45),
            (0.34, 0.00), (0.92, 0.55), (0.50, 0.55),
        ]
        let path = NSBezierPath()
        for (i, p) in points.enumerated() {
            let point = NSPoint(
                x: frame.minX + p.0 * frame.width,
                y: frame.minY + p.1 * frame.height)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }
}
