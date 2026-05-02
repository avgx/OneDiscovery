import Foundation

public enum Web {
    /// Discover product at or near `url`. Uses a fast ephemeral session when `session` is `nil`.
    public static func explore(url: URL, session: URLSession? = nil) async throws -> DiscoveryResult {
        let sess = session ?? URLSession(configuration: .fast)
        for candidate in expansionCandidates(from: url) {
            guard let (data, http) = await httpGET(sess, candidate, redirectDepth: 0),
                  let html = String(data: data, encoding: .utf8)
            else { continue }
            let finalURL = http.url ?? candidate
            let rawTitle = extractRawTitle(from: html)
            let intlStrong = isStrongIntlSignal(html: html, rawTitle: rawTitle)
            do {
                if let r = try await discoverImpl(from: finalURL, html: html, session: sess) {
                    return r
                }
            } catch DiscoveryError.notRecognized {
                if intlStrong { throw DiscoveryError.notRecognized }
                continue
            }
        }
        throw DiscoveryError.notRecognized
    }

    /// Classify from a page already fetched at `baseURL` (tests and tooling).
    public static func discover(from baseURL: URL, html: String, session: URLSession? = nil) async throws -> DiscoveryResult? {
        let sess = session ?? URLSession(configuration: .fast)
        return try await discoverImpl(from: baseURL, html: html, session: sess)
    }
}

// MARK: - Internals

private extension Web {
    /// Follows `Location` manually when the transport returns 3xx (e.g. `/web2` → `/web2/`), in addition to URLSession’s default redirect handling.
    static func httpGET(_ session: URLSession, _ url: URL, redirectDepth: Int) async -> (Data, HTTPURLResponse)? {
        guard redirectDepth < 8 else { return nil }
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse else { return nil }
            if (200...299).contains(http.statusCode) { return (data, http) }
            if let loc = http.value(forHTTPHeaderField: "Location")?.trimmingCharacters(in: .whitespacesAndNewlines),
               [301, 302, 303, 307, 308].contains(http.statusCode) {
                let base = http.url ?? url
                guard let next = URL(string: loc, relativeTo: base)?.absoluteURL else { return nil }
                return await httpGET(session, next, redirectDepth: redirectDepth + 1)
            }
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
        guard let (data, http) = await httpGET(session, u, redirectDepth: 0),
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

    static func discoverImpl(from finalURL: URL, html: String, session: URLSession) async throws -> DiscoveryResult? {
        let rawTitle = extractRawTitle(from: html)
        let hasManifestLink = extractManifestHref(from: html) != nil

        if isStrongIntlSignal(html: html, rawTitle: rawTitle) {
            let web2 = intellectWeb2Root(from: finalURL, html: html, rawTitle: rawTitle)
            let verURL = web2.appendingPathComponent("product", isDirectory: false).appendingPathComponent("version", isDirectory: false)
            guard let (vData, _) = await httpGET(session, verURL, redirectDepth: 0),
                  let version = parseIntellectProductVersion(data: vData), !version.isEmpty
            else { throw DiscoveryError.notRecognized }
            return DiscoveryResult(baseURL: web2, api: .intl, summary: version)
        }

        if rawTitle == "ITV | AxxonSoft client" {
            return DiscoveryResult(baseURL: finalURL, api: .nextLegacy, summary: "Legacy VMS version")
        }

        if let href = extractManifestHref(from: html),
           let manifestURL = resolveHref(href, against: finalURL),
           let (mData, _) = await httpGET(session, manifestURL, redirectDepth: 0),
           let manifest = try? decodeManifest(data: mData) {
            if manifestCloudSignal(manifest) {
                return try await cloudResult(baseURL: finalURL, manifest: manifest, session: session)
            }
            if manifestNextSignal(manifest) {
                let rawName = manifest.name ?? manifest.shortName ?? rawTitle
                let desc = displayTitle(fromRawTitle: rawName)
                return DiscoveryResult(baseURL: finalURL, api: .next, summary: desc)
            }
        }

        if !hasManifestLink, await hasNextLocaleStrings(session: session, base: finalURL) {
            let desc = displayTitle(fromRawTitle: rawTitle)
            let summary = desc.isEmpty ? "Next" : desc
            return DiscoveryResult(baseURL: finalURL, api: .nextLegacy, summary: summary)
        }

        if titleLooksLikeCloudTitle(rawTitle) {
            for path in ["/manifest.json", "/manifest/manifest.json"] {
                guard let mURL = URL(string: path, relativeTo: finalURL)?.absoluteURL,
                      let (mData, _) = await httpGET(session, mURL, redirectDepth: 0),
                      let manifest = try? decodeManifest(data: mData),
                      manifestCloudSignal(manifest)
                else { continue }
                return try await cloudResult(baseURL: finalURL, manifest: manifest, session: session)
            }
        }

        if htmlLooksLikeNextShell(html) || titleLooksLikeNextWebClient(rawTitle) {
            let desc = displayTitle(fromRawTitle: rawTitle)
            return DiscoveryResult(baseURL: finalURL, api: .next, summary: desc)
        }

        return nil
    }

    static func cloudResult(baseURL: URL, manifest: PWAManifest, session: URLSession) async throws -> DiscoveryResult {
        let aboutURL = baseURL.appendingPathComponent("api").appendingPathComponent("v1").appendingPathComponent("about")
        guard let (aboutData, _) = await httpGET(session, aboutURL, redirectDepth: 0),
              let (branch, build) = try? decodeAbout(data: aboutData)
        else { throw DiscoveryError.notRecognized }
        let name = manifest.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Cloud"
        var parts: [String] = [name]
        if let branch, !branch.isEmpty { parts.append(branch) }
        if let build, !build.isEmpty { parts.append("build \(build)") }
        let summary = parts.joined(separator: " ")
        return DiscoveryResult(baseURL: baseURL, api: .cloud, summary: summary)
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
