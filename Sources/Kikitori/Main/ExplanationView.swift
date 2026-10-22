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
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(e.term).font(.japanese(20, weight: .bold)).japaneseText()
                        Text(e.reading).foregroundStyle(.secondary)
                        Spacer()
                        if list.count > 1 {
                            Button { page = max(page - 1, 0) } label: { Image(systemName: "chevron.left") }
                                .buttonStyle(.borderless).disabled(page == 0)
                            Text("\(page + 1) of \(list.count)").font(.caption.monospacedDigit())
                            Button { page = min(page + 1, list.count - 1) } label: { Image(systemName: "chevron.right") }
                                .buttonStyle(.borderless).disabled(page >= list.count - 1)
                        }
                    }
                    Text(e.meaning)
                    if !e.inThisLine.isEmpty {
                        Text("IN THIS LINE").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(e.inThisLine)
                    }
                    if !e.fanSlang.isEmpty {
                        Text("CLOSE ENGLISH FAN SLANG").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(e.fanSlang)
                    }
                    HStack {
                        Button("Explain Again") { model.explain(line, again: true); page = list.count }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(e.term) (\(e.reading)): \(e.meaning)\n\(e.inThisLine)", forType: .string)
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                    Text("Claude Sonnet 5.5 · \(Money.format(cost)) · used profile notes and 12 lines of context")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
                .textSelection(.enabled)
            }
            .onAppear { page = list.count - 1 }
        }
    }
}
