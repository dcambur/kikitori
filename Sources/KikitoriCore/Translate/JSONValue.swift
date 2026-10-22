import Foundation

/// Arbitrary JSON, for the JSON schemas sent as structured-output formats.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(arrayLiteral v: JSONValue...) { self = .array(v) }
    public init(dictionaryLiteral v: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: v))
    }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
}

extension JSONValue {
    /// A strict object schema: every listed property required, nothing else allowed.
    public static func strictObject(_ properties: [String: JSONValue]) -> JSONValue {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(properties.keys.sorted().map { .string($0) }),
            "additionalProperties": false,
        ])
    }
    public static let stringSchema: JSONValue = ["type": "string"]
}
