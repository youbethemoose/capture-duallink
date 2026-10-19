import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let space = CGColorSpaceCreateDeviceRGB()

for size in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let pixels = size * multiplier
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: pixels * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Icon context") }
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.setFillColor(CGColor(red: 0.63, green: 0.94, blue: 0.81, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 62, y: 62, width: 900, height: 900),
                               cornerWidth: 204, cornerHeight: 204, transform: nil))
        context.fillPath()
        let ink = CGColor(red: 0.055, green: 0.14, blue: 0.12, alpha: 1)
        context.setStrokeColor(ink)
        context.setLineWidth(38)
        context.addPath(CGPath(roundedRect: CGRect(x: 207, y: 427, width: 460, height: 335),
                               cornerWidth: 38, cornerHeight: 38, transform: nil))
        context.strokePath()
        context.setFillColor(CGColor(red: 0.63, green: 0.94, blue: 0.81, alpha: 1))
        let front = CGPath(roundedRect: CGRect(x: 357, y: 267, width: 460, height: 335),
                           cornerWidth: 38, cornerHeight: 38, transform: nil)
        context.addPath(front); context.fillPath()
        context.addPath(front); context.strokePath()
        context.setFillColor(ink)
        context.fillEllipse(in: CGRect(x: 567, y: 305, width: 38, height: 38))
        guard let image = context.makeImage() else { fatalError("Icon image") }
        let suffix = multiplier == 2 ? "@2x" : ""
        let url = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("Icon output") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Icon save") }
    }
}
