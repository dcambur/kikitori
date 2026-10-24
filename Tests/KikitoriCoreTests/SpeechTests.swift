import Foundation
import Synchronization
import Testing
@testable import KikitoriCore

/// Tone bursts stand in for speech, zeros for silence.
func signal(_ parts: [(speech: Bool, seconds: Double)]) -> [Float] {
    parts.flatMap { part in
        (0..<Int(part.seconds * 16_000)).map { i in part.speech ? 0.2 * sin(Float(i) * 0.05) : 0 }
    }
}

@Suite struct ChunkerTests {
    @Test func cutsAtPausesAndDropsSilence() async {
        var c = Chunker(vad: EnergyVAD())
        let chunks = await c.append(signal([(false, 3), (true, 3), (false, 1), (true, 2.5), (false, 4)])) + c.finish()
        #expect(chunks.count == 2)
        #expect(abs(chunks[0].start - 2.8) < 0.1)          // 0.2 s of padding before speech
        #expect(abs(chunks[0].speechSeconds - 3) < 0.1)
        #expect(chunks.allSatisfy { $0.duration < 4.5 })
    }

    @Test func forcesACutAtMaxLengthInsideLongSpeech() async {
        var c = Chunker(vad: EnergyVAD())
        let chunks = await c.append(signal([(true, 40)])) + c.finish()
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.duration <= 15.01 })
        #expect(abs(chunks.map(\.duration).reduce(0, +) - 40) < 0.05)   // nothing lost or doubled
    }

    @Test func pureSilenceNeverReachesTheEngine() async {
        var c = Chunker(vad: EnergyVAD())
        let none = await c.append(signal([(false, 60)])) + c.finish()
        #expect(none.isEmpty)
    }

    @Test func clicksShorterThanMinSpeechAreDropped() async {
        var c = Chunker(vad: EnergyVAD())
        let chunks = await c.append(signal([(false, 2), (true, 0.1), (false, 3)])) + c.finish()
        #expect(chunks.isEmpty)
    }

    @Test func feedingInSmallPiecesGivesTheSameChunks() async {
        let audio = signal([(false, 1), (true, 4), (false, 1), (true, 3), (false, 2)])
        var whole = Chunker(vad: EnergyVAD())
        let a = await whole.append(audio) + whole.finish()
        var pieces = Chunker(vad: EnergyVAD())
        var b: [Chunker<EnergyVAD>.Chunk] = []
        for i in stride(from: 0, to: audio.count, by: 441) { b += await pieces.append(Array(audio[i..<min(i + 441, audio.count)])) }
        b += pieces.finish()
        #expect(a == b)
    }

    @Test func paddingAndPausesSurviveSilerosLongFrames() async {
        var c = Chunker(vad: WideEnergyVAD())
        // Speech starts on a frame boundary (12 frames in) and has a 0.3 s dip, shorter than minSilence.
        let chunks = await c.append(signal([(false, 3.072), (true, 3.072), (false, 0.3), (true, 1), (false, 3)])) + c.finish()
        #expect(chunks.count == 1)
        #expect(chunks.first.map { $0.start < 3.0 } == true)   // padding before speech is kept
    }
}

/// EnergyVAD with Silero's frame size: 4096 samples, 0.256 s.
struct WideEnergyVAD: VoiceActivityDetector {
    let frameSize = 4096
    var inner = EnergyVAD()
    mutating func probability(_ frame: ArraySlice<Float>) async -> Float { await inner.probability(frame) }
}

@Suite struct TranscriptFilterTests {
    @Test func dropsInventedOutroPhrases() {
        #expect(TranscriptFilter.clean("ご視聴ありがとうございました。") == "")
        #expect(TranscriptFilter.clean(" 次回予告 ") == "")
        #expect(TranscriptFilter.clean("今日もご視聴ありがとうございました、また明日") == "今日もご視聴ありがとうございました、また明日")
    }

    @Test func collapsesRepetitionLoops() {
        #expect(TranscriptFilter.clean(String(repeating: "い", count: 400)) == "いいいい")
        #expect(TranscriptFilter.clean("はい" + String(repeating: "はい", count: 30) + "了解") == "はいはいはいはい了解")
        #expect(TranscriptFilter.clean("ダメだー!ダメだー!ダメだー!ダメだー!") == "ダメだー!ダメだー!ダメだー!ダメだー!")
    }
}

/// Returns fixed Japanese for every chunk.
struct FakeEngine: SpeechEngine {
    let name = "fake"
    func prepare() async throws {}
    func transcribe(_ samples: [Float], context: [String]) async throws -> String { "こんにちは" }
}

@Suite struct LivePipelineTests {
    @Test func everyHeardChunkIsSettledWhenThereIsNoTranslator() async {
        let pipeline = LivePipeline(engine: FakeEngine(), translator: nil, vad: EnergyVAD())
        let audio = AsyncStream<[Float]> { c in
            c.yield(signal([(false, 1), (true, 2), (false, 1), (true, 2), (false, 2)]))
            c.finish()
        }
        var heard: [Double] = [], skipped: [Double] = []
        for await event in pipeline.run(audio) {
            switch event {
            case let .heard(time, _, _, _, _, _): heard.append(time)
            case let .translationSkipped(time): skipped.append(time)
            default: break
            }
        }
        #expect(heard.count == 2)
        #expect(skipped == heard)   // nothing is left waiting for English that will never come
    }

    @Test func slowRecognitionLosesNoAudio() async {
        // Capture streams keep only the newest buffers (4 here), so audio intake must never wait on recognition.
        let audio = signal([(false, 1), (true, 2), (false, 1), (true, 2), (false, 1), (true, 2), (false, 2)])
        let (stream, feed) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(4))
        let pipeline = LivePipeline(engine: SlowEngine(delay: .milliseconds(400)), translator: nil, vad: EnergyVAD())
        let events = pipeline.run(stream)
        let producer = Task {
            for i in stride(from: 0, to: audio.count, by: 1600) {   // 0.1 s pieces, faster than real time
                feed.yield(Array(audio[i..<min(i + 1600, audio.count)]))
                try? await Task.sleep(for: .milliseconds(1))
            }
            feed.finish()
        }
        var heard: [Double] = []
        for await event in events { if case let .heard(time, _, _, _, _, _) = event { heard.append(time) } }
        await producer.value
        #expect(heard.count == 3)
        // Speech starts at 1, 4 and 7 s; each chunk begins about 0.2 s of padding earlier.
        for (time, speech) in zip(heard, [1.0, 4.0, 7.0]) { #expect(abs(time - (speech - 0.2)) < 0.1) }
    }
}

extension LivePipelineTests {
    /// Pause and Stop cancel the pipeline: chunks still queued for recognition are dropped, not
    /// recognized one after another while the next run competes for the same CPU and models.
    @Test func aStoppedPipelineDoesNotWorkThroughItsBacklog() async throws {
        let engine = CountingEngine()
        var pipeline = LivePipeline(engine: engine, translator: nil, vad: EnergyVAD())
        pipeline.maxChunk = 2
        let (audio, feed) = AsyncStream.makeStream(of: [Float].self)
        for _ in 0..<20 { feed.yield(signal([(true, 2), (false, 0.6)])) }   // recognition lags far behind
        let consumer = Task { for await _ in pipeline.run(audio) {} }
        try await Task.sleep(for: .milliseconds(150))
        consumer.cancel()
        let atStop = engine.calls.withLock { $0 }
        try await Task.sleep(for: .seconds(1.5))
        #expect(engine.calls.withLock { $0 } - atStop <= 1)   // at most the one running when it stopped
        feed.finish()
    }
}

/// A model run that takes 50 ms of CPU and, like Apple's recognizer, ignores cancellation.
final class CountingEngine: SpeechEngine, Sendable {
    let name = "counting"
    let calls = Mutex(0)
    func prepare() async throws {}
    func transcribe(_ samples: [Float], context: [String]) async throws -> String {
        calls.withLock { $0 += 1 }
        usleep(50_000)
        return "こんにちは"
    }
}

/// Takes `delay` per chunk, like a cold model or a busy CPU.
struct SlowEngine: SpeechEngine {
    let name = "slow"
    var delay: Duration
    func prepare() async throws {}
    func transcribe(_ samples: [Float], context: [String]) async throws -> String {
        try await Task.sleep(for: delay)
        return "こんにちは"
    }
}

@Suite struct PageAudioCaptureTests {
    @Test func decodesLittleEndianInt16Packets() async {
        let capture = PageAudioCapture()
        let pcm: [Int16] = [0, 16_384, -16_384, 32_767, -32_768]
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        #expect(capture.push(base64: data.base64EncodedString(), videoTime: 12.5))
        #expect(!capture.push(base64: "not base64!", videoTime: nil))
        capture.stop()
        var all: [Float] = []
        for await s in capture.samples { all += s }
        #expect(all == [0, 0.5, -0.5, Float(32_767) / 32_768, -1])
        #expect(capture.progress.videoTime == 12.5)
    }
}

@Suite struct LiveLineTests {
    @Test func keepsOnlyWordsAfterTheLastChunk() {
        var p = PreviewText()
        #expect(p.update(.init(start: 0, end: 1, text: "こん", isFinal: false)) == "こん")
        #expect(p.update(.init(start: 0, end: 1.5, text: "こんにちは", isFinal: true)) == "こんにちは")
        #expect(p.update(.init(start: 2, end: 2.5, text: "今日", isFinal: false)) == "こんにちは今日")
        #expect(p.cut(at: 1.8) == "今日")                   // the first words became a proper line
        #expect(p.update(.init(start: 2, end: 3, text: "今日は", isFinal: true)) == "今日は")
        // Words the chunker never turned into a line (music, noise) age out.
        #expect(p.update(.init(start: 20, end: 21, text: "ラララ", isFinal: true)) == "ラララ")
    }

    @Test func dropsTheWordsOfAResultThatAChunkAlreadyCovers() {
        // One streaming result often spans several chunks: only its words after the cut stay.
        var p = PreviewText()
        let words = [PreviewResult.Word(text: "毎回", start: 0, end: 1), .init(text: "かさたな", start: 1, end: 2.5),
                     .init(text: "やってるのよ", start: 2.5, end: 4)]
        #expect(p.update(.init(start: 0, end: 4, text: "毎回かさたなやってるのよ", isFinal: true, words: words))
                == "毎回かさたなやってるのよ")
        #expect(p.cut(at: 2.6) == "やってるのよ")
        #expect(p.cut(at: 4) == "")
    }

    @Test func dropsStrayMarksAtTheStartOnly() {
        var p = PreviewText()
        let words = [PreviewResult.Word(text: "見た。", start: 0, end: 1), .init(text: "やばい！？", start: 1, end: 2)]
        _ = p.update(.init(start: 0, end: 2, text: "見た。やばい！？", isFinal: true, words: words))
        #expect(p.cut(at: 0.9) == "やばい！？")   // the 。 left from the line before goes; ！？ stay
    }

    @Test func cutsInsideALongPieceInProportion() {
        var p = PreviewText()
        // Still-changing results come in long pieces: a cut halfway keeps about the second half.
        #expect(p.update(.init(start: 0, end: 4, text: "あいうえおかきくけこ", isFinal: false)) == "あいうえおかきくけこ")
        #expect(p.cut(at: 2) == "かきくけこ")
    }

    struct EchoPreview: LivePreviewEngine {
        func stream(_ audio: AsyncStream<[Float]>, context: [String]) -> AsyncThrowingStream<PreviewResult, Error> {
            AsyncThrowingStream { c in
                Task {
                    var t = 0.0
                    for await s in audio {
                        let d = Double(s.count) / 16_000
                        c.yield(.init(start: t, end: t + d, text: "あ", isFinal: true))
                        t += d
                    }
                    c.finish()
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func pipelineShowsTheLiveLineAndClearsItAtTheEnd() async {
        var pipeline = LivePipeline(engine: FakeEngine(), translator: nil, vad: EnergyVAD())
        pipeline.preview = EchoPreview()
        let (audio, feed) = AsyncStream.makeStream(of: [Float].self)
        func speak(seconds: Int) {   // loud "speech", 0.1 s at a time
            for _ in 0..<seconds * 10 { feed.yield([Float](repeating: 0.3, count: 1_600)) }
        }
        // The second half comes only once the live line shows, as audio does live. Given all 6 s
        // at once, the chunk can be recognized before the preview's first word arrives, and then
        // that word (rightly) never shows: it is already part of a proper line.
        speak(seconds: 3)
        var lines: [String] = [], heardAudio = 0
        for await event in pipeline.run(audio) {
            if case let .hearing(text) = event {
                if !text.isEmpty, lines.allSatisfy(\.isEmpty) { speak(seconds: 3); feed.finish() }
                lines.append(text)
            }
            if case let .heard(_, _, _, _, samples, _) = event { heardAudio += samples.count }
        }
        #expect(lines.contains { !$0.isEmpty })
        #expect(lines.last == "")
        #expect(heardAudio > 0)   // the chunk's audio comes with it, for replay
    }
}
