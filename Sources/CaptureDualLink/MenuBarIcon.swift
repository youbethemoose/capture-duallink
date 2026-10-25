import AppKit

/// A linked DL monogram, distinct from macOS's overlapping-screen symbol.
/// AppKit draws the vector at the destination scale and supplies the menu-bar tint.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()

            let mark = NSBezierPath()
            mark.lineWidth = 1.8
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round

            // D: a squared stem and a generous curve keep the counter open at 1×.
            mark.move(to: NSPoint(x: 2.5, y: 3.5))
            mark.line(to: NSPoint(x: 2.5, y: 14.5))
            mark.line(to: NSPoint(x: 6.5, y: 14.5))
            mark.curve(to: NSPoint(x: 12, y: 9),
                       controlPoint1: NSPoint(x: 9.9, y: 14.5),
                       controlPoint2: NSPoint(x: 12, y: 12.5))
            mark.curve(to: NSPoint(x: 6.5, y: 3.5),
                       controlPoint1: NSPoint(x: 12, y: 5.5),
                       controlPoint2: NSPoint(x: 9.9, y: 3.5))
            mark.close()

            // L and the bridge read as one continuous link through the D.
            mark.move(to: NSPoint(x: 15.5, y: 14.5))
            mark.line(to: NSPoint(x: 15.5, y: 3.5))
            mark.line(to: NSPoint(x: 20, y: 3.5))
            mark.move(to: NSPoint(x: 8.5, y: 9))
            mark.line(to: NSPoint(x: 15.5, y: 9))
            mark.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Capture DualLink"
        return image
    }()
}
