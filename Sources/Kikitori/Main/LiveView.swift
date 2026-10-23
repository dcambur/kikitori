import KikitoriCore
import SwiftUI

/// Main window › Live (spec §5.3).
struct LiveView: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow
    @State private var selection: UUID?
    @State private var showInspector = true
    @State private var search = ""
    @State private var showSourcePicker = false
    @State private var showExport = false
    @State private var showStreamInfo = false
    @State private var following = true
    @State private var newLines = 0

    var lines: [TranscriptLine] { model.session?.lines ?? [] }
    var shown: [TranscriptLine] { search.isEmpty ? lines : lines.filter { $0.matches(search) } }
    var selectedLine: TranscriptLine? { lines.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            if model.isLive || model.state == .starting {
                SessionHeader(showSourcePicker: $showSourcePicker, showStreamInfo: $showStreamInfo)
                Divider()
                IssueBanner()
                transcript
            } else {
                idle
            }
        }
        .navigationTitle(model.activeProfile?.name ?? (model.isLive ? model.source?.name ?? "Live" : "Live"))
        .navigationSubtitle(model.session?.streamTitle ?? "")
        .toolbar { toolbar }
        .searchable(text: $search, placement: .toolbar, prompt: "Search transcript")
        .inspector(isPresented: $showInspector) {
            ExplanationView(line: selectedLine)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.kkInspector)
                .inspectorColumnWidth(min: 280, ideal: 310, max: 400)
        }
        .onChange(of: model.focusRequests) {   // Explain Last Line (hotkey, menus): show it here
            selection = model.explainFocus
            showInspector = true
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(lines: lines, explanations: model.session?.explanations ?? [:],
                        name: [model.activeProfile?.name ?? model.source?.name ?? "kikitori",
                               (model.session?.start ?? .now).formatted(.iso8601.year().month().day())]
                            .joined(separator: " – "))
        }
    }

    var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { line in
                        TranscriptRow(line: line, selected: line.id == selection, pending: model.pendingLines.contains(line.id),
                                      textSize: model.prefs.transcriptTextSize, mode: model.prefs.transcriptMode,
                                      highlight: search, replay: model.replayControl(for: line))
                            .id(line.id)
                            .onTapGesture { select(line) }
                            .contextMenu { rowMenu(line) }
                    }
                    if search.isEmpty {
                        LiveLineSlot(textSize: model.prefs.transcriptTextSize,
                                     placeholder: shown.isEmpty ? "Waiting for Japanese speech…" : nil,
                                     proxy: following ? proxy : nil)
                    } else if shown.isEmpty {
                        Text("No lines match ‘\(search)’.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { following = true; newLines = 0 }
                        .onDisappear { following = false }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: lines.count) { old, new in
                if following { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                else { newLines += max(new - old, 0) }
            }
            .overlay(alignment: .bottom) {
                if !following && newLines > 0 {
                    Button { proxy.scrollTo("bottom", anchor: .bottom); newLines = 0 } label: {
                        Label("Jump to Live · \(newLines) new line\(newLines == 1 ? "" : "s")", systemImage: "arrow.down")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    var idle: some View {
        VStack(spacing: 14) {
            Image(systemName: "captions.bubble").font(.system(size: 44)).foregroundStyle(Color.kkAccent)
            Text("Not listening").font(.title2.bold())
            Text("Pick the app that plays the stream. kikitori hears only that app.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Watch YouTube in kikitori") { openWatch(openWindow) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Listen to an App…") { showSourcePicker = true }
                    .controlSize(.large)
                    .popover(isPresented: $showSourcePicker, arrowEdge: .bottom) { SourcePickerView() }
            }
            Text("The built-in player puts subtitles on the video itself.")
                .font(.callout).foregroundStyle(.secondary)
            if let issue = model.topIssue { Text(AppModel.shortText(issue)).foregroundStyle(Color.kkDanger) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if model.isLive { StatusChip() }
        }
        ToolbarItemGroup {
            if model.isLive {
                Button { Task { await model.togglePause() } } label: {
                    Label(model.state == .paused ? "Resume" : "Pause",
                          systemImage: model.state == .paused ? "play.fill" : "pause.fill")
                }
                .help(model.state == .paused ? "Resume listening" : "Pause listening")
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }.help("Stop listening")
            }
            Toggle(isOn: Binding(get: { model.prefs.overlayVisible }, set: { model.prefs.overlayVisible = $0 })) {
                Label("Subtitles", systemImage: "captions.bubble")
            }
            .help("Show subtitles")
            TranscriptModeMenu()
        }
        ToolbarItemGroup {
            Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(lines.isEmpty)
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    @ViewBuilder func rowMenu(_ line: TranscriptLine) -> some View {
        Button("Explain") { select(line) }
        Button("Explain Again") { model.explain(line, again: true) }
        ReplayMenuItems(line: line)
        Divider()
        Button("Copy English") { copy(line.en ?? "") }
        Button("Copy Japanese") { copy(line.ja) }
        Button("Copy Both with Time") { copy("\(TranscriptExport.clock(line.time))  \(line.ja)\n\(line.en ?? "")") }
        if let term = line.term, let profile = model.activeProfile {
            Divider()
            Button("Add “\(term)” to \(profile.name)’s Glossary") {
                var p = profile
                if !p.glossary.contains(where: { $0.term == term }) {
                    p.glossary.append(GlossaryTerm(term: term, meaning: line.note ?? ""))
                    model.upsert(p)
                }
            }
        }
    }

    func select(_ line: TranscriptLine) {
        selection = line.id
        showInspector = true
        if line.en != nil { model.explain(line) }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Japanese & English · Japanese · English, for the transcript panels.
struct TranscriptModeMenu: View {
    @Environment(AppModel.self) var model
    var body: some View {
        Picker(selection: Binding(get: { model.prefs.transcriptMode }, set: { model.prefs.transcriptMode = $0 })) {
            ForEach(Preferences.TranscriptMode.allCases, id: \.self) { Text($0.title) }
        } label: {
            Label("Show", systemImage: "textformat")
        }
        .pickerStyle(.menu)
        .help("What the transcript shows")
    }
}

/// Hear a line again: normal speed, slower, or on a loop (its audio stays in memory for about
/// half an hour, this session only).
struct ReplayMenuItems: View {
    @Environment(AppModel.self) var model
    let line: TranscriptLine
    var body: some View {
        if model.canReplay(line) {
            Divider()
            if model.replaying == line.time {
                Button("Stop Playing") { model.stopReplay() }
            } else {
                Button("Play Audio") { model.replay(line) }
                Button("Play Audio Slower") { model.replay(line, rate: 0.75) }
                Button("Loop Audio") { model.replay(line, loop: true) }
            }
        }
    }
}

/// “Translating · ≈ 2.9 s” chip; amber over 3.5 s, red over 6 s (spec §4).
struct StatusChip: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let latency = model.latency ?? 0
        let tint: Color = model.topIssue != nil ? .kkNote : latency > 6 ? .kkDanger : latency > 3.5 ? .kkNote : .kkAccent
        Text(model.statusText)
            .font(.callout.weight(.medium)).monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(tint.opacity(0.12), in: .capsule)
            .accessibilityLabel(model.latency.map { "About \(String(format: "%.1f", $0)) seconds behind" } ?? model.statusText)
    }
}

/// Source · Profile · Stream · Duration · Cost (spec §5.3).
struct SessionHeader: View {
    @Environment(AppModel.self) var model
    @Binding var showSourcePicker: Bool
    @Binding var showStreamInfo: Bool

    var body: some View {
        // Wraps instead of squeezing (see FlowLayout): too narrow a row crashed the app.
        FlowLayout(spacing: 16, lineSpacing: 6) {
            field("Source") {
                Button { showSourcePicker = true } label: {
                    HStack(spacing: 4) {
                        if let source = model.source { AppIcon(bundleID: source.id, size: 16) }
                        Text(model.source?.name ?? "—")
                    }
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showSourcePicker, arrowEdge: .bottom) { SourcePickerView() }
            }
            field("Profile") { ProfileMenu() }
            Button { showStreamInfo = true } label: {
                Text(model.session?.streamTitle.isEmpty == false ? model.session!.streamTitle : "Add stream info…")
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: 260, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .popover(isPresented: $showStreamInfo) { StreamInfoForm().padding().frame(width: 320) }
            if let s = model.session {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    field("Duration") { Text(TranscriptExport.clock(s.duration)).monospacedDigit().bold() }
                }
                field("Cost") { Text(Money.format(s.cost)).monospacedDigit().bold() }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 8)
    }

    func field<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 6) { Text(label).foregroundStyle(.secondary); value() }.lineLimit(1).fixedSize()
    }
}

struct StreamInfoForm: View {
    @Environment(AppModel.self) var model
    var body: some View {
        Form {
            TextField("Stream title", text: Binding(get: { model.session?.streamTitle ?? "" },
                                                    set: { model.session?.streamTitle = $0 }))
            TextField("Game or topic", text: Binding(get: { model.session?.game ?? "" }, set: { model.session?.game = $0 }))
            Text("Sent to Claude as context. Type it or paste it from the stream page.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onSubmit { model.contextChanged() }
        .onDisappear { model.contextChanged() }
    }
}

struct ProfileMenu: View {
    @Environment(AppModel.self) var model
    var body: some View {
        Menu(model.activeProfile?.name ?? "No Profile") {
            ForEach(model.profiles) { p in
                Toggle(p.name, isOn: Binding(get: { model.activeProfileID == p.id }, set: { if $0 { model.activeProfileID = p.id } }))
            }
            Toggle("No Profile", isOn: Binding(get: { model.activeProfileID == nil }, set: { if $0 { model.activeProfileID = nil } }))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Warning/error banner in the window (spec §5.10, “window banner” column).
struct IssueBanner: View {
    @Environment(AppModel.self) var model
    @Environment(\.openSettings) var openSettings

    var body: some View {
        if let issue = model.topIssue {
            HStack(spacing: 10) {
                Image(systemName: issue.blocking ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(issue.blocking ? Color.kkDanger : Color.kkNote)
                Text(Self.text(issue)).font(.callout)
                Spacer()
                switch issue {
                case .permissionRevoked:
                    Button("Open System Settings") { openPrivacySettings() }
                case .capReached:
                    Button("Translate This Session Anyway") { model.translateAnyway() }
                case .keyInvalid, .noKey:
                    Button("Update Key…") { openSettings() }
                case .creditsExhausted:
                    Link("Claude Console", destination: URL(string: "https://console.anthropic.com")!)
                default: EmptyView()
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(issue.blocking ? Color.kkDanger.opacity(0.1) : Color.kkNoteBackground)
        }
    }

    static func text(_ issue: AppModel.Issue) -> String {
        switch issue {
        case .permissionRevoked: "kikitori can no longer hear apps. Turn on kikitori in Screen & System Audio Recording, then press Resume."
        case .sourceQuit(let name): "\(name) quit. Choose the app again when it’s back, or pick another source."
        case .modelUnavailable(let m): "The speech model can’t be loaded: \(m)"
        case .keyInvalid: "Your API key stopped working. Japanese subtitles keep going."
        case .noKey: "No Claude API key yet. Add one to get English subtitles; Japanese works without it."
        case .creditsExhausted: "Your Claude account has no API credits left. Claim this month’s Max credits or add credits in the Claude Console."
        case .capReached: "Monthly cap reached. Translation is paused; Japanese subtitles keep working."
        case .offline: "Offline · Japanese only. Translation resumes when the connection is back."
        case .apiOutage: "Claude isn’t responding · Japanese only."
        case .rateLimited: "Claude is busy. Retrying · Japanese only meanwhile."
        case .fallingBehind: "Skipped ahead to live. Missed lines are in the transcript."
        case .noAudio(let name): "No sound from \(name). Is the stream paused or muted?"
        }
    }
}

func openPrivacySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
}

struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 28
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").frame(width: size, height: size)
        }
    }
}
