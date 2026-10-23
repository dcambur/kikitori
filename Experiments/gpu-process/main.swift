// EXPERIMENT (spike for docs/design/realtime-sync.md), not product code.
//
//   swift run kk-spike-gpu [url]
//
// Two muted WKWebViews in one process (one on the default data store, one on a separate
// non-persistent store, as a hidden look-ahead player would be) both play the video. Lists the
// WebKit processes macOS holds this process responsible for: if there is one GPU process, both
// players' sound comes out of the same process and a process tap cannot separate them.
import AppKit
import Darwin
import WebKit

let url = URL(string: CommandLine.arguments.dropFirst().first ?? "https://www.youtube.com/watch?v=kLFsqvruEFs&t=600s")!
let responsibleFor: (@convention(c) (pid_t) -> pid_t)? = {
    guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(s, to: (@convention(c) (pid_t) -> pid_t).self)
}()

/// WebKit processes attributed to the same responsible app as this process (a tool run from a
/// shell is attributed to the terminal app, and so are the WebKit processes it starts).
func webKitProcesses() -> [(pid_t, String)] {
    let me = responsibleFor?(getpid()) ?? getpid()
    var count = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(count) * 2)
    count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return pids.prefix(Int(count)).compactMap { pid in
        guard pid > 0, responsibleFor?(pid) == me, pid != getpid() else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        proc_pidpath(pid, &path, UInt32(path.count))
        let name = URL(fileURLWithPath: String(cString: path)).lastPathComponent
        return name.hasPrefix("com.apple.WebKit") ? (pid, name) : nil
    }
}

@MainActor func run() async {
    let before = Set(webKitProcesses().map(\.0))
    func make(_ store: WKWebsiteDataStore, y: CGFloat) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(source: "setInterval(() => document.querySelectorAll('video').forEach(v => { v.muted = true; if (v.paused) v.play().catch(()=>{}); }), 100);",
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 270), configuration: config)
        let mute = NSSelectorFromString("_setPageMuted:")
        if web.responds(to: mute) {
            typealias Fn = @convention(c) (AnyObject, Selector, UInt) -> Void
            unsafeBitCast(web.method(for: mute), to: Fn.self)(web, mute, 1)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: y, width: 480, height: 270), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "kk-spike-gpu (muted)"
        window.contentView = web
        window.orderFrontRegardless()
        web.load(URLRequest(url: url))
        return web
    }
    let a = make(.default(), y: 0)
    let b = make(.nonPersistent(), y: 300)
    try? await Task.sleep(for: .seconds(15))
    let playing = { (w: WKWebView) async -> String in "\((try? await w.callAsyncJavaScript("const v = document.querySelector('video'); return v ? (v.paused ? 'paused' : 'playing ' + v.currentTime.toFixed(1)) : 'no video'", contentWorld: .page)) ?? "?")" }
    print("player A (default store): \(await playing(a)); player B (separate store): \(await playing(b))")
    print("WebKit processes started for these two players:")
    for (pid, name) in webKitProcesses().filter({ !before.contains($0.0) }).sorted(by: { $0.1 < $1.1 }) { print("  \(pid) \(name)") }
    exit(0)
}
Task { @MainActor in await run() }
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
