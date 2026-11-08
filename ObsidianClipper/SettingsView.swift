import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var settings: ClipperSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var stepBadgeSize: CGFloat = 24
    @State private var showFolderPicker = false
    @State private var resolvedPath: String = "Not set"
    @State private var vaultIsAccessible = false
    @State private var vaultError: VaultBookmarkError?
    #if DEBUG
    @State private var lastExtensionLaunch: String = "Never"
    @State private var extensionLaunchCount: Int = 0
    #endif

    private var needsOnboarding: Bool {
        settings.vaultBookmark == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Onboarding Banner
                if needsOnboarding {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.largeTitle)
                                .imageScale(.large)
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            Text("Get Started")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Text("Select your Obsidian vault folder to start clipping web pages. Tap the button below to choose a folder from iCloud Drive or local storage.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button {
                                showFolderPicker = true
                            } label: {
                                Label("Select Vault Folder", systemImage: "folder.badge.plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        .padding(.vertical, 8)
                    }
                }

                // MARK: - Vault Configuration
                Section {
                    adaptiveRow {
                        Label("Target Folder", systemImage: "folder")
                    } content: {
                        TextField("e.g. Inbox", text: $settings.targetFolder)
                            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Select Vault Folder", systemImage: "folder.badge.plus")
                    }

                    vaultLocationRow
                } header: {
                    Text("Vault")
                } footer: {
                    Text("Select the root folder of your Obsidian vault in iCloud Drive or On My iPhone. The target folder is created inside the vault if it doesn't exist.")
                }

                // MARK: - Clipping Options
                Section {
                    Toggle(isOn: $settings.includeFrontmatter) {
                        Label("YAML Frontmatter", systemImage: "doc.text")
                    }

                    Toggle(isOn: $settings.saveImages) {
                        Label("Save Images", systemImage: "photo.on.rectangle")
                    }

                    Toggle(isOn: $settings.enableOCR) {
                        Label("OCR on Images", systemImage: "text.viewfinder")
                    }
                } header: {
                    Text("Clipping Options")
                } footer: {
                    Text("When enabled, images found in the page are downloaded to an images/ subfolder. OCR extracts text from images and includes it in the note as a blockquote.")
                }

                // MARK: - Site Logins
                Section {
                    NavigationLink {
                        SiteLoginView()
                    } label: {
                        Label("Site Logins", systemImage: "person.badge.key")
                    }
                } footer: {
                    Text("Log in to paywalled sites so clips capture the full article instead of the preview.")
                }

                // MARK: - Enable the Extension
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        step(number: 1, text: "In Safari, tap the Share button")
                        step(number: 2, text: "Scroll the row of app icons to the end and tap More")
                        step(number: 3, text: "Tap Edit, then turn on \"Clip to Obsidian\"")
                        step(number: 4, text: "Tap the + next to it to add it to Favorites so it appears first in the Share sheet")
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Turn On the Share Extension")
                } footer: {
                    Text("You only need to do this once.")
                }

                // MARK: - How to Use
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        step(number: 1, text: "Open any webpage in Safari (or any app with Share)")
                        step(number: 2, text: "Tap the Share button")
                        step(number: 3, text: "Select \"Clip to Obsidian\"")
                        step(number: 4, text: "The article is converted to Markdown and saved to your vault")
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("How to Use")
                }

                #if DEBUG
                // MARK: - Diagnostics (developer builds only)
                Section {
                    adaptiveRow {
                        Label("Last Extension Launch", systemImage: "clock.arrow.circlepath")
                    } content: {
                        Text(lastExtensionLaunch)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    adaptiveRow {
                        Label("Total Launches", systemImage: "number")
                    } content: {
                        Text("\(extensionLaunchCount)")
                            .foregroundStyle(.secondary)
                            .font(.caption.monospacedDigit())
                    }
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Recent Clips", systemImage: "list.bullet.rectangle")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Updated whenever the share extension reaches user code. \"Never\" means the extension has not been launched since the app was installed — useful for confirming Safari can actually start the extension.")
                }
                #endif

                // MARK: - About
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Obsidian Clipper")
            // The large title truncates at accessibility text sizes.
            .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
            .sheet(isPresented: $showFolderPicker) {
                FolderPickerView { url in
                    do {
                        try settings.saveVaultBookmark(for: url)
                    } catch let error as VaultBookmarkError {
                        vaultError = error
                    } catch {
                        vaultError = .bookmarkFailed(underlying: error)
                    }
                    refreshResolvedPath()
                }
            }
            .alert(
                vaultError?.errorDescription ?? "Couldn't use that folder.",
                isPresented: Binding(
                    get: { vaultError != nil },
                    set: { if !$0 { vaultError = nil } }
                )
            ) {
                Button("Choose Again") {
                    vaultError = nil
                    showFolderPicker = true
                }
                Button("Cancel", role: .cancel) { vaultError = nil }
            } message: {
                Text(vaultError?.recoverySuggestion ?? "")
            }
            .onAppear(perform: refreshAll)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshAll() }
            }
        }
    }

    // MARK: - Rows

    private var vaultLocationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            adaptiveRow {
                Text("Vault Location")
                    .foregroundStyle(.secondary)
            } content: {
                HStack(spacing: 6) {
                    Image(systemName: vaultIsAccessible ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(vaultIsAccessible ? .green : .red)
                        .imageScale(.small)
                        .accessibilityLabel(vaultStatusLabel)
                    Text(resolvedPath)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        .truncationMode(.middle)
                }
            }
            if settings.vaultBookmark != nil && !vaultIsAccessible {
                Text("Folder unavailable — tap Select Vault Folder to choose it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var vaultStatusLabel: String {
        if vaultIsAccessible { return "Vault folder accessible" }
        return settings.vaultBookmark == nil ? "Vault folder not set" : "Vault folder unavailable"
    }

    /// A label/value row that sits side by side at normal text sizes and
    /// stacks vertically at accessibility sizes so neither side truncates.
    @ViewBuilder
    private func adaptiveRow<L: View, C: View>(
        @ViewBuilder label: () -> L,
        @ViewBuilder content: () -> C
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                label()
                content()
            }
        } else {
            LabeledContent {
                content()
            } label: {
                label()
            }
        }
    }

    @ViewBuilder
    private func step(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(minWidth: stepBadgeSize, minHeight: stepBadgeSize)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number), \(text)")
    }

    // MARK: - Refresh

    private func refreshAll() {
        refreshResolvedPath()
        #if DEBUG
        refreshDiagnostics()
        #endif
    }

    #if DEBUG
    private func refreshDiagnostics() {
        let defaults = ClipperSettings.sharedDefaults()
        extensionLaunchCount = defaults.integer(forKey: "extension_launch_count")
        if let raw = defaults.string(forKey: "last_extension_launch"),
           let date = ISO8601DateFormatter().date(from: raw) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lastExtensionLaunch = formatter.string(from: date)
        } else {
            lastExtensionLaunch = "Never"
        }
    }
    #endif

    private func refreshResolvedPath() {
        guard let resolved = settings.resolveVaultURL() else {
            resolvedPath = settings.vaultBookmark == nil ? "Not set" : "Unavailable"
            vaultIsAccessible = false
            return
        }
        let url = resolved.url
        // Check if the vault folder is actually accessible
        let accessible = url.startAccessingSecurityScopedResource()
        let exists = FileManager.default.fileExists(atPath: url.path)
        if accessible {
            url.stopAccessingSecurityScopedResource()
        }
        vaultIsAccessible = accessible && exists && !resolved.isStale
        resolvedPath = url.lastPathComponent
    }
}

#Preview {
    SettingsView()
        .environmentObject(ClipperSettings())
}
