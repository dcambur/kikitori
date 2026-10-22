import Foundation

/// Turns chunks of Japanese speech-to-text into subtitle lines with Claude Haiku 5.5.
///
/// The conversation is append-only (system prompt, profile, then alternating chunk / answer),
/// so each request reuses the previous one's prompt cache and pays full price only for the
/// new chunk. When the history grows past `historyBudget` characters the oldest half is
/// dropped, which costs one cache rewrite.
public actor LiveTranslator {
    public struct Result: Sendable {
        public var lines: [Line]
        public var usage: ClaudeClient.Usage
        public var cost: Double
    }

    public struct Line: Codable, Sendable, Equatable {
        public var ja: String
        public var en: String
        public var note: String
        public var term: String
    }

    public static let model = "claude-haiku-5-5"

    let client: ClaudeClient
    let pricing: Pricing
    let historyBudget: Int
    var system: [ClaudeClient.TextBlock]
    var history: [ClaudeClient.Message] = []

    public init(client: ClaudeClient, profile: Profile?, streamInfo: String? = nil,
                settings: TranslationSettings = .init(), pricing: Pricing = .bundled,
                historyBudget: Int = 12_000) {
        self.client = client
        self.pricing = pricing
        self.historyBudget = historyBudget
        var context = settings.promptBlock
        if let profile { context += "\n\n" + profile.promptBlock }
        if let streamInfo, !streamInfo.isEmpty { context += "\n\nThis stream: \(streamInfo)" }
        system = [.init(Self.instructions), .init(context)]
    }

    /// Translate one chunk. An empty chunk returns no lines without calling the API.
    public func translate(_ japanese: String) async throws -> Result {
        let ja = japanese.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ja.isEmpty else { return Result(lines: [], usage: .init(input: 0, output: 0), cost: 0) }
        trimHistory()
        let request = ClaudeClient.Request(
            model: Self.model, maxTokens: 2048, system: system,
            messages: history + [.user(ja)],
            thinking: .disabled,
            outputConfig: .init(effort: "low", format: .init(schema: Self.schema)))
        let response = try await client.send(request)
        let answer = response.text
        let lines = try JSONDecoder().decode(Answer.self, from: Data(answer.utf8)).lines
            .filter { !$0.en.trimmingCharacters(in: .whitespaces).isEmpty }
        history += [.user(ja), .assistant(answer)]
        return Result(lines: lines, usage: response.usage,
                      cost: pricing.cost(response.usage, model: response.model))
    }

    /// Recent Japanese/English pairs, for the explainer's context.
    public func recentHistory() -> [ClaudeClient.Message] { history }

    func trimHistory() {
        var size = history.reduce(0) { $0 + $1.content.reduce(0) { $0 + $1.text.count } }
        guard size > historyBudget else { return }
        var drop = 0
        while drop + 2 <= history.count, size > historyBudget / 2 {
            size -= history[drop...drop + 1].reduce(0) { $0 + $1.content.reduce(0) { $0 + $1.text.count } }
            drop += 2
        }
        history.removeFirst(drop)
    }

    struct Answer: Decodable { var lines: [Line] }

    static let schema: JSONValue = .strictObject([
        "lines": [
            "type": "array",
            "items": .strictObject([
                "ja": .stringSchema, "en": .stringSchema, "note": .stringSchema, "term": .stringSchema,
            ]),
        ],
    ])

    static let instructions = """
    You write live English subtitles for Japanese VTuber livestreams.

    Each user message is one chunk of automatic speech recognition (ASR) from the stream: \
    roughly 5 to 20 seconds of speech, sometimes from several people talking in turn. Earlier \
    chunks and your answers to them are the conversation so far. Reply with JSON only, in the \
    given schema.

    How to read the input
    - The transcript is machine-made and imperfect. Expect homophone mistakes (記者 for 汽車, \
    for example), wrong kanji, dropped particles, words cut off at the start or end of a chunk, \
    and occasional nonsense. Use the conversation so far, the streamer profile and common sense \
    to work out what was actually said.
    - Never translate recognizer garbage literally, and never invent content that is not there. \
    If a fragment is unintelligible, leave it out.
    - Several people may speak in one chunk. Keep each person's line separate when you can tell \
    them apart; do not label speakers.

    How to write the lines
    - Split the chunk into subtitle lines at natural sentence or turn boundaries. Each line has:
      ja: the Japanese for that line, with obvious recognition errors fixed;
      en: the subtitle, short enough to read at a glance (aim for under 90 characters).
    - Match the speaker's tone and energy: casual speech stays casual, screams and reactions \
    stay short and punchy ("Wait wait wait!", "No way!"). Keep catchphrases and greetings \
    recognisable.
    - Use the glossary's spellings and "translate as" choices for names and terms. Romanise \
    other Japanese names in Hepburn.
    - Fillers and lone backchannels (あ, うん, えーと) need no line. If a chunk contains nothing \
    worth a subtitle, return an empty list.

    Context notes
    - Add a note only when an English-speaking viewer would likely miss the meaning: internet \
    or fandom slang (草, てぇてぇ), memes, references to past streams or other streamers, puns \
    and wordplay, cultural references, or a shift in politeness that changes the meaning.
    - note: at most 12 words, plain English. term: the Japanese word or phrase it explains.
    - Most lines have no note: then note and term are empty strings. Never repeat a note \
    already given earlier in the conversation for the same term.
    """
}
