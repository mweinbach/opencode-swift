/// Pure Swift 6.2 schema primitives and foundational domain schemas.
/// Ports `packages/schema/src/{schema,money,token-usage,file-diff,blob-store,reference,snapshot,usage-limits,goal,command,question,llm,models-dev}.ts`.
/// 100% pure Swift standard library (zero OS imports, zero Foundation imports).

public enum SchemaPrimitive {
    public enum ValidationError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        case notPositive(Int)
        case negative(Int)
        case notFinite(Double)
        case outOfRange(Double, min: Double, max: Double)
        case intOutOfRange(Int, min: Int, max: Int)
        case invalidFormat(expected: String, actual: String)
        case invalidPrefix(expected: String, actual: String)
        case emptyString(field: String)
        case invalidLiteral(expected: String, actual: String)
        case unexpectedKey(String)
        case mutuallyExclusiveKeys(String, String)
        case missingRequiredKey(String)

        public var description: String {
            switch self {
            case .notPositive(let v):
                return "Expected positive integer (> 0), got \(v)"
            case .negative(let v):
                return "Expected non-negative integer (>= 0), got \(v)"
            case .notFinite(let v):
                return "Expected finite number, got \(v)"
            case .outOfRange(let v, let min, let max):
                return "Expected number in \(min)...\(max), got \(v)"
            case .intOutOfRange(let v, let min, let max):
                return "Expected integer in \(min)...\(max), got \(v)"
            case .invalidFormat(let expected, let actual):
                return "Expected format \(expected), got '\(actual)'"
            case .invalidPrefix(let expected, let actual):
                return "Expected prefix '\(expected)', got '\(actual)'"
            case .emptyString(let field):
                return "Expected non-empty string for '\(field)'"
            case .invalidLiteral(let expected, let actual):
                return "Expected literal '\(expected)', got '\(actual)'"
            case .unexpectedKey(let key):
                return "Unexpected key '\(key)'"
            case .mutuallyExclusiveKeys(let a, let b):
                return "Keys '\(a)' and '\(b)' are mutually exclusive"
            case .missingRequiredKey(let key):
                return "Missing required key '\(key)'"
            }
        }
    }

    public enum EventDurability: String, Equatable, Hashable, Sendable, Codable {
        case ephemeral
        case durable
    }

    public struct DurableEventMeta: Equatable, Hashable, Sendable, Codable {
        public let aggregate: String
        public let version: Int

        public init(aggregate: String, version: Int) {
            self.aggregate = aggregate
            self.version = version
        }
    }

    public struct EventDescriptor: Equatable, Hashable, Sendable, Codable {
        public let type: String
        public let identifier: String
        public let durability: EventDurability
        public let durable: DurableEventMeta?

        public init(
            type: String,
            identifier: String? = nil,
            durability: EventDurability = .ephemeral,
            durable: DurableEventMeta? = nil
        ) {
            self.type = type
            self.identifier = identifier ?? type
            self.durability = durability
            self.durable = durable
        }

        public static func ephemeral(type: String, identifier: String? = nil) -> EventDescriptor {
            EventDescriptor(type: type, identifier: identifier, durability: .ephemeral, durable: nil)
        }

        public static func durable(
            type: String,
            aggregate: String,
            version: Int,
            identifier: String? = nil
        ) -> EventDescriptor {
            EventDescriptor(
                type: type,
                identifier: identifier,
                durability: .durable,
                durable: DurableEventMeta(aggregate: aggregate, version: version)
            )
        }
    }

    /// Three-state nullable wrapper when composed with `Optional`:
    /// `nil` = key omitted, `.some(.null)` = explicit JSON `null`, `.some(.value(v))` = value `v`.
    public enum Nullable<T: Equatable & Hashable & Sendable & Codable>: Equatable, Hashable, Sendable, Codable {
        case null
        case value(T)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else {
                self = .value(try container.decode(T.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null:
                try container.encodeNil()
            case .value(let v):
                try container.encode(v)
            }
        }
    }

    /// Dynamic coding key for open-ended objects (`StructWithRest`) and strict excess-key checks.
    public struct AnyCodingKey: CodingKey, Hashable, Sendable {
        public let stringValue: String
        public let intValue: Int?

        public init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        public init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }

        public init(_ string: String) {
            self.stringValue = string
            self.intValue = nil
        }
    }

    // MARK: - src/schema.ts

    /// Strictly positive integer (`> 0`).
    // parity: schema/src/schema.ts#PositiveInt [status=implemented hash=7f68d9cac599]
    public struct PositiveInt: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: Int

        public init?(rawValue: Int) {
            guard rawValue > 0 else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: Int) throws(ValidationError) {
            guard value > 0 else { throw .notPositive(value) }
            self.rawValue = value
        }

        public var description: String { String(rawValue) }

        public static func < (lhs: PositiveInt, rhs: PositiveInt) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(Int.self)
            guard value > 0 else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected positive integer (> 0), got \(value)"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Non-negative integer (`>= 0`).
    // parity: schema/src/schema.ts#NonNegativeInt [status=implemented hash=1f05fb2dec09]
    public struct NonNegativeInt: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: Int

        public static let zero = NonNegativeInt(unchecked: 0)

        private init(unchecked value: Int) {
            self.rawValue = value
        }

        public init?(rawValue: Int) {
            guard rawValue >= 0 else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: Int) throws(ValidationError) {
            guard value >= 0 else { throw .negative(value) }
            self.rawValue = value
        }

        public var description: String { String(rawValue) }

        public static func < (lhs: NonNegativeInt, rhs: NonNegativeInt) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(Int.self)
            guard value >= 0 else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected non-negative integer (>= 0), got \(value)"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Branded relative path string.
    // parity: schema/src/schema.ts#RelativePath [status=implemented hash=a13cf9ceb9de]
    public struct RelativePath: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Branded absolute path string.
    // parity: schema/src/schema.ts#AbsolutePath [status=implemented hash=a7d3f72b7cf9]
    public struct AbsolutePath: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Optional-key combinator semantics: in Swift `Codable`, `Optional<T>` with `encodeIfPresent` omits absent/`nil` keys.
    // parity: schema/src/schema.ts#optional [status=adapted hash=4707cfecf66c]
    public static func optional<T: Sendable>(_ value: T?) -> T? {
        value
    }

    /// Container pairing a schema descriptor with attached static helpers.
    public struct StaticAttachment<Schema: Sendable, Statics: Sendable>: Sendable {
        public let schema: Schema
        public let statics: Statics

        public init(schema: Schema, statics: Statics) {
            self.schema = schema
            self.statics = statics
        }
    }

    /// Attaches static helpers to a schema value.
    // parity: schema/src/schema.ts#withStatics [status=adapted hash=c01f36deb0b4]
    public static func withStatics<Schema: Sendable, Statics: Sendable>(
        _ schema: Schema,
        _ methods: Statics
    ) -> StaticAttachment<Schema, Statics> {
        StaticAttachment(schema: schema, statics: methods)
    }

    /// Pipeable builder that attaches computed static helpers to a schema value.
    // parity: schema/src/schema.ts#statics [status=adapted hash=160529ee2162]
    public static func statics<Schema: Sendable, Statics: Sendable>(
        _ build: @escaping @Sendable (Schema) -> Statics
    ) -> @Sendable (Schema) -> StaticAttachment<Schema, Statics> {
        { schema in
            withStatics(schema, build(schema))
        }
    }

    /// UTC timestamp represented on the wire as finite milliseconds since the Unix epoch.
    // parity: schema/src/schema.ts#DateTimeUtcFromMillis [status=implemented hash=0cd8d501c6e9]
    public struct DateTimeUtcFromMillis: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
        public let epochMillis: Double

        public init?(epochMillis: Double) {
            guard epochMillis.isFinite else { return nil }
            self.epochMillis = epochMillis
        }

        public init(validating epochMillis: Double) throws(ValidationError) {
            guard epochMillis.isFinite else { throw .notFinite(epochMillis) }
            self.epochMillis = epochMillis
        }

        public var description: String { String(epochMillis) }

        public static func < (lhs: DateTimeUtcFromMillis, rhs: DateTimeUtcFromMillis) -> Bool {
            lhs.epochMillis < rhs.epochMillis
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(Double.self)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected finite epoch milliseconds, got \(value)"
                )
            }
            self.epochMillis = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(epochMillis)
        }
    }

    // MARK: - Pure stdlib pattern validators (zero Foundation/Regex imports)

    @inline(__always)
    static func isAsciiDigit(_ b: UInt8) -> Bool {
        b >= 0x30 && b <= 0x39
    }

    @inline(__always)
    static func isAsciiLower(_ b: UInt8) -> Bool {
        b >= 0x61 && b <= 0x7A
    }

    @inline(__always)
    static func isAsciiUpper(_ b: UInt8) -> Bool {
        b >= 0x41 && b <= 0x5A
    }

    @inline(__always)
    static func isAsciiLetter(_ b: UInt8) -> Bool {
        isAsciiLower(b) || isAsciiUpper(b)
    }

    @inline(__always)
    static func isLowerHex(_ b: UInt8) -> Bool {
        isAsciiDigit(b) || (b >= 0x61 && b <= 0x66)
    }

    @inline(__always)
    static func isHex(_ b: UInt8) -> Bool {
        isLowerHex(b) || (b >= 0x41 && b <= 0x46)
    }

    @inline(__always)
    static func isBase62(_ b: UInt8) -> Bool {
        isAsciiDigit(b) || isAsciiLetter(b)
    }

    /// Validates `^<prefix>[0-9a-f]{12}[0-9A-Za-z]{14}$` (e.g. `blob_...`, `video_...`).
    static func isStrictPrefixedIdentifier(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let suffix = Array(value.utf8.dropFirst(prefix.utf8.count))
        guard suffix.count == 26 else { return false }
        for i in 0..<12 {
            if !isLowerHex(suffix[i]) { return false }
        }
        for i in 12..<26 {
            if !isBase62(suffix[i]) { return false }
        }
        return true
    }

    /// Validates `^#[0-9a-fA-F]{6}$`.
    static func isHexColor(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 7, bytes[0] == 0x23 else { return false }
        for i in 1..<7 {
            if !isHex(bytes[i]) { return false }
        }
        return true
    }

    /// Validates `^([1-9]\d?(\.\d+)?)%$`.
    static func isCompactionPercent(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 2, bytes.last == 0x25 else { return false }
        let body = bytes.dropLast()
        guard let first = body.first, first >= 0x31 && first <= 0x39 else { return false }
        var idx = body.index(after: body.startIndex)
        if idx < body.endIndex, isAsciiDigit(body[idx]) {
            idx = body.index(after: idx)
        }
        if idx == body.endIndex { return true }
        guard body[idx] == 0x2E else { return false }
        idx = body.index(after: idx)
        guard idx < body.endIndex else { return false }
        while idx < body.endIndex {
            guard isAsciiDigit(body[idx]) else { return false }
            idx = body.index(after: idx)
        }
        return true
    }

    /// Validates `^\d{4}-\d{2}(-\d{2})?$`.
    static func isReleaseDate(_ value: String) -> Bool {
        let b = Array(value.utf8)
        guard b.count == 7 || b.count == 10 else { return false }
        guard isAsciiDigit(b[0]), isAsciiDigit(b[1]), isAsciiDigit(b[2]), isAsciiDigit(b[3]),
              b[4] == 0x2D, isAsciiDigit(b[5]), isAsciiDigit(b[6])
        else { return false }
        if b.count == 10 {
            return b[7] == 0x2D && isAsciiDigit(b[8]) && isAsciiDigit(b[9])
        }
        return true
    }

    /// Validates `^\d+(ms|s|m|h|d)$`.
    static func isCacheTTL(_ value: String) -> Bool {
        let b = Array(value.utf8)
        var i = 0
        while i < b.count && isAsciiDigit(b[i]) {
            i += 1
        }
        guard i > 0, i < b.count else { return false }
        let unit = b[i...]
        if unit.count == 2 {
            return unit[i] == 0x6D && unit[i + 1] == 0x73 // "ms"
        }
        if unit.count == 1 {
            let c = unit[i]
            return c == 0x73 || c == 0x6D || c == 0x68 || c == 0x64 // s, m, h, d
        }
        return false
    }

    /// Validates `^\d+(?:\.\d+)?:\d+(?:\.\d+)?$`.
    static func isAspectRatio(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return isUnsignedDecimal(parts[0]) && isUnsignedDecimal(parts[1])
    }

    static func isUnsignedDecimal(_ slice: Substring) -> Bool {
        let b = Array(slice.utf8)
        guard !b.isEmpty else { return false }
        var i = 0
        while i < b.count && isAsciiDigit(b[i]) { i += 1 }
        guard i > 0 else { return false }
        if i == b.count { return true }
        guard b[i] == 0x2E else { return false }
        i += 1
        let fracStart = i
        while i < b.count && isAsciiDigit(b[i]) { i += 1 }
        return i > fracStart && i == b.count
    }

    /// Linear base64 check matching `prompt.ts#Base64`:
    /// `value.length % 4 === 0 && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/`
    static func isValidBase64(_ value: String) -> Bool {
        let b = Array(value.utf8)
        guard b.count % 4 == 0 else { return false }
        if b.isEmpty { return true }
        var padCount = 0
        if b[b.count - 1] == 0x3D {
            padCount = 1
            if b.count >= 2 && b[b.count - 2] == 0x3D {
                padCount = 2
            }
        }
        let dataLen = b.count - padCount
        for i in 0..<dataLen {
            let c = b[i]
            let ok = isAsciiLetter(c) || isAsciiDigit(c) || c == 0x2B || c == 0x2F // '+' or '/'
            if !ok { return false }
        }
        return true
    }

    /// Validates `^[a-z0-9][a-z0-9._-]*\/[a-z0-9][a-z0-9._/-]*$`.
    static func isInstructionKey(_ value: String) -> Bool {
        let b = Array(value.utf8)
        guard let slash = b.firstIndex(of: 0x2F), slash > 0, slash + 1 < b.count else { return false }
        guard isAsciiLower(b[0]) || isAsciiDigit(b[0]) else { return false }
        for i in 1..<slash {
            let c = b[i]
            if !(isAsciiLower(c) || isAsciiDigit(c) || c == 0x2E || c == 0x5F || c == 0x2D) { return false }
        }
        let after = slash + 1
        guard isAsciiLower(b[after]) || isAsciiDigit(b[after]) else { return false }
        for i in (after + 1)..<b.count {
            let c = b[i]
            if !(isAsciiLower(c) || isAsciiDigit(c) || c == 0x2E || c == 0x5F || c == 0x2F || c == 0x2D) {
                return false
            }
        }
        return true
    }

    /// Validates `^[a-z0-9][a-z0-9._-]*$`.
    static func isInstructionEntryKey(_ value: String) -> Bool {
        let b = Array(value.utf8)
        guard !b.isEmpty, isAsciiLower(b[0]) || isAsciiDigit(b[0]) else { return false }
        for i in 1..<b.count {
            let c = b[i]
            if !(isAsciiLower(c) || isAsciiDigit(c) || c == 0x2E || c == 0x5F || c == 0x2D) { return false }
        }
        return true
    }

    /// Validates `^[a-f0-9]{64}$`.
    static func isSha256Hex(_ value: String) -> Bool {
        let b = Array(value.utf8)
        guard b.count == 64 else { return false }
        return b.allSatisfy(isLowerHex)
    }

    /// Validates `^[a-z][a-z0-9._-]*$`.
    static func isProjectVcs(_ value: String) -> Bool {
        let b = Array(value.utf8)
        guard !b.isEmpty, isAsciiLower(b[0]) else { return false }
        for i in 1..<b.count {
            let c = b[i]
            if !(isAsciiLower(c) || isAsciiDigit(c) || c == 0x2E || c == 0x5F || c == 0x2D) { return false }
        }
        return true
    }

    /// Validates `^image/` case-insensitively.
    static func isImageMime(_ value: String) -> Bool {
        let b = Array(value.utf8)
        guard b.count >= 6 else { return false }
        let prefix: [UInt8] = [0x69, 0x6D, 0x61, 0x67, 0x65, 0x2F] // "image/"
        for i in 0..<6 {
            let c = (b[i] >= 0x41 && b[i] <= 0x5A) ? (b[i] + 32) : b[i]
            if c != prefix[i] { return false }
        }
        return true
    }

    /// Matches JS `/\S/` (contains at least one non-whitespace character).
    static func containsNonWhitespace(_ value: String) -> Bool {
        value.contains { !$0.isWhitespace && $0 != "\u{FEFF}" }
    }

    /// Trims leading and trailing whitespace matching JS `String.prototype.trim()`.
    static func trimWhitespace(_ value: String) -> String {
        var start = value.startIndex
        var end = value.endIndex
        while start < end && (value[start].isWhitespace || value[start] == "\u{FEFF}") {
            start = value.index(after: start)
        }
        while end > start {
            let prev = value.index(before: end)
            if value[prev].isWhitespace || value[prev] == "\u{FEFF}" {
                end = prev
            } else {
                break
            }
        }
        return String(value[start..<end])
    }

    /// Validates an optional `Schema.Literal(true)` field.
    static func decodeOptionalLiteralTrue<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Bool? {
        guard let value = try container.decodeIfPresent(Bool.self, forKey: key) else {
            return nil
        }
        guard value == true else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Expected literal true for '\(key.stringValue)', got false"
            )
        }
        return true
    }

    /// Validates a required `Schema.Literal(expected)` string discriminator.
    static func decodeRequiredLiteral<K: CodingKey>(
        _ expected: String,
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws {
        let actual = try container.decode(String.self, forKey: key)
        guard actual == expected else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Expected literal '\(expected)' for '\(key.stringValue)', got '\(actual)'"
            )
        }
    }

    /// Validates a finite `Double` field.
    static func decodeFinite<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Double {
        let value = try container.decode(Double.self, forKey: key)
        guard value.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Expected finite number for '\(key.stringValue)'"
            )
        }
        return value
    }

    static func decodeFiniteIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Double? {
        guard let value = try container.decodeIfPresent(Double.self, forKey: key) else {
            return nil
        }
        guard value.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Expected finite number for '\(key.stringValue)'"
            )
        }
        return value
    }
}

// MARK: - src/money.ts

public enum MoneySchema {
    /// Branded US dollar amount (finite number).
    // parity: schema/src/money.ts#USD [status=implemented hash=70c071f60fee]
    public struct USD: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: Double

        public static let zero = USD(unchecked: 0)

        private init(unchecked value: Double) {
            self.rawValue = value
        }

        public init?(rawValue: Double) {
            guard rawValue.isFinite else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: Double) throws(SchemaPrimitive.ValidationError) {
            guard value.isFinite else { throw .notFinite(value) }
            self.rawValue = value
        }

        public var description: String { String(rawValue) }

        public static func < (lhs: USD, rhs: USD) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(Double.self)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected finite USD amount")
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Branded US dollar rate per 1,000,000 tokens (finite number).
    // parity: schema/src/money.ts#USDPerMillionTokens [status=implemented hash=a9ede6972333]
    public struct USDPerMillionTokens: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: Double

        public static let zero = USDPerMillionTokens(unchecked: 0)

        private init(unchecked value: Double) {
            self.rawValue = value
        }

        public init?(rawValue: Double) {
            guard rawValue.isFinite else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: Double) throws(SchemaPrimitive.ValidationError) {
            guard value.isFinite else { throw .notFinite(value) }
            self.rawValue = value
        }

        public var description: String { String(rawValue) }

        public static func < (lhs: USDPerMillionTokens, rhs: USDPerMillionTokens) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(Double.self)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected finite USDPerMillionTokens amount"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}

// MARK: - src/token-usage.ts

public enum TokenUsageSchema {
    public struct Cache: Equatable, Hashable, Sendable, Codable {
        public let read: Double
        public let write: Double

        public init(read: Double, write: Double) {
            self.read = read
            self.write = write
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.read = try SchemaPrimitive.decodeFinite(from: container, forKey: .read)
            self.write = try SchemaPrimitive.decodeFinite(from: container, forKey: .write)
        }

        enum CodingKeys: String, CodingKey {
            case read
            case write
        }
    }

    // parity: schema/src/token-usage.ts#Info [status=implemented hash=1821aa3b7f74]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let input: Double
        public let output: Double
        public let reasoning: Double
        public let cache: Cache

        public init(input: Double, output: Double, reasoning: Double, cache: Cache) {
            self.input = input
            self.output = output
            self.reasoning = reasoning
            self.cache = cache
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.input = try SchemaPrimitive.decodeFinite(from: container, forKey: .input)
            self.output = try SchemaPrimitive.decodeFinite(from: container, forKey: .output)
            self.reasoning = try SchemaPrimitive.decodeFinite(from: container, forKey: .reasoning)
            self.cache = try container.decode(Cache.self, forKey: .cache)
        }

        enum CodingKeys: String, CodingKey {
            case input
            case output
            case reasoning
            case cache
        }
    }

    // parity: schema/src/token-usage.ts#total [status=implemented hash=acced5a6ff2c]
    public static func total(_ tokens: Info) -> Double {
        tokens.input + tokens.output + tokens.reasoning + tokens.cache.read + tokens.cache.write
    }
}

// MARK: - src/file-diff.ts

public enum FileDiffSchema {
    public enum Status: String, Equatable, Hashable, Sendable, Codable {
        case added
        case deleted
        case modified
    }

    // parity: schema/src/file-diff.ts#Info [status=implemented hash=cb436e94243a]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let file: String
        public let patch: String
        public let additions: SchemaPrimitive.NonNegativeInt
        public let deletions: SchemaPrimitive.NonNegativeInt
        public let status: Status
        public let more: Bool?

        public init(
            file: String,
            patch: String,
            additions: SchemaPrimitive.NonNegativeInt,
            deletions: SchemaPrimitive.NonNegativeInt,
            status: Status,
            more: Bool? = nil
        ) {
            self.file = file
            self.patch = patch
            self.additions = additions
            self.deletions = deletions
            self.status = status
            self.more = more
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.file = try container.decode(String.self, forKey: .file)
            self.patch = try container.decode(String.self, forKey: .patch)
            self.additions = try container.decode(SchemaPrimitive.NonNegativeInt.self, forKey: .additions)
            self.deletions = try container.decode(SchemaPrimitive.NonNegativeInt.self, forKey: .deletions)
            self.status = try container.decode(Status.self, forKey: .status)
            self.more = try SchemaPrimitive.decodeOptionalLiteralTrue(from: container, forKey: .more)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(file, forKey: .file)
            try container.encode(patch, forKey: .patch)
            try container.encode(additions, forKey: .additions)
            try container.encode(deletions, forKey: .deletions)
            try container.encode(status, forKey: .status)
            if more == true {
                try container.encode(true, forKey: .more)
            }
        }

        enum CodingKeys: String, CodingKey {
            case file
            case patch
            case additions
            case deletions
            case status
            case more
        }
    }

    /// V1 snapshot and persisted session diff shape.
    // parity: schema/src/file-diff.ts#LegacyInfo [status=implemented hash=41dd04b9fa4f]
    public struct LegacyInfo: Equatable, Hashable, Sendable, Codable {
        public let file: String?
        public let patch: String?
        public let additions: Double
        public let deletions: Double
        public let status: Status?

        public init(
            file: String? = nil,
            patch: String? = nil,
            additions: Double,
            deletions: Double,
            status: Status? = nil
        ) {
            self.file = file
            self.patch = patch
            self.additions = additions
            self.deletions = deletions
            self.status = status
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.file = try container.decodeIfPresent(String.self, forKey: .file)
            self.patch = try container.decodeIfPresent(String.self, forKey: .patch)
            self.additions = try SchemaPrimitive.decodeFinite(from: container, forKey: .additions)
            self.deletions = try SchemaPrimitive.decodeFinite(from: container, forKey: .deletions)
            self.status = try container.decodeIfPresent(Status.self, forKey: .status)
        }

        enum CodingKeys: String, CodingKey {
            case file
            case patch
            case additions
            case deletions
            case status
        }
    }
}

// MARK: - src/blob-store.ts

public enum BlobStoreSchema {
    /// Strict stored blob identifier matching `^blob_[0-9a-f]{12}[0-9A-Za-z]{14}$`.
    // parity: schema/src/blob-store.ts#ID [status=implemented hash=782f9cda2a4d]
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard SchemaPrimitive.isStrictPrefixedIdentifier(rawValue, prefix: "blob_") else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(SchemaPrimitive.ValidationError) {
            guard SchemaPrimitive.isStrictPrefixedIdentifier(value, prefix: "blob_") else {
                throw .invalidFormat(expected: "^blob_[0-9a-f]{12}[0-9A-Za-z]{14}$", actual: value)
            }
            self.rawValue = value
        }

        private init(unchecked value: String) {
            self.rawValue = value
        }

        public static func create() -> ID {
            ID(unchecked: "blob_" + Identifier.descending())
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard SchemaPrimitive.isStrictPrefixedIdentifier(value, prefix: "blob_") else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid Blob.ID '\(value)'"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/blob-store.ts#Info [status=implemented hash=1821aa3b7f74]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let mime: String
        public let bytes: Double

        public init(id: ID, mime: String, bytes: Double) {
            self.id = id
            self.mime = mime
            self.bytes = bytes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(ID.self, forKey: .id)
            self.mime = try container.decode(String.self, forKey: .mime)
            self.bytes = try SchemaPrimitive.decodeFinite(from: container, forKey: .bytes)
        }

        enum CodingKeys: String, CodingKey {
            case id
            case mime
            case bytes
        }
    }
}

// MARK: - src/reference.ts

public enum ReferenceSchema {
    // parity: schema/src/reference.ts#Event [status=implemented hash=e7550d251b3a]
    public enum Event {
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "reference.updated")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated]
    }

    // parity: schema/src/reference.ts#LocalSource [status=implemented hash=f2ed21c4c1fa]
    public struct LocalSource: Equatable, Hashable, Sendable, Codable {
        public let path: SchemaPrimitive.AbsolutePath
        public let description: String?
        public let hidden: Bool?

        public init(path: SchemaPrimitive.AbsolutePath, description: String? = nil, hidden: Bool? = nil) {
            self.path = path
            self.description = description
            self.hidden = hidden
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("local", from: container, forKey: .type)
            self.path = try container.decode(SchemaPrimitive.AbsolutePath.self, forKey: .path)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
            self.hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("local", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(hidden, forKey: .hidden)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case path
            case description
            case hidden
        }
    }

    // parity: schema/src/reference.ts#GitSource [status=implemented hash=8190f5417f3b]
    public struct GitSource: Equatable, Hashable, Sendable, Codable {
        public let repository: String
        public let branch: String?
        public let description: String?
        public let hidden: Bool?

        public init(
            repository: String,
            branch: String? = nil,
            description: String? = nil,
            hidden: Bool? = nil
        ) {
            self.repository = repository
            self.branch = branch
            self.description = description
            self.hidden = hidden
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("git", from: container, forKey: .type)
            self.repository = try container.decode(String.self, forKey: .repository)
            self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
            self.hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("git", forKey: .type)
            try container.encode(repository, forKey: .repository)
            try container.encodeIfPresent(branch, forKey: .branch)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(hidden, forKey: .hidden)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case repository
            case branch
            case description
            case hidden
        }
    }

    // parity: schema/src/reference.ts#Source [status=implemented hash=5bf97c6b1971]
    public enum Source: Equatable, Hashable, Sendable, Codable {
        case local(LocalSource)
        case git(GitSource)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "local":
                self = .local(try LocalSource(from: decoder))
            case "git":
                self = .git(try GitSource(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Reference.Source type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .local(let v):
                try v.encode(to: encoder)
            case .git(let v):
                try v.encode(to: encoder)
            }
        }
    }

    // parity: schema/src/reference.ts#Info [status=implemented hash=69947df8ac9a]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let path: SchemaPrimitive.AbsolutePath
        public let description: String?
        public let hidden: Bool?
        public let source: Source

        public init(
            name: String,
            path: SchemaPrimitive.AbsolutePath,
            description: String? = nil,
            hidden: Bool? = nil,
            source: Source
        ) {
            self.name = name
            self.path = path
            self.description = description
            self.hidden = hidden
            self.source = source
        }
    }
}

// MARK: - src/snapshot.ts

public enum SnapshotSchema {
    // parity: schema/src/snapshot.ts#ID [status=implemented hash=2c04e1469c3c]
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}

// MARK: - src/usage-limits.ts

public enum UsageLimitsSchema {
    /// One window of the OpenCode Go allowance.
    // parity: schema/src/usage-limits.ts#Meter [status=implemented hash=373f7a2e37f1]
    public struct Meter: Equatable, Hashable, Sendable, Codable {
        public let percent: Double
        public let limited: Bool
        public let resetsAt: Double

        public init(percent: Double, limited: Bool, resetsAt: Double) {
            self.percent = percent
            self.limited = limited
            self.resetsAt = resetsAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let percent = try SchemaPrimitive.decodeFinite(from: container, forKey: .percent)
            guard percent >= 0 && percent <= 100 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .percent,
                    in: container,
                    debugDescription: "Expected percent in 0...100, got \(percent)"
                )
            }
            self.percent = percent
            self.limited = try container.decode(Bool.self, forKey: .limited)
            self.resetsAt = try SchemaPrimitive.decodeFinite(from: container, forKey: .resetsAt)
        }

        enum CodingKeys: String, CodingKey {
            case percent
            case limited
            case resetsAt
        }
    }

    /// The OpenCode Go allowance of a workspace the member subscribes to Go in.
    // parity: schema/src/usage-limits.ts#Go [status=implemented hash=5a23941d8c6f]
    public struct Go: Equatable, Hashable, Sendable, Codable {
        public let rolling: Meter
        public let weekly: Meter
        public let monthly: Meter

        public init(rolling: Meter, weekly: Meter, monthly: Meter) {
            self.rolling = rolling
            self.weekly = weekly
            self.monthly = monthly
        }
    }

    /// A model a budget covers, by the IDs OpenCode knows it by.
    // parity: schema/src/usage-limits.ts#BudgetModel [status=implemented hash=26215cbfa791]
    public struct BudgetModel: Equatable, Hashable, Sendable, Codable {
        public let providerID: ProviderSchema.ID
        public let modelID: ModelSchema.ID
        public let name: String
        public let spent: MoneySchema.USD?

        public init(
            providerID: ProviderSchema.ID,
            modelID: ModelSchema.ID,
            name: String,
            spent: MoneySchema.USD? = nil
        ) {
            self.providerID = providerID
            self.modelID = modelID
            self.name = name
            self.spent = spent
        }
    }

    /// A monthly spend limit the OpenCode Console workspace sets on the member.
    // parity: schema/src/usage-limits.ts#Budget [status=implemented hash=740949b5f43c]
    public struct Budget: Equatable, Hashable, Sendable, Codable {
        public enum Scope: String, Equatable, Hashable, Sendable, Codable {
            case each
            case combined
        }

        public enum Per: String, Equatable, Hashable, Sendable, Codable {
            case set
            case model
        }

        public enum Coverage: String, Equatable, Hashable, Sendable, Codable {
            case all
            case models
        }

        public let id: String
        public let limit: MoneySchema.USD
        public let spent: MoneySchema.USD
        public let scope: Scope
        public let per: Per
        public let coverage: Coverage
        public let models: [BudgetModel]
        public let vendors: [String]
        public let inputPriceAtLeast: MoneySchema.USDPerMillionTokens?
        public let picked: Bool
        public let shared: Bool
        public let resetsAt: Double

        public init(
            id: String,
            limit: MoneySchema.USD,
            spent: MoneySchema.USD,
            scope: Scope,
            per: Per,
            coverage: Coverage,
            models: [BudgetModel],
            vendors: [String],
            inputPriceAtLeast: MoneySchema.USDPerMillionTokens? = nil,
            picked: Bool,
            shared: Bool,
            resetsAt: Double
        ) {
            self.id = id
            self.limit = limit
            self.spent = spent
            self.scope = scope
            self.per = per
            self.coverage = coverage
            self.models = models
            self.vendors = vendors
            self.inputPriceAtLeast = inputPriceAtLeast
            self.picked = picked
            self.shared = shared
            self.resetsAt = resetsAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.limit = try container.decode(MoneySchema.USD.self, forKey: .limit)
            self.spent = try container.decode(MoneySchema.USD.self, forKey: .spent)
            self.scope = try container.decode(Scope.self, forKey: .scope)
            self.per = try container.decode(Per.self, forKey: .per)
            self.coverage = try container.decode(Coverage.self, forKey: .coverage)
            self.models = try container.decode([BudgetModel].self, forKey: .models)
            self.vendors = try container.decode([String].self, forKey: .vendors)
            self.inputPriceAtLeast = try container.decodeIfPresent(
                MoneySchema.USDPerMillionTokens.self,
                forKey: .inputPriceAtLeast
            )
            self.picked = try container.decode(Bool.self, forKey: .picked)
            self.shared = try container.decode(Bool.self, forKey: .shared)
            self.resetsAt = try SchemaPrimitive.decodeFinite(from: container, forKey: .resetsAt)
        }

        enum CodingKeys: String, CodingKey {
            case id
            case limit
            case spent
            case scope
            case per
            case coverage
            case models
            case vendors
            case inputPriceAtLeast
            case picked
            case shared
            case resetsAt
        }
    }

    public struct WorkspaceRef: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let name: String?
        public let usageURL: String

        public init(id: String, name: String? = nil, usageURL: String) {
            self.id = id
            self.name = name
            self.usageURL = usageURL
        }
    }

    /// The usage limits of the OpenCode Console workspace a location is signed in to.
    // parity: schema/src/usage-limits.ts#Info [status=implemented hash=1821aa3b7f74]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let workspace: WorkspaceRef
        public let go: Go?
        public let budgets: [Budget]

        public init(workspace: WorkspaceRef, go: Go? = nil, budgets: [Budget]) {
            self.workspace = workspace
            self.go = go
            self.budgets = budgets
        }
    }
}

// MARK: - src/goal.ts

public enum GoalSchema {
    // parity: schema/src/goal.ts#Status [status=implemented hash=beacb4d456f3]
    public enum Status: String, Equatable, Hashable, Sendable, Codable {
        case active
        case paused
        case complete
    }

    // parity: schema/src/goal.ts#State [status=implemented hash=294425f79da2]
    public struct State: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let objective: String
        public let status: Status
        public let reason: String?
        public let rounds: Double
        public let maxRounds: Double
        public let stalls: Double?
        public let boot: String
        public let updatedAt: Double

        public init(
            id: String,
            objective: String,
            status: Status,
            reason: String? = nil,
            rounds: Double,
            maxRounds: Double,
            stalls: Double? = nil,
            boot: String,
            updatedAt: Double
        ) {
            self.id = id
            self.objective = objective
            self.status = status
            self.reason = reason
            self.rounds = rounds
            self.maxRounds = maxRounds
            self.stalls = stalls
            self.boot = boot
            self.updatedAt = updatedAt
        }
    }

    public struct GetInput: Equatable, Hashable, Sendable, Codable {
        public let sessionID: String

        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public struct ChangedEventData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: String
        public let goal: State?

        public init(sessionID: String, goal: State?) {
            self.sessionID = sessionID
            self.goal = goal
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.sessionID = try container.decode(String.self, forKey: .sessionID)
            self.goal = try container.decode(State?.self, forKey: .goal)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(goal, forKey: .goal)
        }

        enum CodingKeys: String, CodingKey {
            case sessionID
            case goal
        }
    }

    /// The `/goal` plugin's RPC definition (`opencode.goal`).
    // parity: schema/src/goal.ts#Definition [status=implemented hash=82bdd336711f]
    public static let definition: RpcSchema.PortableDefinition = RpcSchema.PortableDefinition(
        id: "opencode.goal",
        methods: [
            "get": RpcSchema.PortableMethod(
                input: .named("Goal.GetInput"),
                output: .named("Goal.State?")
            ),
        ],
        events: [
            "changed": RpcSchema.PortableEventDefinition(
                schema: .named("Goal.ChangedEventData")
            ),
        ]
    )
}

// MARK: - src/command.ts

public enum CommandSchema {
    // parity: schema/src/command.ts#Info [status=implemented hash=1821aa3b7f74]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let description: String?

        public init(name: String, description: String? = nil) {
            self.name = name
            self.description = description
        }
    }

    // parity: schema/src/command.ts#Event [status=implemented hash=880cfa5454d1]
    public enum Event {
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "command.updated")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated]
    }
}

// MARK: - src/question.ts

public enum QuestionSchema {
    public struct Option: Equatable, Hashable, Sendable, Codable {
        public let label: String
        public let description: String

        public init(label: String, description: String) {
            self.label = label
            self.description = description
        }
    }

    // parity: schema/src/question.ts#Prompt [status=implemented hash=6fbfaa73a184]
    public struct Prompt: Equatable, Hashable, Sendable, Codable {
        public let question: String
        public let header: String
        public let options: [Option]
        public let multiple: Bool?

        public init(question: String, header: String, options: [Option], multiple: Bool? = nil) {
            self.question = question
            self.header = header
            self.options = options
            self.multiple = multiple
        }
    }

    // parity: schema/src/question.ts#Answer [status=implemented hash=98850841bfe9]
    public typealias Answer = [String]
}

// MARK: - src/llm.ts

public enum LLMSchema {
    // parity: schema/src/llm.ts#FinishReason [status=implemented hash=832a6f5ee834]
    public enum FinishReason: String, Equatable, Hashable, Sendable, Codable {
        case stop
        case length
        case toolCalls = "tool-calls"
        case contentFilter = "content-filter"
        case error
        case unknown
    }
}

// MARK: - src/models-dev.ts

public enum ModelsDevSchema {
    // parity: schema/src/models-dev.ts#Event [status=implemented hash=d7e7dc818a7c]
    public enum Event {
        public static let refreshed = SchemaPrimitive.EventDescriptor.ephemeral(type: "models-dev.refreshed")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [refreshed]
    }
}
