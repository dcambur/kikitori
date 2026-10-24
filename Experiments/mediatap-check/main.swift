// EXPERIMENT: checks Sources/Kikitori/Player/MediaTapScript.swift without YouTube.
//
//   swift run kk-check-mediatap <captured audio (.webm or .mp4 from kk-spike-mse)> [--late] [--abort]
//
// A local page with a real MediaSource gets the file in randomly sized appends (1–48 KB), as the
// site's player would, with the production media tap injected at document start. Reports the
// packets it posts: video times covered, gaps, total seconds. --late: appends everything first
// and only then switches the tap on (a session started after the video loaded). --abort: calls
// abort() halfway and skips 64 KB, like a seek (the parser must resync).
import AppKit
import WebKit

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else { print("usage: kk-check-mediatap <file> [--late] [--abort]"); exit(2) }
let late = args.contains("--late"), abort = args.contains("--abort")
let scriptFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../Sources/Kikitori/Player/MediaTapScript.swift").standardized
let swiftSource = try! String(contentsOf: scriptFile, encoding: .utf8)
let script = String(swiftSource[swiftSource.range(of: "#\"\"\"\n")!.upperBound..<swiftSource.range(of: "\"\"\"#")!.lowerBound])
let bytes = try! Data(contentsOf: URL(fileURLWithPath: path))
let mime = path.hasSuffix(".mp4") ? "audio/mp4; codecs=\"mp4a.40.2\"" : "audio/webm; codecs=\"opus\""

final class Sink: NSObject, WKScriptMessageHandler {
    var packets: [(t: Double, end: Double, rate: Double)] = []
    var peak: Float = 0
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "kkLog" { print("  page:", m.body); return }
        guard let b = m.body as? [String: Any], let t = b["t"] as? Double, let r = b["r"] as? Double,
              let pcm = (b["pcm"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return }
        let n = pcm.count / 2
        pcm.withUnsafeBytes { raw in for v in raw.bindMemory(to: Int16.self) { peak = max(peak, abs(Float(v) / 32768)) } }
        packets.append((t, t + Double(n) / r, r))
    }
}

@MainActor func run() async {
    let sink = Sink()
    let config = WKWebViewConfiguration()
    for name in ["kkLog", "kkMedia"] { config.userContentController.add(sink, contentWorld: .page, name: name) }
    config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), configuration: config)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = web; window.orderFrontRegardless()
    web.loadHTMLString("<!doctype html><video muted></video>", baseURL: URL(string: "https://www.youtube.com/")!)
    while web.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
    func js(_ body: String, _ args: [String: Any] = [:]) async -> Any? {
        do { return try await web.callAsyncJavaScript(body, arguments: args, contentWorld: .page) } catch { return "ERROR \(error)" }
    }
    print(await js("""
        const v = document.querySelector('video'); const ms = new MediaSource(); v.src = URL.createObjectURL(ms);
        await new Promise(r => ms.addEventListener('sourceopen', r, { once: true }));
        const real = ms.addSourceBuffer(type);
        // The tap's state hangs off the SourceBuffer; a detached one with the same state takes the
        // appends, so the bytes (garbage after --abort's skip) never reach a real media pipeline.
        window.sb = Object.create(SourceBuffer.prototype); sb.__kikitori = real.__kikitori; window.ms = ms;
        return 'source buffer: ' + type;
        """, ["type": mime]) ?? "nil")
    if !late { _ = await js("window.__kikitoriMedia.setActive(true); return 1;") }
    var offset = 0, pieces = 0, aborted = false
    var rng = SystemRandomNumberGenerator()
    while offset < bytes.count {
        if abort, !aborted, offset > bytes.count / 2 {
            aborted = true
            _ = await js("try { SourceBuffer.prototype.abort.call(window.sb); } catch (e) {} return 1;")
            offset += 65_536
            print("  abort() at \(offset - 65_536), skipped 64 KB")
            continue
        }
        let n = min(bytes.count - offset, Int.random(in: 1_024...49_152, using: &rng))
        let b64 = bytes.subdata(in: offset..<offset + n).base64EncodedString()
        _ = await js("""
            const u8 = Uint8Array.from(atob(b), c => c.charCodeAt(0));
            try { sb.appendBuffer(u8); } catch (e) {}   // the original refuses a detached buffer; the tap ran first
            await new Promise(r => setTimeout(r, 20));
            return 1;
            """, ["b": b64])
        offset += n; pieces += 1
    }
    if late { _ = await js("window.__kikitoriMedia.setActive(true); return 1;") }
    try? await Task.sleep(for: .seconds(2))
    let p = sink.packets.sorted { $0.t < $1.t }
    var gaps: [String] = []
    for (a, b) in zip(p, p.dropFirst()) where abs(b.t - a.end) > 0.03 { gaps.append(String(format: "%.2f→%.2f", a.end, b.t)) }
    let seconds = p.reduce(0) { $0 + $1.end - $1.t }
    print("\(bytes.count) bytes in \(pieces) appends\(late ? ", tap switched on afterwards" : "")")
    print(String(format: "%d packets, %.1f s of audio, %.3f → %.3f, rate %.0f, peak %.2f, gaps: %@", p.count, seconds,
                 p.first?.t ?? -1, p.last?.end ?? -1, p.first?.rate ?? 0, sink.peak, gaps.isEmpty ? "none" : gaps.joined(separator: " ")))
    print("status: \(await js("return JSON.stringify(window.__kikitoriMedia.status());") ?? "nil")")
    exit(0)
}
Task { @MainActor in await run() }
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
