import Foundation

/// Successful discovery: final web root after redirects, product line, human-readable summary.
public struct DiscoveryResult: Equatable, Sendable, CustomStringConvertible {
    /// Effective URL of the API root (after redirects), suitable as a base for further requests.
    public let baseURL: URL
    public let backend: Backend
    /// Human-readable line (product name, version, branch, etc.).
    public let summary: String

    public init(baseURL: URL, backend: Backend, summary: String) {
        self.baseURL = baseURL
        self.backend = backend
        self.summary = summary
    }

    public var description: String {
        let oneLine = summary.replacingOccurrences(of: "\n", with: " ")
        return "DiscoveryResult(backend: \(backend.rawValue), baseURL: \(baseURL.absoluteString), summary: \(oneLine))"
    }
}
