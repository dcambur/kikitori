import Foundation

/// Transcript export (spec §5.3, Export sheet): SRT, WebVTT or Markdown.
public struct TranscriptExport: Sendable {
    public enum Format: String, CaseIterable, Sendable { case srt = "SRT", vtt = "WebVTT", markdown = "Markdown" }

    public var format: Format = .srt
    public var includeEnglish = true
    public var includeJapanese = true
    public var includeSpeakers = false
    /// Markdown only.
    public var includeNotes = true
    /// Added to every time (stream clock offset), seconds.
    public var offset: Double = 0

    public init() {}

    public var fileExtension: String { ["SRT": "srt", "WebVTT": "vtt", "Markdown": "md"][format.rawValue]! }

    public func render(_ lines: [TranscriptLine], explanations: [UUID: [Explainer.Explanation]] = [:],
                       title: String = "") -> String {
        // Lines translated from one chunk share its start time: they follow each other across the
        // chunk (1–7 s each) instead of all appearing at once.
        var cues: [(TranscriptLine, Double, Double)] = []
        var i = 0
        while i < lines.count {
            var j = i
            while j < lines.count, lines[j].time == lines[i].time { j += 1 }
            let count = Double(j - i), start = lines[i].time + offset
            let next = j < lines.count ? lines[j].time + offset : start + 4 * count
            let span = min(max(next - start, count), 7 * count)
            for k in i..<j {
                let n = Double(k - i)
                cues.append((lines[k], start + span * n / count, start + span * (n + 1) / count))
            }
            i = j
        }
        switch format {
        case .srt:
            return cues.enumerated().map { i, cue in
                "\(i + 1)\n\(Self.stamp(cue.1, ",")) --> \(Self.stamp(cue.2, ","))\n\(text(cue.0))\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + cues.map { cue in
                "\(Self.stamp(cue.1, ".")) --> \(Self.stamp(cue.2, "."))\n\(text(cue.0))\n"
            }.joined(separator: "\n")
        case .markdown:
            var out = title.isEmpty ? "" : "# \(title)\n\n"
            for line in lines {
                out += "**\(Self.clock(line.time + offset))**"
                if includeSpeakers, let s = line.speaker { out += " · \(s)" }
                out += "  \n"
                if includeJapanese { out += "\(line.ja)  \n" }
                if includeEnglish, let en = line.en { out += "\(en)\n" }
                if includeNotes, let note = line.note { out += "\n> 注 \(line.term ?? ""): \(note)\n" }
                if includeNotes, let e = explanations[line.id]?.last {
                    let gist = e.gist.isEmpty ? "" : " \(e.gist)."
                    out += "\n> **\(e.term)** (\(e.reading)):\(gist) \(e.meaning) \(e.inThisLine)\n"
                }
                out += "\n"
            }
            return out
        }
    }

    func text(_ line: TranscriptLine) -> String {
        var rows: [String] = []
        let speaker = includeSpeakers ? line.speaker.map { "[\($0)] " } ?? "" : ""
        if includeJapanese { rows.append(speaker + line.ja) }
        if includeEnglish, let en = line.en { rows.append((includeJapanese ? "" : speaker) + en) }
        return rows.joined(separator: "\n")
    }

    static func stamp(_ t: Double, _ separator: String) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }

    /// "1:11:30" or "11:30".
    public static func clock(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Profile files (spec §5.5): `{ "version": 1, "name", "nameJa", "colour", "channel", "glossary", "notes" }`.
public enum ProfileFile {
    struct File: Codable {
        var version = 1
        var name: String
        var nameJa: String
        var colour: String
        var channel: String
        var glossary: [GlossaryTerm]
        var notes: String
    }

    public struct ImportError: Error, CustomStringConvertible { public var description: String }

    public static func export(_ profile: Profile) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(File(name: profile.name, nameJa: profile.nameJa, colour: profile.colour,
                                 channel: profile.channel, glossary: profile.glossary, notes: profile.notes))
    }

    public static func parse(_ data: Data) throws -> Profile {
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) }
        catch { throw ImportError(description: "\(error)") }
        guard file.version == 1 else { throw ImportError(description: "Unsupported version \(file.version).") }
        guard !file.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ImportError(description: "The profile has no name.") }
        return Profile(name: file.name, nameJa: file.nameJa, colour: file.colour, channel: file.channel,
                       glossary: file.glossary, notes: file.notes)
    }

    public enum Keep: String, CaseIterable, Sendable { case yours = "Yours", imported = "Imported", both = "Both" }

    public struct Merge: Sendable {
        public var added: [GlossaryTerm]
        /// Same term, different content: (yours, imported).
        public var conflicts: [(yours: GlossaryTerm, imported: GlossaryTerm)]
    }

    /// What importing `incoming` into `existing` would change.
    public static func plan(_ incoming: Profile, into existing: Profile) -> Merge {
        let mine = Dictionary(existing.glossary.map { ($0.term, $0) }, uniquingKeysWith: { a, _ in a })
        var added: [GlossaryTerm] = [], conflicts: [(GlossaryTerm, GlossaryTerm)] = []
        for t in incoming.glossary {
            if let y = mine[t.term] { if y != t { conflicts.append((y, t)) } } else { added.append(t) }
        }
        return Merge(added: added, conflicts: conflicts)
    }

    /// Apply a plan: new terms are added; each conflict is resolved by `keep` (default: yours).
    public static func apply(_ merge: Merge, to profile: Profile, keep: [String: Keep], appendNotes: String?) -> Profile {
        var p = profile
        p.glossary += merge.added
        for (yours, imported) in merge.conflicts {
            switch keep[yours.term] ?? .yours {
            case .yours: break
            case .imported:
                if let i = p.glossary.firstIndex(of: yours) { p.glossary[i] = imported }
            case .both: p.glossary.append(imported)
            }
        }
        if let notes = appendNotes, !notes.isEmpty { p.notes += (p.notes.isEmpty ? "" : "\n\n") + notes }
        return p
    }
}
