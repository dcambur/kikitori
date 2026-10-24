import AVFoundation
import Foundation
import os

/// Audio in, subtitle events out: chunker → speech engine → filter → translator, plus an
/// optional streaming recognizer for the live line (words as they are spoken).
///
/// Three stages run side by side: chunking reads audio as it arrives, speech recognition takes
/// chunks in order, and translation takes transcripts in order. The queues between them are
/// unbounded, because capture streams keep only their newest buffers: if reading audio waited on
/// a slow recognition, speech would be lost and every later time would come out early.
/// Without a translator (no key, offline, budget cap) it still emits the Japanese.
public struct LivePipeline<VAD: VoiceActivityDetector>: Sendable {
    public enum Event: Sendable {
        /// Japanese for the chunk that started at `time` and lasted `duration` (seconds since the
        /// session began), with the chunk's audio (16 kHz mono) for replay. With speakers tracked,
        /// `turns` is the Japanese split by speaker (else empty).
        case heard(time: Double, duration: Double, ja: String, asrSeconds: Double, audio: [Float], turns: [TranscriptLine])
        /// The live line: words heard since the last chunk, still changing ("" when there are none).
        case hearing(String)
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
    /// Streaming recognition for the live line; nil for none.
    public var preview: (any LivePreviewEngine)?
    /// Who is speaking, for speaker labels (needs a `TimedSpeechEngine`); nil for none.
    public var speakers: (any SpeakerTracking)?

    public init(engine: any SpeechEngine, translator: LiveTranslator?, vad: VAD, contextTerms: [String] = []) {
        self.engine = engine; self.translator = translator; self.vad = vad; self.contextTerms = contextTerms
    }

    public func run(_ audio: AsyncStream<[Float]>) -> AsyncStream<Event> {
        let (events, emit) = AsyncStream.makeStream(of: Event.self)
        let (chunks, toRecognize) = AsyncStream.makeStream(of: Chunker<VAD>.Chunk.self)
        let (heard, toTranslate) = AsyncStream.makeStream(of: (Double, Spoken).self)
        let (previewAudio, toPreview) = AsyncStream.makeStream(of: [Float].self)
        let (speakerAudio, toSpeakers) = AsyncStream.makeStream(of: ([Float], Double).self)
        let speakers = engine is any TimedSpeechEngine ? speakers : nil
        let shouldTranslate = shouldTranslate
        let live = LiveLine { emit.yield(.hearing($0)) }
        let cut = Task { [vad, maxChunk, preview] in
            var chunker = Chunker(vad: vad)
            chunker.maxChunk = maxChunk
            // Samples fed so far: the live line's clock, which ages its words out even through
            // silence. A quarter-second step is fine enough for that.
            var fed = 0, clock = 0.0
            for await samples in audio {
                if speakers != nil { toSpeakers.yield((samples, Double(fed) / 16_000)) }
                fed += samples.count
                if preview != nil {
                    toPreview.yield(samples)
                    let time = Double(fed) / 16_000
                    if time - clock >= 0.25 { clock = time; await live.advance(to: time) }
                }
                for chunk in await chunker.append(samples) { toRecognize.yield(chunk) }
            }
            toPreview.finish()
            toSpeakers.finish()
            for chunk in chunker.finish() { toRecognize.yield(chunk) }
            toRecognize.finish()
        }
        let previewing = Task { [preview, contextTerms] in
            guard let preview else { return }
            // A failing preview only loses the live line; the chunked recognition carries on.
            do {
                for try await result in preview.stream(previewAudio, context: contextTerms) { await live.update(result) }
            } catch {
                Logger(subsystem: "app.kikitori", category: "pipeline").error("live line stopped: \(error, privacy: .public)")
            }
            toPreview.finish()   // nobody reads it any more: later audio is dropped, not buffered
            await live.clear()
        }
        let tracking = Task {
            guard let speakers else { return }
            // Its own stage, so a slow diarizer run never holds up chunking.
            for await (samples, time) in speakerAudio { await speakers.append(samples, at: time) }
            await speakers.finish()
        }
        let recognize = Task { [engine, contextTerms] in
            for await chunk in chunks {
                let start = Date()
                var spoken = Spoken(ja: "")
                if let speakers, let timed = engine as? any TimedSpeechEngine {
                    let pieces = TranscriptFilter.clean((try? await timed.transcribeTimed(chunk.samples, context: contextTerms)) ?? [])
                    spoken = Spoken(ja: pieces.text, chars: OnsetRefiner.refine(pieces, samples: chunk.samples).shifted(by: chunk.start))
                    let asr = Date().timeIntervalSince(start)
                    if !pieces.isEmpty {
                        let frames = await speakers.frames(from: chunk.start, to: chunk.start + chunk.duration)
                        spoken.speakers = SpeakerLabeler.speakers(for: spoken.chars, in: frames)
                    }
                    if !spoken.ja.isEmpty {
                        emit.yield(.heard(time: chunk.start, duration: chunk.duration, ja: spoken.ja, asrSeconds: asr,
                                          audio: chunk.samples, turns: spoken.turnLines(at: chunk.start)))
                    }
                } else {
                    let raw = (try? await engine.transcribe(chunk.samples, context: contextTerms)) ?? ""
                    spoken.ja = TranscriptFilter.clean(raw)
                    if !spoken.ja.isEmpty {
                        emit.yield(.heard(time: chunk.start, duration: chunk.duration, ja: spoken.ja,
                                          asrSeconds: Date().timeIntervalSince(start), audio: chunk.samples, turns: []))
                    }
                }
                if !spoken.ja.isEmpty { toTranslate.yield((chunk.start, spoken)) }
                await live.cut(at: chunk.start + chunk.duration)
            }
            toTranslate.finish()
        }
        let translate = Task { [translator] in
            for await (time, spoken) in heard {
                let ja = spoken.ja
                guard let translator, await shouldTranslate() else {
                    emit.yield(.translationSkipped(time: time))
                    continue
                }
                let start = Date()
                do {
                    let r = try await translator.translate(spoken.translatorInput)
                    let speakers = spoken.cueLines(r.lines).map(\.speaker)
                    let lines = r.lines.enumerated().map { k, l in
                        var line = TranscriptLine(time: time, ja: l.ja.isEmpty ? ja : l.ja, en: l.en,
                                                  note: l.note.isEmpty ? nil : l.note, term: l.term.isEmpty ? nil : l.term)
                        line.speaker = speakers.count == r.lines.count ? speakers[k] : speakers.first ?? nil
                        return line
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
            _ = await (cut.value, recognize.value, translate.value, previewing.value, tracking.value)
            emit.finish()
        }
        emit.onTermination = { _ in cut.cancel(); recognize.cancel(); translate.cancel(); previewing.cancel(); tracking.cancel() }
        return events
    }
}

/// The live line between the preview and recognition stages: emits it whenever it changes.
actor LiveLine {
    let emit: @Sendable (String) -> Void
    var text = PreviewText()
    var shown = ""

    init(emit: @escaping @Sendable (String) -> Void) { self.emit = emit }

    func update(_ result: PreviewResult) { show(text.update(result)) }
    func cut(at time: Double) { show(text.cut(at: time)) }
    func advance(to time: Double) { show(text.advance(to: time)) }
    /// The preview ended: forget its words too, so a later cut can't bring them back.
    func clear() { text = PreviewText(); show("") }

    private func show(_ line: String) {
        guard line != shown else { return }
        shown = line
        emit(line)
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
