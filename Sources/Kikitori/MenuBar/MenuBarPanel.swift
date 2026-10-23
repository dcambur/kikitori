import KikitoriCore
import SwiftUI

/// Menu bar extra panel, 320 pt (spec §5.9).
struct MenuBarPanel: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow
    @Environment(\.openSettings) var openSettings
    @State private var showSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "captions.bubble.fill").font(.title).foregroundStyle(Color.kkAccentFill)
                VStack(alignment: .leading) {
                    Text(model.isLive ? "Listening to \(model.source?.name ?? "")" : "Not listening").bold()
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if model.isLive { Button("Stop") { model.stop() } }
            }
            if model.isLive {
                HStack(spacing: 14) {
                    round("captions.bubble", "Subtitles", model.prefs.overlayVisible) { model.prefs.overlayVisible.toggle() }
                    round("character.ja", "Japanese", model.prefs.showJapanese) { model.prefs.showJapanese.toggle() }
                    round("cursorarrow.slash", "Click-through", model.prefs.clickThrough) { model.prefs.clickThrough.toggle() }
                    round("pause.fill", "Pause", model.state == .paused) { Task { await model.togglePause() } }
                }
                .frame(maxWidth: .infinity)
            } else {
                Button { showSources = true } label: { Text("Start Listening").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .popover(isPresented: $showSources) { SourcePickerView() }
            }
            if let issue = model.topIssue {
                VStack(alignment: .leading, spacing: 6) {
                    Text(IssueBanner.text(issue)).font(.callout)
                    if case .capReached = issue {
                        HStack { Button("Translate Anyway") { model.translateAnyway() } }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(issue.blocking ? Color.kkDanger.opacity(0.12) : Color.kkNoteBackground, in: .rect(cornerRadius: 10))
            }
            Divider()
            LabeledContent("Profile") { ProfileMenu() }
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Today"); Spacer(); Text(Money.format(model.ledger.spentToday())).monospacedDigit() }
                HStack {
                    Text("This cycle"); Spacer()
                    Text("\(Money.format(model.spentThisCycle)) of \(Money.format(model.prefs.monthlyCap))").monospacedDigit()
                }
                ProgressView(value: min(model.spentThisCycle / max(model.prefs.monthlyCap, 0.01), 1)).tint(Color.kkAccentFill)
            }
            .font(.callout)
            Divider()
            menuItem(model.isLive ? "Open Transcript" : "Open kikitori", "⌃⌥T") {
                if model.isLive { selectSection(.live) }
                show()
            }
            if model.isLive {
                menuItem("Explain Last Line", "⌃⌥E") {
                    explainLastLine(open: show)
                }
            }
            menuItem("Watch in kikitori", "⇧⌘W") { openWatch(openWindow) }
            menuItem("Settings…", "⌘,") { NSApp.activate(); openSettings() }
            Divider()
            menuItem("Quit kikitori", "⌘Q") { model.stop(); NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
    }

    var subtitle: String {
        if let s = model.session, model.isLive {
            return "\(model.statusText) · \(TranscriptExport.clock(s.duration))"
        }
        if let last = model.sessions.first {
            return "Last: \(last.profileName ?? last.sourceName), \(last.start.formatted(.relative(presentation: .named))), \(TimeText.format(last.duration))"
        }
        return "Pick a stream to start"
    }

    func show() {
        NSApp.activate()
        openWindow(id: "main")
    }

    func round(_ symbol: String, _ label: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).frame(width: 36, height: 36)
                    .background(on ? Color.kkAccentFill : Color.secondary.opacity(0.15), in: .circle)
                    .foregroundStyle(on ? .white : .primary)
                Text(label).font(.caption2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label).accessibilityAddTraits(on ? .isSelected : [])
    }

    func menuItem(_ title: String, _ shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); Text(shortcut).foregroundStyle(.secondary) }.contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Menu bar glyph: outline when idle, filled when live, pause bars when paused, dot when attention is needed.
struct MenuBarGlyph: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let symbol = switch model.state {
        case .listening: "captions.bubble.fill"
        case .paused: "pause.rectangle"
        default: "captions.bubble"
        }
        Image(systemName: model.topIssue.map { $0.rank <= 5 } == true ? "exclamationmark.bubble" : symbol)
    }
}
