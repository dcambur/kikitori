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

    @Test func refusalIsAnError() async {
        let client = ClaudeClient(apiKey: "k", transport: StubTransport([(200, messageJSON(text: "", stop: "refusal"), [:])]))
        let req = ClaudeClient.Request(model: "m", maxTokens: 1, system: [], messages: [.user("x")])
        await #expect(throws: ClaudeClient.Failure.refusal) { try await client.send(req) }
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
}
