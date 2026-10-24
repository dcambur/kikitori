import KikitoriCore
import SwiftUI
import WebKit

/// Main window › Watch: the real YouTube (or any video site) page with Japanese subtitles on the
/// video as they are heard, and a panel beside it with the translated transcript and explanations.
struct PlayerView: View {
    @Environment(AppModel.self) var model
    @State private var address = ""
    @AppStorage("watchInspector") private var showInspector = false
    private let player = PlayerController.shared

    var listening: Bool { model.isLive && model.source?.id == PlayerController.sourceID }

    var body: some View {
        WebViewHost(player: player)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if listening {
                    Label(status, systemImage: "waveform")
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.75), in: .capsule).foregroundStyle(.white)
                        .padding(12).allowsHitTesting(false)
                }
            }
            .navigationTitle(player.title.isEmpty ? "Watch" : player.title)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { player.webView.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    Button { player.webView.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    Button { toggleListening() } label: {
                        Label(listening ? "Stop Subtitles" : "Start Subtitles",
                              systemImage: listening ? "captions.bubble.fill" : "captions.bubble")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(listening ? .secondary : Color.kkAccentFill)
                }
                ToolbarItem(placement: .principal) {
                    TextField("Paste a YouTube link or search", text: $address)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 220, idealWidth: 380, maxWidth: 460)
                        .onSubmit { player.load(address) }
                }
                // The same controls, in the same place, as Live's toolbar.
                ToolbarItemGroup {
                    TranslateToggle()
                    TranscriptModeMenu()
                    Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                        .help(showInspector ? "Hide Inspector (transcript and explanations)" : "Show Inspector (transcript and explanations)")
                        .keyboardShortcut("i", modifiers: [.command, .option])
                }
            }
            .inspector(isPresented: $showInspector) {
                WatchInspector()
                    .background(Color.kkInspector)
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
            .onAppear { address = player.url?.absoluteString ?? "" }
            .onChange(of: player.url) { _, url in address = url?.absoluteString ?? "" }
            .onChange(of: model.focusRequests) { showInspector = true }
    }

    /// What the player is doing, in a few words (also the first thing to check when no subtitles come).
    var status: String {
        guard listening else { return "" }
        if model.state == .paused { return "Subtitles paused" }
        if player.paused { return "Press play" }
        let lines = model.session?.lines.count ?? 0
        let mode = model.synced ? "Synced" : "Listening"
        return lines == 0 ? "\(mode)…" : "\(mode) · \(lines) line\(lines == 1 ? "" : "s")"
    }

    func toggleListening() {
        if listening { model.stop(); return }
        Task {
            if model.isLive { model.stop() }
            await model.start(source: AudioSource(id: PlayerController.sourceID, name: "kikitori Player", pid: 0,
                                                  processObjects: [], isPlaying: true))
        }
    }
}

/// Beside the video: the explanation of the selected line (a clicked row, Explain Last Line) and
/// the session's transcript, which follows the newest line. Translate and Show are in the toolbar.
struct WatchInspector: View {
    @Environment(AppModel.self) var model
    /// True while the end of the transcript is in view: only then do new lines scroll it.
    @State private var following = true

    var lines: [TranscriptLine] { model.session?.lines ?? [] }
    var focused: TranscriptLine? { lines.first { $0.id == model.explainFocus } }

    var body: some View {
        VStack(spacing: 0) {
            if let focused {
                ExplanationView(line: focused, compact: true)
                    .frame(minHeight: 140, maxHeight: 340, alignment: .top)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            row(line)
                        }
                        LiveLineSlot(textSize: model.prefs.transcriptTextSize - 1,
                                     placeholder: lines.isEmpty ? (model.isLive ? "Waiting for Japanese speech…"
                                                                  : "Press Start Subtitles to see the transcript here.") : nil,
                                     proxy: following ? proxy : nil)
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { following = true }
                            .onDisappear { following = false }
                    }
                    .padding(8)
                }
                .defaultScrollAnchor(.bottom)
                .modifier(TranscriptKeys(lines: lines, selection: Binding(get: { model.explainFocus }, set: { model.explainFocus = $0 }),
                                         proxy: proxy) { line in
                    if !model.pendingLines.contains(line.id) { model.focusExplanation(line) }
                })
                .onChange(of: lines.last?.id) {
                    if following { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
        }
    }

    func row(_ line: TranscriptLine) -> some View {
        TranscriptRow(line: line, selected: line.id == model.explainFocus, pending: model.pendingLines.contains(line.id),
                      textSize: model.prefs.transcriptTextSize - 1, mode: model.prefs.transcriptMode,
                      replay: model.replayControl(for: line), speakerNames: model.session?.speakerNames ?? [:])
            .id(line.id)
            .onTapGesture(count: 2) { if !model.pendingLines.contains(line.id) { model.focusExplanation(line) } }
            .onTapGesture { model.explainFocus = line.id }
            .contextMenu {
                Button("Explain") { model.focusExplanation(line) }.disabled(model.pendingLines.contains(line.id))
                ReplayMenuItems(line: line)
                if let speaker = line.speaker { SpeakerMenu(label: speaker) }
            }
    }
}

/// Hosts the one shared web view. It moves to a new host each time the Watch section is shown;
/// a host lets it go only while it still holds it, so a newer host is never emptied, and never
/// takes it back from WebKit's full-screen window.
struct WebViewHost: NSViewRepresentable {
    let player: PlayerController

    func makeNSView(context: Context) -> HostView { HostView(player: player) }
    func updateNSView(_ view: HostView, context: Context) { view.adopt() }
    static func dismantleNSView(_ view: HostView, coordinator: ()) { view.release() }

    final class HostView: NSView {
        let player: PlayerController

        init(player: PlayerController) {
            self.player = player
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        private var closing: NSObjectProtocol?

        func adopt() {
            let web = player.webView
            guard window != nil, web.superview !== self, web.fullscreenState == .notInFullscreen else { return }
            web.removeFromSuperview()
            web.frame = bounds
            web.autoresizingMask = [.width, .height]
            addSubview(web)
        }

        func release() {
            if player.webView.superview === self { player.webView.removeFromSuperview() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closing { NotificationCenter.default.removeObserver(closing) }
            closing = nil
            guard let window else {
                // In full screen the web view is in WebKit's own window: still on screen.
                if player.host === self, player.webView.window == nil { player.isOnScreen = false }
                return
            }
            player.host = self
            player.isOnScreen = true
            adopt()
            // A closed window may keep its views: count it as off screen right away.
            closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                             queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self, self.player.host === self { self.player.isOnScreen = false } }
            }
        }
    }
}
