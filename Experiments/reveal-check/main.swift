// EXPERIMENT: checks the synced reveal in Sources/Kikitori/Player/PlayerScript.swift.
//
//   swift run kk-check-reveal
//
// A page shaped like YouTube's player (with its Trusted Types policy) runs the production page
// script; the video's clock is replaced by one this tool sets. Prints what the subtitle layer
// shows and which kkReveal messages were posted at each time, and checks them.
import AppKit
import WebKit

let scriptFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../Sources/Kikitori/Player/PlayerScript.swift").standardized
let swiftSource = try! String(contentsOf: scriptFile, encoding: .utf8)
let script = String(swiftSource[swiftSource.range(of: "\"\"\"\n")!.upperBound..<swiftSource.range(of: "\"\"\"\n}")!.lowerBound])
    .replacingOccurrences(of: "\\\\", with: "\\")

let page = """
<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="require-trusted-types-for 'script'"></head><body>
<div id="movie_player" class="html5-video-player" style="width:960px;height:540px;background:#000;position:relative">
  <video class="html5-main-video" style="position:absolute;left:0;top:0;width:960px;height:540px"></video>
</div></body></html>
"""

final class Sink: NSObject, WKScriptMessageHandler {
    var reveals: [String] = []
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "kkReveal", let b = m.body as? [String: Any] { reveals.append("\(b["id"] ?? "?"):\(b["line"] ?? "?")") }
        if m.name == "kkLog" { print("  page:", m.body) }
    }
}

@MainActor func run() async {
    let sink = Sink()
    let config = WKWebViewConfiguration()
    for name in ["kkReveal", "kkLog", "kkState"] { config.userContentController.add(sink, contentWorld: .page, name: name) }
    config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 540), configuration: config)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = web; window.orderFrontRegardless()
    web.loadHTMLString(page, baseURL: URL(string: "https://www.youtube.com/watch?v=vid1")!)
    while web.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
    try? await Task.sleep(for: .milliseconds(300))
    func js(_ body: String) async -> Any? {
        do { return try await web.callAsyncJavaScript(body, contentWorld: .page) } catch { return "ERROR \(error)" }
    }
    _ = await js("""
        window.fakeT = 0;
        const v = document.querySelector('video'); Object.defineProperty(v, 'currentTime', { get: () => window.fakeT });
        document.getElementById('movie_player').getVideoData = () => ({ video_id: 'vid1' });
        window.__kikitori.sync(true, 2);
        window.__kikitori.cues([{ id: 'A', vid: 'vid1', chars: [['今', 10.0, 10.2], ['日', 10.2, 10.4], ['は', 10.4, 10.6], ['晴', 10.8, 11.0], ['れ', 11.0, 11.5]],
                                  lines: [[0, 3], [3, 5]] }], false);
        return 1;
        """)
    var failures = 0
    func at(_ t: Double, expect: String, reveals: [String]? = nil, setup: String = "") async {
        _ = await js("\(setup) window.fakeT = \(t); return 1;")
        try? await Task.sleep(for: .milliseconds(150))
        let shown = (await js("""
            const l = document.getElementById('kikitori-subs'); if (!l) return '';
            return [...l.children].map(r => [...r.querySelectorAll('.kk-c')].map(c => c.classList.contains('on') ? c.textContent : '_').join('')).join(' / ');
            """) as? String) ?? "?"
        let ok = shown == expect && (reveals == nil || reveals! == sink.reveals)
        if !ok { failures += 1 }
        print(String(format: "t=%5.2f  shown: %-14@ reveals: %@ %@", t, shown as NSString, sink.reveals.joined(separator: ","), ok ? "ok" : "FAIL (expected \(expect)\(reveals.map { " / \($0)" } ?? ""))"))
    }
    await at(9.9, expect: "", reveals: [])
    await at(10.05, expect: "今__", reveals: ["A:0"])
    await at(10.45, expect: "今日は", reveals: ["A:0"])
    await at(10.85, expect: "今日は / 晴_", reveals: ["A:0", "A:1"])
    await at(11.2, expect: "今日は / 晴れ")
    await at(18.5, expect: "今日は / 晴れ")          // each line up to 8 s after its own end
    await at(19.0, expect: "晴れ")
    await at(19.6, expect: "")
    // A cue that arrives after its start: into the transcript (a reveal), not onto the video.
    _ = await js("window.fakeT = 31; window.__kikitori.cues([{ id: 'B', vid: 'vid1', chars: [['遅', 30.0, 30.5], ['い', 30.5, 31.5]], lines: [[0, 2]] }], false); return 1;")
    await at(31.1, expect: "", reveals: ["A:0", "A:1", "B:0"])
    // Seeking back before it: drawn in time again.
    await at(29.5, expect: "")
    await at(30.6, expect: "遅い")
    // An ad on its own clock: nothing of the video, even where a cue would be.
    await at(10.3, expect: "", setup: "document.getElementById('movie_player').classList.add('ad-showing');")
    await at(30.6, expect: "遅い", setup: "document.getElementById('movie_player').classList.remove('ad-showing');")
    // Another video's cues never show.
    await at(10.3, expect: "", setup: "document.getElementById('movie_player').getVideoData = () => ({ video_id: 'vid2' });")
    // A seek forward over a cue: it is never posted (the viewer didn't hear it).
    _ = await js("""
        document.getElementById('movie_player').getVideoData = () => ({ video_id: 'vid1' });
        window.__kikitori.cues([{ id: 'C', vid: 'vid1', chars: [['飛', 50.0, 50.5], ['ぶ', 50.5, 51]], lines: [[0, 2]] }], false); return 1;
        """)
    await at(45, expect: "")
    _ = await js("window.fakeT = 60; document.querySelector('video').dispatchEvent(new Event('seeking')); return 1;")
    await at(60.5, expect: "", reveals: ["A:0", "A:1", "B:0"])
    // A cue for the stretch the seek jumped over, arriving afterwards: not posted either…
    _ = await js("window.__kikitori.cues([{ id: 'D', vid: 'vid1', chars: [['跳', 55.0, 55.5]], lines: [[0, 1]] }], false); return 1;")
    await at(61, expect: "", reveals: ["A:0", "A:1", "B:0"])
    // …until the viewer seeks back before it and plays through it.
    _ = await js("window.fakeT = 54; document.querySelector('video').dispatchEvent(new Event('seeking')); return 1;")
    await at(54.5, expect: "飛ぶ")   // spoken at 50–51: still within its 8 s, as playback from there would show
    await at(55.2, expect: "飛ぶ / 跳", reveals: ["A:0", "A:1", "B:0", "D:0"])
    print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}
Task { @MainActor in await run() }
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
