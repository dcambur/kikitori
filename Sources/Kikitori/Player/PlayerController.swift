import AppKit
import KikitoriCore
import Observation
import WebKit
import os

/// The built-in player: a WKWebView showing the real site, with our script injected, shown in the
/// main window's Watch section. It is an audio source for the pipeline (a tap on our own WebKit
/// process) and the place where subtitles are drawn, on the video itself.
@MainActor @Observable
final class PlayerController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = PlayerController()
    static let sourceID = "kikitori.player"

    let webView: WKWebView
    var title = ""
    var url: URL?
    var paused = true
    var hasVideo = false
    /// True while the web view is in a window (the Watch section is showing, or full screen).
    /// Off screen during a player session, the floating overlay shows the subtitles instead.
    var isOnScreen = false

    @ObservationIgnored private let log = Logger(subsystem: "app.kikitori", category: "player")
    @ObservationIgnored private var lastStateLog = Date.distantPast
    @ObservationIgnored private var lastShown = ""
    /// The view hosting the web view now; WebKit's full screen gives the web view back to it.
    @ObservationIgnored weak var host: WebViewHost.HostView?
    @ObservationIgnored private var fullscreenObservation: NSKeyValueObservation?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // stays signed in between launches
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: PlayerScript.source, injectionTime: .atDocumentEnd,
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
        observePlayback()
        fullscreenObservation = webView.observe(\.fullscreenState) { [weak self] web, _ in
            // Leaving full screen puts the web view back where it was; if the Watch section was
            // rebuilt meanwhile, that is an old host: move it to the current one.
            MainActor.assumeIsolated {
                guard let self, web.fullscreenState == .notInFullscreen else { return }
                if let host = self.host, host.window != nil { host.adopt() } else { self.isOnScreen = web.window != nil }
            }
        }
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

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {   // WebKit delivers script messages on the main thread
            let body = message.body as? [String: Any] ?? (message.body as? String).map { ["message": $0] } ?? [:]
            handle(message.name, body)
        }
    }

    private func handle(_ name: String, _ body: [String: Any]) {
        switch name {
        case "kkState":
            // Sent every 500 ms: assign only what changed, so views redraw only when something did.
            let paused = body["paused"] as? Bool ?? true
            let hasVideo = body["hasVideo"] as? Bool ?? false
            let title = (body["title"] as? String ?? "").replacingOccurrences(of: " - YouTube", with: "")
            let url = (body["url"] as? String).flatMap(URL.init(string:))
            if paused != self.paused { self.paused = paused }
            if hasVideo != self.hasVideo { self.hasVideo = hasVideo }
            if title != self.title { self.title = title }
            if url != self.url { self.url = url }
            if Date.now.timeIntervalSince(lastStateLog) > 5 {
                lastStateLog = .now
                log.notice("state video=\(hasVideo) paused=\(paused) lines=\(AppModel.shared.session?.lines.count ?? 0)")
            }
        case "kkLog":
            log.notice("page: \(body["message"] as? String ?? "", privacy: .public)")
        case "kkExplain":
            let model = AppModel.shared
            if let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)),
               let line = model.session?.lines.first(where: { $0.id == id }) {
                // The explanation shows beside the video, which full screen would hide.
                if webView.fullscreenState != .notInFullscreen { webView.closeAllMediaPresentations(completionHandler: nil) }
                model.focusExplanation(line)
            }
        default: break
        }
    }

    /// Pause the video when nobody can see or hear it on purpose: off screen (another section, or
    /// the window closed) with no player session. Checked a moment after a change, so a view that
    /// is only being rebuilt doesn't count.
    private func observePlayback() {
        withObservationTracking {
            _ = isOnScreen
            _ = AppModel.shared.state
            _ = AppModel.shared.source
        } onChange: {
            Task { @MainActor in
                self.observePlayback()
                try? await Task.sleep(for: .milliseconds(500))
                let model = AppModel.shared
                let session = model.state != .idle && model.source?.id == Self.sourceID
                if !self.isOnScreen, !(self.webView.window?.isVisible ?? false), !session { self.webView.pauseAllMediaPlayback(completionHandler: nil) }
            }
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
