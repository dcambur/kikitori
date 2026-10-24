// EXPERIMENT (spike for docs/design/realtime-sync.md), not product code.
//
//   swift run kk-spike-mse "<youtube url>" <seconds> <out prefix> [--behind <s>] [--seek <to>@<at>] [--visible]
//
// Loads the page in a muted WKWebView (page-level mute plus video.muted: nothing reaches the
// speakers), with Hook.source wrapping Media Source Extensions. Every 2 s it prints how far
// the site's own player has downloaded audio ahead of the playhead. At the end it writes
// <prefix>.audio.<ext> (the audio SourceBuffer's bytes, as appended) and <prefix>.wav (those
// bytes decoded by Web Audio's decodeAudioData, 16 kHz mono), and prints the segment list.
// --behind s: on a live stream, seek to (live edge - s) and report whether it stays there.
// --seek to@at: at `at` seconds into the run, seek the video to `to` (VOD seeking behaviour).
import AppKit
import WebKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else { print("usage: kk-spike-mse <url> <seconds> <out prefix> [--behind s] [--seek to@at]"); exit(2) }
let url = URL(string: args[0])!, seconds = Double(args[1]) ?? 60, prefix = args[2]
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } }
let behind = option("--behind").flatMap(Double.init)
let seek = option("--seek").map { $0.split(separator: "@").compactMap { Double($0) } }

final class Sink: NSObject, WKScriptMessageHandler {
    var bytes: [Int: Data] = [:], pcm: [Int: Data] = [:]
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let body = m.body as? [String: Any] ?? [:]
        switch m.name {
        case "log": print("  page:", m.body)
        case "bytes": if let i = body["i"] as? Int, let b = body["b64"] as? String { bytes[i] = Data(base64Encoded: b) }
        case "pcm": if let i = body["i"] as? Int, let b = body["b64"] as? String { pcm[i] = Data(base64Encoded: b) }
        default: break
        }
    }
}

func wav(_ pcm: Data, rate: Int = 16_000) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
    return d
}

@MainActor func run() async {
    let sink = Sink()
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.mediaTypesRequiringUserActionForPlayback = []
    for name in ["log", "bytes", "pcm"] { config.userContentController.add(sink, contentWorld: .page, name: name) }
    config.userContentController.addUserScript(WKUserScript(source: Hook.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 854, height: 480), configuration: config)
    web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    // Page-level mute (private WebKit SPI, spike only): no sound even if the site unmutes its video.
    let mute = NSSelectorFromString("_setPageMuted:")
    if web.responds(to: mute) {
        typealias Fn = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(web.method(for: mute), to: Fn.self)(web, mute, 1)
        print("page muted (WebKit _setPageMuted)")
    }
    // An on-screen window is needed for WebKit to keep decoding and fetching like a visible
    // tab; it sits in the bottom-left corner, small. (--visible is the default here.)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 854, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "kk-spike-mse (muted)"
    window.contentView = web
    window.orderFrontRegardless()
    web.load(URLRequest(url: url))

    func js(_ body: String) async -> Any? {
        do { return try await web.callAsyncJavaScript(body, contentWorld: .page) } catch { return "ERROR \(error)" }
    }
    func json(_ v: Any?) -> String {
        guard let v, JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return "\(v ?? "nil")" }
        return String(decoding: d, as: UTF8.self)
    }

    let began = Date()
    var placed = false, seeked = false
    while Date().timeIntervalSince(began) < seconds {
        try? await Task.sleep(for: .seconds(2))
        let elapsed = Date().timeIntervalSince(began)
        // Start playback if the page didn't (autoplay of a muted video is allowed).
        _ = await js("const v = document.querySelector('#movie_player video') || document.querySelector('video'); if (v && v.paused && !document.getElementById('movie_player')?.classList.contains('ad-showing')) { v.play().catch(()=>{}); } return 1;")
        if let behind, !placed {
            // YouTube's own player API knows where the live edge is (the media element's seekable
            // range does not); seekTo is what its DVR scrubber uses.
            let r = await js("""
                const p = document.getElementById('movie_player'); if (!p || p.classList.contains('ad-showing') || !p.getProgressState) return null;
                const s = p.getProgressState(); if (!s || !s.seekableEnd || !s.current) return null;
                p.seekTo(s.seekableEnd - \(behind), true); return s.seekableEnd;
                """)
            if r is Double { placed = true; print(String(format: "[%5.1f] placed %.0f s behind the seekable end (%@)", elapsed, behind, "\(r!)")) }
        }
        if let seek, seek.count == 2, !seeked, elapsed >= seek[1],
           await js("return !document.getElementById('movie_player').classList.contains('ad-showing');") as? Bool == true {
            seeked = true
            _ = await js("window.__kkspike.seekAt = performance.now(); document.querySelector('#movie_player video').currentTime = \(seek[0]); return 1;")
            print(String(format: "[%5.1f] seek to %.0f", elapsed, seek[0]))
        }
        guard let state = await js("return window.__kkspike ? window.__kkspike.state() : null;") as? [String: Any] else { continue }
        let t = state["t"] as? Double ?? 0
        var ahead: [String] = []
        for a in state["audio"] as? [[String: Any]] ?? [] {
            let ranges = a["buffered"] as? [[Double]] ?? []
            let containing = ranges.first { $0[0] <= t + 0.5 && $0[1] >= t }
            ahead.append(String(format: "a#%d(ms%d) %@ ahead %@", a["id"] as? Int ?? -1, a["ms"] as? Int ?? -1, json(ranges),
                                containing.map { String(format: "%.1f s", $0[1] - t) } ?? "-"))
        }
        var lag = ""
        if let seekable = state["seekable"] as? [Double], seekable.count == 2 { lag = String(format: " behind-seekable-end %.1f s", seekable[1] - t) }
        print(String(format: "[%5.1f] t=%.2f paused=%@ rate=%@ ad=%@ vid=%@ attached=ms%@%@ | %@", elapsed, t, "\(state["paused"] ?? "?")",
                     "\(state["rate"] ?? "?")", "\(state["ad"] ?? "?")", "\(state["vid"] ?? "nil")", "\(state["attachedMs"] ?? "nil")", lag, ahead.joined(separator: " | ")))
        if let live = state["liveEdge"] as? [String: Any], let end = live["seekableEnd"] as? Double, let cur = live["current"] as? Double, end - cur < 3600 {
            print(String(format: "        live: %.1f s behind YouTube's live edge, at live head: %@, ingestion %@", end - cur, "\(live["isAtLiveHead"] ?? "?")", "\(live["ingestion"] ?? "?")"))
        }
    }

    // Which audio buffer carried the video's own sound (the longest one), its segments, its bytes.
    let audio = (await js("return window.__kkspike.state().audio;") as? [[String: Any]]) ?? []
    print("audio buffers: \(json(audio))")
    // The video's own audio: the newest audio buffer made while no ad was showing (ads come in
    // their own MediaSource, on a timeline starting at 0).
    let made = (await js("return window.__kkspike.bufs.map(b => b.madeInAd);") as? [Bool]) ?? []
    let content = audio.filter { a in (a["kb"] as? Int ?? 0) > 0 && made[safe: a["id"] as? Int ?? -1] == false }
    guard let main = content.last ?? audio.last, let id = main["id"] as? Int else { exit(1) }
    let segs = await js("return window.__kkspike.segments(\(id));")
    print("seek issued at page time \(await js("return window.__kkspike.seekAt || null;") ?? "nil") ms")
    print("segments of a#\(id):")
    for s in segs as? [[String: Any]] ?? [] { print("  \(json(s))") }
    let types = await js("return window.__kkspike.bufs.map(b => b.type);")
    let type = ((types as? [String]) ?? [])[safe: id] ?? ""
    let pieces = await js("return window.__kkspike.dump(\(id));") as? Int ?? 0
    try? await Task.sleep(for: .seconds(1))
    let raw = (0..<pieces).compactMap { sink.bytes[$0] }.reduce(Data(), +)
    let ext = type.contains("webm") ? "webm" : "mp4"
    try? raw.write(to: URL(fileURLWithPath: "\(prefix).audio.\(ext)"))
    print("wrote \(prefix).audio.\(ext): \(raw.count) bytes (\(type))")

    let count = (segs as? [Any])?.count ?? 0
    let decoded = await js("return await window.__kkspike.decode(\(id), \(count));")
    print("decodeAudioData of init + \(count) segments: \(json(decoded))")
    let wc = await js("return await window.__kkspike.webcodecs(\(id));")
    print("WebCodecs AudioDecoder on demuxed blocks: \(json(wc))")
    // The WAV: WebCodecs output when it worked (it replaces decodeAudioData's), else decodeAudioData's.
    if let d = decoded as? [String: Any], d["ok"] as? Bool == true || ((wc as? [String: Any])?["frames"] as? Int ?? 0) > 0 {
        let n = await js("return window.__kkspike.sendDecoded();") as? Int ?? 0
        try? await Task.sleep(for: .seconds(1))
        let pcm = (0..<n).compactMap { sink.pcm[$0] }.reduce(Data(), +)
        try? wav(pcm).write(to: URL(fileURLWithPath: "\(prefix).wav"))
        print("wrote \(prefix).wav: \(String(format: "%.1f", Double(pcm.count) / 32_000)) s")
    }
    exit(0)
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

Task { @MainActor in await run() }
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
