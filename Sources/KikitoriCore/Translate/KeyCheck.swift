import Foundation

/// Checks an API key with one minimal request to the live model (onboarding and Settings › Account).
public enum KeyCheck {
    public enum Result: Equatable, Sendable {
        case valid, invalid, busy, noCredit, network
        public var message: String {
            switch self {
            case .valid: "Key works. Live subtitles: Claude Haiku 5.5 · Explanations: Claude Sonnet 5.5."
            case .invalid: "This key wasn’t accepted. Check that you copied the whole key, or create a new one in the Claude Console."
            case .busy: "Claude is busy. Try again in a minute."
            case .noCredit: "No API credits left. Claim or add credits in the Claude Console."
            case .network: "Can’t reach Anthropic. The key is saved and checked on first use."
            }
        }
        /// Rejected keys are not saved; everything else is (a key with no credit is still valid).
        public var shouldSave: Bool { self != .invalid }
    }

    public static func check(_ key: String, transport: any HTTPTransport = URLSessionTransport()) async -> Result {
        let request = ClaudeClient.Request(model: LiveTranslator.model, maxTokens: 16, system: [],
                                           messages: [.user("Reply with OK.")], thinking: .disabled, cacheControl: nil)
        do {
            _ = try await ClaudeClient(apiKey: key, transport: transport).send(request)
            return .valid
        } catch let f as ClaudeClient.Failure {
            switch f {
            case .invalidKey: return .invalid
            case .rateLimited, .overloaded: return .busy
            case .creditsExhausted: return .noCredit
            case .offline: return .network
            case .refusal, .truncated, .badRequest, .unexpected: return .valid
            }
        } catch {
            return .network
        }
    }
}
