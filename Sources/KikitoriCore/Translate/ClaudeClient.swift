import Foundation

/// Minimal Claude Messages API client over raw HTTPS (Swift has no official Anthropic SDK).
public struct ClaudeClient: Sendable {
    public struct Request: Encodable, Sendable {
        public var model: String
        public var maxTokens: Int
        public var system: [TextBlock]
        public var messages: [Message]
        public var thinking: Thinking?
        public var outputConfig: OutputConfig?
        /// Top-level automatic prompt caching: the API puts the breakpoint on the last block.
        public var cacheControl: CacheControl? = CacheControl()
        /// Server-side refusal fallback ("default"); needs `ClaudeClient.fallbackBeta`.
        public var fallbacks: String?

        enum CodingKeys: String, CodingKey {
            case model, system, messages, thinking, fallbacks
            case maxTokens = "max_tokens", outputConfig = "output_config", cacheControl = "cache_control"
        }
    }

    public struct TextBlock: Codable, Sendable, Equatable {
        public var type = "text"
        public var text: String
        public init(_ text: String) { self.text = text }
    }

    public struct Message: Codable, Sendable, Equatable {
        public var role: String
        public var content: [TextBlock]
        public static func user(_ text: String) -> Message { .init(role: "user", content: [.init(text)]) }
        public static func assistant(_ text: String) -> Message { .init(role: "assistant", content: [.init(text)]) }
    }

    public struct Thinking: Encodable, Sendable {
        public var type: String
        public static let disabled = Thinking(type: "disabled")
        public static let adaptive = Thinking(type: "adaptive")
    }

    public struct OutputConfig: Encodable, Sendable {
        public var effort: String?
        public var format: Format?
        public struct Format: Encodable, Sendable {
            public var type = "json_schema"
            public var schema: JSONValue
        }
    }

    public struct CacheControl: Encodable, Sendable { public var type = "ephemeral" }

    public struct Response: Decodable, Sendable {
        public var id: String
        public var model: String
        public var stopReason: String?
        public var content: [Block]
        public var usage: Usage

        public struct Block: Decodable, Sendable {
            public var type: String
            public var text: String?
        }

        /// The concatenated text blocks (thinking blocks, if any, are skipped).
        public var text: String { content.filter { $0.type == "text" }.compactMap(\.text).joined() }

        enum CodingKeys: String, CodingKey {
            case id, model, content, usage
            case stopReason = "stop_reason"
        }
    }

    public struct Usage: Codable, Sendable, Equatable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheCreationInputTokens: Int?
        public var cacheReadInputTokens: Int?

        public init(input: Int, output: Int, cacheWrite: Int = 0, cacheRead: Int = 0) {
            inputTokens = input; outputTokens = output
            cacheCreationInputTokens = cacheWrite; cacheReadInputTokens = cacheRead
        }

        /// Every token billed, cached or not.
        public var total: Int { inputTokens + outputTokens + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0) }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens", outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidKey                         // 401/403: stop retrying until the key changes
        case creditsExhausted                   // account has no credit left
        case rateLimited(retryAfter: Double?)   // 429
        case overloaded                         // 500/529/503
        case offline                            // no network
        case refusal                            // stop_reason "refusal"
        case truncated                          // stop_reason "max_tokens": the answer was cut off
        case badRequest(String)                 // 400 other than credits: a bug on our side
        case unexpected(status: Int, String)
    }

    /// An answer the API billed but that can't be used: refused, cut off, or not the JSON asked
    /// for. Carries the usage and cost so the spend still counts toward the budget.
    public struct BilledFailure: Error, Sendable {
        public var failure: Failure
        public var usage: Usage
        public var cost: Double
    }

    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public var apiKey: String
    public var baseURL = URL(string: "https://api.anthropic.com/v1/messages")!
    public var transport: any HTTPTransport

    public init(apiKey: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    /// Sends `request` and decodes its text as the JSON `T`. Anything wrong with an answer the API
    /// already billed throws `BilledFailure`.
    public func answer<T: Decodable>(_ request: Request, as type: T.Type, pricing: Pricing) async throws
        -> (value: T, response: Response, cost: Double) {
        let response = try await send(request)
        let cost = pricing.cost(response.usage, model: response.model, requested: request.model)
        func billed(_ failure: Failure) -> BilledFailure { .init(failure: failure, usage: response.usage, cost: cost) }
        switch response.stopReason {
        case "refusal": throw billed(.refusal)
        case "max_tokens": throw billed(.truncated)
        default: break
        }
        do {
            return (try JSONDecoder().decode(T.self, from: Data(response.text.utf8)), response, cost)
        } catch {
            throw billed(.unexpected(status: 200, "The answer isn’t the JSON asked for: \(error)"))
        }
    }

    /// Sends `request`; any 200 answer comes back, whatever its stop reason (`answer` checks it).
    public func send(_ request: Request) async throws -> Response {
        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if request.fallbacks != nil {
            req.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONEncoder().encode(request)

        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(req)
        } catch let error as URLError
            where [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                   .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code) {
            throw Failure.offline
        }
        guard http.statusCode == 200 else { throw Self.failure(status: http, body: data) }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    static func failure(status http: HTTPURLResponse, body: Data) -> Failure {
        struct Envelope: Decodable { struct E: Decodable { var type: String?; var message: String? }; var error: E? }
        let message = (try? JSONDecoder().decode(Envelope.self, from: body))?.error?.message
            ?? String(decoding: body.prefix(300), as: UTF8.self)
        switch http.statusCode {
        case 401, 403: return .invalidKey
        case 429: return .rateLimited(retryAfter: http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init))
        case 500, 502, 503, 504, 529: return .overloaded
        case 400 where message.localizedCaseInsensitiveContains("credit balance"): return .creditsExhausted
        case 400: return .badRequest(message)
        default: return .unexpected(status: http.statusCode, message)
        }
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
