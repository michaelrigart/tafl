import Foundation

public enum KeyPathComponent: Hashable, Sendable {
    case key(String)
    case index(Int)
}

/// Finds the line of a key, table or array entry in TOML text. TOMLDecoder reports lines only for
/// syntax errors, so the validator asks this for the rest.
public struct SourceLocator: Sendable {
    private let lines: [[KeyPathComponent]: Int]

    public init(_ text: String) {
        var scan = Scan(Array(text.utf8))
        scan.run()
        lines = scan.lines
    }

    public func line(of path: [KeyPathComponent]) -> Int? {
        lines[path]
    }
}

private struct Scan {
    private let bytes: [UInt8]
    private var position = 0
    private var line = 1
    private var table: [KeyPathComponent] = []
    private var arrayCounts: [[KeyPathComponent]: Int] = [:]
    private(set) var lines: [[KeyPathComponent]: Int] = [:]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    private var current: UInt8? { position < bytes.count ? bytes[position] : nil }

    private func peek(_ offset: Int) -> UInt8? {
        position + offset < bytes.count ? bytes[position + offset] : nil
    }

    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let newline = UInt8(ascii: "\n")
    private static let hash = UInt8(ascii: "#")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")
    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let equals = UInt8(ascii: "=")
    private static let dot = UInt8(ascii: ".")
    private static let doubleQuote = UInt8(ascii: "\"")
    private static let singleQuote = UInt8(ascii: "'")
    private static let backslash = UInt8(ascii: "\\")

    mutating func run() {
        while let byte = current {
            switch byte {
            case Self.newline:
                line += 1
                position += 1
            case Self.space, Self.tab, Self.carriageReturn:
                position += 1
            case Self.hash:
                skipComment()
            case Self.openBracket:
                header()
            default:
                keyValue()
            }
        }
    }

    private mutating func record(_ path: [KeyPathComponent]) {
        if lines[path] == nil { lines[path] = line }
    }

    private mutating func skipBlanks() {
        while let byte = current, byte == Self.space || byte == Self.tab || byte == Self.carriageReturn {
            position += 1
        }
    }

    private mutating func skipComment() {
        while let byte = current, byte != Self.newline { position += 1 }
    }

    private mutating func skipToEndOfLine() {
        while let byte = current, byte != Self.newline { position += 1 }
    }

    private mutating func header() {
        let isArray = peek(1) == Self.openBracket
        position += isArray ? 2 : 1
        let segments = keySegments()
        var path: [KeyPathComponent] = []
        for (offset, segment) in segments.enumerated() {
            path.append(.key(segment))
            if isArray && offset == segments.count - 1 {
                record(path)
                let count = arrayCounts[path, default: 0]
                arrayCounts[path] = count + 1
                path.append(.index(count))
            } else if let count = arrayCounts[path] {
                path.append(.index(count - 1))
            }
            record(path)
        }
        table = path
        skipToEndOfLine()
    }

    private mutating func keyValue() {
        let segments = keySegments()
        skipBlanks()
        guard current == Self.equals else {
            skipToEndOfLine()
            return
        }
        position += 1
        var path = table
        for segment in segments {
            path.append(.key(segment))
            record(path)
        }
        skipValue()
    }

    /// Dotted bare or quoted key segments, up to the first byte that isn't part of the key.
    private mutating func keySegments() -> [String] {
        var segments: [String] = []
        while true {
            skipBlanks()
            guard let byte = current else { break }
            var segment: [UInt8] = []
            if byte == Self.doubleQuote || byte == Self.singleQuote {
                position += 1
                while let next = current, next != byte, next != Self.newline {
                    if byte == Self.doubleQuote, next == Self.backslash, let escaped = peek(1) {
                        segment.append(escaped)
                        position += 2
                    } else {
                        segment.append(next)
                        position += 1
                    }
                }
                if current == byte { position += 1 }
            } else {
                while let next = current,
                      next != Self.space, next != Self.tab, next != Self.carriageReturn, next != Self.newline,
                      next != Self.dot, next != Self.equals, next != Self.closeBracket {
                    segment.append(next)
                    position += 1
                }
            }
            if segment.isEmpty, segments.isEmpty, current != Self.dot { break }
            segments.append(String(decoding: segment, as: UTF8.self))
            skipBlanks()
            if current == Self.dot { position += 1 } else { break }
        }
        return segments
    }

    /// Skips one value, which may span lines when it is an array, an inline table or a multi-line string.
    private mutating func skipValue() {
        var depth = 0
        while let byte = current {
            switch byte {
            case Self.newline:
                if depth <= 0 { return }
                line += 1
                position += 1
            case Self.hash:
                skipComment()
            case Self.doubleQuote, Self.singleQuote:
                skipString(quote: byte)
            case Self.openBracket, Self.openBrace:
                depth += 1
                position += 1
            case Self.closeBracket, Self.closeBrace:
                depth -= 1
                position += 1
            default:
                position += 1
            }
        }
    }

    private mutating func skipString(quote: UInt8) {
        if peek(1) == quote, peek(2) == quote {
            position += 3
            while let byte = current {
                if byte == Self.newline {
                    line += 1
                    position += 1
                } else if quote == Self.doubleQuote, byte == Self.backslash {
                    if peek(1) == Self.newline { line += 1 }
                    position += 2
                } else if byte == quote, peek(1) == quote, peek(2) == quote {
                    position += 3
                    // Up to two more quotes may sit right before the closing delimiter.
                    var extra = 0
                    while extra < 2, current == quote {
                        position += 1
                        extra += 1
                    }
                    return
                } else {
                    position += 1
                }
            }
            return
        }
        position += 1
        while let byte = current, byte != Self.newline {
            if quote == Self.doubleQuote, byte == Self.backslash {
                position += peek(1) == Self.newline ? 1 : 2
            } else if byte == quote {
                position += 1
                return
            } else {
                position += 1
            }
        }
    }
}
