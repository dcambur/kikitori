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
        /// The model's JSON answer, for logs.
        public var raw = ""
    }

    public struct Line: Codable, Sendable, Equatable {
        /// The corrected Japanese for this line; empty unless `echoJapanese` is on.
        public var ja = ""
        public var en: String
        public var note: String
        public var term: String

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ja = try c.decodeIfPresent(String.self, forKey: .ja) ?? ""
            en = try c.decode(String.self, forKey: .en)
            note = try c.decode(String.self, forKey: .note)
            term = try c.decode(String.self, forKey: .term)
        }
    }

    public static let model = "claude-haiku-5-5"

    let client: ClaudeClient
    let pricing: Pricing
    let historyBudget: Int
    let schema: JSONValue
    var system: [ClaudeClient.TextBlock]
    var history: [ClaudeClient.Message] = []

    public init(client: ClaudeClient, profile: Profile?, streamInfo: String? = nil,
                settings: TranslationSettings = .init(), pricing: Pricing = .bundled,
                historyBudget: Int = 12_000, echoJapanese: Bool = true) {
        self.client = client
        self.pricing = pricing
        self.historyBudget = historyBudget
        schema = Self.schema(echoJapanese: echoJapanese)
        var context = settings.promptBlock
        if let profile { context += "\n\n" + profile.promptBlock }
        if let streamInfo, !streamInfo.isEmpty { context += "\n\nThis stream: \(streamInfo)" }
        system = [.init(Self.instructions(echoJapanese: echoJapanese)), .init(context)]
    }

    /// New profile, stream info or settings mid-session. The conversation so far is kept; the
    /// next request rewrites the prompt cache once.
    public func updateContext(profile: Profile?, streamInfo: String?, settings: TranslationSettings) {
        var context = settings.promptBlock
        if let profile { context += "\n\n" + profile.promptBlock }
        if let streamInfo, !streamInfo.isEmpty { context += "\n\nThis stream: \(streamInfo)" }
        system[1] = .init(context)
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
            outputConfig: .init(effort: "low", format: .init(schema: schema)))
        let response = try await client.send(request)
        let answer = response.text
        let lines = try JSONDecoder().decode(Answer.self, from: Data(answer.utf8)).lines
            .filter { !$0.en.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { Self.groundNote($0, heard: ja) }
        history += [.user(ja), .assistant(answer)]
        return Result(lines: lines, usage: response.usage,
                      cost: pricing.cost(response.usage, model: response.model), raw: answer)
    }

    /// A note survives only if its term is in what was actually heard (or in the corrected line):
    /// notes about words the model imagined, or with no term at all, are dropped.
    static func groundNote(_ line: Line, heard: String) -> Line {
        var line = line
        let term = line.term.trimmingCharacters(in: .whitespaces)
        let aboutRecognition = recognitionWords.contains { line.note.localizedCaseInsensitiveContains($0) }
        if line.note.isEmpty || term.isEmpty || aboutRecognition
            || !(heard.contains(term) || line.ja.contains(term)) {
            line.note = ""; line.term = ""
        }
        return line
    }

    /// Notes that talk about the transcript instead of the language (the prompt forbids them,
    /// but the model still writes some).
    static let recognitionWords = ["mishear", "misheard", "garbled", "recognition", "transcri",
                                   "made-up", "made up", "nonsense", "unclear", "typo", "left as-is"]

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

    static func schema(echoJapanese: Bool) -> JSONValue {
        var line: [String: JSONValue] = ["en": .stringSchema, "note": .stringSchema, "term": .stringSchema]
        if echoJapanese { line["ja"] = .stringSchema }
        return .strictObject(["lines": ["type": "array", "items": .strictObject(line)]])
    }

    static func instructions(echoJapanese: Bool) -> String {
        let fields = echoJapanese
            ? """
              ja: the Japanese for that line, with obvious recognition errors fixed;
              en: the subtitle, short enough to read at a glance (aim for under 90 characters).
            """
            : "  en: the subtitle, short enough to read at a glance (aim for under 90 characters)."
        return instructionsTemplate.replacingOccurrences(of: "{fields}", with: fields)
    }

    static let instructionsTemplate = """
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
    - Translate everything that is plausibly speech, giving your best reading of misrecognized \
    words. Leave out only stretches that are clearly noise or nonsense, and never invent content \
    that is not there. A chunk with real sentences never gets an empty list.
    - Several people may speak in one chunk. Keep each person's line separate when you can tell \
    them apart; do not label speakers.

    How to write the lines
    - Split the chunk into subtitle lines at natural sentence or turn boundaries. Each line has:
    {fields}
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
    - Only note things you are confident are real: established slang, memes, references and \
    wordplay you can actually explain. If a word is unfamiliar or might be a recognition \
    error, fix it silently or translate your best guess, and give no note. Never note \
    something as "made-up", "unclear" or "possibly a mishearing".
    """
}
