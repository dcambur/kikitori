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

    @Test func syncedCuesCarryTheirSpeakersFromRecognition() async {
        // Speech at 102–103.5 s of the video; characters from chunk start + 0.2 s, 0.2 s each.
        let tracker = FakeTracker(change: 103)
        var pipeline = MediaPipeline(engine: FakeTimedEngine(), translator: nil, vad: EnergyVAD())
        pipeline.speakers = tracker
        let rate = 48_000.0
        let samples = (0..<Int(8 * rate)).map { i -> Float in
            let t = 100 + Double(i) / rate
            return t >= 102 && t < 103.5 ? 0.2 * sin(Float(i) * 0.02) : 0
        }
        let (inputs, feed) = AsyncStream.makeStream(of: MediaPipeline<EnergyVAD>.Input.self)
        let events = pipeline.run(inputs)
        for start in stride(from: 0, to: samples.count, by: 24_000) {
            feed.yield(.packet(MediaPacket(videoID: "v", stream: 1, time: 100 + Double(start) / rate, rate: rate,
                                           samples: Array(samples[start..<min(start + 24_000, samples.count)]))))
        }
        feed.yield(.playhead(videoID: "v", time: 100, process: true))
        var cue: Cue?
        for await e in events {
            if case let .cue(c, _) = e { cue = c; feed.finish() }
        }
        // The Japanese goes out split by speaker, before any translation.
        #expect(cue?.lines.map(\.speaker) == ["A", "B"])
        #expect(cue.map { $0.lines.map(\.ja).joined() == $0.chars.text } == true)
        #expect(await tracker.appended > 102)   // the tracker heard the audio the chunker read, in video time
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

/// The tracker's bookkeeping, without the model: frames are handed in with `receive`.
@Suite struct SpeakerTrackerTests {
    /// `count` frames of 80 ms where `slot` speaks.
    func rows(_ count: Int, slot: Int) -> [[Float]] {
        (0..<count).map { _ in (0..<4).map { $0 == slot ? 0.9 : 0.05 } }
    }
    func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.1)) * 0.1 } }

    @Test func framesFollowTheCallersClockAcrossASeek() async {
        let tracker = SpeakerTracker.unloaded()
        await tracker.append(tone(2), at: 10)   // diarizer seconds 0–2
        await tracker.append(tone(2), at: 50)   // a seek: diarizer seconds 2–4
        await tracker.receive(settled: rows(25, slot: 0) + rows(25, slot: 1), tentative: [], from: 0)
        let early = await tracker.frames(from: 10.5, to: 11.5)
        let late = await tracker.frames(from: 50.5, to: 51.5)
        #expect(early.frames.allSatisfy { $0.probs[0] > 0.5 } && !early.frames.isEmpty)
        #expect(late.frames.allSatisfy { $0.probs[1] > 0.5 } && !late.frames.isEmpty)
        #expect(late.frames.allSatisfy { $0.start >= 50.4 && $0.start < 51.5 })
    }

    @Test func theNewestAudioForATimeWins() async {
        // A pipeline restarts its clock at 0 after a pause: the same times come again.
        let tracker = SpeakerTracker.unloaded()
        await tracker.append(tone(2), at: 0)
        await tracker.append(tone(2), at: 0)
        await tracker.receive(settled: rows(25, slot: 0) + rows(25, slot: 1), tentative: [], from: 0)
        let f = await tracker.frames(from: 0.5, to: 1.5)
        #expect(!f.frames.isEmpty && f.frames.allSatisfy { $0.probs[1] > 0.5 })
    }

    @Test func aChunkWaitsUntilTheDiarizerHasRunOnIt() async {
        let tracker = SpeakerTracker.unloaded()
        await tracker.setMaxWait(5)
        await tracker.append(tone(2), at: 0)
        await tracker.receive(settled: rows(10, slot: 0), tentative: [], from: 0)   // up to 0.8 s
        let asked = Task { await tracker.frames(from: 0, to: 1.6) }
        try? await Task.sleep(for: .milliseconds(100))
        // Tentative frames up to 1.6 s are enough.
        await tracker.receive(settled: rows(5, slot: 0), tentative: rows(5, slot: 1), from: 10)
        let f = await asked.value
        #expect(f.frames.count == 20)
        #expect(f.frames.last.map { $0.probs[1] > 0.5 } == true)
    }

    @Test func aChunkDoesNotWaitLongerThanMaxWait() async {
        let tracker = SpeakerTracker.unloaded()
        await tracker.setMaxWait(0.2)
        await tracker.append(tone(1), at: 0)
        let start = Date()
        let f = await tracker.frames(from: 0, to: 1)
        #expect(f.frames.isEmpty)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func mutedAudioIsSkippedAndCountsAsDone() async {
        let tracker = SpeakerTracker.unloaded()
        await tracker.setMaxWait(5)
        await tracker.append(tone(1), at: 0)
        await tracker.append([Float](repeating: 0, count: 16_000), at: 1)   // muted: not run
        await tracker.append(tone(1), at: 2)
        await tracker.receive(settled: rows(13, slot: 0), tentative: [], from: 0)   // the first second
        // Ends in the muted second: ready once the audio before it is done (later audio came).
        let start = Date()
        let f = await tracker.frames(from: 0, to: 1.5)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(f.frames.count >= 12 && f.frames.allSatisfy { $0.start < 1.05 })
    }

    @Test func finishStopsTheWaiting() async {
        let tracker = SpeakerTracker.unloaded()
        await tracker.setMaxWait(30)
        await tracker.append(tone(1), at: 0)
        let asked = Task { await tracker.frames(from: 0, to: 1) }
        try? await Task.sleep(for: .milliseconds(100))
        await tracker.finish()
        _ = await asked.value   // returns instead of waiting 30 s
    }
}
