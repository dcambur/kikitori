import AVFoundation
import Foundation

/// Audio in, subtitle events out: chunker → speech engine → filter → translator.
///
/// Two stages run side by side: speech recognition takes chunks in order, and translation takes
/// transcripts in order, so a slow translation never delays recognition of the next chunk.
/// Without a translator (no key, offline, budget cap) it still emits the Japanese.
public struct LivePipeline<VAD: VoiceActivityDetector>: Sendable {
    public enum Event: Sendable {
        /// Japanese for the chunk that started at `time` and lasted `duration` (seconds since the
        /// session began).
        case heard(time: Double, duration: Double, ja: String, asrSeconds: Double)
        case translated(time: Double, lines: [TranscriptLine], cost: Double, seconds: Double, tokens: Int)
        case translationFailed(time: Double, ClaudeClient.Failure)
    }

    public var engine: any SpeechEngine
    public var translator: LiveTranslator?
    public var vad: VAD
    /// Names and glossary terms to bias recognition toward.
    public var contextTerms: [String]
    /// Longest chunk before a forced cut: shorter means subtitles sooner, with less context.
    public var maxChunk = 6.0
    /// Asked before each translation; false means Japanese only (budget cap, user choice).
    public var shouldTranslate: @Sendable () async -> Bool = { true }

    public init(engine: any SpeechEngine, translator: LiveTranslator?, vad: VAD, contextTerms: [String] = []) {
        self.engine = engine; self.translator = translator; self.vad = vad; self.contextTerms = contextTerms
    }

    public func run(_ audio: AsyncStream<[Float]>) -> AsyncStream<Event> {
        let (events, emit) = AsyncStream.makeStream(of: Event.self)
        let (heard, toTranslate) = AsyncStream.makeStream(of: (Double, String).self)
        let shouldTranslate = shouldTranslate
        let recognize = Task { [engine, vad, contextTerms, maxChunk] in
            var chunker = Chunker(vad: vad)
            chunker.maxChunk = maxChunk
            func handle(_ chunk: Chunker<VAD>.Chunk) async {
                let start = Date()
                let raw = (try? await engine.transcribe(chunk.samples, context: contextTerms)) ?? ""
                let ja = TranscriptFilter.clean(raw)
                guard !ja.isEmpty else { return }
                emit.yield(.heard(time: chunk.start, duration: chunk.duration, ja: ja,
                                  asrSeconds: Date().timeIntervalSince(start)))
                toTranslate.yield((chunk.start, ja))
            }
            for await samples in audio {
                for chunk in await chunker.append(samples) { await handle(chunk) }
            }
            for chunk in chunker.finish() { await handle(chunk) }
            toTranslate.finish()
        }
        let translate = Task { [translator] in
            for await (time, ja) in heard {
                guard let translator, await shouldTranslate() else { continue }
                let start = Date()
                do {
                    let r = try await translator.translate(ja)
                    let lines = r.lines.map {
                        TranscriptLine(time: time, ja: $0.ja.isEmpty ? ja : $0.ja, en: $0.en,
                                       note: $0.note.isEmpty ? nil : $0.note, term: $0.term.isEmpty ? nil : $0.term)
                    }
                    let u = r.usage
                    let tokens = u.inputTokens + u.outputTokens + (u.cacheReadInputTokens ?? 0) + (u.cacheCreationInputTokens ?? 0)
                    emit.yield(.translated(time: time, lines: lines, cost: r.cost,
                                           seconds: Date().timeIntervalSince(start), tokens: tokens))
                } catch let failure as ClaudeClient.Failure {
                    emit.yield(.translationFailed(time: time, failure))
                } catch {
                    emit.yield(.translationFailed(time: time, .unexpected(status: 0, "\(error)")))
                }
            }
        }
        Task {
            _ = await (recognize.value, translate.value)
            emit.finish()
        }
        emit.onTermination = { _ in recognize.cancel(); translate.cancel() }
        return events
    }
}

/// Reads an audio file as 16 kHz mono samples, delivered in 0.1 s pieces. With `realTime`, at
/// the speed it would play (to simulate a live stream); otherwise as fast as possible.
public enum FileAudioSource {
    public static func stream(_ url: URL, realTime: Bool = false) throws -> AsyncStream<[Float]> {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let output = AVAudioPCMBuffer(pcmFormat: target,
                                      frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 64)!
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        return AsyncStream { continuation in
            let task = Task {
                for start in stride(from: 0, to: samples.count, by: 1_600) {
                    continuation.yield(Array(samples[start..<min(start + 1_600, samples.count)]))
                    if realTime { try? await Task.sleep(for: .milliseconds(100)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
