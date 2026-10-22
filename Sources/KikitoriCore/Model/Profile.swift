import Foundation

/// A streamer profile: who is talking and the words the translator must get right.
/// Encodes to the export format in docs/design/spec.md §5.5.
public struct Profile: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var nameJa: String
    public var colour: String
    public var channel: String
    public var glossary: [GlossaryTerm]
    public var notes: String

    public init(name: String, nameJa: String = "", colour: String = "#6A4FD8", channel: String = "",
                glossary: [GlossaryTerm] = [], notes: String = "") {
        self.name = name; self.nameJa = nameJa; self.colour = colour
        self.channel = channel; self.glossary = glossary; self.notes = notes
    }

    /// The block of the system prompt that describes this streamer.
    public var promptBlock: String {
        var s = "Streamer: \(name)"
        if !nameJa.isEmpty { s += " (\(nameJa))" }
        if !notes.isEmpty { s += "\nAbout them: \(notes)" }
        if !glossary.isEmpty {
            s += "\nGlossary (use these spellings and translations):"
            for t in glossary {
                var line = "\n- \(t.term)"
                if !t.reading.isEmpty { line += " [\(t.reading)]" }
                if !t.meaning.isEmpty { line += ": \(t.meaning)" }
                if !t.translateAs.isEmpty { line += " → translate as \"\(t.translateAs)\"" }
                s += line
            }
        }
        return s
    }
}

public struct GlossaryTerm: Codable, Sendable, Equatable, Hashable {
    public var term: String
    public var reading: String
    public var meaning: String
    public var translateAs: String

    public init(term: String, reading: String = "", meaning: String = "", translateAs: String = "") {
        self.term = term; self.reading = reading; self.meaning = meaning; self.translateAs = translateAs
    }
}

/// Settings › Translation (spec §5.8).
public struct TranslationSettings: Codable, Sendable, Equatable {
    public var targetLanguage = "English"
    /// 1 = literal … 5 = natural.
    public var style = 4
    public var keepHonorifics = true
    public var markNotes = true

    public init() {}

    var promptBlock: String {
        let styleText = ["", "very literal, close to the Japanese wording",
                         "fairly literal", "balanced", "natural, idiomatic",
                         "fully natural, as a native speaker would say it"][min(max(style, 1), 5)]
        return """
        Target language: \(targetLanguage). Style: \(styleText).
        Honorifics (-chan, -san, -senpai, -sama): \(keepHonorifics ? "keep them, romanised" : "translate them away naturally").
        Context notes: \(markNotes ? "on (see rules)" : "off: always leave note and term empty").
        """
    }
}

/// One subtitle line as shown in the overlay and the transcript.
public struct TranscriptLine: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    /// Seconds from the session start where the chunk began.
    public var time: Double
    public var ja: String
    public var en: String?
    public var note: String?
    public var term: String?
    public var speaker: String?

    public init(time: Double, ja: String, en: String? = nil, note: String? = nil, term: String? = nil) {
        self.time = time; self.ja = ja; self.en = en; self.note = note; self.term = term
    }
}
