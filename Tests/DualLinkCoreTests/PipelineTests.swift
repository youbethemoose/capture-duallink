import XCTest
@testable import DualLinkCore

final class PipelineTests: XCTestCase {
    func testMailboxDropsBacklogAndDeliversOnlyNewestFrame() {
        let queue = DispatchQueue(label: "mailbox-test")
        queue.suspend()
        let mailbox = LatestValueMailbox<Int>(deliveryQueue: queue)
        var delivered: [Int] = []
        for value in 0..<10_000 { mailbox.offer(value) { delivered.append($0) } }
        queue.resume()
        queue.sync {}
        XCTAssertEqual(delivered, [9999])
    }

    func testMailboxInvalidationReleasesPendingValueAndPreventsLateDelivery() {
        final class Frame {}
        let queue = DispatchQueue(label: "cancel-mailbox-test")
        queue.suspend()
        let mailbox = LatestValueMailbox<Frame>(deliveryQueue: queue)
        var frame: Frame? = Frame()
        weak var retained = frame
        var deliveries = 0
        mailbox.offer(frame!) { _ in deliveries += 1 }
        frame = nil
        XCTAssertNotNil(retained)
        mailbox.invalidate()
        XCTAssertNil(retained)
        mailbox.offer(Frame()) { _ in deliveries += 1 }
        queue.resume()
        queue.sync {}
        XCTAssertEqual(deliveries, 0)
    }

    func testConcurrentCaptureOffersKeepOnePendingDelivery() {
        let queue = DispatchQueue(label: "concurrent-mailbox-test")
        queue.suspend()
        let mailbox = LatestValueMailbox<Int>(deliveryQueue: queue)
        var delivered: [Int] = []
        DispatchQueue.concurrentPerform(iterations: 1000) { value in mailbox.offer(value) { delivered.append($0) } }
        mailbox.offer(42) { delivered.append($0) }
        queue.resume()
        queue.sync {}
        XCTAssertEqual(delivered, [42])
    }

    func testRecoveryBackoffCapsAndSuccessfulRecoveryClearsDelay() {
        var backoff = RecoveryBackoff()
        var now: TimeInterval = 100
        for expectedDelay: TimeInterval in [1, 2, 4, 8, 15, 15, 15] {
            XCTAssertTrue(backoff.isReady(at: now))
            backoff.failed(at: now)
            XCTAssertEqual(backoff.nextAttempt - now, expectedDelay)
            XCTAssertFalse(backoff.isReady(at: now + expectedDelay - 0.01))
            now += expectedDelay
        }
        backoff.reset()
        XCTAssertEqual(backoff.attempts, 0)
        XCTAssertTrue(backoff.isReady(at: now))
    }
}
