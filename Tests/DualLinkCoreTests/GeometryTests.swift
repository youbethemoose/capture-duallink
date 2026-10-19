import XCTest
@testable import DualLinkCore

final class GeometryTests: XCTestCase {
    func testCaptureMetadataPointsConvertToRetinaPixelsBeforeCropping() {
        let rect = ImageGeometry.captureContentRect(points: CGRect(x: 0, y: 0, width: 320, height: 240),
                                                   pixelScale: 2, bufferSize: CGSize(width: 640, height: 480))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 640, height: 480))
    }
    func testResizedSourcePaddingIsRemovedFromBottomOfBuffer() {
        let rect = ImageGeometry.captureContentRect(points: CGRect(x: 0, y: 0, width: 320, height: 180),
                                                   pixelScale: 2, bufferSize: CGSize(width: 640, height: 480))
        XCTAssertEqual(rect, CGRect(x: 0, y: 120, width: 640, height: 360))
    }
    func testFitMacCameraImageOnFourByThreeIPadPreservesAspect() {
        let rect = ImageGeometry.placement(source: CGSize(width: 1920, height: 1080),
                                           destination: CGSize(width: 2048, height: 1536), mode: .fit)
        XCTAssertEqual(rect.width, 2048, accuracy: 0.001)
        XCTAssertEqual(rect.height, 1152, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 192, accuracy: 0.001)
    }
    func testFillCropsEquallyInsteadOfStretching() {
        let rect = ImageGeometry.placement(source: CGSize(width: 1920, height: 1080),
                                           destination: CGSize(width: 2048, height: 1536), mode: .fill)
        XCTAssertEqual(rect.height, 1536, accuracy: 0.001)
        XCTAssertLessThan(rect.minX, 0)
        XCTAssertEqual(rect.midX, 1024, accuracy: 0.001)
        XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.001)
    }
    func testOneToOneUsesRealPixelsOnEitherDisplay() {
        let source = CGSize(width: 1200, height: 800)
        for destination in [CGSize(width: 1512, height: 982), CGSize(width: 3024, height: 1964)] {
            let rect = ImageGeometry.placement(source: source, destination: destination, mode: .actualPixels)
            XCTAssertEqual(rect.size, source)
            XCTAssertEqual(rect.midX, destination.width / 2)
        }
    }
    func testTopCropUsesCoreImageBottomLeftOrigin() {
        let rect = ImageCrop(left: 0.1, top: 0.2, right: 0.05, bottom: 0.1)
            .rect(in: CGSize(width: 1000, height: 500))
        XCTAssertEqual(rect.minX, 100, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 50, accuracy: 0.001)
        XCTAssertEqual(rect.width, 850, accuracy: 0.001)
        XCTAssertEqual(rect.height, 350, accuracy: 0.001)
    }
    func testInvalidCropCannotMakeEmptyImage() {
        let rect = ImageCrop(left: 1, top: .nan, right: 1, bottom: 1)
            .rect(in: CGSize(width: 1000, height: 500))
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        XCTAssertTrue(rect.minY.isFinite)
    }
    func testCaptureRetinaScaleAndQualityCapPreservePortraitShape() {
        let points = CGSize(width: 600, height: 1000)
        XCTAssertEqual(ImageGeometry.captureSize(points: points, pixelScale: 2, maximumEdge: nil),
                       CGSize(width: 1200, height: 2000))
        XCTAssertEqual(ImageGeometry.captureSize(points: points, pixelScale: 2, maximumEdge: 1920),
                       CGSize(width: 1152, height: 1920))
        XCTAssertEqual(ImageGeometry.captureSize(points: points, pixelScale: 1, maximumEdge: 1920), points)
    }
    func testZeroAndNonfiniteDestinationsDoNotRenderInvalidTransforms() {
        XCTAssertEqual(ImageGeometry.placement(source: .zero, destination: CGSize(width: 100, height: 100), mode: .fit), .zero)
        XCTAssertEqual(ImageGeometry.placement(source: CGSize(width: 100, height: 100),
                                               destination: CGSize(width: CGFloat.infinity, height: 100), mode: .fill), .zero)
    }

    func testZoomAndPanCannotExposeEmptyEdgesOnAnOverflowingAxis() {
        let source = CGSize(width: 1920, height: 1080), destination = CGSize(width: 2048, height: 1536)
        let viewport = ImageViewport(zoom: 2).panned(by: CGPoint(x: 100_000, y: -100_000),
                                                    source: source, destination: destination, mode: .fit)
        let rect = ImageGeometry.placement(source: source, destination: destination, mode: .fit, viewport: viewport)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, destination.height, accuracy: 0.001)
        XCTAssertEqual(viewport.pan, CGPoint(x: 1, y: -1))
    }

    func testPanDoesNotMoveALetterboxedAxis() {
        let source = CGSize(width: 1920, height: 1080), destination = CGSize(width: 2048, height: 1536)
        let viewport = ImageViewport.identity.panned(by: CGPoint(x: 400, y: 200), source: source,
                                                     destination: destination, mode: .fit)
        XCTAssertEqual(viewport, .identity)
        let rect = ImageGeometry.placement(source: source, destination: destination, mode: .fit, viewport: viewport)
        XCTAssertEqual(rect.midY, destination.height / 2)
    }

    func testPinchKeepsImageUnderFocalPointAcrossRetinaScales() {
        for scale: CGFloat in [1, 2] {
            let source = CGSize(width: 1000 * scale, height: 1000 * scale)
            let destination = CGSize(width: 800 * scale, height: 800 * scale)
            let anchor = CGPoint(x: 250 * scale, y: 300 * scale)
            let before = ImageGeometry.placement(source: source, destination: destination, mode: .fit)
            let viewport = ImageViewport.identity.zoomed(by: 2, source: source, destination: destination,
                                                         mode: .fit, anchor: anchor)
            let after = ImageGeometry.placement(source: source, destination: destination, mode: .fit, viewport: viewport)
            XCTAssertEqual((anchor.x - before.minX) / before.width, (anchor.x - after.minX) / after.width, accuracy: 0.001)
            XCTAssertEqual((anchor.y - before.minY) / before.height, (anchor.y - after.minY) / after.height, accuracy: 0.001)
        }
    }

    func testZoomLimitsAndReturningToFitClearsPan() {
        let size = CGSize(width: 1000, height: 1000)
        XCTAssertEqual(ImageViewport(zoom: .infinity, pan: CGPoint(x: CGFloat.nan, y: CGFloat.infinity)), .identity)
        XCTAssertEqual(ImageViewport(zoom: 999).zoom, 8)
        XCTAssertEqual(ImageViewport(zoom: 0).zoom, 1)
        let zoomed = ImageViewport(zoom: 2, pan: CGPoint(x: 1, y: -1))
        XCTAssertEqual(zoomed.zoomed(by: 0.1, source: size, destination: size, mode: .fit), .identity)
        XCTAssertEqual(zoomed.zoomed(by: .nan, source: size, destination: size, mode: .fit), zoomed)
    }
}
