import KikitoriCore
import SwiftUI

/// The Explain result for one line (spec §5.3 inspector states). Also used in the overlay popover.
struct ExplanationView: View {
    @Environment(AppModel.self) var model
    let line: TranscriptLine?
    var compact = false
    @State private var page = 0

    var body: some View {
        if let line {
            content(line)
        } else {
            ContentUnavailableView {
                Label("Nothing selected", systemImage: "text.bubble")
            } description: {
                Text("Click a line to see what it means. Lines marked 注 have something worth knowing.")
            }
        }
    }

    @ViewBuilder func content(_ line: TranscriptLine) -> some View {
        switch model.explain[line.id] {
        case nil:
            VStack(spacing: 12) {
                Text(line.term ?? line.ja).font(.japanese(20, weight: .bold)).japaneseText()
                Button("Explain") { model.explain(line) }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
            .padding()
        case .loading:
            VStack(alignment: .leading, spacing: 10) {
                Text(line.term ?? String(line.ja.prefix(12))).font(.japanese(20, weight: .bold)).japaneseText()
                ForEach([0.95, 0.8, 0.6], id: \.self) { w in
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 10)
                        .frame(maxWidth: .infinity, alignment: .leading).scaleEffect(x: w, anchor: .leading)
                }
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Asking Claude Sonnet…").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelExplain(line.id) }.controlSize(.small)
                }
            }
            .padding()
            .frame(maxHeight: compact ? nil : .infinity, alignment: .top)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn’t get an explanation.").bold()
                Text(message).foregroundStyle(.secondary)
                Button("Try Again") { model.explain(line, again: true) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .topLeading)
        case .result(let list, let cost):
            let e = list[min(page, list.count - 1)]
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        if model.canReplay(line) {
                            Button { model.replay(line) } label: {
                                Label(model.replaying == line.time ? "Stop" : "Hear It",
                                      systemImage: model.replaying == line.time ? "stop.fill" : "play.fill")
                            }
                            .controlSize(.small)
                        }
                        Spacer()
                        if list.count > 1 {
                            Button { page = max(page - 1, 0) } label: { Image(systemName: "chevron.left") }
                                .buttonStyle(.borderless).disabled(page == 0)
                            Text("\(page + 1) of \(list.count)").font(.caption.monospacedDigit())
                            Button { page = min(page + 1, list.count - 1) } label: { Image(systemName: "chevron.right") }
                                .buttonStyle(.borderless).disabled(page >= list.count - 1)
                        }
                    }
                    ExplanationCard(e: e)
                    HStack {
                        Button("Explain Again") { model.explain(line, again: true); page = list.count }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(e.plainText, forType: .string)
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                    Text("Claude Sonnet 5.5 · \(Money.format(cost)) · used the stream info, profile and 12 lines of context")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
                .textSelection(.enabled)
            }
            .onAppear { page = list.count - 1 }
        }
    }
}

/// An explanation in sections: the term and its reading, a one-line gist, the meaning, what it
/// means in this line, word by word, fan slang, and how sure Claude is.
struct ExplanationCard: View {
    let e: Explainer.Explanation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(e.term).font(.japanese(22, weight: .bold)).japaneseText()
                    Spacer(minLength: 8)
                    ConfidenceBadge(confidence: e.confidence)
                }
                let reading = [e.reading, e.romaji].filter { !$0.isEmpty && $0 != e.term }.joined(separator: " · ")
                if !reading.isEmpty { Text(reading).font(.callout).foregroundStyle(.secondary) }
                if !e.gist.isEmpty { Text(e.gist).font(.headline).padding(.top, 4) }
            }
            if !e.meaning.isEmpty { section("Meaning") { Text(e.meaning) } }
            if !e.inThisLine.isEmpty {
                section("In this line") {
                    Text(e.inThisLine)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.kkNoteBackground, in: .rect(cornerRadius: 8))
                }
            }
            if !e.parts.isEmpty {
                section("Word by word") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                        ForEach(Array(e.parts.enumerated()), id: \.offset) { _, part in
                            GridRow {
                                Text(part.text).font(.japanese(15, weight: .semibold)).japaneseText()
                                Text(part.reading).font(.caption).foregroundStyle(.secondary)
                                Text(part.gloss).font(.callout)
                            }
                        }
                    }
                }
            }
            if !e.fanSlang.isEmpty {
                section("Fan slang") {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(e.fanSlang, id: \.self) { slang in
                            Text(slang).font(.callout)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.quaternary, in: .capsule)
                        }
                    }
                }
            }
            if !e.caveat.isEmpty {
                Label(e.caveat, systemImage: "exclamationmark.bubble")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
    }
}

/// How sure the explanation is: shown only when it isn't.
struct ConfidenceBadge: View {
    let confidence: Explainer.Explanation.Confidence
    var body: some View {
        switch confidence {
        case .high: EmptyView()
        case .medium: badge("Likely", Color.kkNote)
        case .low: badge("Unsure", Color.kkDanger)
        }
    }

    func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.14), in: .capsule)
            .help("Claude is not fully sure of this explanation")
    }
}

extension Explainer.Explanation {
    /// For Copy: the sections as plain text.
    var plainText: String {
        var s = "\(term) (\([reading, romaji].filter { !$0.isEmpty }.joined(separator: ", ")))"
        if !gist.isEmpty { s += ": \(gist)" }
        if !meaning.isEmpty { s += "\n\(meaning)" }
        if !inThisLine.isEmpty { s += "\nIn this line: \(inThisLine)" }
        for p in parts { s += "\n· \(p.text) (\(p.reading)) \(p.gloss)" }
        if !fanSlang.isEmpty { s += "\nFan slang: \(fanSlang.joined(separator: ", "))" }
        if !caveat.isEmpty { s += "\nNote: \(caveat)" }
        return s
    }
}
