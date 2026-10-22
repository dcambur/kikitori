import Foundation
import KikitoriCore

// kikitori-cli: headless checks of the pipeline pieces.
//   sources                          list apps that have audio, playing first
//   translate <chunks.jsonl> [n]     translate the first n chunks ({"hyp": "..."} per line) with
//                                    Haiku 5.5, then explain the first line that got a note
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

switch args.first {
case "sources":
    for s in try AudioSources.list() {
        print("\(s.isPlaying ? "▶︎" : " ") \(s.name)  [\(s.id)]  processes: \(s.processObjects.count)")
    }
case "translate" where args.count >= 2:
    try await translate(args[1], limit: args.count > 2 ? Int(args[2]) ?? 8 : 8)
default:
    print("usage: kikitori-cli sources | translate <chunks.jsonl> [n]")
}
