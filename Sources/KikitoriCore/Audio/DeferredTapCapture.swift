import CoreAudio
import Foundation

/// A process tap that starts once its processes exist (checked every second), for audio that
/// begins later (the built-in player's WebKit process appears when the page first plays sound).
public final class DeferredTapCapture: AudioCapture, @unchecked Sendable {
    public let samples: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation
    private var tap: ProcessTapCapture?
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
                        self?.tap = tap
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
        tap?.stop()
        continuation.finish()
    }
}
