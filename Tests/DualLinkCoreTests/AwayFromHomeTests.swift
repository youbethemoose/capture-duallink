import XCTest
@testable import DualLinkCore

final class AwayFromHomeTests: XCTestCase {
    func testStaysQuietAtHome() {
        var policy = AwayFromHomePolicy()
        XCTAssertFalse(policy.observe(.home, at: 0))
        XCTAssertFalse(policy.observe(.home, at: 500))
    }

    func testAwayConnectionMustRemainStableForTenSeconds() {
        var policy = AwayFromHomePolicy()
        XCTAssertFalse(policy.observe(.away, at: 100))
        XCTAssertFalse(policy.observe(.away, at: 109.9))
        XCTAssertTrue(policy.observe(.away, at: 110))
    }

    func testDisconnectionNeverOpensAndInterruptsConfirmation() {
        var policy = AwayFromHomePolicy()
        XCTAssertFalse(policy.observe(.unknown, at: 0))
        XCTAssertFalse(policy.observe(.unknown, at: 500))
        XCTAssertFalse(policy.observe(.away, at: 501))
        XCTAssertFalse(policy.observe(.unknown, at: 509))
        XCTAssertFalse(policy.observe(.away, at: 510))
        XCTAssertFalse(policy.observe(.away, at: 519))
        XCTAssertTrue(policy.observe(.away, at: 520))
    }

    func testReturningHomeCancelsPendingOpen() {
        var policy = AwayFromHomePolicy()
        XCTAssertFalse(policy.observe(.away, at: 0))
        XCTAssertFalse(policy.observe(.home, at: 9))
        XCTAssertFalse(policy.observe(.home, at: 30))
    }

    func testOpensOnlyOncePerAwayVisitEvenAfterDropout() {
        var policy = AwayFromHomePolicy()
        XCTAssertFalse(policy.observe(.away, at: 0))
        XCTAssertTrue(policy.observe(.away, at: 10))
        XCTAssertFalse(policy.observe(.away, at: 100))
        XCTAssertFalse(policy.observe(.unknown, at: 200))
        XCTAssertFalse(policy.observe(.away, at: 300))
        XCTAssertFalse(policy.observe(.away, at: 400))
    }

    func testNewVisitCanOpenAfterReturningHome() {
        var policy = AwayFromHomePolicy()
        XCTAssertFalse(policy.observe(.away, at: 0))
        XCTAssertTrue(policy.observe(.away, at: 10))
        XCTAssertFalse(policy.observe(.home, at: 50))
        XCTAssertFalse(policy.observe(.away, at: 60))
        XCTAssertTrue(policy.observe(.away, at: 70))
    }

    func testUnknownOrEmptySSIDNeverMeansAway() {
        XCTAssertEqual(AwayFromHomePolicy.classify(homeSSID: "Home", connectedSSIDs: []), .unknown)
        XCTAssertEqual(AwayFromHomePolicy.classify(homeSSID: "Home", connectedSSIDs: [nil]), .unknown)
        XCTAssertEqual(AwayFromHomePolicy.classify(homeSSID: "Home", connectedSSIDs: [""]), .unknown)
        XCTAssertEqual(AwayFromHomePolicy.classify(homeSSID: "", connectedSSIDs: ["Studio"]), .unknown)
    }

    func testSSIDComparisonIsExactAndCaseSensitive() {
        XCTAssertEqual(AwayFromHomePolicy.classify(homeSSID: "Home", connectedSSIDs: ["Home"]), .home)
        XCTAssertEqual(AwayFromHomePolicy.classify(homeSSID: "Home", connectedSSIDs: ["home"]), .away)
        XCTAssertEqual(AwayFromHomePolicy.classify(homeSSID: " Home ", connectedSSIDs: [" Home "]), .home)
    }

    func testHomeWinsAcrossInterfacesAndUnknownFailsClosed() {
        XCTAssertEqual(AwayFromHomePolicy.classify(homeSSID: "Home", connectedSSIDs: ["Studio", "Home"]), .home)
        XCTAssertEqual(AwayFromHomePolicy.classify(homeSSID: "Home", connectedSSIDs: [nil, "Home"]), .home)
        XCTAssertEqual(AwayFromHomePolicy.classify(homeSSID: "Home", connectedSSIDs: [nil, "Studio"]), .unknown)
        XCTAssertEqual(AwayFromHomePolicy.classify(homeSSID: "Home", connectedSSIDs: ["Studio"]), .away)
    }
}
