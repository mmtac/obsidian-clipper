import SwiftUI
import WebKit

/// A site whose login the clipper can reuse. The share extension attaches the
/// harvested cookies when it re-fetches a shared URL, so paywalled pages
/// (NYT etc.) return the full article instead of the anonymous shell.
struct SitePreset: Identifiable {
    /// Registrable domain suffix used for cookie matching.
    let id: String
    let name: String
    let loginURL: URL

    static let all: [SitePreset] = [
        SitePreset(id: "nytimes.com", name: "The New York Times",
                   loginURL: URL(string: "https://myaccount.nytimes.com/auth/login")!),
        SitePreset(id: "wired.com", name: "Wired",
                   loginURL: URL(string: "https://www.wired.com/account/sign-in")!),
        SitePreset(id: "theverge.com", name: "The Verge",
                   loginURL: URL(string: "https://www.theverge.com")!),
    ]
}

/// Settings screen listing supported sites with login status. Tapping a site
/// opens an in-app browser sheet; when the user taps Done, cookies for that
/// site are harvested from the WebView's cookie store into the shared
/// Keychain where the extension can read them.
struct SiteLoginView: View {

    @State private var activePreset: SitePreset?
    @State private var statuses: [String: (count: Int, earliestExpiry: Date?)] = [:]

    private let store = KeychainCookieStore.shared

    var body: some View {
        List {
            Section {
                ForEach(SitePreset.all) { preset in
                    row(for: preset)
                }
            } footer: {
                Text("Log in to a site here and the clipper will use that session when it fetches shared links — so paywalled articles clip in full. Sessions are stored in the Keychain and never leave the device.")
            }
        }
        .navigationTitle("Site Logins")
        .sheet(item: $activePreset, onDismiss: refreshStatuses) { preset in
            SiteLoginSheet(preset: preset) {
                harvestCookies(for: preset)
            }
        }
        .onAppear(perform: refreshStatuses)
    }

    @ViewBuilder
    private func row(for preset: SitePreset) -> some View {
        let status = statuses[preset.id]
        Button {
            activePreset = preset
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
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
            Button(role: .destructive) {
                store.removeCookies(domainSuffix: preset.id)
                refreshStatuses()
            } label: {
                Label("Clear", systemImage: "trash")
            }
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

    private func refreshStatuses() {
        var next: [String: (count: Int, earliestExpiry: Date?)] = [:]
        for preset in SitePreset.all {
            next[preset.id] = store.summary(forDomainSuffix: preset.id)
        }
        statuses = next
    }

    private func harvestCookies(for preset: SitePreset) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let matching = cookies.filter {
                SiteCookies.domainMatches(cookieDomain: $0.domain, host: "www." + preset.id)
                    || SiteCookies.hostMatchesSuffix(host: SiteCookies.normalizedDomain($0.domain), suffix: preset.id)
            }
            store.merge(matching)
            refreshStatuses()
        }
    }
}

/// In-app login browser. Uses the default (persistent) WKWebsiteDataStore so
/// cookies survive into the harvest step; harvest happens when the user taps
/// Done.
private struct SiteLoginSheet: View {

    let preset: SitePreset
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LoginWebView(url: preset.loginURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(preset.name)
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
