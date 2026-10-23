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
                }
                ToolbarItem(placement: .principal) {
                    TextField("Paste a YouTube link or search", text: $address)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 320, idealWidth: 460)
                        .onSubmit { player.load(address) }
                }
                ToolbarItemGroup {
                    Picker("Subtitles", selection: Binding(get: { model.prefs.subtitleMode }, set: { model.prefs.subtitleMode = $0 })) {
                        ForEach(Preferences.SubtitleMode.allCases, id: \.self) { Text($0.title) }
                    }
                    .help("What the subtitles show")
                    Button { toggleListening() } label: {
                        Label(listening ? "Stop Subtitles" : "Subtitles", systemImage: listening ? "captions.bubble.fill" : "captions.bubble")
                    }
                    .help(listening ? "Stop subtitles" : "Start subtitles for this video")
                }
            }
            .onChange(of: player.url) { _, url in address = url?.absoluteString ?? "" }
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
