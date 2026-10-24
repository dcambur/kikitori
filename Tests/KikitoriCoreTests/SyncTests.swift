import Foundation
import Synchronization
import Testing
@testable import KikitoriCore

@Suite struct TimedTextTests {
    func pieces(_ text: String, step: Double = 0.1) -> [TimedChar] {
        text.enumerated().map { TimedChar(text: String($1), start: Double($0) * step, end: Double($0 + 1) * step) }
    }

    @Test func cleaningKeepsTheTimesOfTheCharactersThatStay() {
        let cleaned = TranscriptFilter.clean(pieces(" はははははははね"))
        #expect(cleaned.text == "ははははね")
        #expect(zip(cleaned.map(\.start), [0.1, 0.2, 0.3, 0.4, 0.8]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(TranscriptFilter.clean(pieces("ご視聴ありがとうございました")).isEmpty)
    }

    @Test func aLongFirstCharacterStartsWhereItsSoundDoes() {
        // 0.6 s of silence, then a tone: the recognizer gave あ the pause as well.
        let audio = signal([(false, 0.6), (true, 1.0), (false, 0.4)])
        let refined = OnsetRefiner.refine([TimedChar(text: "、", start: 0, end: 0.1), TimedChar(text: "あ", start: 0.1, end: 0.9),
                                           TimedChar(text: "い", start: 0.9, end: 1.02)], samples: audio)
        #expect(abs(refined[1].start - 0.6) <= 0.02)
        #expect(refined[0] == TimedChar(text: "、", start: 0, end: 0.1))   // short pieces stay
        #expect(refined[2].start == 0.9)
    }
}

@Suite struct CueAlignerTests {
    let chars = "今日はいい天気ですね".enumerated().map { TimedChar(text: String($1), start: Double($0), end: Double($0) + 1) }

    @Test func linesFollowTheTranslatorsSplit() {
        let lines = CueAligner.lines([.init(ja: "今日はいい天気", en: "Nice weather today"), .init(ja: "ですね", en: "isn't it")], over: chars)
        #expect(lines.map { [$0.from, $0.to] } == [[0, 7], [7, 10]])
        #expect(lines[1].en == "isn't it")
    }

    @Test func correctedJapaneseStillFindsItsCharacters() {
        let lines = CueAligner.lines([.init(ja: "今日は良い天気", en: "a"), .init(ja: "ですね。", en: "b")], over: chars)
        #expect(lines.map { [$0.from, $0.to] } == [[0, 7], [7, 10]])
        #expect(lines[0].ja == "今日は良い天気")   // the transcript keeps the translator's Japanese
    }

    @Test func withoutJapaneseTheEnglishLengthSplitsIt() {
        let lines = CueAligner.lines([.init(en: "aaaa"), .init(en: "a")], over: chars)
        #expect(lines.map { [$0.from, $0.to] } == [[0, 8], [8, 10]])
        #expect(lines[1].ja == "すね")
    }

    @Test func everyLineGetsACharacterToBeginOn() {
        // The translator added a line whose Japanese lines up with nothing heard.
        let lines = CueAligner.lines([.init(ja: "今日はいい天気ですね", en: "a"), .init(ja: "うん", en: "yeah")], over: chars)
        #expect(lines.map { [$0.from, $0.to] } == [[0, 9], [9, 10]])
        let few = Array(chars.prefix(1))
        let merged = CueAligner.lines([.init(ja: "今", en: "now"), .init(ja: "日", en: "day")], over: few)
        #expect(merged.count == 1 && merged[0].en == "now day")
    }

    @Test func noTranslationIsOneJapaneseLine() {
        let lines = CueAligner.lines([], over: chars)
        #expect(lines == [Cue.Line(from: 0, to: 10, ja: "今日はいい天気ですね")])
    }
}

@Suite struct MediaTimelineTests {
    func ones(_ seconds: Double) -> [Float] { [Float](repeating: 1, count: Int(seconds * 16_000)) }

    @Test func piecesThatFollowOnJoinAndRepeatsAreIgnored() {
        var t = MediaTimeline()
        t.add(start: 10, samples: ones(1))
        t.add(start: 11.005, samples: ones(1))   // a 5 ms step joins (padded)
        t.add(start: 10.5, samples: ones(1))     // already there
        #expect(t.ranges.count == 1)
        #expect(abs(t.ranges[0].end - 12.005) < 1e-6)
        t.add(start: 20, samples: ones(1))       // a gap
        t.add(start: 15, samples: ones(6))       // fills between, overlapping the later one
        #expect(t.ranges.count == 2)
        #expect(abs(t.ranges[1].start - 15) < 1e-6 && abs(t.ranges[1].end - 21) < 1e-6)
        t.trim(before: 11)
        #expect(abs(t.ranges[0].start - 11) < 1e-6)
        #expect(abs(t.seconds - 7.005) < 1e-3)
    }

    @Test func resamplingKeepsASoundAtItsTime() {
        // A click 1.000 s after the packet's start at 48 kHz, sent in 10 ms packets.
        var source = [Float](repeating: 0, count: 96_000)
        source[48_000] = 1
        let r = MediaResampler()
        var out: [(Double, [Float])] = []
        for i in stride(from: 0, to: source.count, by: 480) {
            if let o = r.convert(MediaPacket(videoID: "v", stream: 0, time: 5 + Double(i) / 48_000, rate: 48_000,
                                             samples: Array(source[i..<i + 480]))) { out.append(o) }
        }
        var timeline = MediaTimeline()
        for (start, samples) in out { timeline.add(start: start, samples: samples) }
        #expect(timeline.ranges.count == 1)
        let s = timeline.ranges[0].samples
        let peak = s.indices.max { abs(s[$0]) < abs(s[$1]) }!
        let time = timeline.ranges[0].start + Double(peak) / 16_000
        #expect(abs(time - 6.0) < 0.001)
    }
}

/// Returns one character at the first sound of the chunk and one at its last, so a cue's times
/// say where the pipeline thought the speech was.
struct EdgeEngine: TimedSpeechEngine {
    let name = "edges"
    func prepare() async throws {}
    func transcribe(_ samples: [Float], context: [String]) async throws -> String { "あい" }
    func transcribeTimed(_ samples: [Float], context: [String]) async throws -> [TimedChar] {
        guard let first = samples.firstIndex(where: { abs($0) > 0.01 }), let last = samples.lastIndex(where: { abs($0) > 0.01 })
        else { return [] }
        let a = Double(first) / 16_000, b = Double(last) / 16_000
        return [TimedChar(text: "あ", start: a, end: a + 0.1), TimedChar(text: "い", start: b - 0.1, end: b)]
    }
}

@Suite struct MediaPipelineTests {
    /// Speech bursts of 1.5 s at the given video times, over `seconds` from `start`, sent as
    /// 48 kHz packets of 0.5 s.
    func packets(start: Double, seconds: Double, bursts: [Double]) -> [MediaPipeline<EnergyVAD>.Input] {
        let rate = 48_000.0
        let samples = (0..<Int(seconds * rate)).map { i -> Float in
            let t = start + Double(i) / rate
            return bursts.contains { t >= $0 && t < $0 + 1.5 } ? 0.2 * sin(Float(i) * 0.02) : 0
        }
        return stride(from: 0, to: samples.count, by: 24_000).map {
            .packet(MediaPacket(videoID: "v", stream: 1, time: start + Double($0) / rate, rate: rate,
                                samples: Array(samples[$0..<min($0 + 24_000, samples.count)])))
        }
    }

    /// Feeds `inputs`, then collects cue start times for `wait`.
    func cues(_ pipeline: MediaPipeline<EnergyVAD>, _ steps: [[MediaPipeline<EnergyVAD>.Input]],
              wait: Duration = .milliseconds(600)) async -> [[Double]] {
        let (inputs, feed) = AsyncStream.makeStream(of: MediaPipeline<EnergyVAD>.Input.self)
        let events = pipeline.run(inputs)
        let seen = Mutex<[Double]>([])
        let reader = Task { for await e in events { if case let .cue(cue, _) = e { seen.withLock { $0.append(cue.start) } } } }
        var out: [[Double]] = []
        for step in steps {
            for input in step { feed.yield(input) }
            try? await Task.sleep(for: wait)
            out.append(seen.withLock { v in defer { v = [] }; return v.sorted() })
        }
        feed.finish()
        await reader.value
        return out
    }

    @Test func cuesCarryVideoTimesAndOnlyReachTheHorizon() async {
        var pipeline = MediaPipeline(engine: EdgeEngine(), translator: nil, vad: EnergyVAD())
        pipeline.horizon = 20
        let audio = packets(start: 100, seconds: 60, bursts: [102, 110, 116, 126, 134])
        let r = await cues(pipeline, [audio + [.playhead(videoID: "v", time: 100, process: true)],
                                      [.playhead(videoID: "v", time: 110, process: true)]])
        // Within 20 s of the playhead at 100 (a chunk closes 0.5 s after its speech): 102, 110 and 116.
        // A burst whose closing pause lies beyond the horizon waits for the next step.
        #expect(r[0].count == 3, "\(r)")
        for (got, want) in zip(r[0], [102.0, 110, 116]) { #expect(abs(got - want) < 0.02) }
        // The playhead at 110 reaches 130: the burst at 126 (134 is beyond).
        #expect(r[1].count == 1 && abs(r[1][0] - 126) < 0.02)
    }

    @Test func aSeekSkipsAheadAndSeekingBackDoesOnlyWhatIsMissing() async {
        var pipeline = MediaPipeline(engine: EdgeEngine(), translator: nil, vad: EnergyVAD())
        pipeline.horizon = 10
        let audio = packets(start: 0, seconds: 80, bursts: [2, 20, 32, 45, 52, 56])
        let r = await cues(pipeline, [audio + [.playhead(videoID: "v", time: 0, process: true)],
                                      [.playhead(videoID: "v", time: 50, process: true)],    // seek: 20–50 never done
                                      [.playhead(videoID: "v", time: 30, process: true)]])   // back: 30–40 only
        #expect(r[0].count == 1 && abs(r[0][0] - 2) < 0.02, "\(r)")
        #expect(r[1].count == 2 && abs(r[1][0] - 52) < 0.02 && abs(r[1][1] - 56) < 0.02)
        #expect(r[2].count == 1 && abs(r[2][0] - 32) < 0.02)
    }

    /// Audio starting a little after the playhead (or a gap in it) is worked on once, not again
    /// on every input, and a gap doesn't hold up what comes after it.
    @Test func holesInTheAudioAreSkippedNotRepeatedOrWaitedIn() async {
        var pipeline = MediaPipeline(engine: EdgeEngine(), translator: nil, vad: EnergyVAD())
        pipeline.horizon = 30
        let first = packets(start: 100.2, seconds: 9.8, bursts: [102, 106])         // 100.2–110
        let second = packets(start: 110.5, seconds: 20, bursts: [114, 120])         // after a 0.5 s gap
        let r = await cues(pipeline, [first + second + [.playhead(videoID: "v", time: 100, process: true)],
                                      [.playhead(videoID: "v", time: 100.5, process: true)],
                                      [.playhead(videoID: "v", time: 101, process: true)]])
        #expect(r[0].count == 4, "\(r)")
        for (got, want) in zip(r[0], [102.0, 106, 114, 120]) { #expect(abs(got - want) < 0.02) }
        #expect(r[1].isEmpty && r[2].isEmpty, "\(r)")
    }

    /// A slow API delays only the English: the cue (its Japanese) goes out once recognized.
    @Test func theJapaneseDoesNotWaitForTheTranslation() async {
        struct SlowTransport: HTTPTransport {
            let inner: StubTransport
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                try await Task.sleep(for: .milliseconds(1500))
                return try await inner.send(request)
            }
        }
        let answer = #"{"lines":[{"ja":"あい","en":"Hi","note":"","term":""}]}"#
        let client = ClaudeClient(apiKey: "k", transport: SlowTransport(inner: StubTransport([(200, messageJSON(text: answer), [:])])))
        let pipeline = MediaPipeline(engine: EdgeEngine(), translator: LiveTranslator(client: client, profile: nil), vad: EnergyVAD())
        let (inputs, feed) = AsyncStream.makeStream(of: MediaPipeline<EnergyVAD>.Input.self)
        let events = pipeline.run(inputs)
        for input in packets(start: 0, seconds: 8, bursts: [2]) + [.playhead(videoID: "v", time: 0, process: true)] { feed.yield(input) }
        let began = Date()
        var cueAt: Double?, translatedAt: Double?, english: String?
        for await e in events {
            switch e {
            case .cue: cueAt = Date().timeIntervalSince(began)
            case let .translation(_, lines, _, _): translatedAt = Date().timeIntervalSince(began); english = lines.first?.en; feed.finish()
            default: break
            }
        }
        #expect(cueAt.map { $0 < 1.0 } == true, "cue after \(cueAt ?? -1) s")
        #expect(translatedAt.map { $0 >= 1.5 } == true)
        #expect(english == "Hi")
    }

    @Test func nothingIsWorkedOnWhileNotSynced() async {
        let pipeline = MediaPipeline(engine: EdgeEngine(), translator: nil, vad: EnergyVAD())
        let audio = packets(start: 0, seconds: 10, bursts: [2])
        let r = await cues(pipeline, [audio + [.playhead(videoID: "v", time: 0, process: false)],
                                      [.playhead(videoID: "v", time: 0, process: true)]])
        #expect(r[0].isEmpty)
        #expect(r[1].count == 1)
    }

    @Test func anotherVideosAudioNeverBecomesCues() async {
        let pipeline = MediaPipeline(engine: EdgeEngine(), translator: nil, vad: EnergyVAD())
        let audio = packets(start: 0, seconds: 10, bursts: [2])
        let r = await cues(pipeline, [audio + [.playhead(videoID: "other", time: 0, process: true)]])
        #expect(r[0].isEmpty)
    }
}

/// The cutting stage driven directly, with 16 kHz packets (no resampler).
@Suite struct CutterTests {
    /// 0.5 s packets; speech bursts of 1.5 s at `bursts`.
    func packets(start: Double, seconds: Double, bursts: [Double]) -> [MediaPipeline<EnergyVAD>.Input] {
        let samples = (0..<Int(seconds * 16_000)).map { i -> Float in
            let t = start + Double(i) / 16_000
            return bursts.contains { t >= $0 && t < $0 + 1.5 } ? 0.2 * sin(Float(i) * 0.06) : 0
        }
        return stride(from: 0, to: samples.count, by: 8_000).map {
            .packet(MediaPacket(videoID: "v", stream: 1, time: start + Double($0) / 16_000, rate: 16_000,
                                samples: Array(samples[$0..<min($0 + 8_000, samples.count)])))
        }
    }

    final class Seen: @unchecked Sendable { var chunks: [(start: Double, end: Double)] = [] }
    func cutter() -> (Cutter<EnergyVAD>, Seen) {
        let seen = Seen()
        let c = Cutter(vad: EnergyVAD(), maxChunk: 6, horizon: 30, keep: 300, playhead: Playhead()) { seen.chunks.append(($0.start, $0.end)) }
        return (c, seen)
    }

    /// A playhead off the 16 kHz grid (any real `currentTime`) used to leave the run a fraction of
    /// a sample short of the gap, stuck: the audio after it waited for the playhead to get there.
    @Test(arguments: [100.00001, 100.00004])
    func aGapIsCrossedWhateverThePlayheadsSubSampleOffset(_ playhead: Double) async {
        let (c, seen) = cutter()
        for input in packets(start: 99, seconds: 11, bursts: [102, 106]) + packets(start: 110.5, seconds: 20, bursts: [114, 120]) {
            await c.take(input)
        }
        await c.take(.playhead(videoID: "v", time: playhead, process: true))
        #expect(seen.chunks.count == 4, "chunks at \(seen.chunks.map(\.start))")
    }

    /// The end of the audio buffered so far is not a gap because some audio lies far beyond the
    /// horizon (left from before a seek back): speech running over it stays one chunk.
    @Test(arguments: [false, true])
    func speechOverTheBufferedEdgeIsOneChunk(_ audioFarAhead: Bool) async {
        let (c, seen) = cutter()
        let speech = packets(start: 0, seconds: 40, bursts: [18.5, 20])   // 18.5–21.5 s
        if audioFarAhead { for p in packets(start: 100, seconds: 10, bursts: []) { await c.take(p) } }
        for p in speech.prefix(40) { await c.take(p) }                    // 0–20 s now
        await c.take(.playhead(videoID: "v", time: 0, process: true))
        for p in speech.dropFirst(40) { await c.take(p) }                 // the rest as it comes
        await c.take(.playhead(videoID: "v", time: 0.5, process: true))
        #expect(seen.chunks.count == 1, "chunks \(seen.chunks)")
    }
}

extension MediaPipelineTests {
    struct SlowEdgeEngine: TimedSpeechEngine {
        let name = "slow edges"
        func prepare() async throws {}
        func transcribe(_ samples: [Float], context: [String]) async throws -> String { "あい" }
        func transcribeTimed(_ samples: [Float], context: [String]) async throws -> [TimedChar] {
            try await Task.sleep(for: .milliseconds(300))
            return try await EdgeEngine().transcribeTimed(samples, context: context)
        }
    }

    /// Chunks dropped before recognition (a seek forward while they were queued) are not done:
    /// seeking back there still gives them cues.
    @Test func chunksDroppedByASeekAreRedoneOnSeekingBack() async {
        var pipeline = MediaPipeline(engine: SlowEdgeEngine(), translator: nil, vad: EnergyVAD())
        pipeline.horizon = 30
        let (inputs, feed) = AsyncStream.makeStream(of: MediaPipeline<EnergyVAD>.Input.self)
        let events = pipeline.run(inputs)
        let seen = Mutex<[Double]>([])
        let reader = Task { for await e in events { if case let .cue(cue, _) = e { seen.withLock { $0.append(cue.start) } } } }
        let bursts: [Double] = [2, 6, 10, 14, 18, 22, 26]
        for p in packets(start: 0, seconds: 120, bursts: bursts + [80, 84]) { feed.yield(p) }
        feed.yield(.playhead(videoID: "v", time: 0, process: true))
        try? await Task.sleep(for: .milliseconds(450))                    // ~1 chunk recognized
        feed.yield(.playhead(videoID: "v", time: 75, process: true))      // seek forward
        try? await Task.sleep(for: .milliseconds(2500))
        for k in 0...8 { feed.yield(.playhead(videoID: "v", time: 1 + Double(k) * 0.5, process: true)); try? await Task.sleep(for: .milliseconds(500)) }
        try? await Task.sleep(for: .milliseconds(2500))
        feed.finish()
        await reader.value
        let starts = seen.withLock { $0 }
        let missing = bursts.filter { b in !starts.contains { abs($0 - b) < 0.05 } }
        #expect(missing.isEmpty, "no cue for the speech at \(missing)")
    }

    /// A 20 ms hole every second (a lost frame) is under the join tolerance: what follows still
    /// goes at its own time instead of shifting earlier with every hole.
    @Test func smallHolesDoNotShiftLaterAudio() {
        let resampler = MediaResampler()
        var timeline = MediaTimeline()
        var t = 10.0
        for k in 0..<200 {   // 0.1 s packets at 48 kHz, a click in the last one
            var samples = [Float](repeating: 0, count: 4_800)
            if k == 199 { samples[2_400] = 1 }
            if k % 10 == 9 { t += 0.02 }
            if let o = resampler.convert(MediaPacket(videoID: "v", stream: 0, time: t, rate: 48_000, samples: samples)) {
                timeline.add(start: o.start, samples: o.samples)
            }
            if k < 199 { t += 0.1 }
        }
        let range = timeline.ranges.last!, s = range.samples
        let peak = s.indices.max { abs(s[$0]) < abs(s[$1]) }!
        #expect(abs(range.start + Double(peak) / 16_000 - (t + 0.05)) < 0.005)
    }
}
