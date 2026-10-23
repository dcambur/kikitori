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
                case .both, .english:
                    if mode == .both || line.en == nil {
                        HStack(spacing: 6) {
                            if let speaker = line.speaker {
                                Text(speaker).font(.caption2.bold()).padding(.horizontal, 4)
                                    .background(Color.kkSpeakers[0].opacity(0.15), in: .rect(cornerRadius: 5))
                            }
                            marked(line.ja).font(.japanese(textSize - 2)).foregroundStyle(.secondary).japaneseText()
                        }
                    }
                    if let en = line.en {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
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
        var s = "\(TranscriptExport.clock(line.time)). \(line.en ?? "Translating"). Japanese: \(line.ja)."
        if let term = line.term { s += " Has a note: \(term)." }
        return s
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
