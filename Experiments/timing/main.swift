// EXPERIMENT (spike for docs/design/realtime-sync.md), not product code.
//
//   swift run kk-spike-timing <audio file> [--truth <truth.json>] [--ass <out.ass>] [--json <out.json>]
//
// Cuts the file exactly as the live pipeline does (Silero VAD, 6 s cap) and recognizes every
// chunk twice with SpeechTranscriber: once as today (preset .transcription), once with the
// same preset plus the .audioTimeRange attribute. It reports
//   - whether the text is identical (adding time ranges must not change recognition),
//   - the time ranges' granularity (characters per run),
//   - how they line up with the audio: runs over silence, runs bridging a pause, error at onsets
//     after a pause (energy-based, 10 ms frames),
//   - with --truth (word onsets of a synthetic file, from make-truth.sh): onset error per word.
// --ass writes karaoke subtitles (\k per run) to burn onto the audio for a by-ear check.
import AVFoundation
import Foundation
import KikitoriCore
import Speech

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else { print("usage: kk-spike-timing <audio> [--truth t.json] [--ass out.ass] [--json out.json]"); exit(2) }
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } }

let locale = Locale(identifier: "ja_JP")
let rate = 16_000.0

struct Run: Codable {
    var text: String; var start: Double; var end: Double
    /// The refined start (first sound inside a long run); set for the JSON output.
    var onset: Double?
    init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}
struct ChunkResult: Codable {
    var start: Double, duration: Double
    var today: String, timed: String
    var todaySeconds: Double, timedSeconds: Double
    var runs: [Run]   // absolute times (seconds in the file)
}

func samples(of url: URL) async throws -> [Float] {
    var all: [Float] = []
    for await s in try FileAudioSource.stream(url) { all += s }
    return all
}

func buffer(_ samples: [Float], as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))!
    input.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    if format == source { return input }
    let converter = AVAudioConverter(from: source, to: format)!
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * format.sampleRate / rate) + 64)!
    var fed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return input
    }
    if let error { throw error }
    return output
}

/// One chunk through a fresh analyzer, as AppleSpeechEngine does; with `timed`, the preset gains
/// the audioTimeRange attribute and the runs come back with their times (relative to the chunk).
func recognize(_ chunk: [Float], timed: Bool) async throws -> (String, [Run]) {
    var preset = SpeechTranscriber.Preset.transcription
    if timed { preset.attributeOptions.insert(.audioTimeRange) }
    let transcriber = SpeechTranscriber(locale: locale, preset: preset)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let input = try buffer(chunk, as: format)
    let collect = Task { () throws -> (String, [Run]) in
        var text = "", runs: [Run] = []
        for try await result in transcriber.results where result.isFinal {
            text += String(result.text.characters)
            for run in result.text.runs {
                let piece = String(result.text[run.range].characters)
                if let r = run.audioTimeRange { runs.append(Run(text: piece, start: r.start.seconds, end: r.end.seconds)) }
            }
        }
        return (text, runs)
    }
    let (stream, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
    feed.yield(AnalyzerInput(buffer: input)); feed.finish()
    try await analyzer.start(inputSequence: stream)
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    return try await collect.value
}

// ---- energy analysis -----------------------------------------------------------------------
/// 10 ms frames, 20 ms window: dB RMS.
func energy(_ s: ArraySlice<Float>) -> [Double] {
    let hop = 160, win = 320
    var out: [Double] = []
    var i = s.startIndex
    while i + win <= s.endIndex {
        var sum: Float = 0
        for j in i..<i + win { sum += s[j] * s[j] }
        out.append(10 * log10(Double(sum / Float(win)) + 1e-10))
        i += hop
    }
    return out
}

func percentile(_ v: [Double], _ p: Double) -> Double {
    guard !v.isEmpty else { return 0 }
    let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

let url = URL(fileURLWithPath: path)
let audio = try await samples(of: url)
print(String(format: "%@: %.1f s", url.lastPathComponent, Double(audio.count) / rate))
if args.contains("--fixed") {   // no VAD: what the recognizer hears in plain 6 s windows
    try await SpeechEngineWarmup.run()
    for start in stride(from: 0, to: audio.count, by: 96_000) {
        let (text, _) = try await recognize(Array(audio[start..<min(start + 96_000, audio.count)]), timed: false)
        print(String(format: "%6.0f s  %@", Double(start) / rate, text))
    }
    exit(0)
}
if args.contains("--vad") {   // Silero's speech probability, the highest per second
    var vad = try await SileroVAD.load()
    var line = ""
    for (i, start) in stride(from: 0, to: audio.count - vad.frameSize, by: vad.frameSize).enumerated() {
        if let every = option("--reset").flatMap(Int.init), i % every == 0 { await vad.reset() }   // fresh state every N frames
        let p = await vad.probability(audio[start..<start + vad.frameSize])
        line += p.isNaN ? "N" : p >= 0.5 ? "#" : p >= 0.2 ? "+" : "."
        if args.contains("--raw"), i < 40 { print(i, p) }
        if (i + 1) % 39 == 0 { print(String(format: "%6.0f s %@", Double(start) / rate - 9, line)); line = "" }
    }
    exit(0)
}
var chunker = Chunker(vad: try await SileroVAD.load())
chunker.maxChunk = 6   // as LivePipeline
var chunks: [Chunker<SileroVAD>.Chunk] = []
for start in stride(from: 0, to: audio.count, by: 1_600) { chunks += await chunker.append(Array(audio[start..<min(start + 1_600, audio.count)])) }
chunks += chunker.finish()
print("\(chunks.count) chunks")

try await SpeechEngineWarmup.run()
var results: [ChunkResult] = []
var identical = 0
for c in chunks {
    var t = Date()
    let (today, _) = try await recognize(c.samples, timed: false)
    let todaySeconds = Date().timeIntervalSince(t)
    t = Date()
    let (timed, runs) = try await recognize(c.samples, timed: true)
    let timedSeconds = Date().timeIntervalSince(t)
    if today == timed { identical += 1 }
    results.append(ChunkResult(start: c.start, duration: c.duration, today: today, timed: timed, todaySeconds: todaySeconds,
                               timedSeconds: timedSeconds, runs: runs.map { Run(text: $0.text, start: c.start + $0.start, end: c.start + $0.end) }))
}

// ---- report -----------------------------------------------------------------------------------
print("\n== text with and without audioTimeRange: \(identical)/\(results.count) chunks identical")
for r in results where r.today != r.timed { print("   DIFF today: \(r.today)\n        timed: \(r.timed)") }
let todayASR = results.map(\.todaySeconds).reduce(0, +), timedASR = results.map(\.timedSeconds).reduce(0, +)
print(String(format: "   recognition time: today %.2f s, with times %.2f s (%d chunks)", todayASR, timedASR, results.count))

let runs = results.flatMap(\.runs)
let chars = runs.map { $0.text.count }
print("\n== granularity: \(runs.count) runs, \(chars.reduce(0, +)) characters, " +
      String(format: "%.2f chars/run, max %d; ", Double(chars.reduce(0, +)) / Double(max(runs.count, 1)), chars.max() ?? 0) +
      "runs with >1 character: \(chars.filter { $0 > 1 }.count)")
let lengths = runs.map { $0.end - $0.start }
print(String(format: "   run duration: median %.0f ms, p90 %.0f ms, max %.0f ms; zero-length runs %d", percentile(lengths, 0.5) * 1000,
             percentile(lengths, 0.9) * 1000, (lengths.max() ?? 0) * 1000, lengths.filter { $0 < 0.001 }.count))
var backwards = 0
for r in results { for (a, b) in zip(r.runs, r.runs.dropFirst()) where b.start < a.start - 0.001 { backwards += 1 } }
print("   runs starting before the previous one: \(backwards)")

// Energy: speech threshold per chunk = its 15th percentile + 12 dB (streams have music under speech).
// Punctuation runs (。、？！ and spaces) carry no sound of their own and are left out.
// "Refined" start: a run longer than 240 ms often begins in the silence before it (the recognizer
// gives the pause to the next character); its start moves to its first 30 ms of sound.
let punctuation = CharacterSet(charactersIn: "。、？！?!,. 　ー")
func isMark(_ r: Run) -> Bool { r.text.trimmingCharacters(in: .whitespaces).unicodeScalars.allSatisfy(punctuation.contains) }
var refined: [String: Double] = [:]   // "start|text" -> refined start
var overSilence = 0, overSilenceRefined = 0, bridging = 0, measured = 0
var onsetErrors: [Double] = [], onsetRefined: [Double] = [], firstErrors: [Double] = [], firstRefined: [Double] = [], lastErrors: [Double] = []
for r in results {
    let a = Int(r.start * rate), b = min(audio.count, a + Int(r.duration * rate))
    let e = energy(audio[a..<b])
    guard e.count > 20 else { continue }
    let floor = percentile(e, 0.15), thr = floor + 12
    let loud = e.map { $0 > thr }
    func frame(_ t: Double) -> Int { max(0, min(e.count - 1, Int((t - r.start) * 100))) }
    func refine(_ run: Run) -> Double {
        guard run.end - run.start > 0.24 else { return run.start }
        let f0 = frame(run.start), f1 = frame(run.end - 0.06)
        guard f1 > f0 + 2 else { return run.start }
        for f in f0..<(f1 - 2) where loud[f] && loud[f + 1] && loud[f + 2] { return r.start + Double(f) / 100 }
        return run.start
    }
    let sounding = r.runs.filter { !isMark($0) }
    for run in sounding { refined["\(run.start)|\(run.text)"] = refine(run) }
    var pauses: [(Int, Int)] = []
    var i = 0
    while i < loud.count {
        if !loud[i] { var j = i; while j < loud.count && !loud[j] { j += 1 }; if j - i >= 15 { pauses.append((i, j)) }; i = j } else { i += 1 }
    }
    func share(_ s: Double, _ end: Double) -> Double {
        let f0 = frame(s), f1 = max(f0 + 1, frame(end))
        return Double(loud[f0..<min(f1, loud.count)].filter { $0 }.count) / Double(max(1, min(f1, loud.count) - f0))
    }
    for run in sounding where run.end - run.start >= 0.02 {
        measured += 1
        if share(run.start, run.end) < 0.2 { overSilence += 1 }
        if share(refine(run), run.end) < 0.2 { overSilenceRefined += 1 }
        let f0 = frame(run.start), f1 = frame(run.end)
        if pauses.contains(where: { f0 < $0.0 - 5 && f1 > $0.1 + 5 && $0.1 - $0.0 >= 25 }) { bridging += 1 }
    }
    // the sound onset after each pause (≥ 150 ms) vs the run that starts nearest to it
    for p in pauses where p.1 < loud.count - 5 {
        let onset = r.start + Double(p.1) / 100
        if let run = sounding.min(by: { abs($0.start - onset) < abs($1.start - onset) }), abs(run.start - onset) < 0.8 { onsetErrors.append(run.start - onset) }
        if let run = sounding.min(by: { abs(refine($0) - onset) < abs(refine($1) - onset) }), abs(refine(run) - onset) < 0.8 { onsetRefined.append(refine(run) - onset) }
    }
    if let first = loud.firstIndex(of: true), let run = sounding.first {
        firstErrors.append(run.start - (r.start + Double(first) / 100)); firstRefined.append(refine(run) - (r.start + Double(first) / 100))
    }
    if let last = loud.lastIndex(of: true), let run = sounding.last { lastErrors.append(run.end - (r.start + Double(last + 2) / 100)) }
}
func stats(_ v: [Double]) -> String {
    guard !v.isEmpty else { return "n/a" }
    let abs = v.map { Swift.abs($0) }
    return String(format: "n=%d median %+.0f ms, |err| median %.0f ms, p90 %.0f ms, max %.0f ms; early > 150 ms: %d", v.count, percentile(v, 0.5) * 1000,
                  percentile(abs, 0.5) * 1000, percentile(abs, 0.9) * 1000, (abs.max() ?? 0) * 1000, v.filter { $0 < -0.15 }.count)
}
print("\n== against the audio (energy, 10 ms frames; punctuation left out)")
print("   runs mostly over silence (<20 % loud frames): \(overSilence)/\(measured), refined \(overSilenceRefined)/\(measured)")
print("   runs bridging a pause of ≥ 250 ms: \(bridging)/\(measured)")
print("   first run start − first loud frame:   " + stats(firstErrors))
print("                              refined:   " + stats(firstRefined))
print("   last run end − last loud frame:       " + stats(lastErrors))
print("   run start − onset after a pause:      " + stats(onsetErrors))
print("                              refined:   " + stats(onsetRefined))

if let truthPath = option("--truth"), let data = FileManager.default.contents(atPath: truthPath),
   let truth = try? JSONDecoder().decode([Run].self, from: data) {
    // Each truth word: the run of its first character nearest its start (within 1 s).
    let sounding = runs.filter { !isMark($0) }
    var errors: [Double] = [], refinedErrors: [Double] = [], endErrors: [Double] = [], found = 0
    for w in truth {
        let first = String(w.text.prefix(1)), last = String(w.text.suffix(1))
        if let run = sounding.filter({ $0.text.hasPrefix(first) && abs($0.start - w.start) < 1 }).min(by: { abs($0.start - w.start) < abs($1.start - w.start) }) {
            found += 1; errors.append(run.start - w.start); refinedErrors.append((refined["\(run.start)|\(run.text)"] ?? run.start) - w.start)
        }
        if let run = sounding.filter({ $0.text.hasSuffix(last) && abs($0.end - w.end) < 1 }).min(by: { abs($0.end - w.end) < abs($1.end - w.end) }) {
            endErrors.append(run.end - w.end)
        }
    }
    print("\n== against ground truth (\(truth.count) words, \(found) matched by first character)")
    print("   word start:         " + stats(errors))
    print("   word start refined: " + stats(refinedErrors))
    print("   word end:           " + stats(endErrors))
}

print("\n== timeline (absolute seconds)")
for r in results {
    print(String(format: "[%6.2f +%.2f] asr %.2f s  %@", r.start, r.duration, r.timedSeconds, r.timed))
    print("   " + r.runs.map { String(format: "%@[%.2f–%.2f]", $0.text, $0.start, $0.end) }.joined(separator: " "))
}

if let jsonPath = option("--json") {
    var out = results
    for i in out.indices { for j in out[i].runs.indices { let r = out[i].runs[j]; out[i].runs[j].onset = refined["\(r.start)|\(r.text)"] ?? r.start } }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
    try enc.encode(out).write(to: URL(fileURLWithPath: jsonPath))
}
if let assPath = option("--ass") {
    // One event per chunk, shown from its first run to its last; \k reveals run by run in time.
    func ts(_ t: Double) -> String { let cs = Int((t * 100).rounded()); return String(format: "%d:%02d:%02d.%02d", cs / 360000, cs / 6000 % 60, cs / 100 % 60, cs % 100) }
    var ass = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1280
        PlayResY: 360

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: K,Hiragino Sans,44,&H00FFFFFF,&HFF000000,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,3,0,2,40,40,40,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
    for r in results where !r.runs.isEmpty {
        let begin = r.runs[0].start
        var cursor = begin, text = ""
        for run in r.runs {
            let gap = Int(((run.start - cursor) * 100).rounded())
            if gap > 0 { text += "{\\k\(gap)}" }
            text += "{\\k\(max(1, Int(((run.end - run.start) * 100).rounded())))}" + run.text
            cursor = run.end
        }
        ass += "Dialogue: 0,\(ts(begin)),\(ts(cursor + 1.0)),K,,0,0,0,,\(text)\n"
    }
    try ass.write(toFile: assPath, atomically: true, encoding: .utf8)
    print("\nwrote \(assPath)")
}

/// The first recognizer of a process loads the model: do that before anything is timed.
enum SpeechEngineWarmup {
    static func run() async throws {
        try await AppleSpeechEngine().prepare()
        _ = try await recognize([Float](repeating: 0, count: 16_000), timed: false)
    }
}
