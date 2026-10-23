import Foundation

/// Audio that a web page sends us (the built-in player): base64 16 kHz mono Int16 packets,
/// each tagged with the video's playback time at the end of the packet.
public final class PageAudioCapture: AudioCapture, @unchecked Sendable {
    public let samples: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation
    private let lock = NSLock()
    private var received = 0
    private var lastVideoTime: Double?
    private var peak: Float = 0

    public init() {
        (samples, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(400))
    }

    /// Decode one packet from the page. Returns false if it is not valid base64 PCM.
    @discardableResult
    public func push(base64: String, videoTime: Double?) -> Bool {
        guard let floats = Self.decode(base64) else { return false }
        let packetPeak = floats.reduce(0) { max($0, abs($1)) }
        lock.withLock {
            received += floats.count
            peak = max(peak, packetPeak)
            if let videoTime { lastVideoTime = videoTime }
        }
        continuation.yield(floats)
        return true
    }

    /// Seconds of audio received so far, and the video time at the latest packet.
    public var progress: (seconds: Double, videoTime: Double?) {
        lock.withLock { (Double(received) / 16_000, lastVideoTime) }
    }

    /// Loudest sample since the last call (0 means the page is sending silence).
    public func takePeak() -> Float { lock.withLock { defer { peak = 0 }; return peak } }

    public func stop() { continuation.finish() }

    static func decode(_ base64: String) -> [Float]? {
        guard let data = Data(base64Encoded: base64), data.count % 2 == 0 else { return nil }
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
        }
    }
}
