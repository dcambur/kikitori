import Foundation

/// On-demand explanation of one subtitle line with Claude Sonnet 5.5 (the "Explain" action).
public struct Explainer: Sendable {
    public struct Explanation: Codable, Sendable, Equatable {
        public var term: String
        public var reading: String
        public var meaning: String
        public var inThisLine: String
        public var fanSlang: String

        public init(term: String, reading: String, meaning: String, inThisLine: String, fanSlang: String) {
            self.term = term; self.reading = reading; self.meaning = meaning
            self.inThisLine = inThisLine; self.fanSlang = fanSlang
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
        self.client = client
        self.pricing = pricing
    }

    /// Explain `line`, given the lines around it (oldest first) and the streamer profile.
    public func explain(_ line: TranscriptLine, context: [TranscriptLine], profile: Profile?) async throws -> Result {
        var system = Self.instructions
        if let profile { system += "\n\n" + profile.promptBlock }
        let recent = context.suffix(12).map { "- \($0.ja)\($0.en.map { " → \($0)" } ?? "")" }
            .joined(separator: "\n")
        var ask = "Recent lines:\n\(recent)\n\nExplain this line:\n\(line.ja)"
        if let en = line.en { ask += "\nSubtitle shown: \(en)" }
        if let term = line.term, !term.isEmpty { ask += "\nThe viewer was told this term needs context: \(term)" }

        let request = ClaudeClient.Request(
            model: Self.model, maxTokens: 4096, system: [.init(system)],
            messages: [.user(ask)], thinking: .adaptive,
            outputConfig: .init(effort: "low", format: .init(schema: Self.schema)),
            fallbacks: "default")
        let (explanation, response, cost) = try await client.answer(request, as: Explanation.self, pricing: pricing)
        return Result(explanation: explanation, usage: response.usage, cost: cost)
    }

    static let schema: JSONValue = .strictObject([
        "term": .stringSchema, "reading": .stringSchema, "meaning": .stringSchema,
        "inThisLine": .stringSchema, "fanSlang": .stringSchema,
    ])

    static let instructions = """
    You explain Japanese VTuber livestream language to English-speaking viewers who are \
    watching live and just saw a subtitle they did not fully get. Reply with JSON only.

    - term: the word or phrase that most needs explaining in the line (Japanese as written). \
    If nothing in particular, the key phrase of the line.
    - reading: its reading in romaji (Hepburn), with the kana in parentheses.
    - meaning: what it means and where it comes from, in 2–4 short sentences.
    - inThisLine: what the speaker meant here, using the recent lines for context (jokes, \
    callbacks, who is teasing whom). 1–3 sentences.
    - fanSlang: close English fan-slang equivalents in quotes, or an empty string.

    The Japanese comes from automatic speech recognition and may contain mishearings; say so \
    briefly if the line only makes sense with a correction. Be accurate: if you are not sure \
    about a reference, say it is likely rather than inventing details.
    """
}
