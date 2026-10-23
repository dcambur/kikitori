import KikitoriCore
import SwiftUI

/// Subtitles (spec §5.2): 1–4 lines, newest at the bottom, one status pill at most.
struct OverlayView: View {
    @Environment(AppModel.self) var model
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var hovering = false
    @State private var lastLineAt = Date.now
    @State private var explaining: TranscriptLine?

    var prefs: Preferences { model.prefs }
    /// The newest lines, unless speech stopped a while ago: then new live words show alone. Over
    /// the built-in player in full screen, only lines with English (or on their way to it): the
    /// video already shows the Japanese.
    var lines: [TranscriptLine] {
        guard Date.now.timeIntervalSince(lastLineAt) <= 8 else { return [] }
        let recent = Array((model.session?.lines ?? []).suffix(prefs.overlayLines))
        return englishOverVideo ? recent.filter { $0.en != nil || model.pendingLines.contains($0.id) } : recent
    }
    /// Over the built-in player in full screen, the video already has the Japanese.
    var englishOverVideo: Bool { model.source?.id == PlayerController.sourceID && PlayerController.shared.isFullScreen }
    var japaneseOnly: Bool { model.topIssue?.japaneseOnly == true }
    var idle: Bool { Date.now.timeIntervalSince(lastLineAt) > 8 && model.hearing.isEmpty }
    /// The words being heard now, under the lines (not in English-only mode).
    var liveLine: String? {
        let mode = japaneseOnly ? Preferences.SubtitleMode.japaneseOnly : prefs.subtitleMode
        return model.hearing.isEmpty || mode == .englishOnly || englishOverVideo ? nil : model.hearing
    }

    var textColor: Color { prefs.overlayStyle == .light ? Color(hex: 0x111114) : .white }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 6) {
                if let issue = model.topIssue { StatusPill(issue: issue) }
                else if model.state == .paused { pill("Paused · ⌃⌥P to resume", symbol: "pause.fill") }
                if idle || (lines.isEmpty && liveLine == nil) {
                    if !(prefs.hideWhenSilent && model.topIssue == nil && model.state != .paused) || lines.isEmpty {
                        pill(lines.isEmpty ? "Waiting for Japanese speech…" : "Listening", symbol: "ear")
                    }
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                            lineView(line, older: i < lines.count - 1 || liveLine != nil)
                                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        }
                        if let liveLine {
                            Text(liveLine).font(.japanese(prefs.textSize.english * 0.8, weight: .semibold))
                                .foregroundStyle(textColor.opacity(0.75)).japaneseText()
                                .multilineTextAlignment(.center)
                        }
                    }
                    .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.18), value: lines.map(\.id))
                    .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 14)
                    .frame(minWidth: 360, maxWidth: 900)
                    .background(background)
                    .overlay(alignment: .topTrailing) { if hovering { controls.offset(y: -36) } }
                    .overlay(alignment: .topLeading) {
                        if hovering || prefs.alwaysShowDelay, let latency = model.latency {
                            pill(String(format: "≈ %.1f s behind", latency), symbol: "clock").offset(y: -36)
                        }
                    }
                }
            }
            .padding(.top, 40)
            .fixedSize()
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onChange(of: model.overlayRevision) { lastLineAt = .now }
        .contextMenu { menu }
        .popover(item: $explaining) { line in
            ExplanationView(line: line, compact: true).frame(width: 440).environment(\.colorScheme, .dark)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Subtitles. \(lines.last?.en ?? lines.last?.ja ?? ""). \(model.statusText)")
        .accessibilityAction(named: "Pause") { Task { await model.togglePause() } }
        .accessibilityAction(named: "Explain Last Line") { explainLast() }
    }

    @ViewBuilder func lineView(_ line: TranscriptLine, older: Bool) -> some View {
        let size = prefs.textSize
        let opacity = older ? 0.62 : 1
        let pending = model.pendingLines.contains(line.id)
        // Japanese only while translation is off (offline, cap): the mode can't show English then.
        let mode = englishOverVideo ? .englishOnly : japaneseOnly ? Preferences.SubtitleMode.japaneseOnly : prefs.subtitleMode
        let japaneseMain = mode == .japaneseMain || mode == .japaneseOnly || (line.en == nil && !pending)
        VStack(spacing: 2) {
            if japaneseMain {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.ja).font(.japanese(size.english * 0.9, weight: .bold)).foregroundStyle(textColor.opacity(opacity))
                        .japaneseText()
                    noteChip(line, size: size)
                }
                if mode == .japaneseMain {
                    if let en = line.en { Text(en).font(.overlay(size.japanese)).foregroundStyle(textColor.opacity(0.82 * opacity)) }
                    else if pending { TranslatingDots(color: textColor.opacity(0.7)).frame(height: size.japanese) }
                }
            } else {
                if mode == .englishMain {
                    Text(line.ja).font(.japanese(size.japanese)).foregroundStyle(textColor.opacity(0.8 * opacity)).japaneseText()
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let en = line.en { Text(en).font(.overlay(size.english)).foregroundStyle(textColor.opacity(opacity)) }
                    else { TranslatingDots(color: textColor.opacity(0.7)).frame(height: size.english) }
                    noteChip(line, size: size)
                }
            }
        }
        .multilineTextAlignment(.center)
        .shadow(color: prefs.overlayStyle == .outline ? .black : .clear, radius: 2)
        .onTapGesture { if line.en != nil { explaining = line } }
    }

    @ViewBuilder func noteChip(_ line: TranscriptLine, size: Preferences.TextSize) -> some View {
        if line.term != nil {
            Button { explaining = line } label: {
                Text("注").font(.system(size: size.english * 0.55, weight: .bold))
                    .foregroundStyle(Color.overlayNote)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.overlayNoteBackground, in: .rect(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Has a note: \(line.term ?? "")")
        }
    }

    @ViewBuilder var background: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        switch prefs.overlayStyle {
        case .outline: Color.clear
        case .light:
            shape.fill(Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255).opacity(0.8))
        case .dark:
            if reduceTransparency || prefs.overlayOpacity >= 1 {
                shape.fill(Color.overlaySolid)
            } else {
                shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    .overlay(shape.fill(Color.overlayFill.opacity(prefs.overlayOpacity)))
                    .overlay(shape.strokeBorder(.white.opacity(hovering ? 0.22 : 0), lineWidth: 1))
            }
        }
    }

    var controls: some View {
        HStack(spacing: 2) {
            control(model.state == .paused ? "play.fill" : "pause.fill", model.state == .paused ? "Resume listening" : "Pause listening") {
                Task { await model.togglePause() }
            }
            control("text.bubble", "Explain last line") { explainLast() }
            control("list.bullet", "Open transcript") { openMainWindow(.live) }
            control(prefs.clickThrough ? "cursorarrow.slash" : "cursorarrow", "Click-through") { prefs.clickThrough.toggle() }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: .capsule)
        .environment(\.colorScheme, .dark)
        .accessibilityLabel("Subtitle controls")
    }

    func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 24) }
            .buttonStyle(.plain).foregroundStyle(.white).help(label).accessibilityLabel(label)
    }

    func pill(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.medium)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.overlaySolid.opacity(0.85), in: .capsule)
    }

    @ViewBuilder var menu: some View {
        Button(model.state == .paused ? "Resume" : "Pause") { Task { await model.togglePause() } }
        Button("Explain Last Line") { explainLast() }
        Button("Open Transcript") { openMainWindow(.live) }
        Divider()
        Picker("Show", selection: Binding(get: { prefs.subtitleMode }, set: { prefs.subtitleMode = $0 })) {
            ForEach(Preferences.SubtitleMode.allCases, id: \.self) { Text($0.title) }
        }
        Picker("Lines", selection: Binding(get: { prefs.overlayLines }, set: { prefs.overlayLines = $0 })) {
            ForEach(1...4, id: \.self) { Text("\($0)") }
        }
        Picker("Text Size", selection: Binding(get: { prefs.textSize }, set: { prefs.textSize = $0 })) {
            ForEach(Preferences.TextSize.allCases, id: \.self) { Text($0.rawValue) }
        }
        Picker("Position", selection: Binding(get: { prefs.position }, set: { prefs.position = $0 })) {
            ForEach(Preferences.Position.allCases, id: \.self) { Text($0.rawValue) }
        }
        Toggle("Click-Through", isOn: Binding(get: { prefs.clickThrough }, set: { prefs.clickThrough = $0 }))
        Divider()
        Button("Hide Subtitles") { prefs.overlayVisible = false }
    }

    func explainLast() {
        guard let line = model.lastLine else { return }
        explaining = line
        model.explain(line)
    }
}

/// The single overlay pill for a non-normal state (spec §5.10, overlay column).
struct StatusPill: View {
    @Environment(AppModel.self) var model
    let issue: AppModel.Issue

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: issue.blocking ? "exclamationmark.triangle.fill" : symbol)
                .foregroundStyle(issue.blocking ? Color(hex: 0xFF6B61) : Color.overlayNote)
            Text(AppModel.shortText(issue)).foregroundStyle(.white)
            if case .permissionRevoked = issue { Button("Open System Settings") { openPrivacySettings() } }
            if case .capReached = issue { Button("Translate Anyway") { model.translateAnyway() } }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.overlaySolid.opacity(0.9), in: .capsule)
    }

    var symbol: String {
        switch issue {
        case .offline, .apiOutage: "wifi.slash"
        case .capReached: "gauge.with.needle"
        case .noAudio: "speaker.slash"
        default: "info.circle"
        }
    }
}

/// Bring the main window forward, on `section` if given.
@MainActor func openMainWindow(_ section: SidebarSection? = nil) {
    if let section { selectSection(section) }
    NSApp.activate()
    if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
        w.makeKeyAndOrderFront(nil)
    } else {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("kikitori.openMainWindow")
}
