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
        let tile = CGPath(roundedRect: CGRect(x: 62, y: 62, width: 900, height: 900),
                          cornerWidth: 204, cornerHeight: 204, transform: nil)
        context.addPath(tile)
        context.saveGState()
        context.clip()
        context.setFillColor(CGColor(red: 0.53, green: 0.70, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 62, y: 62, width: 900, height: 900))
        context.restoreGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        MenuBarIcon.image.draw(in: NSRect(x: 170, y: 242, width: 704, height: 576))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { fatalError("Icon image") }
        let suffix = multiplier == 2 ? "@2x" : ""
        let url = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("Icon output") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Icon save") }
    }
}
