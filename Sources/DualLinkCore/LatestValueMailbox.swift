import Foundation

/// Bounded handoff between capture and UI queues. Invalidation also cancels queued delivery.
public final class LatestValueMailbox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let deliveryQueue: DispatchQueue
    private var latest: Value?
    private var scheduled = false
    private var valid = true

    public init(deliveryQueue: DispatchQueue = .main) { self.deliveryQueue = deliveryQueue }

    public func offer(_ value: Value, deliver: @escaping (Value) -> Void) {
        lock.lock()
        guard valid else { lock.unlock(); return }
        latest = value
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let value = self.valid ? self.latest : nil
            self.latest = nil
            self.scheduled = false
            self.lock.unlock()
            if let value { deliver(value) }
        }
    }

    public func invalidate() {
        lock.lock()
        valid = false
        latest = nil
        lock.unlock()
    }
}
