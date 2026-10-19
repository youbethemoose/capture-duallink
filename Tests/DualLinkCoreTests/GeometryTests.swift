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
    func testFlipRoundTripsBetweenTopLeftAndCoreImageOrigins() {
        let topLeft = CGRect(x: 10, y: 20, width: 100, height: 50)
        let ci = ImageGeometry.flipped(topLeft, height: 480)
        XCTAssertEqual(ci, CGRect(x: 10, y: 410, width: 100, height: 50))
        XCTAssertEqual(ImageGeometry.flipped(ci, height: 480), topLeft)
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
    func testPictureAreaMapsThroughFitPlacement() {
        // A 4:3 picture pillarboxed in a 16:9 source, shown on a 4:3 iPad.
        let source = CGSize(width: 1280, height: 720), destination = CGSize(width: 2048, height: 1536)
        let placement = ImageGeometry.placement(source: source, destination: destination, mode: .fit)
        let picture = ImageGeometry.map(CGRect(x: 160, y: 0, width: 960, height: 720), source: source, into: placement)
        XCTAssertEqual(picture.minX, 256, accuracy: 0.001)
        XCTAssertEqual(picture.width, 1536, accuracy: 0.001)
        XCTAssertEqual(picture.height, 1152, accuracy: 0.001)
        XCTAssertEqual(picture.minY, placement.minY, accuracy: 0.001)
    }
    func testTrimUsesPointsSoToolbarStaysTrimmedOnRetina() {
        let trim = SourceTrim(top: 44, left: 0, bottom: 20, right: 0)
        XCTAssertEqual(trim.apply(to: CGRect(x: 0, y: 0, width: 1600, height: 1000), pixelScale: 2),
                       CGRect(x: 0, y: 88, width: 1600, height: 872))
        XCTAssertEqual(trim.apply(to: CGRect(x: 0, y: 0, width: 800, height: 500), pixelScale: 1),
                       CGRect(x: 0, y: 44, width: 800, height: 436))
    }
    func testTrimIsRelativeToContentOrigin() {
        let trim = SourceTrim(top: 10, left: 5)
        XCTAssertEqual(trim.apply(to: CGRect(x: 0, y: 120, width: 640, height: 360), pixelScale: 2),
                       CGRect(x: 10, y: 140, width: 630, height: 340))
    }
    func testOversizedOrInvalidTrimCannotMakeEmptyImage() {
        let rect = SourceTrim(top: 900, left: .nan, bottom: 900, right: -50)
            .apply(to: CGRect(x: 0, y: 0, width: 1000, height: 500), pixelScale: 2)
        XCTAssertGreaterThanOrEqual(rect.height, 16)
        XCTAssertEqual(rect.width, 1000)
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
}
