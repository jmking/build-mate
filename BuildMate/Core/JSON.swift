import Foundation

/// The protocol's arbitrary JSON fields stay Sendable across actor boundaries.
enum JSON: Codable, Sendable, Equatable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSON { if case .object(let v) = self { v[key] ?? .null } else { .null } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var array: [JSON] { if case .array(let v) = self { v } else { [] } }
    var int: Int? { if case .number(let v) = self { Int(v) } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var text: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
    static func textInput(_ text: String) -> JSON { .array([.object(["type": .string("text"), "text": .string(text)])]) }
}
