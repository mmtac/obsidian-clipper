import Foundation
import Security
import os

/// Persistence seam for site-login cookies. The main app writes cookies
/// harvested from its in-app login WKWebView; the share extension reads them
/// to authenticate its URL re-fetches. The production implementation is
/// `KeychainCookieStore` (shared Keychain, App Group access group); tests use
/// an in-memory fake.
protocol CookieStoring: Sendable {
    /// All persisted cookies, unfiltered.
    func loadAll() -> [HTTPCookie]
    /// Replace the full persisted set.
    func saveAll(_ cookies: [HTTPCookie])
}

extension CookieStoring {

    /// Cookies applicable to `url`: https only, domain- and path-matched,
    /// and unexpired. Never attached to plaintext http.
    func cookies(for url: URL) -> [HTTPCookie] {
        SiteCookies.applicable(SiteCookies.prunedExpired(loadAll()), to: url)
    }

    /// Merge freshly received cookies into the store (matching on
    /// domain+name+path, newer wins), pruning expired ones.
    func merge(_ new: [HTTPCookie]) {
        guard !new.isEmpty else { return }
        saveAll(SiteCookies.prunedExpired(SiteCookies.merge(existing: loadAll(), adding: new)))
    }

    /// Remove all cookies whose domain matches the given registrable suffix
    /// (e.g. "nytimes.com" removes ".nytimes.com" and "www.nytimes.com").
    func removeCookies(domainSuffix: String) {
        saveAll(loadAll().filter { !SiteCookies.domainMatches(cookieDomain: $0.domain, host: domainSuffix)
            && !SiteCookies.hostMatchesSuffix(host: SiteCookies.normalizedDomain($0.domain), suffix: domainSuffix) })
    }

    /// Per-domain-suffix summary for the settings UI: cookie count and the
    /// earliest expiry among persistent cookies (nil when all are session cookies).
    func summary(forDomainSuffix suffix: String) -> (count: Int, earliestExpiry: Date?) {
        let matching = SiteCookies.prunedExpired(loadAll()).filter {
            SiteCookies.hostMatchesSuffix(host: SiteCookies.normalizedDomain($0.domain), suffix: suffix)
        }
        let expiries = matching.compactMap { $0.expiresDate }
        return (matching.count, expiries.min())
    }
}

/// Pure helpers over `[HTTPCookie]` — kept free of I/O so they are trivially
/// unit-testable.
enum SiteCookies {

    /// Strip a leading dot from a cookie domain ("`.nytimes.com`" → "`nytimes.com`").
    static func normalizedDomain(_ domain: String) -> String {
        domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    }

    /// RFC 6265 domain matching: a cookie for `.nytimes.com` applies to
    /// `nytimes.com` and any subdomain (`www.nytimes.com`).
    static func domainMatches(cookieDomain: String, host: String) -> Bool {
        let domain = normalizedDomain(cookieDomain).lowercased()
        let host = host.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }

    /// True when `host` equals `suffix` or is a subdomain of it.
    static func hostMatchesSuffix(host: String, suffix: String) -> Bool {
        domainMatches(cookieDomain: suffix, host: host)
    }

    /// Whether the login browser may navigate its main frame to `url`.
    /// The browser is confined to the site being signed into (and any
    /// sign-in domains it uses), so it never acts as a general web browser.
    static func isLoginNavigationAllowed(_ url: URL, allowedDomains: [String]) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else {
            return false
        }
        return allowedDomains.contains { hostMatchesSuffix(host: host, suffix: $0) }
    }

    /// Filter to cookies applicable to `url` (domain, path). Stored cookies
    /// are login credentials, so nothing — Secure flag or not — is ever
    /// returned for a non-https URL.
    static func applicable(_ cookies: [HTTPCookie], to url: URL) -> [HTTPCookie] {
        guard let host = url.host, url.scheme?.lowercased() == "https" else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        return cookies.filter { cookie in
            guard domainMatches(cookieDomain: cookie.domain, host: host) else { return false }
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            return path.hasPrefix(cookiePath)
        }
    }

    /// Drop cookies whose expiry has passed. Session cookies (no expiry)
    /// are kept — for a harvested login they remain valid until the site
    /// rejects them, at which point the quality gate surfaces the failure.
    static func prunedExpired(_ cookies: [HTTPCookie], now: Date = Date()) -> [HTTPCookie] {
        cookies.filter { cookie in
            guard let expires = cookie.expiresDate else { return true }
            return expires > now
        }
    }

    /// Keep only `new` cookies whose domain equals or is a subdomain of a
    /// site already present in `stored` — Set-Cookie headers from a redirect
    /// target can't introduce cookies for an unrelated site.
    static func restrictedToStoredSites(_ new: [HTTPCookie], stored: [HTTPCookie]) -> [HTTPCookie] {
        let sites = Set(stored.map { normalizedDomain($0.domain).lowercased() })
        return new.filter { cookie in
            let domain = normalizedDomain(cookie.domain)
            return sites.contains { hostMatchesSuffix(host: domain, suffix: $0) }
        }
    }

    /// Merge `adding` over `existing`, matching on (domain, name, path);
    /// entries from `adding` win.
    static func merge(existing: [HTTPCookie], adding: [HTTPCookie]) -> [HTTPCookie] {
        var byKey: [String: HTTPCookie] = [:]
        for cookie in existing + adding {
            byKey["\(normalizedDomain(cookie.domain).lowercased())|\(cookie.name)|\(cookie.path)"] = cookie
        }
        return Array(byKey.values)
    }

    // MARK: - Site input parsing

    /// Parse user input naming a site — a bare domain ("washingtonpost.com"),
    /// a host ("www.economist.com"), or a full URL (optionally a specific
    /// login page) — into the domain suffix used for cookie matching plus the
    /// URL the login sheet should open. Returns nil for input with no
    /// plausible domain.
    static func parseSiteInput(_ input: String) -> (domain: String, loginURL: URL)? {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed),
              let host = url.host,
              host.contains("."),
              url.scheme == "https" || url.scheme == "http" else {
            return nil
        }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        // Keep a user-supplied login path; otherwise open the site root.
        let loginURL = url.path.isEmpty || url.path == "/"
            ? URL(string: "https://\(host)")!
            : url
        return (domain, loginURL)
    }

    // MARK: - Serialization

    /// Round-trip cookies through a plist-safe representation
    /// (`HTTPCookie.properties` with string keys). Dates and strings only —
    /// no NSKeyedArchiver.
    static func serialize(_ cookies: [HTTPCookie]) -> Data? {
        let dicts: [[String: Any]] = cookies.compactMap { cookie in
            guard let properties = cookie.properties else { return nil }
            var out: [String: Any] = [:]
            for (key, value) in properties {
                out[key.rawValue] = value
            }
            return out
        }
        return try? PropertyListSerialization.data(fromPropertyList: dicts, format: .binary, options: 0)
    }

    static func deserialize(_ data: Data) -> [HTTPCookie] {
        guard let raw = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { dict in
            var properties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in dict {
                properties[HTTPCookiePropertyKey(key)] = value
            }
            return HTTPCookie(properties: properties)
        }
    }
}

/// Keychain-backed store shared between the app and the extension via the
/// App Group keychain access group. Session cookies are credentials, so they
/// live in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` —
/// never synced or restored to another device), never in the plaintext App
/// Group UserDefaults plist.
final class KeychainCookieStore: CookieStoring, @unchecked Sendable {

    static let shared = KeychainCookieStore()

    private let service = "com.mmtac.md-clipper.site-cookies"
    private let account = "all"
    private let accessGroup: String?
    private let log = Logger(subsystem: "com.mmtac.md-clipper", category: "cookies")
    private let migrationLock = NSLock()
    private var didMigrateAccessibility = false

    /// `accessGroup` defaults to the App Group ID — the app-groups
    /// entitlement alone authorizes it as a keychain access group on iOS
    /// (no `keychain-access-groups` entitlement; adding one breaks
    /// provisioning-profile matching). Pass `nil` for contexts without the
    /// entitlement (unit test runners).
    init(accessGroup: String? = ClipperSettings.suiteName) {
        self.accessGroup = accessGroup
    }

    func loadAll() -> [HTTPCookie] {
        var query = baseQuery(withGroup: accessGroup != nil)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        var withGroup = accessGroup != nil
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement && withGroup {
            // Simulator/test runners lack the access-group entitlement;
            // fall back to the default group so local dev still works.
            log.notice("keychain access group unavailable on read; falling back to default group")
            withGroup = false
            var fallback = baseQuery(withGroup: false)
            fallback[kSecReturnData as String] = true
            fallback[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(fallback as CFDictionary, &result)
        }
        guard status == errSecSuccess, let data = result as? Data else { return [] }
        migrateAccessibilityIfNeeded(withGroup: withGroup)
        return SiteCookies.deserialize(data)
    }

    /// Items written by earlier builds used `kSecAttrAccessibleAfterFirstUnlock`
    /// (eligible for backup/migration to another device). Downgrade them to
    /// `...ThisDeviceOnly` once per process; best-effort.
    private func migrateAccessibilityIfNeeded(withGroup: Bool) {
        migrationLock.lock()
        let alreadyDone = didMigrateAccessibility
        didMigrateAccessibility = true
        migrationLock.unlock()
        guard !alreadyDone else { return }

        let update: [String: Any] = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(baseQuery(withGroup: withGroup) as CFDictionary, update as CFDictionary)
        if status != errSecSuccess {
            log.error("keychain accessibility migration failed: \(status)")
        }
    }

    func saveAll(_ cookies: [HTTPCookie]) {
        guard let data = SiteCookies.serialize(cookies) else { return }
        save(data: data, withGroup: accessGroup != nil)
    }

    private func save(data: Data, withGroup: Bool) {
        let query = baseQuery(withGroup: withGroup)
        let update: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecMissingEntitlement && withGroup {
            log.notice("keychain access group unavailable on write; falling back to default group")
            save(data: data, withGroup: false)
        } else if status != errSecSuccess {
            log.error("keychain save failed: \(status)")
        }
    }

    private func baseQuery(withGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if withGroup, let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
