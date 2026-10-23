import AVFoundation
import Foundation

/// Audio in, subtitle events out: chunker → speech engine → filter → translator.
///
/// Three stages run side by side: chunking reads audio as it arrives, speech recognition takes
/// chunks in order, and translation takes transcripts in order. The queues between them are
/// unbounded, because capture streams keep only their newest buffers: if reading audio waited on
/// a slow recognition, speech would be lost and every later time would come out early.
/// Without a translator (no key, offline, budget cap) it still emits the Japanese.
public struct LivePipeline<VAD: VoiceActivityDetector>: Sendable {
    public enum Event: Sendable {
        /// Japanese for the chunk that started at `time` and lasted `duration` (seconds since the
        /// session began).
        case heard(time: Double, duration: Double, ja: String, asrSeconds: Double)
        case translated(time: Double, lines: [TranscriptLine], cost: Double, seconds: Double, tokens: Int)
        /// `cost` and `tokens` are what the API billed for an answer that couldn't be used (0 if none).
        case translationFailed(time: Double, ClaudeClient.Failure, cost: Double, tokens: Int)
        /// The chunk was not sent for translation (no translator, or Japanese only right now).
        case translationSkipped(time: Double)
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
        let (chunks, toRecognize) = AsyncStream.makeStream(of: Chunker<VAD>.Chunk.self)
        let (heard, toTranslate) = AsyncStream.makeStream(of: (Double, String).self)
        let shouldTranslate = shouldTranslate
        let cut = Task { [vad, maxChunk] in
            var chunker = Chunker(vad: vad)
            chunker.maxChunk = maxChunk
            for await samples in audio {
                for chunk in await chunker.append(samples) { toRecognize.yield(chunk) }
            }
            for chunk in chunker.finish() { toRecognize.yield(chunk) }
            toRecognize.finish()
        }
        let recognize = Task { [engine, contextTerms] in
            for await chunk in chunks {
                let start = Date()
                let raw = (try? await engine.transcribe(chunk.samples, context: contextTerms)) ?? ""
                let ja = TranscriptFilter.clean(raw)
                guard !ja.isEmpty else { continue }
                emit.yield(.heard(time: chunk.start, duration: chunk.duration, ja: ja,
                                  asrSeconds: Date().timeIntervalSince(start)))
                toTranslate.yield((chunk.start, ja))
            }
            toTranslate.finish()
        }
        let translate = Task { [translator] in
            for await (time, ja) in heard {
                guard let translator, await shouldTranslate() else {
                    emit.yield(.translationSkipped(time: time))
                    continue
                }
                let start = Date()
                do {
                    let r = try await translator.translate(ja)
                    let lines = r.lines.map {
                        TranscriptLine(time: time, ja: $0.ja.isEmpty ? ja : $0.ja, en: $0.en,
                                       note: $0.note.isEmpty ? nil : $0.note, term: $0.term.isEmpty ? nil : $0.term)
                    }
                    emit.yield(.translated(time: time, lines: lines, cost: r.cost,
                                           seconds: Date().timeIntervalSince(start), tokens: r.usage.total))
                } catch let billed as ClaudeClient.BilledFailure {
                    emit.yield(.translationFailed(time: time, billed.failure, cost: billed.cost, tokens: billed.usage.total))
                } catch let failure as ClaudeClient.Failure {
                    emit.yield(.translationFailed(time: time, failure, cost: 0, tokens: 0))
                } catch {
                    emit.yield(.translationFailed(time: time, .unexpected(status: 0, "\(error)"), cost: 0, tokens: 0))
                }
            }
        }
        Task {
            _ = await (cut.value, recognize.value, translate.value)
            emit.finish()
        }
        emit.onTermination = { _ in cut.cancel(); recognize.cancel(); translate.cancel() }
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
