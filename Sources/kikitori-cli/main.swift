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
//   speakers <audio file> [--realtime] [--json out.jsonl] [--enroll name@[file:]from-to ...]
//                                    speaker labels: chunker → Apple Speech (timed) + Sortformer
//                                    → turns, without translation; prints each chunk's turns, how
//                                    long each chunk waited for the diarizer, and its cost.
//                                    KIKITORI_SORTFORMER=fast|balanced|efficient|highContext picks the model,
//                                    KIKITORI_SPEAKER_WAIT=<s> how long a chunk may wait for it,
//                                    KIKITORI_NO_SPEAKERS=1 runs without it (to see what it costs).
//                                    --enroll: a known voice from that stretch (seconds) of the file,
//                                    or of another one (name@file:from-to)
//                                    --json also writes <out>.chars.json: every character's time
//                                    and shown speaker, for Experiments/speakers/score.py
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
        case let .heard(time, _, ja, asr, _, _):
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

/// What each chunk was labelled with, character by character, for scoring against a truth file:
/// the recognizer's pieces (recorded by `RecordingEngine`) and the tracker's frames (by
/// `TimedTracker`), put through the same steps as `LivePipeline`.
actor Recorder {
    struct Char: Encodable { var text: String; var start, end: Double; var speaker: String }
    var samples: [Float] = [], pieces: [TimedChar] = []
    var chunks: [[Char]] = []
    func heard(_ samples: [Float], _ pieces: [TimedChar]) { self.samples = samples; self.pieces = pieces }
    func label(from: Double, frames: SpeakerFrames) {
        let chars = OnsetRefiner.refine(TranscriptFilter.clean(pieces), samples: samples).shifted(by: from)
        let who = SpeakerLabeler.speakers(for: chars, in: frames)
        var shown = [String](repeating: "", count: chars.count)
        for turn in SpeakerLabeler.turns(chars, speakers: who) {
            for i in turn.from..<turn.to { shown[i] = turn.speaker.map(SpeakerLabeler.label) ?? "" }
        }
        chunks.append(chars.indices.map { Char(text: chars[$0].text, start: chars[$0].start, end: chars[$0].end, speaker: shown[$0]) })
    }
}

struct RecordingEngine: TimedSpeechEngine {
    let inner: AppleSpeechEngine, recorder: Recorder
    var name: String { inner.name }
    func prepare() async throws { try await inner.prepare() }
    func transcribe(_ samples: [Float], context: [String]) async throws -> String { try await inner.transcribe(samples, context: context) }
    func transcribeTimed(_ samples: [Float], context: [String]) async throws -> [TimedChar] {
        let pieces = try await inner.transcribeTimed(samples, context: context)
        await recorder.heard(samples, pieces)
        return pieces
    }
}

/// The tracker, timing how long each chunk waits for it.
actor TimedTracker: SpeakerTracking {
    let inner: SpeakerTracker, recorder: Recorder
    var waits: [Double] = []
    init(_ inner: SpeakerTracker, recorder: Recorder) { self.inner = inner; self.recorder = recorder }
    func append(_ samples: [Float], at time: Double) async { await inner.append(samples, at: time) }
    func finish() async { await inner.finish() }
    func reset() async { await inner.reset() }
    func frames(from: Double, to: Double) async -> SpeakerFrames {
        let start = Date()
        let f = await inner.frames(from: from, to: to)
        waits.append(Date().timeIntervalSince(start))
        await recorder.label(from: from, frames: f)
        return f
    }
}

func speakers(_ path: String, realTime: Bool, json: String?, enroll: [String]) async throws {
    let url = URL(fileURLWithPath: path)
    var all: [Float] = []
    for await piece in try FileAudioSource.stream(url) { all += piece }
    var voices: [(name: String, samples: [Float])] = []
    for spec in enroll {   // name@from-to, or name@file:from-to
        guard let at = spec.firstIndex(of: "@") else { continue }
        var rest = spec[spec.index(after: at)...], source = all
        if let colon = rest.lastIndex(of: ":") {
            source = []
            for await piece in try FileAudioSource.stream(URL(fileURLWithPath: String(rest[..<colon]))) { source += piece }
            rest = rest[rest.index(after: colon)...]
        }
        let range = rest.split(separator: "-").compactMap { Double($0) }
        guard range.count == 2 else { continue }
        let a = Int(range[0] * 16_000), b = min(source.count, Int(range[1] * 16_000))
        if a < b { voices.append((String(spec[..<at]), Array(source[a..<b]))) }
    }
    let recorder = Recorder()
    let engine = RecordingEngine(inner: AppleSpeechEngine(), recorder: recorder)
    try await engine.prepare()
    var began = Date()
    let variant = SpeakerTracker.Variant(rawValue: ProcessInfo.processInfo.environment["KIKITORI_SORTFORMER"] ?? "") ?? .fast
    let (tracker, names) = try await SpeakerTracker.load(voices: voices, variant: variant)
    print(String(format: "Sortformer (%@) loaded in %.1f s; enrolled: %@", variant.rawValue, Date().timeIntervalSince(began),
                 names.sorted { $0.key < $1.key }.map { "\(SpeakerLabeler.label($0.key))=\($0.value)" }.joined(separator: " ")))
    // Faster than real time the diarizer falls behind the recognizer: let chunks wait for it.
    if !realTime { await tracker.setMaxWait(600) }
    if let wait = ProcessInfo.processInfo.environment["KIKITORI_SPEAKER_WAIT"].flatMap(Double.init) { await tracker.setMaxWait(wait) }
    let timed = TimedTracker(tracker, recorder: recorder)
    var pipeline = LivePipeline(engine: engine, translator: nil, vad: try await SileroVAD.load())
    pipeline.maxChunk = Double(ProcessInfo.processInfo.environment["KIKITORI_MAX_CHUNK"] ?? "") ?? 6
    // KIKITORI_NO_SPEAKERS: the same run without the tracker, to see what it costs.
    if ProcessInfo.processInfo.environment["KIKITORI_NO_SPEAKERS"] == nil { pipeline.speakers = timed }
    var out = ""
    began = Date()
    let usage0 = cpuSeconds()
    for await event in pipeline.run(try FileAudioSource.stream(url, realTime: realTime)) {
        guard case let .heard(time, duration, ja, asr, _, turns) = event else { continue }
        let wait = await timed.waits.last ?? 0
        print(String(format: "[%6.1f +%4.1f] asr %.2fs, speakers +%.2fs", time, duration, asr, wait))
        for t in turns { print("    \(t.speaker ?? "?")  \(t.ja)") }
        struct Row: Encodable { var time, duration, asr, wait: Double; var ja: String; var turns: [[String: String]] }
        let row = Row(time: time, duration: duration, asr: asr, wait: wait, ja: ja,
                      turns: turns.map { ["speaker": $0.speaker ?? "", "ja": $0.ja] })
        out += String(decoding: try JSONEncoder().encode(row), as: UTF8.self) + "\n"
    }
    let wall = Date().timeIntervalSince(began), busy = await tracker.busySeconds
    let audio = Double(all.count) / 16_000
    let waits = await timed.waits.sorted()
    print(String(format: "audio %.0f s, wall %.1f s; diarizer busy %.1f s (%.1f%% of real time); process CPU %.1f s",
                 audio, wall, busy, 100 * busy / audio, cpuSeconds() - usage0))
    if !waits.isEmpty {
        print(String(format: "speaker wait per chunk: median %.2f s, p90 %.2f s, max %.2f s (%d chunks)",
                     waits[waits.count / 2], waits[Int(Double(waits.count - 1) * 0.9)], waits.last!, waits.count))
    }
    if let json {
        try out.write(toFile: json, atomically: true, encoding: .utf8)
        try JSONEncoder().encode(await recorder.chunks).write(to: URL(fileURLWithPath: json + ".chars.json"))
    }
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
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
case "speakers" where args.count >= 2:
    func values(_ name: String) -> [String] { args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] } }
    try await speakers(args[1], realTime: args.contains("--realtime"), json: values("--json").first, enroll: values("--enroll"))
default:
    print("usage: kikitori-cli sources | translate <chunks.jsonl> [n] | run <audio> [--realtime] | preview <audio> | speakers <audio> [--realtime] [--json out] [--enroll name@from-to]")
}
