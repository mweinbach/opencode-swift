/// Portable LLM chat, messages, responses, and structured decision protocols for `OpenCodeAI`.
///
/// Ports all 24 chat/messages/responses protocol modules under `packages/ai/src/protocols/*`:
/// `anthropic-messages`, `openai-responses`, `openai-chat`, `openai-compatible-chat`,
/// `openai-compatible-responses`, `openai-freeform`, `open-responses`, `open-responses-channel`,
/// `open-responses-continuation`, `gemini`, `google-interactions`, `bedrock-converse`,
/// `cohere-chat`, `mistral-chat`, `alibaba-chat`, `alibaba-messages`, `alibaba-responses`,
/// `meta-messages`, `meta-responses`, `venice-chat`, `xai-responses`, `zai-chat`,
/// `zai-messages`, and `system-one`.
///
/// Strictly PORTABLE tier: zero OS imports, all HTTP via `OpenCodePlatform.HTTPTransport`.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

public enum AIProtocols {

    // MARK: Shared Protocol / Route Descriptors

    public enum FramingKind: String, Equatable, Hashable, Sendable, Codable {
        case sse
        case sseWithDone
        case sseEvents
        case awsEventStream
        case jsonDocument
        case binaryAudio
    }

    /// Stateful incremental wire-stream decoder that consumes transport chunks directly
    /// and emits `AIProtocolUtils.LLMEvent`s as frames arrive without full-body buffering.
    public protocol IncrementalStreamDecoder: Sendable {
        mutating func feed(_ bytes: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent]
        mutating func finish() throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent]
        /// Marks a request boundary inside one logical response (a continuation request), without adding another
        /// logical step or finish. Decoders of single-request protocols ignore it.
        mutating func beginNextRequest() throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent]
    }

    /// A transport that may continue one logical response across several HTTP requests
    /// (upstream route `transport` with a resumable `execute`).
    public struct ChatContinuation: Sendable {
        /// Starts tracking one logical response from its first request body and route label.
        public let makeSession: @Sendable (_ body: [String: JSONValue], _ label: String) -> any ChatContinuationSession

        public init(makeSession: @escaping @Sendable (_ body: [String: JSONValue], _ label: String) -> any ChatContinuationSession) {
            self.makeSession = makeSession
        }
    }

    /// Per-response continuation state: watches each response's raw stream and decides, at its end, whether the
    /// next request continues it.
    public protocol ChatContinuationSession: Sendable {
        /// Observes raw response bytes; true once the response's terminal event arrived and reading can stop.
        mutating func observe(_ bytes: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> Bool
        /// Whether a transport failure that ended the current response may be resumed from a checkpoint.
        func canResume(after error: any Error) -> Bool
        /// After a response ends (`dropped` is the transport failure that ended it early), the body of the request
        /// that continues it, or nil when the response is complete or has no safe checkpoint.
        mutating func next(dropped: (any Error)?) throws -> [String: JSONValue]?
    }

    /// Fallback decoder for custom `ChatProtocolSpec` instances that only provide a batch `parseStream`.
    public struct BufferedStreamDecoder: IncrementalStreamDecoder, Sendable {
        private var buffer: [UInt8] = []
        private let request: AIProtocolUtils.LLMRequest
        private let parseStream: @Sendable ([UInt8], AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent]

        public init(
            request: AIProtocolUtils.LLMRequest,
            parseStream: @escaping @Sendable ([UInt8], AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent]
        ) {
            self.request = request
            self.parseStream = parseStream
        }

        public mutating func feed(_ bytes: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            buffer.append(contentsOf: bytes)
            return []
        }

        public mutating func finish() throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            let bytes = buffer
            buffer.removeAll(keepingCapacity: false)
            return try parseStream(bytes, request)
        }
    }

    public struct ChatProtocolSpec: Sendable {
        public let id: String
        public let framing: FramingKind
        public let sanitizer: String?
        public let buildBody: @Sendable (AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue]
        public let parseStream: @Sendable ([UInt8], AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent]
        public let makeStreamDecoder: (@Sendable (AIProtocolUtils.LLMRequest) -> any IncrementalStreamDecoder)?

        public init(
            id: String,
            framing: FramingKind = .sse,
            sanitizer: String? = nil,
            buildBody: @escaping @Sendable (AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue],
            parseStream: @escaping @Sendable ([UInt8], AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent],
            makeStreamDecoder: (@Sendable (AIProtocolUtils.LLMRequest) -> any IncrementalStreamDecoder)? = nil
        ) {
            self.id = id
            self.framing = framing
            self.sanitizer = sanitizer
            self.buildBody = buildBody
            self.parseStream = parseStream
            self.makeStreamDecoder = makeStreamDecoder
        }

        public func makeDecoder(for request: AIProtocolUtils.LLMRequest) -> any IncrementalStreamDecoder {
            if let makeStreamDecoder {
                return makeStreamDecoder(request)
            }
            return BufferedStreamDecoder(request: request, parseStream: parseStream)
        }
    }

    // MARK: Schema <-> Protocol Bridge Converters

    public static func toProtocolError(_ error: AIProtocolUtils.ProtocolError, http: AISchema.HttpContext? = nil) -> AISchema.AIError {
        switch error.kind {
        case .invalidRequest:
            return AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: error.message,
                body: error.body,
                http: http
            )))
        case .unsupportedOperation:
            return AISchema.AIError(reason: .unsupportedOperation(AISchema.UnsupportedOperationError(
                message: error.message,
                body: error.body,
                http: http,
                operation: error.operation ?? "chat",
                provider: error.provider.map(AISchema.ProviderID.make),
                route: error.route
            )))
        case .authentication:
            return AISchema.AIError(reason: .authentication(AISchema.AuthenticationError(
                message: error.message,
                body: error.body,
                http: http
            )))
        case .rateLimit:
            return AISchema.AIError(reason: .rateLimit(AISchema.RateLimitError(
                message: error.message,
                body: error.body,
                http: http
            )))
        case .contentPolicy:
            return AISchema.AIError(reason: .contentPolicy(AISchema.ContentPolicyError(
                message: error.message,
                body: error.body,
                http: http
            )))
        case .providerInternal:
            return AISchema.AIError(reason: .providerInternal(AISchema.ProviderInternalError(
                message: error.message,
                body: error.body,
                http: http
            )))
        case .unknownProvider:
            return AISchema.AIError(reason: .unknownProvider(AISchema.UnknownProviderError(
                message: error.message,
                body: error.body,
                http: http
            )))
        case .transport:
            return AISchema.AIError(reason: .transport(AISchema.TransportError(
                message: error.message,
                body: error.body,
                http: http,
                transport: .http,
                operation: .read
            )))
        case .invalidProviderOutput:
            let classification: AISchema.InvalidProviderOutputError.Classification? =
                error.classification == "incomplete-stream" ? .incompleteStream : nil
            return AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                message: error.message,
                body: error.body,
                http: http,
                classification: classification,
                route: error.route
            )))
        }
    }

    private static func toProtocolCacheHint(_ hint: AISchema.CacheHint?) -> AIProtocolUtils.CacheHint? {
        guard let hint else { return nil }
        return AIProtocolUtils.CacheHint(type: hint.type.rawValue, ttl: hint.ttl?.rawValue)
    }

    private static func toProtocolMediaAsset(_ asset: AIMedia.Asset) -> AIProtocolUtils.MediaAsset {
        let source: AIProtocolUtils.MediaSource = switch asset.source {
        case .bytes(let data, _):
            .bytes(data)
        case .base64(let data, _):
            .base64(data)
        case .url(let url, _, _):
            .url(url)
        case .ref(let provider, let id, _):
            .ref(provider: provider.rawValue, id: id)
        }
        return AIProtocolUtils.MediaAsset(
            source: source,
            mediaType: asset.mediaType,
            providerMetadata: asset.providerMetadata
        )
    }

    private static func toSchemaMediaAsset(_ asset: AIProtocolUtils.MediaAsset) -> AIMedia.Asset {
        let opts = AIMedia.AssetOptions(providerMetadata: asset.providerMetadata)
        switch asset.source {
        case .bytes(let data):
            return AIMedia.bytes(data, mediaType: asset.mediaType, options: opts)
        case .base64(let data):
            return AIMedia.base64(data, mediaType: asset.mediaType, options: opts)
        case .url(let url):
            return AIMedia.url(url, mediaType: asset.mediaType, options: opts)
        case .ref(let provider, let id):
            return AIMedia.ref(provider: provider, id: id, mediaType: asset.mediaType, options: opts)
        }
    }

    private static func toProtocolToolResultValue(_ value: AISchema.ToolResultValue) -> AIProtocolUtils.ToolResultValue {
        switch value {
        case .json(let v):
            return .json(v)
        case .text(let v):
            if case .string(let s) = v { return .text(s) }
            return .text(AIProtocolUtils.JSONCodec.encode(v))
        case .error(let v):
            return .error(v)
        case .content(let items):
            return .content(items.map { item in
                switch item {
                case .text(let t):
                    return .text(t.text)
                case .file(let f):
                    return .file(AIProtocolUtils.ToolFileContent(uri: f.uri, mime: f.mime, name: f.name))
                }
            })
        }
    }

    private static func toSchemaToolResultValue(_ value: AIProtocolUtils.ToolResultValue) -> AISchema.ToolResultValue {
        switch value {
        case .json(let v):
            return .json(v)
        case .text(let s):
            return .text(.string(s))
        case .error(let v):
            return .error(v)
        case .content(let items):
            return .content(items.map { item in
                switch item {
                case .text(let s):
                    return .text(ToolSchema.TextContent(text: s))
                case .file(let f):
                    return .file(ToolSchema.FileContent(uri: f.uri, mime: f.mime, name: f.name))
                }
            })
        }
    }

    private static func toProtocolToolResultPart(_ part: AISchema.ToolResultPart) -> AIProtocolUtils.ToolResultPart {
        AIProtocolUtils.ToolResultPart(
            id: part.id,
            name: part.name,
            namespace: part.namespace,
            result: toProtocolToolResultValue(part.result),
            providerExecuted: part.providerExecuted,
            cache: toProtocolCacheHint(part.cache),
            providerMetadata: part.providerMetadata
        )
    }

    private static func toProtocolFreeform(_ freeform: AISchema.Freeform?) -> AIProtocolUtils.FreeformFormat? {
        guard let freeform else { return nil }
        switch freeform {
        case .text: return .text
        case .regex(let pattern): return .regex(pattern)
        case .lark(let grammar): return .lark(grammar)
        }
    }

    private static func toProtocolToolEntry(_ entry: AISchema.ToolEntry) -> AIProtocolUtils.ToolEntry {
        switch entry {
        case .tool(let def):
            return .tool(AIProtocolUtils.ToolDefinition(
                name: def.name,
                description: def.description,
                inputSchema: def.inputSchema,
                cache: toProtocolCacheHint(def.cache),
                freeform: toProtocolFreeform(def.freeform),
                native: def.native
            ))
        case .namespace(let ns):
            return .namespace(
                name: ns.name,
                description: ns.description,
                tools: ns.tools.map(toProtocolToolEntry)
            )
        }
    }

    private static func toProtocolToolChoice(_ choice: AISchema.ToolChoice?) -> AIProtocolUtils.ToolChoice? {
        guard let choice else { return nil }
        let kind: AIProtocolUtils.ToolChoice.Kind = switch choice.type {
        case .auto: .auto
        case .none: .none
        case .required: .required
        case .tool: .tool
        }
        return AIProtocolUtils.ToolChoice(
            type: kind,
            name: choice.name,
            disableParallelToolUse: choice.disableParallelToolUse
        )
    }

    private static func toProtocolMessage(_ message: AISchema.Message) -> AIProtocolUtils.Message {
        switch message {
        case .system(let sys):
            let parts: [AIProtocolUtils.ContentPart] = sys.content.compactMap { part in
                switch part {
                case .text(let tp):
                    return .text(AIProtocolUtils.TextPart(
                        text: tp.text,
                        cache: toProtocolCacheHint(tp.cache),
                        providerMetadata: tp.providerMetadata
                    ))
                case .effort:
                    return nil
                }
            }
            return AIProtocolUtils.Message(role: .system, content: parts)
        case .user(let usr):
            let parts: [AIProtocolUtils.ContentPart] = usr.content.map { part in
                switch part {
                case .text(let tp):
                    return .text(AIProtocolUtils.TextPart(
                        text: tp.text,
                        cache: toProtocolCacheHint(tp.cache),
                        providerMetadata: tp.providerMetadata
                    ))
                case .media(let mp):
                    return .media(AIProtocolUtils.MediaPart(
                        media: toProtocolMediaAsset(mp.media),
                        filename: mp.filename,
                        cache: toProtocolCacheHint(mp.cache),
                        providerMetadata: mp.providerMetadata
                    ))
                }
            }
            return AIProtocolUtils.Message(role: .user, content: parts, providerMetadata: usr.providerMetadata)
        case .assistant(let asst):
            let parts: [AIProtocolUtils.ContentPart] = asst.content.map { part in
                switch part {
                case .text(let tp):
                    return .text(AIProtocolUtils.TextPart(
                        text: tp.text,
                        cache: toProtocolCacheHint(tp.cache),
                        providerMetadata: tp.providerMetadata
                    ))
                case .reasoning(let rp):
                    return .reasoning(AIProtocolUtils.ReasoningPart(
                        text: rp.text,
                        encrypted: rp.encrypted,
                        providerMetadata: rp.providerMetadata
                    ))
                case .toolCall(let tc):
                    return .toolCall(AIProtocolUtils.ToolCallPart(
                        id: tc.id,
                        name: tc.name,
                        namespace: tc.namespace,
                        input: tc.input,
                        providerExecuted: tc.providerExecuted,
                        providerMetadata: tc.providerMetadata
                    ))
                case .toolResult(let tr):
                    return .toolResult(toProtocolToolResultPart(tr))
                case .media(let mp):
                    return .media(AIProtocolUtils.MediaPart(
                        media: toProtocolMediaAsset(mp.media),
                        filename: mp.filename,
                        cache: toProtocolCacheHint(mp.cache),
                        providerMetadata: mp.providerMetadata
                    ))
                case .compaction(let cp):
                    return .compaction(AIProtocolUtils.CompactionPart(
                        provider: cp.provider.rawValue,
                        id: cp.id,
                        text: cp.text,
                        encrypted: cp.encrypted
                    ))
                }
            }
            return AIProtocolUtils.Message(role: .assistant, content: parts, providerMetadata: asst.providerMetadata)
        case .tool(let tool):
            let parts: [AIProtocolUtils.ContentPart] = tool.content.map { .toolResult(toProtocolToolResultPart($0)) }
            return AIProtocolUtils.Message(role: .tool, content: parts)
        }
    }

    public static func toProtocolRequest(
        _ request: AISchema.LLMRequest,
        route: ChatRouteSpec,
        defaultCompatibility: AIProtocolUtils.ModelCompatibility? = nil,
        defaultCapabilities: AIProtocolUtils.ModelCapabilities? = nil
    ) -> AIProtocolUtils.LLMRequest {
        let modelCompat = request.model.compatibility
        let mergedCompat = AIProtocolUtils.ModelCompatibility(
            reasoningField: modelCompat?.reasoningField ?? defaultCompatibility?.reasoningField,
            requireReasoning: modelCompat?.requireReasoning ?? defaultCompatibility?.requireReasoning,
            maxTokensField: modelCompat?.maxTokensField?.rawValue ?? defaultCompatibility?.maxTokensField,
            requireFinishReason: modelCompat?.requireFinishReason ?? defaultCompatibility?.requireFinishReason,
            requireAssistantAfterTool: modelCompat?.requireAssistantAfterTool ?? defaultCompatibility?.requireAssistantAfterTool,
            cacheFormat: modelCompat?.cacheFormat?.rawValue ?? defaultCompatibility?.cacheFormat,
            supportsThinkingBlockBinding: modelCompat?.supportsThinkingBlockBinding ?? defaultCompatibility?.supportsThinkingBlockBinding,
            requireSignature: modelCompat?.requireSignature ?? defaultCompatibility?.requireSignature,
            zaiToolStream: modelCompat?.zaiToolStream ?? defaultCompatibility?.zaiToolStream,
            sanitizer: modelCompat?.sanitizer?.rawValue ?? defaultCompatibility?.sanitizer,
            mediaInput: defaultCompatibility?.mediaInput
        )
        let modelCaps = request.model.capabilities
        let mergedCaps = AIProtocolUtils.ModelCapabilities(
            promptCacheKey: modelCaps?.promptCacheKey ?? defaultCapabilities?.promptCacheKey,
            store: modelCaps?.store ?? defaultCapabilities?.store,
            streamUsage: modelCaps?.streamUsage ?? defaultCapabilities?.streamUsage,
            strictTools: modelCaps?.tools?.strict ?? defaultCapabilities?.strictTools,
            systemUpdates: modelCaps?.systemUpdates ?? defaultCapabilities?.systemUpdates,
            reasoningUpdates: modelCaps?.reasoning?.updates ?? defaultCapabilities?.reasoningUpdates
        )
        let descriptor = AIProtocolUtils.ModelDescriptor(
            id: request.model.id.rawValue,
            provider: request.model.provider.rawValue,
            routeID: route.id,
            providerMetadataKey: route.providerMetadataKey,
            baseURL: route.defaultBaseURL,
            sanitizer: route.`protocol`.sanitizer ?? modelCompat?.sanitizer?.rawValue,
            compatibility: mergedCompat,
            capabilities: mergedCaps
        )
        let cacheSetting: AIProtocolUtils.CacheSetting = switch request.cache {
        case nil, .some(.auto):
            .auto
        case .some(.none):
            .none
        case .some(.object(let obj)):
            .configured(ttl: obj.ttl?.rawValue)
        }
        let httpOverlay: AIProtocolUtils.HTTPOverlay?
        if request.headers != nil || request.http != nil {
            httpOverlay = AIProtocolUtils.HTTPOverlay(
                headers: request.headers,
                body: request.http?.body,
                query: request.http?.query,
                encoding: request.http?.encoding?.rawValue
            )
        } else {
            httpOverlay = nil
        }
        let systemParts = request.system.map { part in
            AIProtocolUtils.TextPart(text: part.text, cache: toProtocolCacheHint(part.cache))
        }
        return AIProtocolUtils.LLMRequest(
            model: descriptor,
            system: systemParts,
            messages: request.messages.map(toProtocolMessage),
            tools: request.tools.map(toProtocolToolEntry),
            toolChoice: toProtocolToolChoice(request.toolChoice),
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            topK: request.topK,
            frequencyPenalty: request.frequencyPenalty,
            presencePenalty: request.presencePenalty,
            seed: request.seed,
            stop: request.stop,
            cache: cacheSetting,
            promptCacheKey: request.promptCacheKey,
            providerOptions: request.providerOptions,
            http: httpOverlay
        )
    }

    private static func toSchemaFinishReason(_ details: AIProtocolUtils.FinishReasonDetails) -> AISchema.FinishReasonDetails {
        let normalized: AISchema.FinishReason = switch details.normalized {
        case .stop: .stop
        case .length: .length
        case .toolCalls: .toolCalls
        case .contentFilter: .contentFilter
        case .error: .error
        case .unknown: .unknown
        }
        return AISchema.FinishReasonDetails(
            normalized: normalized,
            raw: details.raw,
            category: details.category,
            explanation: details.explanation
        )
    }

    private static func toSchemaUsage(_ usage: AIProtocolUtils.Usage) -> AISchema.Usage {
        AISchema.Usage(
            contextTokens: usage.contextTokens,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            nonCachedInputTokens: usage.nonCachedInputTokens,
            cacheReadInputTokens: usage.cacheReadInputTokens,
            cacheWriteInputTokens: usage.cacheWriteInputTokens,
            reasoningTokens: usage.reasoningTokens,
            totalTokens: usage.totalTokens,
            cost: usage.cost,
            providerMetadata: usage.providerMetadata
        )
    }

    public static func toSchemaEvent(_ event: AIProtocolUtils.LLMEvent) -> AISchema.LLMEvent {
        switch event {
        case .stepStart(let index):
            return .stepStart(AISchema.StepStart(index: index))
        case .textStart(let id, let meta):
            return .textStart(AISchema.TextStart(id: id, providerMetadata: meta))
        case .textDelta(let id, let text, let meta):
            return .textDelta(AISchema.TextDelta(id: id, text: text, providerMetadata: meta))
        case .textEnd(let id, let text, let meta):
            return .textEnd(AISchema.TextEnd(id: id, text: text, providerMetadata: meta))
        case .reasoningStart(let id, let meta):
            return .reasoningStart(AISchema.ReasoningStart(id: id, providerMetadata: meta))
        case .reasoningDelta(let id, let text, let meta):
            return .reasoningDelta(AISchema.ReasoningDelta(id: id, text: text, providerMetadata: meta))
        case .reasoningEnd(let id, let text, let meta):
            return .reasoningEnd(AISchema.ReasoningEnd(id: id, text: text, providerMetadata: meta))
        case .toolInputStart(let id, let name, let ns, let pe, let meta):
            return .toolInputStart(AISchema.ToolInputStart(id: id, name: name, namespace: ns, providerExecuted: pe, providerMetadata: meta))
        case .toolInputDelta(let id, let name, let ns, let text, let partial):
            return .toolInputDelta(AISchema.ToolInputDelta(id: id, name: name, namespace: ns, text: text, input: partial))
        case .toolInputEnd(let id, let name, let ns, let meta):
            return .toolInputEnd(AISchema.ToolInputEnd(id: id, name: name, namespace: ns, providerMetadata: meta))
        case .toolCall(let id, let name, let ns, let input, let pe, let meta):
            return .toolCall(AISchema.ToolCall(id: id, name: name, namespace: ns, input: input, providerExecuted: pe, providerMetadata: meta))
        case .toolInputError(let id, let name, let ns, let raw):
            return .toolInputError(AISchema.ToolInputError(id: id, name: name, namespace: ns, raw: raw))
        case .toolResult(let id, let name, let result, let pe, let meta):
            return .toolResult(AISchema.ToolResult(
                id: id,
                name: name,
                result: toSchemaToolResultValue(result),
                providerExecuted: pe,
                providerMetadata: meta
            ))
        case .media(let media, let meta):
            return .media(AISchema.MediaEvent(media: toSchemaMediaAsset(media), providerMetadata: meta))
        case .compaction(let provider, let id, let text, let encrypted):
            let pid = AISchema.ProviderID.make(provider)
            if let encrypted {
                return .compaction(AISchema.CompactionPart.make(provider: pid, id: id, encrypted: encrypted))
            }
            return .compaction(AISchema.CompactionPart.make(provider: pid, id: id, text: text))
        case .stepFinish(let index, let reason, let usage, let meta):
            return .stepFinish(AISchema.StepFinish(
                index: index,
                reason: toSchemaFinishReason(reason),
                usage: usage.map(toSchemaUsage),
                providerMetadata: meta
            ))
        case .finish(let reason, let usage, let meta):
            return .finish(AISchema.Finish(
                reason: toSchemaFinishReason(reason),
                usage: usage.map(toSchemaUsage),
                providerMetadata: meta
            ))
        }
    }

    public struct ChatRouteSpec: Sendable {
        public let id: String
        public let provider: String
        public let providerMetadataKey: String
        public let `protocol`: ChatProtocolSpec
        public let defaultBaseURL: String?
        public let pathBuilder: @Sendable (AIProtocolUtils.LLMRequest, [String: JSONValue]) -> String
        public let defaultHeaders: [String: String]
        public let defaultProviderOptions: [String: JSONValue]
        public let auth: AIProtocolUtils.AuthStrategy
        /// A resumable transport that may continue one logical response across requests; nil for plain SSE.
        public let continuation: ChatContinuation?

        public init(
            id: String,
            provider: String,
            providerMetadataKey: String? = nil,
            protocol proto: ChatProtocolSpec,
            defaultBaseURL: String? = nil,
            path: String,
            defaultHeaders: [String: String] = [:],
            defaultProviderOptions: [String: JSONValue] = [:],
            auth: AIProtocolUtils.AuthStrategy = .none,
            continuation: ChatContinuation? = nil
        ) {
            self.id = id
            self.provider = provider
            self.providerMetadataKey = providerMetadataKey ?? provider
            self.`protocol` = proto
            self.defaultBaseURL = defaultBaseURL
            self.pathBuilder = { _, _ in path }
            self.defaultHeaders = defaultHeaders
            self.defaultProviderOptions = defaultProviderOptions
            self.auth = auth
            self.continuation = continuation
        }

        public init(
            id: String,
            provider: String,
            providerMetadataKey: String? = nil,
            protocol proto: ChatProtocolSpec,
            defaultBaseURL: String? = nil,
            pathBuilder: @escaping @Sendable (AIProtocolUtils.LLMRequest, [String: JSONValue]) -> String,
            defaultHeaders: [String: String] = [:],
            defaultProviderOptions: [String: JSONValue] = [:],
            auth: AIProtocolUtils.AuthStrategy = .none,
            continuation: ChatContinuation? = nil
        ) {
            self.id = id
            self.provider = provider
            self.providerMetadataKey = providerMetadataKey ?? provider
            self.`protocol` = proto
            self.defaultBaseURL = defaultBaseURL
            self.pathBuilder = pathBuilder
            self.defaultHeaders = defaultHeaders
            self.defaultProviderOptions = defaultProviderOptions
            self.auth = auth
            self.continuation = continuation
        }

        public func with(
            id: String? = nil,
            provider: String? = nil,
            providerMetadataKey: String? = nil,
            baseURL: String? = nil,
            headers: [String: String]? = nil,
            providerOptions: [String: JSONValue]? = nil,
            auth: AIProtocolUtils.AuthStrategy? = nil
        ) -> ChatRouteSpec {
            var mergedHeaders = self.defaultHeaders
            if let headers {
                for (k, v) in headers { mergedHeaders[k] = v }
            }
            let mergedOptions = AIProtocolUtils.JSONCodec.mergeObjects(self.defaultProviderOptions, providerOptions)
            return ChatRouteSpec(
                id: id ?? self.id,
                provider: provider ?? self.provider,
                providerMetadataKey: providerMetadataKey ?? self.providerMetadataKey,
                protocol: self.`protocol`,
                defaultBaseURL: baseURL ?? self.defaultBaseURL,
                pathBuilder: self.pathBuilder,
                defaultHeaders: mergedHeaders,
                defaultProviderOptions: mergedOptions,
                auth: auth ?? self.auth,
                continuation: self.continuation
            )
        }

        private static let anthropicMessagesProtocols: Set<String> = [
            "anthropic-messages", "alibaba-messages", "meta-messages", "zai-messages",
        ]

        /// The request's provider options merged over the route defaults.
        private func effective(_ request: AIProtocolUtils.LLMRequest) -> AIProtocolUtils.LLMRequest {
            var effectiveRequest = request
            if !defaultProviderOptions.isEmpty {
                effectiveRequest.providerOptions = AIProtocolUtils.JSONCodec.mergeObjects(
                    defaultProviderOptions,
                    request.providerOptions
                )
            }
            return effectiveRequest
        }

        /// The JSON body of the first request for `request`, with the caller's `http.body` overlay applied.
        public func requestBody(for request: AIProtocolUtils.LLMRequest) throws -> [String: JSONValue] {
            var body = try `protocol`.buildBody(effective(request))
            if let overlay = request.http?.body {
                body = AIProtocolUtils.JSONCodec.mergeObjects(body, overlay)
            }
            return body
        }

        public func prepareHTTPRequest(
            for request: AIProtocolUtils.LLMRequest,
            body bodyOverride: [String: JSONValue]? = nil,
            baseURLOverride: String? = nil,
            extraHeaders: [String: String] = [:],
            timestampEpochSeconds: Int64? = nil,
            clock: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
        ) throws -> HTTPRequest {
            let effectiveRequest = effective(request)
            let body = try bodyOverride ?? requestBody(for: request)
            let base = (baseURLOverride ?? request.model.baseURL ?? defaultBaseURL ?? "")
                .trimmingTrailingSlashes()
            let path = pathBuilder(effectiveRequest, body)
            var url = base.isEmpty ? path : "\(base)\(path.hasPrefix("/") ? path : "/\(path)")"
            if let query = request.http?.query, !query.isEmpty {
                let sep = url.contains("?") ? "&" : "?"
                let encoded = query.keys.sorted().map { k in
                    "\(AIProtocolUtils.JSONCodec.percentEncodePathComponent(k))=\(AIProtocolUtils.JSONCodec.percentEncodePathComponent(query[k]!))"
                }.joined(separator: "&")
                url += sep + encoded
            }
            var headers = defaultHeaders
            if let reqHeaders = request.http?.headers {
                for (k, v) in reqHeaders { headers[k] = v }
            }
            for (k, v) in extraHeaders { headers[k] = v }
            if Self.anthropicMessagesProtocols.contains(`protocol`.id) {
                headers = AnthropicMessages.transportHeaders(for: body, existing: headers)
            }
            let encodedBody = AIProtocolUtils.JSONCodec.encodeObject(body)
            let post = AIProtocolUtils.ProviderShared.jsonPost(
                url: url,
                body: encodedBody,
                headers: headers,
                encoding: request.http?.encoding
            )
            let resolvedTimestamp = timestampEpochSeconds ?? clock()
            return try auth.apply(to: post, timestampEpochSeconds: resolvedTimestamp)
        }

        /// Executes a streaming chat request through `OpenCodePlatform.HTTPTransport` and yields parsed `LLMEvent`s
        /// incrementally as each chunk arrives via `SSEParser` / `BedrockEventStream.FrameDecoder`.
        public func streamEvents(
            _ request: AIProtocolUtils.LLMRequest,
            transport: any HTTPTransport,
            baseURLOverride: String? = nil,
            extraHeaders: [String: String] = [:],
            timestampEpochSeconds: Int64? = nil,
            clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
        ) -> AsyncThrowingStream<AIProtocolUtils.LLMEvent, Error> {
            let routeSpec = self
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        var body = try routeSpec.requestBody(for: request)
                        var session = routeSpec.continuation?.makeSession(body, "\(request.model.provider)/\(routeSpec.id)")
                        var decoder = routeSpec.`protocol`.makeDecoder(for: request)
                        while true {
                            let httpRequest = try routeSpec.prepareHTTPRequest(
                                for: request,
                                body: body,
                                baseURLOverride: baseURLOverride,
                                extraHeaders: extraHeaders,
                                timestampEpochSeconds: timestampEpochSeconds,
                                clock: clock
                            )
                            let response = try await transport.stream(httpRequest)
                            if response.head.statusCode >= 400 {
                                var errorBytes: [UInt8] = []
                                for try await chunk in response.chunks {
                                    errorBytes.append(contentsOf: chunk)
                                }
                                let bodyText = String(decoding: errorBytes, as: UTF8.self)
                                throw AIRequestExecutor.httpFailure(
                                    message: AIErrorClassifier.providerErrorMessage(bodyText)
                                        ?? "Provider request failed with HTTP \(response.head.statusCode)",
                                    url: httpRequest.url,
                                    status: response.head.statusCode,
                                    responseHeaders: response.head.headers,
                                    responseBody: bodyText
                                )
                            }
                            var dropped: (any Error)? = nil
                            do {
                                for try await chunk in response.chunks {
                                    try Task.checkCancellation()
                                    if chunk.isEmpty { continue }
                                    let produced = try decoder.feed(chunk)
                                    for event in produced {
                                        continuation.yield(event)
                                    }
                                    if try session?.observe(chunk) == true { break }
                                }
                            } catch {
                                guard let current = session, current.canResume(after: error) else { throw error }
                                dropped = error
                            }
                            guard var current = session else { break }
                            guard let nextBody = try current.next(dropped: dropped) else { break }
                            session = current
                            for event in try decoder.beginNextRequest() {
                                continuation.yield(event)
                            }
                            body = nextBody
                        }
                        let trailing = try decoder.finish()
                        for event in trailing {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }

        /// Executes a streaming chat request through `OpenCodePlatform.HTTPTransport`, consuming chunks
        /// incrementally via `SSEParser` / `BedrockEventStream.FrameDecoder`, and returns all parsed `LLMEvent`s.
        public func executeStream(
            _ request: AIProtocolUtils.LLMRequest,
            transport: any HTTPTransport,
            baseURLOverride: String? = nil,
            extraHeaders: [String: String] = [:],
            timestampEpochSeconds: Int64? = nil,
            clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
        ) async throws -> [AIProtocolUtils.LLMEvent] {
            var events: [AIProtocolUtils.LLMEvent] = []
            for try await event in streamEvents(
                request,
                transport: transport,
                baseURLOverride: baseURLOverride,
                extraHeaders: extraHeaders,
                timestampEpochSeconds: timestampEpochSeconds,
                clock: clock
            ) {
                events.append(event)
            }
            return events
        }

        /// Bridges this protocol route into a runnable `AIRoute.AnyRoute` backed by incremental HTTP streaming.
        public func asAnyRoute(
            defaultCompatibility: AIProtocolUtils.ModelCompatibility? = nil,
            defaultCapabilities: AIProtocolUtils.ModelCapabilities? = nil,
            options: AISchema.RequestOptions? = nil,
            transport: (any HTTPTransport)? = nil,
            clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
        ) -> AIRoute.AnyRoute {
            let routeSpec = self
            let sanitizer: AISchema.LanguageModelSanitizerCompatibility? =
                `protocol`.sanitizer.flatMap(AISchema.LanguageModelSanitizerCompatibility.init(rawValue:))
            return AIRoute.AnyRoute(
                id: id,
                provider: AISchema.ProviderID.make(provider),
                providerMetadataKey: providerMetadataKey,
                protocolID: `protocol`.id,
                baseURL: defaultBaseURL,
                transportID: "http-json",
                options: options,
                sanitizer: sanitizer,
                buildBody: { request in
                    let protoReq = AIProtocols.toProtocolRequest(
                        request,
                        route: routeSpec,
                        defaultCompatibility: defaultCompatibility,
                        defaultCapabilities: defaultCapabilities
                    )
                    var effective = protoReq
                    if !routeSpec.defaultProviderOptions.isEmpty {
                        effective.providerOptions = AIProtocolUtils.JSONCodec.mergeObjects(
                            routeSpec.defaultProviderOptions,
                            protoReq.providerOptions
                        )
                    }
                    do {
                        var body = try routeSpec.`protocol`.buildBody(effective)
                        if let overlay = effective.http?.body {
                            body = AIProtocolUtils.JSONCodec.mergeObjects(body, overlay)
                        }
                        return .object(body)
                    } catch let error as AIProtocolUtils.ProtocolError {
                        throw AIProtocols.toProtocolError(error)
                    }
                },
                executeStream: { request, runtime, streamOptions in
                    AsyncThrowingStream { continuation in
                        let task = Task {
                            var httpContext: AISchema.HttpContext? = nil
                            do {
                                let protoReq = AIProtocols.toProtocolRequest(
                                    request,
                                    route: routeSpec,
                                    defaultCompatibility: defaultCompatibility,
                                    defaultCapabilities: defaultCapabilities
                                )
                                var body = try routeSpec.requestBody(for: protoReq)
                                var session = routeSpec.continuation?.makeSession(
                                    body,
                                    "\(request.model.provider.rawValue)/\(routeSpec.id)"
                                )
                                let executor: AIRequestExecutor.RequestExecutorService = transport.map {
                                    AIRequestExecutor.layer(transport: $0)
                                } ?? runtime.http
                                let middleware = AIRequestExecutor.withFetch(request.fetch, middleware: streamOptions?.http)
                                let execFn = AIRequestExecutor.withTimeout(
                                    AIRequestExecutor.withTls(
                                        { req, mw in try await executor.execute(req, middleware: mw) },
                                        tls: request.http?.tls
                                    ),
                                    timeout: request.timeout
                                )

                                var decoder = routeSpec.`protocol`.makeDecoder(for: protoReq)
                                var sawFinish = false
                                while true {
                                    let httpRequest = try routeSpec.prepareHTTPRequest(
                                        for: protoReq,
                                        body: body,
                                        clock: clock
                                    )
                                    let response = try await execFn(httpRequest, middleware)
                                    if httpContext == nil { httpContext = AIRequestExecutor.responseHttp(response) }
                                    var dropped: (any Error)? = nil
                                    do {
                                        for try await chunk in AIRequestExecutor.responseStream(response) {
                                            try Task.checkCancellation()
                                            if chunk.isEmpty { continue }
                                            let produced = try decoder.feed(chunk)
                                            for ev in produced {
                                                let schemaEvent = AIProtocols.toSchemaEvent(ev)
                                                if schemaEvent.isFinish { sawFinish = true }
                                                continuation.yield(schemaEvent)
                                            }
                                            if try session?.observe(chunk) == true { break }
                                        }
                                    } catch {
                                        guard let current = session, current.canResume(after: error) else { throw error }
                                        dropped = error
                                    }
                                    guard var current = session else { break }
                                    guard let nextBody = try current.next(dropped: dropped) else { break }
                                    session = current
                                    for ev in try decoder.beginNextRequest() {
                                        let schemaEvent = AIProtocols.toSchemaEvent(ev)
                                        if schemaEvent.isFinish { sawFinish = true }
                                        continuation.yield(schemaEvent)
                                    }
                                    body = nextBody
                                }
                                let trailing = try decoder.finish()
                                for ev in trailing {
                                    let schemaEvent = AIProtocols.toSchemaEvent(ev)
                                    if schemaEvent.isFinish { sawFinish = true }
                                    continuation.yield(schemaEvent)
                                }
                                if !sawFinish {
                                    throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                                        message: "The provider response ended unexpectedly.",
                                        http: httpContext,
                                        classification: .incompleteStream,
                                        route: "\(request.model.provider.rawValue)/\(routeSpec.id)"
                                    )))
                                }
                                continuation.finish()
                            } catch let aiError as AISchema.AIError {
                                continuation.finish(throwing: aiError)
                            } catch let protoError as AIProtocolUtils.ProtocolError {
                                continuation.finish(throwing: AIProtocols.toProtocolError(protoError, http: httpContext))
                            } catch {
                                continuation.finish(throwing: error)
                            }
                        }
                        continuation.onTermination = { _ in
                            task.cancel()
                        }
                    }
                }
            )
        }

        /// Bridges this protocol route directly into a runnable `AISchema.LanguageModel`.
        public func asLanguageModel(
            modelID: String,
            config: AIProviders.ProviderConfig = AIProviders.ProviderConfig(),
            transport: (any HTTPTransport)? = nil,
            options: AISchema.RequestOptions? = nil,
            capabilities: AISchema.Capabilities? = nil,
            compatibility: AISchema.LanguageModelCompatibility? = nil,
            defaultCompatibility: AIProtocolUtils.ModelCompatibility? = nil,
            defaultCapabilities: AIProtocolUtils.ModelCapabilities? = nil,
            clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
        ) -> AISchema.LanguageModel {
            let resolvedProvider = config.providerOverride ?? provider
            let resolvedAuth: AIProtocolUtils.AuthStrategy
            if let explicitAuth = config.auth {
                resolvedAuth = explicitAuth
            } else if let token = config.authToken, !token.isEmpty {
                resolvedAuth = .bearer(token)
            } else {
                switch config.apiKey {
                case .disabled:
                    resolvedAuth = .none
                case .explicit(let key):
                    if resolvedProvider == "anthropic" || resolvedProvider == "anthropic-compatible" {
                        resolvedAuth = .header(name: "x-api-key", value: key)
                    } else if resolvedProvider == "google" {
                        resolvedAuth = .header(name: "x-goog-api-key", value: key)
                    } else if resolvedProvider == "azure" {
                        resolvedAuth = .sequence([.remove("authorization"), .header(name: "api-key", value: key)])
                    } else {
                        resolvedAuth = .bearer(key)
                    }
                case .inherited:
                    resolvedAuth = auth
                }
            }
            let configured = with(
                provider: resolvedProvider,
                baseURL: config.baseURL,
                headers: config.headers,
                providerOptions: config.providerOptions,
                auth: resolvedAuth
            )
            let configHttp: AISchema.HttpOptions? = (config.queryParams != nil || config.body != nil)
                ? AISchema.HttpOptions(query: config.queryParams, body: config.body)
                : nil
            let configRequestOptions = AISchema.RequestOptions(
                http: configHttp,
                providerOptions: config.providerOptions
            )
            let mergedOptions = AISchema.mergeRequestOptions(
                configRequestOptions.isEmpty ? nil : configRequestOptions,
                options
            )
            let anyRoute = configured.asAnyRoute(
                defaultCompatibility: defaultCompatibility,
                defaultCapabilities: defaultCapabilities,
                options: mergedOptions,
                transport: transport,
                clock: clock
            )
            return AISchema.LanguageModel.make(AISchema.LanguageModel.Input(
                id: modelID,
                provider: resolvedProvider,
                route: anyRoute,
                options: mergedOptions,
                capabilities: capabilities,
                compatibility: compatibility
            ))
        }
    }

    // MARK: - OpenAIFreeform (packages/ai/src/protocols/openai-freeform.ts — 6 symbols)

    public enum OpenAIFreeform {
        // parity: ai/src/protocols/openai-freeform.ts#Custom [status=implemented hash=2bd792a3b4f9]
        public struct Custom: Equatable, Hashable, Sendable {
            public let field: String
            public let format: AIProtocolUtils.FreeformFormat

            public init(field: String, format: AIProtocolUtils.FreeformFormat) {
                self.field = field
                self.format = format
            }
        }

        public struct GrammarSpec: Equatable, Hashable, Sendable {
            public let syntax: String
            public let definition: String

            public init(syntax: String, definition: String) {
                self.syntax = syntax
                self.definition = definition
            }

            public var jsonValue: JSONValue {
                .object(["syntax": .string(syntax), "definition": .string(definition)])
            }
        }

        // parity: ai/src/protocols/openai-freeform.ts#resolve [status=implemented hash=2d1b2170ae17]
        public static func resolve(_ tool: AIProtocolUtils.ToolDefinition) -> Custom? {
            guard let format = tool.freeform,
                  tool.native == nil,
                  let field = AIProtocolUtils.ToolDefinition.freeformField(tool.inputSchema) else {
                return nil
            }
            return Custom(field: field, format: format)
        }

        // parity: ai/src/protocols/openai-freeform.ts#tools [status=implemented hash=df1ca45d840a]
        public static func tools(_ request: AIProtocolUtils.LLMRequest) -> [String: Custom] {
            var map: [String: Custom] = [:]
            for tool in AIProtocolUtils.ProviderShared.flattenTools(request.tools) {
                if let custom = resolve(tool) {
                    map[tool.name] = custom
                }
            }
            return map
        }

        // parity: ai/src/protocols/openai-freeform.ts#grammar [status=implemented hash=424bd8401928]
        public static func grammar(_ format: AIProtocolUtils.FreeformFormat) -> GrammarSpec? {
            switch format {
            case .text: return nil
            case .regex(let pattern): return GrammarSpec(syntax: "regex", definition: pattern)
            case .lark(let definition): return GrammarSpec(syntax: "lark", definition: definition)
            }
        }

        // parity: ai/src/protocols/openai-freeform.ts#toRaw [status=implemented hash=7af934122b9b]
        public static func toRaw(_ custom: Custom, input: JSONValue) -> String {
            if case .object(let obj) = input, case .string(let s) = obj[custom.field] {
                return s
            }
            return AIProtocolUtils.JSONCodec.encode(input)
        }

        private static func fieldName(_ custom: Custom?) -> String {
            custom?.field ?? "input"
        }

        // parity: ai/src/protocols/openai-freeform.ts#fromRaw [status=implemented hash=0bd3e25be21b]
        public static func fromRaw(_ custom: Custom?, raw: String) -> String {
            AIProtocolUtils.JSONCodec.encodeObject([fieldName(custom): .string(raw)])
        }

        // parity: ai/src/protocols/openai-freeform.ts#streamDelta [status=implemented hash=dcb068547a2a]
        public static func streamDelta(_ raw: String) -> String {
            let encoded = AIProtocolUtils.JSONCodec.encode(.string(raw))
            guard encoded.count >= 2 else { return "" }
            return String(encoded.dropFirst().dropLast())
        }

        // parity: ai/src/protocols/openai-freeform.ts#streamStart [status=implemented hash=cfbcb13fd985]
        public static func streamStart(_ custom: Custom?, raw: String = "") -> String {
            "{\(AIProtocolUtils.JSONCodec.encode(.string(fieldName(custom)))):\"\(streamDelta(raw))"
        }

        // parity: ai/src/protocols/openai-freeform.ts#metadata [status=implemented hash=48e691b6c0b4]
        public static func metadata(itemId: String, custom: Bool) -> [String: JSONValue] {
            custom ? ["itemId": .string(itemId), "custom": .bool(true)] : ["itemId": .string(itemId)]
        }

        // parity: ai/src/protocols/openai-freeform.ts#keepsItemID [status=implemented hash=091ac9278404]
        public static func keepsItemID(
            providerMetadata: AIProtocolUtils.ProviderMetadata?,
            key: String,
            custom: Bool
        ) -> Bool {
            let wasCustom = AIProtocolUtils.JSONCodec.boolValue(providerMetadata?[key]?["custom"]) == true
            return wasCustom == custom
        }

        // parity: ai/src/protocols/openai-freeform.ts#close [status=implemented hash=a5c1b7749c10]
        public static func close<K: Hashable & Sendable>(
            tools: AIProtocolUtils.ToolStream.State<K>,
            keys: [K],
            final: (custom: Custom?, raw: String)? = nil
        ) -> (tools: AIProtocolUtils.ToolStream.State<K>, events: [AIProtocolUtils.LLMEvent]) {
            var currentTools = tools
            var events: [AIProtocolUtils.LLMEvent] = []
            for key in keys {
                guard let pending = currentTools[key] else { continue }
                let closedJSON = pending.input + "\"}"
                if let final {
                    let parsed = (try? AIProtocolUtils.JSONCodec.decode(closedJSON)).flatMap(AIProtocolUtils.JSONCodec.objectValue)
                    let streamedVal = AIProtocolUtils.JSONCodec.stringValue(parsed?[fieldName(final.custom)])
                    if streamedVal != final.raw { continue }
                }
                if let outcome = AIProtocolUtils.ToolStream.append(currentTools, key: key, text: "\"}") {
                    currentTools = outcome.tools
                    events.append(contentsOf: outcome.events)
                }
            }
            return (currentTools, events)
        }
    }

    // MARK: - AnthropicMessages (packages/ai/src/protocols/anthropic-messages.ts — 12 symbols)

    public enum AnthropicMessages {
        public static let adapterID = "anthropic-messages"
        public static let minThinkingBudget = 1_024
        public static let breakpointCap = 4

        // parity: ai/src/protocols/anthropic-messages.ts#DEFAULT_BASE_URL [status=implemented hash=603f87ef2d9a]
        public static let DEFAULT_BASE_URL = "https://api.anthropic.com/v1"

        // parity: ai/src/protocols/anthropic-messages.ts#PATH [status=implemented hash=46ecac3cb034]
        public static let PATH = "/messages"

        // parity: ai/src/protocols/anthropic-messages.ts#DEFAULT_MAX_TOKENS [status=implemented hash=32bacb541542]
        public static let DEFAULT_MAX_TOKENS = 32_000

        public static let sseEvents: Set<String> = [
            "message",
            "message_start",
            "message_delta",
            "message_stop",
            "content_block_start",
            "content_block_delta",
            "content_block_stop",
            "ping",
            "error",
        ]

        // parity: ai/src/protocols/anthropic-messages.ts#framing [status=implemented hash=9eabd122ec76]
        public static let framing: FramingKind = .sseEvents

        // parity: ai/src/protocols/anthropic-messages.ts#ThinkingInput [status=implemented hash=bcea2ae784f3]
        public enum ThinkingInput: Equatable, Hashable, Sendable {
            case enabled(budgetTokens: Int, display: String? = nil)
            case adaptive(display: String? = nil)
            case disabled
            case betweenTools
        }

        // parity: ai/src/protocols/anthropic-messages.ts#ContextManagement [status=implemented hash=06f75743f849]
        public struct ContextManagement: Equatable, Hashable, Sendable {
            public struct Edit: Equatable, Hashable, Sendable {
                public let type: String
                public let triggerInputTokens: Int?
                public let pauseAfterCompaction: Bool?
                public let instructions: String?

                public init(
                    type: String = "compact_20260112",
                    triggerInputTokens: Int? = nil,
                    pauseAfterCompaction: Bool? = nil,
                    instructions: String? = nil
                ) {
                    self.type = type
                    self.triggerInputTokens = triggerInputTokens
                    self.pauseAfterCompaction = pauseAfterCompaction
                    self.instructions = instructions
                }
            }

            public let edits: [Edit]
            public init(edits: [Edit]) { self.edits = edits }
        }

        // parity: ai/src/protocols/anthropic-messages.ts#OptionsInput [status=implemented hash=f75e9b8ed22c]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var contextManagement: ContextManagement?
            public var thinking: ThinkingInput?
            public var effort: String?
            public var serviceTier: String?
            public var speed: String?
            public var inferenceGeo: String?
            public var userID: String?
            public var cacheControl: AIProtocolUtils.CacheHint?

            public init(
                contextManagement: ContextManagement? = nil,
                thinking: ThinkingInput? = nil,
                effort: String? = nil,
                serviceTier: String? = nil,
                speed: String? = nil,
                inferenceGeo: String? = nil,
                userID: String? = nil,
                cacheControl: AIProtocolUtils.CacheHint? = nil
            ) {
                self.contextManagement = contextManagement
                self.thinking = thinking
                self.effort = effort
                self.serviceTier = serviceTier
                self.speed = speed
                self.inferenceGeo = inferenceGeo
                self.userID = userID
                self.cacheControl = cacheControl
            }
        }

        // parity: ai/src/protocols/anthropic-messages.ts#ProviderOptionsInput [status=implemented hash=b8c6e72d7d57]
        public typealias ProviderOptionsInput = OptionsInput

        // parity: ai/src/protocols/anthropic-messages.ts#AnthropicMessagesBody [status=implemented hash=fb39d631bac1]
        public typealias AnthropicMessagesBody = [String: JSONValue]

        public struct ParserState: Equatable, Sendable {
            public let provider: String
            public let providerMetadataKey: String
            public var compactions: [Int: String?]
            public var tools: AIProtocolUtils.ToolStream.State<Int>
            public var reasoningSignatures: [Int: String]
            public var usage: AIProtocolUtils.Usage?
            public var pendingFinishReason: AIProtocolUtils.FinishReasonDetails?
            public var pendingFinishMetadata: AIProtocolUtils.ProviderMetadata?
            public var lifecycle: AIProtocolUtils.Lifecycle.State

            public init(provider: String, providerMetadataKey: String) {
                self.provider = provider
                self.providerMetadataKey = providerMetadataKey
                self.compactions = [:]
                self.tools = AIProtocolUtils.ToolStream.empty()
                self.reasoningSignatures = [:]
                self.usage = nil
                self.pendingFinishReason = nil
                self.pendingFinishMetadata = nil
                self.lifecycle = AIProtocolUtils.Lifecycle.initial()
            }
        }

        private static func cacheControlJSON(
            _ breakpoints: inout AIProtocolUtils.Cache.Breakpoints,
            cache: AIProtocolUtils.CacheHint?
        ) -> JSONValue? {
            guard let cache, cache.type == "ephemeral" || cache.type == "persistent" else { return nil }
            guard AIProtocolUtils.Cache.take(&breakpoints) else { return nil }
            var obj: [String: JSONValue] = ["type": .string("ephemeral")]
            if let ttl = cache.ttl { obj["ttl"] = .string(ttl) }
            return .object(obj)
        }

        private static func scrubToolCallID(_ id: String) -> String {
            String(id.map { ch in
                let isValid = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_" || ch == "-"
                return isValid ? ch : "_"
            })
        }

        private static func lowerMedia(
            _ part: AIProtocolUtils.MediaPart,
            request: AIProtocolUtils.LLMRequest,
            breakpoints: inout AIProtocolUtils.Cache.Breakpoints
        ) throws(AIProtocolUtils.ProtocolError) -> JSONValue {
            let mime = part.media.mediaType.lowercased()
            let cc = cacheControlJSON(&breakpoints, cache: part.cache)
            if mime.hasPrefix("video/") {
                let source: JSONValue
                if let inline = part.media.inline() {
                    source = .object(["type": .string("base64"), "media_type": .string(mime), "data": .string(inline.base64)])
                } else {
                    let ref = try AIProtocolUtils.ProviderShared.mediaReference(
                        asset: part.media,
                        provider: request.model.provider,
                        label: "Messages video"
                    )
                    if ref.type == .ref && !ref.value.contains("://") {
                        source = .object(["type": .string("file"), "file_id": .string(ref.value)])
                    } else {
                        source = .object(["type": .string("url"), "url": .string(ref.value)])
                    }
                }
                var obj: [String: JSONValue] = ["type": .string("video"), "source": source]
                if let cc { obj["cache_control"] = cc }
                return .object(obj)
            }
            let metaKey = request.model.providerMetadataKey ?? request.model.provider
            let mediaMeta = part.providerMetadata?[metaKey]
            func imageBlock(_ source: JSONValue) -> JSONValue {
                var obj: [String: JSONValue] = ["type": .string("image"), "source": source]
                if let cc { obj["cache_control"] = cc }
                if let t = mediaMeta?["transformations"] { obj["transformations"] = t }
                return .object(obj)
            }
            func documentBlock(_ source: JSONValue) -> JSONValue {
                var obj: [String: JSONValue] = ["type": .string("document"), "source": source]
                if let cc { obj["cache_control"] = cc }
                if let title = AIProtocolUtils.JSONCodec.stringValue(mediaMeta?["title"]) ?? part.filename {
                    obj["title"] = .string(title)
                }
                if let ctx = mediaMeta?["context"] { obj["context"] = ctx }
                if let cit = mediaMeta?["citations"] { obj["citations"] = cit }
                return .object(obj)
            }
            if let fileID = AIProtocolUtils.JSONCodec.stringValue(mediaMeta?["file_id"]) {
                let source = JSONValue.object(["type": .string("file"), "file_id": .string(fileID)])
                return mime.hasPrefix("image/") ? imageBlock(source) : documentBlock(source)
            }
            if let urlStr = AIProtocolUtils.ProviderShared.mediaUrl(part.media)?.trimmingASCIIWhitespace(),
               urlStr.lowercased().hasPrefix("http://") || urlStr.lowercased().hasPrefix("https://") {
                let source = JSONValue.object(["type": .string("url"), "url": .string(urlStr)])
                if mime.hasPrefix("image/") { return imageBlock(source) }
                if mime == "application/pdf" { return documentBlock(source) }
            }
            let inline = try AIProtocolUtils.ProviderShared.requireInlineMedia(route: "Anthropic Messages", asset: part.media)
            if mime == "text/plain" {
                let decodedText: String
                if let bytes = try? base64ToBytes(inline.base64) {
                    decodedText = String(decoding: bytes, as: UTF8.self)
                } else {
                    decodedText = inline.base64
                }
                return documentBlock(.object(["type": .string("text"), "media_type": .string("text/plain"), "data": .string(decodedText)]))
            }
            if inline.mime == "application/pdf" {
                return documentBlock(.object(["type": .string("base64"), "media_type": .string("application/pdf"), "data": .string(inline.base64)]))
            }
            guard inline.mime.hasPrefix("image/") else {
                throw AIProtocolUtils.ProviderShared.invalidRequest("Anthropic Messages does not support media type \(part.media.mediaType)")
            }
            return imageBlock(.object(["type": .string("base64"), "media_type": .string(inline.mime), "data": .string(inline.base64)]))
        }

        private static func serverToolResultType(_ name: String) -> String? {
            switch name {
            case "web_search": return "web_search_tool_result"
            case "code_execution": return "code_execution_tool_result"
            case "web_fetch": return "web_fetch_tool_result"
            default: return nil
            }
        }

        private static func requireThinkingSignature(_ request: AIProtocolUtils.LLMRequest) -> Bool {
            if let explicit = request.model.compatibility?.requireSignature { return explicit }
            let provider = request.model.provider.lowercased()
            let model = request.model.id.lowercased()
            let baseURL = (request.model.baseURL ?? "").lowercased()
            if provider == "kimi-for-coding" || provider == "moonshotai" || provider == "moonshotai-cn"
                || model.hasPrefix("kimi-") || baseURL.contains("api.kimi.com/coding")
                || baseURL.contains("api.moonshot.ai/anthropic") || baseURL.contains("api.moonshot.cn/anthropic") {
                return false
            }
            if provider.contains("xiaomi") || model.contains("mimo") || baseURL.contains("xiaomimimo.com") {
                return false
            }
            if model.hasPrefix("qwen") || model.hasPrefix("minimax-") { return false }
            return true
        }

        public static func fromRequest(_ request: AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> AnthropicMessagesBody {
            var breakpoints = AIProtocolUtils.Cache.newBreakpoints(breakpointCap)
            let flattened = AIProtocolUtils.ProviderShared.flattenToolRequest(request)
            let opts = request.providerOptions ?? [:]
            let maxTokens = request.maxTokens ?? DEFAULT_MAX_TOKENS
            let metaKey = request.model.providerMetadataKey ?? request.model.provider

            // 1. Tools (highest cache priority)
            var toolsJSON: [JSONValue]? = nil
            if !flattened.tools.isEmpty {
                toolsJSON = flattened.tools.map { tool in
                    var obj: [String: JSONValue] = [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "input_schema": .object(tool.inputSchema),
                    ]
                    if let cc = cacheControlJSON(&breakpoints, cache: tool.cache) {
                        obj["cache_control"] = cc
                    }
                    return .object(obj)
                }
            }

            // 2. System blocks
            let nonEmptySystem = request.system.filter { !$0.text.isEmpty }
            let systemJSON: [JSONValue]? = nonEmptySystem.isEmpty ? nil : nonEmptySystem.map { part in
                var obj: [String: JSONValue] = ["type": .string("text"), "text": .string(part.text)]
                if let cc = cacheControlJSON(&breakpoints, cache: part.cache) { obj["cache_control"] = cc }
                return .object(obj)
            }

            // 3. Messages
            var messagesJSON: [[String: JSONValue]] = []
            func appendUserBlock(_ block: JSONValue) {
                if let last = messagesJSON.last, case .string("user") = last["role"],
                   case .array(var existing) = last["content"] {
                    existing.append(block)
                    messagesJSON[messagesJSON.count - 1]["content"] = .array(existing)
                } else {
                    messagesJSON.append(["role": .string("user"), "content": .array([block])])
                }
            }

            for message in flattened.request.messages {
                switch message.role {
                case .system:
                    let wrapped = try AIProtocolUtils.ProviderShared.wrappedSystemUpdate(route: "Anthropic Messages", message: message)
                    var block: [String: JSONValue] = ["type": .string("text"), "text": .string(wrapped.text)]
                    if let cc = cacheControlJSON(&breakpoints, cache: wrapped.cache) { block["cache_control"] = cc }
                    appendUserBlock(.object(block))

                case .user:
                    var content: [JSONValue] = []
                    for part in message.content {
                        switch part {
                        case .text(let tp):
                            if tp.text.trimmingASCIIWhitespace().isEmpty { continue }
                            var obj: [String: JSONValue] = ["type": .string("text"), "text": .string(tp.text)]
                            if let cc = cacheControlJSON(&breakpoints, cache: tp.cache) { obj["cache_control"] = cc }
                            content.append(.object(obj))
                        case .media(let mp):
                            content.append(try lowerMedia(mp, request: request, breakpoints: &breakpoints))
                        default:
                            break
                        }
                    }
                    if !content.isEmpty {
                        messagesJSON.append(["role": .string("user"), "content": .array(content)])
                    }

                case .assistant:
                    var content: [JSONValue] = []
                    for part in message.content {
                        switch part {
                        case .compaction(let cp):
                            guard cp.provider == request.model.provider, let text = cp.text else {
                                throw AIProtocolUtils.ProviderShared.invalidRequest("Compaction state must be replayed to its originating provider and API")
                            }
                            content.append(.object(["type": .string("compaction"), "content": .string(text)]))
                        case .text(let tp):
                            if tp.text.trimmingASCIIWhitespace().isEmpty { continue }
                            var obj: [String: JSONValue] = ["type": .string("text"), "text": .string(tp.text)]
                            if let cc = cacheControlJSON(&breakpoints, cache: tp.cache) { obj["cache_control"] = cc }
                            content.append(.object(obj))
                        case .reasoning(let rp):
                            let sig = rp.encrypted ?? AIProtocolUtils.JSONCodec.stringValue(rp.providerMetadata?[metaKey]?["signature"])
                            let redacted = AIProtocolUtils.JSONCodec.stringValue(rp.providerMetadata?[metaKey]?["redactedData"])
                            if sig == nil, let redacted {
                                content.append(.object(["type": .string("redacted_thinking"), "data": .string(redacted)]))
                            } else if let sig, !sig.trimmingASCIIWhitespace().isEmpty {
                                content.append(.object(["type": .string("thinking"), "thinking": .string(rp.text), "signature": .string(sig)]))
                            } else if !rp.text.trimmingASCIIWhitespace().isEmpty && !requireThinkingSignature(request) {
                                content.append(.object(["type": .string("thinking"), "thinking": .string(rp.text), "signature": .string("")]))
                            }
                        case .toolCall(let tc):
                            let blockType = tc.providerExecuted == true ? "server_tool_use" : "tool_use"
                            content.append(.object([
                                "type": .string(blockType),
                                "id": .string(scrubToolCallID(tc.id)),
                                "name": .string(tc.name),
                                "input": tc.input,
                            ]))
                        case .toolResult(let tr) where tr.providerExecuted == true:
                            guard let wireType = serverToolResultType(tr.name) else {
                                throw AIProtocolUtils.ProviderShared.invalidRequest("Anthropic Messages does not know how to round-trip server tool result for \(tr.name)")
                            }
                            let payload: JSONValue
                            if let saved = tr.providerMetadata?[metaKey]?["result"] {
                                payload = saved
                            } else {
                                switch tr.result {
                                case .json(let j): payload = j
                                case .error(let e): payload = e
                                case .text(let t): payload = .string(t)
                                case .content: payload = .string(AIProtocolUtils.ProviderShared.toolResultText(tr))
                                }
                            }
                            content.append(.object([
                                "type": .string(wireType),
                                "tool_use_id": .string(scrubToolCallID(tr.id)),
                                "content": payload,
                            ]))
                        default:
                            throw AIProtocolUtils.ProviderShared.invalidRequest("Anthropic Messages assistant messages only support text, reasoning, and tool-call content for now")
                        }
                    }
                    if !content.isEmpty {
                        messagesJSON.append(["role": .string("assistant"), "content": .array(content)])
                    }

                case .tool:
                    var content: [JSONValue] = []
                    for part in message.content {
                        guard case .toolResult(let tr) = part else { continue }
                        let resultContent: JSONValue
                        if case .content(let items) = tr.result {
                            var blocks: [JSONValue] = []
                            for item in items {
                                switch item {
                                case .text(let t):
                                    blocks.append(.object(["type": .string("text"), "text": .string(t)]))
                                case .file(let f):
                                    var unusedBP = AIProtocolUtils.Cache.newBreakpoints(0)
                                    blocks.append(try lowerMedia(AIProtocolUtils.ProviderShared.toolFileMedia(f), request: request, breakpoints: &unusedBP))
                                }
                            }
                            resultContent = .array(blocks)
                        } else {
                            resultContent = .string(AIProtocolUtils.ProviderShared.toolResultText(tr))
                        }
                        var obj: [String: JSONValue] = [
                            "type": .string("tool_result"),
                            "tool_use_id": .string(scrubToolCallID(tr.id)),
                            "content": resultContent,
                        ]
                        if case .error = tr.result { obj["is_error"] = .bool(true) }
                        if let cc = cacheControlJSON(&breakpoints, cache: tr.cache) { obj["cache_control"] = cc }
                        content.append(.object(obj))
                    }
                    if let last = messagesJSON.last, case .string("user") = last["role"],
                       case .array(let prevBlocks) = last["content"],
                       prevBlocks.allSatisfy({ AIProtocolUtils.JSONCodec.stringValue(AIProtocolUtils.JSONCodec.objectValue($0)?["type"]) == "tool_result" }) {
                        messagesJSON[messagesJSON.count - 1]["content"] = .array(prevBlocks + content)
                    } else if !content.isEmpty {
                        messagesJSON.append(["role": .string("user"), "content": .array(content)])
                    }
                }
            }

            // 4. Tool Choice
            var toolChoiceJSON: JSONValue? = nil
            if toolsJSON != nil, let tc = request.toolChoice {
                toolChoiceJSON = try AIProtocolUtils.ProviderShared.matchToolChoice(
                    route: "Anthropic Messages",
                    toolChoice: tc,
                    auto: {
                        var obj: [String: JSONValue] = ["type": .string("auto")]
                        if let d = tc.disableParallelToolUse { obj["disable_parallel_tool_use"] = .bool(d) }
                        return .object(obj)
                    },
                    none: { .object(["type": .string("none")]) },
                    required: {
                        var obj: [String: JSONValue] = ["type": .string("any")]
                        if let d = tc.disableParallelToolUse { obj["disable_parallel_tool_use"] = .bool(d) }
                        return .object(obj)
                    },
                    tool: { name in
                        var obj: [String: JSONValue] = ["type": .string("tool"), "name": .string(name)]
                        if let d = tc.disableParallelToolUse { obj["disable_parallel_tool_use"] = .bool(d) }
                        return .object(obj)
                    }
                )
            }

            // 5. Thinking & block binding
            var thinkingJSON: [String: JSONValue]? = nil
            if let rawThinking = AIProtocolUtils.JSONCodec.objectValue(opts["thinking"]),
               let tType = AIProtocolUtils.JSONCodec.stringValue(rawThinking["type"]) {
                if tType == "enabled" {
                    let rawBudget = AIProtocolUtils.JSONCodec.intValue(rawThinking["budget_tokens"])
                        ?? AIProtocolUtils.JSONCodec.intValue(rawThinking["budgetTokens"])
                        ?? minThinkingBudget
                    let fitted = AIProtocolUtils.ProviderShared.fitThinkingBudget(rawBudget, maxTokens: maxTokens, minimum: minThinkingBudget)
                    var tObj: [String: JSONValue] = ["type": .string("enabled"), "budget_tokens": .int(Int64(fitted))]
                    if let d = rawThinking["display"] { tObj["display"] = d }
                    if let bb = rawThinking["block_binding"] { tObj["block_binding"] = bb }
                    thinkingJSON = tObj
                } else {
                    thinkingJSON = rawThinking
                }
            }
            let isThinkingOff = thinkingJSON.flatMap { AIProtocolUtils.JSONCodec.stringValue($0["type"]) }.map {
                $0 == "disabled" || $0 == "between_tools"
            } ?? false
            if !isThinkingOff && AIProtocolUtils.ClaudeModel.supportsThinkingBlockBinding(request.model) {
                var tObj = thinkingJSON ?? ["type": .string("adaptive")]
                var binding = AIProtocolUtils.JSONCodec.objectValue(tObj["block_binding"]) ?? [:]
                if binding["prefix_mismatch_behavior"] == nil {
                    binding["prefix_mismatch_behavior"] = .string("drop_block")
                }
                tObj["block_binding"] = .object(binding)
                thinkingJSON = tObj
            }

            // 6. Assemble body
            var body: [String: JSONValue] = [
                "model": .string(request.model.id),
                "messages": .array(messagesJSON.map(JSONValue.object)),
                "stream": .bool(true),
                "max_tokens": .int(Int64(maxTokens)),
            ]
            if let systemJSON { body["system"] = .array(systemJSON) }
            if let toolsJSON { body["tools"] = .array(toolsJSON) }
            if let toolChoiceJSON { body["tool_choice"] = toolChoiceJSON }
            if let temp = request.temperature { body["temperature"] = .double(temp) }
            if let topP = request.topP { body["top_p"] = .double(topP) }
            if let topK = request.topK { body["top_k"] = .int(Int64(topK)) }
            if let stop = request.stop, !stop.isEmpty { body["stop_sequences"] = .array(stop.map(JSONValue.string)) }
            if let thinkingJSON { body["thinking"] = .object(thinkingJSON) }

            let rawOutputConfig = AIProtocolUtils.JSONCodec.objectValue(opts["output_config"])
                ?? AIProtocolUtils.JSONCodec.objectValue(opts["outputConfig"])
            let effort = AIProtocolUtils.JSONCodec.stringValue(opts["effort"])
                ?? AIProtocolUtils.JSONCodec.stringValue(rawOutputConfig?["effort"])
            let format = rawOutputConfig?["format"]
            if effort != nil || (format != nil && format != .null) {
                var oc: [String: JSONValue] = [:]
                if let effort { oc["effort"] = .string(effort) }
                if let format, format != .null { oc["format"] = format }
                body["output_config"] = .object(oc)
            }
            if let cc = opts["cache_control"] ?? opts["cacheControl"] { body["cache_control"] = cc }
            if let c = opts["container"] { body["container"] = c }
            if let geo = opts["inference_geo"] ?? opts["inferenceGeo"], geo != .null { body["inference_geo"] = geo }
            if let meta = opts["metadata"] { body["metadata"] = meta }
            if let tier = opts["service_tier"] ?? opts["serviceTier"] { body["service_tier"] = tier }
            if let speed = opts["speed"] { body["speed"] = speed }
            if let cm = AIProtocolUtils.JSONCodec.objectValue(opts["contextManagement"]),
               let edits = AIProtocolUtils.JSONCodec.arrayValue(cm["edits"]) {
                let loweredEdits: [JSONValue] = edits.compactMap { entry in
                    guard let e = AIProtocolUtils.JSONCodec.objectValue(entry) else { return nil }
                    var out: [String: JSONValue] = ["type": e["type"] ?? .string("compact_20260112")]
                    if let t = e["trigger"] { out["trigger"] = t }
                    if let p = e["pauseAfterCompaction"] ?? e["pause_after_compaction"] { out["pause_after_compaction"] = p }
                    if let ins = e["instructions"] { out["instructions"] = ins }
                    return .object(out)
                }
                body["context_management"] = .object(["edits": .array(loweredEdits)])
            }
            return body
        }

        public static func mapFinishReason(_ reason: String?) -> AIProtocolUtils.FinishReason {
            switch reason {
            case "end_turn", "stop_sequence", "pause_turn": return .stop
            case "max_tokens", "model_context_window_exceeded": return .length
            case "tool_use": return .toolCalls
            case "refusal": return .contentFilter
            default: return .unknown
            }
        }

        private static func mapUsage(
            _ usageVal: JSONValue?,
            providerMetadataKey: String,
            frame: JSONValue? = nil
        ) -> AIProtocolUtils.Usage? {
            guard let u = AIProtocolUtils.JSONCodec.objectValue(usageVal) else { return nil }
            let iterations: [[String: JSONValue]]
            if let arr = AIProtocolUtils.JSONCodec.arrayValue(u["iterations"]), !arr.isEmpty {
                iterations = arr.compactMap(AIProtocolUtils.JSONCodec.objectValue)
            } else {
                iterations = [u]
            }
            let nonCached = AIProtocolUtils.ProviderShared.sumTokens(iterations.map { AIProtocolUtils.JSONCodec.doubleValue($0["input_tokens"]) })
            let cacheRead = AIProtocolUtils.ProviderShared.sumTokens(iterations.map { AIProtocolUtils.JSONCodec.doubleValue($0["cache_read_input_tokens"]) })
            let cacheWrite = AIProtocolUtils.ProviderShared.sumTokens(iterations.map { AIProtocolUtils.JSONCodec.doubleValue($0["cache_creation_input_tokens"]) })
            let inputTokens = AIProtocolUtils.ProviderShared.sumTokens(nonCached, cacheRead, cacheWrite)
            let outputTokens = AIProtocolUtils.ProviderShared.sumTokens(iterations.map { AIProtocolUtils.JSONCodec.doubleValue($0["output_tokens"]) })
            let reasoningTokens = AIProtocolUtils.ProviderShared.sumTokens(iterations.map { item in
                AIProtocolUtils.JSONCodec.doubleValue(AIProtocolUtils.JSONCodec.objectValue(item["output_tokens_details"])?["thinking_tokens"])
            })
            let last = AIProtocolUtils.JSONCodec.arrayValue(u["iterations"])?.last.flatMap(AIProtocolUtils.JSONCodec.objectValue)
            let contextTokens: Double? = (AIProtocolUtils.JSONCodec.stringValue(last?["type"]) == "message")
                ? AIProtocolUtils.ProviderShared.sumTokens(
                    AIProtocolUtils.JSONCodec.doubleValue(last?["input_tokens"]),
                    AIProtocolUtils.JSONCodec.doubleValue(last?["cache_read_input_tokens"]),
                    AIProtocolUtils.JSONCodec.doubleValue(last?["cache_creation_input_tokens"])
                )
                : nil
            let billing = AIProtocolUtils.ProviderShared.reportedBilling(usage: usageVal, frames: frame.map { [$0] } ?? [])
            return AIProtocolUtils.Usage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                contextTokens: contextTokens,
                nonCachedInputTokens: nonCached,
                cacheReadInputTokens: cacheRead,
                cacheWriteInputTokens: cacheWrite,
                reasoningTokens: reasoningTokens,
                totalTokens: AIProtocolUtils.ProviderShared.totalTokens(inputTokens, outputTokens, nil),
                cost: billing.cost,
                providerMetadata: [providerMetadataKey: u]
            )
        }

        private static func mergeUsage(
            _ left: AIProtocolUtils.Usage?,
            _ right: AIProtocolUtils.Usage?,
            key: String
        ) -> AIProtocolUtils.Usage? {
            guard let left else { return right }
            guard let right else { return left }
            let nonCached = right.nonCachedInputTokens ?? left.nonCachedInputTokens
            let cacheRead = right.cacheReadInputTokens ?? left.cacheReadInputTokens
            let cacheWrite = right.cacheWriteInputTokens ?? left.cacheWriteInputTokens
            let inputTokens = AIProtocolUtils.ProviderShared.sumTokens(nonCached, cacheRead, cacheWrite)
            let outputTokens = right.outputTokens ?? left.outputTokens
            return AIProtocolUtils.Usage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                contextTokens: right.contextTokens ?? left.contextTokens,
                nonCachedInputTokens: nonCached,
                cacheReadInputTokens: cacheRead,
                cacheWriteInputTokens: cacheWrite,
                reasoningTokens: right.reasoningTokens ?? left.reasoningTokens,
                totalTokens: AIProtocolUtils.ProviderShared.totalTokens(inputTokens, outputTokens, nil),
                cost: right.cost ?? left.cost,
                providerMetadata: [key: AIProtocolUtils.JSONCodec.mergeObjects(left.providerMetadata?[key], right.providerMetadata?[key])]
            )
        }

        public static func step(
            state: inout ParserState,
            event rawFrame: [String: JSONValue]
        ) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            let frame = AIProtocolUtils.ProviderShared.withUntypedFrames(rawFrame)
            let eventType = AIProtocolUtils.JSONCodec.stringValue(frame["type"]) ?? ""
            guard sseEvents.contains(eventType) else { return [] }

            switch eventType {
            case "message_start":
                let msgUsage = AIProtocolUtils.JSONCodec.objectValue(frame["message"])?["usage"]
                if let u = mapUsage(msgUsage, providerMetadataKey: state.providerMetadataKey) {
                    state.usage = mergeUsage(state.usage, u, key: state.providerMetadataKey)
                }
                return []

            case "content_block_start":
                guard let block = AIProtocolUtils.JSONCodec.objectValue(frame["content_block"]),
                      let blockType = AIProtocolUtils.JSONCodec.stringValue(block["type"]) else {
                    throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Invalid anthropic/anthropic-messages stream event", body: AIProtocolUtils.JSONCodec.encodeObject(frame))
                }
                let index = AIProtocolUtils.JSONCodec.intValue(frame["index"])
                if blockType == "compaction" {
                    guard let idx = index else {
                        throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Invalid anthropic/anthropic-messages stream event")
                    }
                    state.compactions[idx] = AIProtocolUtils.JSONCodec.stringValue(block["content"])
                    return []
                }
                if blockType == "tool_use" || blockType == "server_tool_use" {
                    guard let idx = index else {
                        throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Anthropic \(blockType) missing index")
                    }
                    guard let id = AIProtocolUtils.JSONCodec.stringValue(block["id"]), !id.isEmpty else {
                        throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Anthropic tool_use missing id at index \(idx)")
                    }
                    let name = AIProtocolUtils.JSONCodec.stringValue(block["name"]) ?? ""
                    let isServer = blockType == "server_tool_use"
                    let initialInput: String
                    if let inp = block["input"], inp != .null {
                        if case .object(let obj) = inp, obj.isEmpty {
                            initialInput = ""
                        } else {
                            initialInput = AIProtocolUtils.JSONCodec.encode(inp)
                        }
                    } else {
                        initialInput = ""
                    }
                    var events: [AIProtocolUtils.LLMEvent] = []
                    state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                    state.tools = AIProtocolUtils.ToolStream.start(
                        state.tools,
                        key: idx,
                        tool: AIProtocolUtils.ToolStream.PendingTool(
                            id: id,
                            name: name,
                            input: initialInput,
                            providerExecuted: isServer
                        )
                    )
                    events.append(.toolInputStart(id: id, name: name, providerExecuted: isServer ? true : nil))
                    return events
                }
                if blockType == "text", let text = AIProtocolUtils.JSONCodec.stringValue(block["text"]) {
                    var events: [AIProtocolUtils.LLMEvent] = []
                    let id = "text-\(index ?? 0)"
                    state.lifecycle = AIProtocolUtils.Lifecycle.textStart(state.lifecycle, events: &events, id: id)
                    if !text.isEmpty {
                        state.lifecycle = AIProtocolUtils.Lifecycle.textDelta(state.lifecycle, events: &events, id: id, text: text)
                    }
                    return events
                }
                if blockType == "thinking", let thinking = AIProtocolUtils.JSONCodec.stringValue(block["thinking"]) {
                    var events: [AIProtocolUtils.LLMEvent] = []
                    let id = "reasoning-\(index ?? 0)"
                    let sig = AIProtocolUtils.JSONCodec.stringValue(block["signature"])
                    let meta: AIProtocolUtils.ProviderMetadata? = sig.map { [state.providerMetadataKey: ["signature": .string($0)]] }
                    state.lifecycle = AIProtocolUtils.Lifecycle.reasoningStart(state.lifecycle, events: &events, id: id, providerMetadata: meta)
                    if !thinking.isEmpty {
                        state.lifecycle = AIProtocolUtils.Lifecycle.reasoningDelta(state.lifecycle, events: &events, id: id, text: thinking, providerMetadata: meta)
                    }
                    if let idx = index, let sig { state.reasoningSignatures[idx] = sig }
                    return events
                }
                if blockType == "redacted_thinking", let data = AIProtocolUtils.JSONCodec.stringValue(block["data"]) {
                    var events: [AIProtocolUtils.LLMEvent] = []
                    let meta: AIProtocolUtils.ProviderMetadata = [state.providerMetadataKey: ["redactedData": .string(data)]]
                    state.lifecycle = AIProtocolUtils.Lifecycle.reasoningStart(state.lifecycle, events: &events, id: "reasoning-\(index ?? 0)", providerMetadata: meta)
                    return events
                }
                let serverNames: [String: String] = [
                    "web_search_tool_result": "web_search",
                    "code_execution_tool_result": "code_execution",
                    "web_fetch_tool_result": "web_fetch",
                ]
                if let toolName = serverNames[blockType] {
                    var events: [AIProtocolUtils.LLMEvent] = []
                    state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                    let contentVal = block["content"] ?? .null
                    let errType = AIProtocolUtils.JSONCodec.stringValue(AIProtocolUtils.JSONCodec.objectValue(contentVal)?["type"]) ?? ""
                    let isError = errType.hasSuffix("_tool_result_error")
                    events.append(.toolResult(
                        id: AIProtocolUtils.JSONCodec.stringValue(block["tool_use_id"]) ?? "",
                        name: toolName,
                        result: isError ? .error(contentVal) : .json(contentVal),
                        providerExecuted: true,
                        providerMetadata: [state.providerMetadataKey: ["blockType": .string(blockType), "result": contentVal]]
                    ))
                    return events
                }
                return []

            case "content_block_delta":
                guard let delta = AIProtocolUtils.JSONCodec.objectValue(frame["delta"]) else {
                    throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Invalid anthropic/anthropic-messages stream event")
                }
                let deltaType = AIProtocolUtils.JSONCodec.stringValue(delta["type"]) ?? ""
                let index = AIProtocolUtils.JSONCodec.intValue(frame["index"])
                if deltaType == "compaction_delta" {
                    guard let idx = index, state.compactions[idx] != nil, delta["content"] != nil else {
                        throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Compaction delta is missing its block or content")
                    }
                    state.compactions[idx] = AIProtocolUtils.JSONCodec.stringValue(delta["content"])
                    return []
                }
                if deltaType == "text_delta", let text = AIProtocolUtils.JSONCodec.stringValue(delta["text"]), !text.isEmpty {
                    let id = "text-\(index ?? 0)"
                    guard state.lifecycle.text.contains(id) else { return [] }
                    var events: [AIProtocolUtils.LLMEvent] = []
                    state.lifecycle = AIProtocolUtils.Lifecycle.textDelta(state.lifecycle, events: &events, id: id, text: text)
                    return events
                }
                if deltaType == "thinking_delta", let thinking = AIProtocolUtils.JSONCodec.stringValue(delta["thinking"]), !thinking.isEmpty {
                    let id = "reasoning-\(index ?? 0)"
                    guard state.lifecycle.reasoning.contains(id) else { return [] }
                    var events: [AIProtocolUtils.LLMEvent] = []
                    state.lifecycle = AIProtocolUtils.Lifecycle.reasoningDelta(state.lifecycle, events: &events, id: id, text: thinking)
                    return events
                }
                if deltaType == "signature_delta", let sig = AIProtocolUtils.JSONCodec.stringValue(delta["signature"]), !sig.isEmpty {
                    let idx = index ?? 0
                    guard state.lifecycle.reasoning.contains("reasoning-\(idx)") else { return [] }
                    state.reasoningSignatures[idx] = (state.reasoningSignatures[idx] ?? "") + sig
                    return []
                }
                if deltaType == "input_json_delta", let idx = index,
                   let partial = AIProtocolUtils.JSONCodec.stringValue(delta["partial_json"]), !partial.isEmpty,
                   state.tools[idx] != nil {
                    let result = AIProtocolUtils.ToolStream.appendExisting(
                        route: adapterID,
                        tools: state.tools,
                        key: idx,
                        text: partial,
                        missingToolMessage: "Anthropic Messages tool argument delta is missing its tool call"
                    )
                    switch result {
                    case .error(let err): throw err
                    case .ok(let outcome):
                        state.tools = outcome.tools
                        var events: [AIProtocolUtils.LLMEvent] = []
                        if !outcome.events.isEmpty {
                            state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                        }
                        events.append(contentsOf: outcome.events)
                        return events
                    }
                }
                return []

            case "content_block_stop":
                guard let idx = AIProtocolUtils.JSONCodec.intValue(frame["index"]) else { return [] }
                if let compactionContent = state.compactions.removeValue(forKey: idx) {
                    var events: [AIProtocolUtils.LLMEvent] = []
                    state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                    events.append(.compaction(provider: state.provider, text: compactionContent))
                    return events
                }
                let finished = try AIProtocolUtils.ToolStream.finish(route: adapterID, tools: state.tools, key: idx)
                state.tools = finished.tools
                var events: [AIProtocolUtils.LLMEvent] = []
                let sig = state.reasoningSignatures.removeValue(forKey: idx)
                if !finished.events.isEmpty {
                    state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                    events.append(contentsOf: finished.events)
                } else {
                    let meta: AIProtocolUtils.ProviderMetadata? = sig.map { [state.providerMetadataKey: ["signature": .string($0)]] }
                    state.lifecycle = AIProtocolUtils.Lifecycle.textEnd(state.lifecycle, events: &events, id: "text-\(idx)")
                    state.lifecycle = AIProtocolUtils.Lifecycle.reasoningEnd(state.lifecycle, events: &events, id: "reasoning-\(idx)", providerMetadata: meta)
                }
                return events

            case "message_delta":
                if let u = mapUsage(frame["usage"], providerMetadataKey: state.providerMetadataKey, frame: .object(frame)) {
                    state.usage = mergeUsage(state.usage, u, key: state.providerMetadataKey)
                }
                if let delta = AIProtocolUtils.JSONCodec.objectValue(frame["delta"]),
                   let stopReason = AIProtocolUtils.JSONCodec.stringValue(delta["stop_reason"]) {
                    let stopSeq = AIProtocolUtils.JSONCodec.stringValue(delta["stop_sequence"])
                    let details = AIProtocolUtils.JSONCodec.objectValue(delta["stop_details"])
                    state.pendingFinishReason = AIProtocolUtils.FinishReasonDetails(
                        normalized: mapFinishReason(stopReason),
                        raw: stopReason,
                        category: AIProtocolUtils.JSONCodec.stringValue(details?["category"]),
                        explanation: AIProtocolUtils.JSONCodec.stringValue(details?["explanation"])
                    )
                    if let stopSeq {
                        state.pendingFinishMetadata = [state.providerMetadataKey: ["stopSequence": .string(stopSeq)]]
                    }
                }
                return []

            case "message_stop":
                if !state.compactions.isEmpty {
                    throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Response ended with an incomplete compaction block")
                }
                let finishedTools = try AIProtocolUtils.ToolStream.finishAll(route: adapterID, tools: state.tools)
                state.tools = finishedTools.tools
                var events: [AIProtocolUtils.LLMEvent] = []
                if !finishedTools.events.isEmpty {
                    state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                    events.append(contentsOf: finishedTools.events)
                }
                for idx in state.reasoningSignatures.keys.sorted() {
                    if let sig = state.reasoningSignatures[idx] {
                        let meta: AIProtocolUtils.ProviderMetadata = [state.providerMetadataKey: ["signature": .string(sig)]]
                        state.lifecycle = AIProtocolUtils.Lifecycle.reasoningEnd(state.lifecycle, events: &events, id: "reasoning-\(idx)", providerMetadata: meta)
                    }
                }
                state.lifecycle = AIProtocolUtils.Lifecycle.finish(
                    state.lifecycle,
                    events: &events,
                    reason: state.pendingFinishReason ?? AIProtocolUtils.FinishReasonDetails(normalized: .unknown),
                    usage: state.usage,
                    providerMetadata: state.pendingFinishMetadata
                )
                return events

            case "error":
                let errObj = AIProtocolUtils.JSONCodec.objectValue(frame["error"])
                let type = AIProtocolUtils.JSONCodec.stringValue(errObj?["type"])
                let msg = AIProtocolUtils.JSONCodec.stringValue(errObj?["message"])
                let text: String
                if let type, let msg { text = "\(type): \(msg)" }
                else { text = msg ?? type ?? "Anthropic Messages stream error" }
                let kind: AIProtocolUtils.ProtocolErrorKind = (type == "rate_limit_error") ? .rateLimit : .providerInternal
                throw AIProtocolUtils.ProtocolError(kind: kind, message: text, route: adapterID, body: AIProtocolUtils.JSONCodec.encodeObject(frame))

            default:
                return []
            }
        }

        public struct StreamDecoder: IncrementalStreamDecoder, Sendable {
            private var sse = AIProtocolUtils.SSEParser()
            private var state: ParserState

            public init(request: AIProtocolUtils.LLMRequest) {
                self.state = ParserState(
                    provider: request.model.provider,
                    providerMetadataKey: request.model.providerMetadataKey ?? request.model.provider
                )
            }

            public mutating func feed(_ bytes: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                try process(sse.feed(bytes))
            }

            public mutating func finish() throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                try process(sse.finish())
            }

            private mutating func process(_ frames: [AIProtocolUtils.SSEFrame]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                var events: [AIProtocolUtils.LLMEvent] = []
                for frame in frames {
                    if let evName = frame.event, !sseEvents.contains(evName) { continue }
                    let trimmed = frame.data.trimmingASCIIWhitespace()
                    if trimmed.isEmpty || trimmed == ": keepalive" { continue }
                    let decoded = try AIProtocolUtils.ProviderShared.parseJson(
                        route: adapterID,
                        input: trimmed,
                        message: "Invalid Anthropic Messages SSE JSON"
                    )
                    guard let obj = AIProtocolUtils.JSONCodec.objectValue(decoded) else { continue }
                    events.append(contentsOf: try step(state: &state, event: obj))
                }
                return events
            }
        }

        public static func parseSSEStream(
            _ bytes: [UInt8],
            request: AIProtocolUtils.LLMRequest
        ) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            var decoder = StreamDecoder(request: request)
            return try decoder.feed(bytes) + decoder.finish()
        }

        // parity: ai/src/protocols/anthropic-messages.ts#protocol [status=implemented hash=82faa7844dc3]
        public static let `protocol` = ChatProtocolSpec(
            id: adapterID,
            framing: framing,
            buildBody: fromRequest,
            parseStream: parseSSEStream,
            makeStreamDecoder: { StreamDecoder(request: $0) }
        )

        // parity: ai/src/protocols/anthropic-messages.ts#transport [status=adapted hash=eee9218bbf22]
        public static func transportHeaders(
            for body: AnthropicMessagesBody,
            existing: [String: String] = [:]
        ) -> [String: String] {
            var headers = existing
            if !headers.keys.contains(where: { $0.lowercased() == "anthropic-version" }) {
                headers["anthropic-version"] = "2023-06-01"
            }
            var betas: [String] = []
            if let existingBeta = headers.first(where: { $0.key.lowercased() == "anthropic-beta" })?.value {
                betas.append(contentsOf: existingBeta.split(separator: ",").map { String($0).trimmingASCIIWhitespace() })
            }
            if body["context_management"] != nil && !betas.contains("compact-2026-01-12") {
                betas.append("compact-2026-01-12")
            }
            if let thinking = AIProtocolUtils.JSONCodec.objectValue(body["thinking"]),
               thinking["block_binding"] != nil,
               !betas.contains(AIProtocolUtils.ClaudeModel.THINKING_BINDING_BETA) {
                betas.append(AIProtocolUtils.ClaudeModel.THINKING_BINDING_BETA)
            }
            if !betas.isEmpty {
                headers["anthropic-beta"] = betas.joined(separator: ",")
            }
            return headers
        }

        // parity: ai/src/protocols/anthropic-messages.ts#route [status=implemented hash=6989278dd117]
        public static let route = ChatRouteSpec(
            id: adapterID,
            provider: "anthropic",
            providerMetadataKey: "anthropic",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH,
            defaultHeaders: ["anthropic-version": "2023-06-01"]
        )
    }

    // MARK: - OpenResponses (packages/ai/src/protocols/open-responses.ts — 56 symbols)

    public enum OpenResponses {
        public static let adapterID = "open-responses"
        public static let name = "Open Responses"

        // parity: ai/src/protocols/open-responses.ts#PATH [status=implemented hash=57ecae4492fe]
        public static let PATH = "/responses"

        // parity: ai/src/protocols/open-responses.ts#OpenResponsesInputText [status=implemented hash=f403147b73d0]
        public struct OpenResponsesInputText: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let text: String
            public init(text: String) { self.type = "input_text"; self.text = text }
            public var jsonValue: JSONValue { .object(["type": .string(type), "text": .string(text)]) }
        }

        // parity: ai/src/protocols/open-responses.ts#OpenResponsesInputImage [status=implemented hash=994b0ec481e5]
        public struct OpenResponsesInputImage: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let image_url: String
            public let detail: String?
            public init(image_url: String, detail: String? = nil) { self.type = "input_image"; self.image_url = image_url; self.detail = detail }
            public var jsonValue: JSONValue {
                var obj: [String: JSONValue] = ["type": .string(type), "image_url": .string(image_url)]
                if let detail { obj["detail"] = .string(detail) }
                return .object(obj)
            }
        }

        // parity: ai/src/protocols/open-responses.ts#OpenResponsesInputFile [status=implemented hash=8f31b6285430]
        public struct OpenResponsesInputFile: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let filename: String?
            public let detail: String?
            public let file_data: String?
            public let file_url: String?
            public init(filename: String? = nil, detail: String? = nil, file_data: String? = nil, file_url: String? = nil) {
                self.type = "input_file"; self.filename = filename; self.detail = detail; self.file_data = file_data; self.file_url = file_url
            }
            public var jsonValue: JSONValue {
                var obj: [String: JSONValue] = ["type": .string(type)]
                if let filename { obj["filename"] = .string(filename) }
                if let detail { obj["detail"] = .string(detail) }
                if let file_data { obj["file_data"] = .string(file_data) }
                if let file_url { obj["file_url"] = .string(file_url) }
                return .object(obj)
            }
        }

        // parity: ai/src/protocols/open-responses.ts#MediaInput [status=implemented hash=d9b3af91c0ae]
        public enum MediaInput: Equatable, Hashable, Sendable {
            case image(OpenResponsesInputImage)
            case file(OpenResponsesInputFile)
            case video(video_url: String)

            public var jsonValue: JSONValue {
                switch self {
                case .image(let img): return img.jsonValue
                case .file(let f): return f.jsonValue
                case .video(let u): return .object(["type": .string("input_video"), "video_url": .string(u)])
                }
            }
        }

        // parity: ai/src/protocols/open-responses.ts#OpenResponsesOutputText [status=implemented hash=eb5f7ba82162]
        public struct OpenResponsesOutputText: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let text: String
            public init(text: String) { self.type = "output_text"; self.text = text }
            public var jsonValue: JSONValue { .object(["type": .string(type), "text": .string(text)]) }
        }

        // parity: ai/src/protocols/open-responses.ts#MessagePhase [status=implemented hash=47e0cb52a18b]
        public enum MessagePhase: String, Equatable, Hashable, Sendable, Codable {
            case commentary
            case final_answer
        }

        // parity: ai/src/protocols/open-responses.ts#MessageMetadata [status=implemented hash=6caf671a1310]
        public struct MessageMetadata: Equatable, Hashable, Sendable, Codable {
            public let itemId: String?
            public let status: String?
            public let phase: MessagePhase?
            public init(itemId: String? = nil, status: String? = nil, phase: MessagePhase? = nil) {
                self.itemId = itemId; self.status = status; self.phase = phase
            }
        }

        // parity: ai/src/protocols/open-responses.ts#OpenResponsesReasoningItem [status=implemented hash=09f6e889871c]
        public struct OpenResponsesReasoningItem: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let id: String?
            public let summary: [String]
            public let encrypted_content: String?
            public init(id: String? = nil, summary: [String] = [], encrypted_content: String? = nil) {
                self.type = "reasoning"; self.id = id; self.summary = summary; self.encrypted_content = encrypted_content
            }
            public var jsonValue: JSONValue {
                var obj: [String: JSONValue] = [
                    "type": .string("reasoning"),
                    "summary": .array(summary.map { .object(["type": .string("summary_text"), "text": .string($0)]) }),
                ]
                if let id { obj["id"] = .string(id) }
                if let encrypted_content { obj["encrypted_content"] = .string(encrypted_content) }
                return .object(obj)
            }
        }

        // parity: ai/src/protocols/open-responses.ts#HostedToolItem [status=implemented hash=61408561403f]
        public typealias HostedToolItem = [String: JSONValue]

        // parity: ai/src/protocols/open-responses.ts#CompactionItem [status=implemented hash=f2b23aea7388]
        public struct CompactionItem: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let id: String?
            public let encrypted_content: String
            public init(id: String? = nil, encrypted_content: String) {
                self.type = "compaction"; self.id = id; self.encrypted_content = encrypted_content
            }
            public var jsonValue: JSONValue {
                var obj: [String: JSONValue] = ["type": .string("compaction"), "encrypted_content": .string(encrypted_content)]
                if let id { obj["id"] = .string(id) }
                return .object(obj)
            }
        }

        // parity: ai/src/protocols/open-responses.ts#ConfigurationUpdate [status=implemented hash=eafebb25789e]
        public struct ConfigurationUpdate: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let effort: String
            public init(effort: String) { self.type = "configuration_update"; self.effort = effort }
            public var jsonValue: JSONValue {
                .object(["type": .string(type), "reasoning": .object(["effort": .string(effort)])])
            }
        }

        // parity: ai/src/protocols/open-responses.ts#HostedToolReplay [status=implemented hash=7c9a70662bb7]
        public typealias HostedToolReplay = [String: JSONValue]

        // parity: ai/src/protocols/open-responses.ts#HostedToolReplayItem [status=implemented hash=16bb5161bf18]
        public typealias HostedToolReplayItem = [String: JSONValue]

        // parity: ai/src/protocols/open-responses.ts#Tool [status=implemented hash=27b0eeadc631]
        public typealias Tool = [String: JSONValue]

        // parity: ai/src/protocols/open-responses.ts#CustomTool [status=implemented hash=a1c461c58a84]
        public typealias CustomTool = [String: JSONValue]

        // parity: ai/src/protocols/open-responses.ts#HostedTool [status=implemented hash=5976e28d845f]
        public typealias HostedTool = [String: JSONValue]

        // parity: ai/src/protocols/open-responses.ts#AdditionalTools [status=implemented hash=17d699eb2054]
        public typealias AdditionalTools = [String: JSONValue]

        // parity: ai/src/protocols/open-responses.ts#InputItem [status=implemented hash=708c1ff0fbbf]
        public typealias InputItem = JSONValue

        // parity: ai/src/protocols/open-responses.ts#ToolChoice [status=implemented hash=37c2635ca59c]
        public typealias ToolChoice = JSONValue

        // parity: ai/src/protocols/open-responses.ts#coreFields [status=implemented hash=b4cde5e49298]
        public static let coreFields: [String] = [
            "model", "input", "instructions", "tools", "tool_choice", "store", "metadata",
            "safety_identifier", "stream_options", "top_logprobs", "truncation", "service_tier",
            "prompt_cache_key", "include", "reasoning", "text", "max_output_tokens",
            "max_tool_calls", "parallel_tool_calls", "temperature", "top_p",
            "presence_penalty", "frequency_penalty",
        ]

        // parity: ai/src/protocols/open-responses.ts#OpenResponsesBody [status=implemented hash=54020b508145]
        public typealias OpenResponsesBody = [String: JSONValue]

        // parity: ai/src/protocols/open-responses.ts#OpenResponsesUsage [status=implemented hash=d8fdfab35a3a]
        public typealias OpenResponsesUsage = [String: JSONValue]

        // parity: ai/src/protocols/open-responses.ts#StreamItem [status=implemented hash=66c508a3a764]
        public typealias StreamItem = [String: JSONValue]

        // parity: ai/src/protocols/open-responses.ts#OutputItem [status=implemented hash=2db57e87796e]
        public struct OutputItem: Equatable, Hashable, Sendable {
            public let id: String
            public let type: String
            public let raw: [String: JSONValue]

            public init(id: String, type: String, raw: [String: JSONValue]) {
                self.id = id
                self.type = type
                self.raw = raw
            }
        }

        // parity: ai/src/protocols/open-responses.ts#Event [status=implemented hash=973506a70e49]
        public typealias Event = [String: JSONValue]

        // parity: ai/src/protocols/open-responses.ts#NormalizedEvent [status=implemented hash=0005b2a60a5e]
        public struct NormalizedEvent: Equatable, Hashable, Sendable {
            public let type: String
            public let raw: [String: JSONValue]
            public let itemID: String?
            public let item: OutputItem?

            public init(type: String, raw: [String: JSONValue], itemID: String?, item: OutputItem?) {
                self.type = type
                self.raw = raw
                self.itemID = itemID
                self.item = item
            }
        }

        // parity: ai/src/protocols/open-responses.ts#decodeChannelEvent [status=implemented hash=0bcf38453ee0]
        public static func decodeChannelEvent(_ frame: String) throws(AIProtocolUtils.ProtocolError) -> Event {
            let value = try AIProtocolUtils.ProviderShared.parseJson(
                route: adapterID,
                input: frame,
                message: "Invalid Open Responses WebSocket event"
            )
            guard let obj = AIProtocolUtils.JSONCodec.objectValue(value) else {
                throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Open Responses event must be a JSON object", body: frame)
            }
            return AIProtocolUtils.ProviderShared.withUntypedFrames(obj)
        }

        // parity: ai/src/protocols/open-responses.ts#ProviderAdapter [status=implemented hash=a935ef7f88c5]
        public struct ProviderAdapter: Sendable {
            public let id: String
            public let name: String
            public let nativeTool: (@Sendable ([String: JSONValue]) throws(AIProtocolUtils.ProtocolError) -> HostedTool)?
            public let lowerMedia: (@Sendable (AIProtocolUtils.MediaPart, AIProtocolUtils.InlineMedia?, AIProtocolUtils.LLMRequest) -> MediaInput?)?
            public let restoreHostedToolItem: (@Sendable (JSONValue) -> HostedToolReplayItem?)?

            public init(
                id: String = adapterID,
                name: String = OpenResponses.name,
                nativeTool: (@Sendable ([String: JSONValue]) throws(AIProtocolUtils.ProtocolError) -> HostedTool)? = nil,
                lowerMedia: (@Sendable (AIProtocolUtils.MediaPart, AIProtocolUtils.InlineMedia?, AIProtocolUtils.LLMRequest) -> MediaInput?)? = nil,
                restoreHostedToolItem: (@Sendable (JSONValue) -> HostedToolReplayItem?)? = nil
            ) {
                self.id = id
                self.name = name
                self.nativeTool = nativeTool
                self.lowerMedia = lowerMedia
                self.restoreHostedToolItem = restoreHostedToolItem
            }

            public static let base = ProviderAdapter()
        }

        public struct ReasoningStreamItem: Equatable, Hashable, Sendable {
            public var encryptedContent: String?
            public var summaryParts: [Int: String] // "active" | "can-conclude" | "concluded"
            public var deltaIndexes: Set<Int>

            public init(encryptedContent: String? = nil, summaryParts: [Int: String] = [0: "active"], deltaIndexes: Set<Int> = []) {
                self.encryptedContent = encryptedContent
                self.summaryParts = summaryParts
                self.deltaIndexes = deltaIndexes
            }
        }

        // parity: ai/src/protocols/open-responses.ts#ParserState [status=implemented hash=9f00f141bc73]
        public struct ParserState: Equatable, Sendable {
            public let provider: String
            public var completedCompactions: Set<String>
            public let id: String
            public let name: String
            public let providerMetadataKey: String
            public var tools: AIProtocolUtils.ToolStream.State<String>
            public let custom: [String: OpenAIFreeform.Custom]
            public var hasFunctionCall: Bool
            public var lifecycle: AIProtocolUtils.Lifecycle.State
            public var outputItems: [Int: String]
            public var messageID: String?
            public var messagePhase: MessagePhase?
            public var reasoningItems: [String: ReasoningStreamItem]

            public init(
                provider: String,
                id: String,
                name: String,
                providerMetadataKey: String,
                custom: [String: OpenAIFreeform.Custom] = [:]
            ) {
                self.provider = provider
                self.completedCompactions = []
                self.id = id
                self.name = name
                self.providerMetadataKey = providerMetadataKey
                self.tools = AIProtocolUtils.ToolStream.empty()
                self.custom = custom
                self.hasFunctionCall = false
                self.lifecycle = AIProtocolUtils.Lifecycle.initial()
                self.outputItems = [:]
                self.messageID = nil
                self.messagePhase = nil
                self.reasoningItems = [:]
            }
        }

        // parity: ai/src/protocols/open-responses.ts#lowerTool [status=implemented hash=defeac592024]
        public static func lowerTool(
            protocolName: String,
            tool: AIProtocolUtils.ToolDefinition
        ) throws(AIProtocolUtils.ProtocolError) -> Tool {
            if tool.native != nil {
                throw AIProtocolUtils.ProviderShared.invalidRequest("\(protocolName) does not support provider-native tool \(tool.name)")
            }
            return [
                "type": .string("function"),
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": .object(tool.inputSchema),
                "strict": .bool(false),
            ]
        }

        // parity: ai/src/protocols/open-responses.ts#lowerCustomTool [status=implemented hash=eacd5e9b1175]
        public static func lowerCustomTool(
            tool: AIProtocolUtils.ToolDefinition,
            custom: OpenAIFreeform.Custom
        ) -> CustomTool {
            let format: JSONValue
            if let g = OpenAIFreeform.grammar(custom.format) {
                format = .object(["type": .string("grammar"), "syntax": .string(g.syntax), "definition": .string(g.definition)])
            } else {
                format = .object(["type": .string("text")])
            }
            return [
                "type": .string("custom"),
                "name": .string(tool.name),
                "description": .string(tool.description),
                "format": format,
            ]
        }

        // parity: ai/src/protocols/open-responses.ts#lowerTools [status=implemented hash=c4342efc909d]
        public static func lowerTools(
            _ tools: [AIProtocolUtils.ToolDefinition],
            adapter: ProviderAdapter,
            custom: [String: OpenAIFreeform.Custom]
        ) throws(AIProtocolUtils.ProtocolError) -> [JSONValue] {
            var out: [JSONValue] = []
            for tool in tools {
                if let native = tool.native, let lowerNative = adapter.nativeTool {
                    out.append(.object(try lowerNative(native)))
                } else if let c = custom[tool.name] {
                    out.append(.object(lowerCustomTool(tool: tool, custom: c)))
                } else {
                    out.append(.object(try lowerTool(protocolName: adapter.name, tool: tool)))
                }
            }
            return out
        }

        // parity: ai/src/protocols/open-responses.ts#namedTool [status=implemented hash=c39996cabe26]
        public static func namedTool(_ name: String, custom: [String: OpenAIFreeform.Custom]) -> JSONValue {
            .object(["type": .string(custom[name] != nil ? "custom" : "function"), "name": .string(name)])
        }

        // parity: ai/src/protocols/open-responses.ts#lowerToolChoice [status=implemented hash=1ae87881743a]
        public static func lowerToolChoice(
            protocolName: String,
            toolChoice: AIProtocolUtils.ToolChoice,
            custom: [String: OpenAIFreeform.Custom]
        ) throws(AIProtocolUtils.ProtocolError) -> ToolChoice {
            try AIProtocolUtils.ProviderShared.matchToolChoice(
                route: protocolName,
                toolChoice: toolChoice,
                auto: { .string("auto") },
                none: { .string("none") },
                required: { .string("required") },
                tool: { name in namedTool(name, custom: custom) }
            )
        }

        private static func itemID(_ metadata: AIProtocolUtils.ProviderMetadata?, key: String) -> String? {
            guard let id = AIProtocolUtils.JSONCodec.stringValue(metadata?[key]?["itemId"]),
                  let underscore = id.firstIndex(of: "_"),
                  underscore > id.startIndex,
                  id.index(after: underscore) < id.endIndex else {
                return nil
            }
            return id
        }

        private static func lowerMediaPart(
            _ part: AIProtocolUtils.MediaPart,
            request: AIProtocolUtils.LLMRequest,
            adapter: ProviderAdapter
        ) throws(AIProtocolUtils.ProtocolError) -> MediaInput {
            let inline = part.media.inline()
            if let custom = adapter.lowerMedia?(part, inline, request) { return custom }
            let detail = AIProtocolUtils.JSONCodec.stringValue(part.providerMetadata?[metadataKey(request.model)]?["detail"])
            let url = AIProtocolUtils.ProviderShared.mediaUrl(part.media)
            let location: String
            if let url {
                location = url
            } else {
                location = try AIProtocolUtils.ProviderShared.requireInlineMedia(route: adapter.name, asset: part.media).dataUrl
            }
            if part.media.kind == .image {
                return .image(OpenResponsesInputImage(image_url: location, detail: detail))
            }
            if part.media.kind == .video {
                return .video(video_url: location)
            }
            if let url {
                return .file(OpenResponsesInputFile(detail: detail, file_url: url))
            }
            let defaultName = part.media.mediaType.lowercased() == "application/pdf" ? "document.pdf" : "file"
            return .file(OpenResponsesInputFile(filename: part.filename ?? defaultName, detail: detail, file_data: location))
        }

        // parity: ai/src/protocols/open-responses.ts#lowerMessages [status=implemented hash=84982f1a98b5]
        public static func lowerMessages(
            _ request: AIProtocolUtils.LLMRequest,
            adapter: ProviderAdapter = .base
        ) throws(AIProtocolUtils.ProtocolError) -> [InputItem] {
            var input: [InputItem] = []
            let metaKey = metadataKey(request.model)
            let custom = OpenAIFreeform.tools(request)

            for message in request.messages {
                switch message.role {
                case .system:
                    let textParts = try AIProtocolUtils.ProviderShared.systemUpdateText(route: adapter.name, message: message)
                    input.append(.object([
                        "type": .string("message"),
                        "role": .string("developer"),
                        "content": .string(AIProtocolUtils.ProviderShared.joinText(textParts)),
                    ]))

                case .user:
                    var content: [JSONValue] = []
                    for part in message.content {
                        switch part {
                        case .text(let tp):
                            content.append(OpenResponsesInputText(text: tp.text).jsonValue)
                        case .media(let mp):
                            content.append(try lowerMediaPart(mp, request: request, adapter: adapter).jsonValue)
                        default:
                            break
                        }
                    }
                    if !content.isEmpty {
                        var obj: [String: JSONValue] = [
                            "type": .string("message"),
                            "role": .string("user"),
                            "content": .array(content),
                        ]
                        if let id = itemID(message.providerMetadata, key: metaKey) { obj["id"] = .string(id) }
                        input.append(.object(obj))
                    }

                case .assistant:
                    var textParts: [AIProtocolUtils.TextPart] = []
                    func flushText() {
                        guard !textParts.isEmpty else { return }
                        var obj: [String: JSONValue] = [
                            "type": .string("message"),
                            "role": .string("assistant"),
                            "status": .string("completed"),
                            "content": .array(textParts.map { OpenResponsesOutputText(text: $0.text).jsonValue }),
                        ]
                        if let id = itemID(textParts.first?.providerMetadata, key: metaKey) ?? itemID(message.providerMetadata, key: metaKey) {
                            obj["id"] = .string(id)
                        }
                        if let phase = AIProtocolUtils.JSONCodec.stringValue(textParts.first?.providerMetadata?[metaKey]?["phase"])
                            ?? AIProtocolUtils.JSONCodec.stringValue(message.providerMetadata?[metaKey]?["phase"]) {
                            obj["phase"] = .string(phase)
                        }
                        input.append(.object(obj))
                        textParts.removeAll()
                    }
                    for part in message.content {
                        switch part {
                        case .compaction(let cp):
                            flushText()
                            guard cp.provider == request.model.provider, let enc = cp.encrypted else {
                                throw AIProtocolUtils.ProviderShared.invalidRequest("Compaction state must be replayed to its originating provider and API")
                            }
                            input.append(CompactionItem(id: cp.id, encrypted_content: enc).jsonValue)
                        case .text(let tp):
                            textParts.append(tp)
                        case .reasoning(let rp):
                            flushText()
                            let id = itemID(rp.providerMetadata, key: metaKey)
                            let enc = rp.encrypted ?? AIProtocolUtils.JSONCodec.stringValue(rp.providerMetadata?[metaKey]?["reasoningEncryptedContent"])
                            if rp.text.isEmpty && enc == nil { continue }
                            input.append(OpenResponsesReasoningItem(
                                id: id,
                                summary: rp.text.isEmpty ? [] : [rp.text],
                                encrypted_content: enc
                            ).jsonValue)
                        case .toolCall(let tc):
                            flushText()
                            if tc.providerExecuted == true { continue }
                            let c = tc.namespace == nil ? custom[tc.name] : nil
                            let keptID = OpenAIFreeform.keepsItemID(providerMetadata: tc.providerMetadata, key: metaKey, custom: c != nil)
                                ? itemID(tc.providerMetadata, key: metaKey)
                                : nil
                            if let c {
                                var obj: [String: JSONValue] = [
                                    "type": .string("custom_tool_call"),
                                    "call_id": .string(tc.id),
                                    "name": .string(tc.name),
                                    "input": .string(OpenAIFreeform.toRaw(c, input: tc.input)),
                                ]
                                if let keptID { obj["id"] = .string(keptID) }
                                input.append(.object(obj))
                            } else {
                                var obj: [String: JSONValue] = [
                                    "type": .string("function_call"),
                                    "call_id": .string(tc.id),
                                    "name": .string(tc.name),
                                    "arguments": .string(AIProtocolUtils.JSONCodec.encode(tc.input)),
                                ]
                                if let keptID { obj["id"] = .string(keptID) }
                                if let ns = tc.namespace { obj["namespace"] = .string(ns) }
                                input.append(.object(obj))
                            }
                        case .toolResult(let tr) where tr.providerExecuted == true:
                            flushText()
                            if case .json(let val) = tr.result,
                               let restored = adapter.restoreHostedToolItem?(val) {
                                input.append(.object(restored))
                            } else {
                                input.append(.object([
                                    "type": .string("message"),
                                    "role": .string("user"),
                                    "content": .array([OpenResponsesInputText(text: AIProtocolUtils.ProviderShared.toolResultText(tr)).jsonValue]),
                                ]))
                            }
                        case .media(let mp):
                            flushText()
                            let lowered = try lowerMediaPart(mp, request: request, adapter: adapter)
                            input.append(.object([
                                "type": .string("message"),
                                "role": .string("user"),
                                "content": .array([lowered.jsonValue]),
                            ]))
                        default:
                            throw AIProtocolUtils.ProviderShared.unsupportedContent(
                                route: adapter.name,
                                role: .assistant,
                                types: ["text", "reasoning", "tool-call", "tool-result", "media"]
                            )
                        }
                    }
                    flushText()

                case .tool:
                    for part in message.content {
                        guard case .toolResult(let tr) = part else { continue }
                        let isCustom = tr.namespace == nil && custom[tr.name] != nil
                        let output: JSONValue
                        if case .content(let items) = tr.result {
                            var outItems: [JSONValue] = []
                            for item in items {
                                switch item {
                                case .text(let t): outItems.append(OpenResponsesInputText(text: t).jsonValue)
                                case .file(let f):
                                    outItems.append(try lowerMediaPart(AIProtocolUtils.ProviderShared.toolFileMedia(f), request: request, adapter: adapter).jsonValue)
                                }
                            }
                            output = .array(outItems)
                        } else {
                            output = .string(AIProtocolUtils.ProviderShared.toolResultText(tr))
                        }
                        input.append(.object([
                            "type": .string(isCustom ? "custom_tool_call_output" : "function_call_output"),
                            "call_id": .string(tr.id),
                            "output": output,
                        ]))
                    }
                }
            }
            return input
        }

        // parity: ai/src/protocols/open-responses.ts#lowerConversation [status=implemented hash=ed260ddee544]
        public static func lowerConversation(
            _ request: AIProtocolUtils.LLMRequest,
            adapter: ProviderAdapter = .base
        ) throws(AIProtocolUtils.ProtocolError) -> (model: String, input: [InputItem]) {
            let system = AIProtocolUtils.ProviderShared.joinText(request.system)
            var input: [InputItem] = []
            if !system.isEmpty {
                input.append(.object([
                    "type": .string("message"),
                    "role": .string("developer"),
                    "content": .string(system),
                ]))
            }
            input.append(contentsOf: try lowerMessages(request, adapter: adapter))
            return (model: request.model.id, input: input)
        }

        // parity: ai/src/protocols/open-responses.ts#resolveParallelToolCalls [status=implemented hash=dcba44686b35]
        public static func resolveParallelToolCalls(
            _ request: AIProtocolUtils.LLMRequest,
            options: AIProtocolUtils.OpenResponsesOptions.Resolved? = nil
        ) -> Bool? {
            let resolved = options ?? AIProtocolUtils.OpenResponsesOptions.resolve(request)
            if let configured = resolved.options.parallelToolCalls { return configured }
            guard let disabled = request.toolChoice?.disableParallelToolUse else { return nil }
            return !disabled
        }

        // parity: ai/src/protocols/open-responses.ts#lowerGeneration [status=implemented hash=97ef5b39b2c6]
        public static func lowerGeneration(
            _ request: AIProtocolUtils.LLMRequest,
            options: AIProtocolUtils.OpenResponsesOptions.Resolved? = nil
        ) -> [String: JSONValue] {
            let resolved = options ?? AIProtocolUtils.OpenResponsesOptions.resolve(request)
            let opts = resolved.options
            var body: [String: JSONValue] = ["stream": .bool(true)]
            if let maxT = request.maxTokens { body["max_output_tokens"] = .int(Int64(maxT)) }
            if let temp = request.temperature { body["temperature"] = .double(temp) }
            if let topP = request.topP { body["top_p"] = .double(topP) }
            if let pp = request.presencePenalty { body["presence_penalty"] = .double(pp) }
            if let fp = request.frequencyPenalty { body["frequency_penalty"] = .double(fp) }
            if let store = opts.store { body["store"] = .bool(store) }
            if let metadata = opts.metadata { body["metadata"] = .object(metadata.mapValues(JSONValue.string)) }
            if let safety = opts.safetyIdentifier { body["safety_identifier"] = .string(safety) }
            if let incObf = opts.streamOptions?.includeObfuscation {
                body["stream_options"] = .object(["include_obfuscation": .bool(incObf)])
            }
            if let topLogprobs = opts.topLogprobs { body["top_logprobs"] = .int(Int64(topLogprobs)) }
            if let cacheKey = AIProtocolUtils.ProviderShared.promptCacheKey(request) { body["prompt_cache_key"] = .string(cacheKey) }
            if let include = opts.include { body["include"] = .array(include.map(JSONValue.string)) }
            if opts.reasoningEffort != nil || opts.reasoningSummary != nil {
                var r: [String: JSONValue] = [:]
                if let e = opts.reasoningEffort { r["effort"] = .string(e) }
                if let s = opts.reasoningSummary { r["summary"] = .string(s) }
                body["reasoning"] = .object(r)
            }
            if let verbosity = opts.textVerbosity { body["text"] = .object(["verbosity": .string(verbosity)]) }
            if let tier = opts.serviceTier { body["service_tier"] = .string(tier) }
            if let maxCalls = opts.maxToolCalls { body["max_tool_calls"] = .int(Int64(maxCalls)) }
            if let parallel = resolveParallelToolCalls(request, options: resolved) { body["parallel_tool_calls"] = .bool(parallel) }
            if let trunc = opts.truncation { body["truncation"] = .string(trunc.rawValue) }
            return body
        }

        // parity: ai/src/protocols/open-responses.ts#allowedToolChoice [status=implemented hash=15fc2f63ca2d]
        public static func allowedToolChoice(
            _ options: AIProtocolUtils.OpenResponsesOptions.Resolved,
            custom: [String: OpenAIFreeform.Custom]
        ) -> ToolChoice? {
            guard let allowed = options.resolvedAllowedTools else { return nil }
            return .object([
                "type": .string("allowed_tools"),
                "mode": .string(allowed.mode),
                "tools": .array(allowed.toolNames.map { namedTool($0, custom: custom) }),
            ])
        }

        // parity: ai/src/protocols/open-responses.ts#fromRequestWithAdapter [status=implemented hash=23cf032e495d]
        public static func fromRequestWithAdapter(
            _ request: AIProtocolUtils.LLMRequest,
            adapter: ProviderAdapter
        ) throws(AIProtocolUtils.ProtocolError) -> OpenResponsesBody {
            let projected = AIProtocolUtils.ProviderShared.flattenToolRequest(request)
            let options = AIProtocolUtils.OpenResponsesOptions.resolve(request)
            let custom = OpenAIFreeform.tools(request)
            let conv = try lowerConversation(projected.request, adapter: adapter)
            var body = lowerGeneration(request, options: options)
            body["model"] = .string(conv.model)
            body["input"] = .array(conv.input)
            if !projected.tools.isEmpty {
                body["tools"] = .array(try lowerTools(projected.tools, adapter: adapter, custom: custom))
            }
            if let allowed = allowedToolChoice(options, custom: custom) {
                body["tool_choice"] = allowed
            } else if let tc = request.toolChoice {
                body["tool_choice"] = try lowerToolChoice(protocolName: adapter.name, toolChoice: tc, custom: custom)
            }
            return body
        }

        // parity: ai/src/protocols/open-responses.ts#fromRequest [status=implemented hash=606b3c559e1b]
        public static func fromRequest(_ request: AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> OpenResponsesBody {
            try fromRequestWithAdapter(request, adapter: .base)
        }

        // parity: ai/src/protocols/open-responses.ts#mapUsage [status=implemented hash=d4a478341410]
        public static func mapUsage(
            _ usageVal: JSONValue?,
            providerMetadataKey: String,
            frames: [JSONValue] = []
        ) -> AIProtocolUtils.Usage? {
            guard let u = AIProtocolUtils.JSONCodec.objectValue(usageVal) else { return nil }
            let inputTokens = AIProtocolUtils.JSONCodec.doubleValue(u["input_tokens"])
            let outputTokens = AIProtocolUtils.JSONCodec.doubleValue(u["output_tokens"])
            let inputDetails = AIProtocolUtils.JSONCodec.objectValue(u["input_tokens_details"])
            let outputDetails = AIProtocolUtils.JSONCodec.objectValue(u["output_tokens_details"])
            let cached = AIProtocolUtils.JSONCodec.doubleValue(inputDetails?["cached_tokens"])
            let cacheWrite = AIProtocolUtils.JSONCodec.doubleValue(inputDetails?["cache_write_tokens"])
            let reasoning = AIProtocolUtils.JSONCodec.doubleValue(outputDetails?["reasoning_tokens"])
            let nonCached = AIProtocolUtils.ProviderShared.subtractTokens(
                inputTokens,
                AIProtocolUtils.ProviderShared.sumTokens(cached, cacheWrite)
            )
            let billing = AIProtocolUtils.ProviderShared.reportedBilling(usage: usageVal, frames: frames)
            return AIProtocolUtils.Usage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                nonCachedInputTokens: nonCached,
                cacheReadInputTokens: cached,
                cacheWriteInputTokens: cacheWrite,
                reasoningTokens: reasoning,
                totalTokens: AIProtocolUtils.ProviderShared.totalTokens(inputTokens, outputTokens, AIProtocolUtils.JSONCodec.doubleValue(u["total_tokens"])),
                cost: billing.cost,
                providerMetadata: [providerMetadataKey: u]
            )
        }

        // parity: ai/src/protocols/open-responses.ts#metadataKey [status=implemented hash=8617dcbb3138]
        public static func metadataKey(_ model: AIProtocolUtils.ModelDescriptor) -> String {
            model.providerMetadataKey ?? "openresponses"
        }

        // parity: ai/src/protocols/open-responses.ts#providerMetadata [status=implemented hash=1069ac85b5b6]
        public static func providerMetadata(_ state: ParserState, metadata: [String: JSONValue]) -> AIProtocolUtils.ProviderMetadata {
            [state.providerMetadataKey: metadata]
        }

        // parity: ai/src/protocols/open-responses.ts#StepResult [status=implemented hash=d22dce597029]
        public typealias StepResult = (ParserState, [AIProtocolUtils.LLMEvent])

        private static let terminalTypes: Set<String> = [
            "error", "response.completed", "response.incomplete", "response.failed",
        ]

        // parity: ai/src/protocols/open-responses.ts#terminal [status=implemented hash=e6617d45179b]
        public static func terminal(_ event: Event) -> Bool {
            terminalTypes.contains(AIProtocolUtils.JSONCodec.stringValue(event["type"]) ?? "")
        }

        private static let itemIDPrefix: [String: String] = [
            "message": "msg", "reasoning": "rs", "function_call": "fc", "custom_tool_call": "ctc", "compaction": "cmp",
        ]

        private static func resolveItem(_ outputItems: [Int: String], item: [String: JSONValue], index: Int?) -> OutputItem {
            let type = AIProtocolUtils.JSONCodec.stringValue(item["type"]) ?? ""
            let id = (index.flatMap { outputItems[$0] })
                ?? AIProtocolUtils.JSONCodec.stringValue(item["id"])
                ?? AIProtocolUtils.JSONCodec.stringValue(item["item_id"])
                ?? "\(itemIDPrefix[type] ?? "item")_\(uuid().replacingOccurrences(of: "-", with: ""))"
            var raw = item
            raw["id"] = .string(id)
            return OutputItem(id: id, type: type, raw: raw)
        }

        // parity: ai/src/protocols/open-responses.ts#normalize [status=implemented hash=6f8dbe6844ae]
        public static func normalize(_ state: ParserState, input: Event) -> NormalizedEvent {
            let framed = AIProtocolUtils.ProviderShared.withUntypedFrames(input)
            let type = AIProtocolUtils.JSONCodec.stringValue(framed["type"]) ?? ""
            let outputIndex = AIProtocolUtils.JSONCodec.intValue(framed["output_index"])
            let rawItemID = AIProtocolUtils.JSONCodec.stringValue(framed["item_id"])
            let resolvedItemID = outputIndex.flatMap { state.outputItems[$0] } ?? rawItemID
            let resolvedItem = AIProtocolUtils.JSONCodec.objectValue(framed["item"]).map {
                resolveItem(state.outputItems, item: $0, index: outputIndex)
            }
            return NormalizedEvent(type: type, raw: framed, itemID: resolvedItemID, item: resolvedItem)
        }

        // parity: ai/src/protocols/open-responses.ts#onReasoningDelta [status=implemented hash=3e0ee890e469]
        public static func onReasoningDelta(_ state: ParserState, event: Event, itemID: String) -> StepResult {
            guard var item = state.reasoningItems[itemID],
                  let delta = AIProtocolUtils.JSONCodec.stringValue(event["delta"]), !delta.isEmpty else {
                return (state, [])
            }
            let idx = AIProtocolUtils.JSONCodec.intValue(event["summary_index"]) ?? 0
            if item.summaryParts[idx] == "concluded" { return (state, []) }
            var next = state
            var events: [AIProtocolUtils.LLMEvent] = []
            if idx != 0 && item.summaryParts[idx] == nil {
                for (k, status) in item.summaryParts where status != "concluded" {
                    next.lifecycle = AIProtocolUtils.Lifecycle.reasoningEnd(
                        next.lifecycle,
                        events: &events,
                        id: "\(itemID):\(k)",
                        providerMetadata: providerMetadata(state, metadata: ["itemId": .string(itemID)])
                    )
                    item.summaryParts[k] = "concluded"
                }
                next.lifecycle = AIProtocolUtils.Lifecycle.reasoningStart(
                    next.lifecycle,
                    events: &events,
                    id: "\(itemID):\(idx)",
                    providerMetadata: providerMetadata(state, metadata: [
                        "itemId": .string(itemID),
                        "reasoningEncryptedContent": item.encryptedContent.map(JSONValue.string) ?? .null,
                    ])
                )
                item.summaryParts[idx] = "active"
            }
            next.lifecycle = AIProtocolUtils.Lifecycle.reasoningDelta(next.lifecycle, events: &events, id: "\(itemID):\(idx)", text: delta)
            item.deltaIndexes.insert(idx)
            next.reasoningItems[itemID] = item
            return (next, events)
        }

        // parity: ai/src/protocols/open-responses.ts#onReasoningDone [status=implemented hash=e1c7dfedf388]
        public static func onReasoningDone(_ state: ParserState, event: Event, itemID: String) -> StepResult {
            guard let item = state.reasoningItems[itemID],
                  let text = AIProtocolUtils.JSONCodec.stringValue(event["text"]) else {
                return (state, [])
            }
            let idx = AIProtocolUtils.JSONCodec.intValue(event["summary_index"]) ?? 0
            if item.deltaIndexes.contains(idx) { return (state, []) }
            var synthetic = event
            synthetic["delta"] = .string(text)
            return onReasoningDelta(state, event: synthetic, itemID: itemID)
        }

        private static func asText(_ value: JSONValue?) -> String? {
            switch value {
            case .string(let s) where !s.isEmpty: return s
            case .int(let i): return String(i)
            case .double(let d) where d.isFinite: return String(d)
            default: return nil
            }
        }

        // parity: ai/src/protocols/open-responses.ts#errorDetail [status=implemented hash=b3204f256bfb]
        public static func errorDetail(_ event: Event) -> (message: String?, code: String?) {
            let raw = event["error"] ?? AIProtocolUtils.JSONCodec.objectValue(event["response"])?["error"]
            let nested: [String: JSONValue]?
            if case .string(let s) = raw {
                nested = ["message": .string(s)]
            } else {
                nested = AIProtocolUtils.JSONCodec.objectValue(raw)
            }
            return (
                message: asText(event["message"]) ?? asText(nested?["message"]),
                code: asText(event["code"]) ?? asText(nested?["code"])
            )
        }

        // parity: ai/src/protocols/open-responses.ts#providerFailure [status=implemented hash=1b0160df229f]
        public static func providerFailure(
            _ event: Event,
            fallback: String,
            body: String? = nil
        ) -> AIProtocolUtils.ProtocolError {
            let bodyText = body ?? AIProtocolUtils.JSONCodec.encodeObject(event)
            let detail = errorDetail(event)
            let summary: String?
            if let m = detail.message, let c = detail.code { summary = "\(c): \(m)" }
            else { summary = detail.message ?? detail.code }
            let message = summary ?? (bodyText == "{}" ? fallback : bodyText)
            let status = AIProtocolUtils.JSONCodec.intValue(event["status"]) ?? AIProtocolUtils.JSONCodec.intValue(event["status_code"])
            let kind: AIProtocolUtils.ProtocolErrorKind
            if status == 429 || detail.code?.contains("rate_limit") == true {
                kind = .rateLimit
            } else if status == 401 || status == 403 {
                kind = .authentication
            } else if status == 400 {
                kind = .invalidRequest
            } else {
                kind = .providerInternal
            }
            return AIProtocolUtils.ProtocolError(kind: kind, message: message, route: adapterID, statusCode: status, body: bodyText)
        }

        // parity: ai/src/protocols/open-responses.ts#step [status=implemented hash=02d6d46ddc51]
        public static func step(
            _ state: ParserState,
            event: NormalizedEvent
        ) throws(AIProtocolUtils.ProtocolError) -> StepResult {
            var next = state
            let raw = event.raw
            if let idx = AIProtocolUtils.JSONCodec.intValue(raw["output_index"]), let item = event.item {
                next.outputItems[idx] = item.id
            }

            switch event.type {
            case "error":
                throw providerFailure(raw, fallback: "\(state.name) stream error")
            case "response.failed":
                throw providerFailure(raw, fallback: "\(state.name) response failed")

            case "response.output_item.added":
                guard let item = event.item else { return (next, []) }
                if item.type == "message" {
                    var events: [AIProtocolUtils.LLMEvent] = []
                    for openID in next.lifecycle.textOrder where openID != item.id {
                        next.lifecycle = AIProtocolUtils.Lifecycle.textEnd(next.lifecycle, events: &events, id: openID)
                    }
                    next.messageID = item.id
                    next.messagePhase = AIProtocolUtils.JSONCodec.stringValue(item.raw["phase"]).flatMap(MessagePhase.init(rawValue:))
                    return (next, events)
                }
                if item.type == "reasoning" {
                    if next.reasoningItems[item.id] != nil { return (next, []) }
                    var events: [AIProtocolUtils.LLMEvent] = []
                    let enc = AIProtocolUtils.JSONCodec.stringValue(item.raw["encrypted_content"])
                    let meta = providerMetadata(next, metadata: [
                        "itemId": .string(item.id),
                        "reasoningEncryptedContent": enc.map(JSONValue.string) ?? .null,
                    ])
                    next.lifecycle = AIProtocolUtils.Lifecycle.reasoningStart(next.lifecycle, events: &events, id: "\(item.id):0", providerMetadata: meta)
                    next.reasoningItems[item.id] = ReasoningStreamItem(encryptedContent: enc)
                    return (next, events)
                }
                if (item.type == "function_call" || item.type == "custom_tool_call"),
                   let callID = AIProtocolUtils.JSONCodec.stringValue(item.raw["call_id"]) {
                    if next.tools[item.id] != nil { return (next, []) }
                    let isCustom = item.type == "custom_tool_call"
                    let toolName = AIProtocolUtils.JSONCodec.stringValue(item.raw["name"]) ?? ""
                    let ns = AIProtocolUtils.JSONCodec.stringValue(item.raw["namespace"])
                    let meta = providerMetadata(next, metadata: OpenAIFreeform.metadata(itemId: item.id, custom: isCustom))
                    var events: [AIProtocolUtils.LLMEvent] = []
                    next.lifecycle = AIProtocolUtils.Lifecycle.stepStart(next.lifecycle, events: &events)
                    let initialArgs = isCustom ? "" : (AIProtocolUtils.JSONCodec.stringValue(item.raw["arguments"]) ?? "")
                    next.tools = AIProtocolUtils.ToolStream.start(
                        next.tools,
                        key: item.id,
                        tool: AIProtocolUtils.ToolStream.PendingTool(id: callID, name: toolName, namespace: ns, input: initialArgs, providerMetadata: meta)
                    )
                    events.append(.toolInputStart(id: callID, name: toolName, namespace: ns, providerMetadata: meta))
                    if isCustom {
                        let rawIn = AIProtocolUtils.JSONCodec.stringValue(item.raw["input"]) ?? ""
                        if let opened = AIProtocolUtils.ToolStream.append(next.tools, key: item.id, text: OpenAIFreeform.streamStart(next.custom[toolName], raw: rawIn)) {
                            next.tools = opened.tools
                            events.append(contentsOf: opened.events)
                        }
                    }
                    return (next, events)
                }
                return (next, [])

            case "response.output_text.delta", "response.refusal.delta":
                guard let id = event.itemID, next.messageID == id,
                      let delta = AIProtocolUtils.JSONCodec.stringValue(raw["delta"]), !delta.isEmpty else {
                    return (next, [])
                }
                var events: [AIProtocolUtils.LLMEvent] = []
                var metaFields: [String: JSONValue] = ["itemId": .string(id)]
                if let p = next.messagePhase { metaFields["phase"] = .string(p.rawValue) }
                next.lifecycle = AIProtocolUtils.Lifecycle.textStart(next.lifecycle, events: &events, id: id, providerMetadata: providerMetadata(next, metadata: metaFields))
                next.lifecycle = AIProtocolUtils.Lifecycle.textDelta(next.lifecycle, events: &events, id: id, text: delta)
                return (next, events)

            case "response.output_text.done":
                guard let id = event.itemID else { return (next, []) }
                if next.messageID == id {
                    if !next.lifecycle.text.contains(id), let text = AIProtocolUtils.JSONCodec.stringValue(raw["text"]), !text.isEmpty {
                        var events: [AIProtocolUtils.LLMEvent] = []
                        next.lifecycle = AIProtocolUtils.Lifecycle.textDelta(next.lifecycle, events: &events, id: id, text: text)
                        return (next, events)
                    }
                    return (next, [])
                }
                var events: [AIProtocolUtils.LLMEvent] = []
                next.lifecycle = AIProtocolUtils.Lifecycle.textEnd(next.lifecycle, events: &events, id: id)
                return (next, events)

            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                guard let id = event.itemID else { return (next, []) }
                return onReasoningDelta(next, event: raw, itemID: id)

            case "response.reasoning_summary_text.done", "response.reasoning_text.done":
                guard let id = event.itemID else { return (next, []) }
                return onReasoningDone(next, event: raw, itemID: id)

            case "response.function_call_arguments.delta", "response.function_call_arguments.done":
                guard let id = event.itemID, let tool = next.tools[id] else { return (next, []) }
                let delta: String
                if event.type == "response.function_call_arguments.done" {
                    guard let finalArgs = AIProtocolUtils.JSONCodec.stringValue(raw["arguments"]) else { return (next, []) }
                    if !finalArgs.hasPrefix(tool.input) {
                        next.tools = AIProtocolUtils.ToolStream.start(
                            next.tools,
                            key: id,
                            tool: AIProtocolUtils.ToolStream.PendingTool(
                                id: tool.id, name: tool.name, namespace: tool.namespace,
                                input: finalArgs, providerExecuted: tool.providerExecuted, providerMetadata: tool.providerMetadata
                            )
                        )
                        return (next, [])
                    }
                    delta = String(finalArgs.dropFirst(tool.input.count))
                } else {
                    delta = AIProtocolUtils.JSONCodec.stringValue(raw["delta"]) ?? ""
                }
                guard !delta.isEmpty else { return (next, []) }
                let res = AIProtocolUtils.ToolStream.appendExisting(
                    route: next.id,
                    tools: next.tools,
                    key: id,
                    text: delta,
                    missingToolMessage: "\(next.name) tool argument delta is missing its tool call"
                )
                switch res {
                case .error(let err): throw err
                case .ok(let outcome):
                    next.tools = outcome.tools
                    var events: [AIProtocolUtils.LLMEvent] = []
                    if !outcome.events.isEmpty {
                        next.lifecycle = AIProtocolUtils.Lifecycle.stepStart(next.lifecycle, events: &events)
                    }
                    events.append(contentsOf: outcome.events)
                    return (next, events)
                }

            case "response.custom_tool_call_input.delta":
                guard let id = event.itemID, next.tools[id] != nil,
                      let rawDelta = AIProtocolUtils.JSONCodec.stringValue(raw["delta"]), !rawDelta.isEmpty else {
                    return (next, [])
                }
                if let outcome = AIProtocolUtils.ToolStream.append(next.tools, key: id, text: OpenAIFreeform.streamDelta(rawDelta)) {
                    next.tools = outcome.tools
                    return (next, outcome.events)
                }
                return (next, [])

            case "response.output_item.done":
                guard let item = event.item else { return (next, []) }
                return try finishOutputItem(&next, item: item)

            case "response.completed", "response.incomplete":
                var events: [AIProtocolUtils.LLMEvent] = []
                let resp = AIProtocolUtils.JSONCodec.objectValue(raw["response"])
                if event.type == "response.completed" {
                    for (idx, elem) in (AIProtocolUtils.JSONCodec.arrayValue(resp?["output"]) ?? []).enumerated() {
                        guard let obj = AIProtocolUtils.JSONCodec.objectValue(elem) else { continue }
                        let resolved = resolveItem(next.outputItems, item: obj, index: idx)
                        let recoverable = resolved.type == "compaction"
                            || ((resolved.type == "function_call" || resolved.type == "custom_tool_call") && next.tools[resolved.id] != nil)
                        if recoverable {
                            let (updated, emitted) = try finishOutputItem(&next, item: resolved)
                            next = updated
                            events.append(contentsOf: emitted)
                        }
                    }
                    let pending = try AIProtocolUtils.ToolStream.finishAll(route: next.id, tools: next.tools)
                    next.tools = pending.tools
                    if pending.events.contains(where: \.isToolCallOrError) { next.hasFunctionCall = true }
                    events.append(contentsOf: pending.events)
                }
                let incReason = AIProtocolUtils.JSONCodec.stringValue(AIProtocolUtils.JSONCodec.objectValue(resp?["incomplete_details"])?["reason"])
                let normalized: AIProtocolUtils.FinishReason
                if let incReason {
                    if incReason == "max_output_tokens" { normalized = .length }
                    else if incReason == "content_filter" { normalized = .contentFilter }
                    else { normalized = next.hasFunctionCall ? .toolCalls : .unknown }
                } else if next.hasFunctionCall {
                    normalized = .toolCalls
                } else if event.type == "response.incomplete" {
                    normalized = .unknown
                } else {
                    normalized = .stop
                }
                var finishMeta: [String: JSONValue] = [:]
                if let rid = AIProtocolUtils.JSONCodec.stringValue(resp?["id"]) { finishMeta["responseId"] = .string(rid) }
                if let tier = AIProtocolUtils.JSONCodec.stringValue(resp?["service_tier"]) { finishMeta["serviceTier"] = .string(tier) }
                let usage = mapUsage(resp?["usage"], providerMetadataKey: next.providerMetadataKey, frames: [.object(raw), resp.map(JSONValue.object) ?? .null])
                next.lifecycle = AIProtocolUtils.Lifecycle.finish(
                    next.lifecycle,
                    events: &events,
                    reason: AIProtocolUtils.FinishReasonDetails(normalized: normalized, raw: incReason),
                    usage: usage,
                    providerMetadata: finishMeta.isEmpty ? nil : providerMetadata(next, metadata: finishMeta)
                )
                return (next, events)

            default:
                return (next, [])
            }
        }

        private static func finishOutputItem(
            _ state: inout ParserState,
            item: OutputItem
        ) throws(AIProtocolUtils.ProtocolError) -> StepResult {
            var events: [AIProtocolUtils.LLMEvent] = []
            if item.type == "compaction" {
                guard let enc = AIProtocolUtils.JSONCodec.stringValue(item.raw["encrypted_content"]) else {
                    throw AIProtocolUtils.ProviderShared.eventError(state.id, "Compaction output is missing its encrypted content")
                }
                if state.completedCompactions.contains(item.id) { return (state, []) }
                state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                events.append(.compaction(provider: state.provider, id: item.id, encrypted: enc))
                state.completedCompactions.insert(item.id)
                return (state, events)
            }
            if item.type == "message" {
                let parts = AIProtocolUtils.JSONCodec.arrayValue(item.raw["content"]) ?? []
                let text = parts.compactMap { elem -> String? in
                    let obj = AIProtocolUtils.JSONCodec.objectValue(elem)
                    let t = AIProtocolUtils.JSONCodec.stringValue(obj?["type"])
                    if t == "output_text" { return AIProtocolUtils.JSONCodec.stringValue(obj?["text"]) }
                    if t == "refusal" { return AIProtocolUtils.JSONCodec.stringValue(obj?["refusal"]) }
                    return nil
                }.joined()
                var metaFields: [String: JSONValue] = ["itemId": .string(item.id)]
                if let phase = AIProtocolUtils.JSONCodec.stringValue(item.raw["phase"]) ?? state.messagePhase?.rawValue {
                    metaFields["phase"] = .string(phase)
                }
                let meta = providerMetadata(state, metadata: metaFields)
                if !text.isEmpty {
                    state.lifecycle = AIProtocolUtils.Lifecycle.textStart(state.lifecycle, events: &events, id: item.id, providerMetadata: meta)
                }
                state.lifecycle = AIProtocolUtils.Lifecycle.textEnd(state.lifecycle, events: &events, id: item.id, providerMetadata: meta, text: text.isEmpty ? nil : text)
                if state.messageID == item.id { state.messageID = nil }
                return (state, events)
            }
            if (item.type == "function_call" || item.type == "custom_tool_call"),
               let callID = AIProtocolUtils.JSONCodec.stringValue(item.raw["call_id"]),
               let name = AIProtocolUtils.JSONCodec.stringValue(item.raw["name"]) {
                let isCustom = item.type == "custom_tool_call"
                let ns = AIProtocolUtils.JSONCodec.stringValue(item.raw["namespace"])
                let meta = providerMetadata(state, metadata: OpenAIFreeform.metadata(itemId: item.id, custom: isCustom))
                let rawIn = AIProtocolUtils.JSONCodec.stringValue(item.raw["input"]) ?? ""
                let finalArgs = isCustom
                    ? OpenAIFreeform.fromRaw(state.custom[name], raw: rawIn)
                    : AIProtocolUtils.JSONCodec.stringValue(item.raw["arguments"])
                let registered = state.tools[item.id] != nil
                var closedEvents: [AIProtocolUtils.LLMEvent] = []
                if isCustom && registered {
                    let closed = OpenAIFreeform.close(tools: state.tools, keys: [item.id], final: (state.custom[name], rawIn))
                    state.tools = closed.tools
                    closedEvents = closed.events
                } else if !registered {
                    state.tools = AIProtocolUtils.ToolStream.start(
                        state.tools,
                        key: item.id,
                        tool: AIProtocolUtils.ToolStream.PendingTool(id: callID, name: name, namespace: ns, providerMetadata: meta)
                    )
                }
                let finished = try AIProtocolUtils.ToolStream.finish(route: state.id, tools: state.tools, key: item.id, input: finalArgs)
                state.tools = finished.tools
                let combined = closedEvents + finished.events
                if !combined.isEmpty {
                    state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                    if !registered {
                        events.append(.toolInputStart(id: callID, name: name, namespace: ns, providerMetadata: meta))
                    }
                    events.append(contentsOf: combined)
                    if combined.contains(where: \.isToolCallOrError) { state.hasFunctionCall = true }
                }
                return (state, events)
            }
            if item.type == "reasoning" {
                let enc = AIProtocolUtils.JSONCodec.stringValue(item.raw["encrypted_content"])
                let meta = providerMetadata(state, metadata: [
                    "itemId": .string(item.id),
                    "reasoningEncryptedContent": enc.map(JSONValue.string) ?? .null,
                ])
                let summaryTexts = (AIProtocolUtils.JSONCodec.arrayValue(item.raw["summary"]) ?? []).compactMap {
                    AIProtocolUtils.JSONCodec.stringValue(AIProtocolUtils.JSONCodec.objectValue($0)?["text"])
                }
                let fullText = summaryTexts.isEmpty ? nil : summaryTexts.joined(separator: "\n\n")
                if let existing = state.reasoningItems.removeValue(forKey: item.id) {
                    for idx in existing.summaryParts.keys.sorted() where existing.summaryParts[idx] != "concluded" {
                        let partText = existing.summaryParts.count == 1 ? fullText : (idx < summaryTexts.count ? summaryTexts[idx] : nil)
                        state.lifecycle = AIProtocolUtils.Lifecycle.reasoningEnd(state.lifecycle, events: &events, id: "\(item.id):\(idx)", providerMetadata: meta, text: partText)
                    }
                } else {
                    state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                    events.append(.reasoningStart(id: item.id, providerMetadata: meta))
                    events.append(.reasoningEnd(id: item.id, text: fullText, providerMetadata: meta))
                }
                return (state, events)
            }
            return (state, [])
        }

        // parity: ai/src/protocols/open-responses.ts#initial [status=implemented hash=de588d8a14c0]
        public static func initial(
            _ request: AIProtocolUtils.LLMRequest,
            adapter: ProviderAdapter = .base
        ) -> ParserState {
            ParserState(
                provider: request.model.provider,
                id: adapter.id,
                name: adapter.name,
                providerMetadataKey: metadataKey(request.model),
                custom: OpenAIFreeform.tools(request)
            )
        }

        public struct StreamDecoder: IncrementalStreamDecoder, Sendable {
            private var sse = AIProtocolUtils.SSEParser()
            private var state: ParserState
            private let hostedTools: AIProtocolUtils.ResponsesHostedTools.Definitions?
            private var terminated = false

            public init(
                request: AIProtocolUtils.LLMRequest,
                adapter: ProviderAdapter = .base,
                hostedTools: AIProtocolUtils.ResponsesHostedTools.Definitions? = nil
            ) {
                self.state = initial(request, adapter: adapter)
                self.hostedTools = hostedTools
            }

            public mutating func feed(_ bytes: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                try process(sse.feed(bytes))
            }

            public mutating func finish() throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                try process(sse.finish())
            }

            private mutating func process(_ frames: [AIProtocolUtils.SSEFrame]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                var events: [AIProtocolUtils.LLMEvent] = []
                for frame in frames {
                    if terminated { break }
                    let trimmed = frame.data.trimmingASCIIWhitespace()
                    if trimmed.isEmpty || trimmed == "[DONE]" || trimmed == ": keepalive" { continue }
                    let rawObj = try decodeChannelEvent(trimmed)
                    let norm = normalize(state, input: rawObj)
                    if let hostedTools, norm.type == "response.output_item.done", let item = norm.item {
                        let hostedItem = AIProtocolUtils.ResponsesHostedTools.Item(id: item.id, type: item.type, raw: item.raw)
                        if AIProtocolUtils.ResponsesHostedTools.isItem(hostedItem, in: hostedTools) {
                            let (nextLifecycle, emitted) = try AIProtocolUtils.ResponsesHostedTools.onDone(
                                lifecycle: state.lifecycle,
                                item: hostedItem,
                                tools: hostedTools,
                                providerMetadataKey: state.providerMetadataKey
                            )
                            state.lifecycle = nextLifecycle
                            events.append(contentsOf: emitted)
                            continue
                        }
                    }
                    let (nextState, emitted) = try step(state, event: norm)
                    state = nextState
                    events.append(contentsOf: emitted)
                    if terminal(rawObj) {
                        terminated = true
                    }
                }
                return events
            }
        }

        public static func parseSSEStream(
            _ bytes: [UInt8],
            request: AIProtocolUtils.LLMRequest,
            adapter: ProviderAdapter = .base,
            hostedTools: AIProtocolUtils.ResponsesHostedTools.Definitions? = nil
        ) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            var decoder = StreamDecoder(request: request, adapter: adapter, hostedTools: hostedTools)
            return try decoder.feed(bytes) + decoder.finish()
        }

        // parity: ai/src/protocols/open-responses.ts#protocol [status=implemented hash=3ef6cd7db881]
        public static let `protocol` = ChatProtocolSpec(
            id: adapterID,
            framing: .sse,
            buildBody: fromRequest,
            parseStream: { bytes, req throws(AIProtocolUtils.ProtocolError) in
                try parseSSEStream(bytes, request: req)
            },
            makeStreamDecoder: { StreamDecoder(request: $0) }
        )

        // parity: ai/src/protocols/open-responses.ts#httpTransport [status=adapted hash=f83e75b34cf9]
        public static let httpTransport: FramingKind = .sse
    }

    // MARK: - OpenResponsesContinuation (packages/ai/src/protocols/open-responses-continuation.ts — 3 symbols)

    public enum OpenResponsesContinuation {
        public static let protocolVersion = "open-responses.websocket.v1"

        // parity: ai/src/protocols/open-responses-continuation.ts#Shape [status=implemented hash=4a7d34a31858]
        public typealias Shape = @Sendable ([String: JSONValue]) -> [String: JSONValue]?

        // parity: ai/src/protocols/open-responses-continuation.ts#DriverInput [status=implemented hash=b35479fb426f]
        public struct DriverInput: Sendable {
            public let id: String
            public let name: String
            public let request: [String: JSONValue]
            public let continuation: Shape?

            public init(id: String, name: String, request: [String: JSONValue], continuation: Shape? = nil) {
                self.id = id
                self.name = name
                self.request = request
                self.continuation = continuation
            }
        }

        public struct Checkpoint: Equatable, Hashable, Sendable {
            public let responseID: String
            public let request: [String: JSONValue]
            public let output: [JSONValue]

            public init(responseID: String, request: [String: JSONValue], output: [JSONValue]) {
                self.responseID = responseID
                self.request = request
                self.output = output
            }
        }

        public struct Driver: Sendable {
            public let input: DriverInput

            public init(input: DriverInput) { self.input = input }

            public func createMessage(checkpoint: Checkpoint?) -> (mode: String, message: String) {
                var stripped = input.request
                stripped.removeValue(forKey: "previous_response_id")
                guard let checkpoint else {
                    return ("full", AIProtocolUtils.JSONCodec.encodeObject(stripped))
                }
                let shapeFn: Shape = input.continuation ?? { $0 }
                guard let fields = shapeFn(stripped),
                      let currentInput = AIProtocolUtils.JSONCodec.arrayValue(stripped["input"]),
                      let prevInput = AIProtocolUtils.JSONCodec.arrayValue(checkpoint.request["input"]) else {
                    return ("full", AIProtocolUtils.JSONCodec.encodeObject(stripped))
                }
                let baseline = prevInput + checkpoint.output
                guard currentInput.count > baseline.count,
                      Array(currentInput.prefix(baseline.count)) == baseline else {
                    return ("full", AIProtocolUtils.JSONCodec.encodeObject(stripped))
                }
                var incremental = fields
                incremental["input"] = .array(Array(currentInput.dropFirst(baseline.count)))
                incremental["previous_response_id"] = .string(checkpoint.responseID)
                return ("incremental", AIProtocolUtils.JSONCodec.encodeObject(incremental))
            }
        }

        // parity: ai/src/protocols/open-responses-continuation.ts#driver [status=implemented hash=d75f5aeb1aa5]
        public static func driver(_ input: DriverInput) -> Driver {
            Driver(input: input)
        }
    }

    // MARK: - OpenResponsesChannel (packages/ai/src/protocols/open-responses-channel.ts — 4 symbols)

    public enum OpenResponsesChannel {
        // parity: ai/src/protocols/open-responses-channel.ts#Options [status=implemented hash=5a90c9401b76]
        public struct Options: Sendable {
            public let id: String
            public let name: String
            public let rotateAfterMs: Int?
            public let enabled: (@Sendable (String) -> Bool)?
            public let url: (@Sendable (String) -> String)?
            public let headers: (@Sendable ([String: String]) -> [String: String])?
            public let continuation: OpenResponsesContinuation.Shape?

            public init(
                id: String,
                name: String,
                rotateAfterMs: Int? = nil,
                enabled: (@Sendable (String) -> Bool)? = nil,
                url: (@Sendable (String) -> String)? = nil,
                headers: (@Sendable ([String: String]) -> [String: String])? = nil,
                continuation: OpenResponsesContinuation.Shape? = nil
            ) {
                self.id = id
                self.name = name
                self.rotateAfterMs = rotateAfterMs
                self.enabled = enabled
                self.url = url
                self.headers = headers
                self.continuation = continuation
            }
        }

        // parity: ai/src/protocols/open-responses-channel.ts#Prepared [status=implemented hash=6a3641478e6c]
        public struct Prepared: Equatable, Sendable {
            public let httpRequest: HTTPRequest
            public let webSocketURL: String?
            public let webSocketHeaders: [String: String]?
            public let rotateAfterMs: Int?

            public init(
                httpRequest: HTTPRequest,
                webSocketURL: String? = nil,
                webSocketHeaders: [String: String]? = nil,
                rotateAfterMs: Int? = nil
            ) {
                self.httpRequest = httpRequest
                self.webSocketURL = webSocketURL
                self.webSocketHeaders = webSocketHeaders
                self.rotateAfterMs = rotateAfterMs
            }
        }

        public struct ChannelTransport: Sendable {
            public let options: Options

            public init(options: Options) { self.options = options }

            public func prepare(httpRequest: HTTPRequest, enableWebSocket: Bool = false) -> Prepared {
                let wsEnabled = enableWebSocket && (options.enabled?(httpRequest.url) ?? true)
                guard wsEnabled else {
                    return Prepared(httpRequest: httpRequest)
                }
                let rawURL = options.url?(httpRequest.url) ?? httpRequest.url
                let wsURL: String
                if rawURL.hasPrefix("https://") {
                    wsURL = "wss://" + rawURL.dropFirst(8)
                } else if rawURL.hasPrefix("http://") {
                    wsURL = "ws://" + rawURL.dropFirst(7)
                } else {
                    wsURL = rawURL
                }
                var headers = options.headers?(httpRequest.headers) ?? httpRequest.headers
                headers.removeValue(forKey: "content-length")
                return Prepared(
                    httpRequest: httpRequest,
                    webSocketURL: wsURL,
                    webSocketHeaders: headers,
                    rotateAfterMs: options.rotateAfterMs
                )
            }
        }

        // parity: ai/src/protocols/open-responses-channel.ts#transport [status=implemented hash=46cc6ebd54eb]
        public static func transport(_ options: Options) -> ChannelTransport {
            ChannelTransport(options: options)
        }

        // parity: ai/src/protocols/open-responses-channel.ts#OpenResponsesChannel [status=implemented hash=2af4757b2ad7]
        public static let OpenResponsesChannel = ChannelTransport.self
    }

    // MARK: - OpenAIResponses (packages/ai/src/protocols/openai-responses.ts — 12 symbols)

    public enum OpenAIResponses {
        public static let adapterID = "openai-responses"
        public static let name = "OpenAI Responses"
        public static let webSocketProtocolHeader = "responses_websockets=2026-02-06"
        public static let webSocketRotateAfterMs = 55 * 60 * 1000

        // parity: ai/src/protocols/openai-responses.ts#DEFAULT_BASE_URL [status=implemented hash=97f5685da742]
        public static let DEFAULT_BASE_URL = "https://api.openai.com/v1"

        // parity: ai/src/protocols/openai-responses.ts#PATH [status=implemented hash=1ebc29874fd2]
        public static let PATH = OpenResponses.PATH

        // parity: ai/src/protocols/openai-responses.ts#ContextManagement [status=implemented hash=dc67f96c9c45]
        public struct ContextManagementEntry: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let compactThreshold: Int?
            public init(type: String = "compaction", compactThreshold: Int? = nil) {
                self.type = type; self.compactThreshold = compactThreshold
            }
        }
        public typealias ContextManagement = [ContextManagementEntry]

        // parity: ai/src/protocols/openai-responses.ts#ReasoningMode [status=implemented hash=dbda62f00ba0]
        public typealias ReasoningMode = String

        // parity: ai/src/protocols/openai-responses.ts#ReasoningContext [status=implemented hash=e38d38a3e676]
        public typealias ReasoningContext = String

        // parity: ai/src/protocols/openai-responses.ts#OpenAIResponsesBody [status=implemented hash=243a2ebcb941]
        public typealias OpenAIResponsesBody = [String: JSONValue]

        // parity: ai/src/protocols/openai-responses.ts#CompactionTrigger [status=implemented hash=0802956921b8]
        public struct CompactionTrigger: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public init() { self.type = "compaction_trigger" }
            public var jsonValue: JSONValue { .object(["type": .string(type)]) }
        }

        public static let adapter = OpenResponses.ProviderAdapter(
            id: adapterID,
            name: name,
            restoreHostedToolItem: { value in
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(value),
                      let t = AIProtocolUtils.JSONCodec.stringValue(obj["type"]),
                      t == "computer_call" || t == "web_search_preview_call" || t == "image_generation_call" else {
                    return nil
                }
                return obj
            }
        )

        public static func fromRequest(_ request: AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> OpenAIResponsesBody {
            var body = try OpenResponses.fromRequestWithAdapter(request, adapter: adapter)
            let opts = request.providerOptions ?? [:]
            if case .configured(let ttl) = request.cache {
                for (k, v) in AIProtocolUtils.Cache.openAIRequestTTL(ttl) { body[k] = v }
            }
            if let mode = AIProtocolUtils.JSONCodec.stringValue(opts["reasoningMode"]) {
                var r = AIProtocolUtils.JSONCodec.objectValue(body["reasoning"]) ?? [:]
                r["mode"] = .string(mode)
                body["reasoning"] = .object(r)
            }
            if let ctx = AIProtocolUtils.JSONCodec.stringValue(opts["reasoningContext"]) {
                var r = AIProtocolUtils.JSONCodec.objectValue(body["reasoning"]) ?? [:]
                r["context"] = .string(ctx)
                body["reasoning"] = .object(r)
            }
            if let cm = AIProtocolUtils.JSONCodec.arrayValue(opts["contextManagement"]) {
                let mapped: [JSONValue] = cm.compactMap { elem in
                    guard let obj = AIProtocolUtils.JSONCodec.objectValue(elem) else { return nil }
                    var out: [String: JSONValue] = ["type": obj["type"] ?? .string("compaction")]
                    if let thresh = obj["compactThreshold"] ?? obj["compact_threshold"] { out["compact_threshold"] = thresh }
                    return .object(out)
                }
                body["context_management"] = .array(mapped)
            }
            // Native namespaces & image_generation tool handling
            if !request.tools.isEmpty {
                let custom = OpenAIFreeform.tools(request)
                var loweredTools: [JSONValue] = []
                for entry in request.tools {
                    switch entry {
                    case .tool(let def):
                        if let nativeOpenAI = AIProtocolUtils.JSONCodec.objectValue(def.native?["openai"]),
                           AIProtocolUtils.JSONCodec.stringValue(nativeOpenAI["type"]) == "image_generation" {
                            loweredTools.append(.object(nativeOpenAI))
                        } else if let c = custom[def.name] {
                            loweredTools.append(.object(OpenResponses.lowerCustomTool(tool: def, custom: c)))
                        } else {
                            loweredTools.append(.object(try OpenResponses.lowerTool(protocolName: name, tool: def)))
                        }
                    case .namespace(let nsName, let nsDesc, let nested):
                        var leaves: [JSONValue] = []
                        for leaf in AIProtocolUtils.ProviderShared.flattenTools(nested) {
                            leaves.append(.object(try OpenResponses.lowerTool(protocolName: name, tool: leaf)))
                        }
                        loweredTools.append(.object([
                            "type": .string("namespace"),
                            "name": .string(nsName),
                            "description": .string(nsDesc ?? "Tools in the \(nsName) namespace."),
                            "tools": .array(leaves),
                        ]))
                    }
                }
                body["tools"] = .array(loweredTools)
            }
            return body
        }

        // parity: ai/src/protocols/openai-responses.ts#protocol [status=implemented hash=0550e136092a]
        public static let `protocol` = ChatProtocolSpec(
            id: adapterID,
            framing: .sse,
            buildBody: fromRequest,
            parseStream: { bytes, req throws(AIProtocolUtils.ProtocolError) in
                try OpenResponses.parseSSEStream(bytes, request: req, adapter: adapter, hostedTools: AIProtocolUtils.ResponsesHostedTools.common)
            },
            makeStreamDecoder: { req in
                OpenResponses.StreamDecoder(request: req, adapter: adapter, hostedTools: AIProtocolUtils.ResponsesHostedTools.common)
            }
        )

        // parity: ai/src/protocols/openai-responses.ts#httpTransport [status=adapted hash=b8e5c9dc1cfe]
        public static let httpTransport: FramingKind = .sse

        // parity: ai/src/protocols/openai-responses.ts#channelTransport [status=implemented hash=9c2de87979b8]
        public static func channelTransport(_ options: OpenResponsesChannel.Options) -> OpenResponsesChannel.ChannelTransport {
            OpenResponsesChannel.transport(options)
        }

        // parity: ai/src/protocols/openai-responses.ts#transport [status=implemented hash=9775213b1f97]
        public static let transport = channelTransport(OpenResponsesChannel.Options(
            id: adapterID,
            name: name,
            rotateAfterMs: webSocketRotateAfterMs,
            headers: { headers in
                var copy = headers
                copy["openai-beta"] = webSocketProtocolHeader
                return copy
            }
        ))

        // parity: ai/src/protocols/openai-responses.ts#route [status=implemented hash=8e5d31962209]
        public static let route = ChatRouteSpec(
            id: adapterID,
            provider: "openai",
            providerMetadataKey: "openai",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )
    }

    // MARK: - OpenAIChat (packages/ai/src/protocols/openai-chat.ts — 19 symbols)

    public enum OpenAIChat {
        public static let adapterID = "openai-chat"
        private static let reservedReasoningFields: Set<String> = ["role", "content", "refusal", "tool_calls"]

        // parity: ai/src/protocols/openai-chat.ts#DEFAULT_BASE_URL [status=implemented hash=97f5685da742]
        public static let DEFAULT_BASE_URL = "https://api.openai.com/v1"

        // parity: ai/src/protocols/openai-chat.ts#PATH [status=implemented hash=16806d4aa677]
        public static let PATH = "/chat/completions"

        // parity: ai/src/protocols/openai-chat.ts#OpenAIChatAssistantToolCall [status=implemented hash=5e0c4a6dfd9c]
        public struct OpenAIChatAssistantToolCall: Equatable, Hashable, Sendable {
            public let id: String
            public let name: String
            public let arguments: String
            public let thoughtSignature: String?

            public init(id: String, name: String, arguments: String, thoughtSignature: String? = nil) {
                self.id = id; self.name = name; self.arguments = arguments; self.thoughtSignature = thoughtSignature
            }

            public var jsonValue: JSONValue {
                var obj: [String: JSONValue] = [
                    "id": .string(id),
                    "type": .string("function"),
                    "function": .object(["name": .string(name), "arguments": .string(arguments)]),
                ]
                if let sig = thoughtSignature {
                    obj["extra_content"] = .object(["google": .object(["thought_signature": .string(sig)])])
                }
                return .object(obj)
            }
        }

        // parity: ai/src/protocols/openai-chat.ts#OpenAIChatAssistantCustomToolCall [status=implemented hash=a1cec6bfbacd]
        public struct OpenAIChatAssistantCustomToolCall: Equatable, Hashable, Sendable {
            public let id: String
            public let name: String
            public let input: String

            public init(id: String, name: String, input: String) {
                self.id = id; self.name = name; self.input = input
            }

            public var jsonValue: JSONValue {
                .object([
                    "id": .string(id),
                    "type": .string("custom"),
                    "custom": .object(["name": .string(name), "input": .string(input)]),
                ])
            }
        }

        // parity: ai/src/protocols/openai-chat.ts#OpenAIChatMessage [status=implemented hash=7279d2c113bd]
        public typealias OpenAIChatMessage = [String: JSONValue]

        // parity: ai/src/protocols/openai-chat.ts#bodyFields [status=implemented hash=fc7ccbfa53ef]
        public static let bodyFields: [String] = [
            "model", "messages", "tools", "tool_choice", "stream", "stream_options", "store",
            "prompt_cache_key", "prompt_cache_retention", "prompt_cache_options", "reasoning_effort",
            "verbosity", "service_tier", "parallel_tool_calls", "metadata", "safety_identifier",
            "tool_stream", "max_completion_tokens", "max_tokens", "temperature", "top_p",
            "frequency_penalty", "presence_penalty", "seed", "stop",
        ]

        // parity: ai/src/protocols/openai-chat.ts#OpenAIChatBody [status=implemented hash=ce139493bf0f]
        public typealias OpenAIChatBody = [String: JSONValue]

        // parity: ai/src/protocols/openai-chat.ts#OpenAIChatUsage [status=implemented hash=c1df8544db5b]
        public typealias OpenAIChatUsage = [String: JSONValue]

        // parity: ai/src/protocols/openai-chat.ts#OpenAIChatToolCallDelta [status=implemented hash=718fa6816d21]
        public typealias OpenAIChatToolCallDelta = [String: JSONValue]

        // parity: ai/src/protocols/openai-chat.ts#OpenAIChatDelta [status=implemented hash=4715cbb4a2d6]
        public typealias OpenAIChatDelta = [String: JSONValue]

        // parity: ai/src/protocols/openai-chat.ts#OpenAIChatChoice [status=implemented hash=30f92e438615]
        public typealias OpenAIChatChoice = [String: JSONValue]

        // parity: ai/src/protocols/openai-chat.ts#OpenAIChatEvent [status=implemented hash=d2d3b91f0611]
        public typealias OpenAIChatEvent = [String: JSONValue]

        public struct PendingToolDelta: Equatable, Hashable, Sendable {
            public let id: String?
            public let name: String?
            public let input: String
            public let thoughtSignature: String?
        }

        // parity: ai/src/protocols/openai-chat.ts#ParserState [status=implemented hash=3c1186eeafab]
        public struct ParserState: Equatable, Sendable {
            public let providerMetadataKey: String
            public var tools: AIProtocolUtils.ToolStream.State<Int>
            public let custom: [String: OpenAIFreeform.Custom]
            public var customCalls: Set<Int>
            public var pendingTools: [Int: PendingToolDelta]
            public var toolCallEvents: [AIProtocolUtils.LLMEvent]
            public var usage: AIProtocolUtils.Usage?
            public var finishReason: AIProtocolUtils.FinishReasonDetails?
            public var lifecycle: AIProtocolUtils.Lifecycle.State
            public var reasoningField: String?
            public var reasoningTextObserved: Bool
            public var reasoningDetails: [JSONValue]
            public var reasoningDetailsObserved: Bool
            public var reasoningOpaque: String?
            public var reasoningEmitted: Bool
            public var latestToolIndex: Int?
            public var nextToolIndex: Int
            public let requireFinishReason: Bool

            public init(request: AIProtocolUtils.LLMRequest) {
                self.providerMetadataKey = request.model.providerMetadataKey ?? request.model.provider
                self.tools = AIProtocolUtils.ToolStream.empty()
                self.custom = OpenAIFreeform.tools(request)
                self.customCalls = []
                self.pendingTools = [:]
                self.toolCallEvents = []
                self.usage = nil
                self.finishReason = nil
                self.lifecycle = AIProtocolUtils.Lifecycle.initial()
                self.reasoningField = request.model.compatibility?.reasoningField
                self.reasoningTextObserved = false
                self.reasoningDetails = []
                self.reasoningDetailsObserved = false
                self.reasoningOpaque = nil
                self.reasoningEmitted = false
                self.latestToolIndex = nil
                self.nextToolIndex = 0
                self.requireFinishReason = request.model.compatibility?.requireFinishReason ?? false
            }
        }

        public static func detectMaxTokensField(provider: String, baseURL: String?) -> String {
            let p = provider.lowercased()
            let url = (baseURL ?? "").lowercased()
            let legacyProviders: Set<String> = [
                "deepseek", "moonshotai", "togetherai", "zai", "zai-coding-plan",
                "zhipuai", "zhipuai-coding-plan", "nvidia", "cerebras", "chutes",
                "cloudflare-ai-gateway", "cloudflare-workers-ai",
            ]
            if legacyProviders.contains(p)
                || url.contains("deepseek.com") || url.contains("api.moonshot.ai")
                || url.contains("api.together.") || url.contains("api.z.ai")
                || url.contains("open.bigmodel.cn") || url.contains("integrate.api.nvidia.com")
                || url.contains("cerebras.ai") || url.contains("llm.chutes.ai")
                || url.contains("gateway.ai.cloudflare.com") || url.contains("api.cloudflare.com") {
                return "max_tokens"
            }
            return "max_completion_tokens"
        }

        private static func detectSupportsStore(provider: String, baseURL: String?) -> Bool {
            let p = provider.lowercased()
            let url = (baseURL ?? "").lowercased()
            return p == "openai" || p == "azure"
                || url.contains("api.openai.com")
                || url.contains(".openai.azure.com")
                || url.contains(".cognitiveservices.azure.com")
                || url.contains(".services.ai.azure.com")
        }

        private static func detectSupportsStrictMode(provider: String, baseURL: String?) -> Bool {
            let p = provider.lowercased()
            let url = (baseURL ?? "").lowercased()
            let disallowed = p == "moonshotai" || p == "moonshotai-cn" || url.contains("api.moonshot.")
                || p == "togetherai" || p == "together" || url.contains("api.together.")
                || p == "cloudflare-ai-gateway" || url.contains("gateway.ai.cloudflare.com")
                || p == "nvidia" || url.contains("integrate.api.nvidia.com")
            return !disallowed
        }

        private static func detectZaiToolStream(provider: String, baseURL: String?, modelID: String) -> Bool {
            let p = provider.lowercased()
            let url = (baseURL ?? "").lowercased()
            let isZai = p == "zai" || p == "zai-coding-plan" || p == "zhipuai" || p == "zhipuai-coding-plan"
                || url.contains("api.z.ai") || url.contains("open.bigmodel.cn")
            if !isZai { return false }
            let id = modelID.lowercased()
            return id != "glm-4.5" && id != "glm-4.5-air" && id != "glm-4.5-flash" && id != "glm-4.5v"
        }

        private static func normalizeToolCallID(_ id: String, model: AIProtocolUtils.ModelDescriptor) -> String {
            let lower = model.id.lowercased()
            if ["mistral", "devstral", "codestral", "pixtral", "mixtral"].contains(where: { lower.contains($0) }) {
                let alnum = String(id.filter { ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") }.prefix(9))
                return alnum.count >= 9 ? alnum : alnum + String(repeating: "0", count: 9 - alnum.count)
            }
            if lower.contains("claude") {
                return String(id.map { ch in
                    let ok = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_" || ch == "-"
                    return ok ? ch : "_"
                })
            }
            if model.provider == "openai" || model.provider == "azure" || lower.hasPrefix("openai/") {
                return String(id.prefix(40))
            }
            return id
        }

        private static func lowerMedia(_ part: AIProtocolUtils.MediaPart) throws(AIProtocolUtils.ProtocolError) -> JSONValue {
            if part.media.mediaType.lowercased() == "application/pdf" {
                let inline = try AIProtocolUtils.ProviderShared.requireInlineMedia(route: "OpenAI Chat", asset: part.media)
                return .object([
                    "type": .string("file"),
                    "file": .object([
                        "filename": .string(part.filename ?? "document.pdf"),
                        "file_data": .string(inline.dataUrl),
                    ]),
                ])
            }
            guard part.media.kind == .image || part.media.kind == .video else {
                throw AIProtocolUtils.ProviderShared.invalidRequest("OpenAI Chat does not support media type \(part.media.mediaType)")
            }
            let url: String
            if let remote = AIProtocolUtils.ProviderShared.mediaUrl(part.media) {
                url = remote
            } else {
                url = try AIProtocolUtils.ProviderShared.requireInlineMedia(route: "OpenAI Chat", asset: part.media).dataUrl
            }
            if part.media.kind == .video {
                return .object(["type": .string("video_url"), "video_url": .object(["url": .string(url)])])
            }
            return .object(["type": .string("image_url"), "image_url": .object(["url": .string(url)])])
        }

        // parity: ai/src/protocols/openai-chat.ts#fromRequest [status=implemented hash=b1b6974666e4]
        public static func fromRequest(
            _ request: AIProtocolUtils.LLMRequest,
            useCacheControl: Bool = false
        ) throws(AIProtocolUtils.ProtocolError) -> OpenAIChatBody {
            if let rf = request.model.compatibility?.reasoningField, reservedReasoningFields.contains(rf) {
                throw AIProtocolUtils.ProviderShared.invalidRequest("OpenAI Chat reasoning field conflicts with reserved field \(rf)")
            }
            let flattened = AIProtocolUtils.ProviderShared.flattenToolRequest(request)
            let provider = request.model.provider
            let baseURL = request.model.baseURL
            let maxTokensField = request.model.compatibility?.maxTokensField ?? detectMaxTokensField(provider: provider, baseURL: baseURL)
            let supportsStore = request.model.capabilities?.store ?? detectSupportsStore(provider: provider, baseURL: baseURL)
            let supportsStrict = request.model.capabilities?.strictTools ?? detectSupportsStrictMode(provider: provider, baseURL: baseURL)
            let zaiToolStream = request.model.compatibility?.zaiToolStream ?? detectZaiToolStream(provider: provider, baseURL: baseURL, modelID: request.model.id)
            let custom = OpenAIFreeform.tools(request)
            let enableCC = useCacheControl || request.model.compatibility?.cacheFormat != nil
            var breakpoints = AIProtocolUtils.Cache.newBreakpoints(4)
            func makeCC(_ cache: AIProtocolUtils.CacheHint?) -> JSONValue? {
                guard enableCC, let cache, AIProtocolUtils.Cache.take(&breakpoints) else { return nil }
                var obj: [String: JSONValue] = ["type": .string("ephemeral")]
                if let ttl = cache.ttl { obj["ttl"] = .string(ttl) }
                return .object(obj)
            }

            let metaKey = request.model.providerMetadataKey ?? provider
            let modelLower = request.model.id.lowercased()
            let isMistral = ["mistral", "devstral", "codestral", "pixtral", "mixtral"].contains(where: { modelLower.contains($0) })
            let requireAssistantAfterTool = request.model.compatibility?.requireAssistantAfterTool ?? isMistral
            let requireReasoning = request.model.compatibility?.requireReasoning
                ?? (request.model.compatibility?.reasoningField != nil
                    || provider == "deepseek"
                    || (baseURL ?? "").lowercased().contains("deepseek.com")
                    || modelLower.contains("deepseek"))

            var messages: [OpenAIChatMessage] = []
            if !request.system.isEmpty {
                if enableCC && request.system.contains(where: { $0.cache != nil }) {
                    let parts: [JSONValue] = request.system.map { p in
                        var obj: [String: JSONValue] = ["type": .string("text"), "text": .string(p.text)]
                        if let cc = makeCC(p.cache) { obj["cache_control"] = cc }
                        return .object(obj)
                    }
                    messages.append(["role": .string("system"), "content": .array(parts)])
                } else {
                    messages.append(["role": .string("system"), "content": .string(AIProtocolUtils.ProviderShared.joinText(request.system))])
                }
            }

            for message in flattened.request.messages {
                if message.role == .user && requireAssistantAfterTool,
                   let last = messages.last, case .string("tool") = last["role"] {
                    messages.append(["role": .string("assistant"), "content": .string("Done.")])
                }
                switch message.role {
                case .system:
                    let wrapped = try AIProtocolUtils.ProviderShared.wrappedSystemUpdate(route: "OpenAI Chat", message: message)
                    messages.append(["role": .string("user"), "content": .string(wrapped.text)])

                case .user:
                    var parts: [JSONValue] = []
                    var allPlainText = true
                    var joinedText = ""
                    for part in message.content {
                        switch part {
                        case .text(let tp):
                            let cc = makeCC(tp.cache)
                            if cc != nil { allPlainText = false }
                            var obj: [String: JSONValue] = ["type": .string("text"), "text": .string(tp.text)]
                            if let cc { obj["cache_control"] = cc }
                            parts.append(.object(obj))
                            joinedText += tp.text
                        case .media(let mp):
                            allPlainText = false
                            parts.append(try lowerMedia(mp))
                        default:
                            break
                        }
                    }
                    messages.append([
                        "role": .string("user"),
                        "content": allPlainText ? .string(joinedText) : .array(parts),
                    ])

                case .assistant:
                    var textContent: [JSONValue] = []
                    var plainText = ""
                    var hasCC = false
                    var reasoningTexts: [String] = []
                    var toolCalls: [JSONValue] = []
                    for part in message.content {
                        switch part {
                        case .text(let tp):
                            let cc = makeCC(tp.cache)
                            if cc != nil { hasCC = true }
                            var obj: [String: JSONValue] = ["type": .string("text"), "text": .string(tp.text)]
                            if let cc { obj["cache_control"] = cc }
                            textContent.append(.object(obj))
                            plainText += tp.text
                        case .reasoning(let rp):
                            reasoningTexts.append(rp.text)
                        case .toolCall(let tc):
                            let normID = normalizeToolCallID(tc.id, model: request.model)
                            if let c = custom[tc.name] {
                                toolCalls.append(OpenAIChatAssistantCustomToolCall(id: normID, name: tc.name, input: OpenAIFreeform.toRaw(c, input: tc.input)).jsonValue)
                            } else {
                                let sig = AIProtocolUtils.JSONCodec.stringValue(
                                    AIProtocolUtils.JSONCodec.objectValue(
                                        AIProtocolUtils.JSONCodec.objectValue(tc.providerMetadata?[metaKey]?["extraContent"])?["google"]
                                    )?["thought_signature"]
                                )
                                toolCalls.append(OpenAIChatAssistantToolCall(
                                    id: normID,
                                    name: tc.name,
                                    arguments: AIProtocolUtils.JSONCodec.encode(tc.input),
                                    thoughtSignature: sig
                                ).jsonValue)
                            }
                        default:
                            throw AIProtocolUtils.ProviderShared.unsupportedContent(
                                route: "OpenAI Chat",
                                role: .assistant,
                                types: ["text", "reasoning", "tool-call"]
                            )
                        }
                    }
                    if textContent.isEmpty && reasoningTexts.isEmpty && toolCalls.isEmpty { continue }
                    var msg: OpenAIChatMessage = ["role": .string("assistant")]
                    if hasCC {
                        msg["content"] = .array(textContent)
                    } else if textContent.isEmpty && !toolCalls.isEmpty {
                        msg["content"] = .null
                    } else {
                        msg["content"] = .string(plainText)
                    }
                    if !toolCalls.isEmpty { msg["tool_calls"] = .array(toolCalls) }
                    if !reasoningTexts.isEmpty || requireReasoning {
                        let field = request.model.compatibility?.reasoningField ?? "reasoning_content"
                        if field != "reasoning_details" {
                            msg[field] = .string(reasoningTexts.joined())
                        }
                    }
                    messages.append(msg)

                case .tool:
                    var attachments: [JSONValue] = []
                    for part in message.content {
                        guard case .toolResult(let tr) = part else { continue }
                        let normID = normalizeToolCallID(tr.id, model: request.model)
                        let text: String
                        if case .content(let items) = tr.result {
                            var lines: [String] = []
                            for item in items {
                                switch item {
                                case .text(let t): lines.append(t)
                                case .file(let f): attachments.append(try lowerMedia(AIProtocolUtils.ProviderShared.toolFileMedia(f)))
                                }
                            }
                            text = lines.joined(separator: "\n")
                        } else {
                            text = AIProtocolUtils.ProviderShared.toolResultText(tr)
                        }
                        if let cc = makeCC(tr.cache) {
                            messages.append([
                                "role": .string("tool"),
                                "tool_call_id": .string(normID),
                                "content": .array([.object(["type": .string("text"), "text": .string(text), "cache_control": cc])]),
                            ])
                        } else {
                            messages.append([
                                "role": .string("tool"),
                                "tool_call_id": .string(normID),
                                "content": .string(text),
                            ])
                        }
                    }
                    if !attachments.isEmpty {
                        messages.append(["role": .string("user"), "content": .array(attachments)])
                    }
                }
            }

            let hasActiveTools = !flattened.tools.isEmpty
            let hasToolHistory = request.messages.contains { msg in
                msg.role == .tool || msg.content.contains { if case .toolCall = $0 { return true }; return false }
            }

            var body: OpenAIChatBody = [
                "model": .string(request.model.id),
                "messages": .array(messages.map(JSONValue.object)),
                "stream": .bool(true),
            ]
            if request.model.capabilities?.streamUsage ?? true {
                body["stream_options"] = .object(["include_usage": .bool(true)])
            }
            if hasActiveTools {
                body["tools"] = .array(flattened.tools.map { tool -> JSONValue in
                    if let c = custom[tool.name] {
                        let format: JSONValue
                        if let g = OpenAIFreeform.grammar(c.format) {
                            format = .object(["type": .string("grammar"), "grammar": g.jsonValue])
                        } else {
                            format = .object(["type": .string("text")])
                        }
                        var obj: [String: JSONValue] = [
                            "type": .string("custom"),
                            "custom": .object(["name": .string(tool.name), "description": .string(tool.description), "format": format]),
                        ]
                        if let cc = makeCC(tool.cache) { obj["cache_control"] = cc }
                        return .object(obj)
                    }
                    var fn: [String: JSONValue] = [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": .object(tool.inputSchema),
                    ]
                    if supportsStrict { fn["strict"] = .bool(false) }
                    var obj: [String: JSONValue] = ["type": .string("function"), "function": .object(fn)]
                    if let cc = makeCC(tool.cache) { obj["cache_control"] = cc }
                    return .object(obj)
                })
                if let tc = request.toolChoice {
                    body["tool_choice"] = try AIProtocolUtils.ProviderShared.matchToolChoice(
                        route: "OpenAI Chat",
                        toolChoice: tc,
                        auto: { .string("auto") },
                        none: { .string("none") },
                        required: { .string("required") },
                        tool: { name in
                            if custom[name] != nil {
                                return .object(["type": .string("custom"), "custom": .object(["name": .string(name)])])
                            }
                            return .object(["type": .string("function"), "function": .object(["name": .string(name)])])
                        }
                    )
                }
                if zaiToolStream { body["tool_stream"] = .bool(true) }
            } else if hasToolHistory {
                body["tools"] = .array([])
            }

            if let maxT = request.maxTokens { body[maxTokensField] = .int(Int64(maxT)) }
            if let temp = request.temperature { body["temperature"] = .double(temp) }
            if let topP = request.topP { body["top_p"] = .double(topP) }
            if let fp = request.frequencyPenalty { body["frequency_penalty"] = .double(fp) }
            if let pp = request.presencePenalty { body["presence_penalty"] = .double(pp) }
            if let seed = request.seed { body["seed"] = .int(Int64(seed)) }
            if let stop = request.stop, !stop.isEmpty { body["stop"] = .array(stop.map(JSONValue.string)) }

            let resolvedOpts = AIProtocolUtils.OpenResponsesOptions.resolve(request)
            let opts = resolvedOpts.options
            if supportsStore { body["store"] = .bool(opts.store ?? false) }
            if request.model.capabilities?.promptCacheKey == true,
               let ck = AIProtocolUtils.ProviderShared.promptCacheKey(request) {
                body["prompt_cache_key"] = .string(ck)
            }
            if case .configured(let ttl) = request.cache {
                for (k, v) in AIProtocolUtils.Cache.openAIRequestTTL(ttl) { body[k] = v }
            }
            if let effort = opts.reasoningEffort { body["reasoning_effort"] = .string(effort) }
            if let verb = opts.textVerbosity { body["verbosity"] = .string(verb) }
            if let tier = opts.serviceTier { body["service_tier"] = .string(tier) }
            if hasActiveTools, let par = OpenResponses.resolveParallelToolCalls(request, options: resolvedOpts) {
                body["parallel_tool_calls"] = .bool(par)
            }
            if let metadata = opts.metadata { body["metadata"] = .object(metadata.mapValues(JSONValue.string)) }
            if let safety = opts.safetyIdentifier { body["safety_identifier"] = .string(safety) }
            return body
        }

        private static func mapFinishReason(_ reason: String, rawEvent: OpenAIChatEvent) throws(AIProtocolUtils.ProtocolError) -> AIProtocolUtils.FinishReason {
            switch reason {
            case "error":
                throw AIProtocolUtils.ProtocolError(kind: .unknownProvider, message: "Provider reported an error (finish_reason: error)", route: adapterID, body: AIProtocolUtils.JSONCodec.encodeObject(rawEvent))
            case "network_error":
                throw AIProtocolUtils.ProtocolError(kind: .providerInternal, message: "Provider reported a network error (finish_reason: network_error)", route: adapterID, body: AIProtocolUtils.JSONCodec.encodeObject(rawEvent))
            case "stop", "end": return .stop
            case "length": return .length
            case "content_filter": return .contentFilter
            case "function_call", "tool_calls": return .toolCalls
            default: return .unknown
            }
        }

        private static func mapUsage(_ usageVal: JSONValue?, key: String, frame: OpenAIChatEvent) -> AIProtocolUtils.Usage? {
            guard let u = AIProtocolUtils.JSONCodec.objectValue(usageVal) else { return nil }
            let input = AIProtocolUtils.JSONCodec.doubleValue(u["prompt_tokens"])
            let completion = AIProtocolUtils.JSONCodec.doubleValue(u["completion_tokens"])
            let pDetails = AIProtocolUtils.JSONCodec.objectValue(u["prompt_tokens_details"])
            let cDetails = AIProtocolUtils.JSONCodec.objectValue(u["completion_tokens_details"])
            let cached = AIProtocolUtils.JSONCodec.doubleValue(pDetails?["cached_tokens"])
                ?? AIProtocolUtils.JSONCodec.doubleValue(u["prompt_cache_hit_tokens"])
                ?? AIProtocolUtils.JSONCodec.doubleValue(u["cached_tokens"])
                ?? AIProtocolUtils.JSONCodec.doubleValue(u["cache_read_input_tokens"])
            let cacheWrite = AIProtocolUtils.JSONCodec.doubleValue(pDetails?["cache_write_tokens"])
                ?? AIProtocolUtils.JSONCodec.doubleValue(u["cache_created_input_tokens"])
            let reasoning = AIProtocolUtils.JSONCodec.doubleValue(cDetails?["reasoning_tokens"])
                ?? AIProtocolUtils.JSONCodec.doubleValue(u["reasoning_tokens"])
            let totalRaw = AIProtocolUtils.JSONCodec.doubleValue(u["total_tokens"])
            let output: Double?
            if let completion, let reasoning,
               totalRaw == AIProtocolUtils.ProviderShared.sumTokens(input, completion, reasoning) {
                output = completion + reasoning
            } else {
                output = completion
            }
            let nonCached = AIProtocolUtils.ProviderShared.subtractTokens(input, AIProtocolUtils.ProviderShared.sumTokens(cached, cacheWrite))
            let billing = AIProtocolUtils.ProviderShared.reportedBilling(usage: usageVal, frames: [.object(frame)])
            return AIProtocolUtils.Usage(
                inputTokens: input,
                outputTokens: output,
                nonCachedInputTokens: nonCached,
                cacheReadInputTokens: cached,
                cacheWriteInputTokens: cacheWrite,
                reasoningTokens: reasoning,
                totalTokens: AIProtocolUtils.ProviderShared.totalTokens(input, output, totalRaw),
                cost: billing.cost,
                providerMetadata: [key: u]
            )
        }

        public static func step(
            state: inout ParserState,
            event: OpenAIChatEvent
        ) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            if let errObj = AIProtocolUtils.JSONCodec.objectValue(event["error"]) {
                let msg = AIProtocolUtils.JSONCodec.stringValue(errObj["message"]) ?? "OpenAI Chat error"
                let code = AIProtocolUtils.JSONCodec.intValue(errObj["code"])
                throw AIProtocolUtils.ProtocolError(kind: code == 429 ? .rateLimit : .providerInternal, message: msg, route: adapterID, statusCode: code, body: AIProtocolUtils.JSONCodec.encodeObject(event))
            }
            var events: [AIProtocolUtils.LLMEvent] = []
            let choice = AIProtocolUtils.JSONCodec.arrayValue(event["choices"])?.first.flatMap(AIProtocolUtils.JSONCodec.objectValue)
            if let u = mapUsage(event["usage"], key: state.providerMetadataKey, frame: event)
                ?? mapUsage(choice?["usage"], key: state.providerMetadataKey, frame: event) {
                state.usage = u
            }
            let rawFinish = AIProtocolUtils.JSONCodec.stringValue(choice?["finish_reason"])
            let newFinish: AIProtocolUtils.FinishReasonDetails?
            if let rawFinish {
                let normalized = try mapFinishReason(rawFinish, rawEvent: event)
                let category = rawFinish == "content_filter"
                    ? AIProtocolUtils.ProviderShared.contentFilterCategory(
                        AIProtocolUtils.JSONCodec.objectValue(choice?["delta"])?["copilot_annotations"],
                        choice?["content_filter_results"]
                    )
                    : nil
                newFinish = AIProtocolUtils.FinishReasonDetails(
                    normalized: normalized,
                    raw: AIProtocolUtils.JSONCodec.stringValue(choice?["native_finish_reason"]) ?? rawFinish,
                    category: category
                )
            } else {
                newFinish = nil
            }

            let delta = AIProtocolUtils.JSONCodec.objectValue(choice?["delta"])
            // Reasoning fields
            let candidateFields = [state.reasoningField, "reasoning_content", "reasoning", "reasoning_text"].compactMap { $0 }
            for field in candidateFields {
                if let rText = AIProtocolUtils.JSONCodec.stringValue(delta?[field]), !rText.isEmpty {
                    if state.reasoningField == nil { state.reasoningField = field }
                    state.reasoningTextObserved = true
                    let meta: AIProtocolUtils.ProviderMetadata = [state.providerMetadataKey: ["reasoningField": .string(field)]]
                    state.lifecycle = AIProtocolUtils.Lifecycle.reasoningDelta(state.lifecycle, events: &events, id: "reasoning-0", text: rText, providerMetadata: meta)
                    state.reasoningEmitted = true
                    break
                }
            }
            if let opaque = AIProtocolUtils.JSONCodec.stringValue(delta?["reasoning_opaque"]), !opaque.isEmpty {
                state.reasoningOpaque = opaque
            }
            if let text = AIProtocolUtils.JSONCodec.stringValue(delta?["content"]), !text.isEmpty {
                state.lifecycle = AIProtocolUtils.Lifecycle.textDelta(state.lifecycle, events: &events, id: "text-0", text: text)
            }
            if let refusal = AIProtocolUtils.JSONCodec.stringValue(delta?["refusal"]), !refusal.isEmpty {
                state.lifecycle = AIProtocolUtils.Lifecycle.textDelta(state.lifecycle, events: &events, id: "text-0", text: refusal)
            }

            // Tool call deltas
            let toolDeltas = (AIProtocolUtils.JSONCodec.arrayValue(delta?["tool_calls"]) ?? []).compactMap(AIProtocolUtils.JSONCodec.objectValue)
            for (pos, tc) in toolDeltas.enumerated() {
                let rawID = AIProtocolUtils.JSONCodec.stringValue(tc["id"]).flatMap { $0.isEmpty ? nil : $0 }
                let fnObj = AIProtocolUtils.JSONCodec.objectValue(tc["function"])
                let customObj = AIProtocolUtils.JSONCodec.objectValue(tc["custom"])
                let rawName = AIProtocolUtils.JSONCodec.stringValue(fnObj?["name"]).flatMap { $0.isEmpty ? nil : $0 }
                    ?? AIProtocolUtils.JSONCodec.stringValue(customObj?["name"]).flatMap { $0.isEmpty ? nil : $0 }
                let index = AIProtocolUtils.JSONCodec.intValue(tc["index"]) ?? (toolDeltas.count > 1 ? pos : (state.latestToolIndex ?? pos))
                state.latestToolIndex = index
                state.nextToolIndex = max(state.nextToolIndex, index + 1)

                let current = state.tools[index]
                let pending = state.pendingTools[index]
                let resolvedID = current?.id ?? pending?.id ?? rawID
                let resolvedName = current?.name ?? pending?.name ?? rawName
                let isCustom = customObj != nil
                let opening = isCustom && !state.customCalls.contains(index)
                if opening { state.customCalls.insert(index) }
                let fragment: String
                if isCustom {
                    let rawIn = AIProtocolUtils.JSONCodec.stringValue(customObj?["input"]) ?? ""
                    fragment = opening ? OpenAIFreeform.streamStart(state.custom[resolvedName ?? ""], raw: rawIn) : OpenAIFreeform.streamDelta(rawIn)
                } else {
                    fragment = AIProtocolUtils.JSONCodec.stringValue(fnObj?["arguments"]) ?? ""
                }
                let combinedArgs = (pending?.input ?? "") + fragment
                if current == nil && (resolvedID == nil || resolvedName == nil) {
                    state.pendingTools[index] = PendingToolDelta(id: resolvedID, name: resolvedName, input: combinedArgs, thoughtSignature: nil)
                    continue
                }
                state.pendingTools.removeValue(forKey: index)
                let res = AIProtocolUtils.ToolStream.appendOrStart(
                    route: adapterID,
                    tools: state.tools,
                    key: index,
                    id: resolvedID,
                    name: resolvedName,
                    text: combinedArgs,
                    missingToolMessage: "OpenAI Chat tool call delta is missing id or name"
                )
                switch res {
                case .error(let err): throw err
                case .ok(let outcome):
                    state.tools = outcome.tools
                    if !outcome.events.isEmpty {
                        state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                    }
                    events.append(contentsOf: outcome.events)
                }
            }

            if let newFinish, state.finishReason == nil {
                state.finishReason = newFinish
                let incomplete = newFinish.normalized == .contentFilter || newFinish.normalized == .length
                if !incomplete && !state.tools.isEmpty {
                    let closed = OpenAIFreeform.close(tools: state.tools, keys: Array(state.customCalls).sorted())
                    let finished = try AIProtocolUtils.ToolStream.finishAll(route: adapterID, tools: closed.tools)
                    state.tools = finished.tools
                    state.toolCallEvents = closed.events + finished.events
                }
            }
            return events
        }

        // parity: ai/src/protocols/openai-chat.ts#finishEvents [status=implemented hash=67ed75f4ebe3]
        public static func finishEvents(state: ParserState) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            if state.finishReason == nil && state.requireFinishReason {
                throw AIProtocolUtils.ProtocolError(
                    kind: .invalidProviderOutput,
                    message: "OpenAI Chat stream ended without finish_reason",
                    route: adapterID,
                    classification: "incomplete-stream"
                )
            }
            var events: [AIProtocolUtils.LLMEvent] = []
            var toolEvents = state.toolCallEvents
            if state.finishReason == nil && !state.tools.isEmpty {
                let closed = OpenAIFreeform.close(tools: state.tools, keys: Array(state.customCalls).sorted())
                let finished = try AIProtocolUtils.ToolStream.finishAll(route: adapterID, tools: closed.tools)
                toolEvents = closed.events + finished.events
            }
            let hasToolCalls = !toolEvents.isEmpty
            let reason: AIProtocolUtils.FinishReasonDetails
            if let fr = state.finishReason {
                let norm: AIProtocolUtils.FinishReason = (fr.normalized == .stop && hasToolCalls) ? .toolCalls : fr.normalized
                reason = AIProtocolUtils.FinishReasonDetails(normalized: norm, raw: fr.raw, category: fr.category, explanation: fr.explanation)
            } else {
                reason = AIProtocolUtils.FinishReasonDetails(normalized: hasToolCalls ? .toolCalls : .stop)
            }
            var lifecycle = state.lifecycle
            var rMeta: [String: JSONValue] = [:]
            if let rf = state.reasoningField { rMeta["reasoningField"] = .string(rf) }
            if let op = state.reasoningOpaque { rMeta["reasoningOpaque"] = .string(op) }
            lifecycle = AIProtocolUtils.Lifecycle.reasoningEnd(
                lifecycle,
                events: &events,
                id: "reasoning-0",
                providerMetadata: rMeta.isEmpty ? nil : [state.providerMetadataKey: rMeta]
            )
            if !toolEvents.isEmpty {
                lifecycle = AIProtocolUtils.Lifecycle.stepStart(lifecycle, events: &events)
                events.append(contentsOf: toolEvents)
            }
            _ = AIProtocolUtils.Lifecycle.finish(lifecycle, events: &events, reason: reason, usage: state.usage)
            return events
        }

        public struct StreamDecoder: IncrementalStreamDecoder, Sendable {
            private var sse = AIProtocolUtils.SSEParser()
            private var state: ParserState
            private var finished = false

            public init(request: AIProtocolUtils.LLMRequest) {
                self.state = ParserState(request: request)
            }

            public mutating func feed(_ bytes: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                try process(sse.feed(bytes))
            }

            public mutating func finish() throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                var events = try process(sse.finish())
                if !finished {
                    finished = true
                    events.append(contentsOf: try finishEvents(state: state))
                }
                return events
            }

            private mutating func process(_ frames: [AIProtocolUtils.SSEFrame]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                var events: [AIProtocolUtils.LLMEvent] = []
                for frame in frames {
                    if finished { break }
                    let trimmed = frame.data.trimmingASCIIWhitespace()
                    if trimmed == "[DONE]" {
                        finished = true
                        events.append(contentsOf: try finishEvents(state: state))
                        break
                    }
                    if trimmed.isEmpty || trimmed == ": keepalive" { continue }
                    let decoded = try AIProtocolUtils.ProviderShared.parseJson(
                        route: adapterID,
                        input: trimmed,
                        message: "Invalid OpenAI Chat SSE JSON"
                    )
                    guard let obj = AIProtocolUtils.JSONCodec.objectValue(decoded) else { continue }
                    events.append(contentsOf: try step(state: &state, event: obj))
                }
                return events
            }
        }

        public static func parseSSEStream(
            _ bytes: [UInt8],
            request: AIProtocolUtils.LLMRequest
        ) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            var decoder = StreamDecoder(request: request)
            return try decoder.feed(bytes) + decoder.finish()
        }

        // parity: ai/src/protocols/openai-chat.ts#protocol [status=implemented hash=c3964d88f6d6]
        public static let `protocol` = ChatProtocolSpec(
            id: adapterID,
            framing: .sseWithDone,
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in try fromRequest(req) },
            parseStream: parseSSEStream,
            makeStreamDecoder: { StreamDecoder(request: $0) }
        )

        // parity: ai/src/protocols/openai-chat.ts#framing [status=implemented hash=b470ea06f479]
        public static let framing: FramingKind = .sseWithDone

        // parity: ai/src/protocols/openai-chat.ts#httpTransport [status=adapted hash=77d65b0eabbd]
        public static let httpTransport: FramingKind = .sseWithDone

        // parity: ai/src/protocols/openai-chat.ts#route [status=implemented hash=ff1bf9d58b59]
        public static let route = ChatRouteSpec(
            id: adapterID,
            provider: "openai",
            providerMetadataKey: "openai",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )
    }

    // MARK: - OpenAICompatibleChat & OpenAICompatibleResponses (2 symbols)

    public enum OpenAICompatibleChat {
        // parity: ai/src/protocols/openai-compatible-chat.ts#route [status=implemented hash=eb499ff0e073]
        public static let route = ChatRouteSpec(
            id: "openai-compatible-chat",
            provider: "openai-compatible",
            providerMetadataKey: "openai",
            protocol: OpenAIChat.`protocol`,
            defaultBaseURL: nil,
            path: OpenAIChat.PATH
        )
    }

    public enum OpenAICompatibleResponses {
        // parity: ai/src/protocols/openai-compatible-responses.ts#route [status=implemented hash=a4bd854fd153]
        public static let route = ChatRouteSpec(
            id: "openai-compatible-responses",
            provider: "openai-compatible",
            providerMetadataKey: "openresponses",
            protocol: OpenResponses.`protocol`,
            defaultBaseURL: nil,
            path: OpenResponses.PATH,
            defaultProviderOptions: [
                "store": .bool(false),
                "include": .array([.string("reasoning.encrypted_content")]),
            ]
        )
    }

    // MARK: - Gemini (packages/ai/src/protocols/gemini.ts — 8 symbols)

    public enum Gemini {
        public static let adapterID = "gemini"
        public static let minThinkingBudget = 512
        public static let skipThoughtSignatureValidator = "skip_thought_signature_validator"

        // parity: ai/src/protocols/gemini.ts#DEFAULT_BASE_URL [status=implemented hash=ae7b30027e03]
        public static let DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

        // parity: ai/src/protocols/gemini.ts#OptionsInput [status=implemented hash=f75e9b8ed22c]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var cachedContent: String?
            public var serviceTier: String?
            public var thinkingBudget: Int?
            public var includeThoughts: Bool?
            public var thinkingLevel: String?

            public init(
                cachedContent: String? = nil,
                serviceTier: String? = nil,
                thinkingBudget: Int? = nil,
                includeThoughts: Bool? = nil,
                thinkingLevel: String? = nil
            ) {
                self.cachedContent = cachedContent
                self.serviceTier = serviceTier
                self.thinkingBudget = thinkingBudget
                self.includeThoughts = includeThoughts
                self.thinkingLevel = thinkingLevel
            }
        }

        // parity: ai/src/protocols/gemini.ts#ProviderOptionsInput [status=implemented hash=b8c6e72d7d57]
        public typealias ProviderOptionsInput = OptionsInput

        // parity: ai/src/protocols/gemini.ts#GeminiBody [status=implemented hash=7a1167e09e63]
        public typealias GeminiBody = [String: JSONValue]

        // parity: ai/src/protocols/gemini.ts#Prepared [status=implemented hash=251812ac091c]
        public struct Prepared: Equatable, Sendable {
            public let httpRequest: HTTPRequest
            public let body: GeminiBody

            public init(httpRequest: HTTPRequest, body: GeminiBody) {
                self.httpRequest = httpRequest
                self.body = body
            }
        }

        public struct ParserState: Equatable, Sendable {
            public let route: String
            public let providerMetadataKey: String
            public var finishReason: String?
            public var hasToolCalls: Bool
            public var promptFeedback: [String: JSONValue]?
            public var usage: [String: JSONValue]?
            public var lifecycle: AIProtocolUtils.Lifecycle.State
            public var reasoningSignature: String?
            public var textSignature: String?
            public var reasoningId: String?
            public var textId: String?
            public var nextReasoningId: Int
            public var nextTextId: Int
            public var seenCallIds: Set<String>

            public init(request: AIProtocolUtils.LLMRequest) {
                self.route = "\(request.model.provider)/\(request.model.routeID)"
                self.providerMetadataKey = request.model.providerMetadataKey ?? request.model.provider
                self.finishReason = nil
                self.hasToolCalls = false
                self.promptFeedback = nil
                self.usage = nil
                self.lifecycle = AIProtocolUtils.Lifecycle.initial()
                self.reasoningSignature = nil
                self.textSignature = nil
                self.reasoningId = nil
                self.textId = nil
                self.nextReasoningId = 0
                self.nextTextId = 0
                self.seenCallIds = []
            }
        }

        private static func omitsFunctionCallIds(_ modelID: String) -> Bool {
            let lower = modelID.lowercased()
            let prefix: String
            if lower.hasPrefix("gemini-live-") { prefix = "gemini-live-" }
            else if lower.hasPrefix("gemini-") { prefix = "gemini-" }
            else { return false }
            let rest = lower.dropFirst(prefix.count)
            let digits = rest.prefix { $0 >= "0" && $0 <= "9" }
            guard let major = Int(digits) else { return false }
            return major < 3
        }

        public static func fromRequest(_ request: AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> GeminiBody {
            let flattened = AIProtocolUtils.ProviderShared.flattenToolRequest(request)
            let opts = request.providerOptions ?? [:]
            let metaKey = request.model.providerMetadataKey ?? request.model.provider
            let omitCallIds = omitsFunctionCallIds(request.model.id)

            var contents: [[String: JSONValue]] = []
            for message in flattened.request.messages {
                switch message.role {
                case .system:
                    let wrapped = try AIProtocolUtils.ProviderShared.wrappedSystemUpdate(route: "Gemini", message: message)
                    contents.append(["role": .string("user"), "parts": .array([.object(["text": .string(wrapped.text)])])])

                case .user:
                    var parts: [JSONValue] = []
                    for part in message.content {
                        switch part {
                        case .text(let tp):
                            parts.append(.object(["text": .string(tp.text)]))
                        case .media(let mp):
                            parts.append(.object(try AIProtocolUtils.GeminiGenerateContent.mediaPart(route: "Gemini", asset: mp.media)))
                        default:
                            break
                        }
                    }
                    contents.append(["role": .string("user"), "parts": .array(parts)])

                case .assistant:
                    var parts: [JSONValue] = []
                    var hasSignedCall = false
                    for part in message.content {
                        switch part {
                        case .text(let tp):
                            var obj: [String: JSONValue] = ["text": .string(tp.text)]
                            if let sig = AIProtocolUtils.JSONCodec.stringValue(tp.providerMetadata?[metaKey]?["thoughtSignature"]) {
                                obj["thoughtSignature"] = .string(sig)
                            }
                            parts.append(.object(obj))
                        case .reasoning(let rp):
                            var obj: [String: JSONValue] = ["text": .string(rp.text), "thought": .bool(true)]
                            if let sig = AIProtocolUtils.JSONCodec.stringValue(rp.providerMetadata?[metaKey]?["thoughtSignature"]) {
                                obj["thoughtSignature"] = .string(sig)
                            }
                            parts.append(.object(obj))
                        case .media(let mp):
                            var obj = try AIProtocolUtils.GeminiGenerateContent.mediaPart(route: "Gemini", asset: mp.media)
                            if let sig = AIProtocolUtils.JSONCodec.stringValue(mp.providerMetadata?[metaKey]?["thoughtSignature"]) {
                                obj["thoughtSignature"] = .string(sig)
                            }
                            parts.append(.object(obj))
                        case .toolCall(let tc):
                            var fc: [String: JSONValue] = ["name": .string(tc.name), "args": tc.input]
                            if !omitCallIds { fc["id"] = .string(tc.id) }
                            var obj: [String: JSONValue] = ["functionCall": .object(fc)]
                            if let sig = AIProtocolUtils.JSONCodec.stringValue(tc.providerMetadata?[metaKey]?["thoughtSignature"]) {
                                obj["thoughtSignature"] = .string(sig)
                                hasSignedCall = true
                            } else if !hasSignedCall {
                                obj["thoughtSignature"] = .string(skipThoughtSignatureValidator)
                            }
                            parts.append(.object(obj))
                        default:
                            throw AIProtocolUtils.ProviderShared.unsupportedContent(
                                route: "Gemini",
                                role: .assistant,
                                types: ["text", "reasoning", "tool-call", "media"]
                            )
                        }
                    }
                    contents.append(["role": .string("model"), "parts": .array(parts)])

                case .tool:
                    var parts: [JSONValue] = []
                    for part in message.content {
                        guard case .toolResult(let tr) = part else { continue }
                        var fr: [String: JSONValue] = [
                            "name": .string(tr.name),
                            "response": .object([
                                "name": .string(tr.name),
                                "content": .string(AIProtocolUtils.ProviderShared.toolResultText(tr)),
                            ]),
                        ]
                        if !omitCallIds { fr["id"] = .string(tr.id) }
                        parts.append(.object(["functionResponse": .object(fr)]))
                    }
                    if let last = contents.last, case .string("user") = last["role"],
                       case .array(let prev) = last["parts"],
                       prev.contains(where: { AIProtocolUtils.JSONCodec.objectValue($0)?["functionResponse"] != nil }) {
                        contents[contents.count - 1]["parts"] = .array(prev + parts)
                    } else {
                        contents.append(["role": .string("user"), "parts": .array(parts)])
                    }
                }
            }

            var body: GeminiBody = ["contents": .array(contents.map(JSONValue.object))]
            if let cached = AIProtocolUtils.JSONCodec.stringValue(opts["cachedContent"]) { body["cachedContent"] = .string(cached) }
            if let safety = opts["safetySettings"] { body["safetySettings"] = safety }
            if let tier = AIProtocolUtils.JSONCodec.stringValue(opts["serviceTier"]) { body["serviceTier"] = .string(tier) }
            if !request.system.isEmpty {
                body["systemInstruction"] = .object([
                    "parts": .array(request.system.map { .object(["text": .string($0.text)]) }),
                ])
            }
            if !flattened.tools.isEmpty {
                let decls: [JSONValue] = flattened.tools.map { tool in
                    let normalized = AIProtocolUtils.ToolSchemaProjection.gemini(AIProtocolUtils.ToolSchemaProjection.objectRoot(tool.inputSchema))
                    return .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parametersJsonSchema": .object(normalized),
                    ])
                }
                body["tools"] = .array([.object(["functionDeclarations": .array(decls)])])
                if let tc = request.toolChoice {
                    body["toolConfig"] = try AIProtocolUtils.ProviderShared.matchToolChoice(
                        route: "Gemini",
                        toolChoice: tc,
                        auto: { .object(["functionCallingConfig": .object(["mode": .string("AUTO")])]) },
                        none: { .object(["functionCallingConfig": .object(["mode": .string("NONE")])]) },
                        required: { .object(["functionCallingConfig": .object(["mode": .string("ANY")])]) },
                        tool: { name in
                            .object(["functionCallingConfig": .object(["mode": .string("ANY"), "allowedFunctionNames": .array([.string(name)])])])
                        }
                    )
                }
            }

            var genConfig: [String: JSONValue] = [:]
            if let maxT = request.maxTokens { genConfig["maxOutputTokens"] = .int(Int64(maxT)) }
            if let temp = request.temperature { genConfig["temperature"] = .double(temp) }
            if let topP = request.topP { genConfig["topP"] = .double(topP) }
            if let topK = request.topK { genConfig["topK"] = .int(Int64(topK)) }
            if let fp = request.frequencyPenalty { genConfig["frequencyPenalty"] = .double(fp) }
            if let pp = request.presencePenalty { genConfig["presencePenalty"] = .double(pp) }
            if let seed = request.seed { genConfig["seed"] = .int(Int64(seed)) }
            if let stop = request.stop, !stop.isEmpty { genConfig["stopSequences"] = .array(stop.map(JSONValue.string)) }
            if let tc = AIProtocolUtils.JSONCodec.objectValue(opts["thinkingConfig"]) {
                var outTC = tc
                if outTC["includeThoughts"] == nil { outTC["includeThoughts"] = .bool(true) }
                if let budget = AIProtocolUtils.JSONCodec.intValue(tc["thinkingBudget"]) {
                    let fitted = AIProtocolUtils.ProviderShared.fitThinkingBudget(budget, maxTokens: request.maxTokens, minimum: minThinkingBudget)
                    outTC["thinkingBudget"] = .int(Int64(fitted))
                }
                genConfig["thinkingConfig"] = .object(outTC)
            }
            if !genConfig.isEmpty { body["generationConfig"] = .object(genConfig) }
            return body
        }

        public static func mapFinishReason(_ reason: String?, hasToolCalls: Bool) -> AIProtocolUtils.FinishReason {
            guard let reason else { return hasToolCalls ? .toolCalls : .unknown }
            if reason == "STOP" { return hasToolCalls ? .toolCalls : .stop }
            if reason == "MAX_TOKENS" { return .length }
            if AIProtocolUtils.GeminiGenerateContent.contentFiltered(reason) { return .contentFilter }
            let errorReasons: Set<String> = [
                "MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL", "NO_IMAGE",
                "TOO_MANY_TOOL_CALLS", "MISSING_THOUGHT_SIGNATURE", "MALFORMED_RESPONSE",
            ]
            if errorReasons.contains(reason) { return .error }
            return .unknown
        }

        private static func mapUsage(_ u: [String: JSONValue]?, key: String) -> AIProtocolUtils.Usage? {
            guard let u else { return nil }
            let prompt = AIProtocolUtils.ProviderShared.sumTokens(
                AIProtocolUtils.JSONCodec.doubleValue(u["promptTokenCount"]),
                AIProtocolUtils.JSONCodec.doubleValue(u["toolUsePromptTokenCount"])
            )
            let cached = AIProtocolUtils.JSONCodec.doubleValue(u["cachedContentTokenCount"])
            let thoughts = AIProtocolUtils.JSONCodec.doubleValue(u["thoughtsTokenCount"])
            let visible = AIProtocolUtils.JSONCodec.doubleValue(u["candidatesTokenCount"])
            let nonCached = AIProtocolUtils.ProviderShared.subtractTokens(prompt, cached)
            let output = visible.map { $0 + (thoughts ?? 0) }
            let billing = AIProtocolUtils.ProviderShared.reportedBilling(usage: .object(u))
            return AIProtocolUtils.Usage(
                inputTokens: prompt,
                outputTokens: output,
                nonCachedInputTokens: nonCached,
                cacheReadInputTokens: cached,
                reasoningTokens: thoughts,
                totalTokens: AIProtocolUtils.ProviderShared.totalTokens(prompt, output, AIProtocolUtils.JSONCodec.doubleValue(u["totalTokenCount"])),
                cost: billing.cost,
                providerMetadata: [key: u]
            )
        }

        public static func step(
            state: inout ParserState,
            event: [String: JSONValue]
        ) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            if let err = AIProtocolUtils.JSONCodec.objectValue(event["error"]) {
                let msg = AIProtocolUtils.JSONCodec.stringValue(err["message"])
                    ?? AIProtocolUtils.JSONCodec.stringValue(err["status"])
                    ?? "Gemini provider error"
                let code = AIProtocolUtils.JSONCodec.intValue(err["code"])
                throw AIProtocolUtils.ProtocolError(kind: code == 429 ? .rateLimit : .providerInternal, message: msg, route: state.route, statusCode: code, body: AIProtocolUtils.JSONCodec.encodeObject(event))
            }
            if let fb = AIProtocolUtils.JSONCodec.objectValue(event["promptFeedback"]) { state.promptFeedback = fb }
            if let u = AIProtocolUtils.JSONCodec.objectValue(event["usageMetadata"]) { state.usage = u }

            let candidate = AIProtocolUtils.JSONCodec.arrayValue(event["candidates"])?.first.flatMap(AIProtocolUtils.JSONCodec.objectValue)
            if let fr = AIProtocolUtils.JSONCodec.stringValue(candidate?["finishReason"]),
               !fr.isEmpty, fr != "FINISH_REASON_UNSPECIFIED" {
                state.finishReason = fr
                if mapFinishReason(fr, hasToolCalls: state.hasToolCalls) == .error {
                    throw AIProtocolUtils.ProtocolError(kind: .invalidProviderOutput, message: "Gemini stopped with \(fr)", route: state.route, body: AIProtocolUtils.JSONCodec.encodeObject(event))
                }
            }

            guard let content = AIProtocolUtils.JSONCodec.objectValue(candidate?["content"]),
                  let parts = AIProtocolUtils.JSONCodec.arrayValue(content["parts"]) else {
                return []
            }

            var events: [AIProtocolUtils.LLMEvent] = []
            func signed(_ sig: String?) -> AIProtocolUtils.ProviderMetadata? {
                sig.map { [state.providerMetadataKey: ["thoughtSignature": .string($0)]] }
            }
            func endReasoning() {
                guard let rid = state.reasoningId else { return }
                state.lifecycle = AIProtocolUtils.Lifecycle.reasoningEnd(state.lifecycle, events: &events, id: rid, providerMetadata: signed(state.reasoningSignature))
                state.reasoningId = nil
                state.reasoningSignature = nil
            }
            func endText() {
                guard let tid = state.textId else { return }
                state.lifecycle = AIProtocolUtils.Lifecycle.textEnd(state.lifecycle, events: &events, id: tid, providerMetadata: signed(state.textSignature))
                state.textId = nil
                state.textSignature = nil
            }

            for rawPart in parts {
                guard let part = AIProtocolUtils.JSONCodec.objectValue(rawPart) else { continue }
                let sig = AIProtocolUtils.JSONCodec.stringValue(part["thoughtSignature"])
                if let inlineData = AIProtocolUtils.JSONCodec.objectValue(part["inlineData"]),
                   let data = AIProtocolUtils.JSONCodec.stringValue(inlineData["data"]),
                   let mime = AIProtocolUtils.JSONCodec.stringValue(inlineData["mimeType"]) {
                    state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                    events.append(.media(media: AIProtocolUtils.MediaAsset.base64(data, mediaType: mime), providerMetadata: signed(sig)))
                    continue
                }
                if let text = AIProtocolUtils.JSONCodec.stringValue(part["text"]), !text.isEmpty {
                    let isThought = AIProtocolUtils.JSONCodec.boolValue(part["thought"]) == true
                    if isThought {
                        endText()
                        if let sig { state.reasoningSignature = sig }
                        if state.reasoningId == nil {
                            state.reasoningId = "reasoning-\(state.nextReasoningId)"
                            state.nextReasoningId += 1
                        }
                        state.lifecycle = AIProtocolUtils.Lifecycle.reasoningDelta(state.lifecycle, events: &events, id: state.reasoningId!, text: text, providerMetadata: signed(sig))
                    } else {
                        endReasoning()
                        if let sig { state.textSignature = sig }
                        if state.textId == nil {
                            state.textId = "text-\(state.nextTextId)"
                            state.nextTextId += 1
                        }
                        state.lifecycle = AIProtocolUtils.Lifecycle.textDelta(state.lifecycle, events: &events, id: state.textId!, text: text, providerMetadata: signed(state.textSignature))
                        state.textSignature = nil
                    }
                    continue
                }
                if let fc = AIProtocolUtils.JSONCodec.objectValue(part["functionCall"]),
                   let fnName = AIProtocolUtils.JSONCodec.stringValue(fc["name"]) {
                    let args = fc["args"] ?? .object([:])
                    let supplied = AIProtocolUtils.JSONCodec.stringValue(fc["id"])
                    let callID: String
                    if let supplied, !state.seenCallIds.contains(supplied) {
                        state.seenCallIds.insert(supplied)
                        callID = supplied
                    } else {
                        callID = "tool_\(uuid().replacingOccurrences(of: "-", with: ""))"
                    }
                    endReasoning()
                    endText()
                    state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                    events.append(.toolCall(id: callID, name: fnName, input: args, providerMetadata: signed(sig)))
                    state.hasToolCalls = true
                }
            }
            return events
        }

        public static func finish(state: ParserState) -> [AIProtocolUtils.LLMEvent] {
            let blockReason = state.finishReason == nil ? AIProtocolUtils.JSONCodec.stringValue(state.promptFeedback?["blockReason"]) : nil
            let effectiveReason = state.finishReason ?? blockReason
            if effectiveReason == nil && state.usage == nil { return [] }
            var events: [AIProtocolUtils.LLMEvent] = []
            var lifecycle = state.lifecycle
            if let rid = state.reasoningId {
                let meta: AIProtocolUtils.ProviderMetadata? = state.reasoningSignature.map { [state.providerMetadataKey: ["thoughtSignature": .string($0)]] }
                lifecycle = AIProtocolUtils.Lifecycle.reasoningEnd(lifecycle, events: &events, id: rid, providerMetadata: meta)
            }
            if let tid = state.textId {
                let meta: AIProtocolUtils.ProviderMetadata? = state.textSignature.map { [state.providerMetadataKey: ["thoughtSignature": .string($0)]] }
                lifecycle = AIProtocolUtils.Lifecycle.textEnd(lifecycle, events: &events, id: tid, providerMetadata: meta)
            }
            let normalized: AIProtocolUtils.FinishReason = blockReason != nil
                ? .contentFilter
                : mapFinishReason(effectiveReason, hasToolCalls: state.hasToolCalls)
            let finishMeta: AIProtocolUtils.ProviderMetadata? = state.promptFeedback.map {
                [state.providerMetadataKey: ["promptFeedback": .object($0)]]
            }
            _ = AIProtocolUtils.Lifecycle.finish(
                lifecycle,
                events: &events,
                reason: AIProtocolUtils.FinishReasonDetails(normalized: normalized, raw: effectiveReason),
                usage: mapUsage(state.usage, key: state.providerMetadataKey),
                providerMetadata: finishMeta
            )
            return events
        }

        public struct StreamDecoder: IncrementalStreamDecoder, Sendable {
            private var sse = AIProtocolUtils.SSEParser()
            private var state: ParserState
            private var finished = false

            public init(request: AIProtocolUtils.LLMRequest) {
                self.state = ParserState(request: request)
            }

            public mutating func feed(_ bytes: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                try process(sse.feed(bytes))
            }

            public mutating func finish() throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                var events = try process(sse.finish())
                if !finished {
                    finished = true
                    events.append(contentsOf: Gemini.finish(state: state))
                }
                return events
            }

            private mutating func process(_ frames: [AIProtocolUtils.SSEFrame]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                var events: [AIProtocolUtils.LLMEvent] = []
                for frame in frames {
                    let trimmed = frame.data.trimmingASCIIWhitespace()
                    if trimmed.isEmpty || trimmed == "[DONE]" || trimmed == ": keepalive" { continue }
                    let decoded = try AIProtocolUtils.ProviderShared.parseJson(route: adapterID, input: trimmed, message: "Invalid Gemini stream event")
                    guard let obj = AIProtocolUtils.JSONCodec.objectValue(decoded) else { continue }
                    events.append(contentsOf: try step(state: &state, event: obj))
                }
                return events
            }
        }

        public static func parseSSEStream(
            _ bytes: [UInt8],
            request: AIProtocolUtils.LLMRequest
        ) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            var decoder = StreamDecoder(request: request)
            return try decoder.feed(bytes) + decoder.finish()
        }

        // parity: ai/src/protocols/gemini.ts#transport [status=adapted hash=045e6aedc22c]
        public static let transport: FramingKind = .sse

        // parity: ai/src/protocols/gemini.ts#protocol [status=implemented hash=24c40fee3e9d]
        public static let `protocol` = ChatProtocolSpec(
            id: adapterID,
            framing: .sse,
            sanitizer: "gemini",
            buildBody: fromRequest,
            parseStream: parseSSEStream,
            makeStreamDecoder: { StreamDecoder(request: $0) }
        )

        // parity: ai/src/protocols/gemini.ts#route [status=implemented hash=7b1e9d41b25d]
        public static let route = ChatRouteSpec(
            id: adapterID,
            provider: "google",
            providerMetadataKey: "google",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            pathBuilder: { req, _ in "/models/\(req.model.id):streamGenerateContent?alt=sse" }
        )
    }

    // MARK: - BedrockConverse (packages/ai/src/protocols/bedrock-converse.ts — 4 symbols)

    public enum BedrockConverse {
        public static let adapterID = "bedrock-converse"
        public static let minThinkingBudget = 1_024

        // parity: ai/src/protocols/bedrock-converse.ts#BedrockConverseBody [status=implemented hash=7847cb17cab5]
        public typealias BedrockConverseBody = [String: JSONValue]

        // parity: ai/src/protocols/bedrock-converse.ts#OptionsInput [status=implemented hash=f75e9b8ed22c]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var effort: String?
            public var serviceTier: String?
            public var requestMetadata: [String: String]?

            public init(effort: String? = nil, serviceTier: String? = nil, requestMetadata: [String: String]? = nil) {
                self.effort = effort
                self.serviceTier = serviceTier
                self.requestMetadata = requestMetadata
            }
        }

        public struct ParserState: Equatable, Sendable {
            public let providerMetadataKey: String
            public var tools: AIProtocolUtils.ToolStream.State<Int>
            public var finishReason: AIProtocolUtils.FinishReasonDetails?
            public var usage: AIProtocolUtils.Usage?
            public var hasToolCalls: Bool
            public var lifecycle: AIProtocolUtils.Lifecycle.State
            public var reasoningSignatures: [Int: String]
            public var reasoningRedactedContent: [Int: [[UInt8]]]

            public init(providerMetadataKey: String) {
                self.providerMetadataKey = providerMetadataKey
                self.tools = AIProtocolUtils.ToolStream.empty()
                self.finishReason = nil
                self.usage = nil
                self.hasToolCalls = false
                self.lifecycle = AIProtocolUtils.Lifecycle.initial()
                self.reasoningSignatures = [:]
                self.reasoningRedactedContent = [:]
            }
        }

        private static func removeEmptyToolInputKeys(_ value: JSONValue) -> JSONValue {
            switch value {
            case .array(let items):
                return .array(items.map(removeEmptyToolInputKeys))
            case .object(let obj):
                var out: [String: JSONValue] = [:]
                for (k, v) in obj where !k.isEmpty {
                    out[k] = removeEmptyToolInputKeys(v)
                }
                return .object(out)
            default:
                return value
            }
        }

        private static func scrubToolName(_ name: String) -> String {
            // Converse rejects replayed names over 64 characters; flattenToolRequest already fixed invalid characters.
            String(name.prefix(64))
        }

        private static func effortFields(modelID: String, effort: String) -> [String: JSONValue] {
            if modelID.contains("anthropic") { return ["output_config": .object(["effort": .string(effort)])] }
            if modelID.contains("openai.gpt-oss") { return ["reasoning_effort": .string(effort)] }
            if modelID.contains("openai.") || modelID.contains("xai.") { return ["reasoning": .object(["effort": .string(effort)])] }
            return ["reasoningConfig": .object(["type": .string("enabled"), "maxReasoningEffort": .string(effort)])]
        }

        private static func supportsAdaptiveThinking(_ modelID: String) -> Bool {
            guard let v = AIProtocolUtils.ClaudeModel.claudeVersion(modelID) else { return false }
            return v.major > 4 || (v.major == 4 && v.minor >= 6)
        }

        public static func fromRequest(_ request: AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> BedrockConverseBody {
            let flattened = AIProtocolUtils.ProviderShared.flattenToolRequest(request)
            let opts = request.providerOptions ?? [:]
            let metaKey = request.model.providerMetadataKey ?? request.model.provider
            var breakpoints = AIProtocolUtils.BedrockCache.breakpoints(for: request.model)
            var mistralNormalizer = request.model.id.contains("mistral.") ? AIProtocolUtils.MistralToolID.normalizer(for: request) : nil
            func normalizeID(_ id: String) -> String {
                if mistralNormalizer != nil {
                    return mistralNormalizer!.normalize(id)
                }
                return id
            }

            func textWithCache(_ text: String, cache: AIProtocolUtils.CacheHint?) -> [JSONValue] {
                if let cp = AIProtocolUtils.BedrockCache.block(&breakpoints, cache: cache) {
                    return [.object(["text": .string(text)]), cp.jsonValue]
                }
                return [.object(["text": .string(text)])]
            }

            // 1. Tool config (highest cache priority)
            var toolConfigJSON: JSONValue? = nil
            if !flattened.tools.isEmpty {
                var toolList: [JSONValue] = []
                for tool in flattened.tools {
                    var spec: [String: JSONValue] = [
                        "name": .string(tool.name),
                        "inputSchema": .object(["json": .object(tool.inputSchema)]),
                    ]
                    if !tool.description.trimmingASCIIWhitespace().isEmpty {
                        spec["description"] = .string(tool.description)
                    }
                    toolList.append(.object(["toolSpec": .object(spec)]))
                    if let cp = AIProtocolUtils.BedrockCache.block(&breakpoints, cache: tool.cache) {
                        toolList.append(cp.jsonValue)
                    }
                }
                var cfg: [String: JSONValue] = ["tools": .array(toolList)]
                if let tc = request.toolChoice {
                    let choice: JSONValue? = try AIProtocolUtils.ProviderShared.matchToolChoice(
                        route: "Bedrock Converse",
                        toolChoice: tc,
                        auto: { .object(["auto": .object([:])]) },
                        none: { nil },
                        required: { .object(["any": .object([:])]) },
                        tool: { name in .object(["tool": .object(["name": .string(name)])]) }
                    )
                    if let choice { cfg["toolChoice"] = choice }
                }
                toolConfigJSON = .object(cfg)
            }

            // 2. System blocks
            let systemBlocks: [JSONValue] = request.system
                .filter { !$0.text.isEmpty }
                .flatMap { textWithCache($0.text, cache: $0.cache) }

            // 3. Messages
            var messages: [[String: JSONValue]] = []
            var documentNames = Set<String>()
            func appendToUser(_ blocks: [JSONValue]) {
                if let last = messages.last, case .string("user") = last["role"],
                   case .array(let prev) = last["content"] {
                    messages[messages.count - 1]["content"] = .array(prev + blocks)
                } else if !blocks.isEmpty {
                    messages.append(["role": .string("user"), "content": .array(blocks)])
                }
            }

            for message in flattened.request.messages {
                switch message.role {
                case .system:
                    let wrapped = try AIProtocolUtils.ProviderShared.wrappedSystemUpdate(route: "Bedrock Converse", message: message)
                    appendToUser(textWithCache(wrapped.text, cache: wrapped.cache))

                case .user:
                    var content: [JSONValue] = []
                    for part in message.content {
                        switch part {
                        case .text(let tp):
                            content.append(contentsOf: textWithCache(tp.text, cache: tp.cache))
                        case .media(let mp):
                            content.append(contentsOf: try AIProtocolUtils.BedrockMedia.lower(mp, documentNames: &documentNames))
                        default:
                            break
                        }
                    }
                    appendToUser(content)

                case .assistant:
                    var content: [JSONValue] = []
                    for part in message.content {
                        switch part {
                        case .text(let tp):
                            content.append(contentsOf: textWithCache(tp.text, cache: tp.cache))
                        case .reasoning(let rp):
                            let sig = rp.encrypted ?? AIProtocolUtils.JSONCodec.stringValue(rp.providerMetadata?[metaKey]?["signature"])
                            let redacted = AIProtocolUtils.JSONCodec.stringValue(rp.providerMetadata?[metaKey]?["redactedData"])
                            if sig == nil, let redacted {
                                content.append(.object(["reasoningContent": .object(["redactedContent": .string(redacted)])]))
                            } else if let sig, !sig.trimmingASCIIWhitespace().isEmpty {
                                content.append(.object([
                                    "reasoningContent": .object([
                                        "reasoningText": .object(["text": .string(rp.text), "signature": .string(sig)]),
                                    ]),
                                ]))
                            }
                        case .toolCall(let tc):
                            content.append(.object([
                                "toolUse": .object([
                                    "toolUseId": .string(normalizeID(tc.id)),
                                    "name": .string(scrubToolName(tc.name)),
                                    "input": removeEmptyToolInputKeys(tc.input),
                                ]),
                            ]))
                        default:
                            throw AIProtocolUtils.ProviderShared.unsupportedContent(
                                route: "Bedrock Converse",
                                role: .assistant,
                                types: ["text", "reasoning", "tool-call"]
                            )
                        }
                    }
                    if !content.isEmpty {
                        messages.append(["role": .string("assistant"), "content": .array(content)])
                    }

                case .tool:
                    var content: [JSONValue] = []
                    for part in message.content {
                        guard case .toolResult(let tr) = part else { continue }
                        let items: [JSONValue]
                        switch tr.result {
                        case .text(let t): items = [.object(["text": .string(t)])]
                        case .error: items = [.object(["text": .string(AIProtocolUtils.ProviderShared.toolResultText(tr))])]
                        case .json(let j): items = [.object(["json": j])]
                        case .content(let list):
                            var built: [JSONValue] = []
                            for item in list {
                                switch item {
                                case .text(let t): built.append(.object(["text": .string(t)]))
                                case .file(let f):
                                    built.append(contentsOf: try AIProtocolUtils.BedrockMedia.lower(AIProtocolUtils.ProviderShared.toolFileMedia(f), documentNames: &documentNames))
                                }
                            }
                            items = built
                        }
                        let isErr: Bool
                        if case .error = tr.result { isErr = true } else { isErr = false }
                        content.append(.object([
                            "toolResult": .object([
                                "toolUseId": .string(normalizeID(tr.id)),
                                "content": .array(items),
                                "status": .string(isErr ? "error" : "success"),
                            ]),
                        ]))
                        if let cp = AIProtocolUtils.BedrockCache.block(&breakpoints, cache: tr.cache) {
                            content.append(cp.jsonValue)
                        }
                    }
                    appendToUser(content)
                }
            }

            // 4. Inference config & additionalModelRequestFields
            let effort = AIProtocolUtils.JSONCodec.stringValue(opts["effort"])
            let isNova2High = request.model.id.contains("amazon.nova-2-") && effort == "high"
            let maxTokens = isNova2High ? nil : request.maxTokens

            var inferenceConfig: [String: JSONValue] = [:]
            if let maxTokens { inferenceConfig["maxTokens"] = .int(Int64(maxTokens)) }
            if let temp = request.temperature { inferenceConfig["temperature"] = .double(temp) }
            if let topP = request.topP { inferenceConfig["topP"] = .double(topP) }
            if let stop = request.stop, !stop.isEmpty { inferenceConfig["stopSequences"] = .array(stop.map(JSONValue.string)) }

            var additional: [String: JSONValue] = [:]
            if let topK = request.topK { additional["top_k"] = .int(Int64(topK)) }
            var thinkingObj: [String: JSONValue]? = nil
            if let rawT = AIProtocolUtils.JSONCodec.objectValue(opts["thinking"]),
               let tType = AIProtocolUtils.JSONCodec.stringValue(rawT["type"]) {
                if tType == "enabled" {
                    let budget = AIProtocolUtils.JSONCodec.intValue(rawT["budgetTokens"]) ?? AIProtocolUtils.JSONCodec.intValue(rawT["budget_tokens"]) ?? minThinkingBudget
                    let fitted = AIProtocolUtils.ProviderShared.fitThinkingBudget(budget, maxTokens: maxTokens, minimum: minThinkingBudget)
                    thinkingObj = ["type": .string("enabled"), "budget_tokens": .int(Int64(fitted))]
                } else {
                    thinkingObj = rawT
                }
            } else if effort != nil && supportsAdaptiveThinking(request.model.id) {
                thinkingObj = ["type": .string("adaptive")]
            }
            if AIProtocolUtils.ClaudeModel.supportsThinkingBlockBinding(request.model),
               AIProtocolUtils.JSONCodec.stringValue(thinkingObj?["type"]) != "disabled" {
                var t = thinkingObj ?? ["type": .string("adaptive")]
                t["block_binding"] = .object(["prefix_mismatch_behavior": .string("drop_block")])
                thinkingObj = t
                additional["anthropic_beta"] = .array([.string(AIProtocolUtils.ClaudeModel.THINKING_BINDING_BETA)])
            }
            if let thinkingObj { additional["thinking"] = .object(thinkingObj) }
            if let effort {
                for (k, v) in effortFields(modelID: request.model.id, effort: effort) { additional[k] = v }
            }

            var body: BedrockConverseBody = [
                "modelId": .string(request.model.id),
                "messages": .array(messages.map(JSONValue.object)),
            ]
            if !systemBlocks.isEmpty { body["system"] = .array(systemBlocks) }
            if !inferenceConfig.isEmpty { body["inferenceConfig"] = .object(inferenceConfig) }
            if let toolConfigJSON { body["toolConfig"] = toolConfigJSON }
            if !additional.isEmpty { body["additionalModelRequestFields"] = .object(additional) }
            if let tier = AIProtocolUtils.JSONCodec.stringValue(opts["serviceTier"]) {
                body["serviceTier"] = .object(["type": .string(tier)])
            }
            if let reqMeta = opts["requestMetadata"] { body["requestMetadata"] = reqMeta }
            return body
        }

        public static func mapFinishReason(_ reason: String) -> AIProtocolUtils.FinishReason {
            switch reason {
            case "end_turn", "stop_sequence": return .stop
            case "max_tokens", "model_context_window_exceeded": return .length
            case "tool_use": return .toolCalls
            case "content_filtered", "guardrail_intervened": return .contentFilter
            default: return .unknown
            }
        }

        public static func step(
            state: inout ParserState,
            event: [String: JSONValue]
        ) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            if let startBlock = AIProtocolUtils.JSONCodec.objectValue(event["contentBlockStart"]),
               let idx = AIProtocolUtils.JSONCodec.intValue(startBlock["contentBlockIndex"]),
               let toolUse = AIProtocolUtils.JSONCodec.objectValue(AIProtocolUtils.JSONCodec.objectValue(startBlock["start"])?["toolUse"]),
               let id = AIProtocolUtils.JSONCodec.stringValue(toolUse["toolUseId"]),
               let name = AIProtocolUtils.JSONCodec.stringValue(toolUse["name"]) {
                var events: [AIProtocolUtils.LLMEvent] = []
                state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                state.tools = AIProtocolUtils.ToolStream.start(state.tools, key: idx, tool: AIProtocolUtils.ToolStream.PendingTool(id: id, name: name))
                events.append(.toolInputStart(id: id, name: name))
                return events
            }
            if let deltaBlock = AIProtocolUtils.JSONCodec.objectValue(event["contentBlockDelta"]),
               let idx = AIProtocolUtils.JSONCodec.intValue(deltaBlock["contentBlockIndex"]),
               let delta = AIProtocolUtils.JSONCodec.objectValue(deltaBlock["delta"]) {
                if let text = AIProtocolUtils.JSONCodec.stringValue(delta["text"]), !text.isEmpty {
                    var events: [AIProtocolUtils.LLMEvent] = []
                    state.lifecycle = AIProtocolUtils.Lifecycle.textDelta(state.lifecycle, events: &events, id: "text-\(idx)", text: text)
                    return events
                }
                if let reasoning = AIProtocolUtils.JSONCodec.objectValue(delta["reasoningContent"]) {
                    var events: [AIProtocolUtils.LLMEvent] = []
                    if let sig = AIProtocolUtils.JSONCodec.stringValue(reasoning["signature"]), !sig.isEmpty {
                        state.reasoningSignatures[idx] = sig
                    }
                    if let redactedB64 = AIProtocolUtils.JSONCodec.stringValue(reasoning["redactedContent"]) {
                        let bytes: [UInt8]
                        do { bytes = try base64ToBytes(redactedB64) }
                        catch { throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Bedrock Converse reasoningContent.redactedContent contains invalid base64 data") }
                        state.reasoningRedactedContent[idx, default: []].append(bytes)
                        state.lifecycle = AIProtocolUtils.Lifecycle.reasoningStart(state.lifecycle, events: &events, id: "reasoning-\(idx)")
                    }
                    if let rText = AIProtocolUtils.JSONCodec.stringValue(reasoning["text"]) {
                        let meta: AIProtocolUtils.ProviderMetadata? = state.reasoningSignatures[idx].map {
                            [state.providerMetadataKey: ["signature": .string($0)]]
                        }
                        state.lifecycle = AIProtocolUtils.Lifecycle.reasoningDelta(state.lifecycle, events: &events, id: "reasoning-\(idx)", text: rText, providerMetadata: meta)
                    }
                    return events
                }
                if let toolUse = AIProtocolUtils.JSONCodec.objectValue(delta["toolUse"]),
                   let inp = AIProtocolUtils.JSONCodec.stringValue(toolUse["input"]) {
                    guard let outcome = AIProtocolUtils.ToolStream.append(state.tools, key: idx, text: inp) else { return [] }
                    state.tools = outcome.tools
                    var events: [AIProtocolUtils.LLMEvent] = []
                    if !outcome.events.isEmpty { state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events) }
                    events.append(contentsOf: outcome.events)
                    return events
                }
                return []
            }
            if let stopBlock = AIProtocolUtils.JSONCodec.objectValue(event["contentBlockStop"]),
               let idx = AIProtocolUtils.JSONCodec.intValue(stopBlock["contentBlockIndex"]) {
                let finished = try AIProtocolUtils.ToolStream.finish(route: adapterID, tools: state.tools, key: idx)
                state.tools = finished.tools
                var events: [AIProtocolUtils.LLMEvent] = []
                if !finished.events.isEmpty {
                    state.lifecycle = AIProtocolUtils.Lifecycle.stepStart(state.lifecycle, events: &events)
                    events.append(contentsOf: finished.events)
                    if finished.events.contains(where: \.isToolCallOrError) { state.hasToolCalls = true }
                } else {
                    let meta: AIProtocolUtils.ProviderMetadata?
                    if let sig = state.reasoningSignatures.removeValue(forKey: idx) {
                        meta = [state.providerMetadataKey: ["signature": .string(sig)]]
                    } else if let chunks = state.reasoningRedactedContent.removeValue(forKey: idx) {
                        let joined = chunks.flatMap { $0 }
                        meta = [state.providerMetadataKey: ["redactedData": .string(bytesToBase64(joined))]]
                    } else {
                        meta = nil
                    }
                    state.lifecycle = AIProtocolUtils.Lifecycle.textEnd(state.lifecycle, events: &events, id: "text-\(idx)")
                    state.lifecycle = AIProtocolUtils.Lifecycle.reasoningEnd(state.lifecycle, events: &events, id: "reasoning-\(idx)", providerMetadata: meta)
                }
                return events
            }
            if let msgStop = AIProtocolUtils.JSONCodec.objectValue(event["messageStop"]),
               let reason = AIProtocolUtils.JSONCodec.stringValue(msgStop["stopReason"]) {
                if reason == "malformed_model_output" || reason == "malformed_tool_use" {
                    throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Bedrock Converse stopped with \(reason)", body: AIProtocolUtils.JSONCodec.encodeObject(event))
                }
                state.finishReason = AIProtocolUtils.FinishReasonDetails(normalized: mapFinishReason(reason), raw: reason)
                return []
            }
            if let meta = AIProtocolUtils.JSONCodec.objectValue(event["metadata"]),
               let u = AIProtocolUtils.JSONCodec.objectValue(meta["usage"]) {
                let nonCached = AIProtocolUtils.JSONCodec.doubleValue(u["inputTokens"])
                let cacheRead = AIProtocolUtils.JSONCodec.doubleValue(u["cacheReadInputTokens"])
                let cacheWrite = AIProtocolUtils.JSONCodec.doubleValue(u["cacheWriteInputTokens"])
                let inputTokens = AIProtocolUtils.ProviderShared.sumTokens(nonCached, cacheRead, cacheWrite)
                let outputTokens = AIProtocolUtils.JSONCodec.doubleValue(u["outputTokens"])
                state.usage = AIProtocolUtils.Usage(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    nonCachedInputTokens: nonCached,
                    cacheReadInputTokens: cacheRead,
                    cacheWriteInputTokens: cacheWrite,
                    totalTokens: AIProtocolUtils.ProviderShared.totalTokens(inputTokens, outputTokens, AIProtocolUtils.JSONCodec.doubleValue(u["totalTokens"])),
                    providerMetadata: [state.providerMetadataKey: u]
                )
                return []
            }
            if let exc = AIProtocolUtils.JSONCodec.objectValue(event["exception"]) {
                let details = AIProtocolUtils.JSONCodec.objectValue(exc["details"])
                let msg = AIProtocolUtils.JSONCodec.stringValue(details?["message"])
                    ?? AIProtocolUtils.JSONCodec.stringValue(details?["originalMessage"])
                    ?? "Bedrock Converse stream error"
                let status = AIProtocolUtils.JSONCodec.intValue(details?["originalStatusCode"])
                throw AIProtocolUtils.ProtocolError(kind: status == 429 ? .rateLimit : .providerInternal, message: msg, route: adapterID, statusCode: status, body: AIProtocolUtils.JSONCodec.encodeObject(event))
            }
            return []
        }

        public static func onHalt(state: ParserState) -> [AIProtocolUtils.LLMEvent] {
            guard let fr = state.finishReason else { return [] }
            let normalized: AIProtocolUtils.FinishReason = (fr.normalized == .stop && state.hasToolCalls) ? .toolCalls : fr.normalized
            var events: [AIProtocolUtils.LLMEvent] = []
            var lifecycle = state.lifecycle
            for idx in state.reasoningRedactedContent.keys.sorted() {
                if let chunks = state.reasoningRedactedContent[idx] {
                    let meta: AIProtocolUtils.ProviderMetadata = [state.providerMetadataKey: ["redactedData": .string(bytesToBase64(chunks.flatMap { $0 }))]]
                    lifecycle = AIProtocolUtils.Lifecycle.reasoningEnd(lifecycle, events: &events, id: "reasoning-\(idx)", providerMetadata: meta)
                }
            }
            _ = AIProtocolUtils.Lifecycle.finish(
                lifecycle,
                events: &events,
                reason: AIProtocolUtils.FinishReasonDetails(normalized: normalized, raw: fr.raw),
                usage: state.usage
            )
            return events
        }

        public struct StreamDecoder: IncrementalStreamDecoder, Sendable {
            private var decoder = BedrockEventStream.framing(route: adapterID).makeDecoder()
            private var state: ParserState
            private var finished = false

            public init(request: AIProtocolUtils.LLMRequest) {
                self.state = ParserState(providerMetadataKey: request.model.providerMetadataKey ?? request.model.provider)
            }

            public mutating func feed(_ bytes: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                let frames = try decoder.feed(bytes)
                var events: [AIProtocolUtils.LLMEvent] = []
                for frame in frames {
                    events.append(contentsOf: try step(state: &state, event: frame.event))
                }
                return events
            }

            public mutating func finish() throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                try decoder.finish()
                guard !finished else { return [] }
                finished = true
                return onHalt(state: state)
            }
        }

        public static func parseEventStream(
            _ bytes: [UInt8],
            request: AIProtocolUtils.LLMRequest
        ) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            var decoder = StreamDecoder(request: request)
            return try decoder.feed(bytes) + decoder.finish()
        }

        // parity: ai/src/protocols/bedrock-converse.ts#protocol [status=implemented hash=632fe2c1359b]
        public static let `protocol` = ChatProtocolSpec(
            id: adapterID,
            framing: .awsEventStream,
            buildBody: fromRequest,
            parseStream: parseEventStream,
            makeStreamDecoder: { StreamDecoder(request: $0) }
        )

        // parity: ai/src/protocols/bedrock-converse.ts#route [status=implemented hash=196794f5cef0]
        public static let route = ChatRouteSpec(
            id: adapterID,
            provider: "bedrock",
            providerMetadataKey: "bedrock",
            protocol: `protocol`,
            defaultBaseURL: nil,
            pathBuilder: { req, body in
                let modelID = AIProtocolUtils.JSONCodec.stringValue(body["modelId"]) ?? req.model.id
                return "/model/\(AIProtocolUtils.JSONCodec.percentEncodePathComponent(modelID))/converse-stream"
            },
            auth: AIProtocolUtils.BedrockAuth.auth
        )
    }

    // MARK: - GoogleInteractions (packages/ai/src/protocols/google-interactions.ts — 6 symbols)

    public enum GoogleInteractions {
        public static let adapterID = "google-interactions"
        static let CONTINUATION = "requires_continuation"
        /// Matches Google's GenAI SDKs (Python, JS, and Go).
        static let MAX_STREAM_RECONNECTS_WITHOUT_PROGRESS = 3

        /// https://aistudio.google.com/docs/document-processing#office-documents
        static let officeDocumentMimeTypes: Set<String> = [
            "application/msword",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.template",
            "application/vnd.oasis.opendocument.text",
            "application/vnd.ms-powerpoint",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.oasis.opendocument.presentation",
            "application/vnd.ms-excel",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.oasis.opendocument.spreadsheet",
        ]

        // parity: ai/src/protocols/google-interactions.ts#DEFAULT_BASE_URL [status=implemented hash=ae7b30027e03]
        public static let DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

        // parity: ai/src/protocols/google-interactions.ts#OptionsInput [status=implemented hash=1a427bd2c062]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var previousInteractionId: String?
            public var store: Bool?
            public var thinkingLevel: String?
            public var thinkingSummaries: String?
            public var serviceTier: String?
            public var safetySettings: [AIProtocolUtils.GeminiGenerateContent.SafetySetting]?

            public init(
                previousInteractionId: String? = nil,
                store: Bool? = nil,
                thinkingLevel: String? = nil,
                thinkingSummaries: String? = nil,
                serviceTier: String? = nil,
                safetySettings: [AIProtocolUtils.GeminiGenerateContent.SafetySetting]? = nil
            ) {
                self.previousInteractionId = previousInteractionId
                self.store = store
                self.thinkingLevel = thinkingLevel
                self.thinkingSummaries = thinkingSummaries
                self.serviceTier = serviceTier
                self.safetySettings = safetySettings
            }
        }

        // parity: ai/src/protocols/google-interactions.ts#ProviderOptionsInput [status=implemented hash=b8c6e72d7d57]
        public typealias ProviderOptionsInput = OptionsInput

        // parity: ai/src/protocols/google-interactions.ts#mediaContent [status=implemented hash=33aa1077dc6c]
        public static func mediaContent(_ asset: AIProtocolUtils.MediaAsset) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue] {
            let kind = asset.kind
            guard kind == .image || kind == .audio || kind == .video || asset.mediaType == "application/pdf"
                || asset.mediaType == "text/csv" || officeDocumentMimeTypes.contains(asset.mediaType)
            else {
                throw AIProtocolUtils.ProviderShared.invalidRequest("Google Interactions does not support \(asset.mediaType) document input")
            }
            let typeStr: String = (kind == .image || kind == .audio || kind == .video) ? kind.rawValue : "document"
            let uri: String?
            if kind == .video, case .url(let u) = asset.source,
               u.lowercased().hasPrefix("http://") || u.lowercased().hasPrefix("https://") {
                uri = u
            } else {
                uri = AIProtocolUtils.MediaInput.refID(asset, provider: "google")
            }
            if let uri {
                return ["type": .string(typeStr), "uri": .string(uri), "mime_type": .string(asset.mediaType)]
            }
            let inline = try AIProtocolUtils.ProviderShared.requireInlineMedia(route: "Google Interactions", asset: asset)
            return ["type": .string(typeStr), "data": .string(inline.base64), "mime_type": .string(inline.mime)]
        }

        /// `safetySettings` provider options in the Interactions wire shape: the category without its
        /// `HARM_CATEGORY_` prefix and the threshold, both lowercased.
        static func safetySettings(_ value: JSONValue?) -> [JSONValue]? {
            guard let settings = AIProtocolUtils.JSONCodec.arrayValue(value) else { return nil }
            return settings.compactMap { item -> JSONValue? in
                guard let setting = AIProtocolUtils.GeminiGenerateContent.SafetySetting(json: item) else { return nil }
                var category = setting.category
                if category.hasPrefix("HARM_CATEGORY_") { category.removeFirst("HARM_CATEGORY_".count) }
                return .object(["type": .string(category.lowercased()), "threshold": .string(setting.threshold.lowercased())])
            }
        }

        public static func fromRequest(_ request: AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue] {
            let flattened = AIProtocolUtils.ProviderShared.flattenToolRequest(request)
            let opts = request.providerOptions ?? [:]
            var inputSteps: [JSONValue] = []
            for message in flattened.request.messages {
                switch message.role {
                case .user, .system:
                    var content: [JSONValue] = []
                    for part in message.content {
                        switch part {
                        case .text(let tp): content.append(.object(["type": .string("text"), "text": .string(tp.text)]))
                        case .media(let mp): content.append(.object(try mediaContent(mp.media)))
                        default: break
                        }
                    }
                    inputSteps.append(.object(["type": .string("user_input"), "content": .array(content)]))
                case .assistant:
                    for part in message.content {
                        switch part {
                        case .text(let tp):
                            inputSteps.append(.object(["type": .string("model_output"), "content": .array([.object(["type": .string("text"), "text": .string(tp.text)])])]))
                        case .toolCall(let tc):
                            inputSteps.append(.object(["type": .string("function_call"), "id": .string(tc.id), "name": .string(tc.name), "arguments": tc.input]))
                        default: break
                        }
                    }
                case .tool:
                    for part in message.content {
                        guard case .toolResult(let tr) = part else { continue }
                        inputSteps.append(.object([
                            "type": .string("function_result"),
                            "call_id": .string(tr.id),
                            "name": .string(tr.name),
                            "result": .string(AIProtocolUtils.ProviderShared.toolResultText(tr)),
                        ]))
                    }
                }
            }
            var genConfig: [String: JSONValue] = [:]
            if let maxT = request.maxTokens { genConfig["max_output_tokens"] = .int(Int64(maxT)) }
            if let temp = request.temperature { genConfig["temperature"] = .double(temp) }
            if let topP = request.topP { genConfig["top_p"] = .double(topP) }
            if let tl = AIProtocolUtils.JSONCodec.stringValue(opts["thinkingLevel"]) { genConfig["thinking_level"] = .string(tl) }
            if let ts = AIProtocolUtils.JSONCodec.stringValue(opts["thinkingSummaries"]) { genConfig["thinking_summaries"] = .string(ts) }

            var body: [String: JSONValue] = [
                "model": .string(request.model.id),
                "input": .array(inputSteps),
                "stream": .bool(true),
                // Full-history replay need not create retained provider resources. Continuation callers opt in to storage.
                "store": .bool(AIProtocolUtils.JSONCodec.boolValue(opts["store"]) ?? false),
                "generation_config": .object(genConfig),
            ]
            if !request.system.isEmpty {
                body["system_instruction"] = .string(AIProtocolUtils.ProviderShared.joinText(request.system))
            }
            if let prev = AIProtocolUtils.JSONCodec.stringValue(opts["previousInteractionId"]) {
                body["previous_interaction_id"] = .string(prev)
            }
            if let tier = AIProtocolUtils.JSONCodec.stringValue(opts["serviceTier"]) {
                body["service_tier"] = .string(tier)
            }
            if let safety = safetySettings(opts["safetySettings"]) {
                body["safety_settings"] = .array(safety)
            }
            if !flattened.tools.isEmpty {
                body["tools"] = .array(flattened.tools.map { t in
                    .object(["type": .string("function"), "name": .string(t.name), "description": .string(t.description), "parameters": .object(t.inputSchema)])
                })
            }
            return body
        }

        // MARK: Stream Parsing

        /// The usage counters of one Interactions request (`RawUsage`).
        struct RawUsage: Equatable, Sendable {
            let raw: [String: JSONValue]

            init?(_ value: JSONValue?) {
                guard let raw = AIProtocolUtils.JSONCodec.objectValue(value) else { return nil }
                self.raw = raw
            }

            func number(_ key: String) -> Double? { AIProtocolUtils.JSONCodec.doubleValue(raw[key]) }
            var input: Double? { number("total_input_tokens") }
            var cached: Double? { number("total_cached_tokens") }
            var output: Double? { number("total_output_tokens") }
            var thought: Double? { number("total_thought_tokens") }
            var total: Double? { number("total_tokens") }
            var rawPrompt: Double? { number("raw_prompt_token") }
        }

        /// Maps the usage of a logical call that may span continuation requests: input and context come from the
        /// first request, output and reasoning sum across requests, and re-billed input stays in provider metadata.
        static func mapUsage(_ usage: RawUsage?, key: String, continued: [RawUsage?]) -> AIProtocolUtils.Usage? {
            if usage == nil && continued.allSatisfy({ $0 == nil }) { return nil }
            let first = continued.isEmpty ? usage : continued[0]
            let hops = continued + [usage]
            func sum(_ field: (RawUsage) -> Double?) -> Double? {
                AIProtocolUtils.ProviderShared.sumTokens(hops.map { $0.flatMap(field) })
            }
            let input = first?.input
            let cached = first?.cached
            let reasoning = sum(\.thought)
            let text = sum(\.output)
            let output: Double? = continued.isEmpty
                ? text.map { $0 + (reasoning ?? 0) }
                : AIProtocolUtils.ProviderShared.sumTokens(text, reasoning)
            let metadata: [String: JSONValue]
            if continued.isEmpty {
                metadata = usage?.raw ?? [:]
            } else {
                var summed: [String: JSONValue] = ["requests": .int(Int64(hops.count))]
                func put(_ name: String, _ value: Double?) { if let value { summed[name] = .double(value) } }
                put("total_input_tokens", sum(\.input))
                put("total_cached_tokens", sum(\.cached))
                put("total_output_tokens", text)
                put("total_thought_tokens", reasoning)
                put("total_tokens", sum(\.total))
                metadata = summed
            }
            return AIProtocolUtils.Usage(
                inputTokens: input,
                outputTokens: output,
                contextTokens: first?.rawPrompt ?? input,
                nonCachedInputTokens: AIProtocolUtils.ProviderShared.subtractTokens(input, cached),
                cacheReadInputTokens: cached,
                reasoningTokens: reasoning,
                totalTokens: continued.isEmpty
                    ? usage?.total
                    : AIProtocolUtils.ProviderShared.totalTokens(input, output, nil),
                providerMetadata: [key: metadata]
            )
        }

        private static let recoverableCodes: Set<String> = [
            "MALFORMED_FUNCTION_CALL", "MALFORMED_TOOL_CALL", "UNEXPECTED_TOOL_CALL", "MALFORMED_RESPONSE",
        ]
        private static let invalidOutputCodes: Set<String> = ["MISSING_THOUGHT_SIGNATURE", "TOO_MANY_TOOL_CALLS", "NO_IMAGE"]

        static func failureReason(
            route: String,
            code: String?,
            message: String,
            data: JSONValue?,
            rawBody: String
        ) -> AIProtocolUtils.ProtocolError {
            let normalized = code?.trimmingCharacters(in: .whitespaces).uppercased().replacing("-", with: "_")
            if let normalized, recoverableCodes.contains(normalized) {
                return AIProtocolUtils.ProtocolError(kind: .invalidProviderOutput, message: message, route: route, body: rawBody, classification: "incomplete-stream")
            }
            if let normalized, invalidOutputCodes.contains(normalized) {
                return AIProtocolUtils.ProtocolError(kind: .invalidProviderOutput, message: message, route: route, body: rawBody)
            }
            if let normalized, normalized == "CONTENT_BLOCKED" || AIProtocolUtils.GeminiGenerateContent.contentFiltered(normalized) {
                return AIProtocolUtils.ProtocolError(kind: .contentPolicy, message: message, route: route, body: rawBody)
            }
            let kind: AIProtocolUtils.ProtocolErrorKind
            switch AIErrorClassifier.classifyProviderFailure(AIErrorClassifier.ProviderFailure(message: message, rawBody: rawBody, data: data)) {
            case .contentPolicy: kind = .contentPolicy
            case .rateLimit, .quotaExceeded: kind = .rateLimit
            case .authentication: kind = .authentication
            case .invalidRequest: kind = .invalidRequest
            case .unsupportedOperation: kind = .unsupportedOperation
            case .transport, .timeout: kind = .transport
            case .invalidProviderOutput: kind = .invalidProviderOutput
            case .unknownProvider: kind = .unknownProvider
            case .providerInternal: kind = .providerInternal
            }
            return AIProtocolUtils.ProtocolError(kind: kind, message: message, route: route, body: rawBody)
        }

        public struct StreamDecoder: IncrementalStreamDecoder, Sendable {
            private struct Step: Sendable {
                var type: String
                var signature: String?
            }

            private var sse = AIProtocolUtils.SSEParser()
            private var lifecycle = AIProtocolUtils.Lifecycle.initial()
            private let route: String
            private let metadataKey: String
            private var hop = 0
            private var hasToolCalls = false
            private var usage: RawUsage?
            private var continuedUsage: [RawUsage?] = []
            private var steps: [Int: Step] = [:]
            private var tools: AIProtocolUtils.ToolStream.State<Int> = AIProtocolUtils.ToolStream.empty()

            public init(route: String = "google/\(adapterID)", metadataKey: String = "google") {
                self.route = route
                self.metadataKey = metadataKey
            }

            public init(request: AIProtocolUtils.LLMRequest) {
                self.init(
                    route: "\(request.model.provider)/\(request.model.routeID)",
                    metadataKey: request.model.providerMetadataKey ?? request.model.provider
                )
            }

            public mutating func feed(_ bytes: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                try process(sse.feed(bytes))
            }

            public mutating func finish() throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                try process(sse.finish())
            }

            /// A request boundary: closes the open blocks and pending tool calls of the request that ended, keeps its
            /// usage for the logical call, and starts the next request's block ids at a new hop.
            public mutating func beginNextRequest() throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                var events = try AIProtocolUtils.ToolStream.finishAll(route: adapterID, tools: tools).events
                for index in steps.keys.sorted() {
                    guard let step = steps[index] else { continue }
                    let id = blockID(index)
                    if step.type == "thought" {
                        lifecycle = AIProtocolUtils.Lifecycle.reasoningEnd(lifecycle, events: &events, id: id, providerMetadata: metadata(step))
                    }
                    if step.type == "model_output" {
                        lifecycle = AIProtocolUtils.Lifecycle.textEnd(lifecycle, events: &events, id: id)
                    }
                }
                hop += 1
                steps = [:]
                tools = AIProtocolUtils.ToolStream.empty()
                continuedUsage.append(usage)
                usage = nil
                // A dropped stream may have buffered a partial frame; the next request starts a fresh stream.
                sse = AIProtocolUtils.SSEParser()
                return events
            }

            private func blockID(_ index: Int) -> String { hop == 0 ? String(index) : "\(hop):\(index)" }

            private func metadata(_ step: Step) -> AIProtocolUtils.ProviderMetadata {
                [metadataKey: ["interactionSignature": step.signature.map(JSONValue.string) ?? .null]]
            }

            private mutating func process(_ frames: [AIProtocolUtils.SSEFrame]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                var events: [AIProtocolUtils.LLMEvent] = []
                for frame in frames {
                    let trimmed = frame.data.trimmingASCIIWhitespace()
                    if trimmed.isEmpty || trimmed == ": keepalive" { continue }
                    let decoded = try AIProtocolUtils.ProviderShared.parseJson(route: adapterID, input: trimmed, message: "Invalid \(route) stream event")
                    guard let obj = AIProtocolUtils.JSONCodec.objectValue(decoded),
                          let evType = AIProtocolUtils.JSONCodec.stringValue(obj["event_type"]) else { continue }
                    try step(evType, obj, raw: frame.data, events: &events)
                }
                return events
            }

            private mutating func step(
                _ type: String,
                _ obj: [String: JSONValue],
                raw: String,
                events: inout [AIProtocolUtils.LLMEvent]
            ) throws(AIProtocolUtils.ProtocolError) {
                let index = AIProtocolUtils.JSONCodec.intValue(obj["index"]) ?? 0
                switch type {
                case "step.start":
                    guard let stepObj = AIProtocolUtils.JSONCodec.objectValue(obj["step"]) else {
                        throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Invalid \(route) stream event", body: raw)
                    }
                    try onStart(index, stepObj, raw: raw, events: &events)
                case "step.delta":
                    guard let delta = AIProtocolUtils.JSONCodec.objectValue(obj["delta"]) else {
                        throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Invalid \(route) stream event", body: raw)
                    }
                    try onDelta(index, delta, raw: raw, events: &events)
                case "step.stop":
                    try onStop(index, events: &events)
                case "interaction.status_update":
                    usage = RawUsage(obj["usage"]) ?? usage
                case "interaction.created":
                    break
                case "error":
                    let detail = AIProtocolUtils.JSONCodec.objectValue(obj["error"])
                    let code = AIProtocolUtils.JSONCodec.stringValue(detail?["code"]) ?? AIProtocolUtils.JSONCodec.stringValue(detail?["error_type"])
                    let detailMessage = AIProtocolUtils.JSONCodec.stringValue(detail?["message"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = (detailMessage?.isEmpty == false ? detailMessage : nil)
                        ?? AIErrorClassifier.providerErrorMessage(raw)
                        ?? "Google Interactions stream error"
                    throw failureReason(route: route, code: code, message: message, data: obj["error"], rawBody: raw)
                case "interaction.completed":
                    let interaction = AIProtocolUtils.JSONCodec.objectValue(obj["interaction"]) ?? [:]
                    let status = AIProtocolUtils.JSONCodec.stringValue(interaction["status"]) ?? ""
                    if status == CONTINUATION {
                        usage = RawUsage(interaction["usage"]) ?? usage
                        return
                    }
                    if status == "failed" || status == "cancelled" {
                        let errors = AIProtocolUtils.JSONCodec.arrayValue(interaction["errors"])?.compactMap(AIProtocolUtils.JSONCodec.objectValue) ?? []
                        let messages = errors.compactMap { AIProtocolUtils.JSONCodec.stringValue($0["message"]) }
                            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        let coded = errors.first { AIProtocolUtils.JSONCodec.stringValue($0["code"]) != nil }
                        throw failureReason(
                            route: route,
                            code: coded.flatMap { AIProtocolUtils.JSONCodec.stringValue($0["code"]) },
                            message: messages.isEmpty ? "Google Interactions \(status)" : messages.joined(separator: "\n"),
                            // The first coded error decides the classification; every message stays visible.
                            data: coded.map(JSONValue.object) ?? .object(interaction),
                            rawBody: raw
                        )
                    }
                    guard ["completed", "requires_action", "incomplete"].contains(status) else {
                        throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Unexpected terminal Interactions status: \(status)", body: raw)
                    }
                    let pending = try AIProtocolUtils.ToolStream.finishAll(route: adapterID, tools: tools)
                    events.append(contentsOf: pending.events)
                    tools = pending.tools
                    let normalized: AIProtocolUtils.FinishReason =
                        status == "requires_action" || (status == "completed" && hasToolCalls)
                            ? .toolCalls
                            : status == "incomplete" ? .length : .stop
                    var meta: [String: JSONValue] = [:]
                    if let id = AIProtocolUtils.JSONCodec.stringValue(interaction["id"]) { meta["interactionId"] = .string(id) }
                    lifecycle = AIProtocolUtils.Lifecycle.finish(
                        lifecycle,
                        events: &events,
                        reason: AIProtocolUtils.FinishReasonDetails(normalized: normalized, raw: status),
                        usage: mapUsage(RawUsage(interaction["usage"]) ?? usage, key: metadataKey, continued: continuedUsage),
                        providerMetadata: [metadataKey: meta]
                    )
                default:
                    // Google may add stream event types; unknown types are ignored.
                    break
                }
            }

            private mutating func onStart(
                _ index: Int,
                _ stepObj: [String: JSONValue],
                raw: String,
                events: inout [AIProtocolUtils.LLMEvent]
            ) throws(AIProtocolUtils.ProtocolError) {
                let type = AIProtocolUtils.JSONCodec.stringValue(stepObj["type"]) ?? ""
                let step = Step(type: type, signature: AIProtocolUtils.JSONCodec.stringValue(stepObj["signature"]))
                lifecycle = AIProtocolUtils.Lifecycle.stepStart(lifecycle, events: &events)
                let id = blockID(index)
                switch type {
                case "thought":
                    lifecycle = AIProtocolUtils.Lifecycle.reasoningStart(lifecycle, events: &events, id: id, providerMetadata: metadata(step))
                    for part in AIProtocolUtils.JSONCodec.arrayValue(stepObj["summary"]) ?? [] {
                        guard let text = AIProtocolUtils.JSONCodec.stringValue(AIProtocolUtils.JSONCodec.objectValue(part)?["text"]) else { continue }
                        lifecycle = AIProtocolUtils.Lifecycle.reasoningDelta(lifecycle, events: &events, id: id, text: text)
                    }
                case "model_output":
                    lifecycle = AIProtocolUtils.Lifecycle.textStart(lifecycle, events: &events, id: id)
                    for part in AIProtocolUtils.JSONCodec.arrayValue(stepObj["content"]) ?? [] {
                        let item = AIProtocolUtils.JSONCodec.objectValue(part) ?? [:]
                        let partType = AIProtocolUtils.JSONCodec.stringValue(item["type"]) ?? ""
                        guard partType == "text" else {
                            throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Unsupported Interactions output: \(partType)", body: raw)
                        }
                        if let text = AIProtocolUtils.JSONCodec.stringValue(item["text"]), !text.isEmpty {
                            lifecycle = AIProtocolUtils.Lifecycle.textDelta(lifecycle, events: &events, id: id, text: text)
                        }
                    }
                case "function_call":
                    guard let callID = AIProtocolUtils.JSONCodec.stringValue(stepObj["id"]), !callID.isEmpty,
                          let name = AIProtocolUtils.JSONCodec.stringValue(stepObj["name"]), !name.isEmpty else {
                        throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Interactions function call lacks id or name", body: raw)
                    }
                    let arguments = AIProtocolUtils.JSONCodec.objectValue(stepObj["arguments"])
                    let input = (arguments?.isEmpty == false) ? AIProtocolUtils.JSONCodec.encodeObject(arguments ?? [:]) : ""
                    tools = AIProtocolUtils.ToolStream.start(tools, key: index, tool: AIProtocolUtils.ToolStream.PendingTool(
                        id: callID,
                        name: name,
                        input: input,
                        providerMetadata: metadata(step)
                    ))
                    events.append(.toolInputStart(id: callID, name: name, providerMetadata: metadata(step)))
                    hasToolCalls = true
                default:
                    throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Unsupported Interactions step: \(type)", body: raw)
                }
                steps[index] = step
            }

            private mutating func onDelta(
                _ index: Int,
                _ delta: [String: JSONValue],
                raw: String,
                events: inout [AIProtocolUtils.LLMEvent]
            ) throws(AIProtocolUtils.ProtocolError) {
                guard var step = steps[index] else {
                    throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Interactions delta without step.start", body: raw)
                }
                let type = AIProtocolUtils.JSONCodec.stringValue(delta["type"]) ?? ""
                if type == "text", step.type == "model_output" {
                    lifecycle = AIProtocolUtils.Lifecycle.textDelta(
                        lifecycle, events: &events, id: blockID(index), text: AIProtocolUtils.JSONCodec.stringValue(delta["text"]) ?? ""
                    )
                    return
                }
                if type == "thought_summary", step.type == "thought" {
                    let text = AIProtocolUtils.JSONCodec.stringValue(AIProtocolUtils.JSONCodec.objectValue(delta["content"])?["text"]) ?? ""
                    lifecycle = AIProtocolUtils.Lifecycle.reasoningDelta(lifecycle, events: &events, id: blockID(index), text: text)
                    return
                }
                if type == "thought_signature" {
                    step.signature = AIProtocolUtils.JSONCodec.stringValue(delta["signature"])
                    steps[index] = step
                    if let tool = tools[index] {
                        tools[index] = AIProtocolUtils.ToolStream.PendingTool(
                            id: tool.id,
                            name: tool.name,
                            namespace: tool.namespace,
                            input: tool.input,
                            providerExecuted: tool.providerExecuted,
                            providerMetadata: metadata(step)
                        )
                    }
                    return
                }
                if type == "arguments_delta", step.type == "function_call" {
                    let result = AIProtocolUtils.ToolStream.appendExisting(
                        route: adapterID,
                        tools: tools,
                        key: index,
                        text: AIProtocolUtils.JSONCodec.stringValue(delta["arguments"]) ?? "",
                        missingToolMessage: "Interactions arguments without function call"
                    )
                    switch result {
                    case .ok(let outcome):
                        tools = outcome.tools
                        events.append(contentsOf: outcome.events)
                    case .error(let error):
                        throw error
                    }
                    return
                }
                throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Unsupported Interactions delta: \(type)", body: raw)
            }

            private mutating func onStop(_ index: Int, events: inout [AIProtocolUtils.LLMEvent]) throws(AIProtocolUtils.ProtocolError) {
                guard let step = steps[index] else {
                    throw AIProtocolUtils.ProviderShared.eventError(adapterID, "Interactions step.stop without step.start")
                }
                if step.type == "thought" {
                    lifecycle = AIProtocolUtils.Lifecycle.reasoningEnd(lifecycle, events: &events, id: blockID(index), providerMetadata: metadata(step))
                    return
                }
                if step.type == "model_output" {
                    lifecycle = AIProtocolUtils.Lifecycle.textEnd(lifecycle, events: &events, id: blockID(index))
                    return
                }
                let result = try AIProtocolUtils.ToolStream.finish(route: adapterID, tools: tools, key: index)
                tools = result.tools
                events.append(contentsOf: result.events)
            }
        }

        public static func parseSSEStream(_ bytes: [UInt8], request: AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            var decoder = StreamDecoder(request: request)
            return try decoder.feed(bytes) + decoder.finish()
        }

        // MARK: Transport

        /// The first request of one logical call: its prepared HTTP request and the body continuations reuse.
        // parity: ai/src/protocols/google-interactions.ts#Prepared [status=adapted hash=9d01b04624ac]
        public struct Prepared: Sendable {
            public let http: HTTPRequest?
            public let body: [String: JSONValue]

            public init(http: HTTPRequest? = nil, body: [String: JSONValue]) {
                self.http = http
                self.body = body
            }
        }

        /// Where a continuation resumes: its checkpoint token, the interaction that owns it, and reconnects since
        /// the last progress.
        struct Resume: Sendable {
            let token: String
            let owner: String?
            let reconnectsWithoutProgress: Int
            let lastError: String?
        }

        /// Follows one logical response across requests. A response that ends at a safe checkpoint (a continuation
        /// token with no output since it, no tool call cut mid-arguments) continues with `continuation_token`;
        /// a stored interaction continues by id instead of resending its input.
        public struct ContinuationSession: ChatContinuationSession {
            private let prepared: Prepared
            private let label: String
            private var resume: Resume?
            private var sse = AIProtocolUtils.SSEParser()
            private var token: String?
            private var owner: String?
            private var status: String?
            private var contentSinceToken = false
            private var terminal = false
            private var pendingTools: Set<Int> = []

            public init(prepared: Prepared, label: String) {
                self.prepared = prepared
                self.label = label
            }

            public mutating func observe(_ bytes: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> Bool {
                for frame in sse.feed(bytes) {
                    let trimmed = frame.data.trimmingASCIIWhitespace()
                    if trimmed.isEmpty || trimmed == ": keepalive" { continue }
                    guard let obj = AIProtocolUtils.JSONCodec.objectValue(
                        try AIProtocolUtils.ProviderShared.parseJson(route: adapterID, input: trimmed, message: "Invalid \(label) stream event")
                    ), let type = AIProtocolUtils.JSONCodec.stringValue(obj["event_type"]) else { continue }
                    let index = AIProtocolUtils.JSONCodec.intValue(obj["index"]) ?? 0
                    switch type {
                    case "interaction.created":
                        owner = AIProtocolUtils.JSONCodec.stringValue(AIProtocolUtils.JSONCodec.objectValue(obj["interaction"])?["id"])
                    case "interaction.status_update":
                        status = AIProtocolUtils.JSONCodec.stringValue(obj["status"])
                        owner = AIProtocolUtils.JSONCodec.stringValue(obj["interaction_id"]) ?? owner
                        if let next = AIProtocolUtils.JSONCodec.stringValue(obj["continuation_token"]), !next.isEmpty, next != token {
                            token = next
                            contentSinceToken = false
                        }
                    case "interaction.completed":
                        let interaction = AIProtocolUtils.JSONCodec.objectValue(obj["interaction"]) ?? [:]
                        terminal = true
                        status = AIProtocolUtils.JSONCodec.stringValue(interaction["status"])
                        owner = AIProtocolUtils.JSONCodec.stringValue(interaction["id"]) ?? owner
                        if let next = AIProtocolUtils.JSONCodec.stringValue(interaction["continuation_token"]), !next.isEmpty {
                            token = next
                            contentSinceToken = false
                        }
                        return true
                    case "step.start":
                        let step = AIProtocolUtils.JSONCodec.objectValue(obj["step"]) ?? [:]
                        if AIProtocolUtils.JSONCodec.stringValue(step["type"]) == "function_call" { pendingTools.insert(index) }
                        if pendingTools.contains(index)
                            || !(AIProtocolUtils.JSONCodec.arrayValue(step["content"]) ?? []).isEmpty
                            || !(AIProtocolUtils.JSONCodec.arrayValue(step["summary"]) ?? []).isEmpty
                            || AIProtocolUtils.JSONCodec.stringValue(step["signature"]) != nil {
                            contentSinceToken = true
                        }
                    case "step.delta":
                        contentSinceToken = true
                    case "step.stop":
                        if pendingTools.remove(index) != nil { contentSinceToken = true }
                    default:
                        break
                    }
                }
                return false
            }

            public func canResume(after error: any Error) -> Bool {
                // A dropped connection may resume from the last checkpoint; a timeout or a decode failure may not.
                guard let transport = error as? HTTPTransportError, case .networkFailure(let detail) = transport else { return false }
                let lowered = detail.lowercased()
                return !lowered.contains("timed out") && !lowered.contains("timeout")
            }

            public mutating func next(dropped: (any Error)?) throws -> [String: JSONValue]? {
                let needsContinuation = status == CONTINUATION
                let resumable = needsContinuation || (!terminal && (status == nil || status == "in_progress"))
                let newToken = token != resume?.token
                // An interrupted tool call may carry arguments across the checkpoint. Don't finalize it on EOF.
                if let token, resumable, !contentSinceToken, terminal || pendingTools.isEmpty, !needsContinuation || newToken {
                    let reconnects = newToken ? 0 : (resume?.reconnectsWithoutProgress ?? 0) + 1
                    let lastError = dropped.map { String(describing: $0) } ?? (newToken ? nil : resume?.lastError)
                    if reconnects > MAX_STREAM_RECONNECTS_WITHOUT_PROGRESS {
                        guard let lastError else { return nil }
                        throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                            message: lastError,
                            classification: .incompleteStream,
                            route: label
                        )))
                    }
                    let next = Resume(
                        token: token,
                        owner: newToken ? owner : resume?.owner,
                        reconnectsWithoutProgress: reconnects,
                        lastError: lastError
                    )
                    resume = next
                    // The next response starts at the checkpoint.
                    sse = AIProtocolUtils.SSEParser()
                    owner = nil
                    status = nil
                    contentSinceToken = false
                    terminal = false
                    pendingTools = []
                    return Self.continuationBody(prepared.body, resume: next)
                }
                if let dropped { throw dropped }
                if terminal && needsContinuation && token == nil {
                    throw AIProtocols.toProtocolError(
                        AIProtocolUtils.ProviderShared.eventError(label, "Google Interactions continued without a token")
                    )
                }
                // No safe checkpoint. Leave EOF for the route's incomplete-stream check.
                return nil
            }

            static func continuationBody(_ body: [String: JSONValue], resume: Resume) -> [String: JSONValue] {
                var next = body
                next["continuation_token"] = .string(resume.token)
                if AIProtocolUtils.JSONCodec.boolValue(body["store"]) == true, let owner = resume.owner {
                    next.removeValue(forKey: "input")
                    next["previous_interaction_id"] = .string(owner)
                }
                return next
            }
        }

        /// Server-sent JSON events, continued across requests at Google's continuation checkpoints and after a
        /// dropped stream (at most `MAX_STREAM_RECONNECTS_WITHOUT_PROGRESS` reconnects without progress).
        // parity: ai/src/protocols/google-interactions.ts#transport [status=adapted hash=3f338ac8a9ca]
        public static let transport = ChatContinuation { body, label in
            ContinuationSession(prepared: Prepared(body: body), label: label)
        }

        /// The stream event union also carries request boundaries (`NextRequest`, via `beginNextRequest`), and
        /// `interaction.completed` is terminal only when it doesn't require continuation.
        // parity: ai/src/protocols/google-interactions.ts#protocol [status=implemented hash=8ee16a3d22a6]
        public static let `protocol` = ChatProtocolSpec(
            id: adapterID,
            framing: .sse,
            sanitizer: "gemini",
            buildBody: fromRequest,
            parseStream: parseSSEStream,
            makeStreamDecoder: { request in StreamDecoder(request: request) }
        )

        // parity: ai/src/protocols/google-interactions.ts#route [status=implemented hash=86df32149b29]
        public static let route = ChatRouteSpec(
            id: adapterID,
            provider: "google",
            providerMetadataKey: "google",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: "/interactions",
            continuation: transport
        )
    }

    // MARK: - CohereChat (packages/ai/src/protocols/cohere-chat.ts — 4 symbols)

    public enum CohereChat {
        public static let adapterID = "cohere-chat"

        // parity: ai/src/protocols/cohere-chat.ts#DEFAULT_BASE_URL [status=implemented hash=97ac00e86625]
        public static let DEFAULT_BASE_URL = "https://api.cohere.com/v2"

        // parity: ai/src/protocols/cohere-chat.ts#ProviderOptionsInput [status=implemented hash=4c37d84dc015]
        public struct ProviderOptionsInput: Equatable, Hashable, Sendable {
            public var thinkingType: String?
            public var thinkingTokenBudget: Int?
            public init(thinkingType: String? = nil, thinkingTokenBudget: Int? = nil) {
                self.thinkingType = thinkingType; self.thinkingTokenBudget = thinkingTokenBudget
            }
        }

        public static func fromRequest(_ request: AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue] {
            let flattened = AIProtocolUtils.ProviderShared.flattenToolRequest(request)
            let opts = request.providerOptions ?? [:]
            var messages: [JSONValue] = []
            if !request.system.isEmpty {
                let sysContent: JSONValue = request.system.count == 1
                    ? .string(request.system[0].text)
                    : .array(request.system.map { .object(["type": .string("text"), "text": .string($0.text)]) })
                messages.append(.object(["role": .string("system"), "content": sysContent]))
            }
            for message in flattened.request.messages {
                switch message.role {
                case .system:
                    let w = try AIProtocolUtils.ProviderShared.wrappedSystemUpdate(route: "Cohere Chat", message: message)
                    messages.append(.object(["role": .string("user"), "content": .string(w.text)]))
                case .tool:
                    for part in message.content {
                        guard case .toolResult(let tr) = part else { continue }
                        messages.append(.object(["role": .string("tool"), "tool_call_id": .string(tr.id), "content": .string(AIProtocolUtils.ProviderShared.toolResultText(tr))]))
                    }
                case .user, .assistant:
                    var content: [JSONValue] = []
                    var calls: [JSONValue] = []
                    for part in message.content {
                        switch part {
                        case .text(let tp): content.append(.object(["type": .string("text"), "text": .string(tp.text)]))
                        case .reasoning(let rp) where message.role == .assistant:
                            content.append(.object(["type": .string("thinking"), "thinking": .string(rp.text)]))
                        case .toolCall(let tc) where message.role == .assistant:
                            calls.append(.object(["id": .string(tc.id), "type": .string("function"), "function": .object(["name": .string(tc.name), "arguments": .string(AIProtocolUtils.JSONCodec.encode(tc.input))])]))
                        case .media(let mp) where message.role == .user && mp.media.mediaType.hasPrefix("image/"):
                            let url: String
                            if let remote = AIProtocolUtils.ProviderShared.mediaUrl(mp.media) {
                                url = remote
                            } else {
                                url = try AIProtocolUtils.ProviderShared.requireInlineMedia(route: "Cohere Chat", asset: mp.media).dataUrl
                            }
                            content.append(.object(["type": .string("image_url"), "image_url": .object(["url": .string(url)])]))
                        default: break
                        }
                    }
                    var msg: [String: JSONValue] = ["role": .string(message.role.rawValue)]
                    if !content.isEmpty { msg["content"] = .array(content) }
                    if !calls.isEmpty { msg["tool_calls"] = .array(calls) }
                    messages.append(.object(msg))
                }
            }
            var body: [String: JSONValue] = [
                "model": .string(request.model.id),
                "messages": .array(messages),
                "stream": .bool(true),
            ]
            if !flattened.tools.isEmpty {
                body["tools"] = .array(flattened.tools.map { t in
                    .object(["type": .string("function"), "function": .object(["name": .string(t.name), "description": .string(t.description), "parameters": .object(t.inputSchema)])])
                })
            }
            if let maxT = request.maxTokens { body["max_tokens"] = .int(Int64(maxT)) }
            if let temp = request.temperature { body["temperature"] = .double(temp) }
            if let topP = request.topP { body["p"] = .double(topP) }
            if let topK = request.topK { body["k"] = .int(Int64(topK)) }
            if let seed = request.seed { body["seed"] = .int(Int64(seed)) }
            if let stop = request.stop, !stop.isEmpty { body["stop_sequences"] = .array(stop.map(JSONValue.string)) }
            if let thinking = AIProtocolUtils.JSONCodec.objectValue(opts["thinking"]) {
                var t: [String: JSONValue] = ["type": thinking["type"] ?? .string("enabled")]
                if let b = AIProtocolUtils.JSONCodec.intValue(thinking["tokenBudget"]) {
                    t["token_budget"] = .int(Int64(AIProtocolUtils.ProviderShared.fitThinkingBudget(b, maxTokens: request.maxTokens)))
                }
                body["thinking"] = .object(t)
            }
            return body
        }

        public struct StreamDecoder: IncrementalStreamDecoder, Sendable {
            private var sse = AIProtocolUtils.SSEParser()
            private var lifecycle = AIProtocolUtils.Lifecycle.initial()
            private var tools = AIProtocolUtils.ToolStream.empty() as AIProtocolUtils.ToolStream.State<Int>

            public init() {}

            public mutating func feed(_ bytes: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                try process(sse.feed(bytes))
            }

            public mutating func finish() throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                try process(sse.finish())
            }

            private mutating func process(_ frames: [AIProtocolUtils.SSEFrame]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
                var events: [AIProtocolUtils.LLMEvent] = []
                for frame in frames {
                    let trimmed = frame.data.trimmingASCIIWhitespace()
                    if trimmed.isEmpty || trimmed == ": keepalive" { continue }
                    let decoded = try AIProtocolUtils.ProviderShared.parseJson(route: adapterID, input: trimmed, message: "Invalid Cohere Chat SSE JSON")
                    guard let obj = AIProtocolUtils.JSONCodec.objectValue(decoded),
                          let evType = AIProtocolUtils.JSONCodec.stringValue(obj["type"]) else { continue }
                    let idx = AIProtocolUtils.JSONCodec.intValue(obj["index"]) ?? 0
                    let deltaMsg = AIProtocolUtils.JSONCodec.objectValue(AIProtocolUtils.JSONCodec.objectValue(obj["delta"])?["message"])
                    switch evType {
                    case "content-start", "content-delta":
                        let content = AIProtocolUtils.JSONCodec.objectValue(deltaMsg?["content"])
                        if let text = AIProtocolUtils.JSONCodec.stringValue(content?["text"]), !text.isEmpty {
                            lifecycle = AIProtocolUtils.Lifecycle.textDelta(lifecycle, events: &events, id: "text-\(idx)", text: text)
                        }
                        if let thinking = AIProtocolUtils.JSONCodec.stringValue(content?["thinking"]), !thinking.isEmpty {
                            lifecycle = AIProtocolUtils.Lifecycle.reasoningDelta(lifecycle, events: &events, id: "reasoning-\(idx)", text: thinking)
                        }
                    case "content-end":
                        lifecycle = AIProtocolUtils.Lifecycle.textEnd(lifecycle, events: &events, id: "text-\(idx)")
                        lifecycle = AIProtocolUtils.Lifecycle.reasoningEnd(lifecycle, events: &events, id: "reasoning-\(idx)")
                    case "tool-call-start", "tool-call-delta":
                        let tc = AIProtocolUtils.JSONCodec.objectValue(deltaMsg?["tool_calls"])
                        let fn = AIProtocolUtils.JSONCodec.objectValue(tc?["function"])
                        let res = AIProtocolUtils.ToolStream.appendOrStart(
                            route: adapterID,
                            tools: tools,
                            key: idx,
                            id: AIProtocolUtils.JSONCodec.stringValue(tc?["id"]),
                            name: AIProtocolUtils.JSONCodec.stringValue(fn?["name"]),
                            text: AIProtocolUtils.JSONCodec.stringValue(fn?["arguments"]) ?? "",
                            missingToolMessage: "Cohere tool call delta missing id or name"
                        )
                        if case .ok(let outcome) = res {
                            tools = outcome.tools
                            events.append(contentsOf: outcome.events)
                        }
                    case "tool-call-end":
                        let fin = try AIProtocolUtils.ToolStream.finish(route: adapterID, tools: tools, key: idx)
                        tools = fin.tools
                        events.append(contentsOf: fin.events)
                    case "message-end":
                        let delta = AIProtocolUtils.JSONCodec.objectValue(obj["delta"])
                        let raw = AIProtocolUtils.JSONCodec.stringValue(delta?["finish_reason"])
                        let norm: AIProtocolUtils.FinishReason
                        switch raw {
                        case "COMPLETE", "STOP_SEQUENCE": norm = .stop
                        case "MAX_TOKENS": norm = .length
                        case "TOOL_CALL": norm = .toolCalls
                        default: norm = .unknown
                        }
                        lifecycle = AIProtocolUtils.Lifecycle.finish(lifecycle, events: &events, reason: AIProtocolUtils.FinishReasonDetails(normalized: norm, raw: raw))
                    default:
                        break
                    }
                }
                return events
            }
        }

        public static func parseSSEStream(_ bytes: [UInt8], request: AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] {
            _ = request
            var decoder = StreamDecoder()
            return try decoder.feed(bytes) + decoder.finish()
        }

        // parity: ai/src/protocols/cohere-chat.ts#protocol [status=implemented hash=216f384ef08b]
        public static let `protocol` = ChatProtocolSpec(
            id: adapterID,
            framing: .sse,
            buildBody: fromRequest,
            parseStream: parseSSEStream,
            makeStreamDecoder: { _ in StreamDecoder() }
        )

        // parity: ai/src/protocols/cohere-chat.ts#route [status=implemented hash=5992d819d219]
        public static let route = ChatRouteSpec(
            id: adapterID,
            provider: "cohere",
            providerMetadataKey: "cohere",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: "/chat"
        )
    }

    // MARK: - MistralChat (packages/ai/src/protocols/mistral-chat.ts — 11 symbols)

    public enum MistralChat {
        public static let adapterID = "mistral-chat"

        // parity: ai/src/protocols/mistral-chat.ts#DEFAULT_BASE_URL [status=implemented hash=6632eba15a18]
        public static let DEFAULT_BASE_URL = "https://api.mistral.ai/v1"

        // parity: ai/src/protocols/mistral-chat.ts#PATH [status=implemented hash=16806d4aa677]
        public static let PATH = "/chat/completions"

        // parity: ai/src/protocols/mistral-chat.ts#ReasoningEffort [status=implemented hash=5426516f1067]
        public typealias ReasoningEffort = String

        // parity: ai/src/protocols/mistral-chat.ts#ProviderOptionsInput [status=implemented hash=f4fa24e0e772]
        public struct ProviderOptionsInput: Equatable, Hashable, Sendable {
            public var safePrompt: Bool?
            public var documentImageLimit: Int?
            public var documentPageLimit: Int?
            public var parallelToolCalls: Bool?
            public var reasoningEffort: ReasoningEffort?
            public var promptMode: String?
            public var promptCacheKey: String?
            public init(
                safePrompt: Bool? = nil,
                documentImageLimit: Int? = nil,
                documentPageLimit: Int? = nil,
                parallelToolCalls: Bool? = nil,
                reasoningEffort: ReasoningEffort? = nil,
                promptMode: String? = nil,
                promptCacheKey: String? = nil
            ) {
                self.safePrompt = safePrompt
                self.documentImageLimit = documentImageLimit
                self.documentPageLimit = documentPageLimit
                self.parallelToolCalls = parallelToolCalls
                self.reasoningEffort = reasoningEffort
                self.promptMode = promptMode
                self.promptCacheKey = promptCacheKey
            }
        }

        // parity: ai/src/protocols/mistral-chat.ts#MistralBody [status=implemented hash=b0aee11677de]
        public typealias MistralBody = [String: JSONValue]

        // parity: ai/src/protocols/mistral-chat.ts#ParserState [status=implemented hash=1e31213c36b7]
        public typealias ParserState = OpenAIChat.ParserState

        // parity: ai/src/protocols/mistral-chat.ts#fromRequest [status=implemented hash=33222a8d1847]
        public static func fromRequest(_ request: AIProtocolUtils.LLMRequest) throws(AIProtocolUtils.ProtocolError) -> MistralBody {
            var norm = AIProtocolUtils.MistralToolID.normalizer(for: request)
            var adjusted = request
            adjusted.messages = request.messages.map { msg in
                let parts = msg.content.map { part -> AIProtocolUtils.ContentPart in
                    switch part {
                    case .toolCall(let tc):
                        return .toolCall(AIProtocolUtils.ToolCallPart(
                            id: norm.normalize(tc.id), name: tc.name, namespace: tc.namespace,
                            input: tc.input, providerExecuted: tc.providerExecuted, providerMetadata: tc.providerMetadata
                        ))
                    case .toolResult(let tr):
                        return .toolResult(AIProtocolUtils.ToolResultPart(
                            id: norm.normalize(tr.id), name: tr.name, namespace: tr.namespace,
                            result: tr.result, providerExecuted: tr.providerExecuted, cache: tr.cache, providerMetadata: tr.providerMetadata
                        ))
                    default:
                        return part
                    }
                }
                return AIProtocolUtils.Message(role: msg.role, content: parts, providerMetadata: msg.providerMetadata)
            }
            var body = try OpenAIChat.fromRequest(adjusted)
            body.removeValue(forKey: "stream_options")
            if let maxCT = body.removeValue(forKey: "max_completion_tokens") { body["max_tokens"] = maxCT }
            if let seed = body.removeValue(forKey: "seed") { body["random_seed"] = seed }
            let opts = request.providerOptions ?? [:]
            if let sp = opts["safePrompt"] { body["safe_prompt"] = sp }
            if let dil = opts["documentImageLimit"] { body["document_image_limit"] = dil }
            if let dpl = opts["documentPageLimit"] { body["document_page_limit"] = dpl }
            if let pm = opts["promptMode"] { body["prompt_mode"] = pm }
            if let pck = opts["promptCacheKey"] { body["prompt_cache_key"] = pck }
            return body
        }

        // parity: ai/src/protocols/mistral-chat.ts#protocol [status=implemented hash=a8bd61f9aee8]
        public static let `protocol` = ChatProtocolSpec(
            id: adapterID,
            framing: .sseWithDone,
            buildBody: fromRequest,
            parseStream: OpenAIChat.parseSSEStream,
            makeStreamDecoder: { OpenAIChat.StreamDecoder(request: $0) }
        )

        // parity: ai/src/protocols/mistral-chat.ts#framing [status=implemented hash=b470ea06f479]
        public static let framing: FramingKind = .sseWithDone

        // parity: ai/src/protocols/mistral-chat.ts#httpTransport [status=adapted hash=3fb04d26f89a]
        public static let httpTransport: FramingKind = .sseWithDone

        // parity: ai/src/protocols/mistral-chat.ts#route [status=implemented hash=21bf33d33f75]
        public static let route = ChatRouteSpec(
            id: adapterID,
            provider: "mistral",
            providerMetadataKey: "mistral",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )
    }

    // MARK: - Alibaba Chat / Messages / Responses (9 symbols)

    public enum AlibabaChat {
        // parity: ai/src/protocols/alibaba-chat.ts#ReasoningEffort [status=implemented hash=ab511c97a1f0]
        public typealias ReasoningEffort = String

        // parity: ai/src/protocols/alibaba-chat.ts#OptionsInput [status=implemented hash=592ed96e69da]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var reasoningEffort: ReasoningEffort?
            public var enableThinking: Bool?
            public var thinkingBudget: Int?
            public var preserveThinking: Bool?
            public var clearThinking: Bool?
            public var toolStream: Bool?
            public var parallelToolCalls: Bool?
            public var repetitionPenalty: Double?
            public var enableSearch: Bool?
            public init(
                reasoningEffort: ReasoningEffort? = nil, enableThinking: Bool? = nil,
                thinkingBudget: Int? = nil, preserveThinking: Bool? = nil,
                clearThinking: Bool? = nil, toolStream: Bool? = nil,
                parallelToolCalls: Bool? = nil, repetitionPenalty: Double? = nil,
                enableSearch: Bool? = nil
            ) {
                self.reasoningEffort = reasoningEffort; self.enableThinking = enableThinking
                self.thinkingBudget = thinkingBudget; self.preserveThinking = preserveThinking
                self.clearThinking = clearThinking; self.toolStream = toolStream
                self.parallelToolCalls = parallelToolCalls; self.repetitionPenalty = repetitionPenalty
                self.enableSearch = enableSearch
            }
        }

        // parity: ai/src/protocols/alibaba-chat.ts#compatibility [status=implemented hash=61ab4f67a277]
        public static let compatibility = AIProtocolUtils.ModelCompatibility(
            reasoningField: "reasoning_content",
            maxTokensField: "max_completion_tokens",
            zaiToolStream: false
        )

        // parity: ai/src/protocols/alibaba-chat.ts#capabilities [status=implemented hash=88f845143713]
        public static let capabilities = AIProtocolUtils.ModelCapabilities(strictTools: false)

        // parity: ai/src/protocols/alibaba-chat.ts#protocol [status=implemented hash=ed4c01ed9639]
        public static let `protocol` = ChatProtocolSpec(
            id: "alibaba-chat",
            framing: .sseWithDone,
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var body = try OpenAIChat.fromRequest(req, useCacheControl: true)
                let opts = req.providerOptions ?? [:]
                if let et = opts["enableThinking"] { body["enable_thinking"] = et }
                if let tb = AIProtocolUtils.JSONCodec.intValue(opts["thinkingBudget"]) {
                    body["thinking_budget"] = .int(Int64(AIProtocolUtils.ProviderShared.fitThinkingBudget(tb, maxTokens: req.maxTokens)))
                }
                if let pt = opts["preserveThinking"] { body["preserve_thinking"] = pt }
                if let ct = opts["clearThinking"] { body["clear_thinking"] = ct }
                if let th = opts["thinking"] { body["thinking"] = th }
                if let ts = opts["toolStream"] { body["tool_stream"] = ts }
                if let rp = opts["repetitionPenalty"] { body["repetition_penalty"] = rp }
                if let topK = req.topK { body["top_k"] = .int(Int64(topK)) }
                if let rf = opts["responseFormat"] { body["response_format"] = rf }
                if let es = opts["enableSearch"] { body["enable_search"] = es }
                if let so = opts["searchOptions"] { body["search_options"] = so }
                return body
            },
            parseStream: OpenAIChat.parseSSEStream,
            makeStreamDecoder: { OpenAIChat.StreamDecoder(request: $0) }
        )
    }

    public enum AlibabaMessages {
        // parity: ai/src/protocols/alibaba-messages.ts#OptionsInput [status=implemented hash=c5eaaa65f00c]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var effort: String?
            public var thinkingType: String?
            public var budgetTokens: Int?
            public init(effort: String? = nil, thinkingType: String? = nil, budgetTokens: Int? = nil) {
                self.effort = effort; self.thinkingType = thinkingType; self.budgetTokens = budgetTokens
            }
        }

        // parity: ai/src/protocols/alibaba-messages.ts#protocol [status=implemented hash=18ded8492a43]
        public static let `protocol` = ChatProtocolSpec(
            id: "alibaba-messages",
            framing: AnthropicMessages.framing,
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var stripped = req
                var rawOpts = req.providerOptions ?? [:]
                let rawThinking = AIProtocolUtils.JSONCodec.objectValue(rawOpts.removeValue(forKey: "thinking"))
                stripped.providerOptions = rawOpts
                var body = try AnthropicMessages.fromRequest(stripped)
                if let rawThinking, let tType = AIProtocolUtils.JSONCodec.stringValue(rawThinking["type"]) {
                    var t: [String: JSONValue] = ["type": .string(tType)]
                    if let b = AIProtocolUtils.JSONCodec.intValue(rawThinking["budgetTokens"]) ?? AIProtocolUtils.JSONCodec.intValue(rawThinking["budget_tokens"]) {
                        let maxT = AIProtocolUtils.JSONCodec.intValue(body["max_tokens"])
                        t["budget_tokens"] = .int(Int64(AIProtocolUtils.ProviderShared.fitThinkingBudget(b, maxTokens: maxT)))
                    }
                    body["thinking"] = .object(t)
                }
                return body
            },
            parseStream: AnthropicMessages.parseSSEStream,
            makeStreamDecoder: { AnthropicMessages.StreamDecoder(request: $0) }
        )
    }

    public enum AlibabaResponses {
        // parity: ai/src/protocols/alibaba-responses.ts#OptionsInput [status=implemented hash=592ed96e69da]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var reasoningEffort: String?
            public var enableThinking: Bool?
            public var store: Bool?
            public var previousResponseId: String?
            public var conversation: String?
            public init(reasoningEffort: String? = nil, enableThinking: Bool? = nil, store: Bool? = nil, previousResponseId: String? = nil, conversation: String? = nil) {
                self.reasoningEffort = reasoningEffort; self.enableThinking = enableThinking
                self.store = store; self.previousResponseId = previousResponseId; self.conversation = conversation
            }
        }

        private static let adapter = OpenResponses.ProviderAdapter(
            id: "alibaba-responses",
            name: "Alibaba Responses",
            nativeTool: { native throws(AIProtocolUtils.ProtocolError) in
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(native["alibaba"]),
                      let t = AIProtocolUtils.JSONCodec.stringValue(obj["type"]),
                      t == "web_search" || t == "web_extractor" || t == "code_interpreter" else {
                    throw AIProtocolUtils.ProviderShared.invalidRequest("Invalid Alibaba native tool")
                }
                return obj
            }
        )

        // parity: ai/src/protocols/alibaba-responses.ts#protocol [status=implemented hash=d62413dd60ac]
        public static let `protocol` = ChatProtocolSpec(
            id: "alibaba-responses",
            framing: .sse,
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var body = try OpenResponses.fromRequestWithAdapter(req, adapter: adapter)
                let opts = req.providerOptions ?? [:]
                if let et = opts["enableThinking"] { body["enable_thinking"] = et }
                if let prev = opts["previousResponseId"] { body["previous_response_id"] = prev }
                if let conv = opts["conversation"] { body["conversation"] = conv }
                if let choice = AIProtocolUtils.JSONCodec.objectValue(body["tool_choice"]),
                   AIProtocolUtils.JSONCodec.stringValue(choice["type"]) == "function" {
                    body["tool_choice"] = .object([
                        "type": .string("allowed_tools"),
                        "mode": .string("required"),
                        "tools": .array([.object(choice)]),
                    ])
                }
                return body
            },
            parseStream: { bytes, req throws(AIProtocolUtils.ProtocolError) in
                try OpenResponses.parseSSEStream(bytes, request: req, adapter: adapter, hostedTools: AIProtocolUtils.ResponsesHostedTools.common)
            },
            makeStreamDecoder: { req in
                OpenResponses.StreamDecoder(request: req, adapter: adapter, hostedTools: AIProtocolUtils.ResponsesHostedTools.common)
            }
        )
    }

    // MARK: - MetaMessages & MetaResponses (5 symbols)

    public enum MetaMessages {
        // parity: ai/src/protocols/meta-messages.ts#protocol [status=implemented hash=799d5ec77d4d]
        public static let `protocol` = ChatProtocolSpec(
            id: "meta-messages",
            framing: AnthropicMessages.framing,
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                try AnthropicMessages.fromRequest(req)
            },
            parseStream: AnthropicMessages.parseSSEStream,
            makeStreamDecoder: { AnthropicMessages.StreamDecoder(request: $0) }
        )
    }

    public enum MetaResponses {
        // parity: ai/src/protocols/meta-responses.ts#WebSearch [status=implemented hash=0311a51e3e06]
        public struct WebSearch: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let search_context_size: String?
            public init(search_context_size: String? = nil) {
                self.type = "web_search"; self.search_context_size = search_context_size
            }
        }

        // parity: ai/src/protocols/meta-responses.ts#ImageGeneration [status=implemented hash=8e3dd5eb5a3d]
        public struct ImageGeneration: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let size: String?
            public let output_format: String?
            public let reasoning_strength: String?
            public let enable_image_search: Bool?
            public let enable_web_search: Bool?
            public let enable_shell: Bool?
            public init(
                size: String? = nil, output_format: String? = nil, reasoning_strength: String? = nil,
                enable_image_search: Bool? = nil, enable_web_search: Bool? = nil, enable_shell: Bool? = nil
            ) {
                self.type = "image_generation"; self.size = size; self.output_format = output_format
                self.reasoning_strength = reasoning_strength; self.enable_image_search = enable_image_search
                self.enable_web_search = enable_web_search; self.enable_shell = enable_shell
            }
        }

        private static let adapter = OpenResponses.ProviderAdapter(
            id: "meta-responses",
            name: "Meta Responses",
            nativeTool: { native throws(AIProtocolUtils.ProtocolError) in
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(native["meta"]) else {
                    throw AIProtocolUtils.ProviderShared.invalidRequest("Invalid Meta native tool")
                }
                return obj
            }
        )

        // parity: ai/src/protocols/meta-responses.ts#protocol [status=implemented hash=7fab724286c1]
        public static let `protocol` = ChatProtocolSpec(
            id: "meta-responses",
            framing: .sse,
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                try OpenResponses.fromRequestWithAdapter(req, adapter: adapter)
            },
            parseStream: { bytes, req throws(AIProtocolUtils.ProtocolError) in
                try OpenResponses.parseSSEStream(bytes, request: req, adapter: adapter, hostedTools: AIProtocolUtils.ResponsesHostedTools.common)
            },
            makeStreamDecoder: { req in
                OpenResponses.StreamDecoder(request: req, adapter: adapter, hostedTools: AIProtocolUtils.ResponsesHostedTools.common)
            }
        )

        // parity: ai/src/protocols/meta-responses.ts#httpTransport [status=adapted hash=3494b8eb6f2a]
        public static let httpTransport: FramingKind = OpenResponses.httpTransport
    }

    // MARK: - VeniceChat (packages/ai/src/protocols/venice-chat.ts — 5 symbols)

    public enum VeniceChat {
        // parity: ai/src/protocols/venice-chat.ts#ReasoningEffort [status=implemented hash=ab511c97a1f0]
        public typealias ReasoningEffort = String

        // parity: ai/src/protocols/venice-chat.ts#OptionsInput [status=implemented hash=592ed96e69da]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var reasoningEffort: ReasoningEffort?
            public var promptCacheKey: String?
            public var promptCacheRetention: String?
            public var parallelToolCalls: Bool?
            public var includeVeniceSystemPrompt: Bool?
            public init(
                reasoningEffort: ReasoningEffort? = nil, promptCacheKey: String? = nil,
                promptCacheRetention: String? = nil, parallelToolCalls: Bool? = nil,
                includeVeniceSystemPrompt: Bool? = nil
            ) {
                self.reasoningEffort = reasoningEffort; self.promptCacheKey = promptCacheKey
                self.promptCacheRetention = promptCacheRetention; self.parallelToolCalls = parallelToolCalls
                self.includeVeniceSystemPrompt = includeVeniceSystemPrompt
            }
        }

        // parity: ai/src/protocols/venice-chat.ts#compatibility [status=implemented hash=43d6fffa43fe]
        public static let compatibility = AIProtocolUtils.ModelCompatibility(maxTokensField: "max_completion_tokens")

        // parity: ai/src/protocols/venice-chat.ts#capabilities [status=implemented hash=25a42f8fef17]
        public static let capabilities = AIProtocolUtils.ModelCapabilities(promptCacheKey: true)

        private static func camelToSnake(_ key: String) -> String {
            var out = ""
            for ch in key {
                if ch >= "A" && ch <= "Z" {
                    out.append("_")
                    out.append(ch.lowercased())
                } else {
                    out.append(ch)
                }
            }
            return out
        }

        // parity: ai/src/protocols/venice-chat.ts#protocol [status=implemented hash=2b82709ec225]
        public static let `protocol` = ChatProtocolSpec(
            id: "venice-chat",
            framing: .sseWithDone,
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var body = try OpenAIChat.fromRequest(req, useCacheControl: true)
                let opts = req.providerOptions ?? [:]
                body.removeValue(forKey: "reasoning_effort")
                if let effort = AIProtocolUtils.JSONCodec.stringValue(opts["reasoningEffort"]) {
                    var r = AIProtocolUtils.JSONCodec.objectValue(opts["reasoning"]) ?? [:]
                    r["effort"] = .string(effort)
                    body["reasoning"] = .object(r)
                } else if let r = opts["reasoning"] {
                    body["reasoning"] = r
                }
                var vp: [String: JSONValue] = ["include_venice_system_prompt": .bool(false)]
                if let rawVP = AIProtocolUtils.JSONCodec.objectValue(opts["veniceParameters"]) {
                    for (k, v) in rawVP { vp[camelToSnake(k)] = v }
                }
                body["venice_parameters"] = .object(vp)
                if let topK = req.topK { body["top_k"] = .int(Int64(topK)) }
                if let minP = opts["minP"] { body["min_p"] = minP }
                if let rp = opts["repetitionPenalty"] { body["repetition_penalty"] = rp }
                return body
            },
            parseStream: OpenAIChat.parseSSEStream,
            makeStreamDecoder: { OpenAIChat.StreamDecoder(request: $0) }
        )
    }

    // MARK: - XAIResponses (packages/ai/src/protocols/xai-responses.ts — 3 symbols)

    public enum XAIResponses {
        public static let adapterID = "xai-responses"
        public static let name = "xAI Responses"

        // parity: ai/src/protocols/xai-responses.ts#OptionsInput [status=implemented hash=592ed96e69da]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var minP: Double?
            public init(minP: Double? = nil) { self.minP = minP }
        }

        private static let adapter = OpenResponses.ProviderAdapter(
            id: adapterID,
            name: name,
            lowerMedia: { part, inline, _ in
                guard part.media.kind == .video else { return nil }
                let filename = part.filename ?? "file"
                if let url = AIProtocolUtils.ProviderShared.mediaUrl(part.media) {
                    return .file(OpenResponses.OpenResponsesInputFile(filename: filename, file_url: url))
                }
                return inline.map { .file(OpenResponses.OpenResponsesInputFile(filename: filename, file_data: $0.dataUrl)) }
            }
        )

        private static let hostedTools: AIProtocolUtils.ResponsesHostedTools.Definitions = {
            var defs = AIProtocolUtils.ResponsesHostedTools.common
            defs["x_search_call"] = AIProtocolUtils.ResponsesHostedTools.Definition(name: "x_search") { $0.raw["action"] ?? .object([:]) }
            defs["image_generation_call"] = AIProtocolUtils.ResponsesHostedTools.Definition(name: "image_generation") { _ in .object([:]) }
            return defs
        }()

        // parity: ai/src/protocols/xai-responses.ts#protocol [status=implemented hash=4159e275d9c6]
        public static let `protocol` = ChatProtocolSpec(
            id: adapterID,
            framing: .sse,
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                if req.providerOptions?["contextManagement"] != nil {
                    throw AIProtocolUtils.ProviderShared.unsupportedOperation(
                        operation: "in-band-compaction",
                        message: "xAI requires explicit compaction through ai.compact; automatic context management is not supported",
                        provider: req.model.provider,
                        route: req.model.routeID
                    )
                }
                var body = try OpenResponses.fromRequestWithAdapter(req, adapter: adapter)
                body.removeValue(forKey: "presence_penalty")
                body.removeValue(forKey: "frequency_penalty")
                if let topK = req.topK { body["top_k"] = .int(Int64(topK)) }
                if let minP = req.providerOptions?["minP"] { body["min_p"] = minP }
                return body
            },
            parseStream: { bytes, req throws(AIProtocolUtils.ProtocolError) in
                try OpenResponses.parseSSEStream(bytes, request: req, adapter: adapter, hostedTools: hostedTools)
            },
            makeStreamDecoder: { req in
                OpenResponses.StreamDecoder(request: req, adapter: adapter, hostedTools: hostedTools)
            }
        )

        // parity: ai/src/protocols/xai-responses.ts#compact [status=implemented hash=9d0eb2ae1350]
        public static let compact = AIProtocolUtils.ResponsesCompaction.make(providerName: name) { req throws(AIProtocolUtils.ProtocolError) in
            try `protocol`.buildBody(req)
        }
    }

    // MARK: - ZAIChat & ZAIMessages (7 symbols)

    public enum ZAIChat {
        // parity: ai/src/protocols/zai-chat.ts#ReasoningEffort [status=implemented hash=ab511c97a1f0]
        public typealias ReasoningEffort = String

        // parity: ai/src/protocols/zai-chat.ts#OptionsInput [status=implemented hash=592ed96e69da]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var reasoningEffort: ReasoningEffort?
            public var toolStream: Bool?
            public var doSample: Bool?
            public var requestID: String?
            public var userID: String?
            public init(reasoningEffort: ReasoningEffort? = nil, toolStream: Bool? = nil, doSample: Bool? = nil, requestID: String? = nil, userID: String? = nil) {
                self.reasoningEffort = reasoningEffort; self.toolStream = toolStream
                self.doSample = doSample; self.requestID = requestID; self.userID = userID
            }
        }

        // parity: ai/src/protocols/zai-chat.ts#compatibility [status=implemented hash=1ce61aa4e6d8]
        public static let compatibility = AIProtocolUtils.ModelCompatibility(
            reasoningField: "reasoning_content",
            maxTokensField: "max_tokens",
            zaiToolStream: false
        )

        // parity: ai/src/protocols/zai-chat.ts#capabilities [status=implemented hash=88f845143713]
        public static let capabilities = AIProtocolUtils.ModelCapabilities(strictTools: false)

        // parity: ai/src/protocols/zai-chat.ts#protocol [status=implemented hash=1df861ef9eaa]
        public static let `protocol` = ChatProtocolSpec(
            id: "zai-chat",
            framing: .sseWithDone,
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var body = try OpenAIChat.fromRequest(req)
                let opts = req.providerOptions ?? [:]
                if let th = opts["thinking"] { body["thinking"] = th }
                if let ts = opts["toolStream"] { body["tool_stream"] = ts }
                if let ds = opts["doSample"] { body["do_sample"] = ds }
                if let rf = opts["responseFormat"] { body["response_format"] = rf }
                if let rid = opts["requestID"] { body["request_id"] = rid }
                if let uid = opts["userID"] { body["user_id"] = uid }
                return body
            },
            parseStream: OpenAIChat.parseSSEStream,
            makeStreamDecoder: { OpenAIChat.StreamDecoder(request: $0) }
        )
    }

    public enum ZAIMessages {
        // parity: ai/src/protocols/zai-messages.ts#OptionsInput [status=implemented hash=592ed96e69da]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var effort: String?
            public var thinkingType: String?
            public init(effort: String? = nil, thinkingType: String? = nil) {
                self.effort = effort; self.thinkingType = thinkingType
            }
        }

        // parity: ai/src/protocols/zai-messages.ts#protocol [status=implemented hash=57fad94f58c9]
        public static let `protocol` = ChatProtocolSpec(
            id: "zai-messages",
            framing: AnthropicMessages.framing,
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var stripped = req
                var opts = req.providerOptions ?? [:]
                let thinking = opts.removeValue(forKey: "thinking")
                stripped.providerOptions = opts
                var body = try AnthropicMessages.fromRequest(stripped)
                if let thinking { body["thinking"] = thinking }
                return body
            },
            parseStream: AnthropicMessages.parseSSEStream,
            makeStreamDecoder: { AnthropicMessages.StreamDecoder(request: $0) }
        )
    }

    // MARK: - SystemOne (packages/ai/src/protocols/system-one.ts — 8 symbols)

    public enum SystemOneProtocol {
        public static let id = "system-one"
        public static let name = "System One"

        // parity: ai/src/protocols/system-one.ts#DEFAULT_PATH [status=implemented hash=f2a1e904b095]
        public static let DEFAULT_PATH = "/systemone"

        // parity: ai/src/protocols/system-one.ts#DEFAULT_BASE_URL [status=implemented hash=90a98fcc1d06]
        public static let DEFAULT_BASE_URL = "https://api.typesafe.ai/v1"

        public enum DecisionQuestion: Equatable, Hashable, Sendable {
            case predicate(name: String, instructions: String, criteria: String? = nil)
            case choice(name: String, instructions: String, choices: [(value: String, description: String?)])
            case score(name: String, instructions: String, levels: [(label: String, description: String?)])

            public static func == (lhs: DecisionQuestion, rhs: DecisionQuestion) -> Bool {
                switch (lhs, rhs) {
                case let (.predicate(a1, a2, a3), .predicate(b1, b2, b3)):
                    return a1 == b1 && a2 == b2 && a3 == b3
                case let (.choice(a1, a2, a3), .choice(b1, b2, b3)):
                    return a1 == b1 && a2 == b2 && a3.count == b3.count
                        && zip(a3, b3).allSatisfy { $0.value == $1.value && $0.description == $1.description }
                case let (.score(a1, a2, a3), .score(b1, b2, b3)):
                    return a1 == b1 && a2 == b2 && a3.count == b3.count
                        && zip(a3, b3).allSatisfy { $0.label == $1.label && $0.description == $1.description }
                default:
                    return false
                }
            }

            public func hash(into hasher: inout Hasher) {
                switch self {
                case .predicate(let n, let i, let c): hasher.combine(0); hasher.combine(n); hasher.combine(i); hasher.combine(c)
                case .choice(let n, let i, _): hasher.combine(1); hasher.combine(n); hasher.combine(i)
                case .score(let n, let i, _): hasher.combine(2); hasher.combine(n); hasher.combine(i)
                }
            }

            public var name: String {
                switch self {
                case .predicate(let n, _, _), .choice(let n, _, _), .score(let n, _, _): return n
                }
            }
        }

        public enum DecisionInputPart: Equatable, Hashable, Sendable {
            case text(String)
            case json(JSONValue)
            case media(AIProtocolUtils.MediaAsset, filename: String? = nil)
        }

        public struct DecisionRequest: Equatable, Hashable, Sendable {
            public let model: AIProtocolUtils.ModelDescriptor
            public let input: [DecisionInputPart]
            public let questions: [DecisionQuestion]
            public let providerOptions: [String: JSONValue]?
            public let httpBody: [String: JSONValue]?

            public init(
                model: AIProtocolUtils.ModelDescriptor,
                input: [DecisionInputPart],
                questions: [DecisionQuestion],
                providerOptions: [String: JSONValue]? = nil,
                httpBody: [String: JSONValue]? = nil
            ) {
                self.model = model
                self.input = input
                self.questions = questions
                self.providerOptions = providerOptions
                self.httpBody = httpBody
            }
        }

        // parity: ai/src/protocols/system-one.ts#Response [status=implemented hash=b8254d7731fc]
        public struct Response: Equatable, Hashable, Sendable {
            public let model: String
            public let answers: [String: JSONValue]
            public let usage: [String: JSONValue]?
            public let id: String?
            public let provider: String?

            public init(model: String, answers: [String: JSONValue], usage: [String: JSONValue]? = nil, id: String? = nil, provider: String? = nil) {
                self.model = model; self.answers = answers; self.usage = usage; self.id = id; self.provider = provider
            }
        }

        public struct DecodedDecisionResponse: Equatable, Hashable, Sendable {
            public let answers: [JSONValue]
            public let inputTokens: Double?
            public let outputTokens: Double?
            public let totalTokens: Double?
            public let cost: Double?
            public let providerMetadata: AIProtocolUtils.ProviderMetadata
        }

        // parity: ai/src/protocols/system-one.ts#encodeBody [status=implemented hash=2731606d60e6]
        public static func encodeBody(
            _ request: DecisionRequest,
            fallbackMediaInput: String = "assets"
        ) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue] {
            var questionsMap: [String: JSONValue] = [:]
            for q in request.questions {
                switch q {
                case .predicate(let name, let instructions, let criteria):
                    var obj: [String: JSONValue] = ["type": .string("noul"), "instructions": .string(instructions)]
                    if let criteria { obj["criteria"] = .string(criteria) }
                    questionsMap[name] = .object(obj)
                case .score(let name, let instructions, let levels):
                    let criteria = levels.map { l -> JSONValue in
                        .string(l.description.map { "\(l.label): \($0)" } ?? l.label)
                    }
                    questionsMap[name] = .object(["type": .string("score"), "instructions": .string(instructions), "criteria": .array(criteria)])
                case .choice(let name, let instructions, let choices):
                    var criteria: [String: JSONValue] = [:]
                    for c in choices {
                        if criteria[c.value] != nil {
                            throw AIProtocolUtils.ProviderShared.invalidRequest("Decision choice options are sent as string keys; \"\(name)\" has duplicate key")
                        }
                        criteria[c.value] = c.description.map(JSONValue.string) ?? .null
                    }
                    questionsMap[name] = .object(["type": .string("choice"), "instructions": .string(instructions), "criteria": .object(criteria)])
                }
            }
            let plainValues: [JSONValue] = request.input.compactMap { part in
                switch part {
                case .text(let s): return .string(s)
                case .json(let j): return j
                case .media: return nil
                }
            }
            var body = AIProtocolUtils.JSONCodec.mergeObjects(request.providerOptions, request.httpBody)
            body["state"] = plainValues.count == 1 ? plainValues[0] : .array(plainValues)
            body["questions"] = .object(questionsMap)
            _ = request.model.compatibility?.mediaInput ?? fallbackMediaInput
            return body
        }

        // parity: ai/src/protocols/system-one.ts#toResponse [status=implemented hash=f9f41a5ef2b0]
        public static func toResponse(
            _ data: Response,
            request: DecisionRequest,
            providerMetadataKey: String
        ) throws(AIProtocolUtils.ProtocolError) -> DecodedDecisionResponse {
            let names = request.questions.map(\.name)
            guard data.answers.count == names.count, names.allSatisfy({ data.answers[$0] != nil }) else {
                throw AIProtocolUtils.ProviderShared.eventError(id, "System One answers do not match the requested questions")
            }
            let orderedAnswers = names.map { data.answers[$0]! }
            let inp = AIProtocolUtils.JSONCodec.doubleValue(data.usage?["input_tokens"])
            let out = AIProtocolUtils.JSONCodec.doubleValue(data.usage?["output_tokens"])
            let cost = AIProtocolUtils.JSONCodec.doubleValue(data.usage?["cost"])
            var meta: [String: JSONValue] = ["model": .string(data.model)]
            if let u = data.usage { meta["usage"] = .object(u) }
            if let rid = data.id { meta["responseId"] = .string(rid) }
            if let prov = data.provider { meta["provider"] = .string(prov) }
            return DecodedDecisionResponse(
                answers: orderedAnswers,
                inputTokens: inp,
                outputTokens: out,
                totalTokens: AIProtocolUtils.ProviderShared.totalTokens(inp, out, nil),
                cost: cost,
                providerMetadata: [providerMetadataKey: meta]
            )
        }

        public struct ProtocolDescriptor: Sendable {
            public let id: String
            public let name: String
            public let inlineMedia: Bool
            public init(id: String = SystemOneProtocol.id, name: String = SystemOneProtocol.name, inlineMedia: Bool = true) {
                self.id = id; self.name = name; self.inlineMedia = inlineMedia
            }
        }

        public struct RouteDescriptor: Sendable {
            public let id: String
            public let provider: String
            public let defaultBaseURL: String
            public let path: String
            public let `protocol`: ProtocolDescriptor
            public init(id: String = SystemOneProtocol.id, provider: String = "typesafe-ai", defaultBaseURL: String = DEFAULT_BASE_URL, path: String = DEFAULT_PATH, protocol proto: ProtocolDescriptor = ProtocolDescriptor()) {
                self.id = id; self.provider = provider; self.defaultBaseURL = defaultBaseURL; self.path = path; self.`protocol` = proto
            }
        }

        // parity: ai/src/protocols/system-one.ts#protocol [status=implemented hash=186fa255c445]
        public static let `protocol` = ProtocolDescriptor()

        // parity: ai/src/protocols/system-one.ts#route [status=implemented hash=1ecbc5eb0faa]
        public static let route = RouteDescriptor()

        // parity: ai/src/protocols/system-one.ts#SystemOne [status=implemented hash=21d915099675]
        public static let SystemOne = SystemOneProtocol.self
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

extension AIProtocols.IncrementalStreamDecoder {
    public mutating func beginNextRequest() throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.LLMEvent] { [] }
}
