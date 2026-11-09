import Foundation

/// A small JSON parser for files that decide what gets installed (`package.json`, `bun.lock`).
///
/// Why not `JSONSerialization`: it silently accepts trailing commas and, for a key that appears
/// twice, keeps one of the values. If Singularity checked one value while Bun installed the other,
/// the check would be worthless, so this parser refuses duplicate keys outright.
///
/// `allowJSONC: true` is for `bun.lock`, which Bun writes as JSONC ("JSON with comments"): it
/// allows trailing commas (Bun always writes them) and `//` / `/* */` comments. Everything else is
/// plain JSON (RFC 8259): double-quoted strings, no NaN/Infinity, no unquoted keys.
public enum JSONText {
    public struct ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String
        /// Byte offset where the problem was found.
        public let offset: Int
        public var description: String { "\(message) at byte \(offset)" }
    }

    /// Objects and arrays nested deeper than this are refused (the parser is recursive).
    static let maxDepth = 64

    public static func parse(_ data: Data, allowJSONC: Bool = false) throws(ParseError) -> JSONValue {
        var parser = Parser(bytes: [UInt8](data), jsonc: allowJSONC)
        let value = try parser.value(depth: 0)
        try parser.skipSpace()
        guard parser.atEnd else { throw parser.fail("unexpected text after the end") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        let jsonc: Bool
        var i = 0

        init(bytes: [UInt8], jsonc: Bool) {
            self.bytes = bytes
            self.jsonc = jsonc
        }

        var atEnd: Bool { i >= bytes.count }

        func fail(_ message: String) -> ParseError { ParseError(message: message, offset: i) }

        /// Skips whitespace, and in JSONC mode also comments.
        mutating func skipSpace() throws(ParseError) {
            while i < bytes.count {
                switch bytes[i] {
                case 0x20, 0x09, 0x0A, 0x0D: i += 1
                case 0x2F where jsonc && i + 1 < bytes.count && bytes[i + 1] == 0x2F:   // "//"
                    while i < bytes.count && bytes[i] != 0x0A { i += 1 }
                case 0x2F where jsonc && i + 1 < bytes.count && bytes[i + 1] == 0x2A:   // "/*"
                    i += 2
                    while i + 1 < bytes.count && !(bytes[i] == 0x2A && bytes[i + 1] == 0x2F) { i += 1 }
                    guard i + 1 < bytes.count else { throw fail("unterminated comment") }
                    i += 2
                default: return
                }
            }
        }

        mutating func value(depth: Int) throws(ParseError) -> JSONValue {
            try skipSpace()
            guard i < bytes.count else { throw fail("unexpected end") }
            switch bytes[i] {
            case 0x7B: return try object(depth: depth + 1)                     // {
            case 0x5B: return try array(depth: depth + 1)                      // [
            case 0x22: return .string(try string())                            // "
            case 0x74: try literal("true"); return .bool(true)
            case 0x66: try literal("false"); return .bool(false)
            case 0x6E: try literal("null"); return .null
            case 0x2D, 0x30...0x39: return .number(try number())               // - or digit
            default: throw fail("unexpected character")
            }
        }

        mutating func object(depth: Int) throws(ParseError) -> JSONValue {
            guard depth <= JSONText.maxDepth else { throw fail("nested too deeply") }
            i += 1 // {
            var result: [String: JSONValue] = [:]
            try skipSpace()
            if i < bytes.count && bytes[i] == 0x7D { i += 1; return .object(result) }
            while true {
                try skipSpace()
                guard i < bytes.count, bytes[i] == 0x22 else { throw fail("expected a key") }
                let key = try string()
                guard result[key] == nil else { throw fail("duplicate key \"\(key)\"") }
                try skipSpace()
                guard i < bytes.count, bytes[i] == 0x3A else { throw fail("expected ':'") }  // :
                i += 1
                result[key] = try value(depth: depth)
                try skipSpace()
                guard i < bytes.count else { throw fail("unexpected end") }
                if bytes[i] == 0x7D { i += 1; return .object(result) }
                guard bytes[i] == 0x2C else { throw fail("expected ',' or '}'") }
                i += 1
                try skipSpace()
                if i < bytes.count && bytes[i] == 0x7D {
                    guard jsonc else { throw fail("trailing comma") }
                    i += 1
                    return .object(result)
                }
            }
        }

        mutating func array(depth: Int) throws(ParseError) -> JSONValue {
            guard depth <= JSONText.maxDepth else { throw fail("nested too deeply") }
            i += 1 // [
            var result: [JSONValue] = []
            try skipSpace()
            if i < bytes.count && bytes[i] == 0x5D { i += 1; return .array(result) }
            while true {
                result.append(try value(depth: depth))
                try skipSpace()
                guard i < bytes.count else { throw fail("unexpected end") }
                if bytes[i] == 0x5D { i += 1; return .array(result) }
                guard bytes[i] == 0x2C else { throw fail("expected ',' or ']'") }
                i += 1
                try skipSpace()
                if i < bytes.count && bytes[i] == 0x5D {
                    guard jsonc else { throw fail("trailing comma") }
                    i += 1
                    return .array(result)
                }
            }
        }

        mutating func literal(_ word: String) throws(ParseError) {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw fail("unexpected word") }
            i += w.count
        }

        /// A JSON number: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
        mutating func number() throws(ParseError) -> Double {
            let start = i
            func digits() -> Int {
                let s = i
                while i < bytes.count && (0x30...0x39).contains(bytes[i]) { i += 1 }
                return i - s
            }
            if bytes[i] == 0x2D { i += 1 }
            guard i < bytes.count else { throw fail("bad number") }
            if bytes[i] == 0x30 { i += 1 } else if digits() == 0 { throw fail("bad number") }
            if i < bytes.count && bytes[i] == 0x2E { i += 1; guard digits() > 0 else { throw fail("bad number") } }
            if i < bytes.count && (bytes[i] == 0x65 || bytes[i] == 0x45) {
                i += 1
                if i < bytes.count && (bytes[i] == 0x2B || bytes[i] == 0x2D) { i += 1 }
                guard digits() > 0 else { throw fail("bad number") }
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            guard let value = Double(text) else { throw fail("bad number") }
            return value
        }

        /// A double-quoted string with JSON escapes. Raw control characters are refused.
        mutating func string() throws(ParseError) -> String {
            i += 1 // opening quote
            var out: [UInt8] = []
            while true {
                guard i < bytes.count else { throw fail("unterminated string") }
                let b = bytes[i]
                i += 1
                switch b {
                case 0x22:
                    // Invalid UTF-8 would be "repaired" with U+FFFD; refuse it instead.
                    guard let s = String(bytes: out, encoding: .utf8) else { throw fail("invalid UTF-8") }
                    return s
                case 0x5C:
                    guard i < bytes.count else { throw fail("unterminated string") }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case 0x22: out.append(0x22)
                    case 0x5C: out.append(0x5C)
                    case 0x2F: out.append(0x2F)
                    case 0x62: out.append(0x08)
                    case 0x66: out.append(0x0C)
                    case 0x6E: out.append(0x0A)
                    case 0x72: out.append(0x0D)
                    case 0x74: out.append(0x09)
                    case 0x75: // \uXXXX, with surrogate pairs for characters outside the BMP
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code) {
                            guard i + 1 < bytes.count, bytes[i] == 0x5C, bytes[i + 1] == 0x75 else { throw fail("lone surrogate") }
                            i += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw fail("lone surrogate") }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(code) {
                            throw fail("lone surrogate")
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw fail("bad escape") }
                        out.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default: throw fail("bad escape")
                    }
                case 0x00...0x1F: throw fail("control character in string")
                default: out.append(b)
                }
            }
        }

        mutating func hex4() throws(ParseError) -> UInt32 {
            guard i + 4 <= bytes.count else { throw fail("bad escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let b = bytes[i]
                let digit: UInt32
                switch b {
                case 0x30...0x39: digit = UInt32(b - 0x30)
                case 0x41...0x46: digit = UInt32(b - 0x41 + 10)
                case 0x61...0x66: digit = UInt32(b - 0x61 + 10)
                default: throw fail("bad escape")
                }
                value = value * 16 + digit
                i += 1
            }
            return value
        }
    }
}
