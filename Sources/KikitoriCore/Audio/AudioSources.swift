import AppKit
import CoreAudio
import Darwin

/// An app the user can listen to, with every Core Audio process object that plays its sound.
public struct AudioSource: Sendable, Identifiable, Hashable {
    /// The owning app's bundle identifier (or "pid:<n>" for apps without one).
    public var id: String
    public var name: String
    public var pid: pid_t
    /// Core Audio process objects to tap: the app itself and its audio helper processes.
    public var processObjects: [AudioObjectID]
    /// True when any of those processes is producing output right now.
    public var isPlaying: Bool

    public init(id: String, name: String, pid: pid_t, processObjects: [AudioObjectID], isPlaying: Bool) {
        self.id = id; self.name = name; self.pid = pid; self.processObjects = processObjects; self.isPlaying = isPlaying
    }
}

public enum AudioSources {
    /// Apps that currently have audio process objects, playing ones first.
    public static func list() throws -> [AudioSource] {
        let objects = try CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject),
                                                  kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        var byApp: [String: AudioSource] = [:]
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for object in objects {
            guard let pid = try? CoreAudioProperty.value(object, kAudioProcessPropertyPID, default: pid_t(0)),
                  pid > 0, pid != ownPID else { continue }
            let playing = ((try? CoreAudioProperty.value(object, kAudioProcessPropertyIsRunningOutput,
                                                         default: UInt32(0))) ?? 0) != 0
            let bundleID = (try? CoreAudioProperty.string(object, kAudioProcessPropertyBundleID)) ?? ""
            guard let owner = owningApp(pid: pid, bundleID: bundleID) else { continue }
            let key = owner.bundleIdentifier ?? "pid:\(owner.processIdentifier)"
            var source = byApp[key] ?? AudioSource(id: key, name: owner.localizedName ?? key,
                                                    pid: owner.processIdentifier, processObjects: [], isPlaying: false)
            source.processObjects.append(object)
            source.isPlaying = source.isPlaying || playing
            byApp[key] = source
        }
        return byApp.values.sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
    }

    /// The user-facing app a process plays sound for: itself if it is a regular app, otherwise
    /// the nearest regular-app ancestor (Chrome and Firefox helpers). WebKit's shared GPU process
    /// is an XPC service with no app parent; it is attributed to Safari.
    static func owningApp(pid: pid_t, bundleID: String) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let parent = parentPID(of: current), parent > 1 else { break }
            current = parent
        }
        if bundleID.hasPrefix("com.apple.WebKit") {
            return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first
        }
        return nil
    }

    /// Core Audio process objects of this app's own WebKit processes (the built-in player plays
    /// its sound from WebKit's GPU/WebContent processes, which macOS attributes to this app).
    public static func ownWebKitProcesses() -> [AudioObjectID] { webKitProcesses(of: ProcessInfo.processInfo.processIdentifier) }

    /// WebKit audio process objects that macOS attributes to the app with this pid.
    public static func webKitProcesses(of app: pid_t) -> [AudioObjectID] {
        guard let objects = try? CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject),
                                                         kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        else { return [] }
        return objects.filter { object in
            guard let pid = try? CoreAudioProperty.value(object, kAudioProcessPropertyPID, default: pid_t(0)), pid > 0,
                  let bundle = try? CoreAudioProperty.string(object, kAudioProcessPropertyBundleID),
                  bundle.hasPrefix("com.apple.WebKit") else { return false }
            return responsiblePID(of: pid) == app
        }
    }

    /// The app macOS holds responsible for a helper process (libsystem; used by many system tools).
    static func responsiblePID(of pid: pid_t) -> pid_t? {
        typealias Fn = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        let result = unsafeBitCast(symbol, to: Fn.self)(pid)
        return result > 0 ? result : nil
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
