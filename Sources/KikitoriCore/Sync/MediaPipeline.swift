import Foundation
import Synchronization

/// The built-in player's synced subtitles: the video's audio arrives ahead of playback (decoded
/// from what the site's player has buffered), and this runs the same chunker, recognizer and
/// translator as `LivePipeline` on it in video time, so each chunk's cue is ready before its
/// first character is spoken (docs/design/realtime-sync.md).
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
        /// A chunk ready to be shown, with its audio (16 kHz mono) for replay.
        case cue(Cue, audio: [Float])
        /// What the API billed for the cue that follows.
        case translated(cost: Double, tokens: Int)
        /// `cost` and `tokens` are what the API billed for an answer that couldn't be used (0 if none).
        case translationFailed(ClaudeClient.Failure, cost: Double, tokens: Int)
        /// Not sent for translation (no translator, or Japanese only right now).
        case translationSkipped
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
        var videoID: String
        var chars: [TimedChar]
        var audio: [Float]
        var end: Double
    }

    public func run(_ inputs: AsyncStream<Input>) -> AsyncStream<Event> {
        let (events, emit) = AsyncStream.makeStream(of: Event.self)
        let (chunks, toRecognize) = AsyncStream.makeStream(of: Pending.self)
        let (heard, toTranslate) = AsyncStream.makeStream(of: Heard.self)
        let playhead = Playhead()
        let staleAfter = staleAfter, shouldTranslate = shouldTranslate
        let cutter = Cutter(vad: vad, maxChunk: maxChunk, horizon: horizon, keep: keepBehind, playhead: playhead) { toRecognize.yield($0) }
        let cut = Task {
            for await input in inputs { await cutter.take(input) }
            toRecognize.finish()
        }
        let recognize = Task { [engine, contextTerms] in
            for await chunk in chunks {
                guard !playhead.passed(chunk.videoID, chunk.end, by: staleAfter) else { continue }
                let pieces = (try? await engine.transcribeTimed(chunk.samples, context: contextTerms)) ?? []
                let cleaned = TranscriptFilter.clean(pieces)
                guard !cleaned.isEmpty else { continue }
                let chars = OnsetRefiner.refine(cleaned, samples: chunk.samples).shifted(by: chunk.start)
                toTranslate.yield(Heard(videoID: chunk.videoID, chars: chars, audio: chunk.samples, end: chunk.end))
            }
            toTranslate.finish()
        }
        let translate = Task { [translator] in
            for await h in heard {
                guard !playhead.passed(h.videoID, h.end, by: staleAfter) else { continue }
                let ja = h.chars.text
                func japaneseOnly() -> Cue { Cue(videoID: h.videoID, chars: h.chars, lines: CueAligner.lines([], over: h.chars)) }
                guard let translator, await shouldTranslate() else {
                    emit.yield(.translationSkipped)
                    emit.yield(.cue(japaneseOnly(), audio: h.audio))
                    continue
                }
                do {
                    let r = try await translator.translate(ja)
                    emit.yield(.translated(cost: r.cost, tokens: r.usage.total))
                    // No lines back means fillers or backchannels: the Japanese stays, without English.
                    let lines = r.lines.isEmpty ? CueAligner.lines([], over: h.chars) : CueAligner.lines(r.lines, over: h.chars)
                    emit.yield(.cue(Cue(videoID: h.videoID, chars: h.chars, lines: lines), audio: h.audio))
                } catch let billed as ClaudeClient.BilledFailure {
                    emit.yield(.translationFailed(billed.failure, cost: billed.cost, tokens: billed.usage.total))
                    emit.yield(.cue(japaneseOnly(), audio: h.audio))
                } catch let failure as ClaudeClient.Failure {
                    emit.yield(.translationFailed(failure, cost: 0, tokens: 0))
                    emit.yield(.cue(japaneseOnly(), audio: h.audio))
                } catch {
                    emit.yield(.translationFailed(.unexpected(status: 0, "\(error)"), cost: 0, tokens: 0))
                    emit.yield(.cue(japaneseOnly(), audio: h.audio))
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
