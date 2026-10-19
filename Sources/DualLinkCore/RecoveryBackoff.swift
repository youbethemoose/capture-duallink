import Foundation

/// Monotonic, bounded retry delays; a stream failure never creates a tight restart loop.
public struct RecoveryBackoff {
    public private(set) var attempts = 0
    public private(set) var nextAttempt: TimeInterval = 0
    public init() {}
    public func isReady(at uptime: TimeInterval) -> Bool { uptime >= nextAttempt }
    public mutating func failed(at uptime: TimeInterval) {
        attempts = min(attempts + 1, 6)
        nextAttempt = uptime + min(15, pow(2, Double(attempts - 1)))
    }
    public mutating func reset() { attempts = 0; nextAttempt = 0 }
}
