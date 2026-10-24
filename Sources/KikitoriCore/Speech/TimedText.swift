import Foundation

/// A piece of recognized text with the audio it was heard in (seconds). Apple's recognizer gives
/// one character per piece for Japanese; a number such as " 50" comes as one piece.
public struct TimedChar: Sendable, Equatable, Codable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

extension Array where Element == TimedChar {
    public var text: String { map(\.text).joined() }

    /// The same pieces `seconds` later.
    public func shifted(by seconds: Double) -> [TimedChar] {
        map { TimedChar(text: $0.text, start: $0.start + seconds, end: $0.end + seconds) }
    }
}

/// A speech engine that also says when each character was spoken (relative to the chunk).
public protocol TimedSpeechEngine: SpeechEngine {
    /// The same text `transcribe` returns, in pieces with their times.
    func transcribeTimed(_ samples: [Float], context: [String]) async throws -> [TimedChar]
}

extension TranscriptFilter {
    /// `clean` for timed text: the pieces that survive it, with their times. The cleaned text is
    /// what's left after trimming, dropping an invented phrase and collapsing repeats, so it is a
    /// subsequence of the original; each piece keeps the characters matched to it.
    public static func clean(_ pieces: [TimedChar]) -> [TimedChar] {
        let cleaned = Array(clean(pieces.text))
        guard !cleaned.isEmpty else { return [] }
        var out: [TimedChar] = []
        var next = 0
        for piece in pieces {
            var kept = ""
            for c in piece.text where next < cleaned.count && c == cleaned[next] {
                kept.append(c)
                next += 1
            }
            if !kept.isEmpty { out.append(TimedChar(text: kept, start: piece.start, end: piece.end)) }
        }
        return next == cleaned.count ? out : []   // not a subsequence: never expected; show nothing rather than wrong times
    }
}

/// Moves a character's start to where its sound begins. The recognizer often gives the pause
/// before a word to its first character (、[1.08–1.32] あ[1.32–2.10] with あ spoken at ~1.9 s),
/// which would show it early. A piece longer than `minLength` starts at its first `run` frames
/// of sound instead: 10 ms frames louder than the chunk's 15th percentile + `margin` dB. Measured
/// on stream audio, this cut the median onset error after pauses from 100 ms to 10 ms
/// (docs/design/realtime-sync.md §5.7).
public enum OnsetRefiner {
    public static let minLength = 0.24
    static let margin = 12.0
    static let run = 3

    /// `pieces` relative to `samples` (16 kHz, the chunk they were recognized from).
    public static func refine(_ pieces: [TimedChar], samples: [Float], rate: Double = 16_000) -> [TimedChar] {
        let frames = energy(samples, rate: rate)
        guard frames.count > 20 else { return pieces }
        let sorted = frames.sorted()
        let threshold = sorted[Int(Double(sorted.count - 1) * 0.15)] + margin
        let loud = frames.map { $0 > threshold }
        func frame(_ t: Double) -> Int { max(0, min(frames.count - 1, Int(t * 100))) }
        return pieces.map { piece in
            guard piece.end - piece.start > minLength else { return piece }
            let first = frame(piece.start), last = frame(piece.end - 0.06)
            guard last - first > run - 1 else { return piece }
            for f in first..<(last - run + 1) where (f..<f + run).allSatisfy({ loud[$0] }) {
                var moved = piece
                moved.start = max(piece.start, Double(f) / 100)
                return moved
            }
            return piece
        }
    }

    /// dB RMS of 20 ms windows every 10 ms.
    static func energy(_ s: [Float], rate: Double) -> [Double] {
        let hop = Int(rate / 100), window = hop * 2
        guard s.count >= window else { return [] }
        return stride(from: 0, through: s.count - window, by: hop).map { i in
            var sum: Float = 0
            for j in i..<i + window { sum += s[j] * s[j] }
            return 10 * log10(Double(sum / Float(window)) + 1e-10)
        }
    }
}
