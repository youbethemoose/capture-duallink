import XCTest
@testable import DualLinkCore

/// Synthetic Capture One-style frames: a flat background with a noisy camera picture.
private struct Frame {
    let width: Int, height: Int
    var pixels: [RGB]
    static let background = RGB(58, 58, 58)

    init(width: Int, height: Int, fill: RGB = Frame.background) {
        self.width = width; self.height = height
        pixels = Array(repeating: fill, count: width * height)
    }

    /// Camera-like content: a base color with deterministic ±spread noise per channel.
    mutating func paint(_ rect: CGRect, base: RGB, spread: Int, seed: UInt32 = 7) {
        var state = seed
        func noise() -> Int {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Int(state >> 24) % (2 * spread + 1) - spread
        }
        func channel(_ v: UInt8) -> UInt8 { UInt8(clamping: Int(v) + noise()) }
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                pixels[y * width + x] = spread == 0 ? base : RGB(channel(base.r), channel(base.g), channel(base.b))
            }
        }
    }

    func detect() -> CGRect? {
        ImageAreaDetector.detect(width: width, height: height) { pixels[$1 * width + $0] }
    }
}

final class DetectorTests: XCTestCase {
    private func assertRect(_ found: CGRect?, _ expected: CGRect, within slack: CGFloat = 4,
                            file: StaticString = #file, line: UInt = #line) {
        guard let found else { return XCTFail("No picture detected", file: file, line: line) }
        XCTAssertEqual(found.minX, expected.minX, accuracy: slack, file: file, line: line)
        XCTAssertEqual(found.minY, expected.minY, accuracy: slack, file: file, line: line)
        XCTAssertEqual(found.maxX, expected.maxX, accuracy: slack, file: file, line: line)
        XCTAssertEqual(found.maxY, expected.maxY, accuracy: slack, file: file, line: line)
    }

    func testPillarboxedFourByThreePictureInWideViewer() {
        var frame = Frame(width: 1280, height: 720)
        let picture = CGRect(x: 160, y: 0, width: 960, height: 720)
        frame.paint(picture, base: RGB(140, 110, 90), spread: 10)
        assertRect(frame.detect(), picture)
    }

    func testColorConversionDitherInTheBackgroundStillCountsAsFlat() {
        // Real ScreenCaptureKit frames dither Capture One's gray by ±1 per channel;
        // only about half of the bar pixels keep the exact value.
        var frame = Frame(width: 1280, height: 720)
        frame.paint(CGRect(x: 0, y: 0, width: 1280, height: 720), base: Frame.background, spread: 1)
        let picture = CGRect(x: 320, y: 0, width: 640, height: 720) // Narrow picture: mostly bar on the perimeter.
        frame.paint(picture, base: RGB(140, 110, 90), spread: 10)
        assertRect(frame.detect(), picture)
    }

    func testLetterboxedPictureInTallViewer() {
        var frame = Frame(width: 1000, height: 1200)
        let picture = CGRect(x: 0, y: 267, width: 1000, height: 666)
        frame.paint(picture, base: RGB(30, 90, 160), spread: 6)
        assertRect(frame.detect(), picture)
    }

    func testGraySeamlessBackdropCloseToBackgroundIsStillPicture() {
        var frame = Frame(width: 1280, height: 720)
        let picture = CGRect(x: 160, y: 0, width: 960, height: 720)
        frame.paint(picture, base: Frame.background, spread: 6) // Same gray, but with sensor noise.
        assertRect(frame.detect(), picture)
    }

    func testPictureThatFillsTheViewerHasNoBars() {
        var frame = Frame(width: 1200, height: 800)
        let picture = CGRect(x: 0, y: 0, width: 1200, height: 800)
        frame.paint(picture, base: RGB(200, 180, 150), spread: 8)
        assertRect(frame.detect(), picture, within: 0)
    }

    func testFlatAreaOnOneSideOfPictureIsNotMistakenForABar() {
        // No real bars; the top third of the picture happens to be exactly the background color.
        var frame = Frame(width: 1200, height: 800)
        frame.paint(CGRect(x: 0, y: 260, width: 1200, height: 540), base: RGB(90, 120, 60), spread: 8)
        assertRect(frame.detect(), CGRect(x: 0, y: 0, width: 1200, height: 800), within: 0)
    }

    func testLeftoverToolbarLinesFromAnImperfectTrimAreExcluded() {
        var frame = Frame(width: 1200, height: 900)
        frame.paint(CGRect(x: 0, y: 0, width: 1200, height: 6), base: RGB(220, 220, 220), spread: 30)
        let picture = CGRect(x: 0, y: 106, width: 1200, height: 694)
        frame.paint(picture, base: RGB(120, 100, 80), spread: 10)
        assertRect(frame.detect(), picture)
    }

    func testOverlayInsideABarNeverCutsIntoThePicture() {
        var frame = Frame(width: 1280, height: 720)
        let picture = CGRect(x: 160, y: 0, width: 960, height: 720)
        frame.paint(picture, base: RGB(140, 110, 90), spread: 10)
        frame.paint(CGRect(x: 40, y: 300, width: 100, height: 120), base: RGB(250, 250, 250), spread: 40)
        guard let found = frame.detect() else { return XCTFail("No picture detected") }
        XCTAssertTrue(found.contains(picture), "Detected \(found) must contain the whole picture \(picture)")
    }

    func testEmptyViewerHasNoPictureYet() {
        XCTAssertNil(Frame(width: 1280, height: 720).detect())
    }

    func testTinyRegionsAreIgnored() {
        XCTAssertNil(Frame(width: 8, height: 8).detect())
    }

    func testTrackerNeedsTwoAgreeingDetectionsToMoveTheGrid() {
        var tracker = ImageAreaTracker()
        let size = CGSize(width: 1280, height: 720)
        let a = CGRect(x: 160, y: 0, width: 960, height: 720)
        let b = CGRect(x: 0, y: 0, width: 1280, height: 720)
        XCTAssertTrue(tracker.update(regionSize: size, detected: a, tolerance: 4))
        XCTAssertFalse(tracker.update(regionSize: size, detected: b, tolerance: 4), "One stray result is ignored")
        XCTAssertEqual(tracker.area, a)
        XCTAssertFalse(tracker.update(regionSize: size, detected: nil, tolerance: 4), "No picture keeps the last area")
        XCTAssertFalse(tracker.update(regionSize: size, detected: b, tolerance: 4))
        XCTAssertTrue(tracker.update(regionSize: size, detected: b, tolerance: 4))
        XCTAssertEqual(tracker.area, b)
    }

    func testTrackerAcceptsNewAreaImmediatelyAfterResize() {
        var tracker = ImageAreaTracker()
        _ = tracker.update(regionSize: CGSize(width: 1280, height: 720),
                           detected: CGRect(x: 160, y: 0, width: 960, height: 720), tolerance: 4)
        let resized = CGRect(x: 0, y: 40, width: 900, height: 600)
        XCTAssertTrue(tracker.update(regionSize: CGSize(width: 900, height: 680), detected: resized, tolerance: 4))
        XCTAssertEqual(tracker.area, resized)
    }
}
