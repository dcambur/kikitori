import AVFoundation
import Foundation
import Speech

/// Apple's on-device SpeechTranscriber (macOS 26+), Japanese. The model is a system asset:
/// `prepare()` asks macOS to install it once; nothing is bundled with the app.
public struct AppleSpeechEngine: TimedSpeechEngine {
    public let name = "Apple Speech"
    let locale = Locale(identifier: "ja_JP")

    public init() {}

    public func prepare() async throws {
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
    }

    public func transcribe(_ samples: [Float], context: [String]) async throws -> String {
        try await recognize(samples, context: context, timed: false).text
    }

    /// The same recognition with `.audioTimeRange` on: identical text (checked on 55 chunks of
    /// stream audio), one piece per character, times on a 60 ms grid.
    public func transcribeTimed(_ samples: [Float], context: [String]) async throws -> [TimedChar] {
        try await recognize(samples, context: context, timed: true).pieces
    }

    private func recognize(_ samples: [Float], context: [String], timed: Bool) async throws -> (text: String, pieces: [TimedChar]) {
        var preset = SpeechTranscriber.Preset.transcription
        if timed { preset.attributeOptions.insert(.audioTimeRange) }
        let transcriber = SpeechTranscriber(locale: locale, preset: preset)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !context.isEmpty {
            let analysisContext = AnalysisContext()
            analysisContext.contextualStrings[.general] = context
            try await analyzer.setContext(analysisContext)
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = try Self.buffer(samples, as: format)

        let collect = Task {
            var text = "", pieces: [TimedChar] = []
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
                guard timed else { continue }
                for run in result.text.runs {
                    let range = run.audioTimeRange ?? result.range
                    pieces.append(TimedChar(text: String(result.text[run.range].characters),
                                            start: range.start.seconds, end: range.end.seconds))
                }
            }
            return (text, pieces)
        }
        let (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        feed.yield(AnalyzerInput(buffer: buffer))
        feed.finish()
        do {
            try await analyzer.start(inputSequence: input)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collect.cancel()   // the results may never finish after a failed analysis
            throw error
        }
        return try await collect.value
    }

    /// 16 kHz mono Float32 samples converted to the analyzer's preferred format.
    static func buffer(_ samples: [Float], as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if format == source { return input }
        guard let converter = AVAudioConverter(from: source, to: format) else { throw CocoaError(.featureUnsupported) }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / 16_000) + 64
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return output
    }
}
