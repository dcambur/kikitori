import CoreAudio
import Foundation

/// Thin typed access to Core Audio object properties.
enum CoreAudioProperty {
    struct Failure: Error, CustomStringConvertible {
        var what: String
        var status: OSStatus
        var description: String { "\(what) failed (OSStatus \(status))" }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
        guard status == noErr else { throw Failure(what: "read property \(selector)", status: status) }
        return result
    }

    static func array<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, of _: T.Type) throws -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw Failure(what: "size of property \(selector)", status: status) }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer)
        guard status == noErr else { throw Failure(what: "read property \(selector)", status: status) }
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var result: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
        guard status == noErr, let result else { throw Failure(what: "read string \(selector)", status: status) }
        return result.takeRetainedValue() as String
    }
}
