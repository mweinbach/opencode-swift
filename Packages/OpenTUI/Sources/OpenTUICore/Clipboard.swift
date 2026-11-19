/// Pure-Swift OSC 52 clipboard encoding, multiplexer passthrough (tmux / GNU screen),
/// capability detection, and clipboard adapter types matching
/// `packages/core/src/lib/clipboard.ts` and `packages/native/src/terminal.zig`.

// MARK: - Clipboard Types

/// Stable caller-owned clipboard payload with canonical lowercase MIME essence.
// parity: core/src/lib/clipboard.ts#ClipboardRepresentation [status=implemented hash=21bb38e5965b]
public struct ClipboardRepresentation: Equatable, Hashable, Sendable {
    public let mimeType: String
    public let bytes: [UInt8]

    public init(mimeType: String, bytes: [UInt8]) {
        self.mimeType = mimeType
        self.bytes = bytes
    }
}

/// Logical clipboard selection target.
// parity: core/src/lib/clipboard.ts#ClipboardSelection [status=implemented hash=6c8d236e08b8]
public enum ClipboardSelection: String, Equatable, Hashable, Sendable, Codable {
    case clipboard
    case primary
}

/// Controls whether clipboard writes use the terminal, the process host, or both.
// parity: core/src/lib/clipboard.ts#ClipboardWriteDestination [status=implemented hash=427bab69b1ce]
public enum ClipboardWriteDestination: String, Equatable, Hashable, Sendable, Codable {
    case terminalOnly = "terminal-only"
    case hostOnly = "host-only"
    case bestAvailable = "best-available"
    case allAvailable = "all-available"
}

/// Reported terminal OSC 52 capability state.
public enum Osc52Support: String, Equatable, Hashable, Sendable, Codable {
    case supported
    case unsupported
    case unknown
}

/// Multiplexer passthrough framing mode for OSC 52 escape sequences.
public enum ClipboardPassthrough: String, Equatable, Hashable, Sendable, Codable {
    case none
    case tmux
    case screen
}

/// Status of a local terminal OSC 52 write or clear attempt.
public enum TerminalClipboardOperationStatus: String, Equatable, Hashable, Sendable, Codable {
    case attempted
    case localFailure = "local-failure"
    case notAttempted = "not-attempted"
}

/// Result returned by a terminal clipboard write or clear operation.
// parity: core/src/lib/clipboard.ts#TerminalClipboardOperationResult [status=implemented hash=4c9e2d98d117]
public struct TerminalClipboardOperationResult: Equatable, Hashable, Sendable, Codable {
    public let status: TerminalClipboardOperationStatus
    public let capability: Osc52Support

    public init(status: TerminalClipboardOperationStatus, capability: Osc52Support) {
        self.status = status
        self.capability = capability
    }
}

/// OSC 52 selection target matching `ClipboardTarget` in `clipboard.ts` and `terminal.zig`.
// parity: core/src/lib/clipboard.ts#ClipboardTarget [status=implemented hash=00217313d738]
// parity: native/src/terminal.zig#ClipboardTarget [status=implemented hash=c0265b34550c]
public enum ClipboardTarget: UInt8, Equatable, Hashable, Sendable, Codable {
    case clipboard = 0
    case primary = 1
    case select = 2
    case secondary = 3
    case query = 4

    /// Single-character OSC 52 target parameter (`c`, `p`, `s`, `q`, or `?`).
    public var code: String {
        switch self {
        case .clipboard: return "c"
        case .primary: return "p"
        case .select: return "s"
        case .secondary: return "q"
        case .query: return "?"
        }
    }

    /// ASCII byte corresponding to `code`.
    public var asciiByte: UInt8 {
        switch self {
        case .clipboard: return UInt8(ascii: "c")
        case .primary: return UInt8(ascii: "p")
        case .select: return UInt8(ascii: "s")
        case .secondary: return UInt8(ascii: "q")
        case .query: return UInt8(ascii: "?")
        }
    }
}

/// Terminal clipboard adapter consumed by higher-level clipboard services.
// parity: core/src/lib/clipboard.ts#TerminalClipboardAdapter [status=implemented hash=e408f244268f]
public protocol TerminalClipboardAdapter: Sendable {
    var remote: Bool { get }
    func writeText(_ text: String, selection: ClipboardSelection) -> TerminalClipboardOperationResult
    func clear(selection: ClipboardSelection) -> TerminalClipboardOperationResult
}

/// Snapshot of renderer clipboard capability flags.
public struct RendererClipboardCapabilities: Equatable, Hashable, Sendable, Codable {
    public let remote: Bool
    public let osc52Support: Osc52Support

    public init(remote: Bool = false, osc52Support: Osc52Support = .unknown) {
        self.remote = remote
        self.osc52Support = osc52Support
    }
}

/// Narrow renderer boundary used by `createRendererClipboardAdapter`.
// parity: core/src/lib/clipboard.ts#RendererClipboardBoundary [status=implemented hash=af08421dd684]
public protocol RendererClipboardBoundary: Sendable {
    var clipboardCapabilities: RendererClipboardCapabilities? { get }
    func copyToClipboardOSC52(_ text: String, target: ClipboardTarget) -> Bool
    func clearClipboardOSC52(target: ClipboardTarget) -> Bool
}

public struct RendererClipboardAdapter: TerminalClipboardAdapter, Sendable {
    private let renderer: any RendererClipboardBoundary

    public init(renderer: any RendererClipboardBoundary) {
        self.renderer = renderer
    }

    public var remote: Bool {
        renderer.clipboardCapabilities?.remote ?? true
    }

    private func targetFor(_ selection: ClipboardSelection) -> ClipboardTarget {
        selection == .primary ? .primary : .clipboard
    }

    private func capability() -> Osc52Support {
        renderer.clipboardCapabilities?.osc52Support ?? .unknown
    }

    public func writeText(_ text: String, selection: ClipboardSelection) -> TerminalClipboardOperationResult {
        let currentCapability = capability()
        if currentCapability == .unsupported {
            return TerminalClipboardOperationResult(status: .notAttempted, capability: currentCapability)
        }
        let ok = renderer.copyToClipboardOSC52(text, target: targetFor(selection))
        return TerminalClipboardOperationResult(
            status: ok ? .attempted : .localFailure,
            capability: currentCapability
        )
    }

    public func clear(selection: ClipboardSelection) -> TerminalClipboardOperationResult {
        let currentCapability = capability()
        if currentCapability == .unsupported {
            return TerminalClipboardOperationResult(status: .notAttempted, capability: currentCapability)
        }
        let ok = renderer.clearClipboardOSC52(target: targetFor(selection))
        return TerminalClipboardOperationResult(
            status: ok ? .attempted : .localFailure,
            capability: currentCapability
        )
    }
}

/// Wraps a `RendererClipboardBoundary` into a `TerminalClipboardAdapter`.
// parity: core/src/lib/clipboard.ts#createRendererClipboardAdapter [status=implemented hash=aae9e104ffcc]
public func createRendererClipboardAdapter(_ renderer: any RendererClipboardBoundary) -> RendererClipboardAdapter {
    RendererClipboardAdapter(renderer: renderer)
}

// MARK: - Pure-Swift RFC 4648 Base64

private let base64Alphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
private let base64PaddingByte: UInt8 = UInt8(ascii: "=")

/// Encodes raw bytes into standard RFC 4648 Base64 without requiring `Foundation`.
public func base64Encode(_ bytes: [UInt8]) -> String {
    guard !bytes.isEmpty else { return "" }
    var out: [UInt8] = []
    out.reserveCapacity(((bytes.count + 2) / 3) * 4)

    var i = 0
    let count = bytes.count
    while i < count {
        let b0 = UInt32(bytes[i])
        let hasB1 = i + 1 < count
        let hasB2 = i + 2 < count
        let b1 = hasB1 ? UInt32(bytes[i + 1]) : 0
        let b2 = hasB2 ? UInt32(bytes[i + 2]) : 0

        let triple = (b0 << 16) | (b1 << 8) | b2
        out.append(base64Alphabet[Int((triple >> 18) & 0x3F)])
        out.append(base64Alphabet[Int((triple >> 12) & 0x3F)])
        out.append(hasB1 ? base64Alphabet[Int((triple >> 6) & 0x3F)] : base64PaddingByte)
        out.append(hasB2 ? base64Alphabet[Int(triple & 0x3F)] : base64PaddingByte)

        i += 3
    }

    return String(decoding: out, as: UTF8.self)
}

/// Encodes a UTF-8 string into standard RFC 4648 Base64.
public func base64Encode(_ text: String) -> String {
    base64Encode(Array(text.utf8))
}

@inline(__always)
private func decodeBase64Sextet(_ byte: UInt8) -> UInt8? {
    if byte >= 0x41 && byte <= 0x5A { return byte - 0x41 }           // A-Z
    if byte >= 0x61 && byte <= 0x7A { return byte - 0x61 + 26 }      // a-z
    if byte >= 0x30 && byte <= 0x39 { return byte - 0x30 + 52 }      // 0-9
    if byte == UInt8(ascii: "+") { return 62 }
    if byte == UInt8(ascii: "/") { return 63 }
    return nil
}

/// Decodes a standard RFC 4648 Base64 string into raw bytes, or returns `nil` on invalid input.
public func base64Decode(_ encoded: String) -> [UInt8]? {
    let bytes = Array(encoded.utf8)
    if bytes.isEmpty { return [] }
    guard bytes.count % 4 == 0 else { return nil }

    var out: [UInt8] = []
    out.reserveCapacity((bytes.count / 4) * 3)

    var i = 0
    while i < bytes.count {
        let c0 = bytes[i]
        let c1 = bytes[i + 1]
        let c2 = bytes[i + 2]
        let c3 = bytes[i + 3]

        guard let s0 = decodeBase64Sextet(c0), let s1 = decodeBase64Sextet(c1) else {
            return nil
        }

        let isPad2 = c2 == base64PaddingByte
        let isPad3 = c3 == base64PaddingByte

        if isPad2 && !isPad3 {
            return nil
        }
        if (isPad2 || isPad3) && i + 4 != bytes.count {
            return nil
        }

        let s2: UInt8
        if isPad2 {
            s2 = 0
        } else if let decoded = decodeBase64Sextet(c2) {
            s2 = decoded
        } else {
            return nil
        }

        let s3: UInt8
        if isPad3 {
            s3 = 0
        } else if let decoded = decodeBase64Sextet(c3) {
            s3 = decoded
        } else {
            return nil
        }

        let triple = (UInt32(s0) << 18) | (UInt32(s1) << 12) | (UInt32(s2) << 6) | UInt32(s3)
        out.append(UInt8((triple >> 16) & 0xFF))
        if !isPad2 {
            out.append(UInt8((triple >> 8) & 0xFF))
        }
        if !isPad3 {
            out.append(UInt8(triple & 0xFF))
        }

        i += 4
    }

    return out
}

// MARK: - OSC 52 Sequence Encoding & Support Heuristics

/// GNU screen DCS passthrough chunk size matching `SCREEN_PASSTHROUGH_CHUNK_SIZE` in `terminal.zig`.
public let screenPassthroughChunkSize: Int = 252

private let osc52TermTokens: [String] = [
    "iterm",
    "kitty",
    "alacritty",
    "wezterm",
    "contour",
    "foot",
    "rio",
    "ghostty",
    "tmux",
    "screen",
]

private func containsCaseInsensitive(_ haystack: String, _ needleLower: String) -> Bool {
    let lower = haystack.lowercased()
    let h = Array(lower.utf8)
    let n = Array(needleLower.utf8)
    guard !n.isEmpty, h.count >= n.count else { return false }
    let limit = h.count - n.count
    for i in 0...limit {
        var matched = true
        for j in 0..<n.count {
            if h[i + j] != n[j] {
                matched = false
                break
            }
        }
        if matched { return true }
    }
    return false
}

private func isOsc52Term(_ value: String) -> Bool {
    for token in osc52TermTokens {
        if containsCaseInsensitive(value, token) {
            return true
        }
    }
    return false
}

/// Wraps an ASCII OSC escape sequence for tmux or GNU screen DCS passthrough, matching `PassthroughWriter` in `terminal.zig`.
private func wrapOscPassthrough(_ oscPayload: [UInt8], passthrough: ClipboardPassthrough) -> String {
    switch passthrough {
    case .none:
        return String(decoding: oscPayload, as: UTF8.self)

    case .tmux:
        var out: [UInt8] = []
        out.reserveCapacity(oscPayload.count + 16)
        out.append(contentsOf: "\u{1B}Ptmux;".utf8)
        for byte in oscPayload {
            if byte == 0x1B {
                out.append(0x1B)
                out.append(0x1B)
            } else {
                out.append(byte)
            }
        }
        out.append(contentsOf: "\u{1B}\\".utf8)
        return String(decoding: out, as: UTF8.self)

    case .screen:
        var out: [UInt8] = []
        out.reserveCapacity(oscPayload.count + 32)
        var chunk: [UInt8] = []
        chunk.reserveCapacity(screenPassthroughChunkSize)

        func flushChunk() {
            guard !chunk.isEmpty else { return }
            out.append(contentsOf: "\u{1B}P".utf8)
            out.append(contentsOf: chunk)
            out.append(contentsOf: "\u{1B}\\".utf8)
            chunk.removeAll(keepingCapacity: true)
        }

        for byte in oscPayload {
            if chunk.count == screenPassthroughChunkSize {
                let endsWithEsc = chunk.last == 0x1B
                if endsWithEsc {
                    chunk.removeLast()
                }
                flushChunk()
                if endsWithEsc {
                    chunk.append(0x1B)
                }
            }
            chunk.append(byte)
        }
        flushChunk()
        return String(decoding: out, as: UTF8.self)
    }
}

/// Builds an OSC 52 escape sequence for raw UTF-8 clipboard bytes with optional tmux or GNU screen passthrough.
// parity: native/src/terminal.zig#writeClipboard [status=implemented hash=97de7010f4d8]
public func encodeOsc52Sequence(
    payloadBytes: [UInt8],
    target: ClipboardTarget = .clipboard,
    passthrough: ClipboardPassthrough = .none
) -> String {
    let encoded = base64Encode(payloadBytes)
    return encodeOsc52RawPayload(encoded, target: target, passthrough: passthrough)
}

/// Builds an OSC 52 escape sequence for a pre-encoded payload string (Base64 data, `""` for clear, or `"?"` for query).
public func encodeOsc52RawPayload(
    _ payload: String,
    target: ClipboardTarget = .clipboard,
    passthrough: ClipboardPassthrough = .none
) -> String {
    let terminator = passthrough == .screen ? "\u{07}" : "\u{1B}\\"
    let rawOsc = "\u{1B}]52;\(target.code);\(payload)\(terminator)"
    return wrapOscPassthrough(Array(rawOsc.utf8), passthrough: passthrough)
}

/// Pure-Swift OSC 52 clipboard encoder and writer supporting standard, tmux, and GNU screen passthrough.
public struct Osc52Clipboard: RendererClipboardBoundary, Sendable {
    public var passthrough: ClipboardPassthrough
    public var osc52Support: Osc52Support
    public var remote: Bool
    private let writer: (@Sendable (String) -> Bool)?

    public init(
        passthrough: ClipboardPassthrough = .none,
        osc52Support: Osc52Support = .unknown,
        remote: Bool = false,
        writer: (@Sendable (String) -> Bool)? = nil
    ) {
        self.passthrough = passthrough
        self.osc52Support = osc52Support
        self.remote = remote
        self.writer = writer
    }

    public init(
        environment: [String: String],
        osc52Support: Osc52Support = .unknown,
        writer: (@Sendable (String) -> Bool)? = nil
    ) {
        self.passthrough = Self.detectPassthrough(environment: environment)
        self.osc52Support = osc52Support
        self.remote = Self.isRemoteSession(environment: environment)
        self.writer = writer
    }

    public var clipboardCapabilities: RendererClipboardCapabilities? {
        RendererClipboardCapabilities(remote: remote, osc52Support: osc52Support)
    }

    /// Encodes `text` as a UTF-8 Base64 OSC 52 escape sequence for `target` and `passthrough`.
    public static func encodeCopy(
        _ text: String,
        target: ClipboardTarget = .clipboard,
        passthrough: ClipboardPassthrough = .none
    ) -> String {
        if target == .query {
            return encodeQuery(target: .clipboard, passthrough: passthrough)
        }
        return encodeOsc52Sequence(payloadBytes: Array(text.utf8), target: target, passthrough: passthrough)
    }

    /// Encodes an OSC 52 clear sequence (empty payload) for `target` and `passthrough`.
    public static func encodeClear(
        target: ClipboardTarget = .clipboard,
        passthrough: ClipboardPassthrough = .none
    ) -> String {
        encodeOsc52RawPayload("", target: target, passthrough: passthrough)
    }

    /// Encodes an OSC 52 query sequence (`"?"` payload) for `target` and `passthrough`.
    public static func encodeQuery(
        target: ClipboardTarget = .clipboard,
        passthrough: ClipboardPassthrough = .none
    ) -> String {
        let effectiveTarget: ClipboardTarget = target == .query ? .clipboard : target
        return encodeOsc52RawPayload("?", target: effectiveTarget, passthrough: passthrough)
    }

    /// Detects the active terminal multiplexer passthrough mode from environment variables.
    public static func detectPassthrough(environment: [String: String]) -> ClipboardPassthrough {
        let isRemote = isRemoteSession(environment: environment)
        if let tmux = environment["TMUX"], !tmux.isEmpty, !isRemote {
            return .tmux
        }
        if let sty = environment["STY"], !sty.isEmpty {
            return .screen
        }
        if let term = environment["TERM"] {
            let lower = term.lowercased()
            if lower == "screen" || lower.hasPrefix("screen.") {
                return .screen
            }
        }
        return .none
    }

    /// Reports whether the environment indicates an SSH or Mosh remote session.
    public static func isRemoteSession(environment: [String: String]) -> Bool {
        environment["SSH_CONNECTION"] != nil
            || environment["SSH_CLIENT"] != nil
            || environment["SSH_TTY"] != nil
            || environment["MOSH_CONNECTION"] != nil
    }

    /// Heuristically determines whether OSC 52 clipboard sequences are supported in `environment`.
    public static func isOsc52Supported(
        environment: [String: String],
        osc52Support: Osc52Support = .unknown
    ) -> Bool {
        if osc52Support == .unsupported { return false }
        if osc52Support == .supported { return true }

        if environment["WT_SESSION"] != nil {
            return true
        }
        if let tmux = environment["TMUX"], !tmux.isEmpty {
            return true
        }
        if let sty = environment["STY"], !sty.isEmpty {
            return true
        }
        if let program = environment["TERM_PROGRAM"], isOsc52Term(program) {
            return true
        }
        if let term = environment["TERM"] {
            if isOsc52Term(term)
                || containsCaseInsensitive(term, "256color")
                || containsCaseInsensitive(term, "xterm")
            {
                return true
            }
        }
        return false
    }

    /// Reports whether this clipboard instance permits OSC 52 emission.
    public func isOsc52Supported() -> Bool {
        osc52Support != .unsupported
    }

    /// Encodes and emits an OSC 52 copy sequence via the configured writer.
    @discardableResult
    public func copyToClipboardOSC52(_ text: String, target: ClipboardTarget = .clipboard) -> Bool {
        guard isOsc52Supported(), let writer else { return false }
        let sequence = Self.encodeCopy(text, target: target, passthrough: passthrough)
        return writer(sequence)
    }

    /// Encodes and emits an OSC 52 clear sequence via the configured writer.
    @discardableResult
    public func clearClipboardOSC52(target: ClipboardTarget = .clipboard) -> Bool {
        guard isOsc52Supported(), let writer else { return false }
        let sequence = Self.encodeClear(target: target, passthrough: passthrough)
        return writer(sequence)
    }
}

/// Convenience alias for `Osc52Clipboard`.
public typealias Clipboard = Osc52Clipboard
