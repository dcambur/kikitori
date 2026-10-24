import Foundation

/// A listening session: what was heard, translated and explained (spec §5.7). Audio is never saved.
public struct SessionRecord: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var start: Date
    public var end: Date?
    public var sourceName: String
    public var sourceID: String
    public var profileName: String?
    public var streamTitle = ""
    public var game = ""
    public var lines: [TranscriptLine] = []
    /// Explanations by line id, newest last (Explain Again keeps earlier answers).
    public var explanations: [UUID: [Explainer.Explanation]] = [:]
    public var cost = 0.0
    /// Names given to speaker labels this session ("A" → "Pekora"); nil in sessions without any.
    public var speakerNames: [String: String]?

    public init(start: Date = .now, sourceName: String, sourceID: String, profileName: String?) {
        self.start = start; self.sourceName = sourceName; self.sourceID = sourceID; self.profileName = profileName
    }

    public var duration: TimeInterval { (end ?? .now).timeIntervalSince(start) }
    public var noteCount: Int { lines.filter { $0.note != nil }.count }

    /// How a speaker label reads in text: the name given to it, else "Speaker A".
    public func speakerName(_ label: String) -> String { speakerNames?[label] ?? "Speaker \(label)" }

    /// The lines with their speaker labels written out as names, for export.
    public var namedLines: [TranscriptLine] {
        lines.map { line in
            var line = line
            line.speaker = line.speaker.map(speakerName)
            return line
        }
    }

    public var summary: SessionSummary {
        SessionSummary(id: id, start: start, end: end, sourceName: sourceName, profileName: profileName,
                       streamTitle: streamTitle, lineCount: lines.count, noteCount: noteCount, cost: cost)
    }
}

/// What the Sessions list needs without loading every transcript.
public struct SessionSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var start: Date
    public var end: Date?
    public var sourceName: String
    public var profileName: String?
    public var streamTitle: String
    public var lineCount: Int
    public var noteCount: Int
    public var cost: Double
    public var duration: TimeInterval { (end ?? start).timeIntervalSince(start) }
}

/// Sessions on disk: one JSON file per session plus an index of summaries.
/// Writes are atomic (temp file + rename).
public struct SessionStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var indexURL: URL { directory.appending(path: "index.json") }
    func url(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }

    public func summaries() -> [SessionSummary] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder.kikitori.decode([SessionSummary].self, from: data) else { return [] }
        return list.sorted { $0.start > $1.start }
    }

    public func load(_ id: UUID) -> SessionRecord? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder.kikitori.decode(SessionRecord.self, from: data)
    }

    /// Save (or update) a session. Sessions shorter than a minute with no lines are not kept.
    public func save(_ record: SessionRecord) throws {
        if record.lines.isEmpty && record.duration < 60 { try delete([record.id]); return }
        try JSONEncoder.kikitori.encode(record).write(to: url(record.id), options: .atomic)
        var index = summaries().filter { $0.id != record.id }
        index.append(record.summary)
        try JSONEncoder.kikitori.encode(index).write(to: indexURL, options: .atomic)
    }

    public func delete(_ ids: [UUID]) throws {
        for id in ids { try? FileManager.default.removeItem(at: url(id)) }
        let index = summaries().filter { !ids.contains($0.id) }
        try JSONEncoder.kikitori.encode(index).write(to: indexURL, options: .atomic)
    }

    /// Sessions that started before `cutoff` (for retention).
    public func olderThan(_ cutoff: Date) -> [SessionSummary] { summaries().filter { $0.start < cutoff } }

    /// Full-text search across all saved transcripts (Japanese, English, notes).
    public func search(_ query: String) -> [UUID] {
        guard !query.isEmpty else { return [] }
        return summaries().compactMap { s in
            load(s.id).flatMap { record in
                record.lines.contains { $0.matches(query) } || record.streamTitle.localizedCaseInsensitiveContains(query)
                    ? s.id : nil
            }
        }
    }
}

extension TranscriptLine {
    public func matches(_ query: String) -> Bool {
        ja.localizedCaseInsensitiveContains(query) || (en ?? "").localizedCaseInsensitiveContains(query)
            || (note ?? "").localizedCaseInsensitiveContains(query) || (term ?? "").localizedCaseInsensitiveContains(query)
    }
}

extension JSONEncoder {
    public static var kikitori: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .deferredToDate
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    public static var kikitori: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .deferredToDate
        return d
    }
}
