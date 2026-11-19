/// Test helper utilities for `OpenCodeAITests` (deliberately does NOT import `Testing`
/// to preserve macOS Command Line Tools cross-import compatibility).

import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

struct MockHTTPTransport: HTTPTransport {
    let responseHead: HTTPResponseHead
    let chunks: [[UInt8]]

    init(statusCode: Int = 200, headers: [String: String] = [:], chunks: [[UInt8]]) {
        self.responseHead = HTTPResponseHead(statusCode: statusCode, headers: headers)
        self.chunks = chunks
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        _ = request
        return HTTPResponse(head: responseHead, body: chunks.flatMap { $0 })
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        _ = request
        let localChunks = chunks
        let stream = AsyncThrowingStream<[UInt8], Error> { continuation in
            for chunk in localChunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        return HTTPStreamingResponse(head: responseHead, chunks: stream)
    }
}

enum AITestHelpers {
    static func encodeBedrockEventFrame(
        eventType: String,
        payload: [String: JSONValue],
        messageType: String = "event"
    ) -> [UInt8] {
        let jsonText = AIProtocolUtils.JSONCodec.encodeObject(payload)
        let typeHeaderKey = messageType == "exception" ? ":exception-type" : ":event-type"
        let msg = BedrockEventStream.BinaryMessage(
            headers: [
                ":message-type": .string(messageType),
                typeHeaderKey: .string(eventType),
                ":content-type": .string("application/json"),
            ],
            body: Array(jsonText.utf8)
        )
        return BedrockEventStream.encodeMessage(msg)
    }

    static func encodeFloat32LEBase64(_ values: [Float]) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(values.count * 4)
        for v in values {
            let bits = v.bitPattern
            bytes.append(UInt8(bits & 0xFF))
            bytes.append(UInt8((bits >> 8) & 0xFF))
            bytes.append(UInt8((bits >> 16) & 0xFF))
            bytes.append(UInt8((bits >> 24) & 0xFF))
        }
        return bytesToBase64(bytes)
    }

    static func sseBytes(_ events: [(event: String?, data: String)]) -> [UInt8] {
        var text = ""
        for entry in events {
            if let ev = entry.event {
                text += "event: \(ev)\n"
            }
            text += "data: \(entry.data)\n\n"
        }
        return Array(text.utf8)
    }

    static func decodeRequestBody(_ request: HTTPRequest) throws -> [String: JSONValue] {
        let raw = String(decoding: request.body ?? [], as: UTF8.self)
        let decoded = try AIProtocolUtils.JSONCodec.decode(raw)
        return AIProtocolUtils.JSONCodec.objectValue(decoded) ?? [:]
    }
}
