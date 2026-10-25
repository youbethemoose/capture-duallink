import AppKit

/// A photographic shutter linked to a second view, distinct from Screen Mirroring.
/// AppKit draws the vector at the destination scale and supplies the menu-bar tint.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let link = NSBezierPath()
            link.lineWidth = 1.65
            link.lineCapStyle = .round
            link.appendArc(withCenter: NSPoint(x: 6.3, y: 9), radius: 4.6,
                           startAngle: 82, endAngle: 278)
            link.stroke()
            drawIris(center: NSPoint(x: 12.5, y: 9), radius: 6.75)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Capture DualLink"
        return image
    }()

    private static func drawIris(center: NSPoint, radius: CGFloat) {
        let outer = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
        outer.lineWidth = 1.45
        outer.stroke()

        func point(_ r: CGFloat, _ degrees: CGFloat) -> NSPoint {
            let angle = degrees * .pi / 180
            return NSPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }

        // An open hexagonal iris and six swept blades stay legible at 1× and Retina.
        let blades = NSBezierPath()
        blades.lineWidth = 1.15
        blades.lineCapStyle = .round
        blades.lineJoinStyle = .round
        for i in 0..<6 {
            let vertex = point(2.65, CGFloat(i) * 60 + 30)
            if i == 0 { blades.move(to: vertex) } else { blades.line(to: vertex) }
        }
        blades.close()
        for i in 0..<6 {
            let angle = CGFloat(i) * 60 + 30
            blades.move(to: point(2.65, angle))
            blades.line(to: point(radius, angle + 60))
        }
        blades.stroke()
    }
}
