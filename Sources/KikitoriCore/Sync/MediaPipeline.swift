import Foundation
import os
import Synchronization

/// The built-in player's synced subtitles: the video's audio arrives ahead of playback (decoded
/// from what the site's player has buffered), and this runs the same chunker, recognizer and
/// translator as `LivePipeline` on it in video time, so each chunk's cue is ready before its
/// first character is spoken (docs/design/realtime-sync.md).
///
/// As in unsynced subtitles, the Japanese never waits for Claude: a cue goes out as soon as its
/// chunk is recognized (one Japanese line), and its translation follows as `.translation`. A slow
/// API delays only the English.
///
/// It works from the playhead forward, up to `horizon` seconds ahead: what the viewer skips is
/// never recognized or translated, a seek starts again at the new position, and work already
/// done (seeking back) is not repeated. Chunks the playhead has long passed, or of another video,
/// are dropped before they cost anything.
public struct MediaPipeline<VAD: VoiceActivityDetector>: Sendable {
    public enum Input: Sendable {
        case packet(MediaPacket)
        /// Where the video is. With `process` false, audio is kept but nothing is worked on
        /// (subtitles are not synced right now: a live stream, say).
        case playhead(videoID: String, time: Double, process: Bool)
    }

    public enum Event: Sendable {
        /// A recognized chunk, ready to be shown: its characters and one Japanese line, with its
        /// audio (16 kHz mono) for replay. Its translation follows.
        case cue(Cue, audio: [Float])
        /// The cue's lines as the translator split them, with English; and what the API billed.
        case translation(cue: UUID, lines: [Cue.Line], cost: Double, tokens: Int)
        /// `cost` and `tokens` are what the API billed for an answer that couldn't be used (0 if none).
        case translationFailed(cue: UUID, ClaudeClient.Failure, cost: Double, tokens: Int)
        /// Not sent for translation (no translator, Japanese only right now, or long past).
        case translationSkipped(cue: UUID)
    }

    public var engine: any TimedSpeechEngine
    public var translator: LiveTranslator?
    public var vad: VAD
    public var contextTerms: [String] = []
    /// As `LivePipeline.maxChunk`: the same chunks as unsynced subtitles.
    public var maxChunk = 6.0
    /// How far ahead of the playhead to work.
    public var horizon = 30.0
    /// Chunks ending this long before the playhead are dropped before they cost anything.
    public var staleAfter = 30.0
    /// Audio kept behind the playhead (16 kHz, ~19 MB for 5 minutes): seeking forward and back into
    /// a stretch skipped over finds it still here, since the site won't fetch what it has buffered.
    public var keepBehind = 300.0
    public var shouldTranslate: @Sendable () async -> Bool = { true }

    public init(engine: any TimedSpeechEngine, translator: LiveTranslator?, vad: VAD) {
        self.engine = engine; self.translator = translator; self.vad = vad
    }

    struct Pending: Sendable {
        var videoID: String
        var start: Double
        var samples: [Float]
        var end: Double { start + Double(samples.count) / MediaTimeline.rate }
    }

    struct Heard: Sendable {
        var cue: Cue
        var end: Double
    }

    public func run(_ inputs: AsyncStream<Input>) -> AsyncStream<Event> {
        let (events, emit) = AsyncStream.makeStream(of: Event.self)
        let (chunks, toRecognize) = AsyncStream.makeStream(of: Pending.self)
        let (heard, toTranslate) = AsyncStream.makeStream(of: Heard.self)
        let playhead = Playhead()
        let staleAfter = staleAfter, shouldTranslate = shouldTranslate
        let log = Logger(subsystem: "app.kikitori", category: "sync")
        let cutter = Cutter(vad: vad, maxChunk: maxChunk, horizon: horizon, keep: keepBehind, playhead: playhead) { toRecognize.yield($0) }
        let cut = Task {
            for await input in inputs { await cutter.take(input) }
            toRecognize.finish()
        }
        let recognize = Task { [engine, contextTerms] in
            for await chunk in chunks {
                if playhead.passed(chunk.videoID, chunk.end, by: staleAfter) {
                    log.notice("sync: dropped a chunk at \(chunk.start, format: .fixed(precision: 1)) s before recognition, \(playhead.behind(chunk.end), format: .fixed(precision: 1)) s behind the playhead")
                    continue
                }
                let began = Date()
                let pieces = (try? await engine.transcribeTimed(chunk.samples, context: contextTerms)) ?? []
                let cleaned = TranscriptFilter.clean(pieces)
                guard !cleaned.isEmpty else { continue }
                let chars = OnsetRefiner.refine(cleaned, samples: chunk.samples).shifted(by: chunk.start)
                let cue = Cue(videoID: chunk.videoID, chars: chars, lines: CueAligner.lines([], over: chars))
                emit.yield(.cue(cue, audio: chunk.samples))
                log.notice("sync: cue \(cue.start, format: .fixed(precision: 1))–\(cue.end, format: .fixed(precision: 1)) s, \(playhead.ahead(cue.start), format: .fixed(precision: 1)) s ahead, recognized in \(Date().timeIntervalSince(began), format: .fixed(precision: 2)) s")
                toTranslate.yield(Heard(cue: cue, end: chunk.end))
            }
            toTranslate.finish()
        }
        let translate = Task { [translator] in
            for await h in heard {
                let id = h.cue.id
                // Long past (the translator fell behind, or a seek): its Japanese stays without English.
                if playhead.passed(h.cue.videoID, h.end, by: staleAfter) {
                    log.notice("sync: not translating the cue at \(h.cue.start, format: .fixed(precision: 1)) s, \(playhead.behind(h.end), format: .fixed(precision: 1)) s behind the playhead")
                    emit.yield(.translationSkipped(cue: id))
                    continue
                }
                guard let translator, await shouldTranslate() else { emit.yield(.translationSkipped(cue: id)); continue }
                let began = Date()
                do {
                    let r = try await translator.translate(h.cue.chars.text)
                    // No lines back means fillers or backchannels: the Japanese stays, without English.
                    let lines = r.lines.isEmpty ? h.cue.lines : CueAligner.lines(r.lines, over: h.cue.chars)
                    emit.yield(.translation(cue: id, lines: lines, cost: r.cost, tokens: r.usage.total))
                    log.notice("sync: translated the cue at \(h.cue.start, format: .fixed(precision: 1)) s in \(Date().timeIntervalSince(began), format: .fixed(precision: 2)) s, \(playhead.ahead(h.cue.start), format: .fixed(precision: 1)) s ahead")
                } catch {
                    let (failure, cost, tokens): (ClaudeClient.Failure, Double, Int) = switch error {
                    case let billed as ClaudeClient.BilledFailure: (billed.failure, billed.cost, billed.usage.total)
                    case let failure as ClaudeClient.Failure: (failure, 0, 0)
                    default: (.unexpected(status: 0, "\(error)"), 0, 0)
                    }
                    emit.yield(.translationFailed(cue: id, failure, cost: cost, tokens: tokens))
                    log.error("sync: translation of the cue at \(h.cue.start, format: .fixed(precision: 1)) s failed after \(Date().timeIntervalSince(began), format: .fixed(precision: 1)) s: \(String(describing: failure), privacy: .public)")
                }
            }
        }
        Task {
            _ = await (cut.value, recognize.value, translate.value)
            emit.finish()
        }
        emit.onTermination = { _ in cut.cancel(); recognize.cancel(); translate.cancel() }
        return events
    }
}

/// The latest playhead, for the stages after cutting.
final class Playhead: Sendable {
    private let value = Mutex<(videoID: String, time: Double)?>(nil)
    func set(_ videoID: String, _ time: Double) { value.withLock { $0 = (videoID, time) } }
    /// True for audio of another video, or ending more than `seconds` before the playhead.
    func passed(_ videoID: String, _ end: Double, by seconds: Double) -> Bool {
        value.withLock { v in v.map { $0.videoID != videoID || end < $0.time - seconds } ?? false }
    }
    /// For logs: how far `time` is ahead of the playhead (negative: behind).
    func ahead(_ time: Double) -> Double { value.withLock { v in v.map { time - $0.time } ?? .nan } }
    func behind(_ time: Double) -> Double { -ahead(time) }
}

/// Seconds already worked on, per video: sorted, non-overlapping.
struct Intervals: Sendable, Equatable {
    private(set) var spans: [(Double, Double)] = []

    static func == (a: Intervals, b: Intervals) -> Bool { a.spans.elementsEqual(b.spans) { $0 == $1 } }

    mutating func add(_ a: Double, _ b: Double) {
        guard b > a else { return }
        var lo = a, hi = b
        spans.removeAll { s in
            guard s.0 <= hi + 0.001, s.1 >= lo - 0.001 else { return false }
            lo = min(lo, s.0); hi = max(hi, s.1)
            return true
        }
        spans.insert((lo, hi), at: spans.firstIndex { $0.0 > lo } ?? spans.count)
    }

    /// The first time at or after `t` not worked on.
    func free(from t: Double) -> Double { spans.first { $0.0 <= t + 0.001 && $0.1 > t }?.1 ?? t }

    /// Where the next worked-on stretch after `t` begins.
    func next(after t: Double) -> Double? { spans.first { $0.0 > t + 0.001 }?.0 }
}

/// The cutting stage: keeps the audio by video time and feeds a chunker from the right place.
/// Used by one task only.
final class Cutter<VAD: VoiceActivityDetector>: @unchecked Sendable {
    struct Run {
        var videoID: String
        var start: Double
        var cursor: Double
        /// End of the last chunk it emitted: on a jump, the rest is not done.
        var emitted: Double
        var chunker: Chunker<VAD>
    }

    let vad: VAD, maxChunk: Double, horizon: Double, keep: Double
    let playhead: Playhead
    let emit: (MediaPipeline<VAD>.Pending) -> Void
    var timelines: [String: MediaTimeline] = [:]
    var resamplers: [Int: MediaResampler] = [:]
    var done: [String: Intervals] = [:]
    var run: Run?
    var head: (videoID: String, time: Double, process: Bool)?
    var lastPacketVideo: String?
    let log = Logger(subsystem: "app.kikitori", category: "sync")

    init(vad: VAD, maxChunk: Double, horizon: Double, keep: Double, playhead: Playhead,
         emit: @escaping (MediaPipeline<VAD>.Pending) -> Void) {
        self.vad = vad; self.maxChunk = maxChunk; self.horizon = horizon; self.keep = keep
        self.playhead = playhead; self.emit = emit
    }

    func take(_ input: MediaPipeline<VAD>.Input) async {
        switch input {
        case .packet(let p):
            let resampler = resamplers[p.stream] ?? MediaResampler()
            resamplers[p.stream] = resampler
            if let (start, samples) = resampler.convert(p) { timelines[p.videoID, default: MediaTimeline()].add(start: start, samples: samples) }
            lastPacketVideo = p.videoID
        case let .playhead(videoID, time, process):
            head = (videoID, time, process)
            playhead.set(videoID, time)
            // Only the video playing (and one whose audio is arriving, while the page switches) is kept.
            for id in Array(timelines.keys) where id != videoID && id != lastPacketVideo { timelines[id] = nil; done[id] = nil }
            timelines[videoID]?.trim(before: time - keep)
        }
        await step()
    }

    private func finishRun(flush: Bool) {
        guard var r = run else { return }
        run = nil
        if flush {
            for chunk in r.chunker.finish() { emit(.init(videoID: r.videoID, start: r.start + chunk.start, samples: chunk.samples)) }
            r.emitted = r.cursor
        }
        done[r.videoID, default: Intervals()].add(r.start, r.emitted)
    }

    private func step() async {
        guard let head, head.process, let timeline = timelines[head.videoID] else { finishRun(flush: false); return }
        let limit = head.time + horizon
        for _ in 0..<8 {   // a few runs at most per input: each ends at a stretch already done or a gap
            // A run at a gap in the audio (audio further on, none here): the speech before it ends
            // here; the next run starts after it. At the end of all the audio, it waits for more.
            if let r = run, r.videoID == head.videoID, timeline.range(at: r.cursor) == nil,
               timeline.ranges.contains(where: { $0.start > r.cursor }) { finishRun(flush: true) }
            var claimed = done[head.videoID] ?? Intervals()
            if let r = run, r.videoID == head.videoID { claimed.add(r.start, r.cursor) }
            // The first time from the playhead on that is not done and has audio: a hole in the audio
            // (before its first sample, or a gap) is skipped, never waited in.
            var from = claimed.free(from: head.time)
            while timeline.range(at: from) == nil, let next = timeline.ranges.first(where: { $0.start > from }) {
                from = claimed.free(from: next.start)
            }
            if let r = run, r.videoID != head.videoID || abs(r.cursor - from) > 0.001 { finishRun(flush: false) }
            guard from < limit else { return }
            if run == nil {
                guard timeline.range(at: from) != nil else { return }   // no audio there yet
                var fresh = vad
                await fresh.reset()
                var chunker = Chunker(vad: fresh)
                chunker.maxChunk = maxChunk
                run = Run(videoID: head.videoID, start: from, cursor: from, emitted: from, chunker: chunker)
                log.notice("sync: working from \(from, format: .fixed(precision: 1)) s, the playhead at \(head.time, format: .fixed(precision: 1)) s, audio to \(timeline.range(at: from)?.end ?? from, format: .fixed(precision: 1)) s")
            }
            guard var r = run, let range = timeline.range(at: r.cursor) else { return }   // waiting for audio
            let next = done[head.videoID]?.next(after: r.cursor)
            let stop = min(range.end, limit, next ?? .infinity)
            let samples = timeline.samples(from: r.cursor, to: stop)
            for chunk in await r.chunker.append(samples) {
                emit(.init(videoID: r.videoID, start: r.start + chunk.start, samples: chunk.samples))
                r.emitted = r.start + chunk.start + chunk.duration
            }
            r.cursor += Double(samples.count) / MediaTimeline.rate
            run = r
            if stop == range.end { continue }   // reached a gap or the end of the audio: see the top
            // Reached a stretch already done (after seeking back): close this run, carry on after it.
            guard let next, r.cursor >= next - 0.001 else { return }
            finishRun(flush: true)
        }
    }

}
