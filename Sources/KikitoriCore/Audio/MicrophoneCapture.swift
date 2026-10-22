import AVFoundation
import CoreAudio
import Foundation

/// Anything that delivers 16 kHz mono samples until stopped.
public protocol AudioCapture: AnyObject, Sendable {
    var samples: AsyncStream<[Float]> { get }
    func stop()
}

extension ProcessTapCapture: AudioCapture {}

/// An audio input device (microphone, interface, virtual device).
public struct InputDevice: Sendable, Identifiable, Hashable {
    public var id: AudioDeviceID
    public var uid: String
    public var name: String
    public var detail: String

    /// All devices with input channels, the default one first.
    public static func list() -> [InputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ids = (try? CoreAudioProperty.array(system, kAudioHardwarePropertyDevices, of: AudioDeviceID.self)) ?? []
        let defaultID = (try? CoreAudioProperty.value(system, kAudioHardwarePropertyDefaultInputDevice, default: AudioDeviceID(0))) ?? 0
        let devices: [InputDevice] = ids.compactMap { id in
            var address = CoreAudioProperty.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
            let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
            defer { list.deallocate() }
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return nil }
            let channels = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
                .reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { return nil }
            let rate = (try? CoreAudioProperty.value(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0
            let transport = (try? CoreAudioProperty.value(id, kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0
            var detail = "\(channels) channel\(channels == 1 ? "" : "s") · \(Int(rate / 1000)) kHz"
            if transport == kAudioDeviceTransportTypeBuiltIn { detail = "built in" }
            if transport == kAudioDeviceTransportTypeBluetooth { detail = "Bluetooth · lower quality while in use" }
            return InputDevice(id: id, uid: (try? CoreAudioProperty.string(id, kAudioDevicePropertyDeviceUID)) ?? "\(id)",
                               name: (try? CoreAudioProperty.string(id, kAudioObjectPropertyName)) ?? "Input \(id)",
                               detail: detail)
        }
        return devices.sorted { ($0.id == defaultID ? 0 : 1) < ($1.id == defaultID ? 0 : 1) }
    }
}

/// Records an input device with AVAudioEngine and delivers 16 kHz mono Float32.
/// Needs the microphone permission (Info.plist NSMicrophoneUsageDescription).
public final class MicrophoneCapture: AudioCapture, @unchecked Sendable {
    public let samples: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation
    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public init() {
        (samples, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(400))
    }

    public func start(device: AudioDeviceID?) throws {
        let input = engine.inputNode
        if var device, let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw CoreAudioProperty.Failure(what: "set up converter for input format", status: -1)
        }
        let out = outputFormat
        let continuation = continuation
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / format.sampleRate) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, let data = converted.floatChannelData, converted.frameLength > 0 else { return }
            continuation.yield(Array(UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength))))
        }
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
    }
}
