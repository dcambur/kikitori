import FluidAudio
import Foundation

/// Silero VAD v6 on Core ML (FluidAudio), streaming: 256 ms frames, recurrent state carried
/// from frame to frame. `load()` downloads the small model (~2 MB) on first use.
public struct SileroVAD: VoiceActivityDetector {
    public let frameSize = VadManager.chunkSize
    let manager: VadManager
    var state: VadStreamState

    public static func load() async throws -> SileroVAD {
        let manager = try await VadManager()
        return SileroVAD(manager: manager, state: await manager.makeStreamState())
    }

    public mutating func probability(_ frame: ArraySlice<Float>) async -> Float {
        guard let result = try? await manager.processStreamingChunk(Array(frame), state: state) else { return 0 }
        state = result.state
        return result.probability
    }
}
