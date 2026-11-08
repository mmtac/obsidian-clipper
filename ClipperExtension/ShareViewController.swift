import UIKit
import SwiftUI

// MARK: - View Model

/// Observable view model for the share extension UI.
/// SwiftUI automatically tracks property changes via the Observation framework (iOS 17+).
@Observable
@MainActor
final class ShareViewModel {

    enum ClipState: Equatable {
        case loading(String)
        case success(String)
        case error(String)
    }

    var state: ClipState = .loading("Extracting content…")
}

// MARK: - ShareViewController

/// The Share Extension entry point. Receives content from Safari (or any app)
/// via the Share Sheet, orchestrates the clipping pipeline, and presents a
/// SwiftUI progress/result UI.
final class ShareViewController: UIViewController {

    private let viewModel = ShareViewModel()
    /// Guards against double-completion of the extension context.
    /// Accessed from both the main-actor Task and UI callbacks, so
    /// we protect it with an NSLock for thread safety.
    private var didComplete = false
    private let didCompleteLock = NSLock()
    /// Handle to the clipping Task so we can cancel it when the user taps Cancel.
    private var clippingTask: Task<Void, Never>?
    /// Held so the cancel path can tear down the scratch directory used for
    /// streamed image temp files. Retained until success cleanup or cancel.
    private var imageProcessor: ImageProcessor?
    /// Token for the `didReceiveMemoryWarningNotification` observer. Retained
    /// so `deinit` can remove it explicitly. Block-based observers are not
    /// auto-removed, unlike selector-based ones.
    private var memoryWarningObserver: NSObjectProtocol?

    override func viewDidLoad() {
        // First statement on purpose: if the appex hangs in dynamic-load,
        // this line is never reached and the App Group `last_extension_launch`
        // stays stale — that absence is the diagnostic signal.
        LaunchBeacon.emit()
        super.viewDidLoad()
        setupUI()
        registerMemoryWarningObserver()
        startClipping()
    }

    deinit {
        if let token = memoryWarningObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Memory Warnings

    /// Listen for system memory pressure. If image processing is in flight,
    /// throttle the processor's concurrency cap down to 1 so no new tasks are
    /// seeded. If the processor is nil (e.g. success state, idle) this is a
    /// no-op — which satisfies the "no crash during idle" requirement.
    private func registerMemoryWarningObserver() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard let processor = self.imageProcessor else { return }
            // Hop onto the actor; the notification fires on main.
            Task { await processor.reduceConcurrency() }
        }
    }

    // MARK: - UI

    private func setupUI() {
        let extensionView = ShareExtensionView(
            viewModel: viewModel,
            onDone: { [weak self] in self?.done() },
            onCancel: { [weak self] in self?.cancel() }
        )

        let host = UIHostingController(rootView: extensionView)

        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    // MARK: - Clipping Pipeline

    private func startClipping() {
        // Block swipe-to-dismiss while clipping: an interactive dismissal
        // would tear down the sheet without completing or cancelling the
        // extension request. Re-enabled once we reach success/error.
        isModalInPresentation = true
        clippingTask = Task { [weak self] in
            do {
                guard let self else { return }
                let result = try await self.performClipping()

                guard !Task.isCancelled else { return }
                self.isModalInPresentation = false
                self.viewModel.state = .success(result)

                // Auto-dismiss after a short delay
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self.done()
            } catch {
                guard let self else { return }
                // Error path never reaches the success cleanup in
                // performClipping; drop the scratch temp files here.
                if let processor = self.imageProcessor {
                    self.imageProcessor = nil
                    await processor.cleanup()
                }
                guard !Task.isCancelled else { return }
                self.isModalInPresentation = false
                self.viewModel.state = .error(error.localizedDescription)
            }
        }
    }

    private func performClipping() async throws -> String {
        let title = try await ClippingPipeline.run(
            extensionContext: extensionContext,
            onState: { [weak self] state in
                self?.viewModel.state = .loading(state)
            },
            onImageProcessor: { [weak self] processor in
                self?.imageProcessor = processor
            }
        )
        // Clean up scratch temp files once the vault move is complete.
        await imageProcessor?.cleanup()
        imageProcessor = nil
        return title
    }

    // MARK: - Completion

    private func done() {
        guard trySetComplete() else { return }
        isModalInPresentation = false
        if let processor = imageProcessor {
            imageProcessor = nil
            Task { await processor.cleanup() }
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        guard trySetComplete() else { return }
        clippingTask?.cancel()
        clippingTask = nil
        // Fire-and-forget scratch directory cleanup; fine for the extension to
        // tear down while this runs since the actor method is short and the
        // temp files live under NSTemporaryDirectory() either way.
        if let processor = imageProcessor {
            imageProcessor = nil
            Task { await processor.cleanup() }
        }
        extensionContext?.cancelRequest(withError: ClipError.cancelled)
    }

    /// Atomically checks and sets `didComplete`. Returns `true` if this call
    /// was the first to set it (i.e., the caller should proceed with completion).
    private func trySetComplete() -> Bool {
        didCompleteLock.lock()
        defer { didCompleteLock.unlock() }
        guard !didComplete else { return false }
        didComplete = true
        return true
    }

}

// `ClipError` lives in `ClippingPipeline.swift` so the pipeline's error type
// is co-located with its raiser, and the test target (which compiles the
// pipeline source directly without `ShareViewController.swift`) can resolve
// it during build.
