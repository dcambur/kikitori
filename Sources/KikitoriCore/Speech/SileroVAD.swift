import FluidAudio
import Foundation

/// Silero VAD v6 on Core ML (FluidAudio), streaming: 256 ms frames, recurrent state carried
/// from frame to frame. `load()` downloads the small model (~2 MB) on first use.
///
/// After a stretch without speech the state starts afresh: on a stream with loud game music
/// and sound effects under the voice, the carried state settled on "no speech" within seconds
/// and stayed there while the streamer kept talking (probabilities ~0.003 for minutes, while
/// the same audio from a fresh state, or the recognizer on plain windows, found speech
/// throughout). Speech keeps its state as before; only silence or noise is cut into 2 s pieces.
public struct SileroVAD: VoiceActivityDetector {
    public let frameSize = VadManager.chunkSize
    /// Frames below 0.5 in a row (~2 s) after which the state starts afresh.
    static let freshAfter = 8
    let manager: VadManager
    var state: VadStreamState
    var quiet = 0

    public static func load() async throws -> SileroVAD {
        let manager = try await VadManager()
        return SileroVAD(manager: manager, state: await manager.makeStreamState())
    }

    public mutating func reset() async { state = await manager.makeStreamState(); quiet = 0 }

    public mutating func probability(_ frame: ArraySlice<Float>) async -> Float {
        guard let result = try? await manager.processStreamingChunk(Array(frame), state: state) else { return 0 }
        state = result.state
        quiet = result.probability < 0.5 ? quiet + 1 : 0
        if quiet >= Self.freshAfter { await reset() }
        return result.probability
    }
}
