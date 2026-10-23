import AppKit
import Foundation
import KikitoriCore
import Synchronization

/// Headless end-to-end check through the real app identity (which owns the audio permission):
///   open build/Kikitori.app --args --live-test <bundle id> <seconds> <log path>
/// Taps that app's audio, runs chunker → Apple Speech → Haiku, writes events to the log, quits.
enum LiveTest {
    static func run(bundleID: String, seconds: Double, logPath: String) async {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: logPath)
        func write(_ line: String) {
            log?.write(Data((line + "\n").utf8))
        }
        do {
            let sources = try AudioSources.list()
            write("sources: " + sources.map { "\($0.name)\($0.isPlaying ? " ▶︎" : "")" }.joined(separator: ", "))
            guard let source = sources.first(where: { $0.id == bundleID }) else {
                write("error: \(bundleID) has no audio processes"); return
            }
            let engine = AppleSpeechEngine()
            try await engine.prepare()
            var pipeline = LivePipeline(engine: engine,
                                        translator: KeychainStore.apiKey().map {
                                            LiveTranslator(client: ClaudeClient(apiKey: $0), profile: nil)
                                        },
                                        vad: try await SileroVAD.load())
            pipeline.maxChunk = 6
            let capture = ProcessTapCapture()
            try capture.start(processObjects: source.processObjects)
            write("capturing \(source.name) for \(Int(seconds)) s")

            // Count the audio as it passes through, to tell "no permission" (all zeros) from silence.
            let (counted, feed) = AsyncStream.makeStream(of: [Float].self)
            let meter = Task {
                var total = 0, loud = 0
                for await samples in capture.samples {
                    total += samples.count
                    loud += samples.filter { abs($0) > 0.001 }.count
                    feed.yield(samples)
                }
                feed.finish()
                write(String(format: "audio: %.1f s received, %.0f%% non-silent", Double(total) / 16_000,
                             total > 0 ? 100 * Double(loud) / Double(total) : 0))
            }
            let began = Date()
            let consume = Task {
                var cost = 0.0
                for await event in pipeline.run(counted) {
                    let wall = Date().timeIntervalSince(began)
                    switch event {
                    case let .heard(time, _, ja, _, _):
                        write(String(format: "[%5.1f | wall %5.1f] JA %@", time, wall, ja))
                    case let .translated(time, lines, c, _, _):
                        cost += c
                        for l in lines { write(String(format: "[%5.1f | wall %5.1f] EN %@", time, wall, l.en ?? "")) }
                    case .translationSkipped, .hearing: break
                    case let .translationFailed(time, failure, c, _):
                        cost += c
                        write(String(format: "[%5.1f] translation failed: %@", time, "\(failure)"))
                    }
                }
                write(String(format: "translation cost $%.4f", cost))
            }
            try await Task.sleep(for: .seconds(seconds))
            capture.stop()
            await meter.value
            await consume.value
            write("done")
        } catch {
            write("error: \(error)")
        }
        try? log?.close()
    }
}

/// Headless check of the built-in player, through the real app identity:
///   open build/Kikitori.app --args --player-test <link or search words> <seconds> <log path>
/// Plays the video (the first search result for search words), starts subtitles as the Start
/// Subtitles button does, and logs the audio heard, the lines and where the page draws them.
@MainActor
enum PlayerTest {
    static func run(input: String, seconds: Double, logPath: String) async {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: logPath)
        func write(_ line: String) { log?.write(Data((line + "\n").utf8)) }
        defer { try? log?.close() }

        let model = AppModel.shared, player = PlayerController.shared
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 960, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = player.webView
        window.orderFrontRegardless()
        player.load(input)
        for _ in 0..<40 where !(player.hasVideo && !player.paused) {
            try? await Task.sleep(for: .seconds(1))
            if player.url?.path == "/results" {   // open the first search result
                _ = try? await player.webView.callAsyncJavaScript(
                    "const a = document.querySelector('a#video-title'); if (a) location.href = a.href;", contentWorld: .page)
            }
        }
        write("page: \(player.url?.absoluteString ?? "none") video=\(player.hasVideo) paused=\(player.paused)")

        await model.start(source: AudioSource(id: PlayerController.sourceID, name: "kikitori Player", pid: 0,
                                              processObjects: [], isPlaying: true))
        write("session: state=\(model.state) issues=\(model.issues)")
        let began = Date()
        var probe: ProcessTapCapture?
        let peak = Mutex<Float>(0)   // loudest sample since the last report, from a second tap
        while Date().timeIntervalSince(began) < seconds {
            try? await Task.sleep(for: .seconds(3))
            let objects = AudioSources.ownWebKitProcesses()
            if probe == nil, !objects.isEmpty {
                let tap = ProcessTapCapture()
                if (try? tap.start(processObjects: objects)) != nil {
                    probe = tap
                    Task.detached { for await s in tap.samples { let p = s.map(abs).max() ?? 0; peak.withLock { $0 = max($0, p) } } }
                }
            }
            let loudest = peak.withLock { p in defer { p = 0 }; return p }
            let page = try? await player.webView.callAsyncJavaScript("""
                const v = document.querySelector('video.html5-main-video') || document.querySelector('video');
                const l = document.getElementById('kikitori-subs');
                const r = e => { if (!e) return null; const b = e.getBoundingClientRect(); return [b.x, b.y, b.width, b.height].map(Math.round); };
                const mp = document.getElementById('movie_player');
                const track = mp && mp.getAudioTrack ? mp.getAudioTrack() : null;
                const info = track && track.getLanguageInfo ? track.getLanguageInfo() : null;
                return JSON.stringify({ audio: info ? info.getName() + (track.isAutoDubbed() ? ' (auto-dub)' : '') : null,
                                        layer: !!l, parent: l && l.parentElement ? (l.parentElement.id || l.parentElement.className) : null,
                                        text: l ? l.innerText.slice(0, 60) : '', layerBox: r(l), videoBox: r(v), playing: v ? !v.paused : false });
                """, contentWorld: .page)
            let lines = model.session?.lines ?? []
            write(String(format: "[%4.0f s] webkit audio objects=%d peak=%.3f lines=%d pending=%d issues=%@ page=%@",
                         Date().timeIntervalSince(began), objects.count, loudest, lines.count, model.pendingLines.count,
                         "\(model.issues)", (page as? String) ?? "nil"))
            if !model.hearing.isEmpty { write("    live: \(model.hearing)") }
            if let last = lines.last {
                write("    last: \(last.ja) → \(last.en ?? "…")\(model.canReplay(last) ? "  [audio kept]" : "")")
            }
        }
        // The heard chunks as one file next to the log, for offline checks of the real audio
        // (`kikitori-cli run` or `preview` on it). Test runs only; the app never saves audio.
        var audio: [Int16] = [], seen = Set<Double>()
        for line in model.session?.lines ?? [] where seen.insert(line.time).inserted {
            if let clip = model.clipSamples(line) { audio += clip + [Int16](repeating: 0, count: 4_800) }
        }
        if !audio.isEmpty {
            try? ClipPlayer.wav(audio).write(to: URL(fileURLWithPath: logPath + ".wav"))
            write(String(format: "audio of %d chunks (%.0f s): %@.wav", seen.count, Double(audio.count) / 16_000, logPath))
        }
        probe?.stop()
        model.stop()
        write("done")
    }
}
