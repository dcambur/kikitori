import FluidAudio
import Foundation
import os

/// Says who is speaking when, for a whole session: fed the same audio as the chunker, asked
/// for the speakers over a chunk once it is recognized.
public protocol SpeakerTracking: Sendable {
    /// `samples` (16 kHz mono) starting at `time` in the caller's clock. Audio that doesn't follow
    /// on from the last piece (a seek, a pause) starts a new stretch; speakers stay the same.
    func append(_ samples: [Float], at time: Double) async
    /// Who spoke over `from..<to` (caller's clock), once the diarizer has run on it (settled or
    /// tentative frames), or after a short wait with whatever it has.
    func frames(from: Double, to: Double) async -> SpeakerFrames
    /// No more audio for now (end of a file, a pause): chunks waiting for the diarizer take its
    /// tentative answer instead. Audio appended later carries on with the same speakers.
    func finish() async
    /// Other audio from here on (another video): forget the voices heard so far.
    func reset() async
}

/// A tracker on a clock `offset` seconds behind its own. A live pipeline's clock starts at 0 on
/// every run (after each pause), while its tracker lasts the whole session: shifted by each run's
/// start, the tracker's times keep increasing, so audio from before a pause never stands in for
/// audio after it.
public struct ShiftedSpeakerTracker: SpeakerTracking {
    public let inner: any SpeakerTracking
    public let offset: Double

    public init(_ inner: any SpeakerTracking, by offset: Double) { self.inner = inner; self.offset = offset }

    public func append(_ samples: [Float], at time: Double) async { await inner.append(samples, at: time + offset) }
    public func frames(from: Double, to: Double) async -> SpeakerFrames {
        var f = await inner.frames(from: from + offset, to: to + offset)
        for k in f.frames.indices { f.frames[k].start -= offset }
        return f
    }
    public func finish() async { await inner.finish() }
    public func reset() async { await inner.reset() }
}

/// A tracker that loads in the background: until the model is ready (a download of ~230 MB
/// the first time, a few seconds after that), audio goes unlabelled. `onLoad` gets the names of
/// enrolled voices by slot; a failed load leaves labels off (logged).
public actor DeferredSpeakerTracker: SpeakerTracking {
    var inner: SpeakerTracker?

    public init(voices: [(name: String, samples: [Float])] = [], onLoad: @escaping @Sendable ([Int: String]) -> Void) {
        Task { [weak self] in
            do {
                let (tracker, names) = try await SpeakerTracker.load(voices: voices)
                await self?.loaded(tracker)
                onLoad(names)
            } catch {
                Logger(subsystem: "app.kikitori", category: "speakers").error("speaker labels off: \(error, privacy: .public)")
            }
        }
    }

    private func loaded(_ tracker: SpeakerTracker) { inner = tracker }

    public func append(_ samples: [Float], at time: Double) async { await inner?.append(samples, at: time) }
    public func frames(from: Double, to: Double) async -> SpeakerFrames {
        await inner?.frames(from: from, to: to) ?? SpeakerFrames(frames: [])
    }
    public func finish() async { await inner?.finish() }
    public func reset() async { await inner?.reset() }
    /// See `SpeakerTracker.voice(slot:)`.
    public func voice(slot: Int) async -> [Float] { await inner?.voice(slot: slot) ?? [] }
}

/// Streaming Sortformer (FluidAudio, Core ML): four speaker slots that stay the same for the
/// whole session, numbered in the order the voices first speak. Its answer for a stretch of audio
/// settles ~1 s after the stretch (0.48 s steps plus 0.56 s of look-ahead); before that it has a
/// tentative answer, which labelled characters just as well (docs/design/speaker-labels.md §5).
/// So `frames` waits only until the diarizer has run on the chunk, at most `maxWait` seconds.
public actor SpeakerTracker: SpeakerTracking {
    /// The FluidAudio diarizer is a class with its own lock; only this actor touches it.
    final class Box: @unchecked Sendable { let diarizer: SortformerDiarizer; init(_ d: SortformerDiarizer) { diarizer = d } }

    struct Span { var diar: Double; var caller: Double; var length: Double }

    static let rate = 16_000.0
    let box: Box
    let frameLength: Double
    let slots: Int
    /// Longest wall time `frames` waits for the diarizer to reach the end of a chunk.
    public var maxWait = 0.5
    /// Settled frames kept (and audio for voice samples): 10 minutes.
    let keepFrames = 7_500

    var spans: [Span] = []
    var nextCaller: Double?
    var fed = 0
    /// Settled frames, the first being frame `firstFrame` of the diarizer's clock.
    var settled: [[Float]] = []
    var firstFrame = 0
    var tentative: [[Float]] = []
    /// Since `finish`, no more audio is coming: `frames` doesn't wait.
    var draining = false
    /// `frames` calls waiting for the diarizer to reach a time (caller's clock).
    var waiters: [UUID: (until: Double, resume: CheckedContinuation<Void, Never>)] = [:]
    /// Recent audio (diarizer clock), for voice samples.
    var recent: [Float] = []
    var recentStart = 0
    /// Per slot, the newest audio where only that voice was speaking (up to `voiceSeconds`).
    var solo: [Int: [Float]] = [:]
    static let voiceSeconds = 15.0
    /// Seconds spent in the diarizer, for measuring its cost.
    public private(set) var busySeconds = 0.0

    /// Known voices, put back in their slots after a reset.
    let voices: [(name: String, samples: [Float])]

    init(box: Box, voices: [(name: String, samples: [Float])]) {
        self.box = box
        self.voices = voices
        frameLength = Double(box.diarizer.config.frameDurationSeconds)
        slots = box.diarizer.config.numSpeakers
    }

    /// Downloads the model (~250 MB, once) and loads it. `voices` are known speakers to put in slots
    /// first: their names come back with the slots they got.
    /// FluidAudio's Sortformer models (docs/design/speaker-labels.md §6.4): `fast` and `balanced`
    /// settle ~1 s after the audio, `efficient` ~2.6 s, `highContext` ~30 s.
    public enum Variant: String, Sendable, CaseIterable {
        case fast, balanced, efficient, highContext
        var config: SortformerConfig {
            switch self {
            case .fast: .default
            case .balanced: .balancedV2_1
            case .efficient: .efficientV2_1
            case .highContext: .highContextV2_1
            }
        }
    }

    public static func load(voices: [(name: String, samples: [Float])] = [], variant: Variant = .fast) async throws -> (SpeakerTracker, [Int: String]) {
        let config = variant.config
        // One load at a time (a player session has two trackers, and a quick Stop and Start adds
        // more): loads at once would download the same files into the same place, and a clash
        // there makes FluidAudio delete its cache. Later loads find the files there.
        await loading.enter()
        let models: SortformerModels
        do { models = try await SortformerModels.loadFromHuggingFace(config: config) } catch { await loading.leave(); throw error }
        await loading.leave()
        let diarizer = SortformerDiarizer(config: config, timelineConfig: .init(
            numSpeakers: config.numSpeakers, frameDurationSeconds: config.frameDurationSeconds,
            maxStoredFrames: 7_500, storeSegments: false))
        diarizer.initialize(models: models)
        let box = Box(diarizer)
        let names = enroll(voices, in: box)
        return (SpeakerTracker(box: box, voices: voices), names)
    }

    private static let loading = Gate()

    /// Lets one caller through at a time, in order.
    actor Gate {
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func enter() async {
            if busy { await withCheckedContinuation { waiting.append($0) } } else { busy = true }
        }
        func leave() {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
    }

    static func enroll(_ voices: [(name: String, samples: [Float])], in box: Box) -> [Int: String] {
        var names: [Int: String] = [:]
        for voice in voices where !voice.samples.isEmpty {
            if let speaker = try? box.diarizer.enrollSpeaker(withAudio: voice.samples, named: voice.name) { names[speaker.index] = voice.name }
        }
        return names
    }

    public func reset() async {
        box.diarizer.reset()
        draining = false
        _ = Self.enroll(voices, in: box)
        spans = []; nextCaller = nil; fed = 0
        settled = []; firstFrame = 0; tentative = []
        recent = []; recentStart = 0; solo = [:]
        for (_, w) in waiters { w.resume.resume() }
        waiters = [:]
    }

    public func append(_ samples: [Float], at time: Double) async {
        guard !samples.isEmpty else { return }
        draining = false
        // Muted input (all zeros, while the built-in player shows synced subtitles) isn't worth a run.
        guard samples.contains(where: { $0 != 0 }) else { nextCaller = nil; return }
        let seconds = Double(samples.count) / Self.rate
        if let next = nextCaller, abs(next - time) < 0.01, !spans.isEmpty {
            spans[spans.count - 1].length += seconds
        } else {
            spans.append(Span(diar: Double(fed) / Self.rate, caller: time, length: seconds))
            if spans.count > 200 { spans.removeFirst(spans.count - 200) }
        }
        nextCaller = time + seconds
        fed += samples.count
        recent += samples
        let keepAudio = Int(30 * Self.rate)
        if recent.count > keepAudio * 2 { recentStart += recent.count - keepAudio; recent.removeFirst(recent.count - keepAudio) }
        let began = Date()
        let update = try? box.diarizer.process(samples: samples)
        busySeconds += Date().timeIntervalSince(began)
        if let update { take(update.chunkResult) }
    }

    public func finish() async {
        draining = true
        for (_, w) in waiters { w.resume.resume() }
        waiters = [:]
    }

    public func frames(from: Double, to: Double) async -> SpeakerFrames {
        if !draining, !ready(to) {
            let id = UUID()
            let wait = maxWait
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters[id] = (to, c)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    await self?.timeOut(id)
                }
            }
        }
        // The newest audio for a time wins (the same times come again after a seek back, or in
        // a new run of a pipeline whose clock restarts at 0).
        var out: [SpeakerFrames.Frame] = [], covered: [(Double, Double)] = []
        for s in spans.reversed() {
            let a = max(from, s.caller), b = min(to, s.caller + s.length)
            guard b > a else { continue }
            let first = Int(((s.diar + a - s.caller) / frameLength).rounded(.down))
            let last = Int(((s.diar + b - s.caller) / frameLength).rounded(.up))
            var lo = Double.infinity, hi = -Double.infinity
            for k in first..<last {
                let start = s.caller + Double(k) * frameLength - s.diar
                guard !covered.contains(where: { start > $0.0 - frameLength / 2 && start < $0.1 }), let probs = probs(at: k) else { continue }
                out.append(.init(start: start, probs: probs))
                lo = min(lo, start); hi = max(hi, start + frameLength)
            }
            if lo < hi { covered.append((lo, hi)) }
        }
        return SpeakerFrames(frames: out.sorted { $0.start < $1.start }, length: frameLength)
    }

    /// For tests and the CLI: how long `frames` may wait.
    public func setMaxWait(_ seconds: Double) { maxWait = seconds }

    /// Up to 15 s of recent audio where only this slot's voice was heard: a sample to remember it by.
    public func voice(slot: Int) -> [Float] { solo[slot] ?? [] }

    /// The diarizer has run on the audio up to `time` (caller's clock): its frames are there,
    /// settled or tentative. A time in skipped audio (muted, all zeros) counts from the end of
    /// the audio before it, once later audio has come. Audio that never comes times out.
    func ready(_ time: Double) -> Bool {
        let at: Double
        if let s = spans.last(where: { $0.caller < time && time <= $0.caller + $0.length + 0.001 }) {
            at = s.diar + (time - s.caller)
        } else if spans.contains(where: { $0.caller >= time }), let before = spans.last(where: { $0.caller < time }) {
            at = before.diar + before.length
        } else {
            return false
        }
        return Double(firstFrame + settled.count + tentative.count) * frameLength >= at - 0.001
    }

    private func probs(at frame: Int) -> [Float]? {
        let i = frame - firstFrame
        if i >= 0, i < settled.count { return settled[i] }
        let t = i - settled.count
        return t >= 0 && t < tentative.count ? tentative[t] : nil
    }

    private func timeOut(_ id: UUID) { waiters.removeValue(forKey: id)?.resume.resume() }

    private func take(_ chunk: DiarizerChunkResult) {
        func rows(_ flat: [Float], _ count: Int) -> [[Float]] {
            (0..<count).map { f in Array(flat[f * slots..<min(flat.count, (f + 1) * slots)]) }
        }
        receive(settled: rows(chunk.finalizedPredictions, chunk.finalizedFrameCount),
                tentative: rows(chunk.tentativePredictions, chunk.tentativeFrameCount), from: chunk.startFrame)
    }

    /// New frames from the diarizer (one row of slot probabilities each): settled ones from frame
    /// `first` on, and the tentative ones after them.
    func receive(settled new: [[Float]], tentative: [[Float]], from first: Int) {
        if settled.isEmpty { firstFrame = first }
        let startIndex = firstFrame + settled.count
        settled += new
        self.tentative = tentative
        collectSolo(new, from: startIndex)
        if settled.count > keepFrames * 2 { firstFrame += settled.count - keepFrames; settled.removeFirst(settled.count - keepFrames) }
        for (id, w) in waiters where ready(w.until) { waiters[id] = nil; w.resume.resume() }
    }

    /// A tracker without a model, for tests: frames come only from `receive`.
    static func unloaded() -> SpeakerTracker {
        SpeakerTracker(box: Box(SortformerDiarizer(config: .default)), voices: [])
    }

    /// Frames where one voice is clearly alone go into that voice's sample.
    private func collectSolo(_ frames: [[Float]], from first: Int) {
        let size = Int(frameLength * Self.rate), cap = Int(Self.voiceSeconds * Self.rate)
        for (k, p) in frames.enumerated() {
            guard let top = p.indices.max(by: { p[$0] < p[$1] }), p[top] > 0.8,
                  p.indices.allSatisfy({ $0 == top || p[$0] < 0.2 }) else { continue }
            let at = (first + k) * size - recentStart
            guard at >= 0, at + size <= recent.count else { continue }
            solo[top, default: []] += recent[at..<at + size]
            if solo[top]!.count > cap { solo[top]!.removeFirst(solo[top]!.count - cap) }
        }
    }
}
