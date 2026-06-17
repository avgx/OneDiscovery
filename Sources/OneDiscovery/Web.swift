import Foundation
import DebugThings

private enum DiscoveryLog: Loggable {}

public enum Web {
    /// Discover product at or near `url`. Returns the first match from ``exploreDiscoveries(url:session:)``.
    public static func explore(url: URL, session: URLSession? = nil) async throws -> DiscoveryResult {
        let discoveries = try await exploreDiscoveries(url: url, session: session)
        guard let first = discoveries.first else { throw DiscoveryError.notRecognized }
        return first
    }

    /// Probes only the given `url` — no alternate ports, paths, or scheme heuristics.
    /// Use for preset URLs that must be checked exactly as configured.
    public static func exploreExact(url: URL, session: URLSession? = nil) async throws -> DiscoveryResult {
        DiscoveryLog.logger.info("exploreExact started url=\(url.absoluteString)")
        if Task.isCancelled {
            DiscoveryLog.logger.info("exploreExact cancelled url=\(url.absoluteString)")
            throw CancellationError()
        }

        let sess = session ?? URLSession(configuration: .fast)
        let (result, _) = try await probeCandidate(sess, url)
        guard let result else {
            DiscoveryLog.logger.info("exploreExact not recognized url=\(url.absoluteString)")
            throw DiscoveryError.notRecognized
        }
        DiscoveryLog.logger.info("exploreExact finished url=\(url.absoluteString) backend=\(result.backend.rawValue)")
        return result
    }

    /// Discover all distinct products at or near `url` (up to two on one host).
    /// Stops early when **cloud** is found (cloud does not coexist with other products).
    public static func exploreDiscoveries(url: URL, session: URLSession? = nil) async throws -> [DiscoveryResult] {
        DiscoveryLog.logger.info("explore started url=\(url.absoluteString)")
        if Task.isCancelled {
            DiscoveryLog.logger.info("explore cancelled url=\(url.absoluteString)")
            throw CancellationError()
        }

        let sess = session ?? URLSession(configuration: .fast)
        let collector = DiscoveryCollector()

        do {
            let (phaseA, finalAfterA) = try await probeCandidate(sess, url)
            if let phaseA, await collector.absorb(phaseA) {
                let results = await collector.snapshot()
                DiscoveryLog.logger.info("explore finished url=\(url.absoluteString) count=\(results.count) backends=\(Self.backendNames(results))")
                return results
            }

            let expansionBase = finalAfterA != url ? finalAfterA : url
            let candidates = heuristicExpansions(from: expansionBase)
            guard !candidates.isEmpty else {
                let collected = await collector.snapshot()
                if collected.isEmpty {
                    DiscoveryLog.logger.info("explore not recognized url=\(url.absoluteString)")
                    throw DiscoveryError.notRecognized
                }
                DiscoveryLog.logger.info("explore finished url=\(url.absoluteString) count=\(collected.count) backends=\(Self.backendNames(collected))")
                return collected
            }

            try await withThrowingTaskGroup(of: Bool.self) { group in
                for candidate in candidates {
                    group.addTask {
                        if await collector.shouldStop { return false }
                        let (result, _) = try await probeCandidate(sess, candidate)
                        guard let result else { return false }
                        return await collector.absorb(result)
                    }
                }
                for try await shouldStop in group {
                    if shouldStop {
                        group.cancelAll()
                        break
                    }
                }
            }

            if Task.isCancelled {
                DiscoveryLog.logger.info("explore cancelled url=\(url.absoluteString)")
                throw CancellationError()
            }

            let collected = await collector.snapshot()
            if collected.isEmpty {
                DiscoveryLog.logger.info("explore not recognized url=\(url.absoluteString)")
                throw DiscoveryError.notRecognized
            }
            DiscoveryLog.logger.info("explore finished url=\(url.absoluteString) count=\(collected.count) backends=\(Self.backendNames(collected))")
            return collected
        } catch {
            if error is CancellationError || Task.isCancelled {
                DiscoveryLog.logger.info("explore cancelled url=\(url.absoluteString)")
            }
            throw error
        }
    }

    /// Classify from a page already fetched at `baseURL` (tests and tooling).
    public static func discover(from baseURL: URL, html: String, session: URLSession? = nil) async throws -> DiscoveryResult? {
        let sess = session ?? URLSession(configuration: .fast)
        return try await discoverImpl(from: baseURL, html: html, session: sess)
    }
}

// MARK: - Discovery collection

private actor DiscoveryCollector {
    private var results: [DiscoveryResult] = []
    private var backends = Set<Backend>()
    private var stopRequested = false

    var shouldStop: Bool { stopRequested }

    func absorb(_ result: DiscoveryResult) -> Bool {
        if stopRequested { return true }

        if result.backend == .cloud {
            results = [result]
            backends = [.cloud]
            stopRequested = true
            return true
        }

        if backends.insert(result.backend).inserted {
            results.append(result)
        }

        if backends.count >= 2 {
            stopRequested = true
            return true
        }
        return false
    }

    func snapshot() -> [DiscoveryResult] {
        results
    }
}

// MARK: - Internals

private extension Web {
    static func backendNames(_ results: [DiscoveryResult]) -> String {
        results.map(\.backend.rawValue).joined(separator: ",")
    }

    /// Fetches one URL and runs classification. Returns `(result, finalURLAfterRedirects)`.
    static func probeCandidate(
        _ session: URLSession,
        _ candidate: URL
    ) async throws -> (DiscoveryResult?, URL) {
        guard let (data, http) = await httpGET(session, candidate),
              let html = String(data: data, encoding: .utf8)
        else { return (nil, candidate) }

        let finalURL = http.url ?? candidate
        let rawTitle = extractRawTitle(from: html)
        let intlStrong = isStrongIntlSignal(html: html, rawTitle: rawTitle)
        do {
            if let result = try await discoverImpl(from: finalURL, html: html, session: session) {
                return (result, finalURL)
            }
        } catch DiscoveryError.notRecognized {
            if intlStrong { throw DiscoveryError.notRecognized }
        }
        return (nil, finalURL)
    }

    /// GET via `URLSession` (redirects are followed by the system). Treats Jetty **404** HTML mentioning `web2` as a usable body for Intellect probing.
    static func httpGET(_ session: URLSession, _ url: URL) async -> (Data, HTTPURLResponse)? {
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse else { return nil }
            if (200...299).contains(http.statusCode) { return (data, http) }
            if http.statusCode == 404, let s = String(data: data, encoding: .utf8),
               s.contains("eclipse.org/jetty"), s.localizedCaseInsensitiveContains("web2") {
                return (data, http)
            }
            return nil
        } catch {
            return nil
        }
    }

    static func isStrongIntlSignal(html: String, rawTitle: String) -> Bool {
        rawTitle.contains("WebServer 2.0")
            || rawTitle.contains("Directory: /web2/")
            || (rawTitle.contains("Error 404") && html.contains(">/web2</a>") && html.contains("eclipse.org/jetty"))
    }

    static func intellectWeb2Root(from finalURL: URL, html: String, rawTitle: String) -> URL {
        let path = finalURL.path
        if path == "/web2" || path.hasPrefix("/web2/") {
            return finalURL
        }
        if path == "/" || path.isEmpty, isStrongIntlSignal(html: html, rawTitle: rawTitle) {
            return finalURL.appendingPathComponent("web2", isDirectory: true)
        }
        return finalURL
    }

    /// Classic Next web shell without PWA: `locale/strings-en.xml` is present → **nextLegacy** (no manifest).
    static func hasNextLocaleStrings(session: URLSession, base: URL) async -> Bool {
        let u = base.appendingPathComponent("locale", isDirectory: true).appendingPathComponent("strings-en.xml", isDirectory: false)
        guard let (data, http) = await httpGET(session, u),
              (200...299).contains(http.statusCode),
              let s = String(data: data, encoding: .utf8)
        else { return false }
        return s.contains("<resources") && s.contains("<string")
    }

    static func titleLooksLikeCloudTitle(_ rawTitle: String) -> Bool {
        let lower = rawTitle.lowercased()
        return lower.contains("cloud") && !lower.contains("next")
    }

    static func htmlLooksLikeNextShell(_ html: String) -> Bool {
        html.contains("window.login = ''") && html.contains("window.pass = ''")
    }

    static func titleLooksLikeNextWebClient(_ rawTitle: String) -> Bool {
        if rawTitle.hasSuffix(" Web"), !rawTitle.contains("WebServer") { return true }
        if rawTitle.hasSuffix(" client"), rawTitle != "ITV | AxxonSoft client" { return true }
        return false
    }

    /// Main SPA script names: `app.js` or webpack-style `app.<hex>.js` (used only to tell **.next** from **.nextLegacy** when locale XML is present).
    static func isMainAppScriptName(_ src: String) -> Bool {
        let name = (src as NSString).lastPathComponent
        if name.compare("app.js", options: .caseInsensitive) == .orderedSame { return true }
        guard let re = try? NSRegularExpression(pattern: #"^app\.[0-9a-f]+\.js$"#, options: .caseInsensitive) else { return false }
        return re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    static func scriptSrcs(from html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<script[^>]+src\s*=\s*["']([^"']+)["']"#,
            options: [.caseInsensitive]
        ) else { return [] }
        var out: [String] = []
        regex.enumerateMatches(in: html, options: [], range: NSRange(html.startIndex..., in: html)) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: html) else { return }
            out.append(String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    /// Resolved `<script src>` URLs in document order. Optionally appends `app.js` relative to `baseURL` if not already listed.
    static func mainAppScriptCandidateURLs(from html: String, baseURL: URL, appendAppJsFallback: Bool) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        for src in scriptSrcs(from: html) where isMainAppScriptName(src) {
            guard let u = URL(string: src, relativeTo: baseURL)?.absoluteURL else { continue }
            if seen.insert(u.absoluteString).inserted { urls.append(u) }
        }
        if appendAppJsFallback, let fallback = URL(string: "app.js", relativeTo: baseURL)?.absoluteURL, seen.insert(fallback.absoluteString).inserted {
            urls.append(fallback)
        }
        return urls
    }

    /// Loads listed main app bundles and returns whether the body contains the modern Next auth API path (not used for Cloud or Intellect).
    static func appBundleContainsAuthenticateEx2(session: URLSession, html: String, baseURL: URL, appendAppJsFallback: Bool) async -> Bool {
        let fragment = "v1/authenticate/authenticate_ex2"
        for u in mainAppScriptCandidateURLs(from: html, baseURL: baseURL, appendAppJsFallback: appendAppJsFallback) {
            guard let (data, _) = await httpGET(session, u),
                  let s = String(data: data, encoding: .utf8),
                  s.contains(fragment)
            else { continue }
            return true
        }
        return false
    }

    static func discoverImpl(from finalURL: URL, html: String, session: URLSession) async throws -> DiscoveryResult? {
        let rawTitle = extractRawTitle(from: html)
        let hasManifestLink = extractManifestHref(from: html) != nil

        if isStrongIntlSignal(html: html, rawTitle: rawTitle) {
            let web2 = intellectWeb2Root(from: finalURL, html: html, rawTitle: rawTitle)
            let verURL = web2.appendingPathComponent("product", isDirectory: false).appendingPathComponent("version", isDirectory: false)
            guard let (vData, _) = await httpGET(session, verURL),
                  let version = parseIntellectProductVersion(data: vData), !version.isEmpty
            else { throw DiscoveryError.notRecognized }
            return DiscoveryResult(baseURL: web2, backend: .intl, summary: version)
        }

        if rawTitle == "ITV | AxxonSoft client" {
            return DiscoveryResult(baseURL: finalURL, backend: .nextLegacy, summary: "Legacy VMS version")
        }

        if let href = extractManifestHref(from: html),
           let manifestURL = resolveHref(href, against: finalURL),
           let (mData, _) = await httpGET(session, manifestURL),
           let manifest = try? decodeManifest(data: mData) {
            if manifestCloudSignal(manifest) {
                return try await cloudResult(baseURL: finalURL, manifest: manifest, session: session)
            }
            if manifestNextSignal(manifest) {
                let rawName = manifest.name ?? manifest.shortName ?? rawTitle
                let desc = displayTitle(fromRawTitle: rawName)
                return DiscoveryResult(baseURL: finalURL, backend: .next, summary: desc)
            }
        }

        if !hasManifestLink, await hasNextLocaleStrings(session: session, base: finalURL) {
            let desc = displayTitle(fromRawTitle: rawTitle)
            let summary = desc.isEmpty ? "Next" : desc
            if await appBundleContainsAuthenticateEx2(session: session, html: html, baseURL: finalURL, appendAppJsFallback: false) {
                return DiscoveryResult(baseURL: finalURL, backend: .next, summary: summary)
            }
            return DiscoveryResult(baseURL: finalURL, backend: .nextLegacy, summary: summary)
        }

        if titleLooksLikeCloudTitle(rawTitle) {
            for path in ["/manifest.json", "/manifest/manifest.json"] {
                guard let mURL = URL(string: path, relativeTo: finalURL)?.absoluteURL,
                      let (mData, _) = await httpGET(session, mURL),
                      let manifest = try? decodeManifest(data: mData),
                      manifestCloudSignal(manifest)
                else { continue }
                return try await cloudResult(baseURL: finalURL, manifest: manifest, session: session)
            }
        }

        if htmlLooksLikeNextShell(html) || titleLooksLikeNextWebClient(rawTitle) {
            let desc = displayTitle(fromRawTitle: rawTitle)
            return DiscoveryResult(baseURL: finalURL, backend: .next, summary: desc)
        }

        return nil
    }

    static func cloudResult(baseURL: URL, manifest: PWAManifest, session: URLSession) async throws -> DiscoveryResult {
        let aboutURL = baseURL.appendingPathComponent("api").appendingPathComponent("v1").appendingPathComponent("about")
        guard let (aboutData, _) = await httpGET(session, aboutURL),
              let (branch, build) = try? decodeAbout(data: aboutData)
        else { throw DiscoveryError.notRecognized }
        let name = manifest.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Cloud"
        var parts: [String] = [name]
        if let branch, !branch.isEmpty { parts.append(branch) }
        if let build, !build.isEmpty { parts.append("build \(build)") }
        let summary = parts.joined(separator: " ")
        return DiscoveryResult(baseURL: baseURL, backend: .cloud, summary: summary)
    }
}

extension URLSessionConfiguration {
    static var fast: URLSessionConfiguration {
        let x = URLSessionConfiguration.ephemeral
        x.timeoutIntervalForRequest = 5
        x.timeoutIntervalForResource = 10
        x.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return x
    }
}
