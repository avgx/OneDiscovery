# OneDiscovery
Guess by unauthorized HTTP response what kind of product/API/OEM we are connecting to. Used for a user-defined URL for the root page of the product.

The package takes a user `displayUrl` (host, IP, or full URL with scheme, path, and port) and determines whether a supported product is present and the real API base URL.

## Usage

Probe a URL (tries alternate ports/paths internally; uses a short-lived session if you pass `session: nil`):

```swift
import OneDiscovery

let url = URL(string: "https://vms.example.com:8080/")!
let result = try await Web.explore(url: url)
// result.api: .cloud | .next | .nextLegacy | .intl
// result.baseURL — web root after redirects, use as base for further HTTP calls
// result.summary — human-readable line for UI or logs
// String(describing: result) — same fields, handy for logging
```

If nothing is recognized, `Web.explore` throws **`DiscoveryError.notRecognized`**.

When you already have the root HTML (tests, cached fetch, or a custom session), you can classify without re-fetching the landing page:

```swift
let html = String(decoding: data, as: UTF8.self)
if let result = try await Web.discover(from: pageURL, html: html, session: urlSession) {
    // use result
}
```

`Web.discover` returns **`nil`** when the HTML does not match any supported product. It still **`throws`** in the same cases as a full probe where a product was identified but a required follow-up request failed (for example Intellect shell without **`/product/version`**, or Cloud manifest without **`/api/v1/about`**).

Typical probing pattern when the bare host does not answer:

- For **Next**-style: try ports **8080** and **8000**, with optional path **`/asip-api`**, in addition to the original URL.
- For **Intellect**: try port **8085** with path **`/web2/`**.

**Cloud**: extra metadata from **`/api/v1/about`** and the PWA manifest.

**Intellect**: human-readable **`summary`** from **`/product/version`** (not from generic HTML titles).

**Next** (current / PWA): classification from the manifest and/or page signals (`window.login` / title, etc.).

**Next legacy** (old web shell): no manifest link, but **`/locale/strings-en.xml`** is present — usually **`.nextLegacy`**. If the page also references a main app script (`app.js` or `app.<hash>.js` in `<script src>`) and that script contains **`v1/authenticate/authenticate_ex2`**, the host is classified as **`.next`** instead (modern client still shipping locale files). Cloud and Intellect discovery never fetch these app bundles.

If nothing matches, discovery throws **`DiscoveryError.notRecognized`**.

Successful **`DiscoveryResult`** exposes **`summary`** (human-readable line) and conforms to **`CustomStringConvertible`** for logging.
