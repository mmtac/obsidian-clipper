import SwiftUI

/// External links shown in the About screen. Kept in one place so release
/// URLs can be swapped without hunting through view code.
enum AppLinks {
    static let privacyPolicy = URL(string: "https://mmtac.com/privacy")
    static let support = URL(string: "https://mmtac.com/support")
    static let sourceCode = URL(string: "https://github.com/mmtac/obsidian-clipper")
}

struct AboutView: View {
    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "scissors")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Markdown Clipper")
                        .font(.title2.bold())
                    Text(versionString)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }

            Section("About") {
                Text("Clip any webpage to your Obsidian vault as a clean Markdown note. Images are extracted, OCR is performed using Apple Vision, and everything is saved to your chosen vault folder.")
                    .font(.subheadline)
            }

            Section("Credits") {
                LabeledContent("HTML → Markdown") {
                    Text("SwiftSoup (MIT) + native Swift")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("OCR") {
                    Text("Apple Vision")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("File Access") {
                    Text("Security-Scoped Bookmarks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                linkRow(AppLinks.privacyPolicy, title: "Privacy Policy", systemImage: "hand.raised")
                linkRow(AppLinks.support, title: "Support", systemImage: "questionmark.circle")
                linkRow(AppLinks.sourceCode, title: "Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
            }

            Section("Acknowledgements") {
                DisclosureGroup("SwiftSoup") {
                    Text(Self.swiftSoupLicense)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                Text("Markdown Clipper for Obsidian is an independent app and is not affiliated with or endorsed by Obsidian or Dynalist Inc.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func linkRow(_ url: URL?, title: String, systemImage: String) -> some View {
        if let url {
            Link(destination: url) {
                Label(title, systemImage: systemImage)
            }
            .accessibilityHint("Opens in your browser")
        }
    }

    private static let swiftSoupLicense = """
        The MIT License

        Copyright (c) 2009-2025 Jonathan Hedley <https://jsoup.org/>
        Copyright (c) 2016-2025 Nabil Chatbi (Swift port)

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
