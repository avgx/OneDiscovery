import Foundation

/// Raw `<title>` text (inner HTML, trimmed).
func extractRawTitle(from html: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"<title[^>]*>(.*?)</title>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
          let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
          m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: html)
    else { return "" }
    return String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// User-facing name derived from page title (no trailing ` Web` / ` client`). Does not apply legacy ITV mapping.
func displayTitle(fromRawTitle raw: String) -> String {
    var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasSuffix(" Web") {
        t.removeLast(4)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if t.hasSuffix(" client") {
        t.removeLast(7)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return t
}

func extractManifestHref(from html: String) -> String? {
    let patterns = [
        #"<link[^>]+rel\s*=\s*["']manifest["'][^>]*href\s*=\s*["']([^"']+)["']"#,
        #"<link[^>]+href\s*=\s*["']([^"']+)["'][^>]+rel\s*=\s*["']manifest["']"#,
    ]
    for p in patterns {
        guard let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
        guard let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: html)
        else { continue }
        return String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
}

struct PWAManifest: Decodable, Sendable {
    let name: String?
    let shortName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case shortName = "short_name"
    }
}

func decodeManifest(data: Data) throws -> PWAManifest {
    try JSONDecoder().decode(PWAManifest.self, from: data)
}

func manifestCloudSignal(_ m: PWAManifest) -> Bool {
    let short = m.shortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return short.caseInsensitiveCompare("cloud") == .orderedSame
}

func manifestNextSignal(_ m: PWAManifest) -> Bool {
    let n = m.name?.lowercased() ?? ""
    return n.contains("next") || (m.shortName?.lowercased().contains("next") ?? false)
}

private struct AboutEnvelope: Decodable, Sendable {
    let resultObject: ResultObject?
    struct ResultObject: Decodable, Sendable {
        let buildNumber: String?
        let branchName: String?
    }
}

func decodeAbout(data: Data) throws -> (branch: String?, build: String?) {
    let e = try JSONDecoder().decode(AboutEnvelope.self, from: data)
    return (e.resultObject?.branchName, e.resultObject?.buildNumber)
}

/// Raw `/product/version` body: trim; for plain text, replace the **last** `/` with a space
func parseIntellectProductVersion(data: Data) -> String? {
    let s = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    if !t.contains("<"), let i = t.lastIndex(of: "/") {
        t.replaceSubrange(i ... i, with: " ")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return t.isEmpty ? nil : t
}

/// Phase-B heuristic URLs (alternate ports/paths). Does not include the direct input URL.
func heuristicExpansions(from input: URL) -> [URL] {
    guard let parts = URLComponents(url: input, resolvingAgainstBaseURL: true), parts.host != nil else {
        return []
    }

    let path = parts.path.isEmpty ? "/" : parts.path
    let scheme = (parts.scheme ?? "https").lowercased()
    let inputUsesHTTPPort80 = scheme == "http" && (parts.port == nil || parts.port == 80)
    var seen = Set<String>()
    var out: [URL] = []

    func append(_ url: URL?) {
        guard let url else { return }
        let key = url.absoluteString
        if seen.insert(key).inserted { out.append(url) }
    }

    func appendAsipAPI(from base: URLComponents, path: String) {
        guard !path.contains("asip-api") else { return }
        var p2 = base
        let root = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
        let ap: String
        if root == "/" || root.isEmpty {
            ap = "/asip-api/"
        } else if root.hasSuffix("/") {
            ap = root + "asip-api/"
        } else {
            ap = root + "/asip-api/"
        }
        p2.path = ap
        append(p2.url)
    }

    switch scheme {
    case "http":
        if !inputUsesHTTPPort80 {
            var p80 = parts
            p80.scheme = "http"
            p80.port = nil
            p80.path = path
            append(p80.url)
        }

        for port in [8080, 8000] {
            var p = parts
            p.scheme = "http"
            p.port = port
            p.path = path
            append(p.url)
            appendAsipAPI(from: p, path: path)
        }

        var p8085 = parts
        p8085.scheme = "http"
        p8085.port = 8085
        p8085.path = "/web2/"
        append(p8085.url)

    case "https":
        for port in [8443] {
            var p = parts
            p.scheme = "https"
            p.port = port
            p.path = path
            append(p.url)
            appendAsipAPI(from: p, path: path)
        }

    default:
        break
    }

    return out
}

func resolveHref(_ href: String, against base: URL) -> URL? {
    URL(string: href, relativeTo: base)?.absoluteURL
}
