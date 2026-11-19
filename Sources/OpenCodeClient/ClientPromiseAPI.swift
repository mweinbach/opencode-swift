#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Client Error (packages/client/src/promise/generated/client-error.ts)

/// Failure reason reported by `ClientError`.
// parity: client/src/promise/generated/client-error.ts#ClientErrorReason [status=implemented hash=0fa449cfaf3f]
public enum ClientErrorReason: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case transport = "Transport"
    case unexpectedStatus = "UnexpectedStatus"
    case unsupportedContentType = "UnsupportedContentType"
    case malformedResponse = "MalformedResponse"
    case sseEventTooLarge = "SseEventTooLarge"
}

/// Transport, framing, content-type, or status error raised by the OpenCode HTTP/SSE client.
// parity: client/src/promise/generated/client-error.ts#ClientError [status=implemented hash=7410dd802a4b]
public struct ClientError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let name = "ClientError"
    public let reason: ClientErrorReason
    public let detail: String?
    public let statusCode: Int?
    public let causeDescription: String?

    public init(
        reason: ClientErrorReason,
        detail: String? = nil,
        statusCode: Int? = nil,
        causeDescription: String? = nil
    ) {
        self.reason = reason
        self.detail = detail
        self.statusCode = statusCode
        self.causeDescription = causeDescription
    }

    public var message: String {
        let resolvedDetail = detail ?? causeDescription
        if let resolvedDetail, !resolvedDetail.isEmpty {
            return "\(reason.rawValue): \(resolvedDetail)"
        }
        return reason.rawValue
    }

    public var description: String { message }
}

// MARK: - Client Options & Request Options (packages/client/src/promise/generated/client.ts)

/// Configuration for constructing an `OpenCodeClient` backed by `OpenCodePlatform.HTTPTransport`.
// parity: client/src/promise/generated/client.ts#ClientOptions [status=implemented hash=12e1d6e2aaa5]
public struct ClientOptions: Sendable {
    public let baseUrl: String
    public let transport: any HTTPTransport
    public let headers: [String: String]

    public init(
        baseUrl: String,
        transport: any HTTPTransport,
        headers: [String: String] = [:]
    ) {
        self.baseUrl = baseUrl
        self.transport = transport
        self.headers = headers
    }
}

/// Per-request options (cancellation signal, extra headers, streaming activity callback, and media ref toggle).
// parity: client/src/promise/generated/client.ts#RequestOptions [status=implemented hash=169fc019a535]
public struct RequestOptions: Sendable {
    public let signal: AbortSignal?
    public let headers: [String: String]?
    /// Reports every chunk a streaming response receives, including keepalive comments that yield no event.
    public let onActivity: (@Sendable () -> Void)?
    /// When set to `false` on a `withMediaRefs`-wrapped client, reads stored media inline instead of `media:<hash>` refs.
    public let mediaRefs: Bool?

    public init(
        signal: AbortSignal? = nil,
        headers: [String: String]? = nil,
        onActivity: (@Sendable () -> Void)? = nil,
        mediaRefs: Bool? = nil
    ) {
        self.signal = signal
        self.headers = headers
        self.onActivity = onActivity
        self.mediaRefs = mediaRefs
    }
}

// MARK: - Media Refs (packages/client/src/promise/media.ts)

private let mediaUriCapabilityValue = "experimental-media-uri"
private let capabilitiesHeaderName = "X-OpenCode-Capabilities"

/// `mediaRefs: false` reads stored media as inline bytes, for callers such as export that need self-contained messages.
// parity: client/src/promise/media.ts#MediaRequestOptions [status=implemented hash=12bcf5579823]
public typealias MediaRequestOptions = RequestOptions

/// The blob hash in a `media:<hash>` ref, the only form the server sends stored media in.
// parity: client/src/promise/media.ts#mediaHashFromUri [status=implemented hash=c61408bf5fbe]
public func mediaHashFromUri(_ uri: String?) -> String? {
    guard let uri, uri.hasPrefix("media:") else { return nil }
    let hash = uri.dropFirst("media:".count)
    let bytes = Array(hash.utf8)
    guard bytes.count == 64 else { return nil }
    for b in bytes {
        let isHex = (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66)
        if !isHex { return nil }
    }
    return String(hash)
}

internal func applyMediaRefOptions(_ options: MediaRequestOptions?, enabled: Bool) -> RequestOptions? {
    guard enabled, options?.mediaRefs != false else { return options }
    let merged = ClientHTTPHeaders.merge(options?.headers, [capabilitiesHeaderName: mediaUriCapabilityValue])
    return RequestOptions(
        signal: options?.signal,
        headers: merged,
        onActivity: options?.onActivity,
        mediaRefs: options?.mediaRefs
    )
}

/// Opts a client into the experimental `experimental-media-uri` capability on `message.list`,
/// `session.message.get`, and `session.inbox.list` only.
// parity: client/src/promise/media.ts#withMediaRefs [status=implemented hash=6045ca9ed442]
public func withMediaRefs(_ api: OpenCodeClient) -> OpenCodeClient {
    api.withMediaRefsEnabled()
}

// MARK: - Core HTTP/SSE Executor

public struct ClientRequestDescriptor: Sendable {
    public let method: String
    public let path: String
    public let query: [(String, JSONValue?)]
    public let headers: [String: String]
    public let body: JSONValue?
    public let binaryBody: [UInt8]?
    public let successStatus: Int
    public let declaredStatuses: [Int]
    public let empty: Bool
    public let binary: Bool

    public init(
        method: String,
        path: String,
        query: [(String, JSONValue?)] = [],
        headers: [String: String] = [:],
        body: JSONValue? = nil,
        binaryBody: [UInt8]? = nil,
        successStatus: Int = 200,
        declaredStatuses: [Int] = [],
        empty: Bool = false,
        binary: Bool = false
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.binaryBody = binaryBody
        self.successStatus = successStatus
        self.declaredStatuses = declaredStatuses
        self.empty = empty
        self.binary = binary
    }
}

public struct ClientDataEnvelope<DataValue: Equatable & Hashable & Sendable & Codable>: Equatable, Hashable, Sendable, Codable {
    public let data: DataValue

    public init(data: DataValue) {
        self.data = data
    }
}

public struct ClientHTTPExecutor: Sendable {
    public let options: ClientOptions

    public init(options: ClientOptions) {
        self.options = options
    }

    public func prepare(
        _ descriptor: ClientRequestDescriptor,
        requestOptions: RequestOptions? = nil
    ) throws -> HTTPRequest {
        let url = ClientURLBuilder.join(
            baseUrl: options.baseUrl,
            path: descriptor.path,
            query: descriptor.query
        )
        var mergedHeaders = ClientHTTPHeaders.merge(options.headers, descriptor.headers, requestOptions?.headers)
        let bodyBytes: [UInt8]?
        if let binaryBody = descriptor.binaryBody {
            if ClientHTTPHeaders.value(in: mergedHeaders, for: "content-type") == nil {
                mergedHeaders["content-type"] = "application/octet-stream"
            }
            bodyBytes = binaryBody
        } else if let jsonBody = descriptor.body {
            if ClientHTTPHeaders.value(in: mergedHeaders, for: "content-type") == nil {
                mergedHeaders["content-type"] = "application/json"
            }
            do {
                bodyBytes = try ClientCodec.encode(jsonBody)
            } catch {
                throw ClientError(reason: .transport, causeDescription: String(describing: error))
            }
        } else {
            bodyBytes = nil
        }
        return HTTPRequest(
            method: descriptor.method,
            url: url,
            headers: mergedHeaders,
            body: bodyBytes
        )
    }

    public func execute(
        _ descriptor: ClientRequestDescriptor,
        requestOptions: RequestOptions? = nil
    ) async throws -> HTTPResponse {
        if let signal = requestOptions?.signal, signal.isAborted {
            let desc = signal.reason.map { String(describing: $0) } ?? "Aborted"
            throw ClientError(reason: .transport, causeDescription: desc)
        }
        let prepared = try prepare(descriptor, requestOptions: requestOptions)
        do {
            let response = try await options.transport.send(prepared)
            if let signal = requestOptions?.signal, signal.isAborted {
                let desc = signal.reason.map { String(describing: $0) } ?? "Aborted"
                throw ClientError(reason: .transport, causeDescription: desc)
            }
            return response
        } catch let err as ClientError {
            throw err
        } catch {
            throw ClientError(reason: .transport, causeDescription: String(describing: error))
        }
    }

    private static func unsupportedContentTypeDetail(for response: HTTPResponse) -> String {
        let contentType = ClientHTTPHeaders.value(in: response.head.headers, for: "content-type") ?? "<none>"
        if let snippet = bodySnippet(response.body) {
            return "status \(response.head.statusCode), content-type: \(contentType), body: \(snippet)"
        }
        return "status \(response.head.statusCode), content-type: \(contentType)"
    }

    private static func bodySnippet(_ bytes: [UInt8], maxLength: Int = 200) -> String? {
        guard !bytes.isEmpty else { return nil }
        let raw = String(decoding: bytes.prefix(maxLength * 4), as: UTF8.self)
        let collapsed = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maxLength {
            return collapsed
        }
        return String(collapsed.prefix(maxLength)) + "…"
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        guard ClientHTTPHeaders.isJSONContentType(response.head.headers) else {
            let contentType = ClientHTTPHeaders.value(in: response.head.headers, for: "content-type")
            throw ClientError(
                reason: .unsupportedContentType,
                detail: contentType ?? Self.unsupportedContentTypeDetail(for: response),
                statusCode: response.head.statusCode
            )
        }
        guard !response.body.isEmpty else {
            throw ClientError(reason: .malformedResponse, statusCode: response.head.statusCode)
        }
        do {
            return try ClientCodec.decode(type, from: response.body)
        } catch {
            throw ClientError(
                reason: .malformedResponse,
                statusCode: response.head.statusCode,
                causeDescription: String(describing: error)
            )
        }
    }

    private func responseError(_ response: HTTPResponse, descriptor: ClientRequestDescriptor) throws -> Never {
        if descriptor.declaredStatuses.contains(response.head.statusCode) {
            guard ClientHTTPHeaders.isJSONContentType(response.head.headers) else {
                throw ClientError(
                    reason: .unsupportedContentType,
                    detail: Self.unsupportedContentTypeDetail(for: response),
                    statusCode: response.head.statusCode
                )
            }
            let decoded = try ClientDeclaredErrorDecoder.decode(bytes: response.body)
            throw decoded
        }
        throw ClientError(
            reason: .unexpectedStatus,
            detail: String(response.head.statusCode),
            statusCode: response.head.statusCode
        )
    }

    public func request<Output: Decodable & Sendable>(
        _ descriptor: ClientRequestDescriptor,
        requestOptions: RequestOptions? = nil
    ) async throws -> Output {
        let response = try await execute(descriptor, requestOptions: requestOptions)
        guard response.head.statusCode == descriptor.successStatus else {
            try responseError(response, descriptor: descriptor)
        }
        return try decodeJSON(Output.self, from: response)
    }

    public func requestData<Output: Equatable & Hashable & Sendable & Codable>(
        _ descriptor: ClientRequestDescriptor,
        requestOptions: RequestOptions? = nil
    ) async throws -> Output {
        let envelope: ClientDataEnvelope<Output> = try await request(descriptor, requestOptions: requestOptions)
        return envelope.data
    }

    public func requestEmpty(
        _ descriptor: ClientRequestDescriptor,
        requestOptions: RequestOptions? = nil
    ) async throws {
        let response = try await execute(descriptor, requestOptions: requestOptions)
        guard response.head.statusCode == descriptor.successStatus else {
            try responseError(response, descriptor: descriptor)
        }
    }

    public func requestBinary(
        _ descriptor: ClientRequestDescriptor,
        requestOptions: RequestOptions? = nil
    ) async throws -> [UInt8] {
        let response = try await execute(descriptor, requestOptions: requestOptions)
        guard response.head.statusCode == descriptor.successStatus else {
            try responseError(response, descriptor: descriptor)
        }
        return response.body
    }

    public func sse<Event: Decodable & Sendable>(
        _ descriptor: ClientRequestDescriptor,
        requestOptions: RequestOptions? = nil
    ) -> AsyncThrowingStream<Event, any Error> {
        let executor = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let signal = requestOptions?.signal, signal.isAborted {
                    let desc = signal.reason.map { String(describing: $0) } ?? "Aborted"
                    continuation.finish(throwing: ClientError(reason: .transport, causeDescription: desc))
                    return
                }
                let prepared: HTTPRequest
                do {
                    prepared = try executor.prepare(descriptor, requestOptions: requestOptions)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let streaming: HTTPStreamingResponse
                do {
                    streaming = try await executor.options.transport.stream(prepared)
                } catch {
                    continuation.finish(throwing: ClientError(reason: .transport, causeDescription: String(describing: error)))
                    return
                }

                if streaming.head.statusCode != descriptor.successStatus {
                    var errorBody: [UInt8] = []
                    do {
                        for try await chunk in streaming.chunks {
                            errorBody.append(contentsOf: chunk)
                        }
                    } catch {}
                    let fakeResponse = HTTPResponse(head: streaming.head, body: errorBody)
                    do {
                        try executor.responseError(fakeResponse, descriptor: descriptor)
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }

                guard ClientHTTPHeaders.isContentType(streaming.head.headers, expected: "text/event-stream") else {
                    let contentType = ClientHTTPHeaders.value(in: streaming.head.headers, for: "content-type")
                    let detail = contentType ?? "status \(streaming.head.statusCode), content-type: <none>"
                    continuation.finish(
                        throwing: ClientError(
                            reason: .unsupportedContentType,
                            detail: detail,
                            statusCode: streaming.head.statusCode
                        )
                    )
                    return
                }

                var parser = ClientSSEParser()
                do {
                    for try await chunk in streaming.chunks {
                        if Task.isCancelled || (requestOptions?.signal?.isAborted ?? false) {
                            continuation.finish()
                            return
                        }
                        requestOptions?.onActivity?()
                        let payloads = try parser.feed(chunk, isFinal: false)
                        for payload in payloads {
                            do {
                                let event = try ClientCodec.decode(Event.self, from: payload)
                                continuation.yield(event)
                            } catch {
                                throw ClientError(reason: .malformedResponse, causeDescription: String(describing: error))
                            }
                        }
                    }
                    let trailing = try parser.feed([], isFinal: true)
                    for payload in trailing {
                        do {
                            let event = try ClientCodec.decode(Event.self, from: payload)
                            continuation.yield(event)
                        } catch {
                            throw ClientError(reason: .malformedResponse, causeDescription: String(describing: error))
                        }
                    }
                    continuation.finish()
                } catch let err as ClientError {
                    continuation.finish(throwing: err)
                } catch {
                    continuation.finish(throwing: ClientError(reason: .transport, causeDescription: String(describing: error)))
                }
            }

            let abortCleanup = requestOptions?.signal?.onAbort {
                task.cancel()
            }

            continuation.onTermination = { _ in
                abortCleanup?()
                task.cancel()
            }
        }
    }

    /// Invokes any `OpenCodeProtocol.EndpointDescriptor` dynamically against `OpenCodePlatform.HTTPTransport`.
    public func invoke(
        endpoint: EndpointDescriptor,
        pathParams: [String: String] = [:],
        query: [(String, JSONValue?)] = [],
        headers: [String: String] = [:],
        body: JSONValue? = nil,
        binaryBody: [UInt8]? = nil,
        requestOptions: RequestOptions? = nil
    ) async throws -> HTTPResponse {
        let segments = endpoint.path.split(separator: "/", omittingEmptySubsequences: false).map { seg -> String in
            if seg.hasPrefix(":") && seg.count > 1 {
                let key = String(seg.dropFirst())
                return ClientURLBuilder.encodeURIComponent(pathParams[key] ?? "")
            }
            if seg == "*" {
                return ClientURLBuilder.encodePath(pathParams["path"] ?? "")
            }
            return String(seg)
        }
        let resolvedPath = segments.joined(separator: "/")
        let declared = Array(Set(endpoint.errors.map(\.httpStatusCode))).sorted()
        let descriptor = ClientRequestDescriptor(
            method: endpoint.method.rawValue,
            path: resolvedPath,
            query: query,
            headers: headers,
            body: body,
            binaryBody: binaryBody,
            successStatus: endpoint.successStatusCode,
            declaredStatuses: declared,
            empty: endpoint.successEncoding == .noContent,
            binary: endpoint.successEncoding == .binary
        )
        let response = try await execute(descriptor, requestOptions: requestOptions)
        guard response.head.statusCode == descriptor.successStatus else {
            try responseError(response, descriptor: descriptor)
        }
        return response
    }
}

internal func encodeBodyFields(_ pairs: [(String, JSONValue?)]) -> JSONValue {
    var dict: [String: JSONValue] = [:]
    for (k, v) in pairs {
        if let v { dict[k] = v }
    }
    return .object(dict)
}

internal func encodeOptionalJSON<T: Encodable>(_ value: T?) -> JSONValue? {
    guard let value else { return nil }
    return try? ClientCodec.toJSONValue(value)
}

internal func encodeJSON<T: Encodable>(_ value: T) -> JSONValue {
    (try? ClientCodec.toJSONValue(value)) ?? .null
}

// MARK: - Dedicated Client Response Models

public struct SessionActiveInfo: Equatable, Hashable, Sendable, Codable {
    public let type: String

    public init(type: String = "running") {
        self.type = type
    }
}

public struct SessionsCursorPage: Equatable, Hashable, Sendable, Codable {
    public let previous: SessionsCursor?
    public let next: SessionsCursor?

    public init(previous: SessionsCursor? = nil, next: SessionsCursor? = nil) {
        self.previous = previous
        self.next = next
    }
}

public struct MessagesCursorPage: Equatable, Hashable, Sendable, Codable {
    public let previous: String?
    public let next: String?

    public init(previous: String? = nil, next: String? = nil) {
        self.previous = previous
        self.next = next
    }
}

// parity: client/src/promise/generated/types.ts#SessionsResponse [status=implemented hash=c76275c41e98]
public struct SessionsResponse: Equatable, Hashable, Sendable, Codable {
    public let data: [SessionSchema.Info]
    public let cursor: SessionsCursorPage

    public init(data: [SessionSchema.Info], cursor: SessionsCursorPage = SessionsCursorPage()) {
        self.data = data
        self.cursor = cursor
    }
}

// parity: client/src/promise/generated/types.ts#SessionMessagesResponse [status=implemented hash=d3c04e2fcbb1]
public struct SessionMessagesResponse: Equatable, Hashable, Sendable, Codable {
    public let data: [SessionMessageSchema.Info]
    public let cursor: MessagesCursorPage

    public init(data: [SessionMessageSchema.Info], cursor: MessagesCursorPage = MessagesCursorPage()) {
        self.data = data
        self.cursor = cursor
    }
}

// parity: client/src/promise/generated/types.ts#SessionInterruptResponse [status=implemented hash=83896f9ce78f]
public struct SessionInterruptResponse: Equatable, Hashable, Sendable, Codable {
    public let interrupted: Bool

    public init(interrupted: Bool) {
        self.interrupted = interrupted
    }
}

public struct SessionGenerateData: Equatable, Hashable, Sendable, Codable {
    public let text: String
    public let tokens: TokenUsageSchema.Info
    public let cost: MoneySchema.USD

    public init(text: String, tokens: TokenUsageSchema.Info, cost: MoneySchema.USD) {
        self.text = text
        self.tokens = tokens
        self.cost = cost
    }
}

public struct GenerateTextData: Equatable, Hashable, Sendable, Codable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct VoiceModelsData: Equatable, Hashable, Sendable, Codable {
    public let models: [VoiceModel]
    public let defaultModel: String?

    public init(models: [VoiceModel], defaultModel: String? = nil) {
        self.models = models
        self.defaultModel = defaultModel
    }

    private enum CodingKeys: String, CodingKey {
        case models
        case defaultModel = "default"
    }
}

public struct VoiceSessionData: Equatable, Hashable, Sendable, Codable {
    public let transport: VoiceTransport

    public init(transport: VoiceTransport) {
        self.transport = transport
    }
}

public struct PermissionCreateData: Equatable, Hashable, Sendable, Codable {
    public let id: PermissionSchema.ID
    public let effect: PermissionSchema.Effect

    public init(id: PermissionSchema.ID, effect: PermissionSchema.Effect) {
        self.id = id
        self.effect = effect
    }
}

public struct PersistentPtyHandoffResponse: Equatable, Hashable, Sendable, Codable {
    public let handoff: PersistentPtySchema.Handoff?

    public init(handoff: PersistentPtySchema.Handoff? = nil) {
        self.handoff = handoff
    }
}

public struct HeapDumpMemoryUsage: Equatable, Hashable, Sendable, Codable {
    public let rss: Double
    public let heapTotal: Double
    public let heapUsed: Double
    public let external: Double
    public let arrayBuffers: Double

    public init(rss: Double, heapTotal: Double, heapUsed: Double, external: Double, arrayBuffers: Double) {
        self.rss = rss
        self.heapTotal = heapTotal
        self.heapUsed = heapUsed
        self.external = external
        self.arrayBuffers = arrayBuffers
    }
}

// parity: client/src/promise/generated/types.ts#DebugHeapDumpOutput [status=implemented hash=d4943e8c1a0c]
public struct DebugHeapDumpOutput: Equatable, Hashable, Sendable, Codable {
    public let path: String
    public let pid: Int
    public let memory: HeapDumpMemoryUsage

    public init(path: String, pid: Int, memory: HeapDumpMemoryUsage) {
        self.path = path
        self.pid = pid
        self.memory = memory
    }
}

// parity: client/src/promise/generated/types.ts#SessionLogItem [status=implemented hash=96bf062c74cb]
public enum SessionLogItem: Equatable, Hashable, Sendable, Codable {
    case event(OpenCodeEvent)
    case synced(EventLogSchema.Synced)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        if type == EventLogSchema.Synced.typeTag {
            self = .synced(try EventLogSchema.Synced(from: decoder))
        } else {
            self = .event(try OpenCodeEvent(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .event(let e): try e.encode(to: encoder)
        case .synced(let s): try s.encode(to: encoder)
        }
    }
}

// MARK: - Protocol Error Type Guards (43 guards from packages/client/src/promise/generated/types.ts)

// parity: client/src/promise/generated/types.ts#isInvalidRequestError [status=implemented hash=eca51513f3db]
public func isInvalidRequestError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.InvalidRequestError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .invalidRequest = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.InvalidRequestError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isUnauthorizedError [status=implemented hash=77330a6ab3a3]
public func isUnauthorizedError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.UnauthorizedError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .unauthorized = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.UnauthorizedError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isLocationNotFoundError [status=implemented hash=9674e762b141]
public func isLocationNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.LocationNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .locationNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.LocationNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isServiceUnavailableError [status=implemented hash=419d30d22699]
public func isServiceUnavailableError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.ServiceUnavailableError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .serviceUnavailable = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.ServiceUnavailableError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isAgentNotFoundError [status=implemented hash=e426f18294ac]
public func isAgentNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.AgentNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .agentNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.AgentNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isPluginNotFoundError [status=implemented hash=a090f99e5ea4]
public func isPluginNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.PluginNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .pluginNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.PluginNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isInvalidCursorError [status=implemented hash=5de5c387577b]
public func isInvalidCursorError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.InvalidCursorError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .invalidCursor = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.InvalidCursorError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isSessionNotFoundError [status=implemented hash=144df3494a70]
public func isSessionNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.SessionNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .sessionNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.SessionNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isMessageNotFoundError [status=implemented hash=faf2e45b6b69]
public func isMessageNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.MessageNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .messageNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.MessageNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isConflictError [status=implemented hash=6763fb3023fb]
public func isConflictError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.ConflictError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .conflict = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.ConflictError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isCommandNotFoundError [status=implemented hash=008a6f9e7a1c]
public func isCommandNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.CommandNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .commandNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.CommandNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isCommandExecutionError [status=implemented hash=4e04f7eeae2e]
public func isCommandExecutionError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.CommandExecutionError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .commandExecution = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.CommandExecutionError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isSessionBusyError [status=implemented hash=fffeebecc6a8]
public func isSessionBusyError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.SessionBusyError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .sessionBusy = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.SessionBusyError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isUnknownError [status=implemented hash=679e70e21234]
public func isUnknownError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.UnknownError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .unknown = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.UnknownError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isFormNotFoundError [status=implemented hash=0d5bff7150c1]
public func isFormNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.FormNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .formNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.FormNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isFormInvalidAnswerError [status=implemented hash=28417aa068dc]
public func isFormInvalidAnswerError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.FormInvalidAnswerError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .formInvalidAnswer = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.FormInvalidAnswerError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isFormAlreadySettledError [status=implemented hash=8ce3903fa6aa]
public func isFormAlreadySettledError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.FormAlreadySettledError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .formAlreadySettled = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.FormAlreadySettledError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isSkillNotFoundError [status=implemented hash=5a9273271f62]
public func isSkillNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.SkillNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .skillNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.SkillNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isInstructionEntryValueTooLargeError [status=implemented hash=96b6e89e9d83]
public func isInstructionEntryValueTooLargeError(_ error: any Error) -> Bool {
    if error is InstructionEntrySchema.ValueTooLargeError { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == InstructionEntrySchema.ValueTooLargeError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isProviderNotFoundError [status=implemented hash=a0fdba712b20]
public func isProviderNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.ProviderNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .providerNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.ProviderNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isModelNotFoundError [status=implemented hash=c88a6ef64198]
public func isModelNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.ModelNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .modelNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.ModelNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isUnsupportedModelError [status=implemented hash=348e2e0a74cf]
public func isUnsupportedModelError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.UnsupportedModelError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .unsupportedModel = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.UnsupportedModelError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isProviderRequestError [status=implemented hash=219bd1e655d9]
public func isProviderRequestError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.ProviderRequestError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .providerRequest = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.ProviderRequestError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isForbiddenError [status=implemented hash=8422fd79f523]
public func isForbiddenError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.ForbiddenError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .forbidden = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.ForbiddenError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isVideoNotFoundError [status=implemented hash=8631227bbc86]
public func isVideoNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.VideoNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .videoNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.VideoNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isIntegrationNotFoundError [status=implemented hash=243ae2949ce5]
public func isIntegrationNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.IntegrationNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .integrationNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.IntegrationNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isIntegrationAttemptNotFoundError [status=implemented hash=ea3b56333a62]
public func isIntegrationAttemptNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.IntegrationAttemptNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .integrationAttemptNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.IntegrationAttemptNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isIntegrationMethodNotFoundError [status=implemented hash=5a607fba5f4b]
public func isIntegrationMethodNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.IntegrationMethodNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .integrationMethodNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.IntegrationMethodNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isMcpServerNotFoundError [status=implemented hash=662675aa0087]
public func isMcpServerNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.McpServerNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .mcpServerNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.McpServerNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isProjectNotFoundError [status=implemented hash=bd16eab23e51]
public func isProjectNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.ProjectNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .projectNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.ProjectNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isPermissionSavedNotFoundError [status=implemented hash=89d8f29a3aa4]
public func isPermissionSavedNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.PermissionSavedNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .permissionSavedNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.PermissionSavedNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isPermissionNotFoundError [status=implemented hash=5f676559d666]
public func isPermissionNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.PermissionNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .permissionNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.PermissionNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isFileNotFoundError [status=implemented hash=4774cd5a57c6]
public func isFileNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.FileNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .fileNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.FileNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isRpcError [status=implemented hash=07ee6bfd1223]
public func isRpcError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.RpcError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .rpc = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.RpcError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isRpcInternalError [status=implemented hash=9019ca92aae8]
public func isRpcInternalError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.RpcInternalError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .rpcInternal = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.RpcInternalError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isPtyNotFoundError [status=implemented hash=1bffc8a30f11]
public func isPtyNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.PtyNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .ptyNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.PtyNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isPtyFeatureUnsupportedError [status=implemented hash=2b92ca5d0f38]
public func isPtyFeatureUnsupportedError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.PtyFeatureUnsupportedError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .ptyFeatureUnsupported = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.PtyFeatureUnsupportedError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isBlobNotFoundError [status=implemented hash=2f62023b827e]
public func isBlobNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.BlobNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .blobNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.BlobNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isAutomationNotFoundError [status=implemented hash=cf5fd2c378b0]
public func isAutomationNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.AutomationNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .automationNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.AutomationNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isArtifactNotFoundError [status=implemented hash=49eebe6e3086]
public func isArtifactNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.ArtifactNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .artifactNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.ArtifactNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isShellNotFoundError [status=implemented hash=2208cb1d0c13]
public func isShellNotFoundError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.ShellNotFoundError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .shellNotFound = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.ShellNotFoundError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isWorktreeError [status=implemented hash=1ae71e9b570c]
public func isWorktreeError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.WorktreeError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .worktree = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.WorktreeError.tag { return true }
    return false
}

// parity: client/src/promise/generated/types.ts#isVcsInitNotSupportedError [status=implemented hash=c3d8c982653b]
public func isVcsInitNotSupportedError(_ error: any Error) -> Bool {
    if error is OpenCodeProtocol.VcsInitNotSupportedError { return true }
    if let envelope = error as? ProtocolErrorEnvelope, case .vcsInitNotSupported = envelope { return true }
    if let declared = error as? DeclaredAPIError, declared.tag == OpenCodeProtocol.VcsInitNotSupportedError.tag { return true }
    return false
}

/// Extracts a `SessionNotFoundError` whether thrown directly or inside `ProtocolErrorEnvelope`.
public func extractSessionNotFoundError(_ error: any Error) -> OpenCodeProtocol.SessionNotFoundError? {
    if let direct = error as? OpenCodeProtocol.SessionNotFoundError { return direct }
    if let envelope = error as? ProtocolErrorEnvelope, case .sessionNotFound(let e) = envelope { return e }
    return nil
}

/// Extracts a `FormNotFoundError` whether thrown directly or inside `ProtocolErrorEnvelope`.
public func extractFormNotFoundError(_ error: any Error) -> OpenCodeProtocol.FormNotFoundError? {
    if let direct = error as? OpenCodeProtocol.FormNotFoundError { return direct }
    if let envelope = error as? ProtocolErrorEnvelope, case .formNotFound(let e) = envelope { return e }
    return nil
}

/// Extracts a `FormAlreadySettledError` whether thrown directly or inside `ProtocolErrorEnvelope`.
public func extractFormAlreadySettledError(_ error: any Error) -> OpenCodeProtocol.FormAlreadySettledError? {
    if let direct = error as? OpenCodeProtocol.FormAlreadySettledError { return direct }
    if let envelope = error as? ProtocolErrorEnvelope, case .formAlreadySettled(let e) = envelope { return e }
    return nil
}


// MARK: - Typed Endpoint Input Models (packages/client/src/promise/generated/types.ts)

public enum PromiseInputTypes {
    public struct ServerConnectInput: Equatable, Hashable, Sendable {
        public let code: String
        public init(code: String) {
            self.code = code
        }
    }

    public struct LocationGetInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct AgentListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct AgentGetInput: Equatable, Hashable, Sendable {
        public let agentID: String
        public let location: LocationQuery.LocationField?
        public init(agentID: String, location: LocationQuery.LocationField? = nil) {
            self.agentID = agentID
            self.location = location
        }
    }

    public struct PluginListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct PluginGuiInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let id: String
        public init(location: LocationQuery.LocationField? = nil, id: String) {
            self.location = location
            self.id = id
        }
    }

    public struct PluginCheckInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let target: String?
        public init(location: LocationQuery.LocationField? = nil, target: String? = nil) {
            self.location = location
            self.target = target
        }
    }

    public struct PluginUpdateInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let targets: [String]
        public init(location: LocationQuery.LocationField? = nil, targets: [String]) {
            self.location = location
            self.targets = targets
        }
    }

    public struct SessionListInput: Equatable, Hashable, Sendable {
        public let limit: Int?
        public let order: ProtocolSortOrder?
        public let search: String?
        public let parentID: String?
        public let archived: Bool?
        public let directory: String?
        public let project: String?
        public let subpath: String?
        public let cursor: String?
        public init(
            limit: Int? = nil,
            order: ProtocolSortOrder? = nil,
            search: String? = nil,
            parentID: String? = nil,
            archived: Bool? = nil,
            directory: String? = nil,
            project: String? = nil,
            subpath: String? = nil,
            cursor: String? = nil
        ) {
            self.limit = limit
            self.order = order
            self.search = search
            self.parentID = parentID
            self.archived = archived
            self.directory = directory
            self.project = project
            self.subpath = subpath
            self.cursor = cursor
        }
    }

    public struct SessionCreateInput: Equatable, Hashable, Sendable {
        public let id: String?
        public let parentID: String?
        public let title: String?
        public let agent: String?
        public let model: ModelSchema.Ref?
        public let location: LocationSchema.PublicRef?
        public let metadata: [String: JSONValue]?
        public let permissions: PermissionSchema.Ruleset?
        public init(
            id: String? = nil,
            parentID: String? = nil,
            title: String? = nil,
            agent: String? = nil,
            model: ModelSchema.Ref? = nil,
            location: LocationSchema.PublicRef? = nil,
            metadata: [String: JSONValue]? = nil,
            permissions: PermissionSchema.Ruleset? = nil
        ) {
            self.id = id
            self.parentID = parentID
            self.title = title
            self.agent = agent
            self.model = model
            self.location = location
            self.metadata = metadata
            self.permissions = permissions
        }
    }

    public struct SessionGetInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public struct SessionRemoveInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public struct SessionForkInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let before: String?
        public init(sessionID: String, before: String? = nil) {
            self.sessionID = sessionID
            self.before = before
        }
    }

    public struct SessionSwitchAgentInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let agent: String
        public init(sessionID: String, agent: String) {
            self.sessionID = sessionID
            self.agent = agent
        }
    }

    public struct SessionSwitchModelInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let model: ModelSchema.Ref
        public init(sessionID: String, model: ModelSchema.Ref) {
            self.sessionID = sessionID
            self.model = model
        }
    }

    public struct SessionUpdateInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let title: String?
        public let metadata: [String: JSONValue]?
        public let permissions: PermissionSchema.Ruleset?
        public let archived: Bool?
        public init(
            sessionID: String,
            title: String? = nil,
            metadata: [String: JSONValue]? = nil,
            permissions: PermissionSchema.Ruleset? = nil,
            archived: Bool? = nil
        ) {
            self.sessionID = sessionID
            self.title = title
            self.metadata = metadata
            self.permissions = permissions
            self.archived = archived
        }
    }

    public struct SessionMoveInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let directory: String
        public let delivery: SessionInboxSchema.Delivery?
        public init(
            sessionID: String,
            directory: String,
            delivery: SessionInboxSchema.Delivery? = nil
        ) {
            self.sessionID = sessionID
            self.directory = directory
            self.delivery = delivery
        }
    }

    public struct SessionPromptInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let id: String?
        public let text: String
        public let files: [PromptInputSchema.FileAttachment]?
        public let agents: [PromptSchema.AgentAttachment]?
        public let skills: [PromptInputSchema.SkillAttachment]?
        public let metadata: [String: JSONValue]?
        public let delivery: SessionInboxSchema.Delivery?
        public let resume: Bool?
        public init(
            sessionID: String,
            id: String? = nil,
            text: String,
            files: [PromptInputSchema.FileAttachment]? = nil,
            agents: [PromptSchema.AgentAttachment]? = nil,
            skills: [PromptInputSchema.SkillAttachment]? = nil,
            metadata: [String: JSONValue]? = nil,
            delivery: SessionInboxSchema.Delivery? = nil,
            resume: Bool? = nil
        ) {
            self.sessionID = sessionID
            self.id = id
            self.text = text
            self.files = files
            self.agents = agents
            self.skills = skills
            self.metadata = metadata
            self.delivery = delivery
            self.resume = resume
        }
    }

    public struct SessionCommandInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let name: String
        public let text: String
        public let files: [PromptInputSchema.FileAttachment]?
        public let agents: [PromptSchema.AgentAttachment]?
        public let skills: [PromptInputSchema.SkillAttachment]?
        public let delivery: SessionInboxSchema.Delivery?
        public init(
            sessionID: String,
            name: String,
            text: String,
            files: [PromptInputSchema.FileAttachment]? = nil,
            agents: [PromptSchema.AgentAttachment]? = nil,
            skills: [PromptInputSchema.SkillAttachment]? = nil,
            delivery: SessionInboxSchema.Delivery? = nil
        ) {
            self.sessionID = sessionID
            self.name = name
            self.text = text
            self.files = files
            self.agents = agents
            self.skills = skills
            self.delivery = delivery
        }
    }

    public struct SessionSyntheticInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let id: String?
        public let text: String
        public let description: String?
        public let metadata: [String: JSONValue]?
        public let delivery: SessionInboxSchema.Delivery?
        public let resume: Bool?
        public init(
            sessionID: String,
            id: String? = nil,
            text: String,
            description: String? = nil,
            metadata: [String: JSONValue]? = nil,
            delivery: SessionInboxSchema.Delivery? = nil,
            resume: Bool? = nil
        ) {
            self.sessionID = sessionID
            self.id = id
            self.text = text
            self.description = description
            self.metadata = metadata
            self.delivery = delivery
            self.resume = resume
        }
    }

    public struct SessionShellInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let id: String?
        public let command: String
        public init(
            sessionID: String,
            id: String? = nil,
            command: String
        ) {
            self.sessionID = sessionID
            self.id = id
            self.command = command
        }
    }

    public struct SessionCompactInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let id: String?
        public let delivery: SessionInboxSchema.Delivery?
        public init(
            sessionID: String,
            id: String? = nil,
            delivery: SessionInboxSchema.Delivery? = nil
        ) {
            self.sessionID = sessionID
            self.id = id
            self.delivery = delivery
        }
    }

    public struct SessionRevertStageInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let messageID: String
        public let files: Bool?
        public init(
            sessionID: String,
            messageID: String,
            files: Bool? = nil
        ) {
            self.sessionID = sessionID
            self.messageID = messageID
            self.files = files
        }
    }

    public struct SessionRevertClearInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public struct SessionRevertCommitInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public struct SessionContextInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public struct SessionDiffInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let from: String?
        public let to: String?
        public let context: Double?
        public init(
            sessionID: String,
            from: String? = nil,
            to: String? = nil,
            context: Double? = nil
        ) {
            self.sessionID = sessionID
            self.from = from
            self.to = to
            self.context = context
        }
    }

    public struct SessionInboxListInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public struct SessionInboxCancelInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let inboxID: String
        public init(sessionID: String, inboxID: String) {
            self.sessionID = sessionID
            self.inboxID = inboxID
        }
    }

    public struct SessionInboxUpdateInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let inboxID: String
        public let delivery: SessionInboxSchema.Delivery
        public init(
            sessionID: String,
            inboxID: String,
            delivery: SessionInboxSchema.Delivery
        ) {
            self.sessionID = sessionID
            self.inboxID = inboxID
            self.delivery = delivery
        }
    }

    public struct SessionGenerateInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let prompt: String
        public init(sessionID: String, prompt: String) {
            self.sessionID = sessionID
            self.prompt = prompt
        }
    }

    public struct SessionInterruptInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let resume: Bool?
        public init(sessionID: String, resume: Bool? = nil) {
            self.sessionID = sessionID
            self.resume = resume
        }
    }

    public struct SessionBackgroundInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public struct SessionMessageGetInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let messageID: String
        public init(sessionID: String, messageID: String) {
            self.sessionID = sessionID
            self.messageID = messageID
        }
    }

    public struct SessionFormListInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public struct SessionFormCreateInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let id: String?
        public let title: String
        public let metadata: [String: JSONValue]?
        public let fields: JSONValue
        public init(
            sessionID: String,
            id: String? = nil,
            title: String,
            metadata: [String: JSONValue]? = nil,
            fields: JSONValue
        ) {
            self.sessionID = sessionID
            self.id = id
            self.title = title
            self.metadata = metadata
            self.fields = fields
        }
    }

    public struct SessionFormGetInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let formID: String
        public init(sessionID: String, formID: String) {
            self.sessionID = sessionID
            self.formID = formID
        }
    }

    public struct SessionFormReplyInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let formID: String
        public let answer: FormSchema.Answer
        public init(
            sessionID: String,
            formID: String,
            answer: FormSchema.Answer
        ) {
            self.sessionID = sessionID
            self.formID = formID
            self.answer = answer
        }
    }

    public struct SessionFormCancelInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let formID: String
        public let message: String?
        public init(
            sessionID: String,
            formID: String,
            message: String? = nil
        ) {
            self.sessionID = sessionID
            self.formID = formID
            self.message = message
        }
    }

    public struct SessionEnvironmentInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let variables: [String: String]
        public init(sessionID: String, variables: [String: String]) {
            self.sessionID = sessionID
            self.variables = variables
        }
    }

    public struct SessionViewInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let idle: Int
        public init(sessionID: String, idle: Int) {
            self.sessionID = sessionID
            self.idle = idle
        }
    }

    public struct ExperimentalSessionStatsInput: Equatable, Hashable, Sendable {
        public let from: Double?
        public let to: Double?
        public let project: String?
        public let timezone: String?
        public let tools: String?
        public init(
            from: Double? = nil,
            to: Double? = nil,
            project: String? = nil,
            timezone: String? = nil,
            tools: String? = nil
        ) {
            self.from = from
            self.to = to
            self.project = project
            self.timezone = timezone
            self.tools = tools
        }
    }

    public struct ExperimentalSessionImportInput: Equatable, Hashable, Sendable {
        public let info: JSONValue
        public let messages: [JSONValue]
        public let location: LocationSchema.PublicRef?
        public init(
            info: JSONValue,
            messages: [JSONValue],
            location: LocationSchema.PublicRef? = nil
        ) {
            self.info = info
            self.messages = messages
            self.location = location
        }
    }

    public struct ExperimentalSessionExportInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let sanitize: Bool?
        public init(sessionID: String, sanitize: Bool? = nil) {
            self.sessionID = sessionID
            self.sanitize = sanitize
        }
    }

    public struct ExperimentalSessionSkillInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let id: String
        public let resume: Bool?
        public init(
            sessionID: String,
            id: String,
            resume: Bool? = nil
        ) {
            self.sessionID = sessionID
            self.id = id
            self.resume = resume
        }
    }

    public struct ExperimentalSessionWaitInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public struct ExperimentalSessionInstructionsEntryListInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public struct ExperimentalSessionInstructionsEntryPutInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let key: String
        public let value: JSONValue
        public init(
            sessionID: String,
            key: String,
            value: JSONValue
        ) {
            self.sessionID = sessionID
            self.key = key
            self.value = value
        }
    }

    public struct ExperimentalSessionInstructionsEntryRemoveInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let key: String
        public init(sessionID: String, key: String) {
            self.sessionID = sessionID
            self.key = key
        }
    }

    public struct ExperimentalSessionLogInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let after: Int?
        public let follow: Bool?
        public init(
            sessionID: String,
            after: Int? = nil,
            follow: Bool? = nil
        ) {
            self.sessionID = sessionID
            self.after = after
            self.follow = follow
        }
    }

    public struct MessageListInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let limit: Int?
        public let order: ProtocolSortOrder?
        public let cursor: String?
        public let `type`: SessionMessageType?
        public init(
            sessionID: String,
            limit: Int? = nil,
            order: ProtocolSortOrder? = nil,
            cursor: String? = nil,
            `type`: SessionMessageType? = nil
        ) {
            self.sessionID = sessionID
            self.limit = limit
            self.order = order
            self.cursor = cursor
            self.`type` = `type`
        }
    }

    public struct ModelListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let types: [String]?
        public init(location: LocationQuery.LocationField? = nil, types: [String]? = nil) {
            self.location = location
            self.types = types
        }
    }

    public struct ModelDefaultInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct ExperimentalGenerateTextInput: Equatable, Hashable, Sendable {
        public let prompt: String
        public let model: ModelSchema.Ref?
        public init(prompt: String, model: ModelSchema.Ref? = nil) {
            self.prompt = prompt
            self.model = model
        }
    }

    public struct ExperimentalGenerateImageInput: Equatable, Hashable, Sendable {
        public let model: ModelSchema.Ref
        public let prompt: String
        public let images: [JSONValue]?
        public let n: Int?
        public let aspect: JSONValue?
        public let resolution: JSONValue?
        public init(
            model: ModelSchema.Ref,
            prompt: String,
            images: [JSONValue]? = nil,
            n: Int? = nil,
            aspect: JSONValue? = nil,
            resolution: JSONValue? = nil
        ) {
            self.model = model
            self.prompt = prompt
            self.images = images
            self.n = n
            self.aspect = aspect
            self.resolution = resolution
        }
    }

    public struct ExperimentalGenerateVideoCreateInput: Equatable, Hashable, Sendable {
        public let model: ModelSchema.Ref
        public let prompt: String
        public let start: JSONValue?
        public let end: JSONValue?
        public let references: [JSONValue]?
        public let duration: Int?
        public let aspect: JSONValue?
        public let resolution: JSONValue?
        public let sound: Bool?
        public init(
            model: ModelSchema.Ref,
            prompt: String,
            start: JSONValue? = nil,
            end: JSONValue? = nil,
            references: [JSONValue]? = nil,
            duration: Int? = nil,
            aspect: JSONValue? = nil,
            resolution: JSONValue? = nil,
            sound: Bool? = nil
        ) {
            self.model = model
            self.prompt = prompt
            self.start = start
            self.end = end
            self.references = references
            self.duration = duration
            self.aspect = aspect
            self.resolution = resolution
            self.sound = sound
        }
    }

    public struct ExperimentalGenerateVideoGetInput: Equatable, Hashable, Sendable {
        public let id: String
        public init(id: String) {
            self.id = id
        }
    }

    public struct ExperimentalGenerateDecisionsInput: Equatable, Hashable, Sendable {
        public let model: ModelSchema.Ref
        public let input: [JSONValue]
        public let questions: [JSONValue]
        public init(
            model: ModelSchema.Ref,
            input: [JSONValue],
            questions: [JSONValue]
        ) {
            self.model = model
            self.input = input
            self.questions = questions
        }
    }

    public struct ExperimentalVoiceSessionInput: Equatable, Hashable, Sendable {
        public let model: String
        public let session: JSONValue?
        public let transport: VoiceTransportInput
        public init(
            model: String,
            session: JSONValue? = nil,
            transport: VoiceTransportInput
        ) {
            self.model = model
            self.session = session
            self.transport = transport
        }
    }

    public struct ProviderListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct ProviderGetInput: Equatable, Hashable, Sendable {
        public let providerID: String
        public let location: LocationQuery.LocationField?
        public init(providerID: String, location: LocationQuery.LocationField? = nil) {
            self.providerID = providerID
            self.location = location
        }
    }

    public struct IntegrationListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct IntegrationGetInput: Equatable, Hashable, Sendable {
        public let integrationID: String
        public let location: LocationQuery.LocationField?
        public init(integrationID: String, location: LocationQuery.LocationField? = nil) {
            self.integrationID = integrationID
            self.location = location
        }
    }

    public struct IntegrationConnectKeyInput: Equatable, Hashable, Sendable {
        public let integrationID: String
        public let location: LocationQuery.LocationField?
        public let key: String
        public let answer: FormSchema.Answer?
        public let label: String?
        public init(
            integrationID: String,
            location: LocationQuery.LocationField? = nil,
            key: String,
            answer: FormSchema.Answer? = nil,
            label: String? = nil
        ) {
            self.integrationID = integrationID
            self.location = location
            self.key = key
            self.answer = answer
            self.label = label
        }
    }

    public struct IntegrationConnectExternalInput: Equatable, Hashable, Sendable {
        public let integrationID: String
        public let location: LocationQuery.LocationField?
        public let methodID: String
        public let answer: FormSchema.Answer?
        public let label: String?
        public init(
            integrationID: String,
            location: LocationQuery.LocationField? = nil,
            methodID: String,
            answer: FormSchema.Answer? = nil,
            label: String? = nil
        ) {
            self.integrationID = integrationID
            self.location = location
            self.methodID = methodID
            self.answer = answer
            self.label = label
        }
    }

    public struct IntegrationOauthConnectInput: Equatable, Hashable, Sendable {
        public let integrationID: String
        public let location: LocationQuery.LocationField?
        public let methodID: String
        public let answer: FormSchema.Answer?
        public let label: String?
        public init(
            integrationID: String,
            location: LocationQuery.LocationField? = nil,
            methodID: String,
            answer: FormSchema.Answer? = nil,
            label: String? = nil
        ) {
            self.integrationID = integrationID
            self.location = location
            self.methodID = methodID
            self.answer = answer
            self.label = label
        }
    }

    public struct IntegrationOauthStatusInput: Equatable, Hashable, Sendable {
        public let integrationID: String
        public let attemptID: String
        public let location: LocationQuery.LocationField?
        public init(
            integrationID: String,
            attemptID: String,
            location: LocationQuery.LocationField? = nil
        ) {
            self.integrationID = integrationID
            self.attemptID = attemptID
            self.location = location
        }
    }

    public struct IntegrationOauthCompleteInput: Equatable, Hashable, Sendable {
        public let integrationID: String
        public let attemptID: String
        public let location: LocationQuery.LocationField?
        public let code: String?
        public init(
            integrationID: String,
            attemptID: String,
            location: LocationQuery.LocationField? = nil,
            code: String? = nil
        ) {
            self.integrationID = integrationID
            self.attemptID = attemptID
            self.location = location
            self.code = code
        }
    }

    public struct IntegrationOauthCancelInput: Equatable, Hashable, Sendable {
        public let integrationID: String
        public let attemptID: String
        public let location: LocationQuery.LocationField?
        public init(
            integrationID: String,
            attemptID: String,
            location: LocationQuery.LocationField? = nil
        ) {
            self.integrationID = integrationID
            self.attemptID = attemptID
            self.location = location
        }
    }

    public struct IntegrationCommandConnectInput: Equatable, Hashable, Sendable {
        public let integrationID: String
        public let location: LocationQuery.LocationField?
        public let methodID: String
        public let label: String?
        public init(
            integrationID: String,
            location: LocationQuery.LocationField? = nil,
            methodID: String,
            label: String? = nil
        ) {
            self.integrationID = integrationID
            self.location = location
            self.methodID = methodID
            self.label = label
        }
    }

    public struct IntegrationCommandStatusInput: Equatable, Hashable, Sendable {
        public let integrationID: String
        public let attemptID: String
        public let location: LocationQuery.LocationField?
        public init(
            integrationID: String,
            attemptID: String,
            location: LocationQuery.LocationField? = nil
        ) {
            self.integrationID = integrationID
            self.attemptID = attemptID
            self.location = location
        }
    }

    public struct IntegrationCommandCancelInput: Equatable, Hashable, Sendable {
        public let integrationID: String
        public let attemptID: String
        public let location: LocationQuery.LocationField?
        public init(
            integrationID: String,
            attemptID: String,
            location: LocationQuery.LocationField? = nil
        ) {
            self.integrationID = integrationID
            self.attemptID = attemptID
            self.location = location
        }
    }

    public struct ExperimentalIntegrationWellknownAddInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let url: String
        public init(location: LocationQuery.LocationField? = nil, url: String) {
            self.location = location
            self.url = url
        }
    }

    public struct McpListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct McpResourceCatalogInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct ExperimentalMcpAddInput: Equatable, Hashable, Sendable {
        public let server: String
        public let location: LocationQuery.LocationField?
        public let config: McpSchema.ServerConfig
        public init(
            server: String,
            location: LocationQuery.LocationField? = nil,
            config: McpSchema.ServerConfig
        ) {
            self.server = server
            self.location = location
            self.config = config
        }
    }

    public struct ExperimentalMcpRemoveInput: Equatable, Hashable, Sendable {
        public let server: String
        public let location: LocationQuery.LocationField?
        public init(server: String, location: LocationQuery.LocationField? = nil) {
            self.server = server
            self.location = location
        }
    }

    public struct ExperimentalMcpConnectInput: Equatable, Hashable, Sendable {
        public let server: String
        public let location: LocationQuery.LocationField?
        public init(server: String, location: LocationQuery.LocationField? = nil) {
            self.server = server
            self.location = location
        }
    }

    public struct ExperimentalMcpDisconnectInput: Equatable, Hashable, Sendable {
        public let server: String
        public let location: LocationQuery.LocationField?
        public init(server: String, location: LocationQuery.LocationField? = nil) {
            self.server = server
            self.location = location
        }
    }

    public struct ExperimentalMcpClientTokenInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let name: String
        public let xOpencodeTicket: String?
        public init(
            location: LocationQuery.LocationField? = nil,
            name: String,
            xOpencodeTicket: String? = nil
        ) {
            self.location = location
            self.name = name
            self.xOpencodeTicket = xOpencodeTicket
        }
    }

    public struct CredentialCreateInput: Equatable, Hashable, Sendable {
        public let id: String?
        public let integrationID: String
        public let label: String?
        public let value: CredentialSchema.Value
        public let activate: Bool?
        public init(
            id: String? = nil,
            integrationID: String,
            label: String? = nil,
            value: CredentialSchema.Value,
            activate: Bool? = nil
        ) {
            self.id = id
            self.integrationID = integrationID
            self.label = label
            self.value = value
            self.activate = activate
        }
    }

    public struct CredentialUpdateInput: Equatable, Hashable, Sendable {
        public let credentialID: String
        public let label: String
        public init(credentialID: String, label: String) {
            self.credentialID = credentialID
            self.label = label
        }
    }

    public struct CredentialActivateInput: Equatable, Hashable, Sendable {
        public let credentialID: String
        public init(credentialID: String) {
            self.credentialID = credentialID
        }
    }

    public struct CredentialRemoveInput: Equatable, Hashable, Sendable {
        public let credentialID: String
        public init(credentialID: String) {
            self.credentialID = credentialID
        }
    }

    public struct ProjectListInput: Equatable, Hashable, Sendable {
        public let archived: Bool?
        public init(archived: Bool? = nil) {
            self.archived = archived
        }
    }

    public struct ProjectUpdateInput: Equatable, Hashable, Sendable {
        public let projectID: String
        public let canonical: String?
        public let name: String?
        public let icon: ProjectSchema.Icon?
        public let commands: ProjectSchema.Commands?
        public init(
            projectID: String,
            canonical: String? = nil,
            name: String? = nil,
            icon: ProjectSchema.Icon? = nil,
            commands: ProjectSchema.Commands? = nil
        ) {
            self.projectID = projectID
            self.canonical = canonical
            self.name = name
            self.icon = icon
            self.commands = commands
        }
    }

    public struct FormListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct PermissionRequestListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct PermissionSavedListInput: Equatable, Hashable, Sendable {
        public let projectID: String?
        public init(projectID: String? = nil) {
            self.projectID = projectID
        }
    }

    public struct PermissionSavedUpdateInput: Equatable, Hashable, Sendable {
        public let id: String
        public let action: String?
        public let resource: String?
        public init(
            id: String,
            action: String? = nil,
            resource: String? = nil
        ) {
            self.id = id
            self.action = action
            self.resource = resource
        }
    }

    public struct PermissionSavedRemoveInput: Equatable, Hashable, Sendable {
        public let id: String
        public init(id: String) {
            self.id = id
        }
    }

    public struct PermissionCreateInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let id: String?
        public let action: String
        public let resources: [String]
        public let save: [String]?
        public let metadata: [String: JSONValue]?
        public let source: JSONValue?
        public let agent: String?
        public init(
            sessionID: String,
            id: String? = nil,
            action: String,
            resources: [String],
            save: [String]? = nil,
            metadata: [String: JSONValue]? = nil,
            source: JSONValue? = nil,
            agent: String? = nil
        ) {
            self.sessionID = sessionID
            self.id = id
            self.action = action
            self.resources = resources
            self.save = save
            self.metadata = metadata
            self.source = source
            self.agent = agent
        }
    }

    public struct PermissionListInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public struct PermissionGetInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let requestID: String
        public init(sessionID: String, requestID: String) {
            self.sessionID = sessionID
            self.requestID = requestID
        }
    }

    public struct PermissionReplyInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let requestID: String
        public let decision: PermissionSchema.Reply
        public let message: String?
        public init(
            sessionID: String,
            requestID: String,
            decision: PermissionSchema.Reply,
            message: String? = nil
        ) {
            self.sessionID = sessionID
            self.requestID = requestID
            self.decision = decision
            self.message = message
        }
    }

    public struct FileReadInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let path: String
        public init(location: LocationQuery.LocationField? = nil, path: String) {
            self.location = location
            self.path = path
        }
    }

    public struct FileListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let path: String?
        public init(location: LocationQuery.LocationField? = nil, path: String? = nil) {
            self.location = location
            self.path = path
        }
    }

    public struct FileFindInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let query: String
        public let `type`: FileSystemSchema.EntryType?
        public let limit: Int?
        public init(
            location: LocationQuery.LocationField? = nil,
            query: String,
            `type`: FileSystemSchema.EntryType? = nil,
            limit: Int? = nil
        ) {
            self.location = location
            self.query = query
            self.`type` = `type`
            self.limit = limit
        }
    }

    public struct ExperimentalFileWriteInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let path: String
        public let payload: [UInt8]
        public init(
            location: LocationQuery.LocationField? = nil,
            path: String,
            payload: [UInt8]
        ) {
            self.location = location
            self.path = path
            self.payload = payload
        }
    }

    public struct ExperimentalFileWatchInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let path: String
        public init(location: LocationQuery.LocationField? = nil, path: String) {
            self.location = location
            self.path = path
        }
    }

    public struct ExperimentalFileUnwatchInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let path: String
        public init(location: LocationQuery.LocationField? = nil, path: String) {
            self.location = location
            self.path = path
        }
    }

    public struct CommandListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct SkillListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct RpcCallInput: Equatable, Hashable, Sendable {
        public let rpcID: String
        public let method: String
        public let location: LocationQuery.LocationField?
        public let input: JSONValue?
        public init(
            rpcID: String,
            method: String,
            location: LocationQuery.LocationField? = nil,
            input: JSONValue? = nil
        ) {
            self.rpcID = rpcID
            self.method = method
            self.location = location
            self.input = input
        }
    }

    public struct EventSubscribeInput: Equatable, Hashable, Sendable {
        public let types: [String]?
        public init(types: [String]? = nil) {
            self.types = types
        }
    }

    public struct PtyListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct PtyCreateInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let command: String?
        public let args: [String]?
        public let cwd: String?
        public let title: String?
        public let env: [String: String]?
        public init(
            location: LocationQuery.LocationField? = nil,
            command: String? = nil,
            args: [String]? = nil,
            cwd: String? = nil,
            title: String? = nil,
            env: [String: String]? = nil
        ) {
            self.location = location
            self.command = command
            self.args = args
            self.cwd = cwd
            self.title = title
            self.env = env
        }
    }

    public struct PtyGetInput: Equatable, Hashable, Sendable {
        public let ptyID: String
        public let location: LocationQuery.LocationField?
        public init(ptyID: String, location: LocationQuery.LocationField? = nil) {
            self.ptyID = ptyID
            self.location = location
        }
    }

    public struct PtyUpdateInput: Equatable, Hashable, Sendable {
        public let ptyID: String
        public let location: LocationQuery.LocationField?
        public let title: String?
        public let size: PtySchema.Size?
        public init(
            ptyID: String,
            location: LocationQuery.LocationField? = nil,
            title: String? = nil,
            size: PtySchema.Size? = nil
        ) {
            self.ptyID = ptyID
            self.location = location
            self.title = title
            self.size = size
        }
    }

    public struct PtyRemoveInput: Equatable, Hashable, Sendable {
        public let ptyID: String
        public let location: LocationQuery.LocationField?
        public init(ptyID: String, location: LocationQuery.LocationField? = nil) {
            self.ptyID = ptyID
            self.location = location
        }
    }

    public struct PtyConnectTokenInput: Equatable, Hashable, Sendable {
        public let ptyID: String
        public let location: LocationQuery.LocationField?
        public let xOpencodeTicket: String?
        public init(
            ptyID: String,
            location: LocationQuery.LocationField? = nil,
            xOpencodeTicket: String? = nil
        ) {
            self.ptyID = ptyID
            self.location = location
            self.xOpencodeTicket = xOpencodeTicket
        }
    }

    public struct ExperimentalPersistentPtyReadInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let lines: Int?
        public init(sessionID: String, lines: Int? = nil) {
            self.sessionID = sessionID
            self.lines = lines
        }
    }

    public struct ExperimentalPersistentPtyListInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public struct ExperimentalPersistentPtyCreateInput: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let command: String?
        public let args: [String]
        public let cwd: String?
        public let title: String
        public let env: [String: String]
        public let size: PersistentPtySchema.Size?
        public init(
            sessionID: String,
            command: String? = nil,
            args: [String],
            cwd: String? = nil,
            title: String,
            env: [String: String],
            size: PersistentPtySchema.Size? = nil
        ) {
            self.sessionID = sessionID
            self.command = command
            self.args = args
            self.cwd = cwd
            self.title = title
            self.env = env
            self.size = size
        }
    }

    public struct ExperimentalPersistentPtyGetInput: Equatable, Hashable, Sendable {
        public let ptyID: String
        public init(ptyID: String) {
            self.ptyID = ptyID
        }
    }

    public struct ExperimentalPersistentPtyUpdateInput: Equatable, Hashable, Sendable {
        public let ptyID: String
        public let attachmentID: String?
        public let size: PersistentPtySchema.Size?
        public let title: String?
        public init(
            ptyID: String,
            attachmentID: String? = nil,
            size: PersistentPtySchema.Size? = nil,
            title: String? = nil
        ) {
            self.ptyID = ptyID
            self.attachmentID = attachmentID
            self.size = size
            self.title = title
        }
    }

    public struct ExperimentalPersistentPtySnapshotInput: Equatable, Hashable, Sendable {
        public let ptyID: String
        public init(ptyID: String) {
            self.ptyID = ptyID
        }
    }

    public struct ExperimentalPersistentPtyRemoveInput: Equatable, Hashable, Sendable {
        public let ptyID: String
        public init(ptyID: String) {
            self.ptyID = ptyID
        }
    }

    public struct ExperimentalPersistentPtyConnectTokenInput: Equatable, Hashable, Sendable {
        public let ptyID: String
        public let xOpencodeTicket: String?
        public init(ptyID: String, xOpencodeTicket: String? = nil) {
            self.ptyID = ptyID
            self.xOpencodeTicket = xOpencodeTicket
        }
    }

    public struct ExperimentalMediaGetInput: Equatable, Hashable, Sendable {
        public let hash: String
        public init(hash: String) {
            self.hash = hash
        }
    }

    public struct ExperimentalBlobGetInput: Equatable, Hashable, Sendable {
        public let id: String
        public init(id: String) {
            self.id = id
        }
    }

    public struct ExperimentalAutomationCreateInput: Equatable, Hashable, Sendable {
        public let sessionID: String?
        public let directory: String?
        public let name: String
        public let trigger: JSONValue
        public let action: JSONValue
        public let expires: String?
        public init(
            sessionID: String? = nil,
            directory: String? = nil,
            name: String,
            trigger: JSONValue,
            action: JSONValue,
            expires: String? = nil
        ) {
            self.sessionID = sessionID
            self.directory = directory
            self.name = name
            self.trigger = trigger
            self.action = action
            self.expires = expires
        }
    }

    public struct ExperimentalAutomationListInput: Equatable, Hashable, Sendable {
        public let sessionID: String?
        public let directory: String?
        public init(sessionID: String? = nil, directory: String? = nil) {
            self.sessionID = sessionID
            self.directory = directory
        }
    }

    public struct ExperimentalAutomationGetInput: Equatable, Hashable, Sendable {
        public let automationID: String
        public init(automationID: String) {
            self.automationID = automationID
        }
    }

    public struct ExperimentalAutomationPauseInput: Equatable, Hashable, Sendable {
        public let automationID: String
        public init(automationID: String) {
            self.automationID = automationID
        }
    }

    public struct ExperimentalAutomationResumeInput: Equatable, Hashable, Sendable {
        public let automationID: String
        public init(automationID: String) {
            self.automationID = automationID
        }
    }

    public struct ExperimentalAutomationDeleteInput: Equatable, Hashable, Sendable {
        public let automationID: String
        public init(automationID: String) {
            self.automationID = automationID
        }
    }

    public struct ExperimentalArtifactsProvidersInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct ExperimentalArtifactsListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let sessionID: String?
        public let provider: String?
        public init(
            location: LocationQuery.LocationField? = nil,
            sessionID: String? = nil,
            provider: String? = nil
        ) {
            self.location = location
            self.sessionID = sessionID
            self.provider = provider
        }
    }

    public struct ExperimentalArtifactsCreateInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let title: String
        public let files: [String: String]
        public let entry: String?
        public let provider: String?
        public let sessionID: String?
        public init(
            location: LocationQuery.LocationField? = nil,
            title: String,
            files: [String: String],
            entry: String? = nil,
            provider: String? = nil,
            sessionID: String? = nil
        ) {
            self.location = location
            self.title = title
            self.files = files
            self.entry = entry
            self.provider = provider
            self.sessionID = sessionID
        }
    }

    public struct ExperimentalArtifactsGetInput: Equatable, Hashable, Sendable {
        public let artifactID: String
        public let location: LocationQuery.LocationField?
        public init(artifactID: String, location: LocationQuery.LocationField? = nil) {
            self.artifactID = artifactID
            self.location = location
        }
    }

    public struct ExperimentalArtifactsUpdateInput: Equatable, Hashable, Sendable {
        public let artifactID: String
        public let location: LocationQuery.LocationField?
        public let title: String?
        public let files: [String: String]
        public let entry: String?
        public let sessionID: String?
        public init(
            artifactID: String,
            location: LocationQuery.LocationField? = nil,
            title: String? = nil,
            files: [String: String],
            entry: String? = nil,
            sessionID: String? = nil
        ) {
            self.artifactID = artifactID
            self.location = location
            self.title = title
            self.files = files
            self.entry = entry
            self.sessionID = sessionID
        }
    }

    public struct ExperimentalArtifactsDeleteInput: Equatable, Hashable, Sendable {
        public let artifactID: String
        public let location: LocationQuery.LocationField?
        public init(artifactID: String, location: LocationQuery.LocationField? = nil) {
            self.artifactID = artifactID
            self.location = location
        }
    }

    public struct ExperimentalArtifactsViewInput: Equatable, Hashable, Sendable {
        public let artifactID: String
        public let location: LocationQuery.LocationField?
        public let path: String
        public init(
            artifactID: String,
            location: LocationQuery.LocationField? = nil,
            path: String
        ) {
            self.artifactID = artifactID
            self.location = location
            self.path = path
        }
    }

    public struct ExperimentalJobListInput: Equatable, Hashable, Sendable {
        public let sessionID: String?
        public let kind: JSONValue?
        public let status: JSONValue?
        public let descendants: Bool?
        public init(
            sessionID: String? = nil,
            kind: JSONValue? = nil,
            status: JSONValue? = nil,
            descendants: Bool? = nil
        ) {
            self.sessionID = sessionID
            self.kind = kind
            self.status = status
            self.descendants = descendants
        }
    }

    public struct ShellListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct ShellCreateInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let command: String
        public let cwd: String?
        public let timeout: Double?
        public let metadata: [String: JSONValue]?
        public init(
            location: LocationQuery.LocationField? = nil,
            command: String,
            cwd: String? = nil,
            timeout: Double? = nil,
            metadata: [String: JSONValue]? = nil
        ) {
            self.location = location
            self.command = command
            self.cwd = cwd
            self.timeout = timeout
            self.metadata = metadata
        }
    }

    public struct ShellGetInput: Equatable, Hashable, Sendable {
        public let id: String
        public let location: LocationQuery.LocationField?
        public init(id: String, location: LocationQuery.LocationField? = nil) {
            self.id = id
            self.location = location
        }
    }

    public struct ShellOutputInput: Equatable, Hashable, Sendable {
        public let id: String
        public let location: LocationQuery.LocationField?
        public let cursor: Int?
        public let limit: Int?
        public init(
            id: String,
            location: LocationQuery.LocationField? = nil,
            cursor: Int? = nil,
            limit: Int? = nil
        ) {
            self.id = id
            self.location = location
            self.cursor = cursor
            self.limit = limit
        }
    }

    public struct ShellRemoveInput: Equatable, Hashable, Sendable {
        public let id: String
        public let location: LocationQuery.LocationField?
        public init(id: String, location: LocationQuery.LocationField? = nil) {
            self.id = id
            self.location = location
        }
    }

    public struct ReferenceListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct WorktreeListInput: Equatable, Hashable, Sendable {
        public let projectID: String
        public init(projectID: String) {
            self.projectID = projectID
        }
    }

    public struct WorktreeCreateInput: Equatable, Hashable, Sendable {
        public let projectID: String
        public let from: String?
        public let branch: String?
        public let directory: String?
        public let name: String?
        public init(
            projectID: String,
            from: String? = nil,
            branch: String? = nil,
            directory: String? = nil,
            name: String? = nil
        ) {
            self.projectID = projectID
            self.from = from
            self.branch = branch
            self.directory = directory
            self.name = name
        }
    }

    public struct WorktreeRemoveInput: Equatable, Hashable, Sendable {
        public let projectID: String
        public let directory: String
        public let force: Bool
        public init(
            projectID: String,
            directory: String,
            force: Bool
        ) {
            self.projectID = projectID
            self.directory = directory
            self.force = force
        }
    }

    public struct WorktreeRefreshInput: Equatable, Hashable, Sendable {
        public let projectID: String
        public init(projectID: String) {
            self.projectID = projectID
        }
    }

    public struct VcsInitInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let provider: String?
        public init(location: LocationQuery.LocationField? = nil, provider: String? = nil) {
            self.location = location
            self.provider = provider
        }
    }

    public struct VcsGetInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct VcsBaseInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct VcsStatusInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct VcsBranchListInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let search: String?
        public let limit: Int?
        public init(
            location: LocationQuery.LocationField? = nil,
            search: String? = nil,
            limit: Int? = nil
        ) {
            self.location = location
            self.search = search
            self.limit = limit
        }
    }

    public struct VcsDiffInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let mode: VcsSchema.Mode
        public let base: String?
        public let context: Double?
        public let untracked: VcsSchema.Untracked?
        public init(
            location: LocationQuery.LocationField? = nil,
            mode: VcsSchema.Mode,
            base: String? = nil,
            context: Double? = nil,
            untracked: VcsSchema.Untracked? = nil
        ) {
            self.location = location
            self.mode = mode
            self.base = base
            self.context = context
            self.untracked = untracked
        }
    }

    public struct DebugHeapDumpInput: Equatable, Hashable, Sendable {
        public let directory: String?
        public init(directory: String? = nil) {
            self.directory = directory
        }
    }

    public struct DebugLocationEvictInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct WebsearchProvidersInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct WebsearchQueryInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public let query: String
        public let providerID: String?
        public init(
            location: LocationQuery.LocationField? = nil,
            query: String,
            providerID: String? = nil
        ) {
            self.location = location
            self.query = query
            self.providerID = providerID
        }
    }

    public struct ExperimentalUsageLimitsInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct ConfigGetInput: Equatable, Hashable, Sendable {
        public let location: LocationQuery.LocationField?
        public init(location: LocationQuery.LocationField? = nil) {
            self.location = location
        }
    }

    public struct ExperimentalConfigUpdateInput: Equatable, Hashable, Sendable {
        public let shell: SchemaPrimitive.Nullable<String>
        public init(shell: SchemaPrimitive.Nullable<String>) {
            self.shell = shell
        }
    }
}

// parity: client/src/promise/generated/types.ts#ServerConnectInput [status=implemented hash=35b353992fd9]
public typealias ServerConnectInput = PromiseInputTypes.ServerConnectInput

// parity: client/src/promise/generated/types.ts#LocationGetInput [status=implemented hash=fa1d60fb917a]
public typealias LocationGetInput = PromiseInputTypes.LocationGetInput

// parity: client/src/promise/generated/types.ts#AgentListInput [status=implemented hash=96f8ed742110]
public typealias AgentListInput = PromiseInputTypes.AgentListInput

// parity: client/src/promise/generated/types.ts#AgentGetInput [status=implemented hash=ee33d4385b2e]
public typealias AgentGetInput = PromiseInputTypes.AgentGetInput

// parity: client/src/promise/generated/types.ts#PluginListInput [status=implemented hash=2051bfeaadc8]
public typealias PluginListInput = PromiseInputTypes.PluginListInput

// parity: client/src/promise/generated/types.ts#PluginGuiInput [status=implemented hash=854e79fdb0c1]
public typealias PluginGuiInput = PromiseInputTypes.PluginGuiInput

// parity: client/src/promise/generated/types.ts#PluginCheckInput [status=implemented hash=ce5a193c652a]
public typealias PluginCheckInput = PromiseInputTypes.PluginCheckInput

// parity: client/src/promise/generated/types.ts#PluginUpdateInput [status=implemented hash=324ec545abcc]
public typealias PluginUpdateInput = PromiseInputTypes.PluginUpdateInput

// parity: client/src/promise/generated/types.ts#SessionListInput [status=implemented hash=0fee24a4e1c3]
public typealias SessionListInput = PromiseInputTypes.SessionListInput

// parity: client/src/promise/generated/types.ts#SessionCreateInput [status=implemented hash=f3fe1bfe6d9e]
public typealias SessionCreateInput = PromiseInputTypes.SessionCreateInput

// parity: client/src/promise/generated/types.ts#SessionGetInput [status=implemented hash=f67562403a3a]
public typealias SessionGetInput = PromiseInputTypes.SessionGetInput

// parity: client/src/promise/generated/types.ts#SessionRemoveInput [status=implemented hash=897e191e7b2f]
public typealias SessionRemoveInput = PromiseInputTypes.SessionRemoveInput

// parity: client/src/promise/generated/types.ts#SessionForkInput [status=implemented hash=a85d6bb42293]
public typealias SessionForkInput = PromiseInputTypes.SessionForkInput

// parity: client/src/promise/generated/types.ts#SessionSwitchAgentInput [status=implemented hash=d25aeb53f565]
public typealias SessionSwitchAgentInput = PromiseInputTypes.SessionSwitchAgentInput

// parity: client/src/promise/generated/types.ts#SessionSwitchModelInput [status=implemented hash=e2a7d63e8821]
public typealias SessionSwitchModelInput = PromiseInputTypes.SessionSwitchModelInput

// parity: client/src/promise/generated/types.ts#SessionUpdateInput [status=implemented hash=6d0bc453be9e]
public typealias SessionUpdateInput = PromiseInputTypes.SessionUpdateInput

// parity: client/src/promise/generated/types.ts#SessionMoveInput [status=implemented hash=61d8775c8e62]
public typealias SessionMoveInput = PromiseInputTypes.SessionMoveInput

// parity: client/src/promise/generated/types.ts#SessionPromptInput [status=implemented hash=cd4dbcccdcdc]
public typealias SessionPromptInput = PromiseInputTypes.SessionPromptInput

// parity: client/src/promise/generated/types.ts#SessionCommandInput [status=implemented hash=1365f959449d]
public typealias SessionCommandInput = PromiseInputTypes.SessionCommandInput

// parity: client/src/promise/generated/types.ts#SessionSyntheticInput [status=implemented hash=85662327b0be]
public typealias SessionSyntheticInput = PromiseInputTypes.SessionSyntheticInput

// parity: client/src/promise/generated/types.ts#SessionShellInput [status=implemented hash=12e6725bc35c]
public typealias SessionShellInput = PromiseInputTypes.SessionShellInput

// parity: client/src/promise/generated/types.ts#SessionCompactInput [status=implemented hash=12d7c564329b]
public typealias SessionCompactInput = PromiseInputTypes.SessionCompactInput

// parity: client/src/promise/generated/types.ts#SessionRevertStageInput [status=implemented hash=46d41b61bb49]
public typealias SessionRevertStageInput = PromiseInputTypes.SessionRevertStageInput

// parity: client/src/promise/generated/types.ts#SessionRevertClearInput [status=implemented hash=027c77c73246]
public typealias SessionRevertClearInput = PromiseInputTypes.SessionRevertClearInput

// parity: client/src/promise/generated/types.ts#SessionRevertCommitInput [status=implemented hash=e5054e120a37]
public typealias SessionRevertCommitInput = PromiseInputTypes.SessionRevertCommitInput

// parity: client/src/promise/generated/types.ts#SessionContextInput [status=implemented hash=8edf9794003c]
public typealias SessionContextInput = PromiseInputTypes.SessionContextInput

// parity: client/src/promise/generated/types.ts#SessionDiffInput [status=implemented hash=48de4cbf815e]
public typealias SessionDiffInput = PromiseInputTypes.SessionDiffInput

// parity: client/src/promise/generated/types.ts#SessionInboxListInput [status=implemented hash=ca97eb1671ef]
public typealias SessionInboxListInput = PromiseInputTypes.SessionInboxListInput

// parity: client/src/promise/generated/types.ts#SessionInboxCancelInput [status=implemented hash=3d4678cd17b6]
public typealias SessionInboxCancelInput = PromiseInputTypes.SessionInboxCancelInput

// parity: client/src/promise/generated/types.ts#SessionInboxUpdateInput [status=implemented hash=0905bcc84c3a]
public typealias SessionInboxUpdateInput = PromiseInputTypes.SessionInboxUpdateInput

// parity: client/src/promise/generated/types.ts#SessionGenerateInput [status=implemented hash=4612dccb629f]
public typealias SessionGenerateInput = PromiseInputTypes.SessionGenerateInput

// parity: client/src/promise/generated/types.ts#SessionInterruptInput [status=implemented hash=f1fa2d02f840]
public typealias SessionInterruptInput = PromiseInputTypes.SessionInterruptInput

// parity: client/src/promise/generated/types.ts#SessionBackgroundInput [status=implemented hash=38868c67bcb7]
public typealias SessionBackgroundInput = PromiseInputTypes.SessionBackgroundInput

// parity: client/src/promise/generated/types.ts#SessionMessageGetInput [status=implemented hash=47ea04fa6eb0]
public typealias SessionMessageGetInput = PromiseInputTypes.SessionMessageGetInput

// parity: client/src/promise/generated/types.ts#SessionFormListInput [status=implemented hash=e2664af3ece0]
public typealias SessionFormListInput = PromiseInputTypes.SessionFormListInput

// parity: client/src/promise/generated/types.ts#SessionFormCreateInput [status=implemented hash=091ecdd56109]
public typealias SessionFormCreateInput = PromiseInputTypes.SessionFormCreateInput

// parity: client/src/promise/generated/types.ts#SessionFormGetInput [status=implemented hash=d5f5cdc30450]
public typealias SessionFormGetInput = PromiseInputTypes.SessionFormGetInput

// parity: client/src/promise/generated/types.ts#SessionFormReplyInput [status=implemented hash=846c7d838a16]
public typealias SessionFormReplyInput = PromiseInputTypes.SessionFormReplyInput

// parity: client/src/promise/generated/types.ts#SessionFormCancelInput [status=implemented hash=62432d6e5c41]
public typealias SessionFormCancelInput = PromiseInputTypes.SessionFormCancelInput

// parity: client/src/promise/generated/types.ts#SessionEnvironmentInput [status=implemented hash=f4b9fc05316e]
public typealias SessionEnvironmentInput = PromiseInputTypes.SessionEnvironmentInput

// parity: client/src/promise/generated/types.ts#SessionViewInput [status=implemented hash=d43eb8e50161]
public typealias SessionViewInput = PromiseInputTypes.SessionViewInput

// parity: client/src/promise/generated/types.ts#ExperimentalSessionStatsInput [status=implemented hash=70b3a46d931a]
public typealias ExperimentalSessionStatsInput = PromiseInputTypes.ExperimentalSessionStatsInput

// parity: client/src/promise/generated/types.ts#ExperimentalSessionImportInput [status=implemented hash=d93c8073322f]
public typealias ExperimentalSessionImportInput = PromiseInputTypes.ExperimentalSessionImportInput

// parity: client/src/promise/generated/types.ts#ExperimentalSessionExportInput [status=implemented hash=3f1923b008f0]
public typealias ExperimentalSessionExportInput = PromiseInputTypes.ExperimentalSessionExportInput

// parity: client/src/promise/generated/types.ts#ExperimentalSessionSkillInput [status=implemented hash=9bf46a650028]
public typealias ExperimentalSessionSkillInput = PromiseInputTypes.ExperimentalSessionSkillInput

// parity: client/src/promise/generated/types.ts#ExperimentalSessionWaitInput [status=implemented hash=90bec449b60c]
public typealias ExperimentalSessionWaitInput = PromiseInputTypes.ExperimentalSessionWaitInput

// parity: client/src/promise/generated/types.ts#ExperimentalSessionInstructionsEntryListInput [status=implemented hash=d3ca0a63817b]
public typealias ExperimentalSessionInstructionsEntryListInput = PromiseInputTypes.ExperimentalSessionInstructionsEntryListInput

// parity: client/src/promise/generated/types.ts#ExperimentalSessionInstructionsEntryPutInput [status=implemented hash=53d208edd296]
public typealias ExperimentalSessionInstructionsEntryPutInput = PromiseInputTypes.ExperimentalSessionInstructionsEntryPutInput

// parity: client/src/promise/generated/types.ts#ExperimentalSessionInstructionsEntryRemoveInput [status=implemented hash=fffd8122a251]
public typealias ExperimentalSessionInstructionsEntryRemoveInput = PromiseInputTypes.ExperimentalSessionInstructionsEntryRemoveInput

// parity: client/src/promise/generated/types.ts#ExperimentalSessionLogInput [status=implemented hash=0a6a7aa34767]
public typealias ExperimentalSessionLogInput = PromiseInputTypes.ExperimentalSessionLogInput

// parity: client/src/promise/generated/types.ts#MessageListInput [status=implemented hash=b71e99c600ac]
public typealias MessageListInput = PromiseInputTypes.MessageListInput

// parity: client/src/promise/generated/types.ts#ModelListInput [status=implemented hash=8e313e04306c]
public typealias ModelListInput = PromiseInputTypes.ModelListInput

// parity: client/src/promise/generated/types.ts#ModelDefaultInput [status=implemented hash=c19a788319a6]
public typealias ModelDefaultInput = PromiseInputTypes.ModelDefaultInput

// parity: client/src/promise/generated/types.ts#ExperimentalGenerateTextInput [status=implemented hash=eb536eb4643d]
public typealias ExperimentalGenerateTextInput = PromiseInputTypes.ExperimentalGenerateTextInput

// parity: client/src/promise/generated/types.ts#ExperimentalGenerateImageInput [status=implemented hash=bd16c9a8d3fe]
public typealias ExperimentalGenerateImageInput = PromiseInputTypes.ExperimentalGenerateImageInput

// parity: client/src/promise/generated/types.ts#ExperimentalGenerateVideoCreateInput [status=implemented hash=95cce3a49c9b]
public typealias ExperimentalGenerateVideoCreateInput = PromiseInputTypes.ExperimentalGenerateVideoCreateInput

// parity: client/src/promise/generated/types.ts#ExperimentalGenerateVideoGetInput [status=implemented hash=95999f717a4e]
public typealias ExperimentalGenerateVideoGetInput = PromiseInputTypes.ExperimentalGenerateVideoGetInput

// parity: client/src/promise/generated/types.ts#ExperimentalGenerateDecisionsInput [status=implemented hash=b20349cdedbe]
public typealias ExperimentalGenerateDecisionsInput = PromiseInputTypes.ExperimentalGenerateDecisionsInput

// parity: client/src/promise/generated/types.ts#ExperimentalVoiceSessionInput [status=implemented hash=77c7d19d28d9]
public typealias ExperimentalVoiceSessionInput = PromiseInputTypes.ExperimentalVoiceSessionInput

// parity: client/src/promise/generated/types.ts#ProviderListInput [status=implemented hash=9faa774bd9c6]
public typealias ProviderListInput = PromiseInputTypes.ProviderListInput

// parity: client/src/promise/generated/types.ts#ProviderGetInput [status=implemented hash=deebb2b992ef]
public typealias ProviderGetInput = PromiseInputTypes.ProviderGetInput

// parity: client/src/promise/generated/types.ts#IntegrationListInput [status=implemented hash=a138f3e2f704]
public typealias IntegrationListInput = PromiseInputTypes.IntegrationListInput

// parity: client/src/promise/generated/types.ts#IntegrationGetInput [status=implemented hash=05609a2a3232]
public typealias IntegrationGetInput = PromiseInputTypes.IntegrationGetInput

// parity: client/src/promise/generated/types.ts#IntegrationConnectKeyInput [status=implemented hash=e53d76c9069f]
public typealias IntegrationConnectKeyInput = PromiseInputTypes.IntegrationConnectKeyInput

// parity: client/src/promise/generated/types.ts#IntegrationConnectExternalInput [status=implemented hash=aa1194b089bf]
public typealias IntegrationConnectExternalInput = PromiseInputTypes.IntegrationConnectExternalInput

// parity: client/src/promise/generated/types.ts#IntegrationOauthConnectInput [status=implemented hash=9da7849347e3]
public typealias IntegrationOauthConnectInput = PromiseInputTypes.IntegrationOauthConnectInput

// parity: client/src/promise/generated/types.ts#IntegrationOauthStatusInput [status=implemented hash=be170f25f6e9]
public typealias IntegrationOauthStatusInput = PromiseInputTypes.IntegrationOauthStatusInput

// parity: client/src/promise/generated/types.ts#IntegrationOauthCompleteInput [status=implemented hash=66df42bf2201]
public typealias IntegrationOauthCompleteInput = PromiseInputTypes.IntegrationOauthCompleteInput

// parity: client/src/promise/generated/types.ts#IntegrationOauthCancelInput [status=implemented hash=5eaebd9a54ca]
public typealias IntegrationOauthCancelInput = PromiseInputTypes.IntegrationOauthCancelInput

// parity: client/src/promise/generated/types.ts#IntegrationCommandConnectInput [status=implemented hash=d9dcd5e62fae]
public typealias IntegrationCommandConnectInput = PromiseInputTypes.IntegrationCommandConnectInput

// parity: client/src/promise/generated/types.ts#IntegrationCommandStatusInput [status=implemented hash=9f74cd642e72]
public typealias IntegrationCommandStatusInput = PromiseInputTypes.IntegrationCommandStatusInput

// parity: client/src/promise/generated/types.ts#IntegrationCommandCancelInput [status=implemented hash=dc674cb3d8f1]
public typealias IntegrationCommandCancelInput = PromiseInputTypes.IntegrationCommandCancelInput

// parity: client/src/promise/generated/types.ts#ExperimentalIntegrationWellknownAddInput [status=implemented hash=dc32fd926001]
public typealias ExperimentalIntegrationWellknownAddInput = PromiseInputTypes.ExperimentalIntegrationWellknownAddInput

// parity: client/src/promise/generated/types.ts#McpListInput [status=implemented hash=096c6117fb8b]
public typealias McpListInput = PromiseInputTypes.McpListInput

// parity: client/src/promise/generated/types.ts#McpResourceCatalogInput [status=implemented hash=7f0524d5cd18]
public typealias McpResourceCatalogInput = PromiseInputTypes.McpResourceCatalogInput

// parity: client/src/promise/generated/types.ts#ExperimentalMcpAddInput [status=implemented hash=ebb47a74b8c3]
public typealias ExperimentalMcpAddInput = PromiseInputTypes.ExperimentalMcpAddInput

// parity: client/src/promise/generated/types.ts#ExperimentalMcpRemoveInput [status=implemented hash=22acbbeb1eb7]
public typealias ExperimentalMcpRemoveInput = PromiseInputTypes.ExperimentalMcpRemoveInput

// parity: client/src/promise/generated/types.ts#ExperimentalMcpConnectInput [status=implemented hash=18f23564f36d]
public typealias ExperimentalMcpConnectInput = PromiseInputTypes.ExperimentalMcpConnectInput

// parity: client/src/promise/generated/types.ts#ExperimentalMcpDisconnectInput [status=implemented hash=f919b831ab20]
public typealias ExperimentalMcpDisconnectInput = PromiseInputTypes.ExperimentalMcpDisconnectInput

// parity: client/src/promise/generated/types.ts#ExperimentalMcpClientTokenInput [status=implemented hash=c24dcd025edb]
public typealias ExperimentalMcpClientTokenInput = PromiseInputTypes.ExperimentalMcpClientTokenInput

// parity: client/src/promise/generated/types.ts#CredentialCreateInput [status=implemented hash=ab2196d93a1b]
public typealias CredentialCreateInput = PromiseInputTypes.CredentialCreateInput

// parity: client/src/promise/generated/types.ts#CredentialUpdateInput [status=implemented hash=d201ed66655f]
public typealias CredentialUpdateInput = PromiseInputTypes.CredentialUpdateInput

// parity: client/src/promise/generated/types.ts#CredentialActivateInput [status=implemented hash=9252721ea0f9]
public typealias CredentialActivateInput = PromiseInputTypes.CredentialActivateInput

// parity: client/src/promise/generated/types.ts#CredentialRemoveInput [status=implemented hash=33291d20cd07]
public typealias CredentialRemoveInput = PromiseInputTypes.CredentialRemoveInput

// parity: client/src/promise/generated/types.ts#ProjectListInput [status=implemented hash=169b7fe8bcd2]
public typealias ProjectListInput = PromiseInputTypes.ProjectListInput

// parity: client/src/promise/generated/types.ts#ProjectUpdateInput [status=implemented hash=2392b8d0ac49]
public typealias ProjectUpdateInput = PromiseInputTypes.ProjectUpdateInput

// parity: client/src/promise/generated/types.ts#FormListInput [status=implemented hash=448f28879b4b]
public typealias FormListInput = PromiseInputTypes.FormListInput

// parity: client/src/promise/generated/types.ts#PermissionRequestListInput [status=implemented hash=6f33d848462e]
public typealias PermissionRequestListInput = PromiseInputTypes.PermissionRequestListInput

// parity: client/src/promise/generated/types.ts#PermissionSavedListInput [status=implemented hash=a13598c54a7e]
public typealias PermissionSavedListInput = PromiseInputTypes.PermissionSavedListInput

// parity: client/src/promise/generated/types.ts#PermissionSavedUpdateInput [status=implemented hash=87b66c5eac52]
public typealias PermissionSavedUpdateInput = PromiseInputTypes.PermissionSavedUpdateInput

// parity: client/src/promise/generated/types.ts#PermissionSavedRemoveInput [status=implemented hash=c761150758a7]
public typealias PermissionSavedRemoveInput = PromiseInputTypes.PermissionSavedRemoveInput

// parity: client/src/promise/generated/types.ts#PermissionCreateInput [status=implemented hash=305e614a04bb]
public typealias PermissionCreateInput = PromiseInputTypes.PermissionCreateInput

// parity: client/src/promise/generated/types.ts#PermissionListInput [status=implemented hash=0cc3e9dd4401]
public typealias PermissionListInput = PromiseInputTypes.PermissionListInput

// parity: client/src/promise/generated/types.ts#PermissionGetInput [status=implemented hash=021d4439e2bf]
public typealias PermissionGetInput = PromiseInputTypes.PermissionGetInput

// parity: client/src/promise/generated/types.ts#PermissionReplyInput [status=implemented hash=7f9cab85cd70]
public typealias PermissionReplyInput = PromiseInputTypes.PermissionReplyInput

// parity: client/src/promise/generated/types.ts#FileReadInput [status=implemented hash=7e70211b7213]
public typealias FileReadInput = PromiseInputTypes.FileReadInput

// parity: client/src/promise/generated/types.ts#FileListInput [status=implemented hash=9f486a3441c8]
public typealias FileListInput = PromiseInputTypes.FileListInput

// parity: client/src/promise/generated/types.ts#FileFindInput [status=implemented hash=d4053d112a0f]
public typealias FileFindInput = PromiseInputTypes.FileFindInput

// parity: client/src/promise/generated/types.ts#ExperimentalFileWriteInput [status=implemented hash=13f9ff69682d]
public typealias ExperimentalFileWriteInput = PromiseInputTypes.ExperimentalFileWriteInput

// parity: client/src/promise/generated/types.ts#ExperimentalFileWatchInput [status=implemented hash=13a4ff8867ff]
public typealias ExperimentalFileWatchInput = PromiseInputTypes.ExperimentalFileWatchInput

// parity: client/src/promise/generated/types.ts#ExperimentalFileUnwatchInput [status=implemented hash=777e548dc45b]
public typealias ExperimentalFileUnwatchInput = PromiseInputTypes.ExperimentalFileUnwatchInput

// parity: client/src/promise/generated/types.ts#CommandListInput [status=implemented hash=e101d76ebe5a]
public typealias CommandListInput = PromiseInputTypes.CommandListInput

// parity: client/src/promise/generated/types.ts#SkillListInput [status=implemented hash=61d6874f1036]
public typealias SkillListInput = PromiseInputTypes.SkillListInput

// parity: client/src/promise/generated/types.ts#RpcCallInput [status=implemented hash=9294119ab14d]
public typealias RpcCallInput = PromiseInputTypes.RpcCallInput

// parity: client/src/promise/generated/types.ts#EventSubscribeInput [status=implemented hash=629667134685]
public typealias EventSubscribeInput = PromiseInputTypes.EventSubscribeInput

// parity: client/src/promise/generated/types.ts#PtyListInput [status=implemented hash=dfc8d63403b9]
public typealias PtyListInput = PromiseInputTypes.PtyListInput

// parity: client/src/promise/generated/types.ts#PtyCreateInput [status=implemented hash=90e2c1eac2b2]
public typealias PtyCreateInput = PromiseInputTypes.PtyCreateInput

// parity: client/src/promise/generated/types.ts#PtyGetInput [status=implemented hash=9febfb49866f]
public typealias PtyGetInput = PromiseInputTypes.PtyGetInput

// parity: client/src/promise/generated/types.ts#PtyUpdateInput [status=implemented hash=c8340771b987]
public typealias PtyUpdateInput = PromiseInputTypes.PtyUpdateInput

// parity: client/src/promise/generated/types.ts#PtyRemoveInput [status=implemented hash=09944f2ad15f]
public typealias PtyRemoveInput = PromiseInputTypes.PtyRemoveInput

// parity: client/src/promise/generated/types.ts#PtyConnectTokenInput [status=implemented hash=d93e7a3fd02e]
public typealias PtyConnectTokenInput = PromiseInputTypes.PtyConnectTokenInput

// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyReadInput [status=implemented hash=fe5463286e90]
public typealias ExperimentalPersistentPtyReadInput = PromiseInputTypes.ExperimentalPersistentPtyReadInput

// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyListInput [status=implemented hash=92928f274109]
public typealias ExperimentalPersistentPtyListInput = PromiseInputTypes.ExperimentalPersistentPtyListInput

// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyCreateInput [status=implemented hash=5d47a66adab1]
public typealias ExperimentalPersistentPtyCreateInput = PromiseInputTypes.ExperimentalPersistentPtyCreateInput

// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyGetInput [status=implemented hash=b41f00c30a40]
public typealias ExperimentalPersistentPtyGetInput = PromiseInputTypes.ExperimentalPersistentPtyGetInput

// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyUpdateInput [status=implemented hash=cda22e0e09e6]
public typealias ExperimentalPersistentPtyUpdateInput = PromiseInputTypes.ExperimentalPersistentPtyUpdateInput

// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtySnapshotInput [status=implemented hash=724491981b03]
public typealias ExperimentalPersistentPtySnapshotInput = PromiseInputTypes.ExperimentalPersistentPtySnapshotInput

// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyRemoveInput [status=implemented hash=0308390a3eca]
public typealias ExperimentalPersistentPtyRemoveInput = PromiseInputTypes.ExperimentalPersistentPtyRemoveInput

// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyConnectTokenInput [status=implemented hash=bf7c4fae3285]
public typealias ExperimentalPersistentPtyConnectTokenInput = PromiseInputTypes.ExperimentalPersistentPtyConnectTokenInput

// parity: client/src/promise/generated/types.ts#ExperimentalMediaGetInput [status=implemented hash=93a7d30dd97f]
public typealias ExperimentalMediaGetInput = PromiseInputTypes.ExperimentalMediaGetInput

// parity: client/src/promise/generated/types.ts#ExperimentalBlobGetInput [status=implemented hash=d73ea0a78f2f]
public typealias ExperimentalBlobGetInput = PromiseInputTypes.ExperimentalBlobGetInput

// parity: client/src/promise/generated/types.ts#ExperimentalAutomationCreateInput [status=implemented hash=ebfab6abbbe8]
public typealias ExperimentalAutomationCreateInput = PromiseInputTypes.ExperimentalAutomationCreateInput

// parity: client/src/promise/generated/types.ts#ExperimentalAutomationListInput [status=implemented hash=051616756ab8]
public typealias ExperimentalAutomationListInput = PromiseInputTypes.ExperimentalAutomationListInput

// parity: client/src/promise/generated/types.ts#ExperimentalAutomationGetInput [status=implemented hash=56c9157cb111]
public typealias ExperimentalAutomationGetInput = PromiseInputTypes.ExperimentalAutomationGetInput

// parity: client/src/promise/generated/types.ts#ExperimentalAutomationPauseInput [status=implemented hash=85d8b6f469aa]
public typealias ExperimentalAutomationPauseInput = PromiseInputTypes.ExperimentalAutomationPauseInput

// parity: client/src/promise/generated/types.ts#ExperimentalAutomationResumeInput [status=implemented hash=3598f3a993a4]
public typealias ExperimentalAutomationResumeInput = PromiseInputTypes.ExperimentalAutomationResumeInput

// parity: client/src/promise/generated/types.ts#ExperimentalAutomationDeleteInput [status=implemented hash=c7c03bc20386]
public typealias ExperimentalAutomationDeleteInput = PromiseInputTypes.ExperimentalAutomationDeleteInput

// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsProvidersInput [status=implemented hash=0f30e7b1a235]
public typealias ExperimentalArtifactsProvidersInput = PromiseInputTypes.ExperimentalArtifactsProvidersInput

// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsListInput [status=implemented hash=d05f77b70683]
public typealias ExperimentalArtifactsListInput = PromiseInputTypes.ExperimentalArtifactsListInput

// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsCreateInput [status=implemented hash=9d194c572963]
public typealias ExperimentalArtifactsCreateInput = PromiseInputTypes.ExperimentalArtifactsCreateInput

// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsGetInput [status=implemented hash=f3bccfba6cff]
public typealias ExperimentalArtifactsGetInput = PromiseInputTypes.ExperimentalArtifactsGetInput

// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsUpdateInput [status=implemented hash=7067371d42b1]
public typealias ExperimentalArtifactsUpdateInput = PromiseInputTypes.ExperimentalArtifactsUpdateInput

// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsDeleteInput [status=implemented hash=25d010391a54]
public typealias ExperimentalArtifactsDeleteInput = PromiseInputTypes.ExperimentalArtifactsDeleteInput

// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsViewInput [status=implemented hash=42209adaf8a4]
public typealias ExperimentalArtifactsViewInput = PromiseInputTypes.ExperimentalArtifactsViewInput

// parity: client/src/promise/generated/types.ts#ExperimentalJobListInput [status=implemented hash=d461e35f5368]
public typealias ExperimentalJobListInput = PromiseInputTypes.ExperimentalJobListInput

// parity: client/src/promise/generated/types.ts#ShellListInput [status=implemented hash=0f4202e34c0b]
public typealias ShellListInput = PromiseInputTypes.ShellListInput

// parity: client/src/promise/generated/types.ts#ShellCreateInput [status=implemented hash=77e9ade57618]
public typealias ShellCreateInput = PromiseInputTypes.ShellCreateInput

// parity: client/src/promise/generated/types.ts#ShellGetInput [status=implemented hash=a933b0b58741]
public typealias ShellGetInput = PromiseInputTypes.ShellGetInput

// parity: client/src/promise/generated/types.ts#ShellOutputInput [status=implemented hash=30a8032494a8]
public typealias ShellOutputInput = PromiseInputTypes.ShellOutputInput

// parity: client/src/promise/generated/types.ts#ShellRemoveInput [status=implemented hash=cbe6c406ac59]
public typealias ShellRemoveInput = PromiseInputTypes.ShellRemoveInput

// parity: client/src/promise/generated/types.ts#ReferenceListInput [status=implemented hash=b2964bce60eb]
public typealias ReferenceListInput = PromiseInputTypes.ReferenceListInput

// parity: client/src/promise/generated/types.ts#WorktreeListInput [status=implemented hash=247148991fdc]
public typealias WorktreeListInput = PromiseInputTypes.WorktreeListInput

// parity: client/src/promise/generated/types.ts#WorktreeCreateInput [status=implemented hash=6470b4617caf]
public typealias WorktreeCreateInput = PromiseInputTypes.WorktreeCreateInput

// parity: client/src/promise/generated/types.ts#WorktreeRemoveInput [status=implemented hash=c0ec9ae57cdd]
public typealias WorktreeRemoveInput = PromiseInputTypes.WorktreeRemoveInput

// parity: client/src/promise/generated/types.ts#WorktreeRefreshInput [status=implemented hash=bcb20e0d3ed2]
public typealias WorktreeRefreshInput = PromiseInputTypes.WorktreeRefreshInput

// parity: client/src/promise/generated/types.ts#VcsInitInput [status=implemented hash=2a678477d0a6]
public typealias VcsInitInput = PromiseInputTypes.VcsInitInput

// parity: client/src/promise/generated/types.ts#VcsGetInput [status=implemented hash=e23e1431598d]
public typealias VcsGetInput = PromiseInputTypes.VcsGetInput

// parity: client/src/promise/generated/types.ts#VcsBaseInput [status=implemented hash=0b75e825dc65]
public typealias VcsBaseInput = PromiseInputTypes.VcsBaseInput

// parity: client/src/promise/generated/types.ts#VcsStatusInput [status=implemented hash=b62c51f637d2]
public typealias VcsStatusInput = PromiseInputTypes.VcsStatusInput

// parity: client/src/promise/generated/types.ts#VcsBranchListInput [status=implemented hash=e804c8db0000]
public typealias VcsBranchListInput = PromiseInputTypes.VcsBranchListInput

// parity: client/src/promise/generated/types.ts#VcsDiffInput [status=implemented hash=6376d4b77b0a]
public typealias VcsDiffInput = PromiseInputTypes.VcsDiffInput

// parity: client/src/promise/generated/types.ts#DebugHeapDumpInput [status=implemented hash=efb23e8eb793]
public typealias DebugHeapDumpInput = PromiseInputTypes.DebugHeapDumpInput

// parity: client/src/promise/generated/types.ts#DebugLocationEvictInput [status=implemented hash=c134d2b85a31]
public typealias DebugLocationEvictInput = PromiseInputTypes.DebugLocationEvictInput

// parity: client/src/promise/generated/types.ts#WebsearchProvidersInput [status=implemented hash=62e5bec09693]
public typealias WebsearchProvidersInput = PromiseInputTypes.WebsearchProvidersInput

// parity: client/src/promise/generated/types.ts#WebsearchQueryInput [status=implemented hash=3d2e5ca419a6]
public typealias WebsearchQueryInput = PromiseInputTypes.WebsearchQueryInput

// parity: client/src/promise/generated/types.ts#ExperimentalUsageLimitsInput [status=implemented hash=8afd0d3bd2e3]
public typealias ExperimentalUsageLimitsInput = PromiseInputTypes.ExperimentalUsageLimitsInput

// parity: client/src/promise/generated/types.ts#ConfigGetInput [status=implemented hash=fc3e1ce3aa09]
public typealias ConfigGetInput = PromiseInputTypes.ConfigGetInput

// parity: client/src/promise/generated/types.ts#ExperimentalConfigUpdateInput [status=implemented hash=f76c1585597c]
public typealias ExperimentalConfigUpdateInput = PromiseInputTypes.ExperimentalConfigUpdateInput

// parity: client/src/promise/generated/types.ts#SessionStatsInput [status=implemented hash=ca109da1d0f1]
public typealias SessionStatsInput = ExperimentalSessionStatsInput

// parity: client/src/promise/generated/types.ts#SessionImportInput [status=implemented hash=bfa36f7d9cdb]
public typealias SessionImportInput = ExperimentalSessionImportInput

// parity: client/src/promise/generated/types.ts#SessionExportInput [status=implemented hash=62b5aa8da161]
public typealias SessionExportInput = ExperimentalSessionExportInput

// parity: client/src/promise/generated/types.ts#SessionSkillInput [status=implemented hash=3c6c5dccfd60]
public typealias SessionSkillInput = ExperimentalSessionSkillInput

// parity: client/src/promise/generated/types.ts#SessionWaitInput [status=implemented hash=a84b4df3a46a]
public typealias SessionWaitInput = ExperimentalSessionWaitInput

// parity: client/src/promise/generated/types.ts#SessionInstructionsEntryListInput [status=implemented hash=456a71115197]
public typealias SessionInstructionsEntryListInput = ExperimentalSessionInstructionsEntryListInput

// parity: client/src/promise/generated/types.ts#SessionInstructionsEntryPutInput [status=implemented hash=df593fb00c6f]
public typealias SessionInstructionsEntryPutInput = ExperimentalSessionInstructionsEntryPutInput

// parity: client/src/promise/generated/types.ts#SessionInstructionsEntryRemoveInput [status=implemented hash=e888c2ce0afb]
public typealias SessionInstructionsEntryRemoveInput = ExperimentalSessionInstructionsEntryRemoveInput

// parity: client/src/promise/generated/types.ts#SessionLogInput [status=implemented hash=9d5c6bdab31d]
public typealias SessionLogInput = ExperimentalSessionLogInput

// parity: client/src/promise/generated/types.ts#GenerateTextInput [status=implemented hash=37482ee578b6]
public typealias GenerateTextInput = ExperimentalGenerateTextInput

// parity: client/src/promise/generated/types.ts#GenerateImageInput [status=implemented hash=98114963a2c4]
public typealias GenerateImageInput = ExperimentalGenerateImageInput

// parity: client/src/promise/generated/types.ts#GenerateDecisionsInput [status=implemented hash=97e22369b832]
public typealias GenerateDecisionsInput = ExperimentalGenerateDecisionsInput

// parity: client/src/promise/generated/types.ts#VoiceSessionInput [status=implemented hash=90a301331405]
public typealias VoiceSessionInput = ExperimentalVoiceSessionInput

// parity: client/src/promise/generated/types.ts#IntegrationWellknownAddInput [status=implemented hash=bd0d1f3b7ff1]
public typealias IntegrationWellknownAddInput = ExperimentalIntegrationWellknownAddInput

// parity: client/src/promise/generated/types.ts#McpAddInput [status=implemented hash=65d020477b21]
public typealias McpAddInput = ExperimentalMcpAddInput

// parity: client/src/promise/generated/types.ts#McpRemoveInput [status=implemented hash=60e08ac489eb]
public typealias McpRemoveInput = ExperimentalMcpRemoveInput

// parity: client/src/promise/generated/types.ts#McpConnectInput [status=implemented hash=a786fa4ec762]
public typealias McpConnectInput = ExperimentalMcpConnectInput

// parity: client/src/promise/generated/types.ts#McpDisconnectInput [status=implemented hash=33b8b49139ed]
public typealias McpDisconnectInput = ExperimentalMcpDisconnectInput

// parity: client/src/promise/generated/types.ts#McpClientTokenInput [status=implemented hash=72c03eb2193e]
public typealias McpClientTokenInput = ExperimentalMcpClientTokenInput

// parity: client/src/promise/generated/types.ts#FileWriteInput [status=implemented hash=25afa116b513]
public typealias FileWriteInput = ExperimentalFileWriteInput

// parity: client/src/promise/generated/types.ts#FileWatchInput [status=implemented hash=4f5e177feea0]
public typealias FileWatchInput = ExperimentalFileWatchInput

// parity: client/src/promise/generated/types.ts#FileUnwatchInput [status=implemented hash=7c3e8ca6528b]
public typealias FileUnwatchInput = ExperimentalFileUnwatchInput

// parity: client/src/promise/generated/types.ts#UsageLimitsInput [status=implemented hash=a041dbc41a16]
public typealias UsageLimitsInput = ExperimentalUsageLimitsInput

// parity: client/src/promise/generated/types.ts#ConfigUpdateInput [status=implemented hash=85fd8eb4cf7f]
public typealias ConfigUpdateInput = ExperimentalConfigUpdateInput

// MARK: - Typed Endpoint Output Aliases (packages/client/src/promise/generated/types.ts)

// parity: client/src/promise/generated/types.ts#ServerInfoOutput [status=implemented hash=a2837b8d5f91]
public typealias ServerInfoOutput = OpenCodeProtocol.ServerInfo
// parity: client/src/promise/generated/types.ts#ServerPairOutput [status=implemented hash=c9b4efaad821]
public typealias ServerPairOutput = OpenCodeProtocol.PairingCode
// parity: client/src/promise/generated/types.ts#ServerConnectOutput [status=implemented hash=2aa7d6480429]
public typealias ServerConnectOutput = OpenCodeProtocol.PairingSession
// parity: client/src/promise/generated/types.ts#LocationGetOutput [status=implemented hash=da98ef082780]
public typealias LocationGetOutput = LocationSchema.PublicInfo
// parity: client/src/promise/generated/types.ts#LocationReloadOutput [status=implemented hash=eac2db1bde1e]
public typealias LocationReloadOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#AgentListOutput [status=implemented hash=01e52ada006f]
public typealias AgentListOutput = LocationSchema.ResponseEnvelope<[AgentSchema.Info]>
// parity: client/src/promise/generated/types.ts#AgentGetOutput [status=implemented hash=d010d2a4ed3c]
public typealias AgentGetOutput = LocationSchema.ResponseEnvelope<AgentSchema.Info>
// parity: client/src/promise/generated/types.ts#PluginListOutput [status=implemented hash=f07e359ef65f]
public typealias PluginListOutput = LocationSchema.ResponseEnvelope<[PluginSchema.Info]>
// parity: client/src/promise/generated/types.ts#PluginGuiOutput [status=implemented hash=942a9a46b180]
public typealias PluginGuiOutput = LocationSchema.ResponseEnvelope<PluginSchema.GuiBundle>
// parity: client/src/promise/generated/types.ts#PluginCheckOutput [status=implemented hash=80a5d214b34b]
public typealias PluginCheckOutput = LocationSchema.ResponseEnvelope<[PluginSchema.Info]>
// parity: client/src/promise/generated/types.ts#PluginUpdateOutput [status=implemented hash=6f940937aee3]
public typealias PluginUpdateOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionListOutput [status=implemented hash=4386cadc923d]
public typealias SessionListOutput = SessionsResponse
// parity: client/src/promise/generated/types.ts#SessionCreateOutput [status=implemented hash=9de8114c7144]
public typealias SessionCreateOutput = SessionSchema.Info
// parity: client/src/promise/generated/types.ts#SessionActiveOutput [status=implemented hash=1469f55000e2]
public typealias SessionActiveOutput = [String: SessionActiveInfo]
// parity: client/src/promise/generated/types.ts#SessionGetOutput [status=implemented hash=58aeaf67e3ff]
public typealias SessionGetOutput = SessionSchema.Info
// parity: client/src/promise/generated/types.ts#SessionRemoveOutput [status=implemented hash=8038c7096a55]
public typealias SessionRemoveOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionForkOutput [status=implemented hash=d71684836bf4]
public typealias SessionForkOutput = SessionSchema.Info
// parity: client/src/promise/generated/types.ts#SessionSwitchAgentOutput [status=implemented hash=b21348f24be3]
public typealias SessionSwitchAgentOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionSwitchModelOutput [status=implemented hash=f73e822e676a]
public typealias SessionSwitchModelOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionUpdateOutput [status=implemented hash=8e7a21586d2f]
public typealias SessionUpdateOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionMoveOutput [status=implemented hash=3e397844fd81]
public typealias SessionMoveOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionPromptOutput [status=implemented hash=44825e465352]
public typealias SessionPromptOutput = SessionInboxSchema.User
// parity: client/src/promise/generated/types.ts#SessionCommandOutput [status=implemented hash=b64a45dfdb63]
public typealias SessionCommandOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionSyntheticOutput [status=implemented hash=74c840873c94]
public typealias SessionSyntheticOutput = SessionInboxSchema.Synthetic
// parity: client/src/promise/generated/types.ts#SessionShellOutput [status=implemented hash=59b22dc80787]
public typealias SessionShellOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionCompactOutput [status=implemented hash=59bfef5753da]
public typealias SessionCompactOutput = SessionInboxSchema.Compaction
// parity: client/src/promise/generated/types.ts#SessionRevertStageOutput [status=implemented hash=0bbc3b68706b]
public typealias SessionRevertStageOutput = SessionRevertSchema.Revert
// parity: client/src/promise/generated/types.ts#SessionRevertClearOutput [status=implemented hash=4bfe23826bc6]
public typealias SessionRevertClearOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionRevertCommitOutput [status=implemented hash=e586e6dc58aa]
public typealias SessionRevertCommitOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionContextOutput [status=implemented hash=0bea7f589809]
public typealias SessionContextOutput = [SessionMessageSchema.Info]
// parity: client/src/promise/generated/types.ts#SessionDiffOutput [status=implemented hash=6eb7f51d9030]
public typealias SessionDiffOutput = [FileDiffSchema.Info]
// parity: client/src/promise/generated/types.ts#SessionInboxListOutput [status=implemented hash=3d7d935f3311]
public typealias SessionInboxListOutput = [SessionInboxSchema.Info]
// parity: client/src/promise/generated/types.ts#SessionInboxCancelOutput [status=implemented hash=8af65ea26464]
public typealias SessionInboxCancelOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionInboxUpdateOutput [status=implemented hash=fca13c4e81b8]
public typealias SessionInboxUpdateOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionGenerateOutput [status=implemented hash=61e60995a12a]
public typealias SessionGenerateOutput = SessionGenerateData
// parity: client/src/promise/generated/types.ts#SessionInterruptOutput [status=implemented hash=d07230e1f0f0]
public typealias SessionInterruptOutput = SessionInterruptResponse
// parity: client/src/promise/generated/types.ts#SessionBackgroundOutput [status=implemented hash=6878a2fc8282]
public typealias SessionBackgroundOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionMessageGetOutput [status=implemented hash=dd6cf147e6f5]
public typealias SessionMessageGetOutput = SessionMessageSchema.Info
// parity: client/src/promise/generated/types.ts#SessionFormListOutput [status=implemented hash=ecc8754355a1]
public typealias SessionFormListOutput = [FormSchema.Info]
// parity: client/src/promise/generated/types.ts#SessionFormCreateOutput [status=implemented hash=8e05c50697f9]
public typealias SessionFormCreateOutput = FormSchema.Info
// parity: client/src/promise/generated/types.ts#SessionFormGetOutput [status=implemented hash=1bd6be8fa2e5]
public typealias SessionFormGetOutput = FormSchema.Detail
// parity: client/src/promise/generated/types.ts#SessionFormReplyOutput [status=implemented hash=aeecdb5453da]
public typealias SessionFormReplyOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionFormCancelOutput [status=implemented hash=8e73ab8e4a8d]
public typealias SessionFormCancelOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionEnvironmentOutput [status=implemented hash=b79c043837ca]
public typealias SessionEnvironmentOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionViewOutput [status=implemented hash=5f0a83819bc8]
public typealias SessionViewOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalSessionStatsOutput [status=implemented hash=6266ceb04039]
public typealias ExperimentalSessionStatsOutput = SessionStatsSchema.Info
// parity: client/src/promise/generated/types.ts#ExperimentalSessionImportOutput [status=implemented hash=7d337451acab]
public typealias ExperimentalSessionImportOutput = SessionSchema.Info
// parity: client/src/promise/generated/types.ts#ExperimentalSessionExportOutput [status=implemented hash=beb63f18723f]
public typealias ExperimentalSessionExportOutput = SessionTransferSchema.Data
// parity: client/src/promise/generated/types.ts#ExperimentalSessionSkillOutput [status=implemented hash=78154ad9c13f]
public typealias ExperimentalSessionSkillOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalSessionWaitOutput [status=implemented hash=4ca37a946fe7]
public typealias ExperimentalSessionWaitOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalSessionInstructionsEntryListOutput [status=implemented hash=b848c8c0e6ca]
public typealias ExperimentalSessionInstructionsEntryListOutput = [InstructionEntrySchema.Info]
// parity: client/src/promise/generated/types.ts#ExperimentalSessionInstructionsEntryPutOutput [status=implemented hash=954343fc987a]
public typealias ExperimentalSessionInstructionsEntryPutOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalSessionInstructionsEntryRemoveOutput [status=implemented hash=7f2912f05045]
public typealias ExperimentalSessionInstructionsEntryRemoveOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalSessionLogOutput [status=implemented hash=204a7396ce4a]
public typealias ExperimentalSessionLogOutput = SessionLogItem
// parity: client/src/promise/generated/types.ts#MessageListOutput [status=implemented hash=0a07498916b8]
public typealias MessageListOutput = SessionMessagesResponse
// parity: client/src/promise/generated/types.ts#ModelListOutput [status=implemented hash=7a6a6a97a237]
public typealias ModelListOutput = LocationSchema.ResponseEnvelope<[ModelSchema.Info]>
// parity: client/src/promise/generated/types.ts#ModelDefaultOutput [status=implemented hash=0dbfb8521578]
public typealias ModelDefaultOutput = LocationSchema.ResponseEnvelope<ModelSchema.Info?>
// parity: client/src/promise/generated/types.ts#ExperimentalGenerateTextOutput [status=implemented hash=e35df8db09d9]
public typealias ExperimentalGenerateTextOutput = GenerateTextData
// parity: client/src/promise/generated/types.ts#ExperimentalGenerateImageOutput [status=implemented hash=4071f52ef111]
public typealias ExperimentalGenerateImageOutput = GenerateSchema.ImageResult
// parity: client/src/promise/generated/types.ts#ExperimentalGenerateVideoCreateOutput [status=implemented hash=318146046d86]
public typealias ExperimentalGenerateVideoCreateOutput = GenerateSchema.VideoRunning
// parity: client/src/promise/generated/types.ts#ExperimentalGenerateVideoGetOutput [status=implemented hash=62328b20ca24]
public typealias ExperimentalGenerateVideoGetOutput = GenerateSchema.VideoJob
// parity: client/src/promise/generated/types.ts#ExperimentalGenerateDecisionsOutput [status=implemented hash=c2c60f8d0cfa]
public typealias ExperimentalGenerateDecisionsOutput = GenerateSchema.DecisionResult
// parity: client/src/promise/generated/types.ts#ExperimentalVoiceModelsOutput [status=implemented hash=b22ac14b7def]
public typealias ExperimentalVoiceModelsOutput = VoiceModelsData
// parity: client/src/promise/generated/types.ts#ExperimentalVoiceSessionOutput [status=implemented hash=63cf22c3eeb0]
public typealias ExperimentalVoiceSessionOutput = VoiceSessionData
// parity: client/src/promise/generated/types.ts#ProviderListOutput [status=implemented hash=95a42e5920ea]
public typealias ProviderListOutput = LocationSchema.ResponseEnvelope<[ProviderSchema.Info]>
// parity: client/src/promise/generated/types.ts#ProviderGetOutput [status=implemented hash=4094473e1d2d]
public typealias ProviderGetOutput = LocationSchema.ResponseEnvelope<ProviderSchema.Info>
// parity: client/src/promise/generated/types.ts#IntegrationListOutput [status=implemented hash=ee9815d37b73]
public typealias IntegrationListOutput = LocationSchema.ResponseEnvelope<[IntegrationSchema.Info]>
// parity: client/src/promise/generated/types.ts#IntegrationGetOutput [status=implemented hash=2b0d67a106f4]
public typealias IntegrationGetOutput = LocationSchema.ResponseEnvelope<IntegrationSchema.Info>
// parity: client/src/promise/generated/types.ts#IntegrationConnectKeyOutput [status=implemented hash=77c286d598c7]
public typealias IntegrationConnectKeyOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#IntegrationConnectExternalOutput [status=implemented hash=dc50893ea51b]
public typealias IntegrationConnectExternalOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#IntegrationOauthConnectOutput [status=implemented hash=a67df9c47c6e]
public typealias IntegrationOauthConnectOutput = LocationSchema.ResponseEnvelope<IntegrationSchema.Attempt>
// parity: client/src/promise/generated/types.ts#IntegrationOauthStatusOutput [status=implemented hash=68ad47ec1381]
public typealias IntegrationOauthStatusOutput = LocationSchema.ResponseEnvelope<IntegrationSchema.AttemptStatus>
// parity: client/src/promise/generated/types.ts#IntegrationOauthCompleteOutput [status=implemented hash=99245919a1bc]
public typealias IntegrationOauthCompleteOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#IntegrationOauthCancelOutput [status=implemented hash=c6dd621ffe93]
public typealias IntegrationOauthCancelOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#IntegrationCommandConnectOutput [status=implemented hash=f0e74c66396b]
public typealias IntegrationCommandConnectOutput = LocationSchema.ResponseEnvelope<IntegrationSchema.CommandAttempt>
// parity: client/src/promise/generated/types.ts#IntegrationCommandStatusOutput [status=implemented hash=4f441ab8c0a3]
public typealias IntegrationCommandStatusOutput = LocationSchema.ResponseEnvelope<IntegrationSchema.CommandAttemptStatus>
// parity: client/src/promise/generated/types.ts#IntegrationCommandCancelOutput [status=implemented hash=2d1fc9ce7d1e]
public typealias IntegrationCommandCancelOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalIntegrationWellknownAddOutput [status=implemented hash=6f9be466c897]
public typealias ExperimentalIntegrationWellknownAddOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#McpListOutput [status=implemented hash=78ab5c85d0c4]
public typealias McpListOutput = LocationSchema.ResponseEnvelope<[McpSchema.Server]>
// parity: client/src/promise/generated/types.ts#McpResourceCatalogOutput [status=implemented hash=5fe61cbd9478]
public typealias McpResourceCatalogOutput = LocationSchema.ResponseEnvelope<McpSchema.ResourceCatalog>
// parity: client/src/promise/generated/types.ts#ExperimentalMcpAddOutput [status=implemented hash=4428b0cb8a44]
public typealias ExperimentalMcpAddOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalMcpRemoveOutput [status=implemented hash=04f374c35d74]
public typealias ExperimentalMcpRemoveOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalMcpConnectOutput [status=implemented hash=606cc95e3f78]
public typealias ExperimentalMcpConnectOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalMcpDisconnectOutput [status=implemented hash=004f983716b2]
public typealias ExperimentalMcpDisconnectOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalMcpClientTokenOutput [status=implemented hash=c57f4d66c544]
public typealias ExperimentalMcpClientTokenOutput = LocationSchema.ResponseEnvelope<PtyTicketSchema.ConnectToken>
// parity: client/src/promise/generated/types.ts#CredentialListOutput [status=implemented hash=55db2375c8b9]
public typealias CredentialListOutput = [CredentialSchema.Entry]
// parity: client/src/promise/generated/types.ts#CredentialCreateOutput [status=implemented hash=687fbf5ab902]
public typealias CredentialCreateOutput = CredentialSchema.Entry
// parity: client/src/promise/generated/types.ts#CredentialUpdateOutput [status=implemented hash=17fc4f325ba3]
public typealias CredentialUpdateOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#CredentialActivateOutput [status=implemented hash=10915d5132db]
public typealias CredentialActivateOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#CredentialRemoveOutput [status=implemented hash=2ad933097940]
public typealias CredentialRemoveOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ProjectListOutput [status=implemented hash=f6d2a221b280]
public typealias ProjectListOutput = [ProjectSchema.Info]
// parity: client/src/promise/generated/types.ts#ProjectUpdateOutput [status=implemented hash=4adedffa7c1f]
public typealias ProjectUpdateOutput = ProjectSchema.Info
// parity: client/src/promise/generated/types.ts#FormListOutput [status=implemented hash=5a9ffd7b5219]
public typealias FormListOutput = LocationSchema.ResponseEnvelope<[FormSchema.Info]>
// parity: client/src/promise/generated/types.ts#PermissionRequestListOutput [status=implemented hash=5254dfd99eca]
public typealias PermissionRequestListOutput = LocationSchema.ResponseEnvelope<[PermissionSchema.Request]>
// parity: client/src/promise/generated/types.ts#PermissionSavedListOutput [status=implemented hash=3f38edee58bc]
public typealias PermissionSavedListOutput = [PermissionSavedSchema.Info]
// parity: client/src/promise/generated/types.ts#PermissionSavedUpdateOutput [status=implemented hash=fd8598d966da]
public typealias PermissionSavedUpdateOutput = PermissionSavedSchema.Info
// parity: client/src/promise/generated/types.ts#PermissionSavedRemoveOutput [status=implemented hash=9b7a3c824f8a]
public typealias PermissionSavedRemoveOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#PermissionCreateOutput [status=implemented hash=6e26669dac72]
public typealias PermissionCreateOutput = PermissionCreateData
// parity: client/src/promise/generated/types.ts#PermissionListOutput [status=implemented hash=1bdd60e11aab]
public typealias PermissionListOutput = [PermissionSchema.Request]
// parity: client/src/promise/generated/types.ts#PermissionGetOutput [status=implemented hash=a811819d1d18]
public typealias PermissionGetOutput = PermissionSchema.Request
// parity: client/src/promise/generated/types.ts#PermissionReplyOutput [status=implemented hash=1679a38c440e]
public typealias PermissionReplyOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#FileReadOutput [status=implemented hash=a3f28e098803]
public typealias FileReadOutput = [UInt8]
// parity: client/src/promise/generated/types.ts#FileListOutput [status=implemented hash=3b5c36c4216a]
public typealias FileListOutput = LocationSchema.ResponseEnvelope<[FileSystemSchema.Entry]>
// parity: client/src/promise/generated/types.ts#FileFindOutput [status=implemented hash=b609e892cf7e]
public typealias FileFindOutput = LocationSchema.ResponseEnvelope<[FileSystemSchema.Entry]>
// parity: client/src/promise/generated/types.ts#ExperimentalFileWriteOutput [status=implemented hash=4d4c9be51faa]
public typealias ExperimentalFileWriteOutput = LocationSchema.ResponseEnvelope<FileSystemSchema.Write>
// parity: client/src/promise/generated/types.ts#ExperimentalFileWatchOutput [status=implemented hash=49ad0fa5515b]
public typealias ExperimentalFileWatchOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalFileUnwatchOutput [status=implemented hash=7cd54268a93a]
public typealias ExperimentalFileUnwatchOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#CommandListOutput [status=implemented hash=17a998f9646c]
public typealias CommandListOutput = LocationSchema.ResponseEnvelope<[CommandSchema.Info]>
// parity: client/src/promise/generated/types.ts#SkillListOutput [status=implemented hash=f3c9da61644c]
public typealias SkillListOutput = LocationSchema.ResponseEnvelope<[SkillSchema.Info]>
// parity: client/src/promise/generated/types.ts#RpcCallOutput [status=implemented hash=acec71431aff]
public typealias RpcCallOutput = OpenCodeProtocol.RpcOutput
// parity: client/src/promise/generated/types.ts#EventSubscribeOutput [status=implemented hash=927fe2e0bdf1]
public typealias EventSubscribeOutput = OpenCodeProtocol.OpenCodeEvent
// parity: client/src/promise/generated/types.ts#PtyListOutput [status=implemented hash=93216fb5690f]
public typealias PtyListOutput = LocationSchema.ResponseEnvelope<[PtySchema.Info]>
// parity: client/src/promise/generated/types.ts#PtyCreateOutput [status=implemented hash=6ad2cd0e295d]
public typealias PtyCreateOutput = LocationSchema.ResponseEnvelope<PtySchema.Info>
// parity: client/src/promise/generated/types.ts#PtyGetOutput [status=implemented hash=144ea46bd173]
public typealias PtyGetOutput = LocationSchema.ResponseEnvelope<PtySchema.Info>
// parity: client/src/promise/generated/types.ts#PtyUpdateOutput [status=implemented hash=692941d623fc]
public typealias PtyUpdateOutput = LocationSchema.ResponseEnvelope<PtySchema.Info>
// parity: client/src/promise/generated/types.ts#PtyRemoveOutput [status=implemented hash=f1f92da4a1a0]
public typealias PtyRemoveOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#PtyConnectTokenOutput [status=implemented hash=3c4e759c0651]
public typealias PtyConnectTokenOutput = LocationSchema.ResponseEnvelope<PtyTicketSchema.ConnectToken>
// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyReadOutput [status=implemented hash=1fd48bbb5feb]
public typealias ExperimentalPersistentPtyReadOutput = PersistentPtySchema.ReadResult?
// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyListOutput [status=implemented hash=852f71c27bf7]
public typealias ExperimentalPersistentPtyListOutput = [PersistentPtySchema.Info]
// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyCreateOutput [status=implemented hash=d500a84b8a51]
public typealias ExperimentalPersistentPtyCreateOutput = PersistentPtySchema.Info
// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyShutdownOutput [status=implemented hash=1ed23324ee74]
public typealias ExperimentalPersistentPtyShutdownOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyHandoffOutput [status=implemented hash=70b8ce6e4987]
public typealias ExperimentalPersistentPtyHandoffOutput = PersistentPtyHandoffResponse
// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyGetOutput [status=implemented hash=c17e868e896b]
public typealias ExperimentalPersistentPtyGetOutput = PersistentPtySchema.Info
// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyUpdateOutput [status=implemented hash=e50742343bfd]
public typealias ExperimentalPersistentPtyUpdateOutput = PersistentPtySchema.Info
// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtySnapshotOutput [status=implemented hash=420d57407690]
public typealias ExperimentalPersistentPtySnapshotOutput = PersistentPtySchema.Snapshot
// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyRemoveOutput [status=implemented hash=99f675ad905c]
public typealias ExperimentalPersistentPtyRemoveOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalPersistentPtyConnectTokenOutput [status=implemented hash=e2e9f8cc9e79]
public typealias ExperimentalPersistentPtyConnectTokenOutput = PtyTicketSchema.ConnectToken
// parity: client/src/promise/generated/types.ts#ExperimentalMediaGetOutput [status=implemented hash=fb2591276869]
public typealias ExperimentalMediaGetOutput = [UInt8]
// parity: client/src/promise/generated/types.ts#ExperimentalBlobGetOutput [status=implemented hash=615d33028afd]
public typealias ExperimentalBlobGetOutput = [UInt8]
// parity: client/src/promise/generated/types.ts#ExperimentalAutomationCreateOutput [status=implemented hash=cdfc44ee0c25]
public typealias ExperimentalAutomationCreateOutput = AutomationSchema.Info
// parity: client/src/promise/generated/types.ts#ExperimentalAutomationListOutput [status=implemented hash=44ad268d9a0b]
public typealias ExperimentalAutomationListOutput = [AutomationSchema.Info]
// parity: client/src/promise/generated/types.ts#ExperimentalAutomationGetOutput [status=implemented hash=2ed2e3dc01ba]
public typealias ExperimentalAutomationGetOutput = AutomationSchema.Info
// parity: client/src/promise/generated/types.ts#ExperimentalAutomationPauseOutput [status=implemented hash=78bbfc01c570]
public typealias ExperimentalAutomationPauseOutput = AutomationSchema.Info
// parity: client/src/promise/generated/types.ts#ExperimentalAutomationResumeOutput [status=implemented hash=ca375fd27ec8]
public typealias ExperimentalAutomationResumeOutput = AutomationSchema.Info
// parity: client/src/promise/generated/types.ts#ExperimentalAutomationDeleteOutput [status=implemented hash=38103a7850e7]
public typealias ExperimentalAutomationDeleteOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsProvidersOutput [status=implemented hash=40371ef85d99]
public typealias ExperimentalArtifactsProvidersOutput = LocationSchema.ResponseEnvelope<[ArtifactSchema.Provider]>
// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsListOutput [status=implemented hash=d7a4e2726139]
public typealias ExperimentalArtifactsListOutput = LocationSchema.ResponseEnvelope<[ArtifactSchema.Info]>
// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsCreateOutput [status=implemented hash=445e4a7bcc95]
public typealias ExperimentalArtifactsCreateOutput = LocationSchema.ResponseEnvelope<ArtifactSchema.Info>
// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsGetOutput [status=implemented hash=a04f2d5b15d2]
public typealias ExperimentalArtifactsGetOutput = LocationSchema.ResponseEnvelope<ArtifactSchema.Content>
// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsUpdateOutput [status=implemented hash=5dadbdbb38de]
public typealias ExperimentalArtifactsUpdateOutput = LocationSchema.ResponseEnvelope<ArtifactSchema.Info>
// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsDeleteOutput [status=implemented hash=ea2d2a926f2a]
public typealias ExperimentalArtifactsDeleteOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalArtifactsViewOutput [status=implemented hash=287f0790c515]
public typealias ExperimentalArtifactsViewOutput = [UInt8]
// parity: client/src/promise/generated/types.ts#ExperimentalJobListOutput [status=implemented hash=37262703c7fe]
public typealias ExperimentalJobListOutput = [JobSchema.Info]
// parity: client/src/promise/generated/types.ts#ShellListOutput [status=implemented hash=9f02098b2780]
public typealias ShellListOutput = LocationSchema.ResponseEnvelope<[ShellSchema.Info]>
// parity: client/src/promise/generated/types.ts#ShellCreateOutput [status=implemented hash=4b12e27a5e68]
public typealias ShellCreateOutput = LocationSchema.ResponseEnvelope<ShellSchema.Info>
// parity: client/src/promise/generated/types.ts#ShellGetOutput [status=implemented hash=0f10403e02e9]
public typealias ShellGetOutput = LocationSchema.ResponseEnvelope<ShellSchema.Info>
// parity: client/src/promise/generated/types.ts#ShellOutputOutput [status=implemented hash=460f022e6b06]
public typealias ShellOutputOutput = LocationSchema.ResponseEnvelope<ShellSchema.Output>
// parity: client/src/promise/generated/types.ts#ShellRemoveOutput [status=implemented hash=1053fd9901a5]
public typealias ShellRemoveOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ReferenceListOutput [status=implemented hash=8379a2be7789]
public typealias ReferenceListOutput = LocationSchema.ResponseEnvelope<[ReferenceSchema.Info]>
// parity: client/src/promise/generated/types.ts#WorktreeListOutput [status=implemented hash=6592feb26132]
public typealias WorktreeListOutput = WorktreeSchema.List
// parity: client/src/promise/generated/types.ts#WorktreeCreateOutput [status=implemented hash=7738d125922c]
public typealias WorktreeCreateOutput = WorktreeSchema.Info
// parity: client/src/promise/generated/types.ts#WorktreeRemoveOutput [status=implemented hash=966327baf5eb]
public typealias WorktreeRemoveOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#WorktreeRefreshOutput [status=implemented hash=6e99b77c3972]
public typealias WorktreeRefreshOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#VcsInitOutput [status=implemented hash=118154a31976]
public typealias VcsInitOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#VcsGetOutput [status=implemented hash=905b9af8bc4e]
public typealias VcsGetOutput = LocationSchema.ResponseEnvelope<VcsSchema.Info>
// parity: client/src/promise/generated/types.ts#VcsBaseOutput [status=implemented hash=2642085a8941]
public typealias VcsBaseOutput = LocationSchema.ResponseEnvelope<VcsSchema.Base?>
// parity: client/src/promise/generated/types.ts#VcsStatusOutput [status=implemented hash=ac66992d705f]
public typealias VcsStatusOutput = LocationSchema.ResponseEnvelope<[VcsSchema.FileStatus]>
// parity: client/src/promise/generated/types.ts#VcsBranchListOutput [status=implemented hash=1854ae52c75c]
public typealias VcsBranchListOutput = LocationSchema.ResponseEnvelope<VcsSchema.BranchList>
// parity: client/src/promise/generated/types.ts#VcsDiffOutput [status=implemented hash=db1e956a798c]
public typealias VcsDiffOutput = LocationSchema.ResponseEnvelope<[FileDiffSchema.Info]>
// parity: client/src/promise/generated/types.ts#DebugLocationListOutput [status=implemented hash=532add9b07db]
public typealias DebugLocationListOutput = [LocationSchema.PublicRef]
// parity: client/src/promise/generated/types.ts#DebugLocationEvictOutput [status=implemented hash=430ec551a4b9]
public typealias DebugLocationEvictOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#ExperimentalMigrationV1StatusOutput [status=implemented hash=caa2f54ddcc8]
public typealias ExperimentalMigrationV1StatusOutput = OpenCodeProtocol.V1MigrationStatus
// parity: client/src/promise/generated/types.ts#WebsearchProvidersOutput [status=implemented hash=f82d597cfc08]
public typealias WebsearchProvidersOutput = LocationSchema.ResponseEnvelope<[WebSearchSchema.Provider]>
// parity: client/src/promise/generated/types.ts#WebsearchQueryOutput [status=implemented hash=f541bb3caf22]
public typealias WebsearchQueryOutput = LocationSchema.ResponseEnvelope<WebSearchSchema.Response>
// parity: client/src/promise/generated/types.ts#ExperimentalUsageLimitsOutput [status=implemented hash=1dbf393cfd05]
public typealias ExperimentalUsageLimitsOutput = LocationSchema.ResponseEnvelope<UsageLimitsSchema.Info?>
// parity: client/src/promise/generated/types.ts#ConfigGetOutput [status=implemented hash=0adb7aa8cd60]
public typealias ConfigGetOutput = [ConfigSchema.Entry]
// parity: client/src/promise/generated/types.ts#ConfigShellsOutput [status=implemented hash=1046537cd4bf]
public typealias ConfigShellsOutput = [ConfigShellSchema.Option]
// parity: client/src/promise/generated/types.ts#ExperimentalConfigUpdateOutput [status=implemented hash=69978ae170aa]
public typealias ExperimentalConfigUpdateOutput = ClientEmptyResponse
// parity: client/src/promise/generated/types.ts#SessionStatsOutput [status=implemented hash=d9add1c87473]
public typealias SessionStatsOutput = ExperimentalSessionStatsOutput
// parity: client/src/promise/generated/types.ts#SessionImportOutput [status=implemented hash=73fe60d36bba]
public typealias SessionImportOutput = ExperimentalSessionImportOutput
// parity: client/src/promise/generated/types.ts#SessionExportOutput [status=implemented hash=581bfa49f395]
public typealias SessionExportOutput = ExperimentalSessionExportOutput
// parity: client/src/promise/generated/types.ts#SessionSkillOutput [status=implemented hash=109b36cf99bc]
public typealias SessionSkillOutput = ExperimentalSessionSkillOutput
// parity: client/src/promise/generated/types.ts#SessionWaitOutput [status=implemented hash=3012cd2a68c1]
public typealias SessionWaitOutput = ExperimentalSessionWaitOutput
// parity: client/src/promise/generated/types.ts#SessionInstructionsEntryListOutput [status=implemented hash=8b4ec764ec8d]
public typealias SessionInstructionsEntryListOutput = ExperimentalSessionInstructionsEntryListOutput
// parity: client/src/promise/generated/types.ts#SessionInstructionsEntryPutOutput [status=implemented hash=c113ec309111]
public typealias SessionInstructionsEntryPutOutput = ExperimentalSessionInstructionsEntryPutOutput
// parity: client/src/promise/generated/types.ts#SessionInstructionsEntryRemoveOutput [status=implemented hash=4d3f1cdf36a8]
public typealias SessionInstructionsEntryRemoveOutput = ExperimentalSessionInstructionsEntryRemoveOutput
// parity: client/src/promise/generated/types.ts#SessionLogOutput [status=implemented hash=23e7ac761662]
public typealias SessionLogOutput = ExperimentalSessionLogOutput
// parity: client/src/promise/generated/types.ts#GenerateTextOutput [status=implemented hash=5bca7198e6cf]
public typealias GenerateTextOutput = ExperimentalGenerateTextOutput
// parity: client/src/promise/generated/types.ts#GenerateImageOutput [status=implemented hash=f3902e2a6652]
public typealias GenerateImageOutput = ExperimentalGenerateImageOutput
// parity: client/src/promise/generated/types.ts#GenerateDecisionsOutput [status=implemented hash=b6ada0a6ebee]
public typealias GenerateDecisionsOutput = ExperimentalGenerateDecisionsOutput
// parity: client/src/promise/generated/types.ts#VoiceModelsOutput [status=implemented hash=bf14a42fcc9b]
public typealias VoiceModelsOutput = ExperimentalVoiceModelsOutput
// parity: client/src/promise/generated/types.ts#VoiceSessionOutput [status=implemented hash=5aeaaa02d555]
public typealias VoiceSessionOutput = ExperimentalVoiceSessionOutput
// parity: client/src/promise/generated/types.ts#IntegrationWellknownAddOutput [status=implemented hash=71fb0d519592]
public typealias IntegrationWellknownAddOutput = ExperimentalIntegrationWellknownAddOutput
// parity: client/src/promise/generated/types.ts#McpAddOutput [status=implemented hash=5313048d621e]
public typealias McpAddOutput = ExperimentalMcpAddOutput
// parity: client/src/promise/generated/types.ts#McpRemoveOutput [status=implemented hash=59e51c51ef99]
public typealias McpRemoveOutput = ExperimentalMcpRemoveOutput
// parity: client/src/promise/generated/types.ts#McpConnectOutput [status=implemented hash=11efda9e9c7c]
public typealias McpConnectOutput = ExperimentalMcpConnectOutput
// parity: client/src/promise/generated/types.ts#McpDisconnectOutput [status=implemented hash=0001b08238ff]
public typealias McpDisconnectOutput = ExperimentalMcpDisconnectOutput
// parity: client/src/promise/generated/types.ts#McpClientTokenOutput [status=implemented hash=600dc060da80]
public typealias McpClientTokenOutput = ExperimentalMcpClientTokenOutput
// parity: client/src/promise/generated/types.ts#FileWriteOutput [status=implemented hash=c8cd2153a1e0]
public typealias FileWriteOutput = ExperimentalFileWriteOutput
// parity: client/src/promise/generated/types.ts#FileWatchOutput [status=implemented hash=31be68d703e6]
public typealias FileWatchOutput = ExperimentalFileWatchOutput
// parity: client/src/promise/generated/types.ts#FileUnwatchOutput [status=implemented hash=67fb6949c0ed]
public typealias FileUnwatchOutput = ExperimentalFileUnwatchOutput
// parity: client/src/promise/generated/types.ts#MigrationV1StatusOutput [status=implemented hash=2fabfaab8ff4]
public typealias MigrationV1StatusOutput = ExperimentalMigrationV1StatusOutput
// parity: client/src/promise/generated/types.ts#UsageLimitsOutput [status=implemented hash=714f6eaba7ba]
public typealias UsageLimitsOutput = ExperimentalUsageLimitsOutput
// parity: client/src/promise/generated/types.ts#ConfigUpdateOutput [status=implemented hash=9c8780161fc5]
public typealias ConfigUpdateOutput = ExperimentalConfigUpdateOutput

// MARK: - Promise Wire Type Catalog (packages/client/src/promise/generated/types.ts)

/// Complete catalog of generated Promise wire type aliases mapped cleanly to `OpenCodeSchema` and `OpenCodeProtocol`.
public enum PromiseWire {
    // parity: client/src/promise/generated/types.ts#JsonValue [status=implemented hash=f7703711807d]
    public typealias JsonValue = JSONValue
    // parity: client/src/promise/generated/types.ts#ServerInfo [status=implemented hash=19e4c8ff294b]
    public typealias ServerInfo = OpenCodeProtocol.ServerInfo
    // parity: client/src/promise/generated/types.ts#PairingCode [status=implemented hash=d90c79fc5657]
    public typealias PairingCode = OpenCodeProtocol.PairingCode
    // parity: client/src/promise/generated/types.ts#PairingSession [status=implemented hash=3fd31623a3d4]
    public typealias PairingSession = OpenCodeProtocol.PairingSession
    // parity: client/src/promise/generated/types.ts#AbsolutePath [status=implemented hash=9f5f4f2a480d]
    public typealias AbsolutePath = SchemaPrimitive.AbsolutePath
    // parity: client/src/promise/generated/types.ts#ProjectID [status=implemented hash=76c04fda037c]
    public typealias ProjectID = OpenCodeSchema.ProjectID
    // parity: client/src/promise/generated/types.ts#AgentID [status=implemented hash=5f106d5d9807]
    public typealias AgentID = AgentSchema.ID
    // parity: client/src/promise/generated/types.ts#ProviderID [status=implemented hash=43c582faf65f]
    public typealias ProviderID = ProviderSchema.ID
    // parity: client/src/promise/generated/types.ts#ProviderCompaction [status=implemented hash=8908b8271e83]
    public typealias ProviderCompaction = ProviderSchema.Compaction
    // parity: client/src/promise/generated/types.ts#ProviderCacheTTL [status=implemented hash=99cc034a6e40]
    public typealias ProviderCacheTTL = ProviderSchema.CacheTTL
    // parity: client/src/promise/generated/types.ts#ProviderCacheWarming [status=implemented hash=3e6f1a2c6fd7]
    public typealias ProviderCacheWarming = ProviderSchema.CacheWarming
    // parity: client/src/promise/generated/types.ts#ProviderTransport [status=implemented hash=861002e86c69]
    public typealias ProviderTransport = ProviderSchema.Transport
    // parity: client/src/promise/generated/types.ts#ProviderEncoding [status=implemented hash=37e107fdfb0c]
    public typealias ProviderEncoding = ProviderSchema.Encoding
    // parity: client/src/promise/generated/types.ts#ProviderTls [status=implemented hash=d01c6831254c]
    public typealias ProviderTls = ProviderSchema.Tls
    // parity: client/src/promise/generated/types.ts#AgentColor [status=implemented hash=3e239694d1fb]
    public typealias AgentColor = AgentSchema.Color
    // parity: client/src/promise/generated/types.ts#PermissionEffect [status=implemented hash=9d687bdffe58]
    public typealias PermissionEffect = PermissionSchema.Effect
    // parity: client/src/promise/generated/types.ts#PluginID [status=implemented hash=6373c3b97c8b]
    public typealias PluginID = PluginSchema.ID
    // parity: client/src/promise/generated/types.ts#PluginSource [status=implemented hash=797ed7e4346d]
    public typealias PluginSource = PluginSchema.Source
    // parity: client/src/promise/generated/types.ts#PluginFeatures [status=implemented hash=c7a80481c9b6]
    public typealias PluginFeatures = PluginSchema.Features
    // parity: client/src/promise/generated/types.ts#PluginState [status=implemented hash=7c8b6be0953c]
    public typealias PluginState = PluginSchema.State
    // parity: client/src/promise/generated/types.ts#PluginGuiBundle [status=implemented hash=c75e6606972c]
    public typealias PluginGuiBundle = PluginSchema.GuiBundle
    // parity: client/src/promise/generated/types.ts#SessionID [status=implemented hash=b85c6cb7fa5e]
    public typealias SessionID = OpenCodeSchema.SessionID
    // parity: client/src/promise/generated/types.ts#SessionMessageID [status=implemented hash=2f81f20077a6]
    public typealias SessionMessageID = SessionMessageSchema.ID
    // parity: client/src/promise/generated/types.ts#MoneyUSD [status=implemented hash=caa6efa6b3a7]
    public typealias MoneyUSD = MoneySchema.USD
    // parity: client/src/promise/generated/types.ts#TokenUsageInfo [status=implemented hash=7a21cc646aad]
    public typealias TokenUsageInfo = TokenUsageSchema.Info
    // parity: client/src/promise/generated/types.ts#RelativePath [status=implemented hash=998a41b32c5a]
    public typealias RelativePath = SchemaPrimitive.RelativePath
    // parity: client/src/promise/generated/types.ts#SessionMetadata [status=implemented hash=7beb08c74dfa]
    public typealias SessionMetadata = SessionMetadataSchema.SessionMetadata
    // parity: client/src/promise/generated/types.ts#SnapshotID [status=implemented hash=c1acb54772e9]
    public typealias SnapshotID = SnapshotSchema.ID
    // parity: client/src/promise/generated/types.ts#FileDiffInfo [status=implemented hash=996c68865ea5]
    public typealias FileDiffInfo = FileDiffSchema.Info
    // parity: client/src/promise/generated/types.ts#SessionsCursor [status=implemented hash=4259db7da59b]
    public typealias SessionsCursor = OpenCodeProtocol.SessionsCursor
    // parity: client/src/promise/generated/types.ts#SessionActive [status=implemented hash=c4f9039b79fc]
    public typealias SessionActive = SessionActiveInfo
    // parity: client/src/promise/generated/types.ts#PromptBase64 [status=implemented hash=b9b8ed0bcf4f]
    public typealias PromptBase64 = PromptSchema.Base64
    // parity: client/src/promise/generated/types.ts#PromptFileSource [status=implemented hash=625bb0026a4c]
    public typealias PromptFileSource = PromptSchema.FileSource
    // parity: client/src/promise/generated/types.ts#PromptMention [status=implemented hash=cd4032e4a888]
    public typealias PromptMention = PromptSchema.PromptMention
    // parity: client/src/promise/generated/types.ts#SkillID [status=implemented hash=990eb609c0c1]
    public typealias SkillID = SkillSchema.ID
    // parity: client/src/promise/generated/types.ts#SkillName [status=implemented hash=1afba724236d]
    public typealias SkillName = SkillSchema.Name
    // parity: client/src/promise/generated/types.ts#SessionInboxDelivery [status=implemented hash=e4797c6bd589]
    public typealias SessionInboxDelivery = SessionInboxSchema.Delivery
    // parity: client/src/promise/generated/types.ts#SessionInboxSyntheticPayload [status=implemented hash=de568f236c4e]
    public typealias SessionInboxSyntheticPayload = SessionInboxSchema.SyntheticPayload
    // parity: client/src/promise/generated/types.ts#SessionInboxCompactionPayload [status=implemented hash=199f23507530]
    public typealias SessionInboxCompactionPayload = SessionInboxSchema.CompactionPayload
    // parity: client/src/promise/generated/types.ts#ShellID [status=implemented hash=c1731a4d04ed]
    public typealias ShellID = ShellSchema.ID
    // parity: client/src/promise/generated/types.ts#SessionMessageNative [status=implemented hash=2ae13967a48e]
    public typealias SessionMessageNative = SessionMessageSchema.Native
    // parity: client/src/promise/generated/types.ts#SessionMessageToolStateStreaming [status=implemented hash=9aa89b1eae86]
    public typealias SessionMessageToolStateStreaming = SessionMessageSchema.ToolStateStreaming
    // parity: client/src/promise/generated/types.ts#SessionMessageToolStateRunning [status=implemented hash=6ad152ad5569]
    public typealias SessionMessageToolStateRunning = SessionMessageSchema.ToolStateRunning
    // parity: client/src/promise/generated/types.ts#ToolTextContent [status=implemented hash=43a34a3f9656]
    public typealias ToolTextContent = ToolSchema.TextContent
    // parity: client/src/promise/generated/types.ts#ToolFileContent [status=implemented hash=a9284c1cf4a6]
    public typealias ToolFileContent = ToolSchema.FileContent
    // parity: client/src/promise/generated/types.ts#SessionStructuredError [status=implemented hash=4fc8a6ee0c08]
    public typealias SessionStructuredError = SessionErrorSchema.Error
    // parity: client/src/promise/generated/types.ts#FormID [status=implemented hash=24763c3ff8f4]
    public typealias FormID = FormSchema.ID
    // parity: client/src/promise/generated/types.ts#FormMetadata [status=implemented hash=58974e554423]
    public typealias FormMetadata = FormSchema.Metadata
    // parity: client/src/promise/generated/types.ts#FormWhen [status=implemented hash=15ad29a21117]
    public typealias FormWhen = FormSchema.When
    // parity: client/src/promise/generated/types.ts#FormOption [status=implemented hash=1c72dcd769fd]
    public typealias FormOption = FormSchema.Option
    // parity: client/src/promise/generated/types.ts#FormExternalField [status=implemented hash=5c9c7481555c]
    public typealias FormExternalField = FormSchema.ExternalField
    // parity: client/src/promise/generated/types.ts#FormValue [status=implemented hash=9508dfa881f7]
    public typealias FormValue = FormSchema.Value
    // parity: client/src/promise/generated/types.ts#SessionStatsToolTotals [status=implemented hash=d7f1a42e42a2]
    public typealias SessionStatsToolTotals = SessionStatsSchema.ToolTotals
    // parity: client/src/promise/generated/types.ts#SessionStatsToolUsage [status=implemented hash=a8802033fff8]
    public typealias SessionStatsToolUsage = SessionStatsSchema.ToolUsage
    // parity: client/src/promise/generated/types.ts#SessionStatsActivity [status=implemented hash=56a764e35fcb]
    public typealias SessionStatsActivity = SessionStatsSchema.Activity
    // parity: client/src/promise/generated/types.ts#InstructionEntryKey [status=implemented hash=eadc56335722]
    public typealias InstructionEntryKey = InstructionEntrySchema.Key
    // parity: client/src/promise/generated/types.ts#EventID [status=implemented hash=bcc2e22d8e19]
    public typealias EventID = EventSchema.ID
    // parity: client/src/promise/generated/types.ts#EventSeq [status=implemented hash=283554eeb076]
    public typealias EventSeq = EventSchema.Seq
    // parity: client/src/promise/generated/types.ts#WorkspaceID [status=implemented hash=3abf1c8c00d4]
    public typealias WorkspaceID = OpenCodeSchema.WorkspaceID
    // parity: client/src/promise/generated/types.ts#InstructionKey [status=implemented hash=33e02ecf1cdc]
    public typealias InstructionKey = InstructionSchema.Key
    // parity: client/src/promise/generated/types.ts#InstructionHash [status=implemented hash=aecb7f5e8bdc]
    public typealias InstructionHash = InstructionSchema.Hash
    // parity: client/src/promise/generated/types.ts#SessionInboxSyntheticPayload1 [status=implemented hash=c67df2b8a92b]
    public typealias SessionInboxSyntheticPayload1 = SessionInboxSchema.SyntheticPayload
    // parity: client/src/promise/generated/types.ts#SessionMessageNative1 [status=implemented hash=d1bafb386327]
    public typealias SessionMessageNative1 = SessionMessageSchema.Native
    // parity: client/src/promise/generated/types.ts#ToolFileContent1 [status=implemented hash=934b5c3bf9f6]
    public typealias ToolFileContent1 = ToolSchema.FileContent
    // parity: client/src/promise/generated/types.ts#SessionMessageToolStateRunning1 [status=implemented hash=5ca1fad5aa19]
    public typealias SessionMessageToolStateRunning1 = SessionMessageSchema.ToolStateRunning
    // parity: client/src/promise/generated/types.ts#ModelType [status=implemented hash=d42a96017ef0]
    public typealias ModelType = ModelSchema.ModelType
    // parity: client/src/promise/generated/types.ts#ModelReasoningField [status=implemented hash=377694d10b8f]
    public typealias ModelReasoningField = ModelCompatibilitySchema.ReasoningField
    // parity: client/src/promise/generated/types.ts#ModelMaxTokensField [status=implemented hash=69c805a9695b]
    public typealias ModelMaxTokensField = ModelCompatibilitySchema.MaxTokensField
    // parity: client/src/promise/generated/types.ts#ModelCacheFormat [status=implemented hash=a9f43c7aa662]
    public typealias ModelCacheFormat = ModelCompatibilitySchema.CacheFormat
    // parity: client/src/promise/generated/types.ts#ModelMediaInput [status=implemented hash=2e6d518352a1]
    public typealias ModelMediaInput = ModelCompatibilitySchema.MediaInput
    // parity: client/src/promise/generated/types.ts#ToolFreeformFormat [status=implemented hash=872f90d7d8f3]
    public typealias ToolFreeformFormat = ToolSchema.FreeformFormat
    // parity: client/src/promise/generated/types.ts#MoneyUSDPerMillionTokens [status=implemented hash=632066f81fda]
    public typealias MoneyUSDPerMillionTokens = MoneySchema.USDPerMillionTokens
    // parity: client/src/promise/generated/types.ts#GenerateTextResponse [status=implemented hash=177894d722e0]
    public typealias GenerateTextResponse = ClientDataEnvelope<GenerateTextData>
    // parity: client/src/promise/generated/types.ts#GenerateUsage [status=implemented hash=3d05c5890687]
    public typealias GenerateUsage = GenerateSchema.Usage
    // parity: client/src/promise/generated/types.ts#GenerateNative [status=implemented hash=661451377089]
    public typealias GenerateNative = GenerateSchema.Native
    // parity: client/src/promise/generated/types.ts#GenerateVideoID [status=implemented hash=488bd17bf473]
    public typealias GenerateVideoID = GenerateSchema.VideoID
    // parity: client/src/promise/generated/types.ts#BlobID [status=implemented hash=78eb7b110d8d]
    public typealias BlobID = BlobStoreSchema.ID
    // parity: client/src/promise/generated/types.ts#GenerateVideoErrorReason [status=implemented hash=65aa5d20a606]
    public typealias GenerateVideoErrorReason = GenerateSchema.VideoErrorReason
    // parity: client/src/promise/generated/types.ts#GeneratePredicateAnswer [status=implemented hash=20470a95732d]
    public typealias GeneratePredicateAnswer = GenerateSchema.PredicateAnswer
    // parity: client/src/promise/generated/types.ts#GenerateChoiceValue [status=implemented hash=3152dfe65d96]
    public typealias GenerateChoiceValue = GenerateSchema.ChoiceValue
    // parity: client/src/promise/generated/types.ts#GenerateScoreAnswer [status=implemented hash=0a126a6426b0]
    public typealias GenerateScoreAnswer = GenerateSchema.ScoreAnswer
    // parity: client/src/promise/generated/types.ts#GenerateErrorAnswer [status=implemented hash=a66f5b235d4e]
    public typealias GenerateErrorAnswer = GenerateSchema.ErrorAnswer
    // parity: client/src/promise/generated/types.ts#VoiceTransportType [status=implemented hash=81931a7961ff]
    public typealias VoiceTransportType = OpenCodeProtocol.VoiceTransportType
    // parity: client/src/promise/generated/types.ts#VoiceWebRTCTransport [status=implemented hash=f53235f6bee9]
    public typealias VoiceWebRTCTransport = OpenCodeProtocol.VoiceWebRTCTransport
    // parity: client/src/promise/generated/types.ts#VoiceWebSocketTransport [status=implemented hash=0f3cdb0189b6]
    public typealias VoiceWebSocketTransport = OpenCodeProtocol.VoiceWebSocketTransport
    // parity: client/src/promise/generated/types.ts#IntegrationID [status=implemented hash=3624c803f647]
    public typealias IntegrationID = OpenCodeSchema.IntegrationID
    // parity: client/src/promise/generated/types.ts#IntegrationMethodID [status=implemented hash=c8e301f813e2]
    public typealias IntegrationMethodID = OpenCodeSchema.IntegrationMethodID
    // parity: client/src/promise/generated/types.ts#IntegrationEnvMethod [status=implemented hash=8205627adb09]
    public typealias IntegrationEnvMethod = IntegrationSchema.EnvMethod
    // parity: client/src/promise/generated/types.ts#CredentialID [status=implemented hash=3d355eb4b6d1]
    public typealias CredentialID = CredentialSchema.ID
    // parity: client/src/promise/generated/types.ts#ConnectionStatus [status=implemented hash=022d6d629a3a]
    public typealias ConnectionStatus = ConnectionSchema.Status
    // parity: client/src/promise/generated/types.ts#IntegrationAttemptID [status=implemented hash=0c4a8b3e473d]
    public typealias IntegrationAttemptID = IntegrationSchema.AttemptID
    // parity: client/src/promise/generated/types.ts#IntegrationAttemptStatus [status=implemented hash=6e4359b2cab8]
    public typealias IntegrationAttemptStatus = IntegrationSchema.AttemptStatus
    // parity: client/src/promise/generated/types.ts#IntegrationCommandAttemptStatus [status=implemented hash=0ef7882fbad6]
    public typealias IntegrationCommandAttemptStatus = IntegrationSchema.CommandAttemptStatus
    // parity: client/src/promise/generated/types.ts#McpStatusConnected [status=implemented hash=1f695c5755ec]
    public typealias McpStatusConnected = McpSchema.Status
    // parity: client/src/promise/generated/types.ts#McpStatusPending [status=implemented hash=6e8f402bd009]
    public typealias McpStatusPending = McpSchema.Status
    // parity: client/src/promise/generated/types.ts#McpStatusDisabled [status=implemented hash=f91b65d1c1c2]
    public typealias McpStatusDisabled = McpSchema.Status
    // parity: client/src/promise/generated/types.ts#McpStatusFailed [status=implemented hash=0a9fa9695e5e]
    public typealias McpStatusFailed = McpSchema.Status
    // parity: client/src/promise/generated/types.ts#McpStatusNeedsAuth [status=implemented hash=4b743e185901]
    public typealias McpStatusNeedsAuth = McpSchema.Status
    // parity: client/src/promise/generated/types.ts#McpResource [status=implemented hash=db64ad9b412e]
    public typealias McpResource = McpSchema.Resource
    // parity: client/src/promise/generated/types.ts#McpResourceTemplate [status=implemented hash=2583762f704b]
    public typealias McpResourceTemplate = McpSchema.ResourceTemplate
    // parity: client/src/promise/generated/types.ts#PtyTicketConnectToken [status=implemented hash=e5f362093803]
    public typealias PtyTicketConnectToken = PtyTicketSchema.ConnectToken
    // parity: client/src/promise/generated/types.ts#CredentialKey [status=implemented hash=bb2641d29da3]
    public typealias CredentialKey = CredentialSchema.Key
    // parity: client/src/promise/generated/types.ts#ProjectVcs [status=implemented hash=15f07fc8d97c]
    public typealias ProjectVcs = ProjectSchema.Vcs
    // parity: client/src/promise/generated/types.ts#ProjectIcon [status=implemented hash=30d9f989a37f]
    public typealias ProjectIcon = ProjectSchema.Icon
    // parity: client/src/promise/generated/types.ts#ProjectCommands [status=implemented hash=d1b5e231adf2]
    public typealias ProjectCommands = ProjectSchema.Commands
    // parity: client/src/promise/generated/types.ts#ProjectTime [status=implemented hash=f4b3b875957d]
    public typealias ProjectTime = ProjectSchema.Time
    // parity: client/src/promise/generated/types.ts#PermissionID [status=implemented hash=fe6916617177]
    public typealias PermissionID = PermissionSchema.ID
    // parity: client/src/promise/generated/types.ts#PermissionSource [status=implemented hash=abc157c033d1]
    public typealias PermissionSource = PermissionSchema.Source
    // parity: client/src/promise/generated/types.ts#PermissionSavedID [status=implemented hash=33464e6bf386]
    public typealias PermissionSavedID = PermissionSavedSchema.ID
    // parity: client/src/promise/generated/types.ts#CommandInfo [status=implemented hash=39025f9a9ad8]
    public typealias CommandInfo = CommandSchema.Info
    // parity: client/src/promise/generated/types.ts#RpcOutput [status=implemented hash=67a7ddd96358]
    public typealias RpcOutput = OpenCodeProtocol.RpcOutput
    // parity: client/src/promise/generated/types.ts#PermissionReply [status=implemented hash=8f08df93a144]
    public typealias PermissionReply = PermissionSchema.Reply
    // parity: client/src/promise/generated/types.ts#PtyID [status=implemented hash=7fd8889e9e0e]
    public typealias PtyID = PtySchema.ID
    // parity: client/src/promise/generated/types.ts#FormMetadata1 [status=implemented hash=ac781135b978]
    public typealias FormMetadata1 = FormSchema.Metadata
    // parity: client/src/promise/generated/types.ts#FormWhen1 [status=implemented hash=e0f8226cf98b]
    public typealias FormWhen1 = FormSchema.When
    // parity: client/src/promise/generated/types.ts#FormValue1 [status=implemented hash=5df68b0c176c]
    public typealias FormValue1 = FormSchema.Value
    // parity: client/src/promise/generated/types.ts#SessionStatus [status=implemented hash=3eee93865eab]
    public typealias SessionStatus = SessionStatusEventSchema.Info
    // parity: client/src/promise/generated/types.ts#PersistentPtyHandoff [status=implemented hash=78cc0927c759]
    public typealias PersistentPtyHandoff = PersistentPtySchema.Handoff
    // parity: client/src/promise/generated/types.ts#AutomationID [status=implemented hash=1d15885ddfe7]
    public typealias AutomationID = AutomationSchema.ID
    // parity: client/src/promise/generated/types.ts#AutomationTriggerAt [status=implemented hash=3e63e26280bb]
    public typealias AutomationTriggerAt = AutomationSchema.At
    // parity: client/src/promise/generated/types.ts#AutomationDuration [status=implemented hash=1f8bd188f36e]
    public typealias AutomationDuration = AutomationSchema.DurationString
    // parity: client/src/promise/generated/types.ts#AutomationTriggerCron [status=implemented hash=bf0ba85a271b]
    public typealias AutomationTriggerCron = AutomationSchema.Cron
    // parity: client/src/promise/generated/types.ts#AutomationTriggerEvent [status=implemented hash=5b93b3ed87f2]
    public typealias AutomationTriggerEvent = AutomationSchema.Event
    // parity: client/src/promise/generated/types.ts#AutomationActionCode [status=implemented hash=dc48fc1a3c7d]
    public typealias AutomationActionCode = AutomationSchema.CodeAction
    // parity: client/src/promise/generated/types.ts#AutomationStatus [status=implemented hash=1a68960c2428]
    public typealias AutomationStatus = AutomationSchema.Status
    // parity: client/src/promise/generated/types.ts#AutomationOutcome [status=implemented hash=b41e9e85b18d]
    public typealias AutomationOutcome = AutomationSchema.Outcome
    // parity: client/src/promise/generated/types.ts#ArtifactCapability [status=implemented hash=8415da8befdb]
    public typealias ArtifactCapability = ArtifactSchema.Capability
    // parity: client/src/promise/generated/types.ts#ArtifactID [status=implemented hash=c2726e9bd0a7]
    public typealias ArtifactID = ArtifactSchema.ID
    // parity: client/src/promise/generated/types.ts#ArtifactTime [status=implemented hash=9fd565f341cf]
    public typealias ArtifactTime = ArtifactSchema.Time
    // parity: client/src/promise/generated/types.ts#JobStatus [status=implemented hash=ddf307e523eb]
    public typealias JobStatus = JobSchema.Status
    // parity: client/src/promise/generated/types.ts#JobTime [status=implemented hash=a1beeaefb7fe]
    public typealias JobTime = JobSchema.Time
    // parity: client/src/promise/generated/types.ts#ReferenceGitSource [status=implemented hash=664a171e7623]
    public typealias ReferenceGitSource = ReferenceSchema.GitSource
    // parity: client/src/promise/generated/types.ts#VcsBranch [status=implemented hash=9cdd642bcda0]
    public typealias VcsBranch = VcsSchema.Branch
    // parity: client/src/promise/generated/types.ts#VcsBase [status=implemented hash=876917e7688c]
    public typealias VcsBase = VcsSchema.Base
    // parity: client/src/promise/generated/types.ts#VcsFileStatus [status=implemented hash=2dc287d7b850]
    public typealias VcsFileStatus = VcsSchema.FileStatus
    // parity: client/src/promise/generated/types.ts#VcsBranchList [status=implemented hash=0b57276b2cf1]
    public typealias VcsBranchList = VcsSchema.BranchList
    // parity: client/src/promise/generated/types.ts#WebSearchID [status=implemented hash=bdd49d1c1d50]
    public typealias WebSearchID = WebSearchSchema.ID
    // parity: client/src/promise/generated/types.ts#WebSearchResult [status=implemented hash=f3dbb8c64171]
    public typealias WebSearchResult = WebSearchSchema.Result
    // parity: client/src/promise/generated/types.ts#UsageLimitsMeter [status=implemented hash=ff94d0f4d0cf]
    public typealias UsageLimitsMeter = UsageLimitsSchema.Meter
    // parity: client/src/promise/generated/types.ts#McpProtocol [status=implemented hash=b2067f27abc2]
    public typealias McpProtocol = McpSchema.WireProtocol
    // parity: client/src/promise/generated/types.ts#ConfigCompactionPercent [status=implemented hash=26d7dfa55ae8]
    public typealias ConfigCompactionPercent = ConfigCompactionSchema.Percent
    // parity: client/src/promise/generated/types.ts#ConfigWorktree [status=implemented hash=b22ca5a15022]
    public typealias ConfigWorktree = ConfigWorktreeSchema.Info
    // parity: client/src/promise/generated/types.ts#ConfigModelReasoning [status=implemented hash=ed95b17c7186]
    public typealias ConfigModelReasoning = ConfigProviderSchema.Reasoning
    // parity: client/src/promise/generated/types.ts#ConfigShellOption [status=implemented hash=8e01e9b2c442]
    public typealias ConfigShellOption = ConfigShellSchema.Option
    // parity: client/src/promise/generated/types.ts#LocationPublicRef [status=implemented hash=011a0b71e857]
    public typealias LocationPublicRef = LocationSchema.PublicRef
    // parity: client/src/promise/generated/types.ts#FileSystemWrite [status=implemented hash=c1b6073987f4]
    public typealias FileSystemWrite = FileSystemSchema.Write
    // parity: client/src/promise/generated/types.ts#ReferenceLocalSource [status=implemented hash=c72d91167acd]
    public typealias ReferenceLocalSource = ReferenceSchema.LocalSource
    // parity: client/src/promise/generated/types.ts#WorktreeDirectory [status=implemented hash=a20be7e06f94]
    public typealias WorktreeDirectory = WorktreeSchema.Directory
    // parity: client/src/promise/generated/types.ts#WorktreeInfo [status=implemented hash=b550e5a77286]
    public typealias WorktreeInfo = WorktreeSchema.Info
    // parity: client/src/promise/generated/types.ts#LocationPublicInfo [status=implemented hash=677de3c4fab1]
    public typealias LocationPublicInfo = LocationSchema.PublicInfo
    // parity: client/src/promise/generated/types.ts#ModelRef [status=implemented hash=7c25db844cdc]
    public typealias ModelRef = ModelSchema.Ref
    // parity: client/src/promise/generated/types.ts#ProviderCache [status=implemented hash=130a258bf594]
    public typealias ProviderCache = ProviderSchema.Cache
    // parity: client/src/promise/generated/types.ts#ModelVariantSettings [status=implemented hash=3669c7475452]
    public typealias ModelVariantSettings = ModelSchema.VariantSettings
    // parity: client/src/promise/generated/types.ts#ConfigModelVariantSettings [status=implemented hash=0c24ec95c46c]
    public typealias ConfigModelVariantSettings = ConfigProviderSchema.VariantConfig
    // parity: client/src/promise/generated/types.ts#PermissionRule [status=implemented hash=8eedad7d41cb]
    public typealias PermissionRule = PermissionSchema.Rule
    // parity: client/src/promise/generated/types.ts#PluginInfo [status=implemented hash=842ebaceba44]
    public typealias PluginInfo = PluginSchema.Info
    // parity: client/src/promise/generated/types.ts#AutomationTarget [status=implemented hash=0bc5d9ef67a3]
    public typealias AutomationTarget = AutomationSchema.Target
    // parity: client/src/promise/generated/types.ts#SessionForkBoundary [status=implemented hash=dadbb25d5a2d]
    public typealias SessionForkBoundary = SessionForkSchema.Boundary
    // parity: client/src/promise/generated/types.ts#SessionMessageAgentSelected [status=implemented hash=c81563bcfbb9]
    public typealias SessionMessageAgentSelected = SessionMessageSchema.AgentSelected
    // parity: client/src/promise/generated/types.ts#SessionMessageSynthetic [status=implemented hash=061c335e475e]
    public typealias SessionMessageSynthetic = SessionMessageSchema.Synthetic
    // parity: client/src/promise/generated/types.ts#SessionMessageSystem [status=implemented hash=b30b62a6072c]
    public typealias SessionMessageSystem = SessionMessageSchema.System
    // parity: client/src/promise/generated/types.ts#SessionMessageCompactionRunning [status=implemented hash=2d477858e5fb]
    public typealias SessionMessageCompactionRunning = SessionMessageSchema.CompactionRunning
    // parity: client/src/promise/generated/types.ts#UsageLimitsBudgetModel [status=implemented hash=b665e33cfff1]
    public typealias UsageLimitsBudgetModel = UsageLimitsSchema.BudgetModel
    // parity: client/src/promise/generated/types.ts#SessionGenerateResponse [status=implemented hash=947ed3579b44]
    public typealias SessionGenerateResponse = ClientDataEnvelope<SessionGenerateData>
    // parity: client/src/promise/generated/types.ts#FileSystemEntry [status=implemented hash=21714f56e905]
    public typealias FileSystemEntry = FileSystemSchema.Entry
    // parity: client/src/promise/generated/types.ts#SessionRevert [status=implemented hash=da1b604a4221]
    public typealias SessionRevert = SessionRevertSchema.Revert
    // parity: client/src/promise/generated/types.ts#GenerateImageOutput2 [status=implemented hash=b512f7228585]
    public typealias GenerateImageOutput2 = GenerateSchema.ImageOutput
    // parity: client/src/promise/generated/types.ts#PromptFileAttachment [status=implemented hash=f0dc42dfe62b]
    public typealias PromptFileAttachment = PromptSchema.FileAttachment
    // parity: client/src/promise/generated/types.ts#PromptAgentAttachment [status=implemented hash=d67548ccc92d]
    public typealias PromptAgentAttachment = PromptSchema.AgentAttachment
    // parity: client/src/promise/generated/types.ts#PromptSkillAttachment [status=implemented hash=e407d9f74044]
    public typealias PromptSkillAttachment = PromptSchema.SkillAttachment
    // parity: client/src/promise/generated/types.ts#SessionMessageSkill [status=implemented hash=49467d9bc1b4]
    public typealias SessionMessageSkill = SessionMessageSchema.Skill
    // parity: client/src/promise/generated/types.ts#SkillInfo [status=implemented hash=93b669054836]
    public typealias SkillInfo = SkillSchema.Info
    // parity: client/src/promise/generated/types.ts#SessionInboxSynthetic [status=implemented hash=a4a8a0c3a0da]
    public typealias SessionInboxSynthetic = SessionInboxSchema.Synthetic
    // parity: client/src/promise/generated/types.ts#SessionInboxCompaction [status=implemented hash=5ed9dca5180f]
    public typealias SessionInboxCompaction = SessionInboxSchema.Compaction
    // parity: client/src/promise/generated/types.ts#SessionMessageShell [status=implemented hash=d387a0588dcf]
    public typealias SessionMessageShell = SessionMessageSchema.Shell
    // parity: client/src/promise/generated/types.ts#ShellInfo [status=implemented hash=cb8a6ed9fcc8]
    public typealias ShellInfo = SessionMessageSchema.ShellInfo
    // parity: client/src/promise/generated/types.ts#ShellInfo1 [status=implemented hash=3931bf6da7ae]
    public typealias ShellInfo1 = ShellSchema.Info
    // parity: client/src/promise/generated/types.ts#SessionMessageAssistantText [status=implemented hash=67a45ad3ee7f]
    public typealias SessionMessageAssistantText = SessionMessageSchema.AssistantText
    // parity: client/src/promise/generated/types.ts#SessionMessageAssistantReasoning [status=implemented hash=cea96c15de4a]
    public typealias SessionMessageAssistantReasoning = SessionMessageSchema.AssistantReasoning
    // parity: client/src/promise/generated/types.ts#ToolContent [status=implemented hash=c0f1bf4edb6d]
    public typealias ToolContent = ToolSchema.Content
    // parity: client/src/promise/generated/types.ts#SessionMessageAssistantRetry [status=implemented hash=94ad49d3400d]
    public typealias SessionMessageAssistantRetry = SessionMessageSchema.AssistantRetry
    // parity: client/src/promise/generated/types.ts#SessionMessageCompactionFailed [status=implemented hash=8fb8922496cd]
    public typealias SessionMessageCompactionFailed = SessionMessageSchema.CompactionFailed
    // parity: client/src/promise/generated/types.ts#SessionMessageIdle [status=implemented hash=29f60768fe2f]
    public typealias SessionMessageIdle = SessionMessageSchema.Idle
    // parity: client/src/promise/generated/types.ts#FormNumberField [status=implemented hash=37b92e1923ff]
    public typealias FormNumberField = FormSchema.NumberField
    // parity: client/src/promise/generated/types.ts#FormIntegerField [status=implemented hash=1b07a01fc3e5]
    public typealias FormIntegerField = FormSchema.IntegerField
    // parity: client/src/promise/generated/types.ts#FormBooleanField [status=implemented hash=de5300283235]
    public typealias FormBooleanField = FormSchema.BooleanField
    // parity: client/src/promise/generated/types.ts#FormStringField [status=implemented hash=2101318d205f]
    public typealias FormStringField = FormSchema.StringField
    // parity: client/src/promise/generated/types.ts#FormMultiselectField [status=implemented hash=3eba2593621f]
    public typealias FormMultiselectField = FormSchema.MultiselectField
    // parity: client/src/promise/generated/types.ts#FormAnswer [status=implemented hash=2eae5a38e8bf]
    public typealias FormAnswer = FormSchema.Answer
    // parity: client/src/promise/generated/types.ts#SessionStatsTools [status=implemented hash=d72fa01049c9]
    public typealias SessionStatsTools = SessionStatsSchema.Tools
    // parity: client/src/promise/generated/types.ts#InstructionEntryInfo [status=implemented hash=02a2ad3aa209]
    public typealias InstructionEntryInfo = InstructionEntrySchema.Info
    // parity: client/src/promise/generated/types.ts#InstructionEntrySnapshot [status=implemented hash=3dedfcece4f1]
    public typealias InstructionEntrySnapshot = InstructionEntrySchema.Snapshot
    // parity: client/src/promise/generated/types.ts#EventLogSynced [status=implemented hash=b70114e79ee6]
    public typealias EventLogSynced = EventLogSchema.Synced
    // parity: client/src/promise/generated/types.ts#LocationRef [status=implemented hash=689d1502eea0]
    public typealias LocationRef = LocationSchema.Ref
    // parity: client/src/promise/generated/types.ts#SessionMessageAssistantText1 [status=implemented hash=0b59ad165b62]
    public typealias SessionMessageAssistantText1 = SessionMessageSchema.AssistantText
    // parity: client/src/promise/generated/types.ts#SessionMessageAssistantReasoning1 [status=implemented hash=42010c37d123]
    public typealias SessionMessageAssistantReasoning1 = SessionMessageSchema.AssistantReasoning
    // parity: client/src/promise/generated/types.ts#ToolContent1 [status=implemented hash=67a208b75f81]
    public typealias ToolContent1 = ToolSchema.Content
    // parity: client/src/promise/generated/types.ts#ModelCompatibility [status=implemented hash=b234b6b7d232]
    public typealias ModelCompatibility = ModelCompatibilitySchema.Compatibility
    // parity: client/src/promise/generated/types.ts#ProviderCompatibility [status=implemented hash=597b7e5ea9e6]
    public typealias ProviderCompatibility = ModelCompatibilitySchema.ProviderCompatibility
    // parity: client/src/promise/generated/types.ts#ModelCapabilities [status=implemented hash=3f107bae86a6]
    public typealias ModelCapabilities = ModelSchema.Capabilities
    // parity: client/src/promise/generated/types.ts#ModelCost [status=implemented hash=c64b5cf80fb3]
    public typealias ModelCost = ModelSchema.Cost
    // parity: client/src/promise/generated/types.ts#GenerateVideoRunning [status=implemented hash=fd31727d3336]
    public typealias GenerateVideoRunning = GenerateSchema.VideoRunning
    // parity: client/src/promise/generated/types.ts#BlobInfo [status=implemented hash=1193bf0df70a]
    public typealias BlobInfo = BlobStoreSchema.Info
    // parity: client/src/promise/generated/types.ts#GenerateVideoError [status=implemented hash=3369ee13f8c6]
    public typealias GenerateVideoError = GenerateSchema.VideoError
    // parity: client/src/promise/generated/types.ts#GenerateChoiceAnswer [status=implemented hash=f2eab5c03ddd]
    public typealias GenerateChoiceAnswer = GenerateSchema.ChoiceAnswer
    // parity: client/src/promise/generated/types.ts#VoiceModel [status=implemented hash=9f00cd694568]
    public typealias VoiceModel = OpenCodeProtocol.VoiceModel
    // parity: client/src/promise/generated/types.ts#VoiceTransport [status=implemented hash=ca7a74f9a45a]
    public typealias VoiceTransport = OpenCodeProtocol.VoiceTransport
    // parity: client/src/promise/generated/types.ts#IntegrationCommandMethod [status=implemented hash=e449b639fb21]
    public typealias IntegrationCommandMethod = IntegrationSchema.CommandMethod
    // parity: client/src/promise/generated/types.ts#CredentialOAuth [status=implemented hash=55c744c17653]
    public typealias CredentialOAuth = CredentialSchema.OAuth
    // parity: client/src/promise/generated/types.ts#CredentialExternal [status=implemented hash=ed8f480531e2]
    public typealias CredentialExternal = CredentialSchema.External
    // parity: client/src/promise/generated/types.ts#ConnectionCredentialInfo [status=implemented hash=3971653a5ef5]
    public typealias ConnectionCredentialInfo = ConnectionSchema.CredentialInfo
    // parity: client/src/promise/generated/types.ts#ConnectionEnvInfo [status=implemented hash=072ae60fcdb6]
    public typealias ConnectionEnvInfo = ConnectionSchema.EnvInfo
    // parity: client/src/promise/generated/types.ts#IntegrationAttempt [status=implemented hash=ba95591eedb8]
    public typealias IntegrationAttempt = IntegrationSchema.Attempt
    // parity: client/src/promise/generated/types.ts#IntegrationCommandAttempt [status=implemented hash=207480b0b1a5]
    public typealias IntegrationCommandAttempt = IntegrationSchema.CommandAttempt
    // parity: client/src/promise/generated/types.ts#McpServer [status=implemented hash=b041814ff87b]
    public typealias McpServer = McpSchema.Server
    // parity: client/src/promise/generated/types.ts#McpResourceCatalog [status=implemented hash=d6168be5e3b0]
    public typealias McpResourceCatalog = McpSchema.ResourceCatalog
    // parity: client/src/promise/generated/types.ts#Project [status=implemented hash=4946594f52e5]
    public typealias Project = ProjectSchema.Info
    // parity: client/src/promise/generated/types.ts#PermissionRequest [status=implemented hash=875a264ddc95]
    public typealias PermissionRequest = PermissionSchema.Request
    // parity: client/src/promise/generated/types.ts#PermissionSavedInfo [status=implemented hash=4fb382c4c760]
    public typealias PermissionSavedInfo = PermissionSavedSchema.Info
    // parity: client/src/promise/generated/types.ts#Pty [status=implemented hash=16f5adf112b3]
    public typealias Pty = PtySchema.Info
    // parity: client/src/promise/generated/types.ts#PersistentPtyInfo [status=implemented hash=d5b745705165]
    public typealias PersistentPtyInfo = PersistentPtySchema.Info
    // parity: client/src/promise/generated/types.ts#PersistentPtyReadResult [status=implemented hash=abc26816d58b]
    public typealias PersistentPtyReadResult = PersistentPtySchema.ReadResult
    // parity: client/src/promise/generated/types.ts#FormStringField1 [status=implemented hash=a0baa99d608d]
    public typealias FormStringField1 = FormSchema.StringField
    // parity: client/src/promise/generated/types.ts#FormNumberField1 [status=implemented hash=1a544e7490e9]
    public typealias FormNumberField1 = FormSchema.NumberField
    // parity: client/src/promise/generated/types.ts#FormIntegerField1 [status=implemented hash=6c8a3b119bf2]
    public typealias FormIntegerField1 = FormSchema.IntegerField
    // parity: client/src/promise/generated/types.ts#FormBooleanField1 [status=implemented hash=f2bef96f9884]
    public typealias FormBooleanField1 = FormSchema.BooleanField
    // parity: client/src/promise/generated/types.ts#FormMultiselectField1 [status=implemented hash=de5ec02d6513]
    public typealias FormMultiselectField1 = FormSchema.MultiselectField
    // parity: client/src/promise/generated/types.ts#FormAnswer1 [status=implemented hash=9838e6a3f621]
    public typealias FormAnswer1 = FormSchema.Answer
    // parity: client/src/promise/generated/types.ts#AutomationTriggerEvery [status=implemented hash=ea0100f248ff]
    public typealias AutomationTriggerEvery = AutomationSchema.Every
    // parity: client/src/promise/generated/types.ts#ArtifactProvider [status=implemented hash=41112eb18474]
    public typealias ArtifactProvider = ArtifactSchema.Provider
    // parity: client/src/promise/generated/types.ts#ArtifactInfo [status=implemented hash=349cb08eb23e]
    public typealias ArtifactInfo = ArtifactSchema.Info
    // parity: client/src/promise/generated/types.ts#JobShell [status=implemented hash=f1d40513c5d9]
    public typealias JobShell = JobSchema.Shell
    // parity: client/src/promise/generated/types.ts#JobSubagent [status=implemented hash=c24ab3c02999]
    public typealias JobSubagent = JobSchema.Subagent
    // parity: client/src/promise/generated/types.ts#JobImage [status=implemented hash=c37482a65981]
    public typealias JobImage = JobSchema.Image
    // parity: client/src/promise/generated/types.ts#JobCodeMode [status=implemented hash=c1b50e6e09ee]
    public typealias JobCodeMode = JobSchema.CodeMode
    // parity: client/src/promise/generated/types.ts#VcsInfo [status=implemented hash=be1d066bdaf3]
    public typealias VcsInfo = VcsSchema.Info
    // parity: client/src/promise/generated/types.ts#WebSearchProvider [status=implemented hash=4fa6c3af9cbc]
    public typealias WebSearchProvider = WebSearchSchema.Provider
    // parity: client/src/promise/generated/types.ts#UsageLimitsGo [status=implemented hash=962bf3663bb4]
    public typealias UsageLimitsGo = UsageLimitsSchema.Go
    // parity: client/src/promise/generated/types.ts#ConfigModelCapabilities [status=implemented hash=8e81e83c1958]
    public typealias ConfigModelCapabilities = ConfigProviderSchema.ModelCapabilities
    // parity: client/src/promise/generated/types.ts#SessionMessageLocationSwitched [status=implemented hash=cafa8dd1be38]
    public typealias SessionMessageLocationSwitched = SessionMessageSchema.LocationSwitched
    // parity: client/src/promise/generated/types.ts#SessionInboxMovePayload [status=implemented hash=65c406b42904]
    public typealias SessionInboxMovePayload = SessionInboxSchema.MovePayload
    // parity: client/src/promise/generated/types.ts#V2EventRpc [status=implemented hash=8377c2e15076]
    public typealias V2EventRpc = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#V2EventServerConnected [status=implemented hash=c3385a8c5685]
    public typealias V2EventServerConnected = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#ReferenceSource [status=implemented hash=3a11ecd384c8]
    public typealias ReferenceSource = ReferenceSchema.Source
    // parity: client/src/promise/generated/types.ts#WorktreeList [status=implemented hash=13177565ded3]
    public typealias WorktreeList = WorktreeSchema.List
    // parity: client/src/promise/generated/types.ts#SessionMessageModelSelected [status=implemented hash=52693dd7996d]
    public typealias SessionMessageModelSelected = SessionMessageSchema.ModelSelected
    // parity: client/src/promise/generated/types.ts#SessionMessageCompactionCompleted [status=implemented hash=0c9a2f579791]
    public typealias SessionMessageCompactionCompleted = SessionMessageSchema.CompactionCompleted
    // parity: client/src/promise/generated/types.ts#SessionStatsModelUsage [status=implemented hash=5cf1066931c9]
    public typealias SessionStatsModelUsage = SessionStatsSchema.ModelUsage
    // parity: client/src/promise/generated/types.ts#ProviderSettings [status=implemented hash=309c7035ac04]
    public typealias ProviderSettings = ProviderSchema.Settings
    // parity: client/src/promise/generated/types.ts#ModelSettings [status=implemented hash=80de7d3f9f1a]
    public typealias ModelSettings = ModelSchema.Settings
    // parity: client/src/promise/generated/types.ts#ConfigProviderSettings [status=implemented hash=d7edb4b82654]
    public typealias ConfigProviderSettings = ConfigProviderSchema.Settings
    // parity: client/src/promise/generated/types.ts#ConfigModelSettings [status=implemented hash=50688122b3e2]
    public typealias ConfigModelSettings = ConfigProviderSchema.ModelSettings
    // parity: client/src/promise/generated/types.ts#ModelVariant [status=implemented hash=fd1e8b58cc9c]
    public typealias ModelVariant = ModelSchema.Variant
    // parity: client/src/promise/generated/types.ts#PermissionRuleset [status=implemented hash=1957a3227162]
    public typealias PermissionRuleset = PermissionSchema.Ruleset
    // parity: client/src/promise/generated/types.ts#AutomationActionPrompt [status=implemented hash=e80597ad0b3f]
    public typealias AutomationActionPrompt = AutomationSchema.PromptAction
    // parity: client/src/promise/generated/types.ts#UsageLimitsBudget [status=implemented hash=96f02f300713]
    public typealias UsageLimitsBudget = UsageLimitsSchema.Budget
    // parity: client/src/promise/generated/types.ts#GenerateImageResult [status=implemented hash=1cfe9584ee2d]
    public typealias GenerateImageResult = GenerateSchema.ImageResult
    // parity: client/src/promise/generated/types.ts#SessionInboxUserPayload [status=implemented hash=c05bda7b42ee]
    public typealias SessionInboxUserPayload = SessionInboxSchema.UserPayload
    // parity: client/src/promise/generated/types.ts#SessionMessageUser [status=implemented hash=f0c98235ccaa]
    public typealias SessionMessageUser = SessionMessageSchema.User
    // parity: client/src/promise/generated/types.ts#SessionInboxUserPayload1 [status=implemented hash=13bf03ce5d49]
    public typealias SessionInboxUserPayload1 = SessionInboxSchema.UserPayload
    // parity: client/src/promise/generated/types.ts#SessionMessageToolStateCompleted [status=implemented hash=d033098642ce]
    public typealias SessionMessageToolStateCompleted = SessionMessageSchema.ToolStateCompleted
    // parity: client/src/promise/generated/types.ts#SessionMessageToolStateError [status=implemented hash=ea65839218a5]
    public typealias SessionMessageToolStateError = SessionMessageSchema.ToolStateError
    // parity: client/src/promise/generated/types.ts#FormField [status=implemented hash=aa6e70a9beeb]
    public typealias FormField = FormSchema.Field
    // parity: client/src/promise/generated/types.ts#FormState [status=implemented hash=75c4645cfa26]
    public typealias FormState = FormSchema.State
    // parity: client/src/promise/generated/types.ts#SessionAgentSelected [status=implemented hash=64e4ac3a3efe]
    public typealias SessionAgentSelected = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionModelSelected [status=implemented hash=ecf6e4a0aa33]
    public typealias SessionModelSelected = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionMoved [status=implemented hash=73445f5e7e28]
    public typealias SessionMoved = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionRenamed [status=implemented hash=836beaa3e4d9]
    public typealias SessionRenamed = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionMetadataUpdated [status=implemented hash=316ad7d3e4e8]
    public typealias SessionMetadataUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionViewed [status=implemented hash=347f30a1defc]
    public typealias SessionViewed = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionArchived [status=implemented hash=b6449d5722fb]
    public typealias SessionArchived = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionUnarchived [status=implemented hash=fe1755e79f39]
    public typealias SessionUnarchived = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionDeleted [status=implemented hash=6f36c2579a09]
    public typealias SessionDeleted = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionForked [status=implemented hash=1a95573073ae]
    public typealias SessionForked = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionInboxDelivered [status=implemented hash=6a1d62b53a02]
    public typealias SessionInboxDelivered = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionInboxMovePayload1 [status=implemented hash=15598147859e]
    public typealias SessionInboxMovePayload1 = SessionInboxSchema.MovePayload
    // parity: client/src/promise/generated/types.ts#SessionInboxCancelled [status=implemented hash=422352f24385]
    public typealias SessionInboxCancelled = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionInboxDeliveryChanged [status=implemented hash=41876338c814]
    public typealias SessionInboxDeliveryChanged = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionExecutionStarted [status=implemented hash=9da7f2aad48d]
    public typealias SessionExecutionStarted = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionExecutionSucceeded [status=implemented hash=920e2360e7c8]
    public typealias SessionExecutionSucceeded = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionExecutionFailed [status=implemented hash=beafcdebae69]
    public typealias SessionExecutionFailed = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionExecutionInterrupted [status=implemented hash=243e49f9f8e3]
    public typealias SessionExecutionInterrupted = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionInstructionsUpdated [status=implemented hash=e6e172f4a47c]
    public typealias SessionInstructionsUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionSynthetic [status=implemented hash=ef11c9be5858]
    public typealias SessionSynthetic = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionSkillActivated [status=implemented hash=d18e494d271d]
    public typealias SessionSkillActivated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionShellStarted [status=implemented hash=27c3e8d71f54]
    public typealias SessionShellStarted = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionShellEnded [status=implemented hash=a7c7034adb5a]
    public typealias SessionShellEnded = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionStepStarted [status=implemented hash=1ec35db427be]
    public typealias SessionStepStarted = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionStepFirstToken [status=implemented hash=5a416aecfd75]
    public typealias SessionStepFirstToken = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionStepStreamed [status=implemented hash=bd3e9fda5da3]
    public typealias SessionStepStreamed = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionStepEnded [status=implemented hash=9aeecc383e92]
    public typealias SessionStepEnded = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionStepFailed [status=implemented hash=2f85ef8e54c6]
    public typealias SessionStepFailed = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionTextStarted [status=implemented hash=349515cba34c]
    public typealias SessionTextStarted = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionTextEnded [status=implemented hash=f0cb53ef5f57]
    public typealias SessionTextEnded = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionReasoningStarted [status=implemented hash=62004da99c3a]
    public typealias SessionReasoningStarted = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionReasoningEnded [status=implemented hash=0aaf521205aa]
    public typealias SessionReasoningEnded = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionToolInputStarted [status=implemented hash=822f2009738f]
    public typealias SessionToolInputStarted = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionToolInputEnded [status=implemented hash=2e7ff195090a]
    public typealias SessionToolInputEnded = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionToolCalled [status=implemented hash=a7ee6a744eae]
    public typealias SessionToolCalled = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionRetryScheduled [status=implemented hash=2f402c177ea6]
    public typealias SessionRetryScheduled = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionCompactionStarted [status=implemented hash=75270a18940c]
    public typealias SessionCompactionStarted = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionCompactionEnded [status=implemented hash=f36663dcd855]
    public typealias SessionCompactionEnded = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionCompactionFailed [status=implemented hash=c9783b2636ef]
    public typealias SessionCompactionFailed = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionRevertStaged [status=implemented hash=5e7753c15016]
    public typealias SessionRevertStaged = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionRevertCleared [status=implemented hash=c351ccf4ec03]
    public typealias SessionRevertCleared = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionRevertCommitted [status=implemented hash=f7488fa0c9fc]
    public typealias SessionRevertCommitted = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionUsageRecorded [status=implemented hash=c8a8556fd757]
    public typealias SessionUsageRecorded = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#LocationShutdown [status=implemented hash=9b0f330edc80]
    public typealias LocationShutdown = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#ModelsDevRefreshed [status=implemented hash=7741e2d21c0a]
    public typealias ModelsDevRefreshed = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#CredentialUpdated [status=implemented hash=8a0beeab3f54]
    public typealias CredentialUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#CredentialSwitched [status=implemented hash=d27320c10872]
    public typealias CredentialSwitched = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#IntegrationUpdated [status=implemented hash=03cc0aee2d0a]
    public typealias IntegrationUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#ProviderUpdated [status=implemented hash=a4e85008da9f]
    public typealias ProviderUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#ModelUpdated [status=implemented hash=13c64908eecb]
    public typealias ModelUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#AgentUpdated [status=implemented hash=4005c6259665]
    public typealias AgentUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionUsageUpdated [status=implemented hash=46ae2b32ef24]
    public typealias SessionUsageUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionTextDelta [status=implemented hash=f021ae73adf5]
    public typealias SessionTextDelta = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionReasoningDelta [status=implemented hash=3f63503aab9d]
    public typealias SessionReasoningDelta = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionToolInputDelta [status=implemented hash=c979f3631f40]
    public typealias SessionToolInputDelta = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionToolProgress [status=implemented hash=cc9e45eca1e0]
    public typealias SessionToolProgress = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionCompactionDelta [status=implemented hash=4768ee71e586]
    public typealias SessionCompactionDelta = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#FilesystemChanged [status=implemented hash=fee05208b078]
    public typealias FilesystemChanged = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#ReferenceUpdated [status=implemented hash=2e1e2a0df2cf]
    public typealias ReferenceUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#PermissionAsked [status=implemented hash=073b017fdbdb]
    public typealias PermissionAsked = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#PermissionReplied [status=implemented hash=7c6b615e5ed9]
    public typealias PermissionReplied = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#PluginUpdated [status=implemented hash=401041f13024]
    public typealias PluginUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#ProjectUpdated [status=implemented hash=f2740f8805ce]
    public typealias ProjectUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#WorktreeUpdated [status=implemented hash=f9ee0b1dc2be]
    public typealias WorktreeUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#WorktreeResolved [status=implemented hash=64f14a9eb8ef]
    public typealias WorktreeResolved = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#CommandUpdated [status=implemented hash=7f13dccb9b97]
    public typealias CommandUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#ConfigUpdated [status=implemented hash=9944abf45d5d]
    public typealias ConfigUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SkillUpdated [status=implemented hash=adcb123c1368]
    public typealias SkillUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#PtyExited [status=implemented hash=008492cb7f7d]
    public typealias PtyExited = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#PtyDeleted [status=implemented hash=e71f8a3f53b3]
    public typealias PtyDeleted = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#PersistentPtyRemoved [status=implemented hash=7f845f310e16]
    public typealias PersistentPtyRemoved = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#ShellCreated [status=implemented hash=66c4e11066e4]
    public typealias ShellCreated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#ShellExited [status=implemented hash=4430200240ea]
    public typealias ShellExited = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#ShellDeleted [status=implemented hash=dc04ebe54f6f]
    public typealias ShellDeleted = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#FormCancelled [status=implemented hash=48b3e5416625]
    public typealias FormCancelled = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#WebsearchUpdated [status=implemented hash=66536f92e979]
    public typealias WebsearchUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#ArtifactUpdated [status=implemented hash=d020789ba969]
    public typealias ArtifactUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionStatusUpdated [status=implemented hash=cbd29121384d]
    public typealias SessionStatusUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionIdle [status=implemented hash=e40ad3b8e311]
    public typealias SessionIdle = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#TuiPromptAppend [status=implemented hash=afa417050edb]
    public typealias TuiPromptAppend = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#TuiCommandExecute [status=implemented hash=003ab7256883]
    public typealias TuiCommandExecute = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#TuiToastShow [status=implemented hash=185e323f9dbf]
    public typealias TuiToastShow = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#TuiSessionSelect [status=implemented hash=0408f7f2ed05]
    public typealias TuiSessionSelect = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#InstallationUpdated [status=implemented hash=eddf7a727a75]
    public typealias InstallationUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#InstallationUpdateAvailable [status=implemented hash=7c8b083ae33c]
    public typealias InstallationUpdateAvailable = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#VcsBranchUpdated [status=implemented hash=27492da8123a]
    public typealias VcsBranchUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#McpStatusChanged [status=implemented hash=a1dabda896d7]
    public typealias McpStatusChanged = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#McpResourcesChanged [status=implemented hash=da8e1556ef95]
    public typealias McpResourcesChanged = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#ExperimentalMcpEvent [status=implemented hash=e402212f13f8]
    public typealias ExperimentalMcpEvent = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionToolSuccess [status=implemented hash=c683bc1a15c8]
    public typealias SessionToolSuccess = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionToolFailed [status=implemented hash=b67f2a4030f4]
    public typealias SessionToolFailed = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionMessageToolStateCompleted1 [status=implemented hash=8684ebd08ecd]
    public typealias SessionMessageToolStateCompleted1 = SessionMessageSchema.ToolStateCompleted
    // parity: client/src/promise/generated/types.ts#SessionMessageToolStateError1 [status=implemented hash=c93f6184017d]
    public typealias SessionMessageToolStateError1 = SessionMessageSchema.ToolStateError
    // parity: client/src/promise/generated/types.ts#GenerateVideoCreateResponse [status=implemented hash=df7a61f48b1f]
    public typealias GenerateVideoCreateResponse = ClientDataEnvelope<GenerateSchema.VideoRunning>
    // parity: client/src/promise/generated/types.ts#GenerateVideoCompleted [status=implemented hash=79e94412317b]
    public typealias GenerateVideoCompleted = GenerateSchema.VideoCompleted
    // parity: client/src/promise/generated/types.ts#GenerateDecisionAnswer [status=implemented hash=039b65e7e2c6]
    public typealias GenerateDecisionAnswer = GenerateSchema.DecisionAnswer
    // parity: client/src/promise/generated/types.ts#VoiceModelsResponse [status=implemented hash=039e5f962b81]
    public typealias VoiceModelsResponse = ClientDataEnvelope<VoiceModelsData>
    // parity: client/src/promise/generated/types.ts#VoiceSessionResponse [status=implemented hash=9ba2edbf27af]
    public typealias VoiceSessionResponse = ClientDataEnvelope<VoiceSessionData>
    // parity: client/src/promise/generated/types.ts#CredentialValue [status=implemented hash=59dc987ff58c]
    public typealias CredentialValue = CredentialSchema.Value
    // parity: client/src/promise/generated/types.ts#ConnectionInfo [status=implemented hash=b5fb81dde9c5]
    public typealias ConnectionInfo = ConnectionSchema.Info
    // parity: client/src/promise/generated/types.ts#PtyCreated [status=implemented hash=f4c86862724b]
    public typealias PtyCreated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#PtyUpdated [status=implemented hash=e506c80ac0ae]
    public typealias PtyUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#PersistentPtyAdded [status=implemented hash=96e75bd77c7e]
    public typealias PersistentPtyAdded = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#PersistentPtyUpdated [status=implemented hash=a1c7353b70b9]
    public typealias PersistentPtyUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#PersistentPtySnapshot [status=implemented hash=f171d2fd0541]
    public typealias PersistentPtySnapshot = PersistentPtySchema.Snapshot
    // parity: client/src/promise/generated/types.ts#FormField1 [status=implemented hash=b715bf745e6e]
    public typealias FormField1 = FormSchema.Field
    // parity: client/src/promise/generated/types.ts#FormReplied [status=implemented hash=335fb5199eb5]
    public typealias FormReplied = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#AutomationTrigger [status=implemented hash=58cd5d142065]
    public typealias AutomationTrigger = AutomationSchema.Trigger
    // parity: client/src/promise/generated/types.ts#ArtifactContent [status=implemented hash=1b2da4e73e2a]
    public typealias ArtifactContent = ArtifactSchema.Content
    // parity: client/src/promise/generated/types.ts#JobInfo [status=implemented hash=b3c1311aee6d]
    public typealias JobInfo = JobSchema.Info
    // parity: client/src/promise/generated/types.ts#SessionInboxMove [status=implemented hash=92eb58d8b764]
    public typealias SessionInboxMove = SessionInboxSchema.Move
    // parity: client/src/promise/generated/types.ts#ReferenceInfo [status=implemented hash=4e50342e9062]
    public typealias ReferenceInfo = ReferenceSchema.Info
    // parity: client/src/promise/generated/types.ts#SessionMessageCompaction [status=implemented hash=df335d12bd55]
    public typealias SessionMessageCompaction = SessionMessageSchema.Compaction
    // parity: client/src/promise/generated/types.ts#SessionStatsInfo [status=implemented hash=82429abda7e6]
    public typealias SessionStatsInfo = SessionStatsSchema.Info
    // parity: client/src/promise/generated/types.ts#ProviderRequest [status=implemented hash=ac3b007d4fe2]
    public typealias ProviderRequest = ProviderSchema.Request
    // parity: client/src/promise/generated/types.ts#ProviderInfo [status=implemented hash=1dd748d70aae]
    public typealias ProviderInfo = ProviderSchema.Info
    // parity: client/src/promise/generated/types.ts#ModelInfo [status=implemented hash=de2ac8cdbc71]
    public typealias ModelInfo = ModelSchema.Info
    // parity: client/src/promise/generated/types.ts#SessionInfo [status=implemented hash=d2b916bdeb2a]
    public typealias SessionInfo = SessionSchema.Info
    // parity: client/src/promise/generated/types.ts#SessionCreated [status=implemented hash=49cde4776bd4]
    public typealias SessionCreated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionPermissions [status=implemented hash=dbb835113dd0]
    public typealias SessionPermissions = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#ConfigEntry [status=implemented hash=8402a3f01239]
    public typealias ConfigEntry = ConfigSchema.Entry
    // parity: client/src/promise/generated/types.ts#AutomationAction [status=implemented hash=d3beed292bfa]
    public typealias AutomationAction = AutomationSchema.Action
    // parity: client/src/promise/generated/types.ts#UsageLimitsInfo [status=implemented hash=a771873d4830]
    public typealias UsageLimitsInfo = UsageLimitsSchema.Info
    // parity: client/src/promise/generated/types.ts#GenerateImageResponse [status=implemented hash=ee33ab01abd8]
    public typealias GenerateImageResponse = ClientDataEnvelope<GenerateSchema.ImageResult>
    // parity: client/src/promise/generated/types.ts#SessionInboxUser [status=implemented hash=62da3bb95f24]
    public typealias SessionInboxUser = SessionInboxSchema.User
    // parity: client/src/promise/generated/types.ts#SessionMessageAssistantTool [status=implemented hash=a9eb1af3233b]
    public typealias SessionMessageAssistantTool = SessionMessageSchema.AssistantTool
    // parity: client/src/promise/generated/types.ts#FormFields [status=implemented hash=c7a26b668228]
    public typealias FormFields = FormSchema.Fields
    // parity: client/src/promise/generated/types.ts#SessionInboxItem [status=implemented hash=bdeb60485470]
    public typealias SessionInboxItem = SessionInboxSchema.Item
    // parity: client/src/promise/generated/types.ts#SessionMessageAssistantTool1 [status=implemented hash=9d59c09f25ed]
    public typealias SessionMessageAssistantTool1 = SessionMessageSchema.AssistantTool
    // parity: client/src/promise/generated/types.ts#GenerateVideoJob [status=implemented hash=109bcfccb2be]
    public typealias GenerateVideoJob = GenerateSchema.VideoJob
    // parity: client/src/promise/generated/types.ts#GenerateDecisionResult [status=implemented hash=b576278ff585]
    public typealias GenerateDecisionResult = GenerateSchema.DecisionResult
    // parity: client/src/promise/generated/types.ts#CredentialEntry [status=implemented hash=56f7dbe9939e]
    public typealias CredentialEntry = CredentialSchema.Entry
    // parity: client/src/promise/generated/types.ts#FormFields1 [status=implemented hash=20ec263b4a8e]
    public typealias FormFields1 = FormSchema.Fields
    // parity: client/src/promise/generated/types.ts#AgentInfo [status=implemented hash=7871ac104c21]
    public typealias AgentInfo = AgentSchema.Info
    // parity: client/src/promise/generated/types.ts#AutomationInfo [status=implemented hash=29fb9b987802]
    public typealias AutomationInfo = AutomationSchema.Info
    // parity: client/src/promise/generated/types.ts#SessionInboxInfo [status=implemented hash=a374ba80b426]
    public typealias SessionInboxInfo = SessionInboxSchema.Info
    // parity: client/src/promise/generated/types.ts#SessionMessageAssistant [status=implemented hash=732cbb94b540]
    public typealias SessionMessageAssistant = SessionMessageSchema.Assistant
    // parity: client/src/promise/generated/types.ts#FormInfo [status=implemented hash=e79283d190fe]
    public typealias FormInfo = FormSchema.Info
    // parity: client/src/promise/generated/types.ts#FormDetail [status=implemented hash=228d0b17f085]
    public typealias FormDetail = FormSchema.Detail
    // parity: client/src/promise/generated/types.ts#IntegrationOAuthMethod [status=implemented hash=ace4dc00923e]
    public typealias IntegrationOAuthMethod = IntegrationSchema.OAuthMethod
    // parity: client/src/promise/generated/types.ts#IntegrationKeyMethod [status=implemented hash=67e541aa6d84]
    public typealias IntegrationKeyMethod = IntegrationSchema.KeyMethod
    // parity: client/src/promise/generated/types.ts#IntegrationExternalMethod [status=implemented hash=b557d2a854eb]
    public typealias IntegrationExternalMethod = IntegrationSchema.ExternalMethod
    // parity: client/src/promise/generated/types.ts#SessionInboxEnqueued [status=implemented hash=a8a7de2fa1dc]
    public typealias SessionInboxEnqueued = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionMessageAssistantContentEncoded [status=implemented hash=8cff3ad8c0af]
    public typealias SessionMessageAssistantContentEncoded = SessionMessageSchema.AssistantContentEncoded
    // parity: client/src/promise/generated/types.ts#GenerateVideoGetResponse [status=implemented hash=972b73e25370]
    public typealias GenerateVideoGetResponse = ClientDataEnvelope<GenerateSchema.VideoJob>
    // parity: client/src/promise/generated/types.ts#GenerateDecisionsResponse [status=implemented hash=f27106f46639]
    public typealias GenerateDecisionsResponse = ClientDataEnvelope<GenerateSchema.DecisionResult>
    // parity: client/src/promise/generated/types.ts#FormInfo1 [status=implemented hash=ac36ae6ec538]
    public typealias FormInfo1 = FormSchema.Info
    // parity: client/src/promise/generated/types.ts#SessionMessageInfo [status=implemented hash=73b1a2093f23]
    public typealias SessionMessageInfo = SessionMessageSchema.Info
    // parity: client/src/promise/generated/types.ts#IntegrationMethod [status=implemented hash=e48303ea25b7]
    public typealias IntegrationMethod = IntegrationSchema.Method
    // parity: client/src/promise/generated/types.ts#SessionMessageContentUpdated [status=implemented hash=ef7cf2e1c652]
    public typealias SessionMessageContentUpdated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#FormCreated [status=implemented hash=eb61295b2d6e]
    public typealias FormCreated = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#SessionTransferData [status=implemented hash=d479aef20462]
    public typealias SessionTransferData = SessionTransferSchema.Data
    // parity: client/src/promise/generated/types.ts#IntegrationInfo [status=implemented hash=67080374447c]
    public typealias IntegrationInfo = IntegrationSchema.Info
    // parity: client/src/promise/generated/types.ts#SessionEventDurable [status=implemented hash=8df683f228df]
    public typealias SessionEventDurable = SessionEventSchema.DurableEvent
    // parity: client/src/promise/generated/types.ts#V2Event [status=implemented hash=846c84da91fc]
    public typealias V2Event = OpenCodeProtocol.OpenCodeEvent
    // parity: client/src/promise/generated/types.ts#InvalidRequestError [status=implemented hash=b1b30e11e45e]
    public typealias InvalidRequestError = OpenCodeProtocol.InvalidRequestError
    // parity: client/src/promise/generated/types.ts#UnauthorizedError [status=implemented hash=ca226579249f]
    public typealias UnauthorizedError = OpenCodeProtocol.UnauthorizedError
    // parity: client/src/promise/generated/types.ts#LocationNotFoundError [status=implemented hash=aa0631a44654]
    public typealias LocationNotFoundError = OpenCodeProtocol.LocationNotFoundError
    // parity: client/src/promise/generated/types.ts#ServiceUnavailableError [status=implemented hash=52da8fc1754e]
    public typealias ServiceUnavailableError = OpenCodeProtocol.ServiceUnavailableError
    // parity: client/src/promise/generated/types.ts#AgentNotFoundError [status=implemented hash=59e941617dce]
    public typealias AgentNotFoundError = OpenCodeProtocol.AgentNotFoundError
    // parity: client/src/promise/generated/types.ts#PluginNotFoundError [status=implemented hash=77d2ff47d03c]
    public typealias PluginNotFoundError = OpenCodeProtocol.PluginNotFoundError
    // parity: client/src/promise/generated/types.ts#InvalidCursorError [status=implemented hash=fc1754dfa9df]
    public typealias InvalidCursorError = OpenCodeProtocol.InvalidCursorError
    // parity: client/src/promise/generated/types.ts#SessionNotFoundError [status=implemented hash=86c3493e21cb]
    public typealias SessionNotFoundError = OpenCodeProtocol.SessionNotFoundError
    // parity: client/src/promise/generated/types.ts#MessageNotFoundError [status=implemented hash=26996483b718]
    public typealias MessageNotFoundError = OpenCodeProtocol.MessageNotFoundError
    // parity: client/src/promise/generated/types.ts#ConflictError [status=implemented hash=200dacadcdaa]
    public typealias ConflictError = OpenCodeProtocol.ConflictError
    // parity: client/src/promise/generated/types.ts#CommandNotFoundError [status=implemented hash=64f0575595a1]
    public typealias CommandNotFoundError = OpenCodeProtocol.CommandNotFoundError
    // parity: client/src/promise/generated/types.ts#CommandExecutionError [status=implemented hash=3e0efca0d7c4]
    public typealias CommandExecutionError = OpenCodeProtocol.CommandExecutionError
    // parity: client/src/promise/generated/types.ts#SessionBusyError [status=implemented hash=e36b7e657504]
    public typealias SessionBusyError = OpenCodeProtocol.SessionBusyError
    // parity: client/src/promise/generated/types.ts#UnknownError [status=implemented hash=04f97f03f97e]
    public typealias UnknownError = OpenCodeProtocol.UnknownError
    // parity: client/src/promise/generated/types.ts#FormNotFoundError [status=implemented hash=12765f3277aa]
    public typealias FormNotFoundError = OpenCodeProtocol.FormNotFoundError
    // parity: client/src/promise/generated/types.ts#FormInvalidAnswerError [status=implemented hash=b0e795b6b89b]
    public typealias FormInvalidAnswerError = OpenCodeProtocol.FormInvalidAnswerError
    // parity: client/src/promise/generated/types.ts#FormAlreadySettledError [status=implemented hash=49f7d45149f8]
    public typealias FormAlreadySettledError = OpenCodeProtocol.FormAlreadySettledError
    // parity: client/src/promise/generated/types.ts#SkillNotFoundError [status=implemented hash=15a4f945d7a5]
    public typealias SkillNotFoundError = OpenCodeProtocol.SkillNotFoundError
    // parity: client/src/promise/generated/types.ts#InstructionEntryValueTooLargeError [status=implemented hash=654503e6fff9]
    public typealias InstructionEntryValueTooLargeError = InstructionEntrySchema.ValueTooLargeError
    // parity: client/src/promise/generated/types.ts#ProviderNotFoundError [status=implemented hash=1e9bbdb5daf2]
    public typealias ProviderNotFoundError = OpenCodeProtocol.ProviderNotFoundError
    // parity: client/src/promise/generated/types.ts#ModelNotFoundError [status=implemented hash=2b6949aef881]
    public typealias ModelNotFoundError = OpenCodeProtocol.ModelNotFoundError
    // parity: client/src/promise/generated/types.ts#UnsupportedModelError [status=implemented hash=c910b643fd44]
    public typealias UnsupportedModelError = OpenCodeProtocol.UnsupportedModelError
    // parity: client/src/promise/generated/types.ts#ProviderRequestError [status=implemented hash=16989b3d9ee0]
    public typealias ProviderRequestError = OpenCodeProtocol.ProviderRequestError
    // parity: client/src/promise/generated/types.ts#ForbiddenError [status=implemented hash=d8c7413a2281]
    public typealias ForbiddenError = OpenCodeProtocol.ForbiddenError
    // parity: client/src/promise/generated/types.ts#VideoNotFoundError [status=implemented hash=b5a376941b4e]
    public typealias VideoNotFoundError = OpenCodeProtocol.VideoNotFoundError
    // parity: client/src/promise/generated/types.ts#IntegrationNotFoundError [status=implemented hash=4a9e7ce3ab18]
    public typealias IntegrationNotFoundError = OpenCodeProtocol.IntegrationNotFoundError
    // parity: client/src/promise/generated/types.ts#IntegrationAttemptNotFoundError [status=implemented hash=9ea9d7913576]
    public typealias IntegrationAttemptNotFoundError = OpenCodeProtocol.IntegrationAttemptNotFoundError
    // parity: client/src/promise/generated/types.ts#IntegrationMethodNotFoundError [status=implemented hash=2ce543e401b1]
    public typealias IntegrationMethodNotFoundError = OpenCodeProtocol.IntegrationMethodNotFoundError
    // parity: client/src/promise/generated/types.ts#McpServerNotFoundError [status=implemented hash=f5fdf875fece]
    public typealias McpServerNotFoundError = OpenCodeProtocol.McpServerNotFoundError
    // parity: client/src/promise/generated/types.ts#ProjectNotFoundError [status=implemented hash=c274489d6e3c]
    public typealias ProjectNotFoundError = OpenCodeProtocol.ProjectNotFoundError
    // parity: client/src/promise/generated/types.ts#PermissionSavedNotFoundError [status=implemented hash=df86cf5d5c2c]
    public typealias PermissionSavedNotFoundError = OpenCodeProtocol.PermissionSavedNotFoundError
    // parity: client/src/promise/generated/types.ts#PermissionNotFoundError [status=implemented hash=fb40b1cf9f4e]
    public typealias PermissionNotFoundError = OpenCodeProtocol.PermissionNotFoundError
    // parity: client/src/promise/generated/types.ts#FileNotFoundError [status=implemented hash=74c4fb6d7b8f]
    public typealias FileNotFoundError = OpenCodeProtocol.FileNotFoundError
    // parity: client/src/promise/generated/types.ts#RpcError [status=implemented hash=4c04c49a7593]
    public typealias RpcError = OpenCodeProtocol.RpcError
    // parity: client/src/promise/generated/types.ts#RpcInternalError [status=implemented hash=053e497c8cef]
    public typealias RpcInternalError = OpenCodeProtocol.RpcInternalError
    // parity: client/src/promise/generated/types.ts#PtyNotFoundError [status=implemented hash=5fc7c1d90fce]
    public typealias PtyNotFoundError = OpenCodeProtocol.PtyNotFoundError
    // parity: client/src/promise/generated/types.ts#PtyFeatureUnsupportedError [status=implemented hash=22fed54b4c0e]
    public typealias PtyFeatureUnsupportedError = OpenCodeProtocol.PtyFeatureUnsupportedError
    // parity: client/src/promise/generated/types.ts#BlobNotFoundError [status=implemented hash=af42463d642d]
    public typealias BlobNotFoundError = OpenCodeProtocol.BlobNotFoundError
    // parity: client/src/promise/generated/types.ts#AutomationNotFoundError [status=implemented hash=8dfba690db45]
    public typealias AutomationNotFoundError = OpenCodeProtocol.AutomationNotFoundError
    // parity: client/src/promise/generated/types.ts#ArtifactNotFoundError [status=implemented hash=7346dcc5a6ea]
    public typealias ArtifactNotFoundError = OpenCodeProtocol.ArtifactNotFoundError
    // parity: client/src/promise/generated/types.ts#ShellNotFoundError [status=implemented hash=2bd61f44e3c5]
    public typealias ShellNotFoundError = OpenCodeProtocol.ShellNotFoundError
    // parity: client/src/promise/generated/types.ts#WorktreeError [status=implemented hash=420e5177c94a]
    public typealias WorktreeError = OpenCodeProtocol.WorktreeError
    // parity: client/src/promise/generated/types.ts#VcsInitNotSupportedError [status=implemented hash=513568d90b96]
    public typealias VcsInitNotSupportedError = OpenCodeProtocol.VcsInitNotSupportedError
}

// MARK: - Generated API Group Clients (All 169 Promise Endpoints Across All Groups)

public struct ServerClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func info(options: RequestOptions? = nil) async throws -> ServerInfoOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/info", successStatus: 200, declaredStatuses: [400, 401])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func pair(options: RequestOptions? = nil) async throws -> ServerPairOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/pair", successStatus: 200, declaredStatuses: [400, 401])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func connect(_ input: ServerConnectInput, options: RequestOptions? = nil) async throws -> ServerConnectOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/auth/connect/\(ClientURLBuilder.encodeURIComponent(input.code))", successStatus: 200, declaredStatuses: [400, 401])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct LocationClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func get(_ input: LocationGetInput? = nil, options: RequestOptions? = nil) async throws -> LocationGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/location", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func reload(options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/location/reload", successStatus: 204, declaredStatuses: [400, 401, 503], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct AgentClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: AgentListInput? = nil, options: RequestOptions? = nil) async throws -> AgentListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/agent", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func get(_ input: AgentGetInput, options: RequestOptions? = nil) async throws -> AgentGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/agent/\(ClientURLBuilder.encodeURIComponent(input.agentID))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct PluginClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: PluginListInput? = nil, options: RequestOptions? = nil) async throws -> PluginListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/plugin", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func gui(_ input: PluginGuiInput, options: RequestOptions? = nil) async throws -> PluginGuiOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/plugin/gui", query: [("location", encodeOptionalJSON(input.location)), ("id", encodeJSON(input.id))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func check(_ input: PluginCheckInput? = nil, options: RequestOptions? = nil) async throws -> PluginCheckOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/plugin/check", query: [("location", encodeOptionalJSON(input?.location))], body: encodeBodyFields([("target", encodeOptionalJSON(input?.target))]), successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func update(_ input: PluginUpdateInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/plugin/update", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("targets", encodeJSON(input.targets))]), successStatus: 204, declaredStatuses: [400, 401, 404, 503], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct SessionRevertClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func stage(_ input: SessionRevertStageInput, options: RequestOptions? = nil) async throws -> SessionRevertStageOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/revert/stage", body: encodeBodyFields([("messageID", encodeJSON(input.messageID)), ("files", encodeOptionalJSON(input.files))]), successStatus: 200, declaredStatuses: [400, 401, 404, 409, 500])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func clear(_ input: SessionRevertClearInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/revert", successStatus: 204, declaredStatuses: [400, 401, 404, 409, 500], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func commit(_ input: SessionRevertCommitInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/revert/commit", successStatus: 204, declaredStatuses: [400, 401, 404, 409], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct SessionInboxClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    private let mediaRefsEnabled: Bool
    public init(executor: ClientHTTPExecutor, mediaRefsEnabled: Bool = false) {
        self.executor = executor
        self.mediaRefsEnabled = mediaRefsEnabled
    }
    public func list(_ input: SessionInboxListInput, options: RequestOptions? = nil) async throws -> SessionInboxListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/inbox", successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.requestData(descriptor, requestOptions: applyMediaRefOptions(options, enabled: mediaRefsEnabled))
    }
    public func cancel(_ input: SessionInboxCancelInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/inbox/\(ClientURLBuilder.encodeURIComponent(input.inboxID))", successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func update(_ input: SessionInboxUpdateInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "PATCH", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/inbox/\(ClientURLBuilder.encodeURIComponent(input.inboxID))", body: encodeBodyFields([("delivery", encodeJSON(input.delivery))]), successStatus: 204, declaredStatuses: [400, 401, 404, 409], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct SessionMessageClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    private let mediaRefsEnabled: Bool
    public init(executor: ClientHTTPExecutor, mediaRefsEnabled: Bool = false) {
        self.executor = executor
        self.mediaRefsEnabled = mediaRefsEnabled
    }
    public func get(_ input: SessionMessageGetInput, options: RequestOptions? = nil) async throws -> SessionMessageGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/message/\(ClientURLBuilder.encodeURIComponent(input.messageID))", successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.requestData(descriptor, requestOptions: applyMediaRefOptions(options, enabled: mediaRefsEnabled))
    }
}

public struct SessionFormClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: SessionFormListInput, options: RequestOptions? = nil) async throws -> SessionFormListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/form", successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func create(_ input: SessionFormCreateInput, options: RequestOptions? = nil) async throws -> SessionFormCreateOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/form", body: encodeBodyFields([("id", encodeOptionalJSON(input.id)), ("title", encodeJSON(input.title)), ("metadata", encodeOptionalJSON(input.metadata)), ("fields", encodeJSON(input.fields))]), successStatus: 200, declaredStatuses: [400, 401, 404, 409])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func get(_ input: SessionFormGetInput, options: RequestOptions? = nil) async throws -> SessionFormGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/form/\(ClientURLBuilder.encodeURIComponent(input.formID))", successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func reply(_ input: SessionFormReplyInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/form/\(ClientURLBuilder.encodeURIComponent(input.formID))/reply", body: encodeBodyFields([("answer", encodeJSON(input.answer))]), successStatus: 204, declaredStatuses: [400, 401, 404, 409], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func cancel(_ input: SessionFormCancelInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/form/\(ClientURLBuilder.encodeURIComponent(input.formID))", query: [("message", encodeOptionalJSON(input.message))], successStatus: 204, declaredStatuses: [400, 401, 404, 409], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct SessionClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    private let mediaRefsEnabled: Bool
    public let revert: SessionRevertClientAPI
    public let inbox: SessionInboxClientAPI
    public let message: SessionMessageClientAPI
    public let form: SessionFormClientAPI
    public let instructions: ExperimentalSessionInstructionsClientAPI
    public init(executor: ClientHTTPExecutor, mediaRefsEnabled: Bool = false) {
        self.executor = executor
        self.mediaRefsEnabled = mediaRefsEnabled
        self.revert = SessionRevertClientAPI(executor: executor)
        self.inbox = SessionInboxClientAPI(executor: executor, mediaRefsEnabled: mediaRefsEnabled)
        self.message = SessionMessageClientAPI(executor: executor, mediaRefsEnabled: mediaRefsEnabled)
        self.form = SessionFormClientAPI(executor: executor)
        self.instructions = ExperimentalSessionInstructionsClientAPI(executor: executor)
    }
    public func list(_ input: SessionListInput? = nil, options: RequestOptions? = nil) async throws -> SessionListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/session", query: [("limit", encodeOptionalJSON(input?.limit)), ("order", encodeOptionalJSON(input?.order)), ("search", encodeOptionalJSON(input?.search)), ("parentID", encodeOptionalJSON(input?.parentID)), ("archived", encodeOptionalJSON(input?.archived)), ("directory", encodeOptionalJSON(input?.directory)), ("project", encodeOptionalJSON(input?.project)), ("subpath", encodeOptionalJSON(input?.subpath)), ("cursor", encodeOptionalJSON(input?.cursor))], successStatus: 200, declaredStatuses: [400, 401])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func create(_ input: SessionCreateInput? = nil, options: RequestOptions? = nil) async throws -> SessionCreateOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session", body: encodeBodyFields([("id", encodeOptionalJSON(input?.id)), ("parentID", encodeOptionalJSON(input?.parentID)), ("title", encodeOptionalJSON(input?.title)), ("agent", encodeOptionalJSON(input?.agent)), ("model", encodeOptionalJSON(input?.model)), ("location", encodeOptionalJSON(input?.location)), ("metadata", encodeOptionalJSON(input?.metadata)), ("permissions", encodeOptionalJSON(input?.permissions))]), successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func active(options: RequestOptions? = nil) async throws -> SessionActiveOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/session/active", successStatus: 200, declaredStatuses: [400, 401])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func get(_ input: SessionGetInput, options: RequestOptions? = nil) async throws -> SessionGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))", successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func remove(_ input: SessionRemoveInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))", successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func fork(_ input: SessionForkInput, options: RequestOptions? = nil) async throws -> SessionForkOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/fork", body: encodeBodyFields([("before", encodeOptionalJSON(input.before))]), successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func switchAgent(_ input: SessionSwitchAgentInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/agent", body: encodeBodyFields([("agent", encodeJSON(input.agent))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func switchModel(_ input: SessionSwitchModelInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/model", body: encodeBodyFields([("model", encodeJSON(input.model))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func update(_ input: SessionUpdateInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "PATCH", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))", body: encodeBodyFields([("title", encodeOptionalJSON(input.title)), ("metadata", encodeOptionalJSON(input.metadata)), ("permissions", encodeOptionalJSON(input.permissions)), ("archived", encodeOptionalJSON(input.archived))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func move(_ input: SessionMoveInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/move", body: encodeBodyFields([("directory", encodeJSON(input.directory)), ("delivery", encodeOptionalJSON(input.delivery))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func prompt(_ input: SessionPromptInput, options: RequestOptions? = nil) async throws -> SessionPromptOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/prompt", body: encodeBodyFields([("id", encodeOptionalJSON(input.id)), ("text", encodeJSON(input.text)), ("files", encodeOptionalJSON(input.files)), ("agents", encodeOptionalJSON(input.agents)), ("skills", encodeOptionalJSON(input.skills)), ("metadata", encodeOptionalJSON(input.metadata)), ("delivery", encodeOptionalJSON(input.delivery)), ("resume", encodeOptionalJSON(input.resume))]), successStatus: 200, declaredStatuses: [400, 401, 404, 409])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func command(_ input: SessionCommandInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/command", body: encodeBodyFields([("name", encodeJSON(input.name)), ("text", encodeJSON(input.text)), ("files", encodeOptionalJSON(input.files)), ("agents", encodeOptionalJSON(input.agents)), ("skills", encodeOptionalJSON(input.skills)), ("delivery", encodeOptionalJSON(input.delivery))]), successStatus: 204, declaredStatuses: [400, 401, 404, 500], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func synthetic(_ input: SessionSyntheticInput, options: RequestOptions? = nil) async throws -> SessionSyntheticOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/synthetic", body: encodeBodyFields([("id", encodeOptionalJSON(input.id)), ("text", encodeJSON(input.text)), ("description", encodeOptionalJSON(input.description)), ("metadata", encodeOptionalJSON(input.metadata)), ("delivery", encodeOptionalJSON(input.delivery)), ("resume", encodeOptionalJSON(input.resume))]), successStatus: 200, declaredStatuses: [400, 401, 404, 409])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func shell(_ input: SessionShellInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/shell", body: encodeBodyFields([("id", encodeOptionalJSON(input.id)), ("command", encodeJSON(input.command))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func compact(_ input: SessionCompactInput, options: RequestOptions? = nil) async throws -> SessionCompactOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/compact", body: encodeBodyFields([("id", encodeOptionalJSON(input.id)), ("delivery", encodeOptionalJSON(input.delivery))]), successStatus: 200, declaredStatuses: [400, 401, 404, 409])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func context(_ input: SessionContextInput, options: RequestOptions? = nil) async throws -> SessionContextOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/context", successStatus: 200, declaredStatuses: [400, 401, 404, 500])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func diff(_ input: SessionDiffInput, options: RequestOptions? = nil) async throws -> SessionDiffOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/diff", query: [("from", encodeOptionalJSON(input.from)), ("to", encodeOptionalJSON(input.to)), ("context", encodeOptionalJSON(input.context))], successStatus: 200, declaredStatuses: [400, 401, 404, 500])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func generate(_ input: SessionGenerateInput, options: RequestOptions? = nil) async throws -> SessionGenerateOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/generate", body: encodeBodyFields([("prompt", encodeJSON(input.prompt))]), successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func interrupt(_ input: SessionInterruptInput, options: RequestOptions? = nil) async throws -> SessionInterruptOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/interrupt", query: [("resume", encodeOptionalJSON(input.resume))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func background(_ input: SessionBackgroundInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/background", successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func environment(_ input: SessionEnvironmentInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "PUT", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/environment", body: encodeBodyFields([("variables", encodeJSON(input.variables))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func view(_ input: SessionViewInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/view", body: encodeBodyFields([("idle", encodeJSON(input.idle))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func stats(_ input: SessionStatsInput? = nil, options: RequestOptions? = nil) async throws -> SessionStatsOutput { try await ExperimentalSessionClientAPI(executor: executor).stats(input, options: options) }
    public func `import`(_ input: SessionImportInput, options: RequestOptions? = nil) async throws -> SessionImportOutput { try await ExperimentalSessionClientAPI(executor: executor).`import`(input, options: options) }
    public func export(_ input: SessionExportInput, options: RequestOptions? = nil) async throws -> SessionExportOutput { try await ExperimentalSessionClientAPI(executor: executor).export(input, options: options) }
    public func skill(_ input: SessionSkillInput, options: RequestOptions? = nil) async throws { try await ExperimentalSessionClientAPI(executor: executor).skill(input, options: options) }
    public func wait(_ input: SessionWaitInput, options: RequestOptions? = nil) async throws { try await ExperimentalSessionClientAPI(executor: executor).wait(input, options: options) }
    public func log(_ input: SessionLogInput, options: RequestOptions? = nil) -> AsyncThrowingStream<SessionLogOutput, any Error> { ExperimentalSessionClientAPI(executor: executor).log(input, options: options) }
}

public struct ExperimentalSessionInstructionsEntryClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: ExperimentalSessionInstructionsEntryListInput, options: RequestOptions? = nil) async throws -> ExperimentalSessionInstructionsEntryListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/instructions/entries", successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func put(_ input: ExperimentalSessionInstructionsEntryPutInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "PUT", path: "/api/experimental/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/instructions/entries/\(ClientURLBuilder.encodeURIComponent(input.key))", body: encodeBodyFields([("value", encodeJSON(input.value))]), successStatus: 204, declaredStatuses: [400, 401, 404, 413], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func remove(_ input: ExperimentalSessionInstructionsEntryRemoveInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/experimental/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/instructions/entries/\(ClientURLBuilder.encodeURIComponent(input.key))", successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct ExperimentalSessionInstructionsClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public let entry: ExperimentalSessionInstructionsEntryClientAPI
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
        self.entry = ExperimentalSessionInstructionsEntryClientAPI(executor: executor)
    }
}

public struct ExperimentalSessionClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public let instructions: ExperimentalSessionInstructionsClientAPI
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
        self.instructions = ExperimentalSessionInstructionsClientAPI(executor: executor)
    }
    public func stats(_ input: ExperimentalSessionStatsInput? = nil, options: RequestOptions? = nil) async throws -> ExperimentalSessionStatsOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/session/stats", query: [("from", encodeOptionalJSON(input?.from)), ("to", encodeOptionalJSON(input?.to)), ("project", encodeOptionalJSON(input?.project)), ("timezone", encodeOptionalJSON(input?.timezone)), ("tools", encodeOptionalJSON(input?.tools))], successStatus: 200, declaredStatuses: [400, 401])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func `import`(_ input: ExperimentalSessionImportInput, options: RequestOptions? = nil) async throws -> ExperimentalSessionImportOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/session/import", body: encodeBodyFields([("info", encodeJSON(input.info)), ("messages", encodeJSON(input.messages)), ("location", encodeOptionalJSON(input.location))]), successStatus: 200, declaredStatuses: [400, 401, 404, 409])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func export(_ input: ExperimentalSessionExportInput, options: RequestOptions? = nil) async throws -> ExperimentalSessionExportOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/export", query: [("sanitize", encodeOptionalJSON(input.sanitize))], successStatus: 200, declaredStatuses: [400, 401, 404, 500])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func skill(_ input: ExperimentalSessionSkillInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/skill", body: encodeBodyFields([("id", encodeJSON(input.id)), ("resume", encodeOptionalJSON(input.resume))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func wait(_ input: ExperimentalSessionWaitInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/wait", successStatus: 204, declaredStatuses: [400, 401, 404, 503], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func log(_ input: ExperimentalSessionLogInput, options: RequestOptions? = nil) -> AsyncThrowingStream<ExperimentalSessionLogOutput, any Error> {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/log", query: [("after", encodeOptionalJSON(input.after)), ("follow", encodeOptionalJSON(input.follow))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return executor.sse(descriptor, requestOptions: options)
    }
}

public struct ExperimentalGenerateVideoClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func create(_ input: ExperimentalGenerateVideoCreateInput, options: RequestOptions? = nil) async throws -> ExperimentalGenerateVideoCreateOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/generate/video", body: encodeBodyFields([("model", encodeJSON(input.model)), ("prompt", encodeJSON(input.prompt)), ("start", encodeOptionalJSON(input.start)), ("end", encodeOptionalJSON(input.end)), ("references", encodeOptionalJSON(input.references)), ("duration", encodeOptionalJSON(input.duration)), ("aspect", encodeOptionalJSON(input.aspect)), ("resolution", encodeOptionalJSON(input.resolution)), ("sound", encodeOptionalJSON(input.sound))]), successStatus: 200, declaredStatuses: [400, 401, 403, 404, 422, 502, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func get(_ input: ExperimentalGenerateVideoGetInput, options: RequestOptions? = nil) async throws -> ExperimentalGenerateVideoGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/generate/video/\(ClientURLBuilder.encodeURIComponent(input.id))", successStatus: 200, declaredStatuses: [400, 401, 403, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
}

public struct ExperimentalGenerateClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public let video: ExperimentalGenerateVideoClientAPI
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
        self.video = ExperimentalGenerateVideoClientAPI(executor: executor)
    }
    public func text(_ input: ExperimentalGenerateTextInput, options: RequestOptions? = nil) async throws -> ExperimentalGenerateTextOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/generate/text", body: encodeBodyFields([("prompt", encodeJSON(input.prompt)), ("model", encodeOptionalJSON(input.model))]), successStatus: 200, declaredStatuses: [400, 401, 404, 422, 502, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func image(_ input: ExperimentalGenerateImageInput, options: RequestOptions? = nil) async throws -> ExperimentalGenerateImageOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/generate/image", body: encodeBodyFields([("model", encodeJSON(input.model)), ("prompt", encodeJSON(input.prompt)), ("images", encodeOptionalJSON(input.images)), ("n", encodeOptionalJSON(input.n)), ("aspect", encodeOptionalJSON(input.aspect)), ("resolution", encodeOptionalJSON(input.resolution))]), successStatus: 200, declaredStatuses: [400, 401, 404, 422, 502, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func decisions(_ input: ExperimentalGenerateDecisionsInput, options: RequestOptions? = nil) async throws -> ExperimentalGenerateDecisionsOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/generate/decisions", body: encodeBodyFields([("model", encodeJSON(input.model)), ("input", encodeJSON(input.input)), ("questions", encodeJSON(input.questions))]), successStatus: 200, declaredStatuses: [400, 401, 404, 422, 502, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
}

public struct ExperimentalVoiceClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func models(options: RequestOptions? = nil) async throws -> ExperimentalVoiceModelsOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/voice/models", successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func session(_ input: ExperimentalVoiceSessionInput, options: RequestOptions? = nil) async throws -> ExperimentalVoiceSessionOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/voice/session", body: encodeBodyFields([("model", encodeJSON(input.model)), ("session", encodeOptionalJSON(input.session)), ("transport", encodeJSON(input.transport))]), successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
}

public struct ExperimentalIntegrationWellknownClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func add(_ input: ExperimentalIntegrationWellknownAddInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/integration/wellknown", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("url", encodeJSON(input.url))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct ExperimentalIntegrationClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public let wellknown: ExperimentalIntegrationWellknownClientAPI
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
        self.wellknown = ExperimentalIntegrationWellknownClientAPI(executor: executor)
    }
}

public struct ExperimentalMcpClientClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func token(_ input: ExperimentalMcpClientTokenInput, options: RequestOptions? = nil) async throws -> ExperimentalMcpClientTokenOutput {
        var reqHeaders: [String: String] = [:]
        if let v = input.xOpencodeTicket { reqHeaders["x-opencode-ticket"] = v }
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/client-mcp/token", query: [("location", encodeOptionalJSON(input.location)), ("name", encodeJSON(input.name))], headers: reqHeaders, successStatus: 200, declaredStatuses: [400, 401, 403, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct ExperimentalMcpClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public let client: ExperimentalMcpClientClientAPI
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
        self.client = ExperimentalMcpClientClientAPI(executor: executor)
    }
    public func add(_ input: ExperimentalMcpAddInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "PUT", path: "/api/experimental/mcp/\(ClientURLBuilder.encodeURIComponent(input.server))", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("config", encodeJSON(input.config))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func remove(_ input: ExperimentalMcpRemoveInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/experimental/mcp/\(ClientURLBuilder.encodeURIComponent(input.server))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func connect(_ input: ExperimentalMcpConnectInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/mcp/\(ClientURLBuilder.encodeURIComponent(input.server))/connect", query: [("location", encodeOptionalJSON(input.location))], successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func disconnect(_ input: ExperimentalMcpDisconnectInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/mcp/\(ClientURLBuilder.encodeURIComponent(input.server))/disconnect", query: [("location", encodeOptionalJSON(input.location))], successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct ExperimentalFileClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func write(_ input: ExperimentalFileWriteInput, options: RequestOptions? = nil) async throws -> ExperimentalFileWriteOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/fs/write", query: [("location", encodeOptionalJSON(input.location)), ("path", encodeJSON(input.path))], binaryBody: input.payload, successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func watch(_ input: ExperimentalFileWatchInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/fs/watch", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("path", encodeJSON(input.path))]), successStatus: 204, declaredStatuses: [400, 401, 404, 503], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func unwatch(_ input: ExperimentalFileUnwatchInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/experimental/fs/watch", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("path", encodeJSON(input.path))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct ExperimentalPersistentPtyClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func read(_ input: ExperimentalPersistentPtyReadInput, options: RequestOptions? = nil) async throws -> ExperimentalPersistentPtyReadOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/terminal/read", query: [("lines", encodeOptionalJSON(input.lines))], successStatus: 200, declaredStatuses: [400, 401, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func list(_ input: ExperimentalPersistentPtyListInput, options: RequestOptions? = nil) async throws -> ExperimentalPersistentPtyListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/terminal", successStatus: 200, declaredStatuses: [400, 401, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func create(_ input: ExperimentalPersistentPtyCreateInput, options: RequestOptions? = nil) async throws -> ExperimentalPersistentPtyCreateOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/terminal", body: encodeBodyFields([("command", encodeOptionalJSON(input.command)), ("args", encodeJSON(input.args)), ("cwd", encodeOptionalJSON(input.cwd)), ("title", encodeJSON(input.title)), ("env", encodeJSON(input.env)), ("size", encodeOptionalJSON(input.size))]), successStatus: 200, declaredStatuses: [400, 401, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func shutdown(options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/persistent-pty/shutdown", successStatus: 204, declaredStatuses: [400, 401, 503], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func handoff(options: RequestOptions? = nil) async throws -> ExperimentalPersistentPtyHandoffOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/persistent-pty/handoff", successStatus: 200, declaredStatuses: [400, 401, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func get(_ input: ExperimentalPersistentPtyGetInput, options: RequestOptions? = nil) async throws -> ExperimentalPersistentPtyGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/persistent-pty/\(ClientURLBuilder.encodeURIComponent(input.ptyID))", successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func update(_ input: ExperimentalPersistentPtyUpdateInput, options: RequestOptions? = nil) async throws -> ExperimentalPersistentPtyUpdateOutput {
        let descriptor = ClientRequestDescriptor(method: "PUT", path: "/api/experimental/persistent-pty/\(ClientURLBuilder.encodeURIComponent(input.ptyID))", body: encodeBodyFields([("attachmentID", encodeOptionalJSON(input.attachmentID)), ("size", encodeOptionalJSON(input.size)), ("title", encodeOptionalJSON(input.title))]), successStatus: 200, declaredStatuses: [400, 401, 404, 501, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func snapshot(_ input: ExperimentalPersistentPtySnapshotInput, options: RequestOptions? = nil) async throws -> ExperimentalPersistentPtySnapshotOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/persistent-pty/\(ClientURLBuilder.encodeURIComponent(input.ptyID))/snapshot", successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func remove(_ input: ExperimentalPersistentPtyRemoveInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/experimental/persistent-pty/\(ClientURLBuilder.encodeURIComponent(input.ptyID))", successStatus: 204, declaredStatuses: [400, 401, 404, 503], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func connectToken(_ input: ExperimentalPersistentPtyConnectTokenInput, options: RequestOptions? = nil) async throws -> ExperimentalPersistentPtyConnectTokenOutput {
        var reqHeaders: [String: String] = [:]
        if let v = input.xOpencodeTicket { reqHeaders["x-opencode-ticket"] = v }
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/persistent-pty/\(ClientURLBuilder.encodeURIComponent(input.ptyID))/connect-token", headers: reqHeaders, successStatus: 200, declaredStatuses: [400, 401, 403, 404, 503])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
}

public struct ExperimentalMediaClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func get(_ input: ExperimentalMediaGetInput, options: RequestOptions? = nil) async throws -> ExperimentalMediaGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/media/\(ClientURLBuilder.encodeURIComponent(input.hash))", successStatus: 200, declaredStatuses: [400, 401, 404], binary: true)
        return try await executor.requestBinary(descriptor, requestOptions: options)
    }
}

public struct ExperimentalBlobClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func get(_ input: ExperimentalBlobGetInput, options: RequestOptions? = nil) async throws -> ExperimentalBlobGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/blob/\(ClientURLBuilder.encodeURIComponent(input.id))", successStatus: 200, declaredStatuses: [400, 401, 404], binary: true)
        return try await executor.requestBinary(descriptor, requestOptions: options)
    }
}

public struct ExperimentalAutomationClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func create(_ input: ExperimentalAutomationCreateInput, options: RequestOptions? = nil) async throws -> ExperimentalAutomationCreateOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/automation", body: encodeBodyFields([("sessionID", encodeOptionalJSON(input.sessionID)), ("directory", encodeOptionalJSON(input.directory)), ("name", encodeJSON(input.name)), ("trigger", encodeJSON(input.trigger)), ("action", encodeJSON(input.action)), ("expires", encodeOptionalJSON(input.expires))]), successStatus: 200, declaredStatuses: [400, 401, 403, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func list(_ input: ExperimentalAutomationListInput? = nil, options: RequestOptions? = nil) async throws -> ExperimentalAutomationListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/automation", query: [("sessionID", encodeOptionalJSON(input?.sessionID)), ("directory", encodeOptionalJSON(input?.directory))], successStatus: 200, declaredStatuses: [400, 401, 403, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func get(_ input: ExperimentalAutomationGetInput, options: RequestOptions? = nil) async throws -> ExperimentalAutomationGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/automation/\(ClientURLBuilder.encodeURIComponent(input.automationID))", successStatus: 200, declaredStatuses: [400, 401, 403, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func pause(_ input: ExperimentalAutomationPauseInput, options: RequestOptions? = nil) async throws -> ExperimentalAutomationPauseOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/automation/\(ClientURLBuilder.encodeURIComponent(input.automationID))/pause", successStatus: 200, declaredStatuses: [400, 401, 403, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func resume(_ input: ExperimentalAutomationResumeInput, options: RequestOptions? = nil) async throws -> ExperimentalAutomationResumeOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/automation/\(ClientURLBuilder.encodeURIComponent(input.automationID))/resume", successStatus: 200, declaredStatuses: [400, 401, 403, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func delete(_ input: ExperimentalAutomationDeleteInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/experimental/automation/\(ClientURLBuilder.encodeURIComponent(input.automationID))", successStatus: 204, declaredStatuses: [400, 401, 403, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct ExperimentalArtifactsClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func providers(_ input: ExperimentalArtifactsProvidersInput? = nil, options: RequestOptions? = nil) async throws -> ExperimentalArtifactsProvidersOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/artifacts/providers", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 403, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func list(_ input: ExperimentalArtifactsListInput? = nil, options: RequestOptions? = nil) async throws -> ExperimentalArtifactsListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/artifacts", query: [("location", encodeOptionalJSON(input?.location)), ("sessionID", encodeOptionalJSON(input?.sessionID)), ("provider", encodeOptionalJSON(input?.provider))], successStatus: 200, declaredStatuses: [400, 401, 403, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func create(_ input: ExperimentalArtifactsCreateInput, options: RequestOptions? = nil) async throws -> ExperimentalArtifactsCreateOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/experimental/artifacts", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("title", encodeJSON(input.title)), ("files", encodeJSON(input.files)), ("entry", encodeOptionalJSON(input.entry)), ("provider", encodeOptionalJSON(input.provider)), ("sessionID", encodeOptionalJSON(input.sessionID))]), successStatus: 200, declaredStatuses: [400, 401, 403, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func get(_ input: ExperimentalArtifactsGetInput, options: RequestOptions? = nil) async throws -> ExperimentalArtifactsGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/artifacts/\(ClientURLBuilder.encodeURIComponent(input.artifactID))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 200, declaredStatuses: [400, 401, 403, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func update(_ input: ExperimentalArtifactsUpdateInput, options: RequestOptions? = nil) async throws -> ExperimentalArtifactsUpdateOutput {
        let descriptor = ClientRequestDescriptor(method: "PATCH", path: "/api/experimental/artifacts/\(ClientURLBuilder.encodeURIComponent(input.artifactID))", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("title", encodeOptionalJSON(input.title)), ("files", encodeJSON(input.files)), ("entry", encodeOptionalJSON(input.entry)), ("sessionID", encodeOptionalJSON(input.sessionID))]), successStatus: 200, declaredStatuses: [400, 401, 403, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func delete(_ input: ExperimentalArtifactsDeleteInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/experimental/artifacts/\(ClientURLBuilder.encodeURIComponent(input.artifactID))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 204, declaredStatuses: [400, 401, 403, 404, 503], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func view(_ input: ExperimentalArtifactsViewInput, options: RequestOptions? = nil) async throws -> ExperimentalArtifactsViewOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/artifacts/\(ClientURLBuilder.encodeURIComponent(input.artifactID))/view/\(ClientURLBuilder.encodePath(input.path))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 200, declaredStatuses: [400, 401, 403, 404, 503], binary: true)
        return try await executor.requestBinary(descriptor, requestOptions: options)
    }
}

public struct ExperimentalJobClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: ExperimentalJobListInput? = nil, options: RequestOptions? = nil) async throws -> ExperimentalJobListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/job", query: [("sessionID", encodeOptionalJSON(input?.sessionID)), ("kind", encodeOptionalJSON(input?.kind)), ("status", encodeOptionalJSON(input?.status)), ("descendants", encodeOptionalJSON(input?.descendants))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
}

public struct ExperimentalMigrationV1ClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func status(options: RequestOptions? = nil) async throws -> ExperimentalMigrationV1StatusOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/migration/v1", successStatus: 200, declaredStatuses: [400, 401])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct ExperimentalMigrationClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public let v1: ExperimentalMigrationV1ClientAPI
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
        self.v1 = ExperimentalMigrationV1ClientAPI(executor: executor)
    }
}

public struct ExperimentalUsageClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func limits(_ input: ExperimentalUsageLimitsInput? = nil, options: RequestOptions? = nil) async throws -> ExperimentalUsageLimitsOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/experimental/usage/limits", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct ExperimentalConfigClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func update(_ input: ExperimentalConfigUpdateInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "PATCH", path: "/api/experimental/config", body: encodeBodyFields([("shell", encodeJSON(input.shell))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct ExperimentalClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public let session: ExperimentalSessionClientAPI
    public let generate: ExperimentalGenerateClientAPI
    public let voice: ExperimentalVoiceClientAPI
    public let integration: ExperimentalIntegrationClientAPI
    public let mcp: ExperimentalMcpClientAPI
    public let file: ExperimentalFileClientAPI
    public let persistentPty: ExperimentalPersistentPtyClientAPI
    public let media: ExperimentalMediaClientAPI
    public let blob: ExperimentalBlobClientAPI
    public let automation: ExperimentalAutomationClientAPI
    public let artifacts: ExperimentalArtifactsClientAPI
    public let job: ExperimentalJobClientAPI
    public let migration: ExperimentalMigrationClientAPI
    public let usage: ExperimentalUsageClientAPI
    public let config: ExperimentalConfigClientAPI
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
        self.session = ExperimentalSessionClientAPI(executor: executor)
        self.generate = ExperimentalGenerateClientAPI(executor: executor)
        self.voice = ExperimentalVoiceClientAPI(executor: executor)
        self.integration = ExperimentalIntegrationClientAPI(executor: executor)
        self.mcp = ExperimentalMcpClientAPI(executor: executor)
        self.file = ExperimentalFileClientAPI(executor: executor)
        self.persistentPty = ExperimentalPersistentPtyClientAPI(executor: executor)
        self.media = ExperimentalMediaClientAPI(executor: executor)
        self.blob = ExperimentalBlobClientAPI(executor: executor)
        self.automation = ExperimentalAutomationClientAPI(executor: executor)
        self.artifacts = ExperimentalArtifactsClientAPI(executor: executor)
        self.job = ExperimentalJobClientAPI(executor: executor)
        self.migration = ExperimentalMigrationClientAPI(executor: executor)
        self.usage = ExperimentalUsageClientAPI(executor: executor)
        self.config = ExperimentalConfigClientAPI(executor: executor)
    }
}

public struct MessageClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    private let mediaRefsEnabled: Bool
    public init(executor: ClientHTTPExecutor, mediaRefsEnabled: Bool = false) {
        self.executor = executor
        self.mediaRefsEnabled = mediaRefsEnabled
    }
    public func list(_ input: MessageListInput, options: RequestOptions? = nil) async throws -> MessageListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/message", query: [("limit", encodeOptionalJSON(input.limit)), ("order", encodeOptionalJSON(input.order)), ("cursor", encodeOptionalJSON(input.cursor)), ("type", encodeOptionalJSON(input.`type`))], successStatus: 200, declaredStatuses: [400, 401, 404, 500])
        return try await executor.request(descriptor, requestOptions: applyMediaRefOptions(options, enabled: mediaRefsEnabled))
    }
}

public struct ModelClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: ModelListInput? = nil, options: RequestOptions? = nil) async throws -> ModelListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/model", query: [("location", encodeOptionalJSON(input?.location)), ("types", encodeOptionalJSON(input?.types))], successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func `default`(_ input: ModelDefaultInput? = nil, options: RequestOptions? = nil) async throws -> ModelDefaultOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/model/default", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct ProviderClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: ProviderListInput? = nil, options: RequestOptions? = nil) async throws -> ProviderListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/provider", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func get(_ input: ProviderGetInput, options: RequestOptions? = nil) async throws -> ProviderGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/provider/\(ClientURLBuilder.encodeURIComponent(input.providerID))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct IntegrationConnectClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func key(_ input: IntegrationConnectKeyInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/integration/\(ClientURLBuilder.encodeURIComponent(input.integrationID))/connect/key", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("key", encodeJSON(input.key)), ("answer", encodeOptionalJSON(input.answer)), ("label", encodeOptionalJSON(input.label))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func external(_ input: IntegrationConnectExternalInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/integration/\(ClientURLBuilder.encodeURIComponent(input.integrationID))/connect/external", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("methodID", encodeJSON(input.methodID)), ("answer", encodeOptionalJSON(input.answer)), ("label", encodeOptionalJSON(input.label))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct IntegrationOauthClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func connect(_ input: IntegrationOauthConnectInput, options: RequestOptions? = nil) async throws -> IntegrationOauthConnectOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/integration/\(ClientURLBuilder.encodeURIComponent(input.integrationID))/connect/oauth", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("methodID", encodeJSON(input.methodID)), ("answer", encodeOptionalJSON(input.answer)), ("label", encodeOptionalJSON(input.label))]), successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func status(_ input: IntegrationOauthStatusInput, options: RequestOptions? = nil) async throws -> IntegrationOauthStatusOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/integration/\(ClientURLBuilder.encodeURIComponent(input.integrationID))/connect/oauth/\(ClientURLBuilder.encodeURIComponent(input.attemptID))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func complete(_ input: IntegrationOauthCompleteInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/integration/\(ClientURLBuilder.encodeURIComponent(input.integrationID))/connect/oauth/\(ClientURLBuilder.encodeURIComponent(input.attemptID))/complete", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("code", encodeOptionalJSON(input.code))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func cancel(_ input: IntegrationOauthCancelInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/integration/\(ClientURLBuilder.encodeURIComponent(input.integrationID))/connect/oauth/\(ClientURLBuilder.encodeURIComponent(input.attemptID))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct IntegrationCommandClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func connect(_ input: IntegrationCommandConnectInput, options: RequestOptions? = nil) async throws -> IntegrationCommandConnectOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/integration/\(ClientURLBuilder.encodeURIComponent(input.integrationID))/connect/command", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("methodID", encodeJSON(input.methodID)), ("label", encodeOptionalJSON(input.label))]), successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func status(_ input: IntegrationCommandStatusInput, options: RequestOptions? = nil) async throws -> IntegrationCommandStatusOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/integration/\(ClientURLBuilder.encodeURIComponent(input.integrationID))/connect/command/\(ClientURLBuilder.encodeURIComponent(input.attemptID))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func cancel(_ input: IntegrationCommandCancelInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/integration/\(ClientURLBuilder.encodeURIComponent(input.integrationID))/connect/command/\(ClientURLBuilder.encodeURIComponent(input.attemptID))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct IntegrationClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public let connect: IntegrationConnectClientAPI
    public let oauth: IntegrationOauthClientAPI
    public let command: IntegrationCommandClientAPI
    public let wellknown: ExperimentalIntegrationWellknownClientAPI
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
        self.connect = IntegrationConnectClientAPI(executor: executor)
        self.oauth = IntegrationOauthClientAPI(executor: executor)
        self.command = IntegrationCommandClientAPI(executor: executor)
        self.wellknown = ExperimentalIntegrationWellknownClientAPI(executor: executor)
    }
    public func list(_ input: IntegrationListInput? = nil, options: RequestOptions? = nil) async throws -> IntegrationListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/integration", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func get(_ input: IntegrationGetInput, options: RequestOptions? = nil) async throws -> IntegrationGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/integration/\(ClientURLBuilder.encodeURIComponent(input.integrationID))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct McpResourceClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func catalog(_ input: McpResourceCatalogInput? = nil, options: RequestOptions? = nil) async throws -> McpResourceCatalogOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/mcp/resource", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct McpClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public let resource: McpResourceClientAPI
    public let client: ExperimentalMcpClientClientAPI
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
        self.resource = McpResourceClientAPI(executor: executor)
        self.client = ExperimentalMcpClientClientAPI(executor: executor)
    }
    public func list(_ input: McpListInput? = nil, options: RequestOptions? = nil) async throws -> McpListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/mcp", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func add(_ input: McpAddInput, options: RequestOptions? = nil) async throws { try await ExperimentalMcpClientAPI(executor: executor).add(input, options: options) }
    public func remove(_ input: McpRemoveInput, options: RequestOptions? = nil) async throws { try await ExperimentalMcpClientAPI(executor: executor).remove(input, options: options) }
    public func connect(_ input: McpConnectInput, options: RequestOptions? = nil) async throws { try await ExperimentalMcpClientAPI(executor: executor).connect(input, options: options) }
    public func disconnect(_ input: McpDisconnectInput, options: RequestOptions? = nil) async throws { try await ExperimentalMcpClientAPI(executor: executor).disconnect(input, options: options) }
}

public struct CredentialClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(options: RequestOptions? = nil) async throws -> CredentialListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/credential", successStatus: 200, declaredStatuses: [400, 401])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func create(_ input: CredentialCreateInput, options: RequestOptions? = nil) async throws -> CredentialCreateOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/credential", body: encodeBodyFields([("id", encodeOptionalJSON(input.id)), ("integrationID", encodeJSON(input.integrationID)), ("label", encodeOptionalJSON(input.label)), ("value", encodeJSON(input.value)), ("activate", encodeOptionalJSON(input.activate))]), successStatus: 200, declaredStatuses: [400, 401, 409])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func update(_ input: CredentialUpdateInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "PATCH", path: "/api/credential/\(ClientURLBuilder.encodeURIComponent(input.credentialID))", body: encodeBodyFields([("label", encodeJSON(input.label))]), successStatus: 204, declaredStatuses: [400, 401], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func activate(_ input: CredentialActivateInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/credential/\(ClientURLBuilder.encodeURIComponent(input.credentialID))/activate", successStatus: 204, declaredStatuses: [400, 401], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func remove(_ input: CredentialRemoveInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/credential/\(ClientURLBuilder.encodeURIComponent(input.credentialID))", successStatus: 204, declaredStatuses: [400, 401], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct ProjectClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: ProjectListInput? = nil, options: RequestOptions? = nil) async throws -> ProjectListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/project", query: [("archived", encodeOptionalJSON(input?.archived))], successStatus: 200, declaredStatuses: [400, 401])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func update(_ input: ProjectUpdateInput, options: RequestOptions? = nil) async throws -> ProjectUpdateOutput {
        let descriptor = ClientRequestDescriptor(method: "PATCH", path: "/api/project/\(ClientURLBuilder.encodeURIComponent(input.projectID))", body: encodeBodyFields([("canonical", encodeOptionalJSON(input.canonical)), ("name", encodeOptionalJSON(input.name)), ("icon", encodeOptionalJSON(input.icon)), ("commands", encodeOptionalJSON(input.commands))]), successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct FormClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: FormListInput? = nil, options: RequestOptions? = nil) async throws -> FormListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/form", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct PermissionRequestClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: PermissionRequestListInput? = nil, options: RequestOptions? = nil) async throws -> PermissionRequestListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/permission/request", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct PermissionSavedClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: PermissionSavedListInput? = nil, options: RequestOptions? = nil) async throws -> PermissionSavedListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/permission/saved", query: [("projectID", encodeOptionalJSON(input?.projectID))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func update(_ input: PermissionSavedUpdateInput, options: RequestOptions? = nil) async throws -> PermissionSavedUpdateOutput {
        let descriptor = ClientRequestDescriptor(method: "PATCH", path: "/api/permission/saved/\(ClientURLBuilder.encodeURIComponent(input.id))", body: encodeBodyFields([("action", encodeOptionalJSON(input.action)), ("resource", encodeOptionalJSON(input.resource))]), successStatus: 200, declaredStatuses: [400, 401, 404, 409])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func remove(_ input: PermissionSavedRemoveInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/permission/saved/\(ClientURLBuilder.encodeURIComponent(input.id))", successStatus: 204, declaredStatuses: [400, 401], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct PermissionClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public let request: PermissionRequestClientAPI
    public let saved: PermissionSavedClientAPI
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
        self.request = PermissionRequestClientAPI(executor: executor)
        self.saved = PermissionSavedClientAPI(executor: executor)
    }
    public func create(_ input: PermissionCreateInput, options: RequestOptions? = nil) async throws -> PermissionCreateOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/permission", body: encodeBodyFields([("id", encodeOptionalJSON(input.id)), ("action", encodeJSON(input.action)), ("resources", encodeJSON(input.resources)), ("save", encodeOptionalJSON(input.save)), ("metadata", encodeOptionalJSON(input.metadata)), ("source", encodeOptionalJSON(input.source)), ("agent", encodeOptionalJSON(input.agent))]), successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func list(_ input: PermissionListInput, options: RequestOptions? = nil) async throws -> PermissionListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/permission", successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func get(_ input: PermissionGetInput, options: RequestOptions? = nil) async throws -> PermissionGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/permission/\(ClientURLBuilder.encodeURIComponent(input.requestID))", successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.requestData(descriptor, requestOptions: options)
    }
    public func reply(_ input: PermissionReplyInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/session/\(ClientURLBuilder.encodeURIComponent(input.sessionID))/permission/\(ClientURLBuilder.encodeURIComponent(input.requestID))/reply", body: encodeBodyFields([("decision", encodeJSON(input.decision)), ("message", encodeOptionalJSON(input.message))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct FileClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func read(_ input: FileReadInput, options: RequestOptions? = nil) async throws -> FileReadOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/fs/read/\(ClientURLBuilder.encodePath(input.path))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 200, declaredStatuses: [400, 401, 404], binary: true)
        return try await executor.requestBinary(descriptor, requestOptions: options)
    }
    public func list(_ input: FileListInput? = nil, options: RequestOptions? = nil) async throws -> FileListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/fs/list", query: [("location", encodeOptionalJSON(input?.location)), ("path", encodeOptionalJSON(input?.path))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func find(_ input: FileFindInput, options: RequestOptions? = nil) async throws -> FileFindOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/fs/find", query: [("location", encodeOptionalJSON(input.location)), ("query", encodeJSON(input.query)), ("type", encodeOptionalJSON(input.`type`)), ("limit", encodeOptionalJSON(input.limit))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func write(_ input: FileWriteInput, options: RequestOptions? = nil) async throws -> FileWriteOutput { try await ExperimentalFileClientAPI(executor: executor).write(input, options: options) }
    public func watch(_ input: FileWatchInput, options: RequestOptions? = nil) async throws { try await ExperimentalFileClientAPI(executor: executor).watch(input, options: options) }
    public func unwatch(_ input: FileUnwatchInput, options: RequestOptions? = nil) async throws { try await ExperimentalFileClientAPI(executor: executor).unwatch(input, options: options) }
}

public struct CommandClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: CommandListInput? = nil, options: RequestOptions? = nil) async throws -> CommandListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/command", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct SkillClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: SkillListInput? = nil, options: RequestOptions? = nil) async throws -> SkillListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/skill", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct RpcClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func call(_ input: RpcCallInput, options: RequestOptions? = nil) async throws -> RpcCallOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/rpc/\(ClientURLBuilder.encodeURIComponent(input.rpcID))/\(ClientURLBuilder.encodeURIComponent(input.method))", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("input", encodeOptionalJSON(input.input))]), successStatus: 200, declaredStatuses: [400, 401, 404, 500])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct EventClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func subscribe(_ input: EventSubscribeInput? = nil, options: RequestOptions? = nil) -> AsyncThrowingStream<EventSubscribeOutput, any Error> {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/event", query: [("types", encodeOptionalJSON(input?.types))], successStatus: 200, declaredStatuses: [400, 401])
        return executor.sse(descriptor, requestOptions: options)
    }
}

public struct PtyConnectClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func token(_ input: PtyConnectTokenInput, options: RequestOptions? = nil) async throws -> PtyConnectTokenOutput {
        var reqHeaders: [String: String] = [:]
        if let v = input.xOpencodeTicket { reqHeaders["x-opencode-ticket"] = v }
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/pty/\(ClientURLBuilder.encodeURIComponent(input.ptyID))/connect-token", query: [("location", encodeOptionalJSON(input.location))], headers: reqHeaders, successStatus: 200, declaredStatuses: [400, 401, 403, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct PtyClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public let connect: PtyConnectClientAPI
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
        self.connect = PtyConnectClientAPI(executor: executor)
    }
    public func list(_ input: PtyListInput? = nil, options: RequestOptions? = nil) async throws -> PtyListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/pty", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func create(_ input: PtyCreateInput? = nil, options: RequestOptions? = nil) async throws -> PtyCreateOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/pty", query: [("location", encodeOptionalJSON(input?.location))], body: encodeBodyFields([("command", encodeOptionalJSON(input?.command)), ("args", encodeOptionalJSON(input?.args)), ("cwd", encodeOptionalJSON(input?.cwd)), ("title", encodeOptionalJSON(input?.title)), ("env", encodeOptionalJSON(input?.env))]), successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func get(_ input: PtyGetInput, options: RequestOptions? = nil) async throws -> PtyGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/pty/\(ClientURLBuilder.encodeURIComponent(input.ptyID))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func update(_ input: PtyUpdateInput, options: RequestOptions? = nil) async throws -> PtyUpdateOutput {
        let descriptor = ClientRequestDescriptor(method: "PUT", path: "/api/pty/\(ClientURLBuilder.encodeURIComponent(input.ptyID))", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("title", encodeOptionalJSON(input.title)), ("size", encodeOptionalJSON(input.size))]), successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func remove(_ input: PtyRemoveInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/pty/\(ClientURLBuilder.encodeURIComponent(input.ptyID))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct ShellClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: ShellListInput? = nil, options: RequestOptions? = nil) async throws -> ShellListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/shell", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func create(_ input: ShellCreateInput, options: RequestOptions? = nil) async throws -> ShellCreateOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/shell", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("command", encodeJSON(input.command)), ("cwd", encodeOptionalJSON(input.cwd)), ("timeout", encodeOptionalJSON(input.timeout)), ("metadata", encodeOptionalJSON(input.metadata))]), successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func get(_ input: ShellGetInput, options: RequestOptions? = nil) async throws -> ShellGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/shell/\(ClientURLBuilder.encodeURIComponent(input.id))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func output(_ input: ShellOutputInput, options: RequestOptions? = nil) async throws -> ShellOutputOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/shell/\(ClientURLBuilder.encodeURIComponent(input.id))/output", query: [("location", encodeOptionalJSON(input.location)), ("cursor", encodeOptionalJSON(input.cursor)), ("limit", encodeOptionalJSON(input.limit))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func remove(_ input: ShellRemoveInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/shell/\(ClientURLBuilder.encodeURIComponent(input.id))", query: [("location", encodeOptionalJSON(input.location))], successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct ReferenceClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: ReferenceListInput? = nil, options: RequestOptions? = nil) async throws -> ReferenceListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/reference", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct WorktreeClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: WorktreeListInput, options: RequestOptions? = nil) async throws -> WorktreeListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/worktree", query: [("projectID", encodeJSON(input.projectID))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func create(_ input: WorktreeCreateInput, options: RequestOptions? = nil) async throws -> WorktreeCreateOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/worktree", body: encodeBodyFields([("projectID", encodeJSON(input.projectID)), ("from", encodeOptionalJSON(input.from)), ("branch", encodeOptionalJSON(input.branch)), ("directory", encodeOptionalJSON(input.directory)), ("name", encodeOptionalJSON(input.name))]), successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func remove(_ input: WorktreeRemoveInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/worktree", body: encodeBodyFields([("projectID", encodeJSON(input.projectID)), ("directory", encodeJSON(input.directory)), ("force", encodeJSON(input.force))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func refresh(_ input: WorktreeRefreshInput, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/worktree/refresh", body: encodeBodyFields([("projectID", encodeJSON(input.projectID))]), successStatus: 204, declaredStatuses: [400, 401, 404], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct VcsBranchClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(_ input: VcsBranchListInput? = nil, options: RequestOptions? = nil) async throws -> VcsBranchListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/vcs/branch", query: [("location", encodeOptionalJSON(input?.location)), ("search", encodeOptionalJSON(input?.search)), ("limit", encodeOptionalJSON(input?.limit))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct VcsClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public let branch: VcsBranchClientAPI
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
        self.branch = VcsBranchClientAPI(executor: executor)
    }
    public func initialize(_ input: VcsInitInput? = nil, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/vcs/init", query: [("location", encodeOptionalJSON(input?.location)), ("provider", encodeOptionalJSON(input?.provider))], successStatus: 204, declaredStatuses: [400, 401, 404, 409, 501, 503], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
    public func get(_ input: VcsGetInput? = nil, options: RequestOptions? = nil) async throws -> VcsGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/vcs", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func base(_ input: VcsBaseInput? = nil, options: RequestOptions? = nil) async throws -> VcsBaseOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/vcs/base", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func status(_ input: VcsStatusInput? = nil, options: RequestOptions? = nil) async throws -> VcsStatusOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/vcs/status", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func diff(_ input: VcsDiffInput, options: RequestOptions? = nil) async throws -> VcsDiffOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/vcs/diff", query: [("location", encodeOptionalJSON(input.location)), ("mode", encodeJSON(input.mode)), ("base", encodeOptionalJSON(input.base)), ("context", encodeOptionalJSON(input.context)), ("untracked", encodeOptionalJSON(input.untracked))], successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct DebugLocationClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func list(options: RequestOptions? = nil) async throws -> DebugLocationListOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/debug/location", successStatus: 200, declaredStatuses: [400, 401])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func evict(_ input: DebugLocationEvictInput? = nil, options: RequestOptions? = nil) async throws {
        let descriptor = ClientRequestDescriptor(method: "DELETE", path: "/api/debug/location", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 204, declaredStatuses: [400, 401], empty: true)
        try await executor.requestEmpty(descriptor, requestOptions: options)
    }
}

public struct DebugClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public let location: DebugLocationClientAPI
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
        self.location = DebugLocationClientAPI(executor: executor)
    }
    public func heapDump(_ input: DebugHeapDumpInput? = nil, options: RequestOptions? = nil) async throws -> DebugHeapDumpOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/debug/heap-dump", query: [("directory", encodeOptionalJSON(input?.directory))], successStatus: 200, declaredStatuses: [400, 401, 500])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct WebsearchClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func providers(_ input: WebsearchProvidersInput? = nil, options: RequestOptions? = nil) async throws -> WebsearchProvidersOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/websearch/provider", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func query(_ input: WebsearchQueryInput, options: RequestOptions? = nil) async throws -> WebsearchQueryOutput {
        let descriptor = ClientRequestDescriptor(method: "POST", path: "/api/websearch", query: [("location", encodeOptionalJSON(input.location))], body: encodeBodyFields([("query", encodeJSON(input.query)), ("providerID", encodeOptionalJSON(input.providerID))]), successStatus: 200, declaredStatuses: [400, 401, 404, 503])
        return try await executor.request(descriptor, requestOptions: options)
    }
}

public struct ConfigClientAPI: Sendable {
    private let executor: ClientHTTPExecutor
    public init(executor: ClientHTTPExecutor) {
        self.executor = executor
    }
    public func get(_ input: ConfigGetInput? = nil, options: RequestOptions? = nil) async throws -> ConfigGetOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/config", query: [("location", encodeOptionalJSON(input?.location))], successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func shells(options: RequestOptions? = nil) async throws -> ConfigShellsOutput {
        let descriptor = ClientRequestDescriptor(method: "GET", path: "/api/config/shell", successStatus: 200, declaredStatuses: [400, 401, 404])
        return try await executor.request(descriptor, requestOptions: options)
    }
    public func update(_ input: ConfigUpdateInput, options: RequestOptions? = nil) async throws { try await ExperimentalConfigClientAPI(executor: executor).update(input, options: options) }
}

/// Deprecated top-level alias of `experimental.generate`.
public struct DeprecatedGenerateClientAPI: Sendable {
    private let inner: ExperimentalGenerateClientAPI
    public init(executor: ClientHTTPExecutor) { self.inner = ExperimentalGenerateClientAPI(executor: executor) }
    public func text(_ input: GenerateTextInput, options: RequestOptions? = nil) async throws -> GenerateTextOutput { try await inner.text(input, options: options) }
    public func image(_ input: GenerateImageInput, options: RequestOptions? = nil) async throws -> GenerateImageOutput { try await inner.image(input, options: options) }
    public func decisions(_ input: GenerateDecisionsInput, options: RequestOptions? = nil) async throws -> GenerateDecisionsOutput { try await inner.decisions(input, options: options) }
}

/// Raw generated Promise client mirroring `packages/client/src/promise/generated/client.ts#make`.
public struct GeneratedOpenCodeClient: Sendable {
    public let executor: ClientHTTPExecutor
    public let server: ServerClientAPI
    public let location: LocationClientAPI
    public let agent: AgentClientAPI
    public let plugin: PluginClientAPI
    public let session: SessionClientAPI
    public let experimental: ExperimentalClientAPI
    public let message: MessageClientAPI
    public let model: ModelClientAPI
    public let provider: ProviderClientAPI
    public let integration: IntegrationClientAPI
    public let mcp: McpClientAPI
    public let credential: CredentialClientAPI
    public let project: ProjectClientAPI
    public let form: FormClientAPI
    public let permission: PermissionClientAPI
    public let file: FileClientAPI
    public let command: CommandClientAPI
    public let skill: SkillClientAPI
    public let rpc: RpcClientAPI
    public let event: EventClientAPI
    public let pty: PtyClientAPI
    public let shell: ShellClientAPI
    public let reference: ReferenceClientAPI
    public let worktree: WorktreeClientAPI
    public let vcs: VcsClientAPI
    public let debug: DebugClientAPI
    public let websearch: WebsearchClientAPI
    public let config: ConfigClientAPI
    // Deprecated top-level aliases
    public let generate: DeprecatedGenerateClientAPI
    public let voice: ExperimentalVoiceClientAPI
    public let migration: ExperimentalMigrationClientAPI
    public let usage: ExperimentalUsageClientAPI

    public init(options: ClientOptions, mediaRefsEnabled: Bool = false) {
        let executor = ClientHTTPExecutor(options: options)
        self.executor = executor
        self.server = ServerClientAPI(executor: executor)
        self.location = LocationClientAPI(executor: executor)
        self.agent = AgentClientAPI(executor: executor)
        self.plugin = PluginClientAPI(executor: executor)
        self.session = SessionClientAPI(executor: executor, mediaRefsEnabled: mediaRefsEnabled)
        self.experimental = ExperimentalClientAPI(executor: executor)
        self.message = MessageClientAPI(executor: executor, mediaRefsEnabled: mediaRefsEnabled)
        self.model = ModelClientAPI(executor: executor)
        self.provider = ProviderClientAPI(executor: executor)
        self.integration = IntegrationClientAPI(executor: executor)
        self.mcp = McpClientAPI(executor: executor)
        self.credential = CredentialClientAPI(executor: executor)
        self.project = ProjectClientAPI(executor: executor)
        self.form = FormClientAPI(executor: executor)
        self.permission = PermissionClientAPI(executor: executor)
        self.file = FileClientAPI(executor: executor)
        self.command = CommandClientAPI(executor: executor)
        self.skill = SkillClientAPI(executor: executor)
        self.rpc = RpcClientAPI(executor: executor)
        self.event = EventClientAPI(executor: executor)
        self.pty = PtyClientAPI(executor: executor)
        self.shell = ShellClientAPI(executor: executor)
        self.reference = ReferenceClientAPI(executor: executor)
        self.worktree = WorktreeClientAPI(executor: executor)
        self.vcs = VcsClientAPI(executor: executor)
        self.debug = DebugClientAPI(executor: executor)
        self.websearch = WebsearchClientAPI(executor: executor)
        self.config = ConfigClientAPI(executor: executor)
        self.generate = DeprecatedGenerateClientAPI(executor: executor)
        self.voice = ExperimentalVoiceClientAPI(executor: executor)
        self.migration = ExperimentalMigrationClientAPI(executor: executor)
        self.usage = ExperimentalUsageClientAPI(executor: executor)
    }

    /// Invokes any `OpenCodeProtocol.EndpointDescriptor` dynamically via `OpenCodeProtocol.ClientApi`.
    public func invoke(
        endpoint: EndpointDescriptor,
        pathParams: [String: String] = [:],
        query: [(String, JSONValue?)] = [],
        headers: [String: String] = [:],
        body: JSONValue? = nil,
        binaryBody: [UInt8]? = nil,
        options: RequestOptions? = nil
    ) async throws -> HTTPResponse {
        try await executor.invoke(
            endpoint: endpoint,
            pathParams: pathParams,
            query: query,
            headers: headers,
            body: body,
            binaryBody: binaryBody,
            requestOptions: options
        )
    }
}

public enum GeneratedOpenCode {
    /// Constructs a raw generated Promise client backed by `OpenCodePlatform.HTTPTransport`.
    // parity: client/src/promise/generated/client.ts#make [status=implemented hash=90a1061f7003]
    public static func make(_ options: ClientOptions) -> GeneratedOpenCodeClient {
        GeneratedOpenCodeClient(options: options)
    }
}

// MARK: - Promise RPC Client (packages/client/src/promise/rpc.ts)

/// Per-call options for plugin RPC invocations.
// parity: client/src/promise/rpc.ts#RpcCallOptions [status=implemented hash=1bbd20c3d338]
public struct RpcCallOptions: Sendable {
    public let location: LocationQuery.LocationField?
    public let signal: AbortSignal?
    public let headers: [String: String]?

    public init(
        location: LocationQuery.LocationField? = nil,
        signal: AbortSignal? = nil,
        headers: [String: String]? = nil
    ) {
        self.location = location
        self.signal = signal
        self.headers = headers
    }
}

/// Argument tuple representation matching upstream `RpcArguments`.
// parity: client/src/promise/rpc.ts#RpcArguments [status=adapted hash=836151c1e499]
public typealias RpcArguments<Input, Options> = (input: Input, options: Options?)

/// Typed RPC event payload matching upstream `RpcEventPayload`.
// parity: client/src/promise/rpc.ts#RpcEventPayload [status=implemented hash=ebf02ee49b96]
public typealias RpcEventPayload = OpenCodeEvent

/// Events interface for a bound Promise RPC client.
public struct PromiseRpcEvents: Sendable {
    private let definition: RpcSchema.PortableDefinition
    private let subscribeAll: @Sendable (AbortSignal?) -> AsyncThrowingStream<OpenCodeEvent, any Error>

    public init(
        definition: RpcSchema.PortableDefinition,
        subscribeAll: @escaping @Sendable (AbortSignal?) -> AsyncThrowingStream<OpenCodeEvent, any Error>
    ) {
        self.definition = definition
        self.subscribeAll = subscribeAll
    }

    public func subscribe(
        _ name: String,
        signal: AbortSignal? = nil
    ) throws -> AsyncThrowingStream<RpcEventPayload, any Error> {
        guard definition.events[name] != nil else {
            throw ServiceLifecycleError("Unknown RPC event: \(definition.id).\(name)")
        }
        let targetType = RpcRuntime.eventType(definition: definition, name: name)
        let sourceFactory = subscribeAll
        return AsyncThrowingStream { continuation in
            let controller = AbortController()
            let linkedCleanup = signal?.onAbort {
                controller.abort()
            }
            if signal?.isAborted == true {
                controller.abort()
            }
            let task = Task {
                defer {
                    linkedCleanup?()
                    controller.abort()
                }
                do {
                    for try await published in sourceFactory(controller.signal) {
                        if controller.signal.isAborted || Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        if published.type != targetType { continue }
                        continuation.yield(published)
                    }
                    continuation.finish()
                } catch {
                    if controller.signal.isAborted || Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                controller.abort()
                task.cancel()
            }
        }
    }

    /// Registers an async callback for a named RPC event and returns a disposer closure.
    @discardableResult
    public func on(
        _ name: String,
        signal: AbortSignal? = nil,
        handler: @escaping @Sendable (RpcEventPayload) async -> Void
    ) throws -> @Sendable () -> Void {
        let controller = AbortController()
        let linkedCleanup = signal?.onAbort {
            controller.abort()
        }
        let stream = try subscribe(name, signal: controller.signal)
        let task = Task {
            defer { linkedCleanup?() }
            do {
                for try await event in stream {
                    if controller.signal.isAborted || Task.isCancelled { break }
                    await handler(event)
                }
            } catch {}
        }
        return {
            controller.abort()
            task.cancel()
        }
    }
}

/// Bound Promise-style RPC client for one `RpcSchema.PortableDefinition`.
// parity: client/src/promise/rpc.ts#RpcClient [status=implemented hash=073718a355d8]
public struct RpcClient: Sendable {
    public let definition: RpcSchema.PortableDefinition
    public let events: PromiseRpcEvents
    private let invoker: @Sendable (String, JSONValue?, RpcCallOptions?) async throws -> JSONValue?

    public init(
        definition: RpcSchema.PortableDefinition,
        events: PromiseRpcEvents,
        invoker: @escaping @Sendable (String, JSONValue?, RpcCallOptions?) async throws -> JSONValue?
    ) {
        self.definition = definition
        self.events = events
        self.invoker = invoker
    }

    public func call(
        _ method: String,
        input: JSONValue? = nil,
        options: RpcCallOptions? = nil
    ) async throws -> JSONValue? {
        guard definition.methods[method] != nil else {
            throw RpcMethodErrorPayload(type: "rpc.method_not_found", message: "Unknown RPC method: \(definition.id).\(method)")
        }
        return try await invoker(method, input, options)
    }
}

/// Callable factory creating a bound `RpcClient` for a given `RpcSchema.PortableDefinition`.
// parity: client/src/promise/rpc.ts#RpcApi [status=implemented hash=af1ab410c099]
public struct RpcApi: Sendable {
    private let build: @Sendable (RpcSchema.PortableDefinition) -> RpcClient

    public init(_ build: @escaping @Sendable (RpcSchema.PortableDefinition) -> RpcClient) {
        self.build = build
    }

    public func callAsFunction(_ definition: RpcSchema.PortableDefinition) -> RpcClient {
        build(definition)
    }
}

/// Builds a Promise `RpcApi` backed by `raw.rpc.call` and a shared event stream.
// parity: client/src/promise/rpc.ts#makeRpc [status=implemented hash=b2e6a6f5b9bf]
public func makeRpc(
    raw: GeneratedOpenCodeClient,
    events: SharedEventsHub<OpenCodeEvent>
) -> RpcApi {
    RpcApi { definition in
        let rpcEvents = PromiseRpcEvents(definition: definition) { signal in
            events.subscribe(SubscribeOptions(signal: signal))
        }
        return RpcClient(definition: definition, events: rpcEvents) { method, input, options in
            do {
                let result = try await raw.rpc.call(
                    RpcCallInput(
                        rpcID: definition.id,
                        method: method,
                        location: options?.location,
                        input: input
                    ),
                    options: RequestOptions(signal: options?.signal, headers: options?.headers)
                )
                return result.output
            } catch {
                if isRpcError(error) || isRpcInternalError(error) {
                    if let rpcErr = error as? OpenCodeProtocol.RpcError {
                        throw RpcMethodErrorPayload(type: rpcErr.type, message: rpcErr.message, data: rpcErr.data)
                    }
                    if let intErr = error as? OpenCodeProtocol.RpcInternalError {
                        throw RpcMethodErrorPayload(type: intErr.type.rawValue, message: intErr.message, data: intErr.data)
                    }
                    if let env = error as? ProtocolErrorEnvelope {
                        switch env {
                        case .rpc(let e):
                            throw RpcMethodErrorPayload(type: e.type, message: e.message, data: e.data)
                        case .rpcInternal(let e):
                            throw RpcMethodErrorPayload(type: e.type.rawValue, message: e.message, data: e.data)
                        default:
                            break
                        }
                    }
                }
                throw error
            }
        }
    }
}

/// Composed `client.rpc` surface supporting both `client.rpc.call(...)` and `client.rpc(definition)`.
public struct OpenCodeRpcAPI: Sendable {
    private let raw: RpcClientAPI
    private let builder: RpcApi

    public init(raw: RpcClientAPI, builder: RpcApi) {
        self.raw = raw
        self.builder = builder
    }

    public func call(_ input: RpcCallInput, options: RequestOptions? = nil) async throws -> RpcCallOutput {
        try await raw.call(input, options: options)
    }

    public func callAsFunction(_ definition: RpcSchema.PortableDefinition) -> RpcClient {
        builder(definition)
    }
}

// MARK: - Top-Level OpenCode Promise Client (packages/client/src/promise/{client,index,api}.ts)

/// Full typed OpenCode HTTP/SSE/RPC client with shared multiplexed events.
// parity: client/src/promise/index.ts#OpenCodeClient [status=implemented hash=43fb55cbf779]
public struct OpenCodeClient: Sendable {
    private let rawOptions: ClientOptions
    private let mediaRefsEnabled: Bool

    public let raw: GeneratedOpenCodeClient
    public let server: ServerClientAPI
    public let location: LocationClientAPI
    public let agent: AgentClientAPI
    public let plugin: PluginClientAPI
    public let session: SessionClientAPI
    public let experimental: ExperimentalClientAPI
    public let message: MessageClientAPI
    public let model: ModelClientAPI
    public let provider: ProviderClientAPI
    public let integration: IntegrationClientAPI
    public let mcp: McpClientAPI
    public let credential: CredentialClientAPI
    public let project: ProjectClientAPI
    public let form: FormClientAPI
    public let permission: PermissionClientAPI
    public let file: FileClientAPI
    public let command: CommandClientAPI
    public let skill: SkillClientAPI
    public let rpc: OpenCodeRpcAPI
    public let event: SharedEventsHub<OpenCodeEvent>
    public let pty: PtyClientAPI
    public let shell: ShellClientAPI
    public let reference: ReferenceClientAPI
    public let worktree: WorktreeClientAPI
    public let vcs: VcsClientAPI
    public let debug: DebugClientAPI
    public let websearch: WebsearchClientAPI
    public let config: ConfigClientAPI
    // Deprecated top-level aliases
    public let generate: DeprecatedGenerateClientAPI
    public let voice: ExperimentalVoiceClientAPI
    public let migration: ExperimentalMigrationClientAPI
    public let usage: ExperimentalUsageClientAPI

    public init(options: ClientOptions, mediaRefsEnabled: Bool = false) {
        let raw = GeneratedOpenCodeClient(options: options, mediaRefsEnabled: mediaRefsEnabled)
        let events = SharedEvents.make { signal, onActivity in
            raw.event.subscribe(nil, options: RequestOptions(signal: signal, onActivity: onActivity))
        }
        let rpcBuilder = makeRpc(raw: raw, events: events)
        self.init(options: options, mediaRefsEnabled: mediaRefsEnabled, raw: raw, events: events, rpcBuilder: rpcBuilder)
    }

    private init(
        options: ClientOptions,
        mediaRefsEnabled: Bool,
        raw: GeneratedOpenCodeClient,
        events: SharedEventsHub<OpenCodeEvent>,
        rpcBuilder: RpcApi
    ) {
        self.rawOptions = options
        self.mediaRefsEnabled = mediaRefsEnabled
        self.raw = raw
        self.server = raw.server
        self.location = raw.location
        self.agent = raw.agent
        self.plugin = raw.plugin
        self.session = raw.session
        self.experimental = raw.experimental
        self.message = raw.message
        self.model = raw.model
        self.provider = raw.provider
        self.integration = raw.integration
        self.mcp = raw.mcp
        self.credential = raw.credential
        self.project = raw.project
        self.form = raw.form
        self.permission = raw.permission
        self.file = raw.file
        self.command = raw.command
        self.skill = raw.skill
        self.rpc = OpenCodeRpcAPI(raw: raw.rpc, builder: rpcBuilder)
        self.event = events
        self.pty = raw.pty
        self.shell = raw.shell
        self.reference = raw.reference
        self.worktree = raw.worktree
        self.vcs = raw.vcs
        self.debug = raw.debug
        self.websearch = raw.websearch
        self.config = raw.config
        self.generate = raw.generate
        self.voice = raw.voice
        self.migration = raw.migration
        self.usage = raw.usage
    }

    internal func withMediaRefsEnabled() -> OpenCodeClient {
        let nextRaw = GeneratedOpenCodeClient(options: rawOptions, mediaRefsEnabled: true)
        let rpcBuilder = makeRpc(raw: nextRaw, events: event)
        return OpenCodeClient(
            options: rawOptions,
            mediaRefsEnabled: true,
            raw: nextRaw,
            events: event,
            rpcBuilder: rpcBuilder
        )
    }

    public func invoke(
        endpoint: EndpointDescriptor,
        pathParams: [String: String] = [:],
        query: [(String, JSONValue?)] = [],
        headers: [String: String] = [:],
        body: JSONValue? = nil,
        binaryBody: [UInt8]? = nil,
        options: RequestOptions? = nil
    ) async throws -> HTTPResponse {
        try await raw.invoke(
            endpoint: endpoint,
            pathParams: pathParams,
            query: query,
            headers: headers,
            body: body,
            binaryBody: binaryBody,
            options: options
        )
    }
}

public enum OpenCode {
    /// Creates an `OpenCodeClient` with shared SSE event multiplexing and typed plugin RPC.
    // parity: client/src/promise/client.ts#make [status=implemented hash=e4ac1874321d]
    public static func make(_ options: ClientOptions) -> OpenCodeClient {
        OpenCodeClient(options: options)
    }
}

// MARK: - Promise API Group Type Aliases (packages/client/src/promise/api.ts — 20 symbols)

// parity: client/src/promise/api.ts#AgentApi [status=implemented hash=a18161fa4ef4]
public typealias AgentApi = AgentClientAPI
// parity: client/src/promise/api.ts#CommandApi [status=implemented hash=a646535e23d3]
public typealias CommandApi = CommandClientAPI
// parity: client/src/promise/api.ts#ConfigApi [status=implemented hash=65572a98b2f8]
public typealias ConfigApi = ConfigClientAPI
// parity: client/src/promise/api.ts#CredentialApi [status=implemented hash=30fb1216070b]
public typealias CredentialApi = CredentialClientAPI
// parity: client/src/promise/api.ts#EventApi [status=implemented hash=8ab6d07bade8]
public typealias EventApi = SharedEventsHub<OpenCodeEvent>
// parity: client/src/promise/api.ts#GenerateApi [status=implemented hash=89e80858e2d2]
public typealias GenerateApi = DeprecatedGenerateClientAPI
// parity: client/src/promise/api.ts#ExperimentalGenerateApi [status=implemented hash=caf50a15581d]
public typealias ExperimentalGenerateApi = ExperimentalGenerateClientAPI
// parity: client/src/promise/api.ts#ExperimentalSessionApi [status=implemented hash=af7c2d0e9859]
public typealias ExperimentalSessionApi = ExperimentalSessionClientAPI
// parity: client/src/promise/api.ts#IntegrationApi [status=implemented hash=1efdbafd5f72]
public typealias IntegrationApi = IntegrationClientAPI
// parity: client/src/promise/api.ts#McpApi [status=implemented hash=70345c60da1e]
public typealias McpApi = McpClientAPI
// parity: client/src/promise/api.ts#ModelApi [status=implemented hash=03433e04d45b]
public typealias ModelApi = ModelClientAPI
// parity: client/src/promise/api.ts#PluginApi [status=implemented hash=0d031c232436]
public typealias PluginApi = PluginClientAPI
// parity: client/src/promise/api.ts#PermissionApi [status=implemented hash=0830ea4911f9]
public typealias PermissionApi = PermissionClientAPI
// parity: client/src/promise/api.ts#ProviderApi [status=implemented hash=377cb84a215b]
public typealias ProviderApi = ProviderClientAPI
// parity: client/src/promise/api.ts#ReferenceApi [status=implemented hash=5e2357af8490]
public typealias ReferenceApi = ReferenceClientAPI
// parity: client/src/promise/api.ts#WebSearchApi [status=implemented hash=2f644b9a5362]
public typealias WebSearchApi = WebsearchClientAPI
// parity: client/src/promise/api.ts#SessionApi [status=implemented hash=4e74aaa3b87a]
public typealias SessionApi = SessionClientAPI
// parity: client/src/promise/api.ts#SkillApi [status=implemented hash=896f6a202d65]
public typealias SkillApi = SkillClientAPI
// parity: client/src/promise/api.ts#VcsApi [status=implemented hash=9acf1acc79f6]
public typealias VcsApi = VcsClientAPI
// parity: client/src/promise/api.ts#WorktreeApi [status=implemented hash=bf037fba0f7c]
public typealias WorktreeApi = WorktreeClientAPI

// MARK: - Promise Local Service Lifecycle (packages/client/src/promise/service.ts)

/// Promise-based local service lifecycle operations mirroring `packages/client/src/promise/service.ts`.
public enum PromiseService {
    /// The default registration file (`$XDG_STATE_HOME/opencode/service.json` or `~/.local/state/opencode/service.json`).
    // parity: client/src/promise/service.ts#fallback [status=implemented hash=17d8a31e4fa3]
    public static func fallback(environment: any EnvironmentProviding = SystemEnvironment.shared) -> String {
        serviceProbeFallback(environment: environment)
    }

    /// Create HTTP authentication headers for a service endpoint (re-exported from `service-probe.ts`).
    // parity: client/src/promise/service.ts#headers [status=implemented hash=17d8a31e4fa3]
    public static func headers(for endpoint: ServiceEndpoint) -> [String: String]? {
        serviceProbeHeaders(for: endpoint)
    }

    /// Discover a healthy, compatible local service without starting one.
    // parity: client/src/promise/service.ts#discover [status=implemented hash=02b22845f895]
    public static func discover(
        options: ServiceDiscoverOptions = ServiceDiscoverOptions(),
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        transport: any HTTPTransport,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) async -> ServiceEndpoint? {
        let reg = await registered(
            file: options.file,
            timeoutMs: defaultEnsureTiming.requestTimeout,
            fileSystem: fileSystem,
            transport: transport,
            environment: environment
        )
        guard let found = reg.service, found.state == .ready, found.compatible else { return nil }
        guard matchesVersion(found.version, options: options) else { return nil }
        return found.endpoint
    }

    /// Ensure a healthy, compatible local service is running.
    // parity: client/src/promise/service.ts#ensure [status=implemented hash=e4cf96270698]
    public static func ensure(
        options: ServiceEnsureOptions = ServiceEnsureOptions(),
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        transport: any HTTPTransport,
        launcher: any ServiceProcessLauncher,
        signaler: any ServiceProcessSignaler,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        now: @escaping @Sendable () -> Int64 = { ClientClock.nowEpochMs() }
    ) async throws -> ServiceEndpoint {
        let timing = ensureTiming(options)
        let deadline = now() + timing.promiseTimeout
        let pool = contenderPool(timing: timing, now: now)
        let registrationFile = options.file ?? fallback(environment: environment)
        var timeoutInfo: ServiceInfo?
        var timeoutCount = 0
        var announced = false

        func announce(_ reason: ServiceEnsureReason, previousVersion: String? = nil) {
            if announced { return }
            announced = true
            options.onStart?(reason, previousVersion)
        }

        func spawnOne() async throws -> ServiceContender {
            let cmd = options.command ?? ["opencode", "serve", "--service"]
            guard let command = cmd.first else {
                throw ServiceLifecycleError("Missing service command")
            }
            let args = Array(cmd.dropFirst())
            let env = await PtyHandoff.environment(file: registrationFile, env: options.env, fileSystem: fileSystem, now: now)
            do {
                return try spawnServiceContender(command: command, args: args, env: env, launcher: launcher)
            } catch {
                throw ServiceLifecycleError("Failed to start server: \(error)")
            }
        }

        defer { pool.releaseAll() }

        while true {
            if now() >= deadline {
                throw pool.failure() ?? ServiceLifecycleError("Timed out waiting for the background service to start")
            }
            let reg = await registered(
                file: options.file,
                timeoutMs: timing.requestTimeout,
                fileSystem: fileSystem,
                transport: transport,
                environment: environment
            )
            if reg.timedOut, let info = reg.info {
                if let prev = timeoutInfo, same(prev, info) {
                    timeoutCount += 1
                } else {
                    timeoutInfo = info
                    timeoutCount = 1
                }
                if timeoutCount >= 3 {
                    announce(.missing)
                    await PtyHandoff.clear(file: registrationFile, fileSystem: fileSystem)
                    try await terminate(
                        info: info,
                        file: options.file,
                        timing: timing,
                        fileSystem: fileSystem,
                        signaler: signaler,
                        environment: environment
                    )
                    pool.evict(pid: info.pid)
                    pool.recruitNow()
                    timeoutInfo = nil
                    timeoutCount = 0
                }
            } else {
                timeoutInfo = nil
                timeoutCount = 0
            }

            if let service = reg.service {
                pool.serviceAnswered()
                switch decide(service, options: options.discoverOptions) {
                case .fail(let error):
                    throw error
                case .reuse:
                    await PtyHandoff.complete(file: registrationFile, info: service.info, fileSystem: fileSystem)
                    return service.endpoint
                case .replace(let ptyMode):
                    announce(.versionMismatch, previousVersion: service.version)
                    try? await stop(
                        options: ServiceStopOptions(file: options.file, pty: ptyMode, timing: options.timing),
                        fileSystem: fileSystem,
                        transport: transport,
                        signaler: signaler,
                        environment: environment,
                        now: now
                    )
                    pool.evict(pid: service.info.pid)
                case .wait:
                    break
                }
            } else {
                if let failed = pool.reap() {
                    throw failed
                }
                if pool.shouldRecruit(registered: reg.info != nil) {
                    announce(.missing)
                    pool.add(try await spawnOne())
                }
            }

            if timing.pollInterval > 0 {
                try await Task.sleep(for: .milliseconds(timing.pollInterval))
            }
        }
    }

    /// Stop the registered local service.
    // parity: client/src/promise/service.ts#stop [status=implemented hash=61cac4f955cf]
    public static func stop(
        options: ServiceStopOptions = ServiceStopOptions(),
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        transport: any HTTPTransport,
        signaler: any ServiceProcessSignaler,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        now: @escaping @Sendable () -> Int64 = { ClientClock.nowEpochMs() }
    ) async throws {
        let registrationFile = options.file ?? fallback(environment: environment)
        let info = await readInfo(file: registrationFile, fileSystem: fileSystem)
        if options.pty == .handoff, let info {
            await PtyHandoff.prepare(
                file: registrationFile,
                info: info,
                timeoutMs: defaultEnsureTiming.requestTimeout,
                fileSystem: fileSystem,
                transport: transport,
                now: now
            )
        } else {
            await PtyHandoff.clear(file: registrationFile, fileSystem: fileSystem)
        }
        if let info {
            try await terminate(
                info: info,
                file: options.file,
                timing: ensureTiming(options),
                fileSystem: fileSystem,
                signaler: signaler,
                environment: environment
            )
        }
    }

    /// Grouped Promise service handle matching `export const Service = { discover, ensure, stop, headers }`.
    public struct ServiceHandle: Sendable {
        public let fileSystem: any OpenCodeFileSystem
        public let transport: any HTTPTransport
        public let launcher: (any ServiceProcessLauncher)?
        public let signaler: (any ServiceProcessSignaler)?
        public let environment: any EnvironmentProviding

        public init(
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            transport: any HTTPTransport,
            launcher: (any ServiceProcessLauncher)? = nil,
            signaler: (any ServiceProcessSignaler)? = nil,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) {
            self.fileSystem = fileSystem
            self.transport = transport
            self.launcher = launcher
            self.signaler = signaler
            self.environment = environment
        }

        public func discover(_ options: ServiceDiscoverOptions = ServiceDiscoverOptions()) async -> ServiceEndpoint? {
            await PromiseService.discover(
                options: options,
                fileSystem: fileSystem,
                transport: transport,
                environment: environment
            )
        }

        public func ensure(_ options: ServiceEnsureOptions = ServiceEnsureOptions()) async throws -> ServiceEndpoint {
            guard let launcher, let signaler else {
                throw ServiceLifecycleError("ServiceProcessLauncher and ServiceProcessSignaler are required for ensure()")
            }
            return try await PromiseService.ensure(
                options: options,
                fileSystem: fileSystem,
                transport: transport,
                launcher: launcher,
                signaler: signaler,
                environment: environment
            )
        }

        public func stop(_ options: ServiceStopOptions = ServiceStopOptions()) async throws {
            guard let signaler else {
                throw ServiceLifecycleError("ServiceProcessSignaler is required for stop()")
            }
            try await PromiseService.stop(
                options: options,
                fileSystem: fileSystem,
                transport: transport,
                signaler: signaler,
                environment: environment
            )
        }

        public func authHeaders(for endpoint: ServiceEndpoint) -> [String: String]? {
            headers(for: endpoint)
        }
    }

    // parity: client/src/promise/service.ts#Service [status=implemented hash=9c1638f86b5a]
    public static let Service = PromiseService.self

    internal static func readInfo(file: String, fileSystem: any OpenCodeFileSystem) async -> ServiceInfo? {
        guard let bytes = try? await fileSystem.readFile(at: file),
              let info = try? ClientCodec.decode(ServiceInfo.self, from: bytes),
              info.pid > 0
        else {
            return nil
        }
        return info
    }

    internal static func registered(
        file: String?,
        timeoutMs: Int64,
        fileSystem: any OpenCodeFileSystem,
        transport: any HTTPTransport,
        environment: any EnvironmentProviding
    ) async -> (info: ServiceInfo?, service: LocalService?, timedOut: Bool) {
        let resolved = file ?? fallback(environment: environment)
        guard let info = await readInfo(file: resolved, fileSystem: fileSystem) else {
            return (nil, nil, false)
        }
        let probed = await probeResult(info, timeoutMs: timeoutMs, transport: transport)
        return (info, probed.service, probed.timedOut)
    }

    internal static func terminate(
        info: ServiceInfo,
        file: String?,
        timing: EnsureTiming,
        fileSystem: any OpenCodeFileSystem,
        signaler: any ServiceProcessSignaler,
        environment: any EnvironmentProviding
    ) async throws {
        let resolved = file ?? fallback(environment: environment)
        guard let current = await readInfo(file: resolved, fileSystem: fileSystem), same(current, info) else {
            return
        }
        signaler.sendSignal(pid: info.pid, signal: "SIGTERM")
        if !(await waitUntilStopped(pid: info.pid, timing: timing, signaler: signaler)) {
            signaler.sendSignal(pid: info.pid, signal: "SIGKILL")
            if !(await waitUntilStopped(pid: info.pid, timing: timing, signaler: signaler)) {
                throw ServiceLifecycleError("Server process \(info.pid) is still running")
            }
        }
        if let latest = await readInfo(file: resolved, fileSystem: fileSystem), same(latest, info) {
            try? await fileSystem.remove(at: resolved)
        }
    }

    private static func waitUntilStopped(
        pid: Int,
        timing: EnsureTiming,
        signaler: any ServiceProcessSignaler
    ) async -> Bool {
        for attempt in 0...max(0, timing.stopPollAttempts) {
            if !signaler.isRunning(pid: pid) { return true }
            if attempt < timing.stopPollAttempts && timing.stopPollInterval > 0 {
                try? await Task.sleep(for: .milliseconds(timing.stopPollInterval))
            }
        }
        return false
    }
}
