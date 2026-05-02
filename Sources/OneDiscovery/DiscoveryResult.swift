import Foundation

/// Successful discovery: final web root after redirects, product line, human-readable summary.
public struct DiscoveryResult: Equatable, Sendable, CustomStringConvertible {
    /// Effective URL of the web client root (after redirects), suitable as a base for further requests.
    public var baseURL: URL
    public var api: Api
    /// Human-readable line (product name, version, branch, etc.).
    public var summary: String

    public init(baseURL: URL, api: Api, summary: String) {
        self.baseURL = baseURL
        self.api = api
        self.summary = summary
    }

    public var description: String {
        let oneLine = summary.replacingOccurrences(of: "\n", with: " ")
        return "DiscoveryResult(api: \(api.rawValue), baseURL: \(baseURL.absoluteString), summary: \(oneLine))"
    }
}
