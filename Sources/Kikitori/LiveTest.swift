import AppKit
import Foundation
import KikitoriCore

/// Headless end-to-end check through the real app identity (which owns the audio permission):
///   open build/Kikitori.app --args --live-test <bundle id> <seconds> <log path>
/// Taps that app's audio, runs chunker → Apple Speech → Haiku, writes events to the log, quits.
enum LiveTest {
    static func run(bundleID: String, seconds: Double, logPath: String) async {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: logPath)
        func write(_ line: String) {
            log?.write(Data((line + "\n").utf8))
        }
        do {
            let sources = try AudioSources.list()
            write("sources: " + sources.map { "\($0.name)\($0.isPlaying ? " ▶︎" : "")" }.joined(separator: ", "))
            guard let source = sources.first(where: { $0.id == bundleID }) else {
                write("error: \(bundleID) has no audio processes"); return
            }
            let engine = AppleSpeechEngine()
            try await engine.prepare()
            var pipeline = LivePipeline(engine: engine,
                                        translator: KeychainStore.apiKey().map {
                                            LiveTranslator(client: ClaudeClient(apiKey: $0), profile: nil)
                                        },
                                        vad: try await SileroVAD.load())
            pipeline.maxChunk = 6
            let capture = ProcessTapCapture()
            try capture.start(processObjects: source.processObjects)
            write("capturing \(source.name) for \(Int(seconds)) s")

            // Count the audio as it passes through, to tell "no permission" (all zeros) from silence.
            let (counted, feed) = AsyncStream.makeStream(of: [Float].self)
            let meter = Task {
                var total = 0, loud = 0
                for await samples in capture.samples {
                    total += samples.count
                    loud += samples.filter { abs($0) > 0.001 }.count
                    feed.yield(samples)
                }
                feed.finish()
                write(String(format: "audio: %.1f s received, %.0f%% non-silent", Double(total) / 16_000,
                             total > 0 ? 100 * Double(loud) / Double(total) : 0))
            }
            let began = Date()
            let consume = Task {
                var cost = 0.0
                for await event in pipeline.run(counted) {
                    let wall = Date().timeIntervalSince(began)
                    switch event {
                    case let .heard(time, _, ja, _):
                        write(String(format: "[%5.1f | wall %5.1f] JA %@", time, wall, ja))
                    case let .translated(time, lines, c, _, _):
                        cost += c
                        for l in lines { write(String(format: "[%5.1f | wall %5.1f] EN %@", time, wall, l.en ?? "")) }
                    case .translationSkipped: break
                    case let .translationFailed(time, failure, c, _):
                        cost += c
                        write(String(format: "[%5.1f] translation failed: %@", time, "\(failure)"))
                    }
                }
                write(String(format: "translation cost $%.4f", cost))
            }
            try await Task.sleep(for: .seconds(seconds))
            capture.stop()
            await meter.value
            await consume.value
            write("done")
        } catch {
            write("error: \(error)")
        }
        try? log?.close()
    }
}
