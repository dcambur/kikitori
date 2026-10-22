import Foundation

/// Token prices per model, from Resources/pricing.json, and the cost of a response.
public struct Pricing: Codable, Sendable {
    public struct Rates: Codable, Sendable {
        public var input, output, cacheWrite, cacheRead: Double
    }
    public var models: [String: Rates]

    public static let bundled: Pricing = {
        let url = Bundle.module.url(forResource: "pricing", withExtension: "json")!
        return try! JSONDecoder().decode(Pricing.self, from: Data(contentsOf: url))
    }()

    /// US dollars for one response's usage; 0 for a model without a price.
    public func cost(_ usage: ClaudeClient.Usage, model: String) -> Double {
        guard let r = models[model] else { return 0 }
        let tokens = Double(usage.inputTokens) * r.input + Double(usage.outputTokens) * r.output
            + Double(usage.cacheCreationInputTokens ?? 0) * r.cacheWrite
            + Double(usage.cacheReadInputTokens ?? 0) * r.cacheRead
        return tokens / 1_000_000
    }
}
