import Foundation
import Synchronization
import Testing
@testable import KikitoriCore

/// Answers every request with the next canned (status, body) and records what was sent.
final class StubTransport: HTTPTransport {
    let replies: Mutex<[(Int, String, [String: String])]>
    let sent = Mutex<[URLRequest]>([])

    init(_ replies: [(Int, String, [String: String])]) { self.replies = Mutex(replies) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.withLock { $0.append(request) }
        let (status, body, headers) = replies.withLock { $0.removeFirst() }
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), http)
    }

    func body(_ i: Int) throws -> [String: Any] {
        let data = sent.withLock { $0[i].httpBody! }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

func messageJSON(text: String, model: String = "claude-haiku-5-5", stop: String = "end_turn",
                 input: Int = 100, output: Int = 20, cacheRead: Int = 0) -> String {
    let content = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
    return """
    {"id":"msg_1","type":"message","role":"assistant","model":"\(model)","stop_reason":"\(stop)",
     "content":[{"type":"text","text":\(content)}],
     "usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":0,
              "cache_read_input_tokens":\(cacheRead)}}
    """
}

@Suite struct LiveTranslatorTests {
    let answer = #"{"lines":[{"ja":"え、待って","en":"Wait, what?","note":"","term":""}]}"#

    @Test func sendsCachedLowEffortRequestWithoutThinking() async throws {
        let stub = StubTransport([(200, messageJSON(text: answer), [:])])
        let t = LiveTranslator(client: ClaudeClient(apiKey: "k", transport: stub),
                               profile: Profile(name: "Hoshimi Kuu"))
        let result = try await t.translate("え、待って")

        #expect(result.lines.map(\.en) == ["Wait, what?"])
        let body = try stub.body(0)
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect((body["cache_control"] as? [String: String])?["type"] == "ephemeral")
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "low")
        #expect((config["format"] as? [String: Any])?["type"] as? String == "json_schema")
        let system = try #require(body["system"] as? [[String: Any]])
        #expect((system[1]["text"] as? String)?.contains("Hoshimi Kuu") == true)
        #expect(stub.sent.withLock { $0[0].value(forHTTPHeaderField: "anthropic-beta") } == nil)
    }

    @Test func historyIsAppendOnlySoThePromptCacheHolds() async throws {
        let stub = StubTransport([(200, messageJSON(text: answer), [:]), (200, messageJSON(text: answer), [:])])
        let t = LiveTranslator(client: ClaudeClient(apiKey: "k", transport: stub), profile: nil)
        _ = try await t.translate("一つ目")
        _ = try await t.translate("二つ目")

        let first = try #require(try stub.body(0)["messages"] as? [[String: Any]])
        let second = try #require(try stub.body(1)["messages"] as? [[String: Any]])
        #expect(first.count == 1 && second.count == 3)
        #expect(second.map { $0["role"] as! String } == ["user", "assistant", "user"])
        // The second request starts with exactly the first request's messages.
        #expect(NSDictionary(dictionary: first[0]).isEqual(to: second[0]))
    }

    @Test func trimsOldestTurnsPastTheBudget() async throws {
        let replies = (0..<6).map { _ in (200, messageJSON(text: answer), [String: String]()) }
        let stub = StubTransport(replies)
        let t = LiveTranslator(client: ClaudeClient(apiKey: "k", transport: stub), profile: nil,
                               historyBudget: 300)
        for i in 0..<6 { _ = try await t.translate(String(repeating: "あ", count: 40) + "\(i)") }
        let last = try #require(try stub.body(5)["messages"] as? [[String: Any]])
        #expect(last.count < 11)
        #expect(last.count % 2 == 1)
        #expect(last.first?["role"] as? String == "user")
    }

    @Test func notesMustNameSomethingThatWasHeard() {
        func line(_ term: String, _ note: String = "n") -> LiveTranslator.Line {
            try! JSONDecoder().decode(LiveTranslator.Line.self, from: Data(
                #"{"ja":"草生える","en":"lol","note":"\#(note)","term":"\#(term)"}"#.utf8))
        }
        #expect(LiveTranslator.groundNote(line("草"), heard: "草生える").note == "n")
        #expect(LiveTranslator.groundNote(line("ケロップゲ"), heard: "草生える").note == "")
        #expect(LiveTranslator.groundNote(line(""), heard: "草生える").note == "")
        #expect(LiveTranslator.groundNote(line("草", "Japanese 草 misheard, left as-is"), heard: "草生える").note == "")
    }

    @Test func contextUpdateKeepsTheConversation() async throws {
        let stub = StubTransport([(200, messageJSON(text: answer), [:]), (200, messageJSON(text: answer), [:])])
        let t = LiveTranslator(client: ClaudeClient(apiKey: "k", transport: stub), profile: nil)
        _ = try await t.translate("一つ目")
        await t.updateContext(profile: Profile(name: "Amane Rio"), streamInfo: "Horror collab", settings: .init())
        _ = try await t.translate("二つ目")
        let system = try #require(try stub.body(1)["system"] as? [[String: Any]])
        let context = try #require(system[1]["text"] as? String)
        #expect(context.contains("Amane Rio") && context.contains("Horror collab"))
        #expect((try stub.body(1)["messages"] as? [[String: Any]])?.count == 3)
    }

    @Test func emptyChunkCostsNothing() async throws {
        let stub = StubTransport([])
        let t = LiveTranslator(client: ClaudeClient(apiKey: "k", transport: stub), profile: nil)
        let r = try await t.translate("  \n")
        #expect(r.lines.isEmpty && r.cost == 0)
        #expect(stub.sent.withLock { $0.isEmpty })
    }
}

@Suite struct ClaudeClientErrorTests {
    func failure(_ status: Int, _ body: String = "{}", _ headers: [String: String] = [:]) async -> ClaudeClient.Failure? {
        let client = ClaudeClient(apiKey: "k", transport: StubTransport([(status, body, headers)]))
        let req = ClaudeClient.Request(model: "m", maxTokens: 1, system: [], messages: [.user("x")])
        do { _ = try await client.send(req); return nil }
        catch { return error as? ClaudeClient.Failure }
    }

    @Test func mapsStatusesToAppStates() async {
        #expect(await failure(401) == .invalidKey)
        #expect(await failure(429, "{}", ["retry-after": "20"]) == .rateLimited(retryAfter: 20))
        #expect(await failure(529) == .overloaded)
        let credit = #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}"#
        #expect(await failure(400, credit) == .creditsExhausted)
        #expect(await failure(400, #"{"error":{"message":"bad field"}}"#) == .badRequest("bad field"))
    }

    /// What `answer` throws for a 200 with this stop reason and text, as Haiku.
    func billed(stop: String, text: String) async -> ClaudeClient.BilledFailure? {
        let stub = StubTransport([(200, messageJSON(text: text, stop: stop, input: 1_000_000, output: 0), [:])])
        let req = ClaudeClient.Request(model: LiveTranslator.model, maxTokens: 1, system: [], messages: [.user("x")])
        do { _ = try await ClaudeClient(apiKey: "k", transport: stub).answer(req, as: [String: String].self, pricing: .bundled); return nil }
        catch { return error as? ClaudeClient.BilledFailure }
    }

    @Test func unusableAnswersStillCarryTheirCost() async {
        let refusal = await billed(stop: "refusal", text: "")
        #expect(refusal?.failure == .refusal)
        #expect(refusal.map { abs($0.cost - 0.10) < 1e-9 } == true)        // 1M Haiku input tokens
        #expect(await billed(stop: "max_tokens", text: #"{"a":"#)?.failure == .truncated)
        let garbled = await billed(stop: "end_turn", text: "not json")
        #expect(garbled.map { $0.usage.inputTokens == 1_000_000 && $0.cost > 0 } == true)
    }

    @Test func explainerCutOffByThinkingIsBilled() async {
        let stub = StubTransport([(200, messageJSON(text: #"{"term":"#, model: "claude-sonnet-5-5", stop: "max_tokens",
                                                    input: 1000, output: 4096), [:])])
        do {
            _ = try await Explainer(client: ClaudeClient(apiKey: "k", transport: stub))
                .explain(TranscriptLine(time: 0, ja: "草"), context: [], profile: nil)
            Issue.record("expected a billed failure")
        } catch let billed as ClaudeClient.BilledFailure {
            #expect(billed.failure == .truncated)
            #expect(abs(billed.cost - (1000 * 2.0 + 4096 * 10.0) / 1_000_000) < 1e-9)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func pipelineReportsTheCostOfAFailedTranslation() async {
        let stub = StubTransport([(200, messageJSON(text: "", stop: "refusal", input: 500, output: 10), [:])])
        let translator = LiveTranslator(client: ClaudeClient(apiKey: "k", transport: stub), profile: nil)
        let pipeline = LivePipeline(engine: FakeEngine(), translator: translator, vad: EnergyVAD())
        let audio = AsyncStream<[Float]> { c in c.yield(signal([(false, 1), (true, 2), (false, 2)])); c.finish() }
        var failures: [(ClaudeClient.Failure, Double, Int)] = []
        for await event in pipeline.run(audio) {
            if case let .translationFailed(_, failure, cost, tokens) = event { failures.append((failure, cost, tokens)) }
        }
        #expect(failures.count == 1)
        #expect(failures.first.map { $0.0 == .refusal && $0.1 > 0 && $0.2 == 510 } == true)
    }

    @Test func sonnetExplainerSendsFallbackBeta() async throws {
        let json = #"{"term":"てぇてぇ","reading":"tētē (てぇてぇ)","meaning":"m","inThisLine":"i","fanSlang":""}"#
        let stub = StubTransport([(200, messageJSON(text: json, model: "claude-sonnet-5-5"), [:])])
        let r = try await Explainer(client: ClaudeClient(apiKey: "k", transport: stub))
            .explain(TranscriptLine(time: 0, ja: "てぇてぇ"), context: [], profile: nil)
        #expect(r.explanation.term == "てぇてぇ")
        #expect(stub.sent.withLock { $0[0].value(forHTTPHeaderField: "anthropic-beta") } == ClaudeClient.fallbackBeta)
        #expect(try stub.body(0)["fallbacks"] as? String == "default")
    }
}

@Suite struct PricingTests {
    @Test func haikuCostIncludesCacheRates() {
        let usage = ClaudeClient.Usage(input: 1_000_000, output: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000)
        #expect(abs(Pricing.bundled.cost(usage, model: "claude-haiku-5-5") - (0.10 + 0.50 + 0.125 + 0.01)) < 1e-9)
        #expect(Pricing.bundled.cost(usage, model: "unknown") == 0)
    }

    @Test func unpricedModelIdsAreNeverFree() {
        let usage = ClaudeClient.Usage(input: 1_000_000, output: 0)
        #expect(abs(Pricing.bundled.cost(usage, model: "claude-sonnet-5-5-20261001") - 2.0) < 1e-9)   // dated id
        #expect(abs(Pricing.bundled.cost(usage, model: "claude-other", requested: "claude-sonnet-5-5") - 2.0) < 1e-9)
    }
}
