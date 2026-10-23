import AVFoundation
import Foundation
import Speech

/// Words as they are spoken, for the live line: a streaming recognizer runs beside the chunked
/// one, and its text shows until the chunk it belongs to is recognized properly.
public protocol LivePreviewEngine: Sendable {
    /// Recognizes `audio` (16 kHz mono, contiguous from 0 s) as it arrives. Times are seconds on
    /// the same clock as the chunker's.
    func stream(_ audio: AsyncStream<[Float]>, context: [String]) -> AsyncThrowingStream<PreviewResult, Error>
}

public struct PreviewResult: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    /// False while the recognizer may still change it.
    public var isFinal: Bool
    /// The text in pieces with the time each ends, so the part already turned into a line can be
    /// dropped: one result often spans several chunks.
    public var words: [Word]

    public struct Word: Sendable, Equatable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
    }

    /// Without `words`, the whole text counts as ending at `end`.
    public init(start: Double, end: Double, text: String, isFinal: Bool, words: [Word]? = nil) {
        self.start = start; self.end = end; self.text = text; self.isFinal = isFinal
        self.words = words ?? [Word(text: text, start: start, end: end)]
    }
}

/// Apple's SpeechTranscriber in streaming mode, with volatile (still changing) results.
public struct AppleLivePreview: LivePreviewEngine {
    let locale = Locale(identifier: "ja_JP")

    public init() {}

    public func stream(_ audio: AsyncStream<[Float]>, context: [String]) -> AsyncThrowingStream<PreviewResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                        reportingOptions: [.volatileResults, .fastResults],
                                                        attributeOptions: [.audioTimeRange])
                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    if !context.isEmpty {
                        let analysisContext = AnalysisContext()
                        analysisContext.contextualStrings[.general] = context
                        try await analyzer.setContext(analysisContext)
                    }
                    let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                        ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
                    let converter = try StreamConverter(to: format)
                    let (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
                    // A recognizer error ends the live line at once (the pipeline then stops feeding
                    // it) rather than when the session stops.
                    let results = Task {
                        do {
                            for try await r in transcriber.results {
                                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                                let words = r.text.runs.map { run in
                                    let time = run.audioTimeRange ?? r.range
                                    return PreviewResult.Word(text: String(r.text[run.range].characters),
                                                              start: time.start.seconds, end: time.end.seconds)
                                }
                                continuation.yield(PreviewResult(start: r.range.start.seconds, end: r.range.end.seconds,
                                                                 text: text, isFinal: r.isFinal, words: words))
                            }
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    do { try await analyzer.start(inputSequence: input) } catch { results.cancel(); throw error }
                    for await samples in audio {
                        if let buffer = converter.convert(samples) { feed.yield(AnalyzerInput(buffer: buffer)) }
                    }
                    feed.finish()
                    if Task.isCancelled {   // stopped: no need for the last words
                        await analyzer.cancelAndFinishNow()
                        results.cancel()
                        continuation.finish()
                        return
                    }
                    do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { results.cancel(); throw error }
                    await results.value
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 16 kHz mono Float32 to the recognizer's format, one buffer at a time, keeping the resampler's
/// state between buffers so there are no clicks at their edges.
final class StreamConverter {
    let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let target: AVAudioFormat
    let converter: AVAudioConverter?

    init(to target: AVAudioFormat) throws {
        self.target = target
        if target == source { converter = nil; return }
        guard let converter = AVAudioConverter(from: source, to: target) else { throw CocoaError(.featureUnsupported) }
        self.converter = converter
    }

    func convert(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard let converter else { return input }
        let capacity = AVAudioFrameCount(Double(samples.count) * target.sampleRate / source.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

/// The live line: the words the streaming recognizer heard after the end of the last chunk that
/// was recognized properly. Words over audio the chunker dropped (music, noise) age out after
/// `keep` seconds.
struct PreviewText {
    var keep = 8.0
    private var finals: [PreviewResult] = []
    private var volatile: PreviewResult?
    private var cutAt = 0.0
    private var latest = 0.0

    /// A new streaming result; returns the live line.
    mutating func update(_ r: PreviewResult) -> String {
        latest = max(latest, r.end)
        if r.isFinal {
            if !r.text.isEmpty { finals.append(r) }
            if let v = volatile, v.start < r.end { volatile = nil }
        } else {
            volatile = r.text.isEmpty ? nil : r
        }
        return text()
    }

    /// The audio has reached `time` (seconds since the start): words older than `keep` go even
    /// when nothing new is recognized, so the line empties after speech stops.
    mutating func advance(to time: Double) -> String {
        latest = max(latest, time)
        return text()
    }

    /// Everything before `time` is now a proper line; returns what is left of the live line.
    mutating func cut(at time: Double) -> String {
        cutAt = max(cutAt, time)
        return text()
    }

    private mutating func text() -> String {
        let after = max(cutAt, latest - keep)
        finals.removeAll { $0.end <= after }
        if let v = volatile, v.end <= after { volatile = nil }
        let words = (finals + (volatile.map { [$0] } ?? [])).flatMap(\.words)
        // A cut can leave a stray "、" or "。" from the line before at the start (not the end:
        // 「やばい！？」 keeps its marks).
        let line = words.map { Self.part($0, after: after) }.joined()
        return String(line.drop { $0.unicodeScalars.allSatisfy(Self.stray.contains) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let stray = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "、。，．,.!?！？"))

    /// The part of `word` heard after `time`. A piece the cut falls inside (results still being
    /// recognized come in long pieces) is cut in proportion to its duration: Japanese is spoken
    /// at a fairly even pace per character.
    static func part(_ word: PreviewResult.Word, after time: Double) -> String {
        if word.end <= time { return "" }
        if word.start >= time || word.end - word.start < 0.01 { return word.text }
        let chars = Array(word.text)
        let keep = Int((Double(chars.count) * (word.end - time) / (word.end - word.start)).rounded())
        return String(chars.suffix(keep))
    }
}
