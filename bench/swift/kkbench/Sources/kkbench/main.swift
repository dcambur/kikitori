// kkbench: run one on-device Japanese ASR engine over a manifest.
// usage: kkbench <engine> <manifest.jsonl> <out.jsonl>
// engines: parakeet-ja | cohere-ja | nemotron-ja | whisperkit-turbo
//
// Manifest rows: {"id", "path", ...} (16 kHz mono WAV). Output rows: {"id", "hyp", "sec"}, with
// sec = processing time for that clip (audio already in memory, model load excluded). Rows that
// carry "clip" (bench/vtcc.py segment manifests) also get "clip", "dur" and "variant" (= the
// manifest's folder name), and no summary line; otherwise a final
// {"summary": true, "load_s", "peak_gb", "loadavg"} line is written for score.py.
//
// Experiment knobs (env, defaults = benchmark settings): KKBENCH_NEMO_LANG (ja-JP),
// KKBENCH_NEMO_CHUNK_MS (2240), KKBENCH_NEMO_LEAD_MS / KKBENCH_NEMO_PAD_MS (0, silence before /
// after each clip), KKBENCH_WK_NO_SPEECH (0.6), KKBENCH_WK_FIRST_LOGPROB (off); "off" = nil.
// build: swift build -c release   (from bench/swift/kkbench)

import CoreML
import Darwin
import FluidAudio
import Foundation
import WhisperKit

// MARK: engines

protocol Engine {
    /// Download if needed (not timed), then load (timed by the caller).
    mutating func prepare() async throws
    mutating func load() async throws
    /// Transcribe 16 kHz mono samples.
    mutating func transcribe(_ samples: [Float]) async throws -> String
    /// Engine-specific notes printed at the end (e.g. truncation counts).
    func notes() -> String
}

extension Engine {
    func notes() -> String { "" }
}

struct ParakeetJa: Engine {
    var manager: AsrManager?
    var dir: URL?

    mutating func prepare() async throws {
        dir = try await AsrModels.download(version: .tdtJa)
    }

    mutating func load() async throws {
        let models = try await AsrModels.load(from: dir!, version: .tdtJa)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
    }

    mutating func transcribe(_ samples: [Float]) async throws -> String {
        var state = try TdtDecoderState(decoderLayers: 2)
        return try await manager!.transcribe(samples, decoderState: &state).text
    }
}

struct CohereJa: Engine {
    var models: CoherePipeline.LoadedModels?
    let pipeline = CoherePipeline()
    var dir: URL?
    var truncated = 0  // calls that used the whole decoder token budget
    var calls = 0

    mutating func prepare() async throws {
        let base = MLModelConfigurationUtils.defaultModelsDirectory()
        let target = base.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName)
        let needed = [
            ModelNames.CohereTranscribe.encoderCompiledFile,
            ModelNames.CohereTranscribe.decoderCacheExternalV2CompiledFile,
            ModelNames.CohereTranscribe.vocab,
        ]
        let missing = { needed.filter { !FileManager.default.fileExists(atPath: target.appendingPathComponent($0).path) } }
        if !missing().isEmpty {
            try await ModelHub.download(.cohereTranscribeCoreml, to: base)
        }
        guard missing().isEmpty else { throw Failure("cohere model incomplete at \(target.path): \(missing())") }
        dir = target
    }

    mutating func load() async throws {
        models = try await CoherePipeline.loadModels(encoderDir: dir!, decoderDir: dir!, vocabDir: dir!)
    }

    mutating func transcribe(_ samples: [Float]) async throws -> String {
        // One call covers up to CohereAsrConfig.maxAudioSeconds (35 s); longer audio would be
        // silently truncated by transcribe(), so route those through transcribeLong.
        let r: CoherePipeline.TranscriptionResult
        if samples.count <= CohereAsrConfig.maxSamples {
            r = try await pipeline.transcribe(audio: samples, models: models!, language: .japanese)
        } else {
            r = try await pipeline.transcribeLong(audio: samples, models: models!, language: .japanese)
        }
        calls += 1
        let budget = CohereAsrConfig.maxSeqLen - CohereAsrConfig.Language.japanese.promptSequence.count
        if r.tokenIds.count >= budget { truncated += 1 }
        return r.text
    }

    func notes() -> String {
        let budget = CohereAsrConfig.maxSeqLen - CohereAsrConfig.Language.japanese.promptSequence.count
        return "cohere: \(truncated)/\(calls) calls hit the \(budget)-token decoder budget (likely truncated)"
    }
}

struct NemotronJa: Engine {
    // Experiment knobs (defaults are what the benchmark uses).
    static let env = ProcessInfo.processInfo.environment
    static let language = env["KKBENCH_NEMO_LANG"] ?? "ja-JP"
    static let chunkMs = Int(env["KKBENCH_NEMO_CHUNK_MS"] ?? "") ?? 2240
    static let padSamples = (Int(env["KKBENCH_NEMO_PAD_MS"] ?? "") ?? 0) * 16
    static let leadSamples = (Int(env["KKBENCH_NEMO_LEAD_MS"] ?? "") ?? 0) * 16
    var manager = StreamingNemotronMultilingualAsrManager()
    var dir: URL?
    var detected: [String: Int] = [:]

    mutating func prepare() async throws {
        dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: Self.language, chunkMs: Self.chunkMs)
        // Japanese must be in the model's prompt dictionary, else we would silently run "auto".
        let meta = try NemotronMultilingualStreamingConfig(
            from: dir!.appendingPathComponent(ModelNames.NemotronMultilingualStreaming.metadata))
        let auto = meta.promptId(forLanguage: "auto")
        let ja = meta.promptId(forLanguage: Self.language)
        print("nemotron: \(Self.language) @ \(Self.chunkMs) ms, pad \(Self.padSamples / 16) ms, prompt id \(ja) (auto=\(auto))")
        guard ja != auto || Self.language == "auto" else {
            throw Failure("\(Self.language) is not in this Nemotron model's prompt dictionary")
        }
    }

    mutating func load() async throws {
        try await manager.loadModels(from: dir!)
        await manager.setLanguage(Self.language)
    }

    mutating func transcribe(_ samples: [Float]) async throws -> String {
        if Self.leadSamples > 0 { _ = try await manager.process(samples: [Float](repeating: 0, count: Self.leadSamples)) }
        _ = try await manager.process(samples: samples)
        if Self.padSamples > 0 { _ = try await manager.process(samples: [Float](repeating: 0, count: Self.padSamples)) }
        let text = try await manager.finish()
        detected[await manager.detectedLanguage() ?? "none", default: 0] += 1
        await manager.reset()
        return text
    }

    func notes() -> String { "nemotron: detected language tags \(detected)" }
}

struct WhisperKitTurbo: Engine {
    static let variant = "large-v3-v20240930"  // openai_whisper-large-v3-v20240930 (full precision)
    var pipe: WhisperKit?
    var folder: URL?
    // Experiment knobs: KKBENCH_WK_NO_SPEECH / KKBENCH_WK_FIRST_LOGPROB = a number or "off".
    // firstTokenLogProbThreshold is a WhisperKit-only gate (default -1.5, not in OpenAI/MLX
    // Whisper); on stream audio it emptied 12/288 real speech segments, so it is off here.
    static func knob(_ name: String, _ def: Float?) -> Float? {
        guard let v = ProcessInfo.processInfo.environment[name] else { return def }
        return v == "off" ? nil : Float(v)
    }
    let options = DecodingOptions(
        task: .transcribe,
        language: "ja",
        temperature: 0.0,
        temperatureIncrementOnFallback: 0.2,
        temperatureFallbackCount: 5,  // 0.0, 0.2, ... 1.0 as in bench/engines.py MLX_OPTS
        usePrefillPrompt: true,
        detectLanguage: false,
        skipSpecialTokens: true,
        withoutTimestamps: true,
        compressionRatioThreshold: 2.4,
        logProbThreshold: -1.0,
        firstTokenLogProbThreshold: knob("KKBENCH_WK_FIRST_LOGPROB", nil),
        noSpeechThreshold: knob("KKBENCH_WK_NO_SPEECH", 0.6))

    mutating func prepare() async throws {
        folder = try await WhisperKit.download(variant: Self.variant)
    }

    mutating func load() async throws {
        let config = WhisperKitConfig(
            modelFolder: folder!.path, verbose: false, logLevel: .error, prewarm: false, load: true,
            download: false)
        pipe = try await WhisperKit(config)
    }

    mutating func transcribe(_ samples: [Float]) async throws -> String {
        let results = try await pipe!.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined()
    }
}

// MARK: helpers

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func peakFootprintGB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1e9 : 0
}

func loadavg() -> [Double] {
    var l = [Double](repeating: 0, count: 3)
    _ = getloadavg(&l, 3)
    return l
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func round4(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }

func jsonLine(_ obj: [String: Any]) throws -> Data {
    var d = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
    d.append(0x0A)
    return d
}

// MARK: main

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count == 4 else {
    print("usage: kkbench <parakeet-ja|cohere-ja|nemotron-ja|whisperkit-turbo> <manifest.jsonl> <out.jsonl>")
    exit(2)
}
let engineName = args[1]
let manifestURL = URL(fileURLWithPath: args[2])
let outURL = URL(fileURLWithPath: args[3])

var engine: any Engine
switch engineName {
case "parakeet-ja": engine = ParakeetJa()
case "cohere-ja": engine = CohereJa()
case "nemotron-ja": engine = NemotronJa()
case "whisperkit-turbo": engine = WhisperKitTurbo()
default:
    print("unknown engine \(engineName)")
    exit(2)
}

let rows: [[String: Any]] = try String(contentsOf: manifestURL, encoding: .utf8)
    .split(separator: "\n")
    .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
let segmentMode = rows.first?["clip"] != nil
let variant = manifestURL.deletingLastPathComponent().lastPathComponent

print("\(engineName): \(rows.count) clips from \(manifestURL.path)")
var t = now()
try await engine.prepare()
print(String(format: "model files ready in %.1f s", now() - t))
t = now()
try await engine.load()
let loadSec = now() - t
print(String(format: "model load: %.2f s", loadSec))

t = now()
let warm = try await engine.transcribe([Float](repeating: 0, count: 16_000))
print(String(format: "warm-up on 1 s silence: %.2f s -> %@", now() - t, "\"\(warm)\""))

let converter = AudioConverter()
try FileManager.default.createDirectory(
    at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
FileManager.default.createFile(atPath: outURL.path, contents: nil)
let out = try FileHandle(forWritingTo: outURL)
var totalSec = 0.0
var totalDur = 0.0
var empty = 0
for (i, row) in rows.enumerated() {
    let id = row["id"] as! String
    let samples = try converter.resampleAudioFile(path: row["path"] as! String)
    let start = now()
    let hyp = try await engine.transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
    let sec = now() - start
    totalSec += sec
    totalDur += Double(samples.count) / 16_000
    if hyp.isEmpty { empty += 1 }
    var line: [String: Any] = ["id": id, "hyp": hyp, "sec": round4(sec)]
    if segmentMode {
        line["clip"] = row["clip"]
        line["dur"] = row["dur"]
        line["variant"] = variant
    }
    out.write(try jsonLine(line))
    if i % 25 == 0 || i == rows.count - 1 {
        print(String(format: "[%d/%d] %@ %.2fs  %@", i + 1, rows.count, id, sec, hyp))
    }
}
let peak = peakFootprintGB()
if !segmentMode {
    out.write(try jsonLine([
        "summary": true, "load_s": (loadSec * 100).rounded() / 100,
        "peak_gb": (peak * 100).rounded() / 100, "loadavg": loadavg(),
    ]))
}
try out.close()
let note = engine.notes()
if !note.isEmpty { print(note) }
print(String(format: "done: %d clips, %.1f s audio in %.1f s (%.1fx RT), %d empty, peak footprint %.2f GB -> %@",
             rows.count, totalDur, totalSec, totalDur / max(totalSec, 1e-9), empty, peak, outURL.path))
