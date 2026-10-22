// Transcribe every manifest clip with Apple's on-device SpeechTranscriber (ja_JP).
// usage: apple_speech <manifest.jsonl> <out.jsonl>
// Installs the Japanese model through AssetInventory on first run.

import AVFoundation
import Foundation
import Speech

struct Clip: Decodable { let id: String; let path: String }

@main struct Main {
    static func main() async throws {
        let args = CommandLine.arguments
        let clips = try String(contentsOfFile: args[1], encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
        let locale = Locale(identifier: "ja_JP")

        setvbuf(stdout, nil, _IOLBF, 0)
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        let t0 = Date()
        print("status:", await AssetInventory.status(forModules: [probe]))
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            print("installing ja_JP model…")
            let watch = Task {
                while !Task.isCancelled {
                    let p = request.progress
                    print(String(format: "  %.0f%%  %lld / %lld bytes", p.fractionCompleted * 100,
                                 p.completedUnitCount, p.totalUnitCount))
                    try await Task.sleep(for: .seconds(5))
                }
            }
            try await request.downloadAndInstall()
            watch.cancel()
        }
        print(String(format: "model ready in %.1f s", Date().timeIntervalSince(t0)))
        if args.count > 3, args[3] == "--install-only" { return }

        FileManager.default.createFile(atPath: args[2], contents: nil)
        let out = try FileHandle(forWritingTo: URL(fileURLWithPath: args[2]))
        for clip in clips {
            let start = Date()
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let collect = Task {
                var text = ""
                for try await result in transcriber.results where result.isFinal {
                    text += String(result.text.characters)
                }
                return text
            }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: clip.path))
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let text = try await collect.value
            let line: [String: Any] = ["id": clip.id, "hyp": text,
                                       "sec": Date().timeIntervalSince(start)]
            out.write(try JSONSerialization.data(withJSONObject: line))
            out.write(Data("\n".utf8))
        }
        try out.close()
        print("done", clips.count)
    }
}
