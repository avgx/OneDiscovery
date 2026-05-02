# OneDiscovery
Guess by unauthorized HTTP response what kind of product/API/OEM we are connecting to. Used for a user-defined URL for the root page of the product.

The package takes a user `displayUrl` (host, IP, or full URL with scheme, path, and port) and determines whether a supported product is present and the real API base URL.

Typical probing pattern when the bare host does not answer:

- For **Next**-style web clients: try ports **8080** and **8000**, with optional path **`/asip-api`**, in addition to the original URL.
- For **Intellect**: try port **8085** with path **`/web2/`**.

**Cloud**: extra metadata from **`/api/v1/about`** and the PWA manifest.

**Intellect**: human-readable **`summary`** from **`/product/version`** (not from generic HTML titles).

**Next** (current / PWA): classification from the manifest and/or page signals; optional **`/app.js`** checks (e.g. `v1/authenticate/authenticate_ex2`) can be used when a cheaper signal is not enough.

**Next legacy** (old web shell): no manifest link, but **`/locale/strings-en.xml`** is present — classified as **`.nextLegacy`** (including the fixed **`ITV | AxxonSoft client`** title).

If nothing matches, discovery throws **`DiscoveryError.notRecognized`**.

Successful **`DiscoveryResult`** exposes **`summary`** (human-readable line) and conforms to **`CustomStringConvertible`** for logging.

Tests use bundled HTTP fixtures only (no network in CI). For a one-off live run, see `ManualNetworkDiscoveryTests.swift`.
