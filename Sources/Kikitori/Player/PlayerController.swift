import AppKit
import KikitoriCore
import Observation
import WebKit
import os

/// The built-in player: a WKWebView showing the real site, with our script injected.
/// It is an audio source for the pipeline (no system-audio permission needed) and the place
/// where subtitles are drawn, on the video itself.
@MainActor @Observable
final class PlayerController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = PlayerController()
    static let sourceID = "kikitori.player"

    let webView: WKWebView
    var title = ""
    var url: URL?
    var videoTime: Double = -1
    var paused = true
    var isLive = false
    var hasVideo = false
    /// Web Audio state in the page ("running", "suspended", "none") and whether the video is tapped.
    var audioState = "none"
    var tapped = false
    /// Seconds of page audio received this session.
    var heardSeconds: Double = 0

    @ObservationIgnored private var capture: PageAudioCapture?
    @ObservationIgnored private let log = Logger(subsystem: "app.kikitori", category: "player")
    @ObservationIgnored private var lastStateLog = Date.distantPast
    @ObservationIgnored private var lastShown = ""

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // stays signed in between launches
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: PlayerScript.source(hear: true), injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .page))
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        // Safari's user agent: Google refuses sign-in for unknown embedded browsers more often.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        for name in ["kkState", "kkExplain", "kkLog"] { controller.add(self, contentWorld: .page, name: name) }
        webView.navigationDelegate = self
        load("https://www.youtube.com")
        observeSubtitles()
    }

    /// A link, a video id or search words.
    func load(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let target: URL?
        if text.contains("."), let u = URL(string: text.hasPrefix("http") ? text : "https://\(text)") {
            target = u
        } else {
            var c = URLComponents(string: "https://www.youtube.com/results")!
            c.queryItems = [URLQueryItem(name: "search_query", value: text)]
            target = c.url
        }
        if let target { webView.load(URLRequest(url: target)) }
    }

    /// A fresh audio stream for a new listening session.
    /// The capture for a new session: a system audio tap on this app's own WebKit process, which
    /// is where the player's sound plays. The process appears once the page first plays sound,
    /// so the tap starts as soon as it exists.
    func makeAnyCapture() throws -> any AudioCapture {
        let deferred = DeferredTapCapture()
        let log = self.log
        deferred.start(find: { AudioSources.ownWebKitProcesses() }, onStart: { count in
            log.notice("process tap started on \(count) WebKit process(es)")
        })
        return deferred
    }

    func makeCapture() -> PageAudioCapture {
        capture?.stop()
        let c = PageAudioCapture()
        capture = c
        return c
    }

    func stopCapture() {
        capture?.stop()
        capture = nil
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        let name = message.name
        let body = message.body as? [String: Any] ?? (message.body as? String).map { ["message": $0] } ?? [:]
        MainActor.assumeIsolated { handle(name, body) }
    }

    private func handle(_ name: String, _ body: [String: Any]) {
        switch name {
        case "kkState":
            videoTime = body["t"] as? Double ?? -1
            paused = body["paused"] as? Bool ?? true
            isLive = body["live"] as? Bool ?? false
            hasVideo = body["hasVideo"] as? Bool ?? false
            if Date.now.timeIntervalSince(lastStateLog) > 5 {
                lastStateLog = .now
                log.notice("state video=\(self.hasVideo) paused=\(self.paused) lines=\(AppModel.shared.session?.lines.count ?? 0)")
            }
            title = (body["title"] as? String ?? "").replacingOccurrences(of: " - YouTube", with: "")
            url = (body["url"] as? String).flatMap(URL.init(string:))
        case "kkLog":
            log.notice("page: \(body["message"] as? String ?? "", privacy: .public)")
        case "kkExplain":
            let model = AppModel.shared
            if let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)),
               let line = model.session?.lines.first(where: { $0.id == id }) {
                model.explain(line)
                openMainWindow()
            }
        default: break
        }
    }

    /// Push the latest lines into the page whenever they or the display mode change.
    private func observeSubtitles() {
        withObservationTracking {
            _ = AppModel.shared.overlayRevision
            _ = AppModel.shared.pendingLines
            _ = AppModel.shared.prefs.subtitleMode
            _ = AppModel.shared.prefs.overlayLines
        } onChange: {
            Task { @MainActor in self.pushSubtitles(); self.observeSubtitles() }
        }
    }

    func pushSubtitles() {
        let model = AppModel.shared
        guard model.source?.id == Self.sourceID else { if !lastShown.isEmpty { show([]) }; return }
        let lines = (model.session?.lines ?? []).suffix(model.prefs.overlayLines).map { line -> [String: Any] in
            ["id": line.id.uuidString, "ja": line.ja, "en": line.en ?? "", "term": line.term ?? "",
             "pending": model.pendingLines.contains(line.id)]
        }
        show(Array(lines))
    }

    private func show(_ lines: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: lines),
              let json = String(data: data, encoding: .utf8) else { return }
        let mode = AppModel.shared.prefs.subtitleMode.rawValue
        let script = "window.__kikitori && window.__kikitori.show(\(json), '\(mode)')"
        guard script != lastShown else { return }
        lastShown = lines.isEmpty ? "" : script
        webView.evaluateJavaScript(script, in: nil, in: .page)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { lastShown = ""; pushSubtitles() }
    }
}
