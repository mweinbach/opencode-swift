/// Pure-Swift streaming audio demuxer protocol and Icecast/Shoutcast ICY stream demuxer
/// matching `packages/core/src/audio-stream/{demuxer,icy/demuxer,icy/metadata}.ts`.

// MARK: - Demuxer Errors & Text Encoding

/// Errors thrown by streaming audio demuxers and header selection.
public enum AudioStreamDemuxerError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidMetadataInterval(String)
    case unsupportedMetadataEncoding(String)
    case truncatedMetadataBlock

    public var description: String {
        switch self {
        case .invalidMetadataInterval(let raw):
            return "Invalid icy-metaint response header: \(raw)"
        case .unsupportedMetadataEncoding(let encoding):
            return "Unsupported metadataEncoding: \(encoding)"
        case .truncatedMetadataBlock:
            return "ICY stream ended inside a metadata block"
        }
    }
}

/// Pure-Swift character encodings supported for ICY inline metadata decoding.
public enum IcyMetadataEncoding: String, Equatable, Hashable, Sendable, CaseIterable {
    case iso88591 = "windows-1252"
    case utf8 = "utf-8"
    case ascii = "ascii"

    /// Resolves a WHATWG/IANA encoding label to an `IcyMetadataEncoding`.
    public init?(label: String) {
        let normalized = label.trimmingCharacters(in: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
            .lowercased()
        switch normalized {
        case "iso-8859-1", "iso8859-1", "iso88591", "iso_8859-1", "latin1", "latin-1", "l1",
             "windows-1252", "cp1252", "x-cp1252":
            self = .iso88591
        case "utf-8", "utf8", "unicode-1-1-utf-8":
            self = .utf8
        case "ascii", "us-ascii", "ansi_x3.4-1968":
            self = .ascii
        default:
            return nil
        }
    }

    /// Decodes raw metadata bytes into a Swift `String` without OS or Foundation dependencies.
    public func decode(_ bytes: [UInt8]) -> String {
        switch self {
        case .utf8:
            return String(decoding: bytes, as: UTF8.self)
        case .ascii:
            var scalars = String.UnicodeScalarView()
            scalars.reserveCapacity(bytes.count)
            for byte in bytes {
                if byte < 0x80, let scalar = UnicodeScalar(UInt32(byte)) {
                    scalars.append(scalar)
                } else {
                    scalars.append(UnicodeScalar(0xFFFD)!)
                }
            }
            return String(scalars)
        case .iso88591:
            // Matches WHATWG TextDecoder("iso-8859-1") which maps to windows-1252.
            var scalars = String.UnicodeScalarView()
            scalars.reserveCapacity(bytes.count)
            for byte in bytes {
                let codePoint: UInt32
                if byte >= 0x80 && byte <= 0x9F {
                    codePoint = windows1252HighTable[Int(byte - 0x80)]
                } else {
                    codePoint = UInt32(byte)
                }
                scalars.append(UnicodeScalar(codePoint) ?? UnicodeScalar(0xFFFD)!)
            }
            return String(scalars)
        }
    }
}

private let windows1252HighTable: [UInt32] = [
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
]

private extension String {
    func trimmingCharacters(in predicate: (Character) -> Bool) -> String {
        var start = startIndex
        while start < endIndex && predicate(self[start]) {
            start = index(after: start)
        }
        var end = endIndex
        while end > start {
            let prev = index(before: end)
            if predicate(self[prev]) {
                end = prev
            } else {
                break
            }
        }
        return String(self[start..<end])
    }
}

// MARK: - Demuxer Protocol & Outputs

/// Unit emitted by an `AudioStreamDemuxer` as incoming bytes are pushed or flushed.
// parity: core/src/audio-stream/demuxer.ts#AudioStreamDemuxOutput [status=implemented hash=d564e0ecfc57]
public enum AudioStreamDemuxOutput<M: Sendable>: Sendable {
    case audio([UInt8])
    case metadata(M?)
}

extension AudioStreamDemuxOutput: Equatable where M: Equatable {}
extension AudioStreamDemuxOutput: Hashable where M: Hashable {}

/// Streaming audio demuxer separating audio payload bytes from inline metadata frames.
// parity: core/src/audio-stream/demuxer.ts#AudioStreamDemuxer [status=implemented hash=6c46835ca1c5]
public protocol AudioStreamDemuxer<Metadata>: AnyObject, Sendable {
    associatedtype Metadata: Sendable
    var initialMetadata: Metadata? { get }
    func push(_ chunk: [UInt8]) -> [AudioStreamDemuxOutput<Metadata>]
    func flush() throws -> [AudioStreamDemuxOutput<Metadata>]
    func abort(reason: (any Error)?)
}

public extension AudioStreamDemuxer {
    func abort(reason: (any Error)?) {}
}

/// Factory closure producing a fresh `AudioStreamDemuxer` per stream connection attempt.
// parity: core/src/audio-stream/demuxer.ts#AudioStreamDemuxerFactory [status=implemented hash=b08c930e7809]
public typealias AudioStreamDemuxerFactory<M: Sendable> = @Sendable () -> any AudioStreamDemuxer<M>

// MARK: - ICY Metadata Parsing

/// Parses a NUL-padded Shoutcast/Icecast inline metadata payload (`Key='Value';Key2='Value2';`).
/// Returns `nil` when empty or when no valid `Key='Value';` entries are present.
// parity: core/src/audio-stream/icy/metadata.ts#parseIcyMetadata [status=implemented hash=2151724843a7]
public func parseIcyMetadata(
    _ bytes: [UInt8],
    encoding: IcyMetadataEncoding = .iso88591
) -> [String: String]? {
    let decoded = encoding.decode(bytes)
    let text: Substring
    if let nulIndex = decoded.firstIndex(of: "\0") {
        text = decoded[..<nulIndex]
    } else {
        text = decoded[...]
    }
    if text.isEmpty {
        return nil
    }

    var fields: [String: String] = [:]
    var found = false
    var offset = text.startIndex

    while offset < text.endIndex {
        guard let eqQuote = findSubstring("='", in: text, from: offset) else {
            break
        }
        let key = text[offset..<eqQuote.lowerBound]
        if key.isEmpty || key.contains(where: { $0 == "'" || $0 == ";" || $0 == "=" }) {
            break
        }
        let valueStart = eqQuote.upperBound
        guard let quoteSemi = findSubstring("';", in: text, from: valueStart) else {
            break
        }
        let value = text[valueStart..<quoteSemi.lowerBound]
        fields[String(key)] = String(value)
        found = true
        offset = quoteSemi.upperBound
    }

    return found ? fields : nil
}

/// Convenience overload accepting a metadata encoding label (e.g. `"iso-8859-1"` or `"utf-8"`).
public func parseIcyMetadata(
    _ bytes: [UInt8],
    encodingName: String
) throws(AudioStreamDemuxerError) -> [String: String]? {
    guard let encoding = IcyMetadataEncoding(label: encodingName) else {
        throw .unsupportedMetadataEncoding(encodingName)
    }
    return parseIcyMetadata(bytes, encoding: encoding)
}

private func findSubstring(
    _ needle: String,
    in haystack: Substring,
    from start: Substring.Index
) -> Range<Substring.Index>? {
    let needleCount = needle.count
    guard needleCount > 0 else { return start..<start }
    var cursor = start
    while cursor < haystack.endIndex {
        if haystack[cursor...].hasPrefix(needle) {
            let end = haystack.index(cursor, offsetBy: needleCount)
            return cursor..<end
        }
        cursor = haystack.index(after: cursor)
    }
    return nil
}

// MARK: - ICY Stream Demuxer

/// Configuration options for `IcyStreamDemuxer`.
// parity: core/src/audio-stream/icy/demuxer.ts#IcyStreamDemuxerOptions [status=implemented hash=de69561f747f]
public struct IcyStreamDemuxerOptions: Equatable, Hashable, Sendable {
    public var metadataInterval: Int
    public var metadataEncoding: String?
    public var headers: [String: String]

    public init(
        metadataInterval: Int,
        metadataEncoding: String? = nil,
        headers: [String: String] = [:]
    ) {
        self.metadataInterval = metadataInterval
        self.metadataEncoding = metadataEncoding
        self.headers = headers
    }
}

private func normalizeIcyHeaders(_ headers: [String: String]) -> [String: String] {
    var result: [String: String] = [:]
    result.reserveCapacity(headers.count)
    for (name, value) in headers {
        result[name.lowercased()] = value
    }
    return result
}

/// Icecast/Shoutcast (`icy-metaint`) stream demuxer separating interleaved audio bytes
/// from inline length-prefixed metadata blocks across arbitrary chunk boundaries.
// parity: core/src/audio-stream/icy/demuxer.ts#IcyStreamDemuxer [status=implemented hash=ac9a15f0c98d]
public final class IcyStreamDemuxer: AudioStreamDemuxer, @unchecked Sendable {
    public typealias Metadata = AudioStreamMetadata

    public let initialMetadata: AudioStreamMetadata?

    private let interval: Int
    private let encoding: IcyMetadataEncoding
    private let headers: [String: String]
    private var audioRemaining: Int
    private var metadataBuffer: [UInt8]? = nil
    private var metadataOffset: Int = 0
    private var fields: [String: String] = [:]

    public init(options: IcyStreamDemuxerOptions) throws(AudioStreamDemuxerError) {
        guard options.metadataInterval >= 0 else {
            throw .invalidMetadataInterval("\(options.metadataInterval)")
        }
        let encodingName = options.metadataEncoding ?? "iso-8859-1"
        guard let resolvedEncoding = IcyMetadataEncoding(label: encodingName) else {
            throw .unsupportedMetadataEncoding(encodingName)
        }
        self.interval = options.metadataInterval
        self.encoding = resolvedEncoding
        self.headers = normalizeIcyHeaders(options.headers)
        self.audioRemaining = options.metadataInterval
        self.initialMetadata = AudioStreamMetadata(format: .icy, headers: self.headers, fields: [:])
    }

    public func push(_ chunk: [UInt8]) -> [AudioStreamDemuxOutput<AudioStreamMetadata>] {
        if interval == 0 {
            return chunk.isEmpty ? [] : [.audio(chunk)]
        }

        var outputs: [AudioStreamDemuxOutput<AudioStreamMetadata>] = []
        var offset = 0

        while offset < chunk.count {
            if audioRemaining > 0 {
                let length = min(audioRemaining, chunk.count - offset)
                outputs.append(.audio(Array(chunk[offset..<(offset + length)])))
                offset += length
                audioRemaining -= length
                continue
            }

            if metadataBuffer == nil {
                let metadataLength = Int(chunk[offset]) * 16
                offset += 1
                if metadataLength == 0 {
                    audioRemaining = interval
                    continue
                }
                metadataBuffer = Array(repeating: 0, count: metadataLength)
                metadataOffset = 0
            }

            if var buffer = metadataBuffer {
                let length = min(buffer.count - metadataOffset, chunk.count - offset)
                for i in 0..<length {
                    buffer[metadataOffset + i] = chunk[offset + i]
                }
                offset += length
                metadataOffset += length

                if metadataOffset < buffer.count {
                    metadataBuffer = buffer
                    continue
                }

                metadataBuffer = nil
                metadataOffset = 0
                audioRemaining = interval

                if let parsed = parseIcyMetadata(buffer, encoding: encoding), parsed != fields {
                    fields = parsed
                    outputs.append(
                        .metadata(AudioStreamMetadata(format: .icy, headers: headers, fields: parsed))
                    )
                }
            }
        }

        return outputs
    }

    public func flush() throws(AudioStreamDemuxerError) -> [AudioStreamDemuxOutput<AudioStreamMetadata>] {
        if interval == 0 {
            return []
        }
        if audioRemaining == 0 || metadataBuffer != nil {
            throw .truncatedMetadataBlock
        }
        return []
    }
}

/// Constructs an `IcyStreamDemuxer` from options.
// parity: core/src/audio-stream/icy/demuxer.ts#createIcyStreamDemuxer [status=implemented hash=d01dddee1812]
public func createIcyStreamDemuxer(
    _ options: IcyStreamDemuxerOptions
) throws(AudioStreamDemuxerError) -> IcyStreamDemuxer {
    try IcyStreamDemuxer(options: options)
}

/// Inspects HTTP response headers and creates an `IcyStreamDemuxer` when `icy-*` headers
/// or `icy-metaint` are present, or returns `nil` for plain non-ICY streams.
// parity: core/src/audio-stream/demuxer.ts#selectAudioStreamDemuxer [status=implemented hash=f8969892d746]
public func selectAudioStreamDemuxer(
    headers: [String: String],
    metadataEncoding: String = "iso-8859-1"
) throws(AudioStreamDemuxerError) -> IcyStreamDemuxer? {
    var icyHeaders: [String: String] = [:]
    var rawInterval: String? = nil

    for (name, value) in headers {
        let lower = name.lowercased()
        if lower.hasPrefix("icy-") {
            icyHeaders[lower] = value
        }
        if lower == "icy-metaint" {
            rawInterval = value
        }
    }

    guard let rawInterval else {
        if icyHeaders.isEmpty {
            return nil
        }
        return try createIcyStreamDemuxer(
            IcyStreamDemuxerOptions(
                metadataInterval: 0,
                metadataEncoding: metadataEncoding,
                headers: icyHeaders
            )
        )
    }

    let trimmed = rawInterval.trimmingCharacters(in: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
    guard !trimmed.isEmpty,
          trimmed.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
          let interval = Int(trimmed),
          interval >= 0
    else {
        throw .invalidMetadataInterval(rawInterval)
    }

    return try createIcyStreamDemuxer(
        IcyStreamDemuxerOptions(
            metadataInterval: interval,
            metadataEncoding: metadataEncoding,
            headers: icyHeaders
        )
    )
}
