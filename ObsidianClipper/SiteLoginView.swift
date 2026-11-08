import SwiftUI
import WebKit
import os

/// A site whose login the clipper can reuse. The share extension attaches the
/// harvested cookies when it re-fetches a shared URL, so paywalled pages
/// (NYT etc.) return the full article instead of the anonymous shell.
/// Built-in presets cover common paywalls; users add their own sites for
/// whatever sources they routinely read.
struct LoginSite: Identifiable, Equatable, Codable {
    /// Registrable domain suffix used for cookie matching.
    let id: String
    let name: String
    let loginURLString: String
    var isPreset: Bool = false

    /// Where the login sheet opens. Nil only if both the stored URL and the
    /// bare domain fail to parse, which the sheet reports instead of crashing.
    var loginURL: URL? { URL(string: loginURLString) ?? URL(string: "https://\(id)") }

    static let presets: [LoginSite] = [
        LoginSite(id: "nytimes.com", name: "The New York Times",
                  loginURLString: "https://myaccount.nytimes.com/auth/login", isPreset: true),
        LoginSite(id: "wired.com", name: "Wired",
                  loginURLString: "https://www.wired.com/account/sign-in", isPreset: true),
        LoginSite(id: "theverge.com", name: "The Verge",
                  loginURLString: "https://www.theverge.com", isPreset: true),
    ]
}

/// Persistence for user-added login sites, in the App Group defaults so the
/// list survives reinstalls alongside the rest of the settings. (The
/// extension never reads this list — cookie matching is purely by domain —
/// so it lives here rather than in ClipperSettings.)
enum CustomLoginSites {

    private static let key = "custom_login_sites"

    private static var defaults: UserDefaults {
        ClipperSettings.sharedDefaults()
    }

    static func load() -> [LoginSite] {
        guard let data = defaults.data(forKey: key),
              let sites = try? JSONDecoder().decode([LoginSite].self, from: data) else {
            return []
        }
        return sites
    }

    static func save(_ sites: [LoginSite]) {
        if let data = try? JSONEncoder().encode(sites) {
            defaults.set(data, forKey: key)
        }
    }

    /// Add a site from raw user input. Returns the stored site, or nil when
    /// the input has no plausible domain. Duplicates (by domain, including
    /// presets) return the existing entry instead of adding twice.
    static func add(input: String, name: String) -> LoginSite? {
        guard let parsed = SiteCookies.parseSiteInput(input) else { return nil }
        if let preset = LoginSite.presets.first(where: { $0.id == parsed.domain }) {
            return preset
        }
        var sites = load()
        if let existing = sites.first(where: { $0.id == parsed.domain }) {
            return existing
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = LoginSite(
            id: parsed.domain,
            name: trimmedName.isEmpty ? parsed.domain : trimmedName,
            loginURLString: parsed.loginURL.absoluteString
        )
        sites.append(site)
        save(sites)
        return site
    }

    static func remove(id: String) {
        save(load().filter { $0.id != id })
    }
}

/// Settings screen listing supported sites with login status. Tapping a site
/// opens an in-app browser sheet; when the sheet closes, cookies for that
/// site are harvested from the WebView's cookie store into the shared
/// Keychain where the extension can read them.
struct SiteLoginView: View {

    /// A destructive action awaiting confirmation.
    private enum PendingAction: Identifiable {
        case logOut(LoginSite)
        case remove(LoginSite)

        var id: String {
            switch self {
            case .logOut(let site): return "logout-\(site.id)"
            case .remove(let site): return "remove-\(site.id)"
            }
        }

        var site: LoginSite {
            switch self {
            case .logOut(let site), .remove(let site): return site
            }
        }
    }

    @State private var customSites: [LoginSite] = []
    @State private var activeSite: LoginSite?
    @State private var showAddSheet = false
    @State private var statuses: [String: (count: Int, earliestExpiry: Date?)] = [:]
    @State private var pendingAction: PendingAction?

    private let store = KeychainCookieStore.shared

    private var allSites: [LoginSite] {
        LoginSite.presets + customSites.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                ForEach(allSites) { site in
                    row(for: site)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Log in to a site here and the clipper will use that session when it fetches shared links — so paywalled articles clip in full. Sessions are stored in the Keychain and never leave the device. Add any site you routinely clip from with the + button. Swipe left on a site to log out.")
                    Text("Sign in with Google or Apple may not work in this browser — use the site's email and password sign-in.")
                }
            }
        }
        .navigationTitle("Site Logins")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Site", systemImage: "plus")
                }
            }
        }
        .sheet(item: $activeSite, onDismiss: refresh) { site in
            SiteLoginSheet(site: site) {
                harvestCookies(for: site)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddSiteSheet { newSite in
                refresh()
                // Drop straight into the login sheet for the new site.
                activeSite = newSite
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            switch action {
            case .logOut(let site):
                Button("Log Out", role: .destructive) { logOut(site) }
            case .remove(let site):
                Button("Remove Site", role: .destructive) { remove(site) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            switch action {
            case .logOut(let site):
                Text("The saved session for \(site.name) will be deleted. Clips from this site will no longer include content that requires a login.")
            case .remove(let site):
                Text("\(site.name) and its saved session will be removed from the clipper.")
            }
        }
        .onAppear(perform: refresh)
    }

    private var confirmationTitle: String {
        switch pendingAction {
        case .logOut(let site): return "Log out of \(site.name)?"
        case .remove(let site): return "Remove \(site.name)?"
        case nil: return ""
        }
    }

    @ViewBuilder
    private func row(for site: LoginSite) -> some View {
        let status = statuses[site.id]
        let loggedIn = (status?.count ?? 0) > 0
        Button {
            activeSite = site
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.name)
                        .foregroundStyle(.primary)
                    Text(statusText(for: status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: loggedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle(loggedIn ? .green : .secondary)
                    .accessibilityLabel(loggedIn ? "Logged in" : "Not logged in")
            }
        }
        .accessibilityHint("Opens the sign-in page")
        .swipeActions {
            if !site.isPreset {
                Button(role: .destructive) {
                    pendingAction = .remove(site)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            Button {
                pendingAction = .logOut(site)
            } label: {
                Label("Log Out", systemImage: "person.crop.circle.badge.xmark")
            }
            .tint(.orange)
        }
    }

    private func statusText(for status: (count: Int, earliestExpiry: Date?)?) -> String {
        guard let status, status.count > 0 else { return "Not logged in" }
        if let expiry = status.earliestExpiry {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return "Logged in · session until \(formatter.string(from: expiry))"
        }
        return "Logged in"
    }

    private func refresh() {
        customSites = CustomLoginSites.load()
        var next: [String: (count: Int, earliestExpiry: Date?)] = [:]
        for site in LoginSite.presets + customSites {
            next[site.id] = store.summary(forDomainSuffix: site.id)
        }
        statuses = next
    }

    private func logOut(_ site: LoginSite) {
        store.removeCookies(domainSuffix: site.id)
        refresh()
        Task { await clearWebSession(for: site) }
    }

    private func remove(_ site: LoginSite) {
        CustomLoginSites.remove(id: site.id)
        logOut(site)
    }

    /// Delete the site's session from the in-app browser too. Without this the
    /// persistent WKWebsiteDataStore still holds the login, and reopening the
    /// sheet would silently re-harvest it into the Keychain.
    @MainActor
    private func clearWebSession(for site: LoginSite) async {
        let dataStore = WKWebsiteDataStore.default()
        let cookieStore = dataStore.httpCookieStore
        for cookie in await cookieStore.allCookies()
        where SiteCookies.hostMatchesSuffix(host: SiteCookies.normalizedDomain(cookie.domain), suffix: site.id) {
            await cookieStore.deleteCookie(cookie)
        }
        // Data records are keyed by registrable domain ("nytimes.com"), so
        // match in both directions to cover sites stored by subdomain.
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types).filter { record in
            let name = record.displayName.lowercased()
            return SiteCookies.hostMatchesSuffix(host: name, suffix: site.id)
                || SiteCookies.hostMatchesSuffix(host: site.id, suffix: name)
        }
        if !records.isEmpty {
            await dataStore.removeData(ofTypes: types, for: records)
        }
        Self.logger.info("Cleared web session for site; cookies and \(records.count) data records removed")
    }

    private static let logger = Logger(subsystem: "com.obsidian.clipper", category: "site-login")

    private func harvestCookies(for site: LoginSite) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let matching = cookies.filter {
                SiteCookies.hostMatchesSuffix(host: SiteCookies.normalizedDomain($0.domain), suffix: site.id)
            }
            store.merge(matching)
            refresh()
        }
    }
}

/// Form for adding a custom site: paste a domain, host, or a specific
/// login-page URL.
private struct AddSiteSheet: View {

    let onAdded: (LoginSite) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var showInvalidInput = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("washingtonpost.com", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Name (optional)", text: $name)
                } header: {
                    Text("Site")
                } footer: {
                    Text("Enter the site's domain, or paste its sign-in page URL and the login screen will open there directly.")
                }
            }
            .navigationTitle("Add Site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let site = CustomLoginSites.add(input: address, name: name) {
                            dismiss()
                            onAdded(site)
                        } else {
                            showInvalidInput = true
                        }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Couldn't recognize that address", isPresented: $showInvalidInput) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Enter a domain like example.com, or a full https:// URL.")
            }
        }
    }
}

/// In-app login browser. Uses the default (persistent) WKWebsiteDataStore so
/// cookies survive into the harvest step; harvest happens once, when the
/// sheet goes away (Done or swipe-to-dismiss).
private struct SiteLoginSheet: View {

    let site: LoginSite
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var browser = LoginBrowser()

    var body: some View {
        NavigationStack {
            content
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(site.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        titleView
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        if browser.isLoading {
                            ProgressView()
                                .accessibilityLabel("Loading")
                        }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            browser.goBack()
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .disabled(!browser.canGoBack)
                        Spacer()
                        Button {
                            browser.reload()
                        } label: {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                        .disabled(site.loginURL == nil)
                    }
                }
        }
        .onDisappear(perform: onFinish)
    }

    @ViewBuilder
    private var content: some View {
        if let url = site.loginURL {
            ZStack {
                LoginWebView(url: url, browser: browser)
                if let error = browser.loadError {
                    ContentUnavailableView {
                        Label("Couldn't Load Page", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { browser.reload() }
                            .buttonStyle(.borderedProminent)
                    }
                    .background(Color(uiColor: .systemBackground))
                }
            }
        } else {
            ContentUnavailableView(
                "Invalid Address",
                systemImage: "exclamationmark.triangle",
                description: Text("This site's sign-in address couldn't be read. Remove the site and add it again.")
            )
        }
    }

    private var titleView: some View {
        VStack(spacing: 0) {
            Text(site.name)
                .font(.headline)
                .lineLimit(1)
            if let host = browser.host {
                HStack(spacing: 3) {
                    if browser.isSecure {
                        Image(systemName: "lock.fill")
                            .imageScale(.small)
                            .accessibilityLabel("Secure connection")
                    }
                    Text(host)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Navigation state for the login browser, doubling as the web view's
/// navigation delegate.
@Observable
@MainActor
private final class LoginBrowser: NSObject, WKNavigationDelegate {

    var isLoading = false
    var canGoBack = false
    var host: String?
    var isSecure = false
    var loadError: String?

    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var initialURL: URL?
    @ObservationIgnored private var failedURL: URL?

    func goBack() {
        loadError = nil
        webView?.goBack()
    }

    /// Reload the current page, or retry the URL that failed to load.
    func reload() {
        guard let webView else { return }
        loadError = nil
        if let target = failedURL ?? (webView.url == nil ? initialURL : nil) {
            failedURL = nil
            webView.load(URLRequest(url: target))
        } else {
            webView.reload()
        }
    }

    private func sync(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        if let url = webView.url {
            host = url.host
            isSecure = url.scheme?.lowercased() == "https"
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        loadError = nil
        failedURL = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        sync(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        sync(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error, in: webView)
    }

    private func handle(_ error: Error, in webView: WKWebView) {
        isLoading = false
        sync(webView)
        let nsError = error as NSError
        // A redirect or a new tap supersedes the load; not a real failure.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        failedURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        loadError = nsError.localizedDescription
    }
}

private struct LoginWebView: UIViewRepresentable {

    let url: URL
    let browser: LoginBrowser

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = browser
        browser.webView = webView
        browser.initialURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#Preview {
    NavigationStack {
        SiteLoginView()
    }
}
