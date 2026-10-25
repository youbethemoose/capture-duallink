import Foundation

/// A stable connection to another Wi-Fi network starts one away visit. Missing
/// network names (including disconnection or redaction) are never evidence of away.
public struct AwayFromHomePolicy {
    public enum Network: Equatable {
        case home, away, unknown
    }

    public let confirmationDelay: TimeInterval
    private var awaySince: TimeInterval?
    private var openedDuringVisit = false

    public var needsConfirmation: Bool { awaySince != nil && !openedDuringVisit }

    public init(confirmationDelay: TimeInterval = 10) {
        self.confirmationDelay = confirmationDelay
    }

    public mutating func observe(_ network: Network, at uptime: TimeInterval) -> Bool {
        switch network {
        case .home:
            awaySince = nil
            openedDuringVisit = false
        case .unknown:
            awaySince = nil
        case .away:
            guard !openedDuringVisit else { return false }
            guard let awaySince else { self.awaySince = uptime; return false }
            guard uptime - awaySince >= confirmationDelay else { return false }
            openedDuringVisit = true
            return true
        }
        return false
    }

    /// SSIDs are case-sensitive. If any connected interface is at home, stay home.
    /// An unreadable interface makes the result unknown unless home is already known.
    public static func classify(homeSSID: String, connectedSSIDs: [String?]) -> Network {
        guard !homeSSID.isEmpty else { return .unknown }
        if connectedSSIDs.contains(where: { $0 == homeSSID }) { return .home }
        guard !connectedSSIDs.isEmpty,
              connectedSSIDs.allSatisfy({ $0?.isEmpty == false }) else { return .unknown }
        return .away
    }
}
