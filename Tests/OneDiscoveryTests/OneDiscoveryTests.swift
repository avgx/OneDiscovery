import Foundation
import Testing
@testable import OneDiscovery

// MARK: - Fixture loading

private enum Fixture {
    static func data(_ name: String, _ ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            throw FixtureError.missing(name, ext)
        }
        return try Data(contentsOf: url)
    }

    static func string(_ name: String, _ ext: String) throws -> String {
        let d = try data(name, ext)
        guard let s = String(data: d, encoding: .utf8) else { throw FixtureError.encoding }
        return s
    }

    enum FixtureError: Error {
        case missing(String, String)
        case encoding
    }
}

// MARK: - URL stub

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URL) -> (HTTPURLResponse, Data)?)?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".fixture") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let handler = Self.handler,
              let (response, data) = handler(url)
        else {
            let e = URLError(.badURL)
            client?.urlProtocol(self, didFailWithError: e)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    let defaults = cfg.protocolClasses ?? []
    cfg.protocolClasses = [StubURLProtocol.self] + defaults
    return URLSession(configuration: cfg)
}

private func http200(_ url: URL, data: Data) -> (HTTPURLResponse, Data) {
    let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/octet-stream"])!
    return (r, data)
}

// MARK: - Tests (stubbed suite is serialized — shared URLProtocol handler)

@Test func discoveryResult_customStringConvertible() {
    let u = URL(string: "https://example.test/")!
    let r = DiscoveryResult(baseURL: u, api: .cloud, summary: "ITV Cloud release/1.0 build 1")
    #expect(r.description.contains("cloud"))
    #expect(r.description.contains("https://example.test/"))
    #expect(r.description.contains("ITV Cloud"))
}

@Test func displayTitle_stripsWebAndClient() {
    #expect(displayTitle(fromRawTitle: "AxxonOne Web") == "AxxonOne")
    #expect(displayTitle(fromRawTitle: "Axxon Next client") == "Axxon Next")
    #expect(displayTitle(fromRawTitle: "Intellect X Web") == "Intellect X")
}

@Test func extractRawTitle_nextFixture() throws {
    let html = try Fixture.string("next-with-manifest", "html")
    #expect(extractRawTitle(from: html) == "Axxon Next client")
}

@Test func parseIntellectProductVersion_fixture() throws {
    let data = try Fixture.data("intellect-product-version", "txt")
    let want = parseIntellectProductVersion(data: data)
    #expect(want == "Intellect 4.11.3.5184")
}

@Suite(.serialized)
struct StubbedDiscoverTests {
    /// Jetty 404 at `/` + real `/web2/product/version` body (see FIXTURES_SOURCES.txt).
    @Test func discover_intellect_jetty404_resolvesWeb2Root() async throws {
        let html = try Fixture.string("intellect-root", "html")
        let base = URL(string: "http://intellect.fixture:8085/")!
        let versionData = try Fixture.data("intellect-product-version", "txt")
        let want = parseIntellectProductVersion(data: versionData)!
        StubURLProtocol.handler = { url in
            if url.path.hasSuffix("/web2/product/version") || url.path.hasSuffix("web2/product/version") {
                return http200(url, data: versionData)
            }
            return nil
        }
        let session = stubSession()
        let r = try await Web.discover(from: base, html: html, session: session)
        StubURLProtocol.handler = nil
        #expect(r?.api == .intl)
        #expect(r?.summary == want)
        #expect(r?.baseURL.path == "/web2" || r?.baseURL.path == "/web2/")
    }

    @Test func discover_intellect_throwsWhenVersionMissing() async throws {
        let html = try Fixture.string("intellect-root", "html")
        let base = URL(string: "http://intellect.fixture:8085/")!
        StubURLProtocol.handler = { _ in nil }
        let session = stubSession()
        await #expect(throws: DiscoveryError.self) {
            _ = try await Web.discover(from: base, html: html, session: session)
        }
        StubURLProtocol.handler = nil
    }

    @Test func discover_cloud_manifestAndAbout() async throws {
        let html = try Fixture.string("cloud-root", "html")
        let base = URL(string: "https://cloud.fixture/")!
        let manifest = try Fixture.data("cloud-manifest", "json")
        let about = try Fixture.data("cloud-about", "json")
        StubURLProtocol.handler = { url in
            if url.path.hasSuffix("/manifest.json") {
                return http200(url, data: manifest)
            }
            if url.path.hasSuffix("/about") {
                return http200(url, data: about)
            }
            return nil
        }
        let session = stubSession()
        let r = try await Web.discover(from: base, html: html, session: session)
        StubURLProtocol.handler = nil
        #expect(r?.api == .cloud)
        #expect(r?.baseURL == base)
        #expect(r?.summary.contains("ITV Cloud") == true)
        #expect(r?.summary.contains("release/3.26.0") == true)
        #expect(r?.summary.contains("build 9") == true)
    }

    @Test func discover_next_oldShell_noManifest_butLocaleStrings() async throws {
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"/><title>Old Next Shell</title></head><body></body></html>
        """
        let base = URL(string: "https://oldnext.fixture/")!
        let localeData = try Fixture.data("next-locale-strings-en", "xml")
        StubURLProtocol.handler = { url in
            if url.path.hasSuffix("/locale/strings-en.xml") {
                return http200(url, data: localeData)
            }
            return nil
        }
        let session = stubSession()
        let r = try await Web.discover(from: base, html: html, session: session)
        StubURLProtocol.handler = nil
        #expect(r?.api == .nextLegacy)
        #expect(r?.summary == "Old Next Shell")
    }

    @Test func discover_next_prefersManifestName() async throws {
        let html = try Fixture.string("next-with-manifest", "html")
        let base = URL(string: "https://next.fixture/")!
        let manifest = try Fixture.data("next-manifest", "json")
        StubURLProtocol.handler = { url in
            if url.path.hasSuffix("manifest.json") {
                return http200(url, data: manifest)
            }
            return nil
        }
        let session = stubSession()
        let r = try await Web.discover(from: base, html: html, session: session)
        StubURLProtocol.handler = nil
        #expect(r?.api == .next)
        #expect(r?.baseURL == base)
        #expect(r?.summary == "Axxon Next")
    }

    /// Locale suggests legacy shell, but `app.js` contains modern `authenticate_ex2` → **.next**.
    @Test func discover_next_whenLocalePlusAppBundleHasAuthenticateEx2() async throws {
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"/><title>Hybrid Shell client</title></head>\
        <body><script src="app.js"></script></body></html>
        """
        let base = URL(string: "https://hybrid.fixture/")!
        let localeData = try Fixture.data("next-locale-strings-en", "xml")
        let bundle = try Fixture.data("next-appjs-bundle", "js")
        StubURLProtocol.handler = { url in
            if url.path.hasSuffix("/locale/strings-en.xml") {
                return http200(url, data: localeData)
            }
            if url.path.hasSuffix("/app.js") {
                return http200(url, data: bundle)
            }
            return nil
        }
        let session = stubSession()
        let r = try await Web.discover(from: base, html: html, session: session)
        StubURLProtocol.handler = nil
        #expect(r?.api == .next)
        #expect(r?.baseURL == base)
        #expect(r?.summary == "Hybrid Shell")
    }

    @Test func explore_intellectThroughCandidates() async throws {
        let intellectHTML = try Fixture.string("intellect-root", "html")
        let versionData = try Fixture.data("intellect-product-version", "txt")
        let start = URL(string: "http://intellect.fixture:8085/")!
        StubURLProtocol.handler = { url in
            guard url.host == "intellect.fixture" else { return nil }
            if url.path.contains("web2/product/version") {
                return http200(url, data: versionData)
            }
            return http200(url, data: Data(intellectHTML.utf8))
        }
        let r = try await Web.explore(url: start, session: stubSession())
        StubURLProtocol.handler = nil
        #expect(r.api == .intl)
    }
}

@Test func discover_nextLegacy_ITV() async throws {
    let html = """
    <!DOCTYPE html><html><head><meta charset="utf-8"/><title>ITV | AxxonSoft client</title></head><body></body></html>
    """
    let base = URL(string: "https://legacy.fixture/")!
    let r = try await Web.discover(from: base, html: html, session: URLSession(configuration: .ephemeral))
    #expect(r?.api == .nextLegacy)
    #expect(r?.summary == "Legacy VMS version")
}
