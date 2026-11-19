import Foundation

/// Built-in Mermaid terminal diagram parser, layout engine, box-drawing renderer,
/// Markdown fenced-block integration, and TUI plugin (`packages/merman`).
public enum Merman {}

extension Merman {
    // parity: merman/src/diagnostics.ts#MermaidDiagramKind [status=implemented hash=2ac0bf94ae71]
    public enum MermaidDiagramKind: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case flowchart
        case sequence
        case state
        case timeline
        case gitGraph
        case gantt
    }

    /// An otherwise valid diagram contains syntax that this renderer does not support.
    // parity: merman/src/diagnostics.ts#MermaidSyntaxError [status=implemented hash=a97c4c5101db]
    public struct MermaidSyntaxError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let _tag: String = "MermaidSyntaxError"
        public let name: String = "MermaidSyntaxError"
        public let kind: MermaidDiagramKind
        public let lineNumber: Int
        public let sourceLine: String
        public let reason: String
        public let message: String

        public init(
            kind: MermaidDiagramKind,
            lineNumber: Int,
            sourceLine: String,
            reason: String = "Unsupported syntax"
        ) {
            self.kind = kind
            self.lineNumber = lineNumber
            self.sourceLine = sourceLine
            self.reason = reason
            self.message = "\(reason) in \(kind.rawValue) diagram at line \(lineNumber): \"\(sourceLine)\""
        }

        public var description: String { message }
    }
}

// MARK: - Internal Math & String Parity Helpers

extension Merman {
    /// Exact JavaScript `Math.floor(a / b)` for positive divisor `b`.
    @inline(__always)
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        precondition(b > 0)
        if a >= 0 { return a / b }
        return -((-a + b - 1) / b)
    }

    /// Exact JavaScript `Math.ceil(a / b)` for positive divisor `b`.
    @inline(__always)
    static func ceilDiv(_ a: Int, _ b: Int) -> Int {
        precondition(b > 0)
        if a >= 0 { return (a + b - 1) / b }
        return -((-a) / b)
    }

    /// Exact JavaScript `Math.round(x)` (half towards +infinity).
    @inline(__always)
    static func jsRound(_ x: Double) -> Int {
        Int(floor(x + 0.5))
    }

    /// Exact JavaScript `Math.trunc(x)` for finite numbers.
    @inline(__always)
    static func jsTrunc(_ x: Double) -> Int {
        Int(x.rounded(.towardZero))
    }

    /// Trims leading and trailing Unicode whitespace matching JS `String.prototype.trim()`.
    static func jsTrim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits lines on `\r\n` or `\n` (matching JS `.split(/\r?\n/)`).
    static func splitCRLF(_ content: String) -> [String] {
        var result: [String] = []
        var current = ""
        var prevCR = false
        for scalar in content.unicodeScalars {
            if scalar == "\r" {
                if prevCR {
                    current.unicodeScalars.append("\r")
                }
                prevCR = true
            } else if scalar == "\n" {
                result.append(current)
                current = ""
                prevCR = false
            } else {
                if prevCR {
                    current.unicodeScalars.append("\r")
                    prevCR = false
                }
                current.unicodeScalars.append(scalar)
            }
        }
        if prevCR {
            current.unicodeScalars.append("\r")
        }
        result.append(current)
        return result
    }

    /// Compiles and matches an NSRegularExpression returning captured group strings (1-based).
    static func regexFirstMatch(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String?]? {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = rx.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String?] = []
        groups.reserveCapacity(match.numberOfRanges)
        for idx in 0..<match.numberOfRanges {
            let r = match.range(at: idx)
            groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
        }
        return groups
    }

    static func regexTest(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> Bool {
        regexFirstMatch(pattern, in: text, options: options) != nil
    }

    static func regexAllMatches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [(range: Range<String.Index>, groups: [String?])] {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        let matches = rx.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        var out: [(range: Range<String.Index>, groups: [String?])] = []
        out.reserveCapacity(matches.count)
        for match in matches {
            guard let fullRange = Range(match.range, in: text) else { continue }
            var groups: [String?] = []
            groups.reserveCapacity(match.numberOfRanges)
            for idx in 0..<match.numberOfRanges {
                let r = match.range(at: idx)
                groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
            }
            out.append((fullRange, groups))
        }
        return out
    }

    static func regexReplace(_ pattern: String, in text: String, with template: String, options: NSRegularExpression.Options = []) -> String {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let ns = text as NSString
        return rx.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }
}
