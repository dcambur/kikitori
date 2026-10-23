import KikitoriCore
import SwiftUI
import WebKit

/// The Watch window: the real YouTube (or any video site) page with subtitles on the video.
struct PlayerView: View {
    @Environment(AppModel.self) var model
    @State private var address = ""
    private let player = PlayerController.shared

    var listening: Bool { model.isLive && model.source?.id == PlayerController.sourceID }

    var body: some View {
        WebViewHost(webView: player.webView)
            .frame(minWidth: 640, minHeight: 400)
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
                ToolbarItemGroup {
                    Text(status).font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    Menu {
                        Picker("Show", selection: Binding(get: { model.prefs.subtitleMode }, set: { model.prefs.subtitleMode = $0 })) {
                            ForEach(Preferences.SubtitleMode.allCases, id: \.self) { Text($0.title) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(model.prefs.subtitleMode.title, systemImage: "textformat")
                    }
                    .help("What the subtitles show")
                }
            }
            .onChange(of: player.url) { _, url in address = url?.absoluteString ?? "" }
    }

    /// What the player is doing, in a few words (also the first thing to check when no subtitles come).
    var status: String {
        guard listening else { return player.hasVideo ? "Subtitles off" : "" }
        if !player.tapped { return "Press play to start" }
        if player.audioState != "running" { return "Click the video once to enable audio" }
        let lines = model.session?.lines.count ?? 0
        return "Hearing audio · \(Int(player.heardSeconds)) s · \(lines) line\(lines == 1 ? "" : "s")"
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

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
