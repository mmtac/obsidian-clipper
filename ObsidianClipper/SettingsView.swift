import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var settings: ClipperSettings
    @State private var showFolderPicker = false
    @State private var resolvedPath: String = "Not set"
    @State private var vaultIsAccessible = false
    @State private var lastExtensionLaunch: String = "Never"
    @State private var extensionLaunchCount: Int = 0

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
                                .font(.system(size: 40))
                                .foregroundStyle(.orange)
                            Text("Get Started")
                                .font(.headline)
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
                    HStack {
                        Label("Vault Name", systemImage: "book.closed")
                        Spacer()
                        TextField("e.g. omniscient", text: $settings.vaultName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    HStack {
                        Label("Target Folder", systemImage: "folder")
                        Spacer()
                        TextField("e.g. Inbox", text: $settings.targetFolder)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Select Vault Folder", systemImage: "folder.badge.plus")
                    }

                    HStack {
                        Text("Vault Location")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: vaultIsAccessible ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(vaultIsAccessible ? .green : .red)
                            .imageScale(.small)
                        Text(resolvedPath)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
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

                // MARK: - Diagnostics
                Section {
                    HStack {
                        Label("Last Extension Launch", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text(lastExtensionLaunch)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Label("Total Launches", systemImage: "number")
                        Spacer()
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
            .sheet(isPresented: $showFolderPicker) {
                FolderPickerView { url in
                    settings.saveVaultBookmark(for: url)
                    refreshResolvedPath()
                }
            }
            .onAppear {
                refreshResolvedPath()
                refreshDiagnostics()
            }
        }
    }

    private func refreshDiagnostics() {
        let defaults = UserDefaults(suiteName: ClipperSettings.suiteName) ?? .standard
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

    private func refreshResolvedPath() {
        guard let resolved = settings.resolveVaultURL() else {
            resolvedPath = "Not set"
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

    @ViewBuilder
    private func step(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(ClipperSettings())
}
