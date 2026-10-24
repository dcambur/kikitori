// EXPERIMENT: synced subtitles end to end on a real page, without the app.
//
//   swift run kk-check-sync "<youtube url>" <seconds> [--seek <to>@<at>]
//
// A muted WKWebView runs the production page scripts (MediaTapScript, PlayerScript); the media
// pipeline (Silero VAD, Apple Speech; no translation, so nothing is billed) makes cues from the
// page's buffered audio and hands them back, as AppModel does. Reports each cue's lead (how long
// before its first character it reached the page) and, for every character the page revealed,
// how far from its time the video was when it appeared.
import AppKit
import KikitoriCore
import WebKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let url = URL(string: args[0]), let seconds = Double(args[1]) else { print("usage: kk-check-sync <url> <seconds> [--seek to@at]"); exit(2) }
let seek = args.firstIndex(of: "--seek").flatMap { args.count > $0 + 1 ? args[$0 + 1].split(separator: "@").compactMap { Double($0) } : nil }

func pageScript(_ file: String, _ open: String, _ close: String) -> String {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/Kikitori/Player/\(file)").standardized
    let s = try! String(contentsOf: path, encoding: .utf8)
    return String(s[s.range(of: open)!.upperBound..<s.range(of: close)!.lowerBound])
}
let mediaTap = pageScript("MediaTapScript.swift", "#\"\"\"\n", "\"\"\"#")
let player = pageScript("PlayerScript.swift", "\"\"\"\n", "\"\"\"\n}").replacingOccurrences(of: "\\\\", with: "\\")

final class Bridge: NSObject, WKScriptMessageHandler {
    var feed: AsyncStream<MediaPipeline<SileroVAD>.Input>.Continuation?
    var state: [String: Any] = [:]
    var reveals: [(cue: String, line: Int)] = []
    var packets = 0
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let b = m.body as? [String: Any] ?? [:]
        switch m.name {
        case "kkLog": print("  page:", m.body)
        case "kkMedia":
            guard let vid = b["vid"] as? String, let t = b["t"] as? Double, let r = b["r"] as? Double,
                  let data = (b["pcm"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return }
            let samples = data.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 } }
            packets += 1
            feed?.yield(.packet(MediaPacket(videoID: vid, stream: b["s"] as? Int ?? 0, time: t, rate: r, samples: samples)))
        case "kkState":
            state = b
            guard let vid = b["vid"] as? String, let t = b["t"] as? Double, t >= 0, b["ad"] as? Bool != true else { return }
            let synced = b["media"] as? Bool == true && b["live"] as? Bool != true
            feed?.yield(.playhead(videoID: vid, time: t, process: synced))
        case "kkReveal": reveals.append((b["id"] as? String ?? "", b["line"] as? Int ?? -1))
        default: break
        }
    }
}

@MainActor func run() async {
    let bridge = Bridge()
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.mediaTypesRequiringUserActionForPlayback = []
    for name in ["kkLog", "kkMedia", "kkState", "kkReveal"] { config.userContentController.add(bridge, contentWorld: .page, name: name) }
    config.userContentController.addUserScript(WKUserScript(source: mediaTap, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    config.userContentController.addUserScript(WKUserScript(source: player, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 854, height: 480), configuration: config)
    web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    let mute = NSSelectorFromString("_setPageMuted:")   // private WebKit SPI, checks only: nothing plays aloud
    if web.responds(to: mute) {
        typealias Fn = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(web.method(for: mute), to: Fn.self)(web, mute, 1)
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 854, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "kk-check-sync (muted)"
    window.contentView = web; window.orderFrontRegardless()

    let engine = AppleSpeechEngine()
    try! await engine.prepare()
    let pipeline = MediaPipeline(engine: engine, translator: nil, vad: try! await SileroVAD.load())
    let (inputs, feed) = AsyncStream.makeStream(of: MediaPipeline<SileroVAD>.Input.self)
    bridge.feed = feed
    func js(_ body: String) async -> Any? { do { return try await web.callAsyncJavaScript(body, contentWorld: .page) } catch { return "ERROR \(error)" } }
    var cues: [String: Cue] = [:]
    var leads: [Double] = []
    let events = pipeline.run(inputs)
    let consume = Task { @MainActor in
        for await e in events {
            guard case let .cue(cue, _) = e else { continue }
            cues[cue.id.uuidString] = cue
            let now = bridge.state["t"] as? Double ?? 0
            leads.append(cue.start - now)
            let list: [[String: Any]] = [["id": cue.id.uuidString, "vid": cue.videoID, "chars": cue.chars.map { [$0.text, $0.start, $0.end] as [Any] },
                                          "lines": cue.lines.map { [$0.from, $0.to] }]]
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: list), as: UTF8.self)
            _ = try? await web.evaluateJavaScript("window.__kikitori.cues(\(json), false)", in: nil, contentWorld: .page)
            print(String(format: "  cue %.2f–%.2f (lead %+.1f s): %@", cue.start, cue.end, cue.start - now, cue.chars.text))
        }
    }
    web.load(URLRequest(url: url))
    // Record, for each character as it turns on, the video time then vs its own time.
    let observer = """
        if (window.__kkObs) return 1; window.__kkReveal = [];
        const obs = new MutationObserver(ms => { const v = document.querySelector('#movie_player video'); if (!v) return;
          for (const m of ms) if (m.target.classList && m.target.classList.contains('kk-c') && m.target.classList.contains('on') && !seen.has(m.target)) { seen.add(m.target); window.__kkReveal.push(v.currentTime - +m.target.dataset.t); } });
        const seen = new WeakSet();
        obs.observe(document.documentElement, { subtree: true, attributes: true, attributeFilter: ['class'] }); window.__kkObs = obs; return 1;
        """
    let began = Date()
    var seeked = false, syncedOn = false
    while Date().timeIntervalSince(began) < seconds {
        try? await Task.sleep(for: .seconds(1))
        _ = await js("window.__kikitoriMedia && window.__kikitoriMedia.setActive(true); const v = document.querySelector('#movie_player video'); if (v && v.paused && !document.querySelector('#movie_player.ad-showing')) v.play().catch(() => {}); return 1;")
        _ = await js(observer)
        if Int(Date().timeIntervalSince(began)) % 10 == 0, args.contains("--debug") {
            print(await js("const M = window.__kikitoriMedia; return JSON.stringify({ streams: M && M.streams.map(s => [s.id, s.type, s.ad, s.vid, s.decoded.toFixed(1), !!s.decoder, !!s.cfg]), ours: String(MediaSource.prototype.addSourceBuffer).slice(0, 60), mms: typeof ManagedMediaSource, srcType: (document.querySelector('video') || {}).src });") ?? "nil")
        }
        let synced = bridge.state["media"] as? Bool == true && bridge.state["live"] as? Bool != true
        if synced != syncedOn { syncedOn = synced; _ = await js("window.__kikitori.sync(\(synced), 2); return 1;"); print(String(format: "[%4.0f s] synced: %@", Date().timeIntervalSince(began), "\(synced)")) }
        if let seek, seek.count == 2, !seeked, Date().timeIntervalSince(began) >= seek[1], bridge.state["ad"] as? Bool != true {
            seeked = true
            _ = await js("document.querySelector('#movie_player video').currentTime = \(seek[0]); return 1;")
            print(String(format: "[%4.0f s] seek to %.0f", Date().timeIntervalSince(began), seek[0]))
        }
    }
    let deltas = (await js("return window.__kkReveal || [];") as? [Double]) ?? []
    feed.finish(); consume.cancel()
    let sortedLeads = leads.sorted(), absD = deltas.map(abs).sorted()
    func pct(_ v: [Double], _ p: Double) -> Double { v.isEmpty ? .nan : v[min(v.count - 1, Int(Double(v.count - 1) * p))] }
    print(String(format: "\n%d media packets, %d cues, %d line reveals posted", bridge.packets, cues.count, bridge.reveals.count))
    print(String(format: "cue lead (first character − playhead when it reached the page): min %+.1f s, median %+.1f s, late (≤ 0): %d",
                 sortedLeads.first ?? .nan, pct(sortedLeads, 0.5), leads.filter { $0 <= 0 }.count))
    print(String(format: "reveals: %d characters; video time at reveal − character time: median %.0f ms, p95 %.0f ms, max %.0f ms, early: %d",
                 deltas.count, pct(absD, 0.5) * 1000, pct(absD, 0.95) * 1000, (absD.last ?? .nan) * 1000, deltas.filter { $0 < -0.001 }.count))
    exit(0)
}
Task { @MainActor in await run() }
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
