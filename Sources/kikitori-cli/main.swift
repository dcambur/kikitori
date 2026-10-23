import Foundation
import KikitoriCore

// kikitori-cli: headless checks of the pipeline pieces.
//   sources                          list apps that have audio, playing first
//   translate <chunks.jsonl> [n]     translate the first n chunks ({"hyp": "..."} per line) with
//                                    Haiku 5.5, then explain the first line that got a note
//   run <audio file> [--realtime]    the whole live pipeline on a file: chunker → Apple Speech
//                                    → filter → Haiku 5.5, printing events as they happen
//   preview <audio file>             the streaming recognizer behind the live line, at real-time
//                                    speed: each result with its pieces and their times
let args = Array(CommandLine.arguments.dropFirst())

func translate(_ path: String, limit: Int) async throws {
    guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? KeychainStore.apiKey() else {
        print("No API key. Add one with: security add-generic-password -s kikitori -a anthropic-api-key -w")
        exit(2)
    }
    struct Row: Decodable { var hyp: String }
    let rows = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        .compactMap { try? JSONDecoder().decode(Row.self, from: Data($0.utf8)) }.prefix(limit)
    let client = ClaudeClient(apiKey: key)
    let translator = LiveTranslator(client: client, profile: nil,
                                    echoJapanese: ProcessInfo.processInfo.environment["KIKITORI_ECHO_JA"] != nil)
    var total = 0.0, lines: [TranscriptLine] = []
    for (i, row) in rows.enumerated() {
        let ja = TranscriptFilter.clean(row.hyp)
        let start = Date()
        let r = try await translator.translate(ja)
        total += r.cost
        print(String(format: "── chunk %d  %.1f s  $%.5f  in %d (cache write %d, read %d) out %d", i,
                     Date().timeIntervalSince(start), r.cost, r.usage.inputTokens,
                     r.usage.cacheCreationInputTokens ?? 0, r.usage.cacheReadInputTokens ?? 0, r.usage.outputTokens))
        if ProcessInfo.processInfo.environment["KIKITORI_DEBUG"] != nil { print("   RAW: \(r.raw)") }
        print("   ASR: \(ja)")
        for l in r.lines {
            print("   EN:  \(l.en)\(l.note.isEmpty ? "" : "   [注 \(l.term): \(l.note)]")")
            lines.append(TranscriptLine(time: Double(i * 15), ja: l.ja, en: l.en,
                                        note: l.note.isEmpty ? nil : l.note, term: l.term.isEmpty ? nil : l.term))
        }
    }
    print(String(format: "total $%.4f for %d chunks", total, rows.count))
    if let noted = lines.first(where: { $0.note != nil }) {
        let e = try await Explainer(client: client).explain(noted, context: lines, profile: nil)
        print(String(format: "── explain (Sonnet 5.5, $%.4f): %@ [%@]", e.cost, e.explanation.term, e.explanation.reading))
        print("   \(e.explanation.meaning)\n   In this line: \(e.explanation.inThisLine)")
    }
}

func runFile(_ path: String, realTime: Bool) async throws {
    let engine = AppleSpeechEngine()
    try await engine.prepare()
    let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? KeychainStore.apiKey()
    let translator = key.map { LiveTranslator(client: ClaudeClient(apiKey: $0), profile: nil) }
    var pipeline = LivePipeline(engine: engine, translator: translator, vad: try await SileroVAD.load())
    pipeline.maxChunk = Double(ProcessInfo.processInfo.environment["KIKITORI_MAX_CHUNK"] ?? "") ?? 6
    let began = Date()
    var cost = 0.0
    for await event in pipeline.run(try FileAudioSource.stream(URL(fileURLWithPath: path), realTime: realTime)) {
        let wall = Date().timeIntervalSince(began)
        switch event {
        case let .heard(time, _, ja, asr, _):
            print(String(format: "[%6.1f] JA (asr %.2fs, wall %.1fs): %@", time, asr, wall, ja))
        case let .translated(time, lines, c, seconds, _):
            cost += c
            for l in lines {
                print(String(format: "[%6.1f] EN (+%.1fs): %@%@", time, seconds, l.en ?? "", l.note.map { "  [注 \($0)]" } ?? ""))
            }
        case .translationSkipped, .hearing: break
        case let .translationFailed(time, failure, c, _):
            cost += c
            print(String(format: "[%6.1f] translation failed: %@", time, "\(failure)"))
        }
    }
    print(String(format: "done in %.1fs, translation cost $%.4f", Date().timeIntervalSince(began), cost))
}

switch args.first {
case "sources":
    for s in try AudioSources.list() {
        print("\(s.isPlaying ? "▶︎" : " ") \(s.name)  [\(s.id)]  processes: \(s.processObjects.count)")
    }
case "translate" where args.count >= 2:
    try await translate(args[1], limit: args.count > 2 ? Int(args[2]) ?? 8 : 8)
case "webkit" where args.count >= 2:
    // Which WebKit audio processes belong to the app with this pid (built-in player check).
    let objects = AudioSources.webKitProcesses(of: pid_t(args[1]) ?? 0)
    print("\(objects.count) WebKit audio process(es) for pid \(args[1]): \(objects)")
    for s in try AudioSources.list() where s.id.hasPrefix("com.apple") || s.name.contains("Safari") {
        print("  listed as source: \(s.name) [\(s.id)] playing=\(s.isPlaying)")
    }
case "level" where args.count >= 2:
    // Tap the WebKit audio of the app with this pid for 6 s and report how loud it is.
    let objects = AudioSources.webKitProcesses(of: pid_t(args[1]) ?? 0)
    let tap = ProcessTapCapture()
    try tap.start(processObjects: objects)
    var total = 0, loud = 0, peak: Float = 0
    let reader = Task { for await s in tap.samples { total += s.count; loud += s.filter { abs($0) > 0.003 }.count; peak = max(peak, s.map(abs).max() ?? 0) } }
    try await Task.sleep(for: .seconds(6))
    tap.stop(); _ = await reader.value
    print(String(format: "%.1f s tapped, %.0f%% audible, peak %.3f", Double(total) / 16_000, total > 0 ? 100 * Double(loud) / Double(total) : 0, peak))
case "run" where args.count >= 2:
    try await runFile(args[1], realTime: args.contains("--realtime"))
case "preview" where args.count >= 2:
    let began = Date()
    for try await r in AppleLivePreview().stream(try FileAudioSource.stream(URL(fileURLWithPath: args[1]), realTime: true), context: []) {
        let pieces = r.words.map { String(format: "%@[%.2f–%.2f]", $0.text, $0.start, $0.end) }.joined(separator: " ")
        print(String(format: "wall %5.2f  %@ %5.2f–%5.2f  %@", Date().timeIntervalSince(began), r.isFinal ? "FINAL" : "  vol", r.start, r.end, pieces))
    }
default:
    print("usage: kikitori-cli sources | translate <chunks.jsonl> [n] | run <audio> [--realtime] | preview <audio>")
}
