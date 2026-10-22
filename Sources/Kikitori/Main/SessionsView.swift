import KikitoriCore
import SwiftUI

/// Main window › Sessions (spec §5.7): saved transcripts, full-text search, export, delete.
struct SessionsView: View {
    @Environment(AppModel.self) var model
    @State private var selection: Set<UUID> = []
    @State private var query = ""
    @State private var matches: [UUID]?
    @State private var confirmDelete = false
    @State private var opened: SessionRecord?
    @State private var lineSelection: UUID?
    @State private var showExport = false

    var list: [SessionSummary] {
        guard let matches else { return model.sessions }
        return model.sessions.filter { matches.contains($0.id) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if model.sessions.isEmpty {
                    ContentUnavailableView("No past sessions", systemImage: "clock",
                                           description: Text("Finished streams appear here with their transcripts and explanations."))
                } else {
                    List(selection: $selection) {
                        ForEach(groups, id: \.0) { title, items in
                            Section(title) {
                                ForEach(items) { s in row(s).tag(s.id) }
                            }
                        }
                    }
                    .onDeleteCommand { confirmDelete = !selection.isEmpty }
                }
            }
            .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)
            .searchable(text: $query, placement: .sidebar, prompt: "Search all transcripts")
            .onChange(of: query) { _, q in matches = q.isEmpty ? nil : model.sessionStore.search(q) }

            detail.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Sessions")
        .onChange(of: selection) { _, ids in
            opened = ids.count == 1 ? model.sessionStore.load(ids.first!) : nil
            lineSelection = nil
        }
        .toolbar {
            Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.disabled(opened == nil)
            Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }.disabled(selection.isEmpty)
        }
        .alert(selection.count > 1 ? "Delete \(selection.count) sessions?" : "Delete this session?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteSessions(Array(selection)); selection = [] }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their transcripts and explanations are removed from this Mac. Spend history in Usage is kept.")
        }
        .sheet(isPresented: $showExport) {
            if let s = opened {
                ExportSheet(lines: s.lines, explanations: s.explanations,
                            name: [s.profileName ?? s.sourceName, s.start.formatted(.iso8601.year().month().day())].joined(separator: " – "))
            }
        }
    }

    func row(_ s: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.streamTitle.isEmpty ? s.start.formatted(date: .abbreviated, time: .shortened) : s.streamTitle)
                .lineLimit(1).help(s.streamTitle)
            Text([s.profileName ?? s.sourceName, TimeText.format(s.duration), Money.format(s.cost)].joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    var groups: [(String, [SessionSummary])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: list) { s -> String in
            if cal.isDateInToday(s.start) { return "Today" }
            if cal.isDateInYesterday(s.start) { return "Yesterday" }
            if cal.isDate(s.start, equalTo: .now, toGranularity: .month) { return "Earlier this month" }
            return s.start.formatted(.dateTime.month(.wide).year())
        }
        return grouped.map { ($0.key, $0.value.sorted { $0.start > $1.start }) }
            .sorted { ($0.1.first?.start ?? .distantPast) > ($1.1.first?.start ?? .distantPast) }
    }

    @ViewBuilder var detail: some View {
        if let s = opened {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text("Source **\(s.sourceName)**")
                    if let p = s.profileName { Text("Profile **\(p)**") }
                    Text("Lines **\(s.lines.count)**")
                    Text("Notes **\(s.noteCount)**")
                    Text("Cost **\(Money.format(s.cost))**")
                    Spacer()
                }
                .font(.callout).padding(.horizontal, 18).padding(.vertical, 8)
                Divider()
                HSplitView {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(s.lines) { line in
                                TranscriptRow(line: line, selected: line.id == lineSelection,
                                              textSize: model.prefs.transcriptTextSize, highlight: query)
                                    .onTapGesture { lineSelection = line.id }
                            }
                        }
                        .padding(12)
                    }
                    if let id = lineSelection, let saved = s.explanations[id]?.last {
                        SavedExplanation(e: saved).frame(minWidth: 260, idealWidth: 300).background(Color.kkInspector)
                    }
                }
                Divider()
                Text("Saved on this Mac only. Kept for \(model.prefs.retention.rawValue.lowercased()) (Settings › General).")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
        } else {
            ContentUnavailableView(selection.count > 1 ? "\(selection.count) sessions selected" : "No session selected",
                                   systemImage: "text.alignleft")
        }
    }
}

struct SavedExplanation: View {
    let e: Explainer.Explanation
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(e.term).font(.japanese(20, weight: .bold)).japaneseText()
                    Text(e.reading).foregroundStyle(.secondary)
                }
                Text(e.meaning)
                if !e.inThisLine.isEmpty {
                    Text("IN THIS LINE").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(e.inThisLine)
                }
            }
            .padding().textSelection(.enabled)
        }
    }
}
