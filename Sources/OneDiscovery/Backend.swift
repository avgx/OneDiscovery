import Foundation

/// Backend type
public enum Backend: String, Codable, Equatable, Sendable {
    /// Cloud
    case cloud
    /// Current-generation Next
    case next
    /// Legacy-generation Next (basic auth only)
    case nextLegacy
    /// Intl4
    case intl
}
