import SwiftUI

/// Debug list of the last few clips recorded by the share extension —
/// which capture path fed the pipeline, which extraction route ran, and how
/// the clip ended. The data answers "why was this note empty?" without
/// needing a connected debugger.
struct DiagnosticsView: View {

    @State private var records: [ClipRecord] = []

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView(
                    "No Clips Recorded",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Clip something with the share extension and its diagnostic record will appear here.")
                )
            } else {
                ForEach(records.reversed()) { record in
                    row(for: record)
                }
            }
        }
        .navigationTitle("Recent Clips")
        .onAppear { records = ClipDiagnostics.recent() }
    }

    @ViewBuilder
    private func row(for record: ClipRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.host ?? "(no URL)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                outcomeBadge(record.outcome)
            }
            Text("\(record.source.rawValue) → \(record.route)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("html \(record.htmlChars.map(String.init) ?? "–") · md \(record.markdownChars) chars · \(record.elapsedMs) ms")
                Spacer()
                Text(record.date, format: .dateTime.month().day().hour().minute())
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func outcomeBadge(_ outcome: String) -> some View {
        Text(outcome)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(outcome == "saved" ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
            )
            .foregroundStyle(outcome == "saved" ? .green : .red)
    }
}

#Preview {
    NavigationStack {
        DiagnosticsView()
    }
}
