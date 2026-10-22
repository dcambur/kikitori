import KikitoriCore
import SwiftUI

/// One transcript row (spec §5.3): 58 pt time column, Japanese above English, 注 chip.
struct TranscriptRow: View {
    let line: TranscriptLine
    var selected = false
    var pending = false
    var textSize: Double = 15
    var showJapanese = true
    var highlight: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if pending {
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
                if showJapanese || line.en == nil {
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
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(selected ? Color.kkSelection : .clear, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
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
