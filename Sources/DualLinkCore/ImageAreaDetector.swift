import Foundation
import CoreGraphics

public struct RGB: Equatable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// Finds the camera picture inside a viewer that letterboxes it with a flat background.
///
/// Capture One draws Live View on a perfectly uniform background. A camera feed is never
/// uniform: sensor noise and compression texture survive even on a gray seamless backdrop.
/// So a background bar is an edge row or column whose samples (nearly) all equal one exact color.
/// Errors are conservative: an ambiguous edge leaves background visible rather than cutting
/// into the picture.
public enum ImageAreaDetector {
    /// `pixel(x, y)` uses a top-left origin. Returns the picture in the same coordinates,
    /// or nil when the region holds no picture yet (for example, entirely background).
    public static func detect(width: Int, height: Int, tolerance: Int = 2,
                              pixel: (Int, Int) -> RGB) -> CGRect? {
        guard width >= 16, height >= 16 else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let step = max(1, max(width, height) / 400)

        // The background is the most common color around the perimeter. Color conversion
        // dithers flat areas by ±1, so its share counts every sample within tolerance.
        var perimeter: [RGB] = []
        for x in stride(from: 0, to: width, by: step) { perimeter.append(pixel(x, 0)); perimeter.append(pixel(x, height - 1)) }
        for y in stride(from: 0, to: height, by: step) { perimeter.append(pixel(0, y)); perimeter.append(pixel(width - 1, y)) }
        var counts: [UInt32: Int] = [:]
        for c in perimeter { counts[UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b), default: 0] += 1 }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return full }
        let background = RGB(UInt8(key >> 16 & 0xFF), UInt8(key >> 8 & 0xFF), UInt8(key & 0xFF))
        func matches(_ c: RGB) -> Bool {
            abs(Int(c.r) - Int(background.r)) <= tolerance &&
            abs(Int(c.g) - Int(background.g)) <= tolerance &&
            abs(Int(c.b) - Int(background.b)) <= tolerance
        }
        guard perimeter.filter(matches).count * 4 >= perimeter.count else { return full }
        func flat(_ samples: StrideTo<Int>, _ sample: (Int) -> RGB) -> Bool {
            var n = 0, m = 0
            for i in samples { n += 1; if matches(sample(i)) { m += 1 } }
            return n > 0 && m * 100 >= n * 95
        }
        // Allow a few non-background lines at the very edge, such as an imperfect toolbar trim.
        func band(_ length: Int, isFlat: (Int) -> Bool) -> Int {
            let skip = max(2, length * 3 / 100)
            var i = 0
            while i < skip, i < length, !isFlat(i) { i += 1 }
            guard i < skip, i < length else { return 0 }
            while i < length, isFlat(i) { i += 1 }
            return i
        }

        var left = 0, right = 0, top = 0, bottom = 0
        for _ in 0..<2 {
            let columns = stride(from: left, to: width - right, by: step)
            top = band(height) { y in flat(columns) { pixel($0, y) } }
            bottom = band(height) { y in flat(columns) { pixel($0, height - 1 - y) } }
            guard top + bottom < height else { return nil }
            let rows = stride(from: top, to: height - bottom, by: step)
            left = band(width) { x in flat(rows) { pixel(x, $0) } }
            right = band(width) { x in flat(rows) { pixel(width - 1 - x, $0) } }
            guard left + right < width else { return nil }
        }

        func balance(_ a: Int, _ b: Int, _ length: Int) -> (Int, Int) {
            let slack = max(2 * step, length * 3 / 100)
            if max(a, b) <= slack || abs(a - b) <= slack { return (a, b) }
            if min(a, b) == 0 { return (0, 0) } // One-sided: picture content that matches the background.
            let m = min(a, b)
            return (m, m)
        }
        (top, bottom) = balance(top, bottom, height)
        (left, right) = balance(left, right, width)
        let area = CGRect(x: left, y: top, width: width - left - right, height: height - top - bottom)
        guard area.width * 5 >= CGFloat(width), area.height * 5 >= CGFloat(height) else { return nil }
        return area
    }
}

/// Smooths detection over time: a new picture area must be seen twice before it replaces
/// the current one, except after the region changes size or when nothing is known yet.
public struct ImageAreaTracker {
    public private(set) var area: CGRect?
    private var size: CGSize = .zero
    private var candidate: CGRect?

    public init() {}

    /// Returns true when `area` changed.
    public mutating func update(regionSize: CGSize, detected: CGRect?, tolerance: CGFloat) -> Bool {
        func close(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
        }
        let previous = area
        if regionSize != size {
            size = regionSize; candidate = nil; area = detected
        } else if let detected {
            if let current = area, close(current, detected) {
                candidate = nil
            } else if area == nil || candidate.map({ close($0, detected) }) == true {
                area = detected; candidate = nil
            } else {
                candidate = detected
            }
        } else {
            candidate = nil // Agreement must be consecutive.
        }
        return area != previous
    }

    public mutating func reset() { self = ImageAreaTracker() }
}
