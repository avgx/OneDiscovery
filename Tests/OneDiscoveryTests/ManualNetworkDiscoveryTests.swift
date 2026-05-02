import Foundation
import Testing
@testable import OneDiscovery

/// Optional live check: remove `.disabled`, set `URL` to a non-production base URL, run locally. Do not commit secrets.
@Test(.disabled("Local manual run: set URL and remove .disabled"))
func exploreLivePlaceholder() async throws {
    let raw = ProcessInfo.processInfo.environment["URL"] ?? ""
    guard let url = URL(string: raw), !raw.isEmpty else { return }
    let res = try await Web.explore(url: url)
    print(res)
}
