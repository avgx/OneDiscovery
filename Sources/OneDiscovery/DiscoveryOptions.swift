import Foundation

/// Controls which product lines discovery may probe and classify.
public struct DiscoveryOptions: Sendable, Equatable {
  public var allowedBackends: Set<Backend>

  public init(allowedBackends: Set<Backend> = Set(Backend.allCases)) {
    self.allowedBackends = allowedBackends
  }

  public static let all = DiscoveryOptions()

  public func allows(_ backend: Backend) -> Bool {
    allowedBackends.contains(backend)
  }
}
