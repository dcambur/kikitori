import Foundation

/// Decides, frame by frame, whether there is speech. Frames are `frameSize` samples at 16 kHz.
public protocol VoiceActivityDetector: Sendable {
    var frameSize: Int { get }
    /// Probability of speech in this frame, 0…1. Called in order; may keep state.
    mutating func probability(_ frame: ArraySlice<Float>) async -> Float
}

/// Loudness-based stand-in used in tests and as a fallback when no model is available.
public struct EnergyVAD: VoiceActivityDetector {
    public let frameSize = 512
    public var threshold: Float
    public init(threshold: Float = 0.01) { self.threshold = threshold }
    public mutating func probability(_ frame: ArraySlice<Float>) async -> Float {
        let rms = (frame.reduce(0) { $0 + $1 * $1 } / Float(max(frame.count, 1))).squareRoot()
        return min(rms / threshold, 1) * 0.99
    }
}

/// Cuts a continuous 16 kHz stream into speech chunks for the speech engine.
///
/// A chunk ends at the first pause of `minSilence` after at least `minChunk` of audio, or is
/// forced at `maxChunk`, cut at the quietest frame of its last 3 s so words are not split.
/// Chunks with less than `minSpeech` of detected speech are dropped: nothing is sent to the
/// engine, which is what keeps Whisper-style models from inventing text over silence and music.
public struct Chunker<VAD: VoiceActivityDetector>: Sendable {
    public struct Chunk: Sendable, Equatable {
        /// Seconds since the stream started.
        public var start: Double
        public var samples: [Float]
        public var speechSeconds: Double
        public var duration: Double { Double(samples.count) / Chunker.rate }
    }

    static var rate: Double { 16_000 }

    public var vad: VAD
    public var threshold: Float = 0.5
    public var minSilence = 0.5
    public var minChunk = 2.0
    public var maxChunk = 15.0
    public var minSpeech = 0.3
    public var padding = 0.2

    var pending: [Float] = []            // samples not yet split into frames
    var buffer: [Float] = []             // current chunk candidate
    var probs: [Float] = []              // per frame of `buffer`
    var bufferStart = 0                  // absolute sample index of buffer[0]
    var consumed = 0                     // absolute samples consumed into frames

    public init(vad: VAD) { self.vad = vad }

    /// Feed samples; returns any chunks that completed.
    public mutating func append(_ samples: [Float]) async -> [Chunk] {
        pending += samples
        var out: [Chunk] = []
        let n = vad.frameSize
        while pending.count >= n {
            let frame = pending[0..<n]
            probs.append(await vad.probability(frame))
            if buffer.isEmpty { bufferStart = consumed }
            buffer += frame
            pending.removeFirst(n)
            consumed += n
            if let chunk = cutIfReady() { out.append(chunk) }
        }
        return out
    }

    /// Flush whatever is buffered (end of stream).
    public mutating func finish() -> [Chunk] {
        defer { buffer = []; probs = []; pending = [] }
        return makeChunk(frames: probs.count).map { [$0] } ?? []
    }

    mutating func cutIfReady() -> Chunk? {
        let frameSec = Double(vad.frameSize) / Self.rate
        let length = Double(probs.count) * frameSec
        // Leading silence: keep only `padding` of it so chunks start near speech.
        // Durations round up to whole frames: Silero's frames are 0.256 s, so rounding down would
        // turn the 0.2 s padding into none and a 0.5 s pause into a single frame.
        func frames(_ seconds: Double) -> Int { Int((seconds / frameSec - 1e-9).rounded(.up)) }
        if !probs.contains(where: { $0 >= threshold }) {
            let keep = frames(padding)
            if probs.count > keep { dropFront(probs.count - keep) }
            return nil
        }
        let silenceFrames = frames(minSilence)
        if length >= minChunk, probs.count > silenceFrames,
           probs.suffix(silenceFrames).allSatisfy({ $0 < threshold }) {
            return makeChunk(frames: probs.count - silenceFrames + frames(padding))
        }
        if length >= maxChunk {
            let window = Int(3.0 / frameSec)
            // Quietest frame of the last 3 s; on ties the latest, so chunks stay near maxChunk.
            let tail = probs.indices.suffix(window).reversed()
            let cut = tail.min { probs[$0] < probs[$1] }.map { $0 + 1 } ?? probs.count
            return makeChunk(frames: cut)
        }
        return nil
    }

    /// Emit the first `frames` frames as a chunk (if it has enough speech) and keep the rest.
    mutating func makeChunk(frames: Int) -> Chunk? {
        let frames = min(frames, probs.count)
        guard frames > 0 else { return nil }
        let n = vad.frameSize
        let speech = Double(probs[0..<frames].filter { $0 >= threshold }.count * n) / Self.rate
        let chunk = Chunk(start: Double(bufferStart) / Self.rate, samples: Array(buffer[0..<frames * n]),
                          speechSeconds: speech)
        dropFront(frames)
        return speech >= minSpeech ? chunk : nil
    }

    mutating func dropFront(_ frames: Int) {
        buffer.removeFirst(min(frames * vad.frameSize, buffer.count))
        probs.removeFirst(min(frames, probs.count))
        bufferStart += frames * vad.frameSize
    }
}
