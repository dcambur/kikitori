import AVFoundation
import Foundation

/// The audio of recent chunks, so a line can be heard again. Memory only: nothing is written to
/// disk, the oldest clips go once `limit` bytes are used (about 30 minutes of speech), and all of
/// it goes when the session stops.
struct LineClips {
    var limit = 60 << 20
    private var clips: [Double: [Int16]] = [:]   // chunk start (session seconds) → 16 kHz mono
    private var order: [Double] = []
    private var bytes = 0

    mutating func store(_ samples: [Float], at time: Double) {
        guard clips[time] == nil, !samples.isEmpty else { return }
        clips[time] = samples.map { Int16(max(-1, min(1, $0)) * 32_767) }
        order.append(time)
        bytes += samples.count * 2
        while bytes > limit, let oldest = order.first {
            order.removeFirst()
            bytes -= (clips.removeValue(forKey: oldest)?.count ?? 0) * 2
        }
    }

    func clip(at time: Double) -> [Int16]? { clips[time] }
    mutating func removeAll() { clips = [:]; order = []; bytes = 0 }
}

/// Plays one clip at a time, optionally slower or on a loop.
@MainActor
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinish: () -> Void = {}

    /// False when it can't play (no output device, say): nothing is playing then.
    func play(_ samples: [Int16], rate: Float, loop: Bool) -> Bool {
        stop()
        guard let player = try? AVAudioPlayer(data: Self.wav(samples)) else { return false }
        player.enableRate = rate != 1
        player.rate = rate
        player.numberOfLoops = loop ? -1 : 0
        player.delegate = self
        guard player.play() else { return false }
        self.player = player
        return true
    }

    func stop() {
        player?.stop()
        player = nil
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        MainActor.assumeIsolated {
            guard let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.player = nil
            onFinish()
        }
    }

    /// 16 kHz mono 16-bit PCM in a WAV container.
    static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let pcm = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + pcm)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(16_000)); put(UInt32(32_000)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(pcm)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }   // little-endian on Apple silicon and Intel
        return data
    }
}
