#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeAI
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer

/// Driver-answered OpenAI Chat Completions SSE route for `SimulationNetwork`
/// (`packages/simulation/src/backend/openai.ts`).
///
/// Claims `POST https://api.openai.com/v1/chat/completions`, invokes `SimulatedProvider.Interface`,
/// and streams its provider events as OpenAI Chat SSE chunks terminated by `data: [DONE]`.
public enum SimulationOpenAI {
    private static let endpointURL = AIProtocols.OpenAIChat.DEFAULT_BASE_URL + AIProtocols.OpenAIChat.PATH

    /// Creates a `SimulationNetwork.Route` claiming `POST {DEFAULT_BASE_URL}{PATH}` and streaming OpenAI SSE events.
    // parity: simulation/src/backend/openai.ts#route [status=implemented hash=fcd86781d4a4]
    public static func route(_ provider: any SimulatedProvider.Interface) -> SimulationNetwork.Route {
        SimulationNetwork.Route { request, url in
            guard request.method.uppercased() == "POST" else { return nil }
            guard url.origin + url.pathname == endpointURL else { return nil }
            return {
                let body: JSONValue
                if let rawBody = request.body, !rawBody.isEmpty {
                    do {
                        body = try ServerCodec.decode(JSONValue.self, from: rawBody)
                    } catch {
                        throw SimulationNetwork.TransportError(
                            requestMethod: request.method,
                            requestURL: request.url,
                            detail: "Simulation received an invalid OpenAI request body",
                            causeDescription: String(describing: error)
                        )
                    }
                } else {
                    body = .object([:])
                }

                let events = provider.stream(SimulatedProvider.ProviderRequest(url: request.url, body: body))
                let chunks = AsyncThrowingStream<[UInt8], Error> { continuation in
                    let task = Task {
                        do {
                            for try await event in events {
                                let encoded = try encodeSSEFrame(event)
                                continuation.yield(encoded)
                            }
                            continuation.yield(Array("data: [DONE]\n\n".utf8))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in
                        task.cancel()
                    }
                }
                let head = HTTPResponseHead(
                    statusCode: 200,
                    headers: ["content-type": "text/event-stream"]
                )
                return HTTPStreamingResponse(head: head, chunks: chunks)
            }
        }
    }

    // MARK: - OpenAI Chat SSE Wire Encoding

    private static func finishReasonWire(_ reason: OpenCodeProtocol.Backend.FinishReason) -> String {
        switch reason {
        case .stop: return "stop"
        case .toolCalls: return "tool_calls"
        case .length: return "length"
        case .contentFilter: return "content_filter"
        }
    }

    private static func encodeSSEFrame(_ event: SimulatedProvider.ProviderResponseEvent) throws -> [UInt8] {
        let jsonString: String
        switch event {
        case .finish(let reason):
            let payload: [String: JSONValue] = [
                "choices": .array([
                    .object([
                        "delta": .object([:]),
                        "finish_reason": .string(finishReasonWire(reason)),
                    ]),
                ]),
            ]
            jsonString = try encodeOrderedChunk(payload)

        case .item(let item):
            switch item {
            case .textDelta(let text):
                jsonString = "{\"choices\":[{\"delta\":{\"content\":\(try encodeLiteral(text))}}]}"
            case .reasoningDelta(let text):
                jsonString = "{\"choices\":[{\"delta\":{\"reasoning_content\":\(try encodeLiteral(text))}}]}"
            case .toolInputStart(let index, let id, let name):
                let idxStr = formatNumber(index)
                jsonString = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":\(idxStr),\"id\":\(try encodeLiteral(id)),\"function\":{\"name\":\(try encodeLiteral(name)),\"arguments\":\"\"}}]}}]}"
            case .toolInputDelta(let index, let text):
                let idxStr = formatNumber(index)
                jsonString = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":\(idxStr),\"function\":{\"arguments\":\(try encodeLiteral(text))}}]}}]}"
            case .toolCall(let index, let id, let name, let input):
                let idxStr = formatNumber(index)
                let argsJSON = try ServerCodec.encodeString(input)
                jsonString = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":\(idxStr),\"id\":\(try encodeLiteral(id)),\"function\":{\"name\":\(try encodeLiteral(name)),\"arguments\":\(try encodeLiteral(argsJSON))}}]}}]}"
            case .raw(let chunk):
                jsonString = try ServerCodec.encodeString(chunk)
            }
        }
        return Array("data: \(jsonString)\n\n".utf8)
    }

    private static func encodeOrderedChunk(_ payload: [String: JSONValue]) throws -> String {
        try ServerCodec.encodeString(payload)
    }

    private static func encodeLiteral(_ text: String) throws -> String {
        try ServerCodec.encodeString(text)
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.isFinite, value.rounded() == value, value >= Double(Int64.min), value <= Double(Int64.max) {
            return String(Int64(value))
        }
        return String(value)
    }
}
