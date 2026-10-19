import Foundation
import CoreGraphics

public enum ImageFit: String, CaseIterable {
    case fit = "Fit — show entire image"
    case fill = "Fill — crop to window"
}

/// Fixed source chrome to remove, in the source window's logical points.
/// Points keep the trim correct when the source window is resized or moves
/// to a display with another pixel density; toolbars don't scale with the window.
public struct SourceTrim: Equatable, Codable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }

    public static let none = SourceTrim()

    /// Shrinks a top-left-origin pixel rect, always leaving at least `minimum` pixels per axis.
    public func apply(to rect: CGRect, pixelScale: CGFloat, minimum: CGFloat = 16) -> CGRect {
        let scale = pixelScale.isFinite && pixelScale > 0 ? pixelScale : 1
        func clean(_ value: Double) -> CGFloat { value.isFinite ? max(0, CGFloat(value)) * scale : 0 }
        let floor = min(minimum, rect.width, rect.height)
        var l = clean(left), r = clean(right), t = clean(top), b = clean(bottom)
        if l + r > rect.width - floor { let k = max(0, rect.width - floor) / (l + r); l *= k; r *= k }
        if t + b > rect.height - floor { let k = max(0, rect.height - floor) / (t + b); t *= k; b *= k }
        return CGRect(x: rect.minX + l, y: rect.minY + t,
                      width: rect.width - l - r, height: rect.height - t - b).integral
    }
}

public enum ImageGeometry {
    /// ScreenCaptureKit's content rect is in logical points with a top-left origin.
    /// Convert it to buffer pixels before cropping with Core Image.
    public static func captureContentRect(points: CGRect, pixelScale: CGFloat, bufferSize: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: bufferSize)
        guard points.width > 0, points.height > 0,
              points.minX.isFinite, points.minY.isFinite,
              points.width.isFinite, points.height.isFinite else { return bounds }
        let scale = pixelScale.isFinite && pixelScale > 0 ? pixelScale : 1
        let pixels = CGRect(x: points.minX * scale, y: bufferSize.height - points.maxY * scale,
                            width: points.width * scale, height: points.height * scale)
        let clipped = pixels.intersection(bounds)
        return clipped.isEmpty ? bounds : clipped
    }

    /// Converts between top-left (buffer memory) and bottom-left (Core Image) origins.
    public static func flipped(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// All dimensions are real pixels, never logical display points.
    public static func placement(source: CGSize, destination: CGSize, mode: ImageFit) -> CGRect {
        guard source.width > 0, source.height > 0, destination.width > 0, destination.height > 0,
              source.width.isFinite, source.height.isFinite,
              destination.width.isFinite, destination.height.isFinite else { return .zero }
        let x = destination.width / source.width
        let y = destination.height / source.height
        let scale = mode == .fit ? min(x, y) : max(x, y)
        let result = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (destination.width - result.width) / 2, y: (destination.height - result.height) / 2,
                      width: result.width, height: result.height)
    }

    /// Maps a rect in source pixels through a placement of the whole source.
    public static func map(_ rect: CGRect, source: CGSize, into placement: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return .zero }
        let sx = placement.width / source.width, sy = placement.height / source.height
        return CGRect(x: placement.minX + rect.minX * sx, y: placement.minY + rect.minY * sy,
                      width: rect.width * sx, height: rect.height * sy)
    }

    /// Limit the source size proportionally; never upscale or force a 16:9 aspect ratio.
    public static func captureSize(points: CGSize, pixelScale: CGFloat, maximumEdge: Int?) -> CGSize {
        let scale = pixelScale.isFinite ? max(1, pixelScale) : 1
        var width = points.width.isFinite ? max(2, points.width * scale) : 2
        var height = points.height.isFinite ? max(2, points.height * scale) : 2
        let cap = CGFloat(max(2, maximumEdge ?? 8192))
        let ratio = min(1, cap / max(width, height))
        width *= ratio; height *= ratio
        return CGSize(width: max(2, Int(width.rounded())), height: max(2, Int(height.rounded())))
    }
}
