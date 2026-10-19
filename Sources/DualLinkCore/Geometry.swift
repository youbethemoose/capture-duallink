import Foundation
import CoreGraphics

public enum ImageFit: String, CaseIterable {
    case fit = "Fit — show entire image"
    case fill = "Fill — crop to window"
    case actualPixels = "Actual pixels — 1:1"
}

/// Pan is normalized to the available overflow, so it survives display-density changes.
public struct ImageViewport: Equatable {
    public let zoom: CGFloat
    public let pan: CGPoint
    public static let identity = ImageViewport()

    public init(zoom: CGFloat = 1, pan: CGPoint = .zero) {
        self.zoom = zoom.isFinite ? min(8, max(1, zoom)) : 1
        self.pan = CGPoint(x: Self.clamp(pan.x), y: Self.clamp(pan.y))
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(1, max(-1, value)) : 0
    }

    public func panned(by delta: CGPoint, source: CGSize, destination: CGSize, mode: ImageFit) -> Self {
        let rect = ImageGeometry.placement(source: source, destination: destination, mode: mode, viewport: self)
        let overflowX = max(0, rect.width - destination.width)
        let overflowY = max(0, rect.height - destination.height)
        return Self(zoom: zoom, pan: CGPoint(x: overflowX > 0 ? pan.x + 2 * delta.x / overflowX : 0,
                                           y: overflowY > 0 ? pan.y + 2 * delta.y / overflowY : 0))
    }

    /// Keep the image under a pinch's focal point still, subject to the image edges.
    public func zoomed(by factor: CGFloat, source: CGSize, destination: CGSize,
                       mode: ImageFit, anchor: CGPoint? = nil) -> Self {
        guard factor.isFinite, factor > 0 else { return self }
        let next = Self(zoom: zoom * factor)
        let before = ImageGeometry.placement(source: source, destination: destination, mode: mode, viewport: self)
        let after = ImageGeometry.placement(source: source, destination: destination, mode: mode, viewport: next)
        guard before.width > 0, after.width > 0 else { return next }
        let point = anchor ?? CGPoint(x: destination.width / 2, y: destination.height / 2)
        let ratio = next.zoom / zoom
        let origin = CGPoint(x: point.x - (point.x - before.minX) * ratio,
                             y: point.y - (point.y - before.minY) * ratio)
        let overflowX = max(0, after.width - destination.width)
        let overflowY = max(0, after.height - destination.height)
        return Self(zoom: next.zoom, pan: CGPoint(x: overflowX > 0 ? 2 * (origin.x - after.minX) / overflowX : 0,
                                                y: overflowY > 0 ? 2 * (origin.y - after.minY) / overflowY : 0))
    }
}

/// Unit coordinates measured from the top-left of the source image.
public struct ImageCrop: Equatable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }

    public static let none = ImageCrop()

    public func rect(in size: CGSize) -> CGRect {
        let l = min(max(left.isFinite ? left : 0, 0), 0.95)
        let r = min(max(right.isFinite ? right : 0, 0), 0.95 - l)
        let t = min(max(top.isFinite ? top : 0, 0), 0.95)
        let b = min(max(bottom.isFinite ? bottom : 0, 0), 0.95 - t)
        // Core Image uses a bottom-left origin.
        return CGRect(x: size.width * l, y: size.height * b,
                      width: size.width * (1 - l - r), height: size.height * (1 - t - b))
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

    /// All dimensions are real pixels, never logical display points.
    public static func placement(source: CGSize, destination: CGSize, mode: ImageFit,
                                 viewport: ImageViewport = .identity) -> CGRect {
        guard source.width > 0, source.height > 0, destination.width > 0, destination.height > 0,
              source.width.isFinite, source.height.isFinite,
              destination.width.isFinite, destination.height.isFinite else { return .zero }
        let x = destination.width / source.width
        let y = destination.height / source.height
        let scale: CGFloat
        switch mode {
        case .fit: scale = min(x, y)
        case .fill: scale = max(x, y)
        case .actualPixels: scale = 1
        }
        let result = CGSize(width: source.width * scale * viewport.zoom, height: source.height * scale * viewport.zoom)
        return CGRect(x: (destination.width - result.width) / 2 + viewport.pan.x * max(0, result.width - destination.width) / 2,
                      y: (destination.height - result.height) / 2 + viewport.pan.y * max(0, result.height - destination.height) / 2,
                      width: result.width, height: result.height)
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
