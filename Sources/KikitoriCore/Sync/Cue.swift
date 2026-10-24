import Foundation

/// One chunk of a video's speech, ready before it is spoken: its characters with their times in
/// the video (seconds of `currentTime`), and the translator's lines over them. Final once made:
/// the player reveals the characters as the video reaches them and never changes them.
public struct Cue: Sendable, Equatable, Codable, Identifiable {
    public struct Line: Sendable, Equatable, Codable {
        /// Pieces `from..<to` of the cue's characters.
        public var from: Int
        public var to: Int
        /// The translator's (possibly corrected) Japanese, else the recognized text.
        public var ja: String
        public var en: String?
        public var note: String?
        public var term: String?
        /// Who said it ("A", "B", …), when speakers are tracked.
        public var speaker: String?

        public init(from: Int, to: Int, ja: String, en: String? = nil, note: String? = nil, term: String? = nil,
                    speaker: String? = nil) {
            self.from = from; self.to = to; self.ja = ja; self.en = en; self.note = note; self.term = term
            self.speaker = speaker
        }
    }

    public var id = UUID()
    public var videoID: String
    public var chars: [TimedChar]
    public var lines: [Line]

    public init(videoID: String, chars: [TimedChar], lines: [Line]) {
        self.videoID = videoID; self.chars = chars; self.lines = lines
    }

    public var start: Double { chars.first?.start ?? 0 }
    public var end: Double { chars.last?.end ?? 0 }
}

/// Places the translator's lines on the recognized characters. The translator splits a chunk
/// into lines and may correct their Japanese, so its line boundaries are mapped onto the
/// recognized text through a character alignment (edit distance); lines without Japanese split
/// the characters in proportion to their English.
public enum CueAligner {
    public static func lines(_ translated: [LiveTranslator.Line], over chars: [TimedChar]) -> [Cue.Line] {
        let heard = chars.text
        guard !translated.isEmpty, !chars.isEmpty else {
            return chars.isEmpty ? [] : [Cue.Line(from: 0, to: chars.count, ja: heard)]
        }
        // Every line needs a character to begin on (that is when it is shown and transcribed);
        // more lines than characters: one line.
        if translated.count > chars.count {
            let note = translated.map(\.note).filter { !$0.isEmpty }.joined(separator: " ")
            let term = translated.map(\.term).filter { !$0.isEmpty }.joined(separator: ", ")
            return [Cue.Line(from: 0, to: chars.count, ja: translated.map(\.ja).joined().isEmpty ? heard : translated.map(\.ja).joined(),
                             en: translated.map(\.en).joined(separator: " "), note: note.isEmpty ? nil : note, term: term.isEmpty ? nil : term)]
        }
        // Character offset where each piece starts, and the end.
        var offsets: [Int] = [], total = 0
        for c in chars { offsets.append(total); total += c.text.count }
        let ends: [Int]   // character offset in `heard` where each line ends
        if translated.allSatisfy({ !$0.ja.isEmpty }) {
            let map = alignment(Array(translated.map(\.ja).joined()), Array(heard))
            var cumulative = 0
            ends = translated.map { cumulative += $0.ja.count; return map[cumulative] }
        } else {
            let weights = translated.map { Double(max(1, $0.en.count)) }, sum = weights.reduce(0, +)
            var acc = 0.0
            ends = weights.map { acc += $0; return Int((Double(total) * acc / sum).rounded()) }
        }
        // Character offsets to piece boundaries (nearest), increasing, the last at the end.
        func piece(atChar offset: Int) -> Int {
            let i = offsets.firstIndex { $0 >= offset } ?? chars.count
            guard i > 0, i < chars.count else { return i }
            return offset - offsets[i - 1] < offsets[i] - offset ? i - 1 : i
        }
        var out: [Cue.Line] = [], from = 0
        for (k, line) in translated.enumerated() {
            let after = translated.count - 1 - k   // lines still to place, one character each at least
            let to = k == translated.count - 1 ? chars.count : min(chars.count - after, max(from + 1, piece(atChar: ends[k])))
            let ja = line.ja.isEmpty ? chars[from..<to].map(\.text).joined() : line.ja
            out.append(Cue.Line(from: from, to: to, ja: ja, en: line.en, note: line.note.isEmpty ? nil : line.note,
                                term: line.term.isEmpty ? nil : line.term))
            from = to
        }
        return out
    }

    /// For each prefix length of `a` (0...a.count), how much of `b` it lines up with in a minimal
    /// edit alignment.
    static func alignment(_ a: [Character], _ b: [Character]) -> [Int] {
        let n = a.count, m = b.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n { for j in 1...m {
                d[i][j] = min(d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1), d[i - 1][j] + 1, d[i][j - 1] + 1)
            } }
        }
        // Walk back from the end, noting for each i the largest j on the path.
        var map = [Int](repeating: 0, count: n + 1)
        var i = n, j = m
        map[n] = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) { i -= 1; j -= 1 }
            else if i > 0, d[i][j] == d[i - 1][j] + 1 { i -= 1 }
            else { j -= 1 }
            map[i] = max(map[i], j)
        }
        for k in stride(from: n - 1, through: 0, by: -1) { map[k] = min(map[k], map[k + 1]) }
        return map
    }
}
