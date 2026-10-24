import CoreAudio
import Foundation
import Synchronization

/// A process tap that starts once its processes exist (checked every second), for audio that
/// begins later (the built-in player's WebKit process appears when the page first plays sound).
public final class DeferredTapCapture: AudioCapture, @unchecked Sendable {
    public let samples: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation
    /// The tap once started, and whether `stop` came (from another thread than the one starting it).
    private let state = Mutex<(tap: ProcessTapCapture?, stopped: Bool)>((nil, false))
    private var task: Task<Void, Never>?

    public init() {
        (samples, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(400))
    }

    public func start(find: @escaping @Sendable () -> [AudioObjectID], onStart: @escaping @Sendable (Int) -> Void) {
        let continuation = continuation
        task = Task { [weak self] in
            while !Task.isCancelled {
                let objects = find()
                if !objects.isEmpty {
                    let tap = ProcessTapCapture()
                    if (try? tap.start(processObjects: objects)) != nil {
                        // Stopped while it was starting: stop it here, not in a deinit that could
                        // run on the audio thread.
                        let kept = self?.state.withLock { s -> Bool in
                            if !s.stopped { s.tap = tap }
                            return !s.stopped
                        } ?? false
                        guard kept else { tap.stop(); return }
                        onStart(objects.count)
                        for await s in tap.samples { continuation.yield(s) }
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        task?.cancel()
        state.withLock { s in s.stopped = true; return s.tap }?.stop()
        continuation.finish()
    }
}
