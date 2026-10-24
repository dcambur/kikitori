import AppKit
import KikitoriCore
import SwiftUI

/// One transcript row (spec §5.3): 58 pt time column, Japanese above English, 注 chip, and a play
/// button while the line's audio is still in memory.
struct TranscriptRow: View {
    let line: TranscriptLine
    var selected = false
    var pending = false
    var textSize: Double = 15
    var mode: Preferences.TranscriptMode = .both
    var highlight: String = ""
    /// Shows the play button (on hover, or while playing) when set.
    var replay: ReplayControl?
    /// Names given to speaker labels this session ("A" → "Pekora").
    var speakerNames: [String: String] = [:]

    struct ReplayControl {
        var playing: Bool
        var toggle: () -> Void
    }

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if pending && mode != .japanese {
                    HStack(spacing: 4) { Circle().fill(Color.kkDanger).frame(width: 6, height: 6); Text("Live") }
                        .accessibilityLabel("Translating")
                } else {
                    Text(TranscriptExport.clock(line.time))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                switch mode {
                case .japanese:
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        marked(line.ja).font(.japanese(textSize)).japaneseText()
                        if let term = line.term { NoteChip(term: term) }
                    }
                case .both, .english where line.en == nil && !pending:
                    // No English is coming (translation off, or a filler): the Japanese is the line.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let speaker = line.speaker { SpeakerChip(label: speaker, name: speakerNames[speaker]) }
                        marked(line.ja).font(.japanese(textSize)).japaneseText()
                        if let term = line.term { NoteChip(term: term) }
                    }
                case .both, .english:
                    if mode == .both || line.en == nil {
                        HStack(spacing: 6) {
                            if let speaker = line.speaker { SpeakerChip(label: speaker, name: speakerNames[speaker]) }
                            marked(line.ja).font(.japanese(textSize - 2)).foregroundStyle(.secondary).japaneseText()
                        }
                    }
                    if let en = line.en {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if mode == .english, let speaker = line.speaker { SpeakerChip(label: speaker, name: speakerNames[speaker]) }
                            marked(en).font(.system(size: textSize))
                            if let term = line.term { NoteChip(term: term) }
                        }
                    } else if pending {
                        TranslatingDots().frame(height: textSize)
                    }
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            if let replay, hovering || replay.playing {
                Button(action: replay.toggle) {
                    Image(systemName: replay.playing ? "stop.circle.fill" : "play.circle")
                        .font(.system(size: 16)).foregroundStyle(replay.playing ? Color.kkAccent : .secondary)
                }
                .buttonStyle(.borderless)
                .help(replay.playing ? "Stop" : "Hear this line again")
                .accessibilityLabel(replay.playing ? "Stop playing" : "Play this line")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(selected ? Color.kkSelection : .clear, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    func marked(_ s: String) -> Text {
        guard !highlight.isEmpty, let r = s.range(of: highlight, options: .caseInsensitive) else { return Text(s) }
        var a = AttributedString(s)
        if let ar = Range(r, in: a) { a[ar].backgroundColor = Color(hex: 0xFFD60A, alpha: 0.45) }
        return Text(a)
    }

    var accessibilityText: String {
        var s = "\(TranscriptExport.clock(line.time)). "
        if let speaker = line.speaker { s += "Speaker \(speaker)\(speakerNames[speaker].map { ", \($0)" } ?? ""). " }
        if let en = line.en { s += "\(en). Japanese: \(line.ja)." }
        else if pending { s += "Translating. Japanese: \(line.ja)." }
        else { s += "\(line.ja)." }
        if let term = line.term { s += " Has a note: \(term)." }
        return s
    }
}

/// Keyboard for a transcript (HIG): ↑/↓ move the selection, Return explains the selected line
/// (the paid action, never a plain click), ⌘C copies it.
struct TranscriptKeys: ViewModifier {
    let lines: [TranscriptLine]
    @Binding var selection: UUID?
    let proxy: ScrollViewProxy
    let explain: (TranscriptLine) -> Void

    var selected: TranscriptLine? { lines.first { $0.id == selection } }

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.return) {
                guard let line = selected else { return .ignored }
                explain(line)
                return .handled
            }
            .onCopyCommand {
                guard let line = selected else { return [] }
                return [NSItemProvider(object: ([line.ja] + (line.en.map { [$0] } ?? [])).joined(separator: "\n") as NSString)]
            }
    }

    func move(_ step: Int) -> KeyPress.Result {
        guard !lines.isEmpty else { return .ignored }
        let i = lines.firstIndex { $0.id == selection }.map { $0 + step } ?? (step > 0 ? 0 : lines.count - 1)
        let line = lines[min(max(i, 0), lines.count - 1)]
        selection = line.id
        proxy.scrollTo(line.id)
        return .handled
    }
}

/// The end of a live transcript: the words being heard now, or `placeholder` when there are none
/// and no lines yet. The only view that reads the live line, which changes several times a
/// second, so the transcript above it doesn't redraw with it; it keeps the list scrolled down.
struct LiveLineSlot: View {
    @Environment(AppModel.self) var model
    var textSize: Double = 15
    var placeholder: String?
    var proxy: ScrollViewProxy?

    var body: some View {
        Group {
            if !model.hearing.isEmpty {
                LiveLineRow(text: model.hearing, textSize: textSize)
            } else if let placeholder {
                Text(placeholder).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
            }
        }
        .id("live")
        .onChange(of: model.hearing.isEmpty) { _, empty in if !empty { proxy?.scrollTo("live", anchor: .bottom) } }
    }
}

/// The words being heard right now, under the transcript: they become a line at the next pause.
struct LiveLineRow: View {
    let text: String
    var textSize: Double = 15

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 4) { Circle().fill(Color.kkDanger).frame(width: 6, height: 6); Text("Live") }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(text).font(.japanese(textSize - 1)).foregroundStyle(.secondary).japaneseText()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hearing now: \(text)")
    }
}

/// A speaker tag (spec §5.3): the letter, or the name given to it, in that speaker's colour.
struct SpeakerChip: View {
    let label: String
    var name: String?

    static func index(_ label: String) -> Int { Int((label.unicodeScalars.first?.value ?? 65) - 65) % 4 }

    var body: some View {
        let colour = Color.kkSpeakers[max(0, Self.index(label))]
        Text(name ?? label).font(.caption2.bold()).foregroundStyle(colour).padding(.horizontal, 4)
            .background(colour.opacity(0.15), in: .rect(cornerRadius: 5))
            .help(name.map { "Speaker \(label): \($0)" } ?? "Speaker \(label). Right-click the line to name this voice.")
            .accessibilityLabel(name.map { "Speaker \(label), \($0)" } ?? "Speaker \(label)")
    }
}

/// A line's speaker in its context menu: name the voice for this session (a profile's name, or
/// any), or also remember it for the profile's next sessions (experimental: see
/// docs/design/speaker-labels.md §4).
struct SpeakerMenu: View {
    @Environment(AppModel.self) var model
    let label: String

    var body: some View {
        Menu("Speaker \(model.session?.speakerNames?[label] ?? label)") {
            ForEach(model.profiles) { profile in
                Button("This Is \(profile.name)") { model.nameSpeaker(label, as: profile.name) }
            }
            Button("Name for This Session…") { if let name = ask() { model.nameSpeaker(label, as: name) } }
            if !model.profiles.isEmpty {
                Divider()
                Menu("Remember This Voice") {
                    ForEach(model.profiles) { profile in
                        Button("As \(profile.name)") { model.nameSpeaker(label, as: profile.name, profile: profile) }
                    }
                }
            }
        }
    }

    func ask() -> String? {
        let alert = NSAlert()
        alert.messageText = "Name Speaker \(label)"
        alert.informativeText = "Lines by this voice show the name for the rest of this session."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = model.session?.speakerNames?[label] ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Name")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

struct NoteChip: View {
    let term: String
    var body: some View {
        Text("注 \(term)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.kkNote)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.kkNoteBackground, in: .rect(cornerRadius: 5))
            .accessibilityLabel("Has a note: \(term)")
    }
}

/// Three dots while a line is being translated (spec §2.6: bounce, or fill one by one with Reduce Motion).
struct TranslatingDots: View {
    var color: Color = .secondary
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(color).frame(width: 5, height: 5)
                        .opacity(reduceMotion ? (i <= step ? 1 : 0.3) : 1)
                        .offset(y: !reduceMotion && i == step ? -2 : 0)
                }
            }
        }
        .accessibilityLabel("Translating")
    }
}
