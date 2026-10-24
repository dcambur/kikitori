import Foundation
import Testing
@testable import KikitoriCore

/// Characters of `text`, `step` seconds each from `start`.
func timed(_ text: String, from start: Double = 0, step: Double = 0.1) -> [TimedChar] {
    text.enumerated().map { TimedChar(text: String($1), start: start + Double($0) * step, end: start + Double($0 + 1) * step) }
}

/// 80 ms frames over `from..<to`; `who(t)` says which slot is speaking at t (nil: silence).
func frames(_ from: Double, _ to: Double, slots: Int = 4, who: (Double) -> Int?) -> SpeakerFrames {
    var out: [SpeakerFrames.Frame] = []
    var t = from
    while t < to - 1e-9 {
        var p = [Float](repeating: 0.02, count: slots)
        if let s = who(t + 0.04) { p[s] = 0.95 }
        out.append(.init(start: t, probs: p))
        t += 0.08
    }
    return SpeakerFrames(frames: out)
}

@Suite struct SpeakerLabelerTests {
    @Test func eachCharacterGetsWhoeverWasSpeakingThen() {
        let chars = timed("はいそうですね", step: 0.2)   // 0–1.4 s
        let f = frames(0, 1.4) { $0 < 0.6 ? 0 : 1 }
        #expect(SpeakerLabeler.speakers(for: chars, in: f) == [0, 0, 0, 1, 1, 1, 1])
    }

    @Test func silentPiecesTakeTheSpeakerBeforeThemElseAfter() {
        let chars = timed("、あ、い", step: 0.5)   // 、 0–0.5 silent; あ 0.5–1 A; 、 1–1.5 silent; い 1.5–2 B
        let f = frames(0, 2) { t in t < 0.5 || (t >= 1 && t < 1.5) ? nil : t < 1 ? 0 : 1 }
        #expect(SpeakerLabeler.speakers(for: chars, in: f) == [0, 0, 0, 1])
    }

    @Test func aPieceThatAbsorbedAPauseIsJudgedOnItsSpeechOnly() {
        // あ runs 0–1.2 s but is spoken (by B) only in its last 0.3 s; A spoke before it.
        let chars = [TimedChar(text: "ね", start: 0, end: 0.2), TimedChar(text: "あ", start: 0.2, end: 1.2)]
        let f = frames(0, 1.2) { t in t < 0.2 ? 0 : t < 0.9 ? nil : 1 }
        #expect(SpeakerLabeler.speakers(for: chars, in: f) == [0, 1])
    }

    @Test func noSpeechAnywhereMeansNoSpeaker() {
        let chars = timed("うん")
        #expect(SpeakerLabeler.speakers(for: chars, in: frames(0, 0.2) { _ in nil }) == [nil, nil])
        #expect(SpeakerLabeler.speakers(for: chars, in: SpeakerFrames(frames: [])) == [nil, nil])
    }

    @Test func overlappingSpeechGoesToTheLouderVoice() {
        let chars = timed("えー", step: 0.4)
        var f = frames(0, 0.8) { _ in 0 }
        for i in f.frames.indices { f.frames[i].probs[2] = 0.6 }   // C also there, less sure
        #expect(SpeakerLabeler.speakers(for: chars, in: f) == [0, 0])
    }

    @Test func turnsAreRunsOfOneSpeaker() {
        let chars = timed("そうだねわかった", step: 0.2)
        let turns = SpeakerLabeler.turns(chars, speakers: [0, 0, 0, 0, 1, 1, 1, 1])
        #expect(turns == [SpeakerTurn(from: 0, to: 4, speaker: 0), SpeakerTurn(from: 4, to: 8, speaker: 1)])
    }

    @Test func aBlipInsideATurnJoinsIt() {
        // One misread character (0.1 s) of B inside A's sentence: one turn.
        let chars = timed("今日はいい天気だね")
        let turns = SpeakerLabeler.turns(chars, speakers: [0, 0, 0, 0, 1, 0, 0, 0, 0])
        #expect(turns == [SpeakerTurn(from: 0, to: 9, speaker: 0)])
    }

    @Test func aShortTurnAtTheEndJoinsItsNeighbour() {
        let chars = timed("そうですね", step: 0.2) + timed("え", from: 1.0, step: 0.2)
        let turns = SpeakerLabeler.turns(chars, speakers: [0, 0, 0, 0, 0, 1])
        #expect(turns == [SpeakerTurn(from: 0, to: 6, speaker: 0)])
    }

    @Test func aShortTurnBetweenTwoSpeakersJoinsTheLongerOne() {
        let chars = timed("あいうえおかきくけこさしすせそた", step: 0.1)   // 1.6 s
        // A 0.6 s, C 0.3 s, B 0.7 s.
        let s: [Int?] = [0, 0, 0, 0, 0, 0, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1]
        let turns = SpeakerLabeler.turns(chars, speakers: s)
        #expect(turns == [SpeakerTurn(from: 0, to: 6, speaker: 0), SpeakerTurn(from: 6, to: 16, speaker: 1)])
    }

    @Test func turnsWithoutSpeakersAreOneTurn() {
        let chars = timed("はい")
        #expect(SpeakerLabeler.turns(chars, speakers: [nil, nil]) == [SpeakerTurn(from: 0, to: 2, speaker: nil)])
        #expect(SpeakerLabeler.turns([], speakers: []).isEmpty)
    }

    @Test func aLineBelongsToWhoeverSaidMostOfIt() {
        let chars = [TimedChar(text: "あ", start: 0, end: 0.1), TimedChar(text: "い", start: 0.1, end: 0.2),
                     TimedChar(text: "う", start: 0.2, end: 0.8)]
        #expect(SpeakerLabeler.speaker(of: chars, from: 0, to: 3, speakers: [0, 0, 1]) == 1)
        #expect(SpeakerLabeler.speaker(of: chars, from: 0, to: 2, speakers: [0, 0, 1]) == 0)
        #expect(SpeakerLabeler.speaker(of: chars, from: 0, to: 3, speakers: [nil, nil, nil]) == nil)
    }

    @Test func labelsAreLetters() {
        #expect(SpeakerLabeler.label(0) == "A")
        #expect(SpeakerLabeler.label(3) == "D")
    }
}

@Suite struct SpokenTests {
    // "そうなんだ" by A (0–1 s), "へえすごい" by B (1–2 s).
    let spoken = Spoken(ja: "そうなんだへえすごい", chars: timed("そうなんだへえすごい", step: 0.2),
                        speakers: [0, 0, 0, 0, 0, 1, 1, 1, 1, 1])

    @Test func withoutTranslationEachTurnIsALine() {
        let lines = spoken.cueLines([])
        #expect(lines.map(\.ja) == ["そうなんだ", "へえすごい"])
        #expect(lines.map(\.speaker) == ["A", "B"])
        #expect(lines.map(\.from) == [0, 5] && lines.map(\.to) == [5, 10])
        #expect(spoken.turnLines(at: 12).map(\.speaker) == ["A", "B"])
        #expect(spoken.turnLines(at: 12).allSatisfy { $0.time == 12 })
    }

    @Test func theTranslatorReadsOneTurnPerLine() {
        #expect(spoken.translatorInput == "そうなんだ\nへえすごい")
        #expect(Spoken(ja: "はい").translatorInput == "はい")
    }

    @Test func translatedLinesTakeTheSpeakerOfTheirJapanese() {
        let translated = [LiveTranslator.Line(ja: "そうなんだ", en: "Is that so"),
                          LiveTranslator.Line(ja: "へえ、すごい", en: "Wow, amazing")]
        let lines = spoken.cueLines(translated)
        #expect(lines.map(\.speaker) == ["A", "B"])
        #expect(lines.map(\.en) == ["Is that so", "Wow, amazing"])
    }

    @Test func oneTranslatedLineOverBothTurnsGoesToWhoeverSaidMore() {
        let longer = Spoken(ja: "そうなんだへえ", chars: timed("そうなんだへえ", step: 0.2), speakers: [0, 0, 0, 0, 0, 1, 1])
        #expect(longer.cueLines([LiveTranslator.Line(ja: "そうなんだへえ", en: "Oh really")]).map(\.speaker) == ["A"])
    }

    @Test func withoutSpeakersNothingIsLabelled() {
        let plain = Spoken(ja: "はい", chars: timed("はい"))
        #expect(plain.cueLines([]).map(\.speaker) == [nil])
        #expect(plain.turnLines(at: 0).isEmpty)
    }
}

/// Speaks "あいうえおかきくけこ" over each chunk, one character per 0.2 s from 0.2 s into it.
struct FakeTimedEngine: TimedSpeechEngine {
    let name = "fake timed"
    func prepare() async throws {}
    func transcribe(_ samples: [Float], context: [String]) async throws -> String { "あいうえおかきくけこ" }
    func transcribeTimed(_ samples: [Float], context: [String]) async throws -> [TimedChar] { timed("あいうえおかきくけこ", from: 0.2, step: 0.2) }
}

/// A speaks until `change` seconds into the session, B after.
actor FakeTracker: SpeakerTracking {
    let change: Double
    var appended = 0.0
    var asked: [(Double, Double)] = []
    init(change: Double) { self.change = change }
    func append(_ samples: [Float], at time: Double) async { appended = time + Double(samples.count) / 16_000 }
    func frames(from: Double, to: Double) async -> SpeakerFrames {
        asked.append((from, to))
        return KikitoriCoreTests.frames(from, to) { [change] in $0 < change ? 0 : 1 }
    }
    func finish() async {}
    func reset() async {}
}

@Suite struct SpeakerPipelineTests {
    @Test func theLivePipelineSplitsAChunkWhereTheVoiceChanges() async throws {
        // One chunk from ~0.8 s (speech at 1–3 s); characters from chunk start + 0.2 s, 0.2 s each.
        let tracker = FakeTracker(change: 2.0)
        var pipeline = LivePipeline(engine: FakeTimedEngine(), translator: nil, vad: EnergyVAD())
        pipeline.speakers = tracker
        let audio = AsyncStream<[Float]> { c in
            c.yield(signal([(false, 1), (true, 2), (false, 2)]))
            c.finish()
        }
        var turns: [[TranscriptLine]] = [], times: [Double] = []
        for await event in pipeline.run(audio) {
            if case let .heard(time, _, ja, _, _, t) = event {
                turns.append(t); times.append(time)
                #expect(t.map(\.ja).joined() == ja)
            }
        }
        try #require(turns.count == 1)
        // The voice changes at 2 s: characters before it are A's, give or take the one the 80 ms
        // frames straddle.
        let firstB = Int(((2.0 - (times[0] + 0.2)) / 0.2).rounded(.up))
        #expect(turns[0].map(\.speaker) == ["A", "B"])
        #expect(abs(turns[0][0].ja.count - firstB) <= 1)
        #expect(await tracker.appended > 4.9)   // the tracker heard all the audio
    }

    @Test func withoutTimedRecognitionThereAreNoTurns() async {
        var pipeline = LivePipeline(engine: FakeEngine(), translator: nil, vad: EnergyVAD())
        pipeline.speakers = FakeTracker(change: 1.5)
        let audio = AsyncStream<[Float]> { c in c.yield(signal([(false, 1), (true, 2), (false, 2)])); c.finish() }
        for await event in pipeline.run(audio) {
            if case let .heard(_, _, _, _, _, turns) = event { #expect(turns.isEmpty) }
        }
    }
}

@Suite struct SpeakerNameTests {
    @Test func namedLinesWriteOutNamesOrSpeakerLetters() {
        var record = SessionRecord(sourceName: "Safari", sourceID: "com.apple.Safari", profileName: nil)
        var a = TranscriptLine(time: 0, ja: "はい"); a.speaker = "A"
        var b = TranscriptLine(time: 1, ja: "うん"); b.speaker = "B"
        record.lines = [a, b, TranscriptLine(time: 2, ja: "ね")]
        record.speakerNames = ["A": "Pekora"]
        #expect(record.namedLines.map(\.speaker) == ["Pekora", "Speaker B", nil])
        #expect(record.namedLines.map(\.id) == record.lines.map(\.id))   // explanations still match
    }

    @Test func sessionsSavedBeforeSpeakerNamesStillLoad() throws {
        let record = SessionRecord(sourceName: "Safari", sourceID: "x", profileName: nil)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        json["speakerNames"] = nil
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.speakerNames == nil)
    }
}
