import Foundation

/// Who was speaking, frame by frame: each speaker's probability (0–1) over a short frame of
/// audio, in the caller's time (seconds). Frames may have gaps (audio that wasn't diarized).
public struct SpeakerFrames: Sendable, Equatable {
    public struct Frame: Sendable, Equatable {
        public var start: Double
        /// One probability per speaker slot.
        public var probs: [Float]
        public init(start: Double, probs: [Float]) { self.start = start; self.probs = probs }
    }

    public var frames: [Frame]
    public var length: Double

    public init(frames: [Frame], length: Double = 0.08) { self.frames = frames; self.length = length }
}

/// A stretch of a chunk's characters said by one speaker: pieces `from..<to`.
public struct SpeakerTurn: Sendable, Equatable {
    public var from: Int
    public var to: Int
    public var speaker: Int?
    public init(from: Int, to: Int, speaker: Int?) { self.from = from; self.to = to; self.speaker = speaker }
}

/// Puts speakers on recognized text: the diarizer says who spoke when (80 ms frames), the
/// recognizer when each character was said, so each character gets the speaker most active
/// while it was spoken. Turns are runs of one speaker, with blips too short to be a turn
/// (a misread frame, a cough) folded into their neighbours.
public enum SpeakerLabeler {
    /// A frame is speech when some speaker is at least this likely.
    public static let speech: Float = 0.5
    /// Turns shorter than this (seconds, first character's start to last one's end) join a neighbour.
    public static let minTurn = 0.5

    /// The speaker slot of each piece (times in the same clock as `frames`), or nil when no
    /// frame says anyone was speaking anywhere in the chunk. A piece is scored on its speech
    /// frames only: one that absorbed the pause before it isn't diluted by the silence. A piece
    /// with no speech frames (punctuation, a pause) takes the speaker before it, else after it.
    public static func speakers(for pieces: [TimedChar], in frames: SpeakerFrames) -> [Int?] {
        var out: [Int?] = pieces.map { piece in
            var sums: [Float] = [], count = 0
            for f in frames.frames where f.start < piece.end && f.start + frames.length > piece.start {
                guard f.probs.contains(where: { $0 >= speech }) else { continue }
                if sums.isEmpty { sums = [Float](repeating: 0, count: f.probs.count) }
                for (k, p) in f.probs.enumerated() where k < sums.count { sums[k] += p }
                count += 1
            }
            guard count > 0, let best = sums.indices.max(by: { sums[$0] < sums[$1] }) else { return nil }
            return best
        }
        var last: Int?
        for i in out.indices { if let s = out[i] { last = s } else { out[i] = last } }
        var next: Int?
        for i in out.indices.reversed() { if let s = out[i] { next = s } else { out[i] = next } }
        return out
    }

    /// Runs of one speaker over `pieces`, covering them all in order. A run shorter than
    /// `minTurn` joins its neighbour: the one on both sides when they agree, else the longer.
    public static func turns(_ pieces: [TimedChar], speakers: [Int?], minTurn: Double = minTurn) -> [SpeakerTurn] {
        guard !pieces.isEmpty, pieces.count == speakers.count else {
            return pieces.isEmpty ? [] : [SpeakerTurn(from: 0, to: pieces.count, speaker: nil)]
        }
        var runs: [SpeakerTurn] = []
        for (i, s) in speakers.enumerated() {
            if let last = runs.last, last.speaker == s { runs[runs.count - 1].to = i + 1 }
            else { runs.append(SpeakerTurn(from: i, to: i + 1, speaker: s)) }
        }
        func length(_ r: SpeakerTurn) -> Double { pieces[r.to - 1].end - pieces[r.from].start }
        while runs.count > 1 {
            guard let shortest = runs.indices.min(by: { length(runs[$0]) < length(runs[$1]) }),
                  length(runs[shortest]) < minTurn else { break }
            let before = shortest > 0 ? shortest - 1 : nil
            let after = shortest < runs.count - 1 ? shortest + 1 : nil
            let into: Int
            switch (before, after) {
            case let (b?, a?): into = runs[b].speaker == runs[a].speaker || length(runs[b]) >= length(runs[a]) ? b : a
            case let (b?, nil): into = b
            case let (nil, a?): into = a
            default: return runs
            }
            runs[into].from = min(runs[into].from, runs[shortest].from)
            runs[into].to = max(runs[into].to, runs[shortest].to)
            runs.remove(at: shortest)
            // Neighbours that now say the same speaker are one turn.
            var merged: [SpeakerTurn] = []
            for r in runs {
                if let last = merged.last, last.speaker == r.speaker { merged[merged.count - 1].to = r.to } else { merged.append(r) }
            }
            runs = merged
        }
        return runs
    }

    /// The speaker who said most of pieces `from..<to` (by time), or nil when none is known.
    public static func speaker(of pieces: [TimedChar], from: Int, to: Int, speakers: [Int?]) -> Int? {
        var time: [Int: Double] = [:]
        for i in max(0, from)..<min(to, pieces.count, speakers.count) {
            if let s = speakers[i] { time[s, default: 0] += max(0.001, pieces[i].end - pieces[i].start) }
        }
        return time.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    /// The label shown for a speaker slot: "A", "B", …
    public static func label(_ slot: Int) -> String {
        slot >= 0 && slot < 26 ? String(UnicodeScalar(UInt8(65 + slot))) : "\(slot + 1)"
    }
}
