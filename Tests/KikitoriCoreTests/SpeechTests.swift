import Foundation
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
            case let .heard(time, _, _, _): heard.append(time)
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
        for await event in events { if case let .heard(time, _, _, _) = event { heard.append(time) } }
        await producer.value
        #expect(heard.count == 3)
        // Speech starts at 1, 4 and 7 s; each chunk begins about 0.2 s of padding earlier.
        for (time, speech) in zip(heard, [1.0, 4.0, 7.0]) { #expect(abs(time - (speech - 0.2)) < 0.1) }
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
