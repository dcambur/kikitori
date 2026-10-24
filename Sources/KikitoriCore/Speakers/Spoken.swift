import Foundation

/// A recognized chunk on its way to translation: its text and, with speakers tracked, its
/// characters (in the pipeline's clock) and who said each.
struct Spoken: Sendable {
    var ja: String
    var chars: [TimedChar] = []
    var speakers: [Int?] = []

    var turns: [SpeakerTurn] { SpeakerLabeler.turns(chars, speakers: speakers) }

    /// The chunk split into speaker turns, as untranslated lines (none without speakers).
    func turnLines(at time: Double) -> [TranscriptLine] {
        guard !speakers.isEmpty else { return [] }
        return turns.map { turn in
            var line = TranscriptLine(time: time, ja: chars[turn.from..<turn.to].map(\.text).joined())
            line.speaker = turn.speaker.map(SpeakerLabeler.label)
            return line
        }
    }

    /// What the translator reads: one speaker turn per line, so it splits its lines there too.
    var translatorInput: String {
        guard !speakers.isEmpty else { return ja }
        return turns.map { chars[$0.from..<$0.to].map(\.text).joined() }.joined(separator: "\n")
    }

    /// The translator's lines placed on the characters, each with whoever said most of it.
    /// Without translated lines, one line per speaker turn (one line without speakers).
    func cueLines(_ translated: [LiveTranslator.Line]) -> [Cue.Line] {
        guard !speakers.isEmpty, !chars.isEmpty else { return CueAligner.lines(translated, over: chars) }
        if translated.isEmpty {
            return turns.map { turn in
                Cue.Line(from: turn.from, to: turn.to, ja: chars[turn.from..<turn.to].map(\.text).joined(),
                         speaker: turn.speaker.map(SpeakerLabeler.label))
            }
        }
        return CueAligner.lines(translated, over: chars).map { line in
            var line = line
            line.speaker = SpeakerLabeler.speaker(of: chars, from: line.from, to: line.to, speakers: speakers).map(SpeakerLabeler.label)
            return line
        }
    }
}
