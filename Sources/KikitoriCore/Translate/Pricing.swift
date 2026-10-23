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

    /// US dollars for one response's usage. `model` is the one that answered: a dated or fallback
    /// id without a price of its own is priced as its base model, else as `requested`, so spend
    /// never counts as free. 0 only when neither has a price.
    public func cost(_ usage: ClaudeClient.Usage, model: String, requested: String? = nil) -> Double {
        let base = models.keys.filter { model.hasPrefix($0) }.max { $0.count < $1.count }
        guard let r = models[model] ?? base.flatMap({ models[$0] }) ?? requested.flatMap({ models[$0] }) else { return 0 }
        let tokens = Double(usage.inputTokens) * r.input + Double(usage.outputTokens) * r.output
            + Double(usage.cacheCreationInputTokens ?? 0) * r.cacheWrite
            + Double(usage.cacheReadInputTokens ?? 0) * r.cacheRead
        return tokens / 1_000_000
    }
}
