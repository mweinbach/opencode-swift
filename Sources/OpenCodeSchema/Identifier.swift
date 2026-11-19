#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization

/// Monotonic 26-character identifiers matching `packages/schema/src/identifier.ts`:
/// 12 lowercase hex chars encoding 48 bits of `(timestampMs * 0x1000 + counter)` (bitwise NOT when descending)
/// followed by 14 base62 random characters.
public enum Identifier {
    public static let length = 26
    public static let timeHexLength = 12
    public static let randomLength = 14

    private static let base62Chars: [UInt8] = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8
    )
    private static let hexChars: [UInt8] = Array("0123456789abcdef".utf8)

    /// Isolated monotonic generator for deterministic or concurrent callers that should not share
    /// the process-global clock state.
    public struct Generator: Sendable {
        private var lastTimestamp: Int64 = 0
        private var counter: Int64 = 0

        public init() {}

        public mutating func nextCounter(for timestamp: Int64) -> Int64 {
            if timestamp != lastTimestamp {
                lastTimestamp = timestamp
                counter = 0
            }
            counter += 1
            return counter
        }

        public mutating func create(
            descending: Bool,
            timestamp: Int64? = nil
        ) -> String {
            let ts = timestamp ?? Identifier.currentEpochMillis()
            let next = nextCounter(for: ts)
            var rng = SystemRandomNumberGenerator()
            var randomBytes = [UInt8](repeating: 0, count: Identifier.randomLength)
            for i in 0..<Identifier.randomLength {
                randomBytes[i] = UInt8.random(in: 0...255, using: &rng)
            }
            return Identifier.encode(
                descending: descending,
                timestamp: ts,
                counter: next,
                randomBytes: randomBytes
            )
        }
    }

    private static let state = Mutex(Generator())

    /// Generates an ascending (chronologically sortable) 26-character identifier.
    // parity: schema/src/identifier.ts#ascending [status=implemented hash=830998decb11]
    public static func ascending() -> String {
        create(descending: false)
    }

    /// Generates a descending (reverse-chronologically sortable) 26-character identifier.
    // parity: schema/src/identifier.ts#descending [status=implemented hash=60170da3d25e]
    public static func descending() -> String {
        create(descending: true)
    }

    /// Generates an identifier for the given direction and millisecond epoch timestamp.
    // parity: schema/src/identifier.ts#create [status=implemented hash=e770ce8eb53c]
    public static func create(
        descending: Bool,
        timestamp: Int64? = nil
    ) -> String {
        let ts = timestamp ?? currentEpochMillis()
        let counter = state.withLock { $0.nextCounter(for: ts) }
        var rng = SystemRandomNumberGenerator()
        var randomBytes = [UInt8](repeating: 0, count: randomLength)
        for i in 0..<randomLength {
            randomBytes[i] = UInt8.random(in: 0...255, using: &rng)
        }
        return encode(
            descending: descending,
            timestamp: ts,
            counter: counter,
            randomBytes: randomBytes
        )
    }

    /// Deterministic encoder for parity and unit testing.
    public static func encode(
        descending: Bool,
        timestamp: Int64,
        counter: Int64,
        randomBytes: [UInt8]
    ) -> String {
        precondition(randomBytes.count == randomLength, "Expected \(randomLength) random bytes")
        let current = Int64(bitPattern: UInt64(bitPattern: timestamp) &* 0x1000 &+ UInt64(bitPattern: counter))
        let value = descending ? ~current : current
        let bits = UInt64(bitPattern: value)

        var out: [UInt8] = []
        out.reserveCapacity(length)

        for index in 0..<6 {
            let shift = UInt64(40 - 8 * index)
            let byte = UInt8((bits >> shift) & 0xFF)
            out.append(hexChars[Int(byte >> 4)])
            out.append(hexChars[Int(byte & 0x0F)])
        }

        for byte in randomBytes {
            out.append(base62Chars[Int(byte) % 62])
        }

        return String(decoding: out, as: UTF8.self)
    }

    private static func currentEpochMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }
}
