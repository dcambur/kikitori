import AVFoundation
import CoreAudio
import Foundation

/// Records what a set of processes plays, through a Core Audio process tap (macOS 14.4+),
/// and delivers it as 16 kHz mono Float32. Needs the "System Audio Recording" permission;
/// the app's Info.plist must carry NSAudioCaptureUsageDescription.
public final class ProcessTapCapture: @unchecked Sendable {
    public static let sampleRate = 16_000.0

    /// 16 kHz mono samples, in order. Finishes when `stop()` is called.
    public let samples: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation

    private let queue = DispatchQueue(label: "kikitori.tap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: ProcessTapCapture.sampleRate,
                                             channels: 1, interleaved: false)!

    public init() {
        (samples, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(400))
    }

    deinit { stop() }

    /// Start tapping `processObjects` (from `AudioSource.processObjects`). Their sound keeps playing.
    public func start(processObjects: [AudioObjectID]) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CoreAudioProperty.Failure(what: "create process tap", status: status) }

        let outputDevice = try CoreAudioProperty.value(AudioObjectID(kAudioObjectSystemObject),
                                                       kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                       default: AudioDeviceID(0))
        let outputUID = try CoreAudioProperty.string(outputDevice, kAudioDevicePropertyDeviceUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "kikitori tap",
            kAudioAggregateDeviceUIDKey: "kikitori-tap-\(description.uuid.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw CoreAudioProperty.Failure(what: "create aggregate device", status: status)
        }

        var asbd = try CoreAudioProperty.value(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: format, to: outputFormat) else {
            stop()
            throw CoreAudioProperty.Failure(what: "set up converter for tap format", status: -1)
        }
        inputFormat = format
        self.converter = converter

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.handle(input)
        }
        guard status == noErr else { stop(); throw CoreAudioProperty.Failure(what: "create IO proc", status: status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stop(); throw CoreAudioProperty.Failure(what: "start device", status: status) }
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        continuation.finish()
    }

    private func handle(_ input: UnsafePointer<AudioBufferList>) {
        guard let inputFormat, let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
        continuation.yield(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
    }
}
