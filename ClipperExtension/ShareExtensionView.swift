import SwiftUI

/// The SwiftUI view displayed in the Share Extension sheet.
/// Shows a progress indicator while clipping, then success or error state.
/// Observes a `ShareViewModel` for reactive state updates (iOS 17+ Observation).
struct ShareExtensionView: View {

    let viewModel: ShareViewModel
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                switch viewModel.state {
                case .loading(let message):
                    ProgressView()
                        .scaleEffect(1.5)
                    Text(message)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                case .success(let title):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                    Text("Saved to Obsidian")
                        .font(.headline)
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                case .error(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.orange)
                    Text("Clipping Failed")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                switch viewModel.state {
                case .loading:
                    EmptyView()
                case .success, .error:
                    Button("Done") {
                        onDone()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding()
            .navigationTitle("MD Clipper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
    }
}
