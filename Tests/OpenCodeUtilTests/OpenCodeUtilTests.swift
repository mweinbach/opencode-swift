import Testing
import OpenCodeUtil

@Suite("OpenCodeUtil Core Unit Tests")
struct OpenCodeUtilTests {
    @Test("Base64 standard round-trip across all 256 byte values")
    func base64RoundTrip() throws {
        let raw: [UInt8] = Array(0...255)
        let encoded = bytesToBase64(raw)
        let decoded = try base64ToBytes(encoded)
        #expect(decoded == raw)
    }

    @Test("URL-safe base64 encode/decode matches upstream")
    func urlSafeBase64() throws {
        #expect(base64Encode("hello") == "aGVsbG8")
        #expect(base64Encode("✓ à la mode") == "4pyTIMOgIGxhIG1vZGU")
        #expect(try base64Decode("4pyTIMOgIGxhIG1vZGU") == "✓ à la mode")
        #expect(throws: Base64Error.self) {
            _ = try base64Decode("%%%")
        }
    }

    @Test("FNV-1a checksum and sampledChecksum match upstream")
    func checksums() {
        #expect(checksum("") == nil)
        #expect(checksum("hello") == "m3bicr")
        #expect(checksum("✓ à la mode") == "jmczk0")

        let value = String(repeating: "abcdef", count: 100)
        #expect(sampledChecksum(value, limit: value.utf16.count) == checksum(value))
        #expect(sampledChecksum(value, limit: value.utf16.count - 1) == "600:1isj1k5:1isj1k5:1isj1k5:1isj1k5:1isj1k5")
    }

    @Test("Pure-Swift SHA-1 and SHA-256 match FIPS test vectors")
    func hashes() {
        #expect(Hash.fast("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(Hash.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("TextBoundary keeps whole code points across every UTF-16 and UTF-8 cut")
    func textBoundaryExhaustive() {
        let samples = ["", "ascii", "ab😀cd", "😀é€\u{FFFD}😀"]
        for text in samples {
            let totalUTF16 = text.utf16.count
            for limit in 0...(totalUTF16 + 1) {
                let h = TextBoundary.head(text, limit: limit)
                let t = TextBoundary.tail(text, limit: limit)
                #expect(text.hasPrefix(h))
                #expect(text.hasSuffix(t))
                #expect(h.utf16.count <= limit)
                #expect(t.utf16.count <= limit)
                #expect(h.utf16.count >= max(0, min(limit, totalUTF16) - 1))
                #expect(t.utf16.count >= max(0, min(limit, totalUTF16) - 1))
            }

            let utf8 = Array(text.utf8)
            for limit in 0...(utf8.count + 1) {
                let tail = TextBoundary.utf8Tail(utf8, limit: limit)
                #expect(text.hasSuffix(tail))
                #expect(tail.utf8.count <= limit)
                #expect(tail.utf8.count >= max(0, min(limit, utf8.count) - 3))
            }
        }
    }

    @Test("SessionMention round-trips and rejects malformed IDs")
    func sessionMention() {
        let id = "ses_0123456789abcdefghijklmnop"
        #expect(serializeSessionMention(SessionMention(id: id)) == "@session:\(id)")
        #expect(parseSessionMention("@session:\(id)") == SessionMention(id: id))
        #expect(parseSessionMention(id) == SessionMention(id: id))
        #expect(sessionMentions("See @session:\(id), then \(id).").map(\.id) == [id, id])

        for bad in ["ses_123", "@session:\(id)extra", "x\(id)", "\(id)/path", "https://host/\(id)", "@other:\(id)", "\(id)_x"] {
            #expect(parseSessionMention(bad) == nil)
            #expect(sessionMentions(bad).isEmpty)
        }
    }
}
