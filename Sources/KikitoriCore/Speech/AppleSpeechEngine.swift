import AVFoundation
import Foundation
import Speech

/// Apple's on-device SpeechTranscriber (macOS 26+), Japanese. The model is a system asset:
/// `prepare()` asks macOS to install it once; nothing is bundled with the app.
public struct AppleSpeechEngine: SpeechEngine {
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
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
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
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
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
