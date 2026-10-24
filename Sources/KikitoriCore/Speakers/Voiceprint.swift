import CryptoKit
import FluidAudio
import Foundation

/// What is remembered of a voice: a speaker embedding (WeSpeaker, 256 numbers, unit length),
/// never audio. `model` names the model that made it: a print from another model can't be
/// compared and is treated as missing.
public struct Voiceprint: Codable, Sendable, Equatable {
    public var model: String
    public var vector: [Float]

    public init(model: String, vector: [Float]) { self.model = model; self.vector = vector }

    /// Cosine similarity (−1…1); 0 when the two come from different models.
    public func similarity(_ other: Voiceprint) -> Float {
        guard model == other.model, vector.count == other.vector.count, !vector.isEmpty else { return 0 }
        var dot: Float = 0, a: Float = 0, b: Float = 0
        for i in vector.indices { dot += vector[i] * other.vector[i]; a += vector[i] * vector[i]; b += other.vector[i] * other.vector[i] }
        return a > 0 && b > 0 ? dot / (a * b).squareRoot() : 0
    }

    /// The print of a voice heard in several stretches: their mean, back to unit length.
    static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let n = vectors.first?.count else { return [] }
        var sum = [Float](repeating: 0, count: n)
        for v in vectors where v.count == n { for i in 0..<n { sum[i] += v[i] } }
        let length = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? sum.map { $0 / length } : sum
    }
}

/// Makes voiceprints with FluidAudio's WeSpeaker model (~22 MB, downloaded once with the
/// segmentation model it ships with).
public actor VoiceprintMaker {
    /// FluidAudio's diarizer class with its own models; only this actor touches it.
    final class Box: @unchecked Sendable { let manager: DiarizerManager; init(_ m: DiarizerManager) { manager = m } }

    let box: Box
    /// The model the prints are made with: its name and a hash of its files.
    public nonisolated let model: String
    /// Shortest audio worth a print (seconds).
    public static let minSeconds = 3.0

    init(box: Box, model: String) { self.box = box; self.model = model }

    /// Whether the model is on this Mac already (`load` won't download).
    public static var isDownloaded: Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: DiarizerModels.defaultModelsDirectory().path)) ?? []
        return files.contains { $0.hasPrefix("wespeaker") && $0.hasSuffix(".mlmodelc") }
    }

    public static func load() async throws -> VoiceprintMaker {
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        return VoiceprintMaker(box: Box(manager), model: "wespeaker_v2 " + modelHash())
    }

    /// A short hash of the model's program and weights: the model has no version of its own, and
    /// a different model under the same name must not match old prints.
    static func modelHash() -> String {
        let folder = DiarizerModels.defaultModelsDirectory().appending(path: "wespeaker_v2.mlmodelc")
        var hash = SHA256()
        for part in ["model.mil", "weights/weight.bin"] {
            if let data = try? Data(contentsOf: folder.appending(path: part), options: .mappedIfSafe) { hash.update(data: data) }
        }
        return hash.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The print of `samples` (16 kHz mono, one voice), or nil for less than `minSeconds`. The
    /// model takes 10 s at a time: longer audio is printed in 10 s pieces and averaged.
    public func voiceprint(_ samples: [Float]) throws -> Voiceprint? {
        let rate = 16_000, window = 10 * rate, least = Int(Self.minSeconds * Double(rate))
        guard samples.count >= least else { return nil }
        var vectors: [[Float]] = []
        for start in stride(from: 0, to: samples.count, by: window) {
            let piece = samples[start..<min(start + window, samples.count)]
            guard piece.count >= least || vectors.isEmpty else { continue }
            vectors.append(try box.manager.extractSpeakerEmbedding(from: Array(piece)))
        }
        return Voiceprint(model: model, vector: Voiceprint.mean(vectors))
    }
}

/// Names voices heard in a session from remembered voiceprints. A voice gets a name when its
/// print is close enough to that name's (`threshold`) and clearly closer than to any other
/// remembered name (`margin`); each name goes to one voice at most, the closest.
/// The defaults come from stream audio: docs/design/speaker-labels.md §6.3.
public enum VoiceMatcher {
    public static let threshold: Float = 0.65
    public static let margin: Float = 0.1

    public static func names(heard: [Int: Voiceprint], known: [String: Voiceprint],
                             threshold: Float = threshold, margin: Float = margin) -> [Int: String] {
        var candidates: [(slot: Int, name: String, score: Float)] = []
        for (slot, print) in heard {
            let scores = known.map { (name: $0.key, score: print.similarity($0.value)) }.sorted { $0.score > $1.score }
            guard let best = scores.first, best.score >= threshold else { continue }
            if scores.count > 1, best.score - scores[1].score < margin { continue }
            candidates.append((slot, best.name, best.score))
        }
        var out: [Int: String] = [:], taken = Set<String>()
        for c in candidates.sorted(by: { $0.score > $1.score }) where !taken.contains(c.name) && out[c.slot] == nil {
            out[c.slot] = c.name
            taken.insert(c.name)
        }
        return out
    }
}

/// Voiceprints on disk, one JSON file per profile (`<directory>/<profile id>.json`).
public struct VoiceStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    func url(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }

    public func load(_ id: UUID) -> Voiceprint? {
        (try? Data(contentsOf: url(id))).flatMap { try? JSONDecoder().decode(Voiceprint.self, from: $0) }
    }

    public func save(_ print: Voiceprint, for id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(print).write(to: url(id), options: .atomic)
    }

    public func forget(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }

    /// Files from before voiceprints: raw audio (`<profile id>.f32`, 16 kHz Float32). Each becomes
    /// a voiceprint, then the audio is deleted. With no `maker` (the model couldn't load), or audio
    /// that can't be printed, the audio is deleted anyway: no audio stays on disk; the voice can be
    /// remembered again. Returns the profiles that got a voiceprint.
    @discardableResult
    public func migrateAudio(with maker: VoiceprintMaker?) async -> [UUID] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var migrated: [UUID] = []
        for file in files where file.pathExtension == "f32" {
            if let maker, let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
               let data = try? Data(contentsOf: file) {
                let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                if let print = try? await maker.voiceprint(samples), (try? save(print, for: id)) != nil { migrated.append(id) }
            }
            try? FileManager.default.removeItem(at: file)
        }
        return migrated
    }
}

/// Puts remembered names on a session's voices: from time to time, each voice not named yet
/// that has enough audio of its own (`SpeakerTracker.voice(slot:)`, kept in memory only) is
/// printed and matched against the remembered voiceprints.
public actor SpeakerNamer {
    let maker: VoiceprintMaker
    let known: [String: Voiceprint]
    var named: [Int: String] = [:]
    /// Audio a voice needs before it is matched (seconds).
    public static let minSeconds = 5.0

    public init(maker: VoiceprintMaker, known: [String: Voiceprint]) { self.maker = maker; self.known = known }

    /// Names found this time, by slot (each slot and each name once per session).
    public func check(slots: Int = 4, voice: @Sendable (Int) async -> [Float]) async -> [Int: String] {
        guard !known.isEmpty else { return [:] }
        var heard: [Int: Voiceprint] = [:]
        for slot in 0..<slots where named[slot] == nil {
            let samples = await voice(slot)
            guard Double(samples.count) >= Self.minSeconds * 16_000, let print = try? await maker.voiceprint(samples) else { continue }
            heard[slot] = print
        }
        let open = known.filter { !named.values.contains($0.key) }
        let found = VoiceMatcher.names(heard: heard, known: open)
        named.merge(found) { a, _ in a }
        return found
    }
}
