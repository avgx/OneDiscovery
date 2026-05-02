import Foundation

public enum Api: String, Codable, Equatable, Sendable {
    /// Cloud (PWA) product / API surface.
    case cloud
    /// Current-generation Axxon Next web client.
    case next
    /// Legacy-generation Axxon Next web client (no manifest, older shell, etc.).
    case nextLegacy
    /// Intellect (Jetty `/web2` stack).
    case intl
}
