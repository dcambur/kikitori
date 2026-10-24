import AVFoundation
import Foundation

/// Decoded audio of the video playing in the built-in player, as the page sends it: mono samples
/// at the decoder's rate, starting at `time` on the video's timeline (`currentTime` seconds).
public struct MediaPacket: Sendable {
    public var videoID: String
    /// The page's audio stream (one per SourceBuffer): a resampler's state belongs to one stream.
    public var stream: Int
    public var time: Double
    public var rate: Double
    public var samples: [Float]

    public init(videoID: String, stream: Int, time: Double, rate: Double, samples: [Float]) {
        self.videoID = videoID; self.stream = stream; self.time = time; self.rate = rate; self.samples = samples
    }

    public var end: Double { time + Double(samples.count) / rate }
}

/// A video's audio at 16 kHz by video time: contiguous ranges, kept in order. Audio arrives ahead
/// of playback, in bursts and sometimes out of order (a live stream's newest segment before the
/// ones a seek asked for), and the same seconds can come twice; what is already there is kept.
public struct MediaTimeline: Sendable {
    public static let rate = 16_000.0
    /// Joins pieces this close (an Opus decoder's 6.5 ms pre-skip step), padding or trimming.
    static let joinTolerance = 0.03

    public struct Range: Sendable, Equatable {
        public var start: Double
        public var samples: [Float]
        public var end: Double { start + Double(samples.count) / MediaTimeline.rate }
    }

    public private(set) var ranges: [Range] = []

    public init() {}

    /// Add 16 kHz samples starting at `start`.
    public mutating func add(start: Double, samples: [Float]) {
        guard !samples.isEmpty else { return }
        var start = start, samples = samples
        // Drop what an existing range already covers, splitting around ranges inside the piece.
        for r in ranges {
            let end = start + Double(samples.count) / Self.rate
            guard r.start < end - 1e-6, r.end > start + 1e-6 else { continue }
            if r.start <= start + Self.joinTolerance {
                let skip = Int(((r.end - start) * Self.rate).rounded())
                guard skip < samples.count else { return }
                samples.removeFirst(skip)
                start = r.end
            } else {
                let keep = Int(((r.start - start) * Self.rate).rounded())
                let tail = Array(samples[min(samples.count, keep)...]), tailStart = r.start
                samples = Array(samples[..<min(samples.count, keep)])
                add(start: tailStart, samples: tail)
                if samples.isEmpty { return }
            }
        }
        insert(Range(start: start, samples: samples))
    }

    private mutating func insert(_ new: Range) {
        ranges.insert(new, at: ranges.firstIndex { $0.start > new.start } ?? ranges.count)
        // Join neighbours that now touch (within the tolerance), padding or trimming the seam.
        var k = 0
        while k + 1 < ranges.count {
            let gap = ranges[k + 1].start - ranges[k].end
            guard gap <= Self.joinTolerance else { k += 1; continue }
            let next = ranges.remove(at: k + 1)
            let pad = Int((gap * Self.rate).rounded())
            if pad > 0 { ranges[k].samples += [Float](repeating: 0, count: pad) }
            ranges[k].samples += pad < 0 ? Array(next.samples.dropFirst(-pad)) : next.samples
        }
    }

    /// The range holding `time`, or starting within `slack` after it.
    public func range(at time: Double, slack: Double = 0) -> Range? {
        ranges.first { $0.start <= time + slack && $0.end > time }
    }

    /// Samples from `from` to `to` (both inside one range).
    public func samples(from: Double, to: Double) -> [Float] {
        guard let r = range(at: from) else { return [] }
        let a = max(0, Int(((from - r.start) * Self.rate).rounded()))
        let b = min(r.samples.count, Int(((min(to, r.end) - r.start) * Self.rate).rounded()))
        return a < b ? Array(r.samples[a..<b]) : []
    }

    /// Forget audio before `time` (already played or processed).
    public mutating func trim(before time: Double) {
        ranges.removeAll { $0.end <= time }
        if let first = ranges.first, first.start < time {
            let drop = Int(((time - first.start) * Self.rate).rounded())
            ranges[0].samples.removeFirst(min(drop, first.samples.count))
            ranges[0].start = time
        }
    }

    public var seconds: Double { ranges.reduce(0) { $0 + $1.end - $1.start } }
}

/// Converts one stream's packets to 16 kHz, keeping the converter's state while they follow on
/// from each other (no clicks at packet edges) and starting afresh at a jump in time or rate.
/// Output times account for the converter's delay, so a sound keeps its time to within a sample.
public final class MediaResampler: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private var rate = 0.0
    private var nextInput = 0.0     // where the next contiguous packet would start
    private var outputTime = 0.0    // where the next output sample belongs

    public init() {}

    /// 16 kHz samples and where they start, or nil while the converter fills.
    public func convert(_ packet: MediaPacket) -> (start: Double, samples: [Float])? {
        if packet.rate == MediaTimeline.rate { return (packet.time, packet.samples) }
        if converter == nil || packet.rate != rate || abs(packet.time - nextInput) > MediaTimeline.joinTolerance {
            let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: packet.rate, channels: 1, interleaved: false)!
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MediaTimeline.rate, channels: 1, interleaved: false)!
            converter = AVAudioConverter(from: source, to: target)
            converter?.primeMethod = .none   // output sample 0 is input sample 0: times stay put
            rate = packet.rate
            outputTime = packet.time
        }
        nextInput = packet.end
        guard let converter, !packet.samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(packet.samples.count))
        else { return nil }
        input.frameLength = AVAudioFrameCount(packet.samples.count)
        packet.samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: packet.samples.count) }
        let capacity = AVAudioFrameCount(Double(packet.samples.count) * MediaTimeline.rate / packet.rate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        defer { outputTime += Double(samples.count) / MediaTimeline.rate }
        return (outputTime, samples)
    }
}
