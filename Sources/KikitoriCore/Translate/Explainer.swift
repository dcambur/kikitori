import Foundation

/// On-demand explanation of one subtitle line with Claude Sonnet 5.5 (the "Explain" action).
public struct Explainer: Sendable {
    /// One explanation, in short fields the panel shows as sections.
    public struct Explanation: Codable, Sendable, Equatable {
        public var term: String
        /// The term's reading in kana.
        public var reading: String
        public var romaji: String
        /// What the term means, in a few words.
        public var gist: String
        /// Where it comes from and how it is used.
        public var meaning: String
        public var inThisLine: String
        /// Key words of the line, in order, when it is hard to parse.
        public var parts: [Part]
        public var fanSlang: [String]
        public var confidence: Confidence
        /// Why it isn't certain (a likely mishearing, an unclear reference); empty when sure.
        public var caveat: String

        public struct Part: Codable, Sendable, Equatable {
            public var text: String
            public var reading: String
            public var gloss: String
            public init(text: String, reading: String, gloss: String) { self.text = text; self.reading = reading; self.gloss = gloss }
        }

        public enum Confidence: String, Codable, Sendable { case high, medium, low }

        public init(term: String, reading: String, romaji: String = "", gist: String = "", meaning: String,
                    inThisLine: String, parts: [Part] = [], fanSlang: [String] = [], confidence: Confidence = .high,
                    caveat: String = "") {
            self.term = term; self.reading = reading; self.romaji = romaji; self.gist = gist; self.meaning = meaning
            self.inThisLine = inThisLine; self.parts = parts; self.fanSlang = fanSlang
            self.confidence = confidence; self.caveat = caveat
        }

        enum CodingKeys: String, CodingKey {
            case term, reading, romaji, gist, meaning, inThisLine, parts, fanSlang, confidence, caveat
        }

        /// Also reads explanations saved before the fields were split (fanSlang was one string).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            term = try c.decode(String.self, forKey: .term)
            reading = try c.decodeIfPresent(String.self, forKey: .reading) ?? ""
            romaji = try c.decodeIfPresent(String.self, forKey: .romaji) ?? ""
            gist = try c.decodeIfPresent(String.self, forKey: .gist) ?? ""
            meaning = try c.decodeIfPresent(String.self, forKey: .meaning) ?? ""
            inThisLine = try c.decodeIfPresent(String.self, forKey: .inThisLine) ?? ""
            parts = try c.decodeIfPresent([Part].self, forKey: .parts) ?? []
            if let list = try? c.decodeIfPresent([String].self, forKey: .fanSlang) {
                fanSlang = list
            } else {
                let old = try c.decodeIfPresent(String.self, forKey: .fanSlang) ?? ""
                fanSlang = old.isEmpty ? [] : [old]
            }
            confidence = (try? c.decodeIfPresent(Confidence.self, forKey: .confidence)) ?? .high
            caveat = try c.decodeIfPresent(String.self, forKey: .caveat) ?? ""
        }
    }

    public struct Result: Sendable {
        public var explanation: Explanation
        public var usage: ClaudeClient.Usage
        public var cost: Double
    }

    public static let model = "claude-sonnet-5-5"

    let client: ClaudeClient
    let pricing: Pricing

    public init(client: ClaudeClient, pricing: Pricing = .bundled) {
        var client = client
        // Sonnet thinks before it answers (up to 8192 tokens, not streamed): over a minute at times.
        client.timeout = max(client.timeout, 150)
        self.client = client
        self.pricing = pricing
    }

    /// Explain `line`, given the lines around it (oldest first), the streamer profile and what the
    /// stream is (title, game, channel): names of games and other streamers are easily mistaken
    /// for ordinary words without it.
    public func explain(_ line: TranscriptLine, context: [TranscriptLine], profile: Profile?,
                        streamInfo: String = "") async throws -> Result {
        var system = Self.instructions
        if let profile { system += "\n\n" + profile.promptBlock }
        if !streamInfo.isEmpty { system += "\n\nThis stream: \(streamInfo)" }
        let recent = context.suffix(12).map { "- \($0.ja)\($0.en.map { " → \($0)" } ?? "")" }
            .joined(separator: "\n")
        var ask = "Recent lines:\n\(recent)\n\nExplain this line:\n\(line.ja)"
        if let en = line.en { ask += "\nSubtitle shown: \(en)" }
        if let term = line.term, !term.isEmpty { ask += "\nThe viewer was told this term needs context: \(term)" }

        let request = ClaudeClient.Request(
            model: Self.model, maxTokens: 8192, system: [.init(system)],
            messages: [.user(ask)], thinking: .adaptive,
            outputConfig: .init(effort: "medium", format: .init(schema: Self.schema)),
            fallbacks: "default")
        let (explanation, response, cost) = try await client.answer(request, as: Explanation.self, pricing: pricing)
        return Result(explanation: explanation, usage: response.usage, cost: cost)
    }

    static let schema: JSONValue = .strictObject([
        "term": .stringSchema, "reading": .stringSchema, "romaji": .stringSchema, "gist": .stringSchema,
        "meaning": .stringSchema, "inThisLine": .stringSchema,
        "parts": ["type": "array", "items": .strictObject(["text": .stringSchema, "reading": .stringSchema, "gloss": .stringSchema])],
        "fanSlang": ["type": "array", "items": .stringSchema],
        "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
        "caveat": .stringSchema,
    ])

    static let instructions = """
    You explain Japanese VTuber livestream language to English-speaking viewers who are \
    watching live and just saw a subtitle they did not fully get. Reply with JSON only, in the \
    given schema. The answer is shown in a narrow side panel: keep every field short and plain, \
    and never repeat one field's content in another.

    - term: the word or phrase in the line that most needs explaining, exactly as written. If \
    nothing in particular, the key phrase of the line.
    - reading: the reading of the term only (not the whole line), in hiragana or katakana.
    - romaji: the same reading in Hepburn romaji.
    - gist: what the term means, in at most 10 words.
    - meaning: where it comes from and how it is used, 1–3 short sentences. Explain the term, \
    not the grammar of the whole line.
    - inThisLine: what the speaker meant here, using the recent lines and the stream info \
    (jokes, callbacks, who is teasing whom). 1–2 sentences.
    - parts: only when the line is hard to parse, up to 4 key words of the line in order, each \
    with its kana reading and a 1–4 word English gloss; otherwise an empty list.
    - fanSlang: up to 3 close English fan-slang equivalents, a few words each; empty if none fit.
    - confidence: "high" when you know the term and the line is clearly heard; "medium" when \
    the reading depends on context; "low" when the line is probably misheard or the reference \
    is unclear.
    - caveat: when confidence is not high, one short sentence on why (and what was probably \
    said); otherwise an empty string.

    The Japanese comes from automatic speech recognition and may contain mishearings. Streams \
    are full of proper nouns: games, songs, other streamers, events, fan names. Before reading \
    a word (often katakana) as an ordinary noun, check whether the stream info or the recent \
    lines make it a name: in a stream playing the game R.E.P.O., レポ is the game, not a report. \
    Be accurate: if you are not sure about a reference, say it is likely rather than inventing \
    details, and lower the confidence.
    """
}
