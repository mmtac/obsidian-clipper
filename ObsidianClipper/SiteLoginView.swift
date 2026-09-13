import SwiftUI
import WebKit

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

    var loginURL: URL { URL(string: loginURLString) ?? URL(string: "https://\(id)")! }

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
        UserDefaults(suiteName: ClipperSettings.suiteName) ?? .standard
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
/// opens an in-app browser sheet; when the user taps Done, cookies for that
/// site are harvested from the WebView's cookie store into the shared
/// Keychain where the extension can read them.
struct SiteLoginView: View {

    @State private var customSites: [LoginSite] = []
    @State private var activeSite: LoginSite?
    @State private var showAddSheet = false
    @State private var statuses: [String: (count: Int, earliestExpiry: Date?)] = [:]

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
                Text("Log in to a site here and the clipper will use that session when it fetches shared links — so paywalled articles clip in full. Sessions are stored in the Keychain and never leave the device. Add any site you routinely clip from with the + button.")
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
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func row(for site: LoginSite) -> some View {
        let status = statuses[site.id]
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
                Image(systemName: (status?.count ?? 0) > 0 ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle((status?.count ?? 0) > 0 ? .green : .secondary)
            }
        }
        .swipeActions {
            if !site.isPreset {
                Button(role: .destructive) {
                    CustomLoginSites.remove(id: site.id)
                    store.removeCookies(domainSuffix: site.id)
                    refresh()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            Button {
                store.removeCookies(domainSuffix: site.id)
                refresh()
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
/// cookies survive into the harvest step; harvest happens when the user taps
/// Done.
private struct SiteLoginSheet: View {

    let site: LoginSite
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LoginWebView(url: site.loginURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(site.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onDone()
                            dismiss()
                        }
                    }
                }
        }
        .interactiveDismissDisabled(false)
        .onDisappear(perform: onDone)
    }
}

private struct LoginWebView: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
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
