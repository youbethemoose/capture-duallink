import XCTest
@testable import DualLinkCore

final class MouseMappingTests: XCTestCase {
    private let crop = CGRect(x: 20, y: 40, width: 800, height: 400)

    func testFitMapsIntoTrimmedSourcePointsWithYFlipped() {
        XCTAssertEqual(ImageGeometry.sourcePoint(CGPoint(x: 250, y: 375), viewerSize: CGSize(width: 1000, height: 1000),
                                                imageSize: CGSize(width: 1600, height: 800), sourceRect: crop, mode: .fit),
                       CGPoint(x: 220, y: 340))
    }

    func testLetterboxClicksAreIgnored() {
        XCTAssertNil(ImageGeometry.sourcePoint(CGPoint(x: 500, y: 100), viewerSize: CGSize(width: 1000, height: 1000),
                                               imageSize: CGSize(width: 1600, height: 800), sourceRect: crop, mode: .fit))
    }

    func testFillIncludesTheCroppedPartOfTheOriginalImage() {
        XCTAssertEqual(ImageGeometry.sourcePoint(CGPoint(x: 0, y: 500), viewerSize: CGSize(width: 1000, height: 1000),
                                                imageSize: CGSize(width: 1600, height: 800), sourceRect: crop, mode: .fill),
                       CGPoint(x: 220, y: 240))
    }

    func testRetinaAndQualitySettingsDoNotChangeWhereAClickLands() {
        for pixels: CGFloat in [1, 2, 0.5] {
            XCTAssertEqual(ImageGeometry.sourcePoint(CGPoint(x: 400, y: 200), viewerSize: CGSize(width: 800, height: 400),
                                                    imageSize: CGSize(width: 800 * pixels, height: 400 * pixels),
                                                    sourceRect: crop, mode: .fit), CGPoint(x: 420, y: 240))
        }
    }

    func testDragReleaseOutsideImageClampsToItsEdge() {
        XCTAssertEqual(ImageGeometry.sourcePoint(CGPoint(x: -100, y: 2000), viewerSize: CGSize(width: 1000, height: 1000),
                                                imageSize: CGSize(width: 1600, height: 800), sourceRect: crop,
                                                mode: .fit, clamp: true), CGPoint(x: 20, y: 40))
    }

    func testInvalidGeometryNeverProducesAnInputPoint() {
        XCTAssertNil(ImageGeometry.sourcePoint(.zero, viewerSize: .zero, imageSize: CGSize(width: 1600, height: 800),
                                               sourceRect: crop, mode: .fit))
        XCTAssertNil(ImageGeometry.sourcePoint(CGPoint(x: CGFloat.nan, y: 0), viewerSize: CGSize(width: 800, height: 400),
                                               imageSize: CGSize(width: 1600, height: 800), sourceRect: crop, mode: .fit))
    }
}
