import Foundation

/// Successful discovery: final web root after redirects, product line, display name, and details.
public struct DiscoveryResult: Equatable, Sendable, CustomStringConvertible {
  /// Effective URL of the API root (after redirects), suitable as a base for further requests.
  public let baseURL: URL
  public let backend: Backend
  /// Product display name (manifest `name`, product line, page title, etc.).
  public let name: String
  /// Human-readable details (version, branch, build) without duplicating ``name``.
  public let summary: String

  public init(baseURL: URL, backend: Backend, name: String, summary: String) {
    self.baseURL = baseURL
    self.backend = backend
    self.name = name
    self.summary = summary
  }

  public var description: String {
    let oneLineSummary = summary.replacingOccurrences(of: "\n", with: " ")
    return "DiscoveryResult(backend: \(backend.rawValue), baseURL: \(baseURL.absoluteString), name: \(name), summary: \(oneLineSummary))"
  }
}
