/// Portable media, embeddings, decisions, speech, transcription, image, and video protocols for `OpenCodeAI`.
///
/// Ports all 29 non-chat protocol modules under `packages/ai/src/protocols/*`:
/// `alibaba-images`, `assemblyai-transcription`, `cartesia-speech`, `cloudflare-run-decisions`,
/// `cloudflare-workers-ai-images`, `deepgram-speech`, `deepgram-transcription`, `elevenlabs-speech`,
/// `elevenlabs-transcription`, `google-decisions`, `google-embed-content`, `google-images`,
/// `google-interactions-video`, `google-speech`, `google-transcription`,
/// `google-vertex-predict-embeddings`, `meta-images`, `minimax-images`, `minimax-video`,
/// `openai-decisions`, `openai-embeddings`, `openai-images`, `openai-speech`,
/// `openai-transcription`, `openrouter-video`, `seedance-video`, `xai-images`,
/// `xai-video`, and `zai-images`.
///
/// Strictly PORTABLE tier: zero OS imports, all HTTP via `OpenCodePlatform.HTTPTransport`.

import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

extension AIProtocols {

    // MARK: Shared Media / Embedding / Decision Protocol Primitives

    public enum MediaMode: String, Equatable, Hashable, Sendable, Codable {
        case inline
        case stream
        case queued
    }

    public struct MediaModelInput: Equatable, Hashable, Sendable {
        public let id: String
        public let provider: String?
        public let baseURL: String?
        public let providerOptions: [String: JSONValue]?

        public init(
            id: String,
            provider: String? = nil,
            baseURL: String? = nil,
            providerOptions: [String: JSONValue]? = nil
        ) {
            self.id = id
            self.provider = provider
            self.baseURL = baseURL
            self.providerOptions = providerOptions
        }
    }

    public struct MediaModelHandle: Equatable, Hashable, Sendable {
        public let id: String
        public let provider: String
        public let protocolID: String
        public let baseURL: String?
        public let path: String
        public let mode: MediaMode
        public let providerOptions: [String: JSONValue]?

        public init(
            id: String,
            provider: String,
            protocolID: String,
            baseURL: String?,
            path: String,
            mode: MediaMode,
            providerOptions: [String: JSONValue]? = nil
        ) {
            self.id = id
            self.provider = provider
            self.protocolID = protocolID
            self.baseURL = baseURL
            self.path = path
            self.mode = mode
            self.providerOptions = providerOptions
        }
    }

    public struct DecodedImageResponse: Equatable, Hashable, Sendable {
        public let images: [AIProtocolUtils.MediaAsset]
        public let usage: AIProtocolUtils.MediaUsage?
        public let providerMetadata: AIProtocolUtils.ProviderMetadata?

        public init(
            images: [AIProtocolUtils.MediaAsset],
            usage: AIProtocolUtils.MediaUsage? = nil,
            providerMetadata: AIProtocolUtils.ProviderMetadata? = nil
        ) {
            self.images = images
            self.usage = usage
            self.providerMetadata = providerMetadata
        }
    }

    public struct DecodedSpeechResponse: Equatable, Hashable, Sendable {
        public let audio: AIProtocolUtils.MediaAsset
        public let timestamps: [AIProtocolUtils.SpeechTimestampItem]
        public let usage: AIProtocolUtils.MediaUsage?
        public let providerMetadata: AIProtocolUtils.ProviderMetadata?

        public init(
            audio: AIProtocolUtils.MediaAsset,
            timestamps: [AIProtocolUtils.SpeechTimestampItem] = [],
            usage: AIProtocolUtils.MediaUsage? = nil,
            providerMetadata: AIProtocolUtils.ProviderMetadata? = nil
        ) {
            self.audio = audio
            self.timestamps = timestamps
            self.usage = usage
            self.providerMetadata = providerMetadata
        }
    }

    public struct TranscriptionWord: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let startSeconds: Double
        public let endSeconds: Double
        public let speaker: String?
        public let confidence: Double?

        public init(
            text: String,
            startSeconds: Double,
            endSeconds: Double,
            speaker: String? = nil,
            confidence: Double? = nil
        ) {
            self.text = text
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.speaker = speaker
            self.confidence = confidence
        }
    }

    public struct DecodedTranscriptionResponse: Equatable, Hashable, Sendable {
        public let text: String
        public let language: String?
        public let durationSeconds: Double?
        public let segments: [AIProtocolUtils.TranscriptionSegment]
        public let words: [TranscriptionWord]
        public let usage: AIProtocolUtils.MediaUsage?
        public let providerMetadata: AIProtocolUtils.ProviderMetadata?

        public init(
            text: String,
            language: String? = nil,
            durationSeconds: Double? = nil,
            segments: [AIProtocolUtils.TranscriptionSegment] = [],
            words: [TranscriptionWord] = [],
            usage: AIProtocolUtils.MediaUsage? = nil,
            providerMetadata: AIProtocolUtils.ProviderMetadata? = nil
        ) {
            self.text = text
            self.language = language
            self.durationSeconds = durationSeconds
            self.segments = segments
            self.words = words
            self.usage = usage
            self.providerMetadata = providerMetadata
        }
    }

    public struct MediaProtocolSpec: Sendable {
        public let identity: AIProtocolUtils.MediaIdentity
        public let mode: MediaMode
        public let defaultBaseURL: String?
        public let path: String
        public let buildBody: @Sendable ([String: JSONValue]) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue]
        public let parseResponse: @Sendable (String) throws(AIProtocolUtils.ProtocolError) -> JSONValue

        public init(
            identity: AIProtocolUtils.MediaIdentity,
            mode: MediaMode,
            defaultBaseURL: String? = nil,
            path: String = "",
            buildBody: @escaping @Sendable ([String: JSONValue]) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue] = { $0 },
            parseResponse: (@Sendable (String) throws(AIProtocolUtils.ProtocolError) -> JSONValue)? = nil
        ) {
            self.identity = identity
            self.mode = mode
            self.defaultBaseURL = defaultBaseURL
            self.path = path
            self.buildBody = buildBody
            let routeID = identity.id
            self.parseResponse = parseResponse ?? { raw throws(AIProtocolUtils.ProtocolError) in
                try AIProtocolUtils.ProviderShared.parseJson(route: routeID, input: raw, message: "Invalid \(routeID) JSON response")
            }
        }

        public func makeModel(_ input: MediaModelInput, pathOverride: String? = nil) -> MediaModelHandle {
            MediaModelHandle(
                id: input.id,
                provider: input.provider ?? identity.provider,
                protocolID: identity.id,
                baseURL: input.baseURL ?? defaultBaseURL,
                path: pathOverride ?? path,
                mode: mode,
                providerOptions: input.providerOptions
            )
        }
    }

    public struct ImageRequestPayload: Equatable, Hashable, Sendable {
        public let modelID: String
        public let prompt: String
        public let n: Int?
        public let aspect: String?
        public let resolution: String?
        public let images: [AIProtocolUtils.MediaAsset]?
        public let providerOptions: [String: JSONValue]?

        public init(
            modelID: String,
            prompt: String,
            n: Int? = nil,
            aspect: String? = nil,
            resolution: String? = nil,
            images: [AIProtocolUtils.MediaAsset]? = nil,
            providerOptions: [String: JSONValue]? = nil
        ) {
            self.modelID = modelID; self.prompt = prompt; self.n = n
            self.aspect = aspect; self.resolution = resolution
            self.images = images; self.providerOptions = providerOptions
        }
    }

    public struct SpeechRequestPayload: Equatable, Hashable, Sendable {
        public let modelID: String
        public let text: String
        public let voice: String?
        public let instructions: String?
        public let format: String?
        public let speed: Double?
        public let language: String?
        public let timestamps: Bool?
        public let streaming: Bool
        public let providerOptions: [String: JSONValue]?

        public init(
            modelID: String, text: String, voice: String? = nil, instructions: String? = nil,
            format: String? = nil, speed: Double? = nil, language: String? = nil,
            timestamps: Bool? = nil, streaming: Bool = false, providerOptions: [String: JSONValue]? = nil
        ) {
            self.modelID = modelID; self.text = text; self.voice = voice
            self.instructions = instructions; self.format = format; self.speed = speed
            self.language = language; self.timestamps = timestamps
            self.streaming = streaming; self.providerOptions = providerOptions
        }
    }

    public struct TranscriptionRequestPayload: Equatable, Hashable, Sendable {
        public let modelID: String
        public let audio: AIProtocolUtils.MediaAsset
        public let language: String?
        public let prompt: String?
        public let diarize: Bool?
        public let timestamps: String?
        public let streaming: Bool
        public let providerOptions: [String: JSONValue]?

        public init(
            modelID: String, audio: AIProtocolUtils.MediaAsset, language: String? = nil,
            prompt: String? = nil, diarize: Bool? = nil, timestamps: String? = nil,
            streaming: Bool = false, providerOptions: [String: JSONValue]? = nil
        ) {
            self.modelID = modelID; self.audio = audio; self.language = language
            self.prompt = prompt; self.diarize = diarize; self.timestamps = timestamps
            self.streaming = streaming; self.providerOptions = providerOptions
        }
    }

    public struct VideoRequestPayload: Equatable, Hashable, Sendable {
        public let modelID: String
        public let prompt: String
        public let durationSeconds: Int?
        public let aspect: String?
        public let resolution: String?
        public let images: [AIProtocolUtils.MediaAsset]?
        public let providerOptions: [String: JSONValue]?

        public init(
            modelID: String, prompt: String, durationSeconds: Int? = nil,
            aspect: String? = nil, resolution: String? = nil,
            images: [AIProtocolUtils.MediaAsset]? = nil, providerOptions: [String: JSONValue]? = nil
        ) {
            self.modelID = modelID; self.prompt = prompt; self.durationSeconds = durationSeconds
            self.aspect = aspect; self.resolution = resolution; self.images = images
            self.providerOptions = providerOptions
        }
    }

    public enum EmbeddingInputValue: Equatable, Hashable, Sendable {
        case text(String)
        case media(AIProtocolUtils.MediaAsset)
    }

    public struct EmbeddingRequestPayload: Equatable, Hashable, Sendable {
        public let model: AIProtocolUtils.ModelDescriptor
        public let values: [EmbeddingInputValue]
        public let dimensions: Int?
        public let inputType: String?
        public let providerOptions: [String: JSONValue]?
        public let httpBody: [String: JSONValue]?

        public init(
            model: AIProtocolUtils.ModelDescriptor,
            values: [EmbeddingInputValue],
            dimensions: Int? = nil,
            inputType: String? = nil,
            providerOptions: [String: JSONValue]? = nil,
            httpBody: [String: JSONValue]? = nil
        ) {
            self.model = model; self.values = values; self.dimensions = dimensions
            self.inputType = inputType; self.providerOptions = providerOptions; self.httpBody = httpBody
        }
    }

    public struct EmbeddingResponsePayload: Equatable, Hashable, Sendable {
        public let embeddings: [[Double]]
        public let inputTokens: Double?
        public let providerMetadata: AIProtocolUtils.ProviderMetadata

        public init(embeddings: [[Double]], inputTokens: Double? = nil, providerMetadata: AIProtocolUtils.ProviderMetadata = [:]) {
            self.embeddings = embeddings; self.inputTokens = inputTokens; self.providerMetadata = providerMetadata
        }
    }

    public struct EmbeddingProtocolSpec: Sendable {
        public let id: String
        public let name: String
        public let buildBody: @Sendable (EmbeddingRequestPayload) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue]
        public let decodeResponse: @Sendable (String, String) throws(AIProtocolUtils.ProtocolError) -> EmbeddingResponsePayload

        public init(
            id: String,
            name: String,
            buildBody: @escaping @Sendable (EmbeddingRequestPayload) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue],
            decodeResponse: @escaping @Sendable (String, String) throws(AIProtocolUtils.ProtocolError) -> EmbeddingResponsePayload
        ) {
            self.id = id; self.name = name; self.buildBody = buildBody; self.decodeResponse = decodeResponse
        }
    }

    public struct EmbeddingRouteSpec: Sendable {
        public let id: String
        public let provider: String
        public let `protocol`: EmbeddingProtocolSpec
        public let defaultBaseURL: String?
        public let pathBuilder: @Sendable (String) -> String
        public let maxValues: Int?

        public init(
            id: String,
            provider: String,
            protocol proto: EmbeddingProtocolSpec,
            defaultBaseURL: String? = nil,
            path: String,
            maxValues: Int? = nil
        ) {
            self.id = id; self.provider = provider; self.`protocol` = proto
            self.defaultBaseURL = defaultBaseURL; self.pathBuilder = { _ in path }; self.maxValues = maxValues
        }

        public init(
            id: String,
            provider: String,
            protocol proto: EmbeddingProtocolSpec,
            defaultBaseURL: String? = nil,
            pathBuilder: @escaping @Sendable (String) -> String,
            maxValues: Int? = nil
        ) {
            self.id = id; self.provider = provider; self.`protocol` = proto
            self.defaultBaseURL = defaultBaseURL; self.pathBuilder = pathBuilder; self.maxValues = maxValues
        }
    }

    public struct DecisionProtocolSpec: Sendable {
        public let id: String
        public let name: String
        public let provider: String
        public let buildBody: @Sendable (SystemOneProtocol.DecisionRequest) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue]

        public init(
            id: String,
            name: String,
            provider: String,
            buildBody: @escaping @Sendable (SystemOneProtocol.DecisionRequest) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue]
        ) {
            self.id = id; self.name = name; self.provider = provider; self.buildBody = buildBody
        }
    }

    public struct DecisionRouteSpec: Sendable {
        public let id: String
        public let provider: String
        public let `protocol`: DecisionProtocolSpec
        public let defaultBaseURL: String?
        public let pathBuilder: @Sendable (String) -> String

        public init(
            id: String,
            provider: String,
            protocol proto: DecisionProtocolSpec,
            defaultBaseURL: String? = nil,
            path: String
        ) {
            self.id = id; self.provider = provider; self.`protocol` = proto
            self.defaultBaseURL = defaultBaseURL; self.pathBuilder = { _ in path }
        }

        public init(
            id: String,
            provider: String,
            protocol proto: DecisionProtocolSpec,
            defaultBaseURL: String? = nil,
            pathBuilder: @escaping @Sendable (String) -> String
        ) {
            self.id = id; self.provider = provider; self.`protocol` = proto
            self.defaultBaseURL = defaultBaseURL; self.pathBuilder = pathBuilder
        }
    }

    // MARK: - 1. AlibabaImages (packages/ai/src/protocols/alibaba-images.ts — 6 symbols)

    public enum AlibabaImages {
        // parity: ai/src/protocols/alibaba-images.ts#PATH [status=implemented hash=27ab16aeb685]
        public static let PATH = "/services/aigc/multimodal-generation/generation"

        // parity: ai/src/protocols/alibaba-images.ts#AlibabaImageOptions [status=implemented hash=a457a961d911]
        public typealias AlibabaImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/alibaba-images.ts#Request [status=implemented hash=52a04160fbc7]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/alibaba-images.ts#protocol [status=implemented hash=32b174ab3a05]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "alibaba-images", name: "Alibaba Images", provider: "alibaba"),
            mode: .inline,
            path: PATH
        )

        // parity: ai/src/protocols/alibaba-images.ts#model [status=implemented hash=abf777b06d34]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/alibaba-images.ts#AlibabaImages [status=implemented hash=88aab82a16b1]
        public static let AlibabaImages = AIProtocols.AlibabaImages.self
    }

    // MARK: - 2. AssemblyAITranscription (packages/ai/src/protocols/assemblyai-transcription.ts — 9 symbols)

    public enum AssemblyAITranscription {
        // parity: ai/src/protocols/assemblyai-transcription.ts#DEFAULT_BASE_URL [status=implemented hash=cda670435821]
        public static let DEFAULT_BASE_URL = "https://api.assemblyai.com"

        // parity: ai/src/protocols/assemblyai-transcription.ts#PATH [status=implemented hash=4e90f44c27bd]
        public static let PATH = "/v2/transcript"

        // parity: ai/src/protocols/assemblyai-transcription.ts#UPLOAD_PATH [status=implemented hash=95a896564a6a]
        public static let UPLOAD_PATH = "/v2/upload"

        // parity: ai/src/protocols/assemblyai-transcription.ts#AssemblyAITranscriptionOptions [status=implemented hash=7f748f1b86a7]
        public typealias AssemblyAITranscriptionOptions = [String: JSONValue]

        // parity: ai/src/protocols/assemblyai-transcription.ts#Request [status=implemented hash=ae2fc21d671a]
        public typealias Request = TranscriptionRequestPayload

        // parity: ai/src/protocols/assemblyai-transcription.ts#Token [status=implemented hash=0581afea4c14]
        public struct Token: Equatable, Hashable, Sendable, Codable {
            public let transcriptID: String
            public init(transcriptID: String) { self.transcriptID = transcriptID }
        }

        // parity: ai/src/protocols/assemblyai-transcription.ts#protocol [status=implemented hash=108a03f17d63]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "assemblyai-transcription", name: "AssemblyAI", provider: "assemblyai"),
            mode: .queued,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/assemblyai-transcription.ts#model [status=implemented hash=6096dac4e957]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/assemblyai-transcription.ts#AssemblyAITranscription [status=implemented hash=a2d8bba59152]
        public static let AssemblyAITranscription = AIProtocols.AssemblyAITranscription.self
    }

    // MARK: - 3. CartesiaSpeech (packages/ai/src/protocols/cartesia-speech.ts — 10 symbols)

    public enum CartesiaSpeech {
        // parity: ai/src/protocols/cartesia-speech.ts#DEFAULT_BASE_URL [status=implemented hash=497d69cbc59b]
        public static let DEFAULT_BASE_URL = "https://api.cartesia.ai"

        // parity: ai/src/protocols/cartesia-speech.ts#API_VERSION [status=implemented hash=3216859930a6]
        public static let API_VERSION = "2026-08-14"

        // parity: ai/src/protocols/cartesia-speech.ts#BYTES_PATH [status=implemented hash=559345b3508b]
        public static let BYTES_PATH = "/tts/bytes"

        // parity: ai/src/protocols/cartesia-speech.ts#SSE_PATH [status=implemented hash=e30f9f5f8d81]
        public static let SSE_PATH = "/tts/sse"

        // parity: ai/src/protocols/cartesia-speech.ts#CartesiaEncoding [status=implemented hash=e659e0a52d26]
        public typealias CartesiaEncoding = AIProtocolUtils.SpeechStream.PcmEncoding

        // parity: ai/src/protocols/cartesia-speech.ts#CartesiaSpeechOptions [status=implemented hash=77653b8fd1f7]
        public typealias CartesiaSpeechOptions = [String: JSONValue]

        // parity: ai/src/protocols/cartesia-speech.ts#Request [status=implemented hash=8f386fc9e7be]
        public typealias Request = SpeechRequestPayload

        // parity: ai/src/protocols/cartesia-speech.ts#protocol [status=implemented hash=d0cc2da7275d]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "cartesia-speech", name: "Cartesia", provider: "cartesia"),
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: BYTES_PATH
        )

        // parity: ai/src/protocols/cartesia-speech.ts#model [status=implemented hash=db5aabf853cf]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/cartesia-speech.ts#CartesiaSpeech [status=implemented hash=46895865cd3f]
        public static let CartesiaSpeech = AIProtocols.CartesiaSpeech.self
    }

    // MARK: - 4. CloudflareRunDecisions (packages/ai/src/protocols/cloudflare-run-decisions.ts — 3 symbols)

    public enum CloudflareRunDecisions {
        // parity: ai/src/protocols/cloudflare-run-decisions.ts#protocol [status=implemented hash=f8577cecaa59]
        public static let `protocol` = DecisionProtocolSpec(
            id: "cloudflare-run-decisions",
            name: "Cloudflare Run Decisions",
            provider: "cloudflare-workers-ai",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                try SystemOneProtocol.encodeBody(req, fallbackMediaInput: "assets")
            }
        )

        // parity: ai/src/protocols/cloudflare-run-decisions.ts#route [status=implemented hash=85f644ec7476]
        public static let route = DecisionRouteSpec(
            id: "cloudflare-run-decisions",
            provider: "cloudflare-workers-ai",
            protocol: `protocol`,
            pathBuilder: { modelID in "/\(modelID)" }
        )

        // parity: ai/src/protocols/cloudflare-run-decisions.ts#CloudflareRunDecisions [status=implemented hash=d68e2d21c690]
        public static let CloudflareRunDecisions = AIProtocols.CloudflareRunDecisions.self
    }

    // MARK: - 5. CloudflareWorkersAIImages (packages/ai/src/protocols/cloudflare-workers-ai-images.ts — 5 symbols)

    public enum CloudflareWorkersAIImages {
        // parity: ai/src/protocols/cloudflare-workers-ai-images.ts#CloudflareWorkersAIImageOptions [status=implemented hash=82c6d1c29265]
        public typealias CloudflareWorkersAIImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/cloudflare-workers-ai-images.ts#Request [status=implemented hash=163fb959970f]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/cloudflare-workers-ai-images.ts#protocol [status=implemented hash=32b174ab3a05]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "cloudflare-workers-ai-images", name: "Cloudflare Workers AI Images", provider: "cloudflare-workers-ai"),
            mode: .inline
        )

        // parity: ai/src/protocols/cloudflare-workers-ai-images.ts#model [status=implemented hash=961dcfe05aa4]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input, pathOverride: "/\(input.id)")
        }

        // parity: ai/src/protocols/cloudflare-workers-ai-images.ts#CloudflareWorkersAIImages [status=implemented hash=19dad9db5879]
        public static let CloudflareWorkersAIImages = AIProtocols.CloudflareWorkersAIImages.self
    }

    // MARK: - 6. DeepgramSpeech (packages/ai/src/protocols/deepgram-speech.ts — 8 symbols)

    public enum DeepgramSpeech {
        // parity: ai/src/protocols/deepgram-speech.ts#DEFAULT_BASE_URL [status=implemented hash=0a1f66140d03]
        public static let DEFAULT_BASE_URL = "https://api.deepgram.com"

        // parity: ai/src/protocols/deepgram-speech.ts#PATH [status=implemented hash=47b420561e5c]
        public static let PATH = "/v1/speak"

        // parity: ai/src/protocols/deepgram-speech.ts#DeepgramEncoding [status=implemented hash=4e5c0fc0fe62]
        public typealias DeepgramEncoding = String

        // parity: ai/src/protocols/deepgram-speech.ts#DeepgramSpeechOptions [status=implemented hash=14b4237a4c98]
        public typealias DeepgramSpeechOptions = [String: JSONValue]

        // parity: ai/src/protocols/deepgram-speech.ts#Request [status=implemented hash=560a21e16471]
        public typealias Request = SpeechRequestPayload

        // parity: ai/src/protocols/deepgram-speech.ts#protocol [status=implemented hash=698ac4ffa9ea]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "deepgram-speech", name: "Deepgram", provider: "deepgram"),
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/deepgram-speech.ts#model [status=implemented hash=9685a30465f3]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/deepgram-speech.ts#DeepgramSpeech [status=implemented hash=362b3b12d292]
        public static let DeepgramSpeech = AIProtocols.DeepgramSpeech.self
    }

    // MARK: - 7. DeepgramTranscription (packages/ai/src/protocols/deepgram-transcription.ts — 7 symbols)

    public enum DeepgramTranscription {
        public static let routeIdentity = AIProtocolUtils.MediaIdentity(id: "deepgram-transcription", name: "Deepgram", provider: "deepgram")

        // parity: ai/src/protocols/deepgram-transcription.ts#DEFAULT_BASE_URL [status=implemented hash=0a1f66140d03]
        public static let DEFAULT_BASE_URL = "https://api.deepgram.com"

        // parity: ai/src/protocols/deepgram-transcription.ts#PATH [status=implemented hash=dca308dcac99]
        public static let PATH = "/v1/listen"

        // parity: ai/src/protocols/deepgram-transcription.ts#DeepgramTranscriptionOptions [status=implemented hash=2b21f8e48b1e]
        public typealias DeepgramTranscriptionOptions = [String: JSONValue]

        // parity: ai/src/protocols/deepgram-transcription.ts#Request [status=implemented hash=c7a294bf58a6]
        public typealias Request = TranscriptionRequestPayload

        public static func buildQuery(_ request: Request) throws(AIProtocolUtils.ProtocolError) -> [String: [String]] {
            if request.prompt != nil {
                throw routeIdentity.unsupported("media.prompt", "\(routeIdentity.name) does not accept a prompt")
            }
            var params: [String: JSONValue] = [
                "model": .string(request.modelID),
                "smart_format": .bool(true),
            ]
            if let lang = request.language {
                params["language"] = .string(lang)
            } else {
                params["detect_language"] = .bool(true)
            }
            if request.diarize == true {
                params["diarize_model"] = .string("latest")
            }
            if request.diarize == true || request.timestamps == "segment" {
                params["utterances"] = .bool(true)
            }
            let merged = AIProtocolUtils.JSONCodec.mergeObjects(params, request.providerOptions)
            return try AIProtocolUtils.MediaInput.query(route: routeIdentity.id, values: merged)
        }

        public static func fromRequest(_ request: Request) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue] {
            let query = try buildQuery(request)
            let queryJSON: [String: JSONValue] = query.mapValues { vals in
                vals.count == 1 ? .string(vals[0]) : .array(vals.map(JSONValue.string))
            }
            if let url = AIProtocolUtils.ProviderShared.mediaUrl(request.audio) {
                return [
                    "url": .string(url),
                    "query": .object(queryJSON),
                ]
            }
            let raw = try AIProtocolUtils.MediaInput.inlineBytes(route: routeIdentity.id, asset: request.audio)
            return [
                "audio_base64": .string(bytesToBase64(raw)),
                "content_type": .string(request.audio.mediaType),
                "query": .object(queryJSON),
            ]
        }

        public static func decodeResponse(_ text: String) throws(AIProtocolUtils.ProtocolError) -> DecodedTranscriptionResponse {
            let parsed = try AIProtocolUtils.ProviderShared.parseJson(
                route: routeIdentity.id,
                input: text,
                message: "Invalid Deepgram transcription response"
            )
            guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                  let results = AIProtocolUtils.JSONCodec.objectValue(obj["results"]),
                  let channels = AIProtocolUtils.JSONCodec.arrayValue(results["channels"]),
                  let firstChannel = channels.first.flatMap(AIProtocolUtils.JSONCodec.objectValue),
                  let alternatives = AIProtocolUtils.JSONCodec.arrayValue(firstChannel["alternatives"]),
                  let alternative = alternatives.first.flatMap(AIProtocolUtils.JSONCodec.objectValue),
                  let transcript = AIProtocolUtils.JSONCodec.stringValue(alternative["transcript"])
            else {
                throw routeIdentity.frameError("\(routeIdentity.name) returned no transcript", body: text)
            }

            func speakerString(_ value: JSONValue?) -> String? {
                if let i = AIProtocolUtils.JSONCodec.intValue(value) { return String(i) }
                return AIProtocolUtils.JSONCodec.stringValue(value)
            }

            func parseWord(_ raw: JSONValue) -> TranscriptionWord? {
                guard let w = AIProtocolUtils.JSONCodec.objectValue(raw),
                      let wordStr = AIProtocolUtils.JSONCodec.stringValue(w["punctuated_word"]) ?? AIProtocolUtils.JSONCodec.stringValue(w["word"]),
                      let start = AIProtocolUtils.JSONCodec.doubleValue(w["start"]),
                      let end = AIProtocolUtils.JSONCodec.doubleValue(w["end"])
                else { return nil }
                return TranscriptionWord(
                    text: wordStr,
                    startSeconds: start,
                    endSeconds: end,
                    speaker: speakerString(w["speaker"]),
                    confidence: AIProtocolUtils.JSONCodec.doubleValue(w["confidence"])
                )
            }

            let words = (AIProtocolUtils.JSONCodec.arrayValue(alternative["words"]) ?? []).compactMap(parseWord)

            var segments: [AIProtocolUtils.TranscriptionSegment] = []
            if let utterances = AIProtocolUtils.JSONCodec.arrayValue(results["utterances"]) {
                for rawU in utterances {
                    guard let u = AIProtocolUtils.JSONCodec.objectValue(rawU),
                          let start = AIProtocolUtils.JSONCodec.doubleValue(u["start"]),
                          let end = AIProtocolUtils.JSONCodec.doubleValue(u["end"]),
                          let uttText = AIProtocolUtils.JSONCodec.stringValue(u["transcript"])
                    else { continue }
                    let uttWords = (AIProtocolUtils.JSONCodec.arrayValue(u["words"]) ?? []).compactMap(parseWord)
                    if uttWords.isEmpty {
                        segments.append(AIProtocolUtils.TranscriptionSegment(
                            text: uttText,
                            start: start,
                            end: end,
                            speaker: speakerString(u["speaker"])
                        ))
                    } else {
                        let turns = AIProtocolUtils.SpeakerTurns.group(uttWords) { $0.speaker }
                        for turn in turns where !turn.isEmpty {
                            segments.append(AIProtocolUtils.TranscriptionSegment(
                                text: turn.map(\.text).joined(separator: " "),
                                start: turn.first!.startSeconds,
                                end: turn.last!.endSeconds,
                                speaker: turn.first!.speaker
                            ))
                        }
                    }
                }
            }

            let meta = AIProtocolUtils.JSONCodec.objectValue(obj["metadata"])
            let duration = AIProtocolUtils.JSONCodec.doubleValue(meta?["duration"])
            let requestID = AIProtocolUtils.JSONCodec.stringValue(meta?["request_id"])
            let language = AIProtocolUtils.JSONCodec.stringValue(firstChannel["detected_language"])?.lowercased()

            return DecodedTranscriptionResponse(
                text: transcript,
                language: language,
                durationSeconds: duration,
                segments: segments,
                words: words,
                usage: duration.map { .seconds($0) },
                providerMetadata: requestID.map { ["deepgram": ["requestId": .string($0)]] }
            )
        }

        // parity: ai/src/protocols/deepgram-transcription.ts#protocol [status=implemented hash=48203598c073]
        public static let `protocol` = MediaProtocolSpec(
            identity: routeIdentity,
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH,
            buildBody: { input throws(AIProtocolUtils.ProtocolError) in
                guard let modelID = AIProtocolUtils.JSONCodec.stringValue(input["model"])
                    ?? AIProtocolUtils.JSONCodec.stringValue(input["modelID"]),
                      !modelID.isEmpty else {
                    throw AIProtocolUtils.ProviderShared.invalidRequest("Deepgram transcription requires model")
                }
                let asset: AIProtocolUtils.MediaAsset
                if let url = AIProtocolUtils.JSONCodec.stringValue(input["url"]) {
                    asset = .url(url, mediaType: AIProtocolUtils.JSONCodec.stringValue(input["mediaType"]) ?? "audio/mpeg")
                } else if let b64 = AIProtocolUtils.JSONCodec.stringValue(input["audio_base64"]) {
                    asset = .base64(b64, mediaType: AIProtocolUtils.JSONCodec.stringValue(input["mediaType"]) ?? "audio/mpeg")
                } else {
                    throw AIProtocolUtils.ProviderShared.invalidRequest("Deepgram transcription requires url or audio_base64")
                }
                let req = Request(
                    modelID: modelID,
                    audio: asset,
                    language: AIProtocolUtils.JSONCodec.stringValue(input["language"]),
                    prompt: AIProtocolUtils.JSONCodec.stringValue(input["prompt"]),
                    diarize: AIProtocolUtils.JSONCodec.boolValue(input["diarize"]),
                    timestamps: AIProtocolUtils.JSONCodec.stringValue(input["timestamps"]),
                    providerOptions: AIProtocolUtils.JSONCodec.objectValue(input["providerOptions"])
                )
                return try fromRequest(req)
            },
            parseResponse: { text throws(AIProtocolUtils.ProtocolError) in
                let decoded = try decodeResponse(text)
                var out: [String: JSONValue] = [
                    "text": .string(decoded.text),
                    "segments": .array(decoded.segments.map { seg in
                        var s: [String: JSONValue] = [
                            "text": .string(seg.text),
                            "start": .double(seg.start),
                            "end": .double(seg.end),
                        ]
                        if let spk = seg.speaker { s["speaker"] = .string(spk) }
                        return .object(s)
                    }),
                ]
                if let lang = decoded.language { out["language"] = .string(lang) }
                if let dur = decoded.durationSeconds { out["durationSeconds"] = .double(dur) }
                return .object(out)
            }
        )

        // parity: ai/src/protocols/deepgram-transcription.ts#model [status=implemented hash=1af1524f717f]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/deepgram-transcription.ts#DeepgramTranscription [status=implemented hash=ca1514ca3079]
        public static let DeepgramTranscription = AIProtocols.DeepgramTranscription.self
    }

    // MARK: - 8. ElevenLabsSpeech (packages/ai/src/protocols/elevenlabs-speech.ts — 8 symbols)

    public enum ElevenLabsSpeech {
        public static let routeIdentity = AIProtocolUtils.MediaIdentity(id: "elevenlabs-speech", name: "ElevenLabs", provider: "elevenlabs")

        // parity: ai/src/protocols/elevenlabs-speech.ts#DEFAULT_BASE_URL [status=implemented hash=3992eb92ee13]
        public static let DEFAULT_BASE_URL = "https://api.elevenlabs.io"

        // parity: ai/src/protocols/elevenlabs-speech.ts#PATH [status=implemented hash=11a9ef52923a]
        public static let PATH = "/v1/text-to-speech"

        // parity: ai/src/protocols/elevenlabs-speech.ts#ElevenLabsOutputFormat [status=implemented hash=37ac60dd5922]
        public typealias ElevenLabsOutputFormat = String

        // parity: ai/src/protocols/elevenlabs-speech.ts#ElevenLabsSpeechOptions [status=implemented hash=46ddfbac8ccd]
        public typealias ElevenLabsSpeechOptions = [String: JSONValue]

        // parity: ai/src/protocols/elevenlabs-speech.ts#Request [status=implemented hash=97ed8161a20a]
        public typealias Request = SpeechRequestPayload

        private static let defaultOutputFormats: [String: String] = [
            "mp3": "mp3_44100_128",
            "pcm": "pcm_24000",
            "wav": "wav_24000",
            "opus": "opus_48000_64",
        ]

        private static let pcmCodecs: [String: AIProtocolUtils.SpeechStream.PcmEncoding] = [
            "pcm": .pcm_s16le,
            "ulaw": .pcm_mulaw,
            "alaw": .pcm_alaw,
        ]

        public static func outputFormat(for request: Request) throws(AIProtocolUtils.ProtocolError) -> String {
            let explicit = AIProtocolUtils.JSONCodec.stringValue(request.providerOptions?["outputFormat"])
            guard let format = explicit ?? defaultOutputFormats[request.format ?? "mp3"] else {
                throw routeIdentity.unsupported(
                    "media.format",
                    "\(routeIdentity.name) has no default output format for \"\(request.format ?? "")\"; pass providerOptions.outputFormat"
                )
            }
            if request.streaming && format.hasPrefix("wav_") {
                throw routeIdentity.unsupported(
                    "media.format",
                    "\(routeIdentity.name) streams mp3, pcm, opus, ulaw, and alaw but not \"\(format)\"; use generate for WAV"
                )
            }
            return format
        }

        public static func requestPath(for request: Request) -> String {
            let encodedVoice = AIProtocolUtils.JSONCodec.percentEncodePathComponent(request.voice ?? "")
            let streamSuffix = request.streaming ? "/stream" : ""
            let tsSuffix = request.timestamps == true ? "/with-timestamps" : ""
            return "\(PATH)/\(encodedVoice)\(streamSuffix)\(tsSuffix)"
        }

        public static func fromRequest(_ request: Request) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue] {
            if request.instructions != nil {
                throw routeIdentity.unsupported("media.instructions", "\(routeIdentity.name) does not support instructions")
            }
            guard let voice = request.voice, !voice.isEmpty else {
                throw AIProtocolUtils.ProviderShared.invalidRequest("\(routeIdentity.name) requires a voice id; pass it as `voice`")
            }
            _ = try outputFormat(for: request)
            var base: [String: JSONValue] = [
                "text": .string(request.text),
                "model_id": .string(request.modelID),
            ]
            if let lang = request.language {
                base["language_code"] = .string(lang)
            }
            if let speed = request.speed {
                base["voice_settings"] = .object(["speed": .double(speed)])
            }
            var native = request.providerOptions ?? [:]
            native.removeValue(forKey: "outputFormat")
            return AIProtocolUtils.JSONCodec.mergeObjects(base, native)
        }

        public static func describeOutputFormat(_ format: String) -> AIProtocolUtils.SpeechStream.FormatMetadata {
            let parts = format.split(separator: "_").map(String.init)
            let codec = parts.first ?? format
            let sampleRate = parts.count > 1 ? Int(parts[1]) : nil
            if let encoding = pcmCodecs[codec] {
                return AIProtocolUtils.SpeechStream.pcm(encoding: encoding, sampleRate: sampleRate)
            }
            return AIProtocolUtils.SpeechStream.container(format: codec, sampleRate: sampleRate)
        }

        public static func decodeTimestampedResponse(
            _ text: String,
            format: String = "mp3_44100_128",
            headers: [String: String] = [:]
        ) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.SpeechEvent] {
            var audioState = AIProtocolUtils.SpeechStream.Audio()
            var events: [AIProtocolUtils.SpeechEvent] = []
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init).filter { !$0.trimmingASCIIWhitespace().isEmpty }
            let records = lines.isEmpty ? [text] : lines
            for record in records {
                let parsed = try AIProtocolUtils.ProviderShared.parseJson(
                    route: routeIdentity.id,
                    input: record,
                    message: "Invalid ElevenLabs speech JSON record"
                )
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                      let b64 = AIProtocolUtils.JSONCodec.stringValue(obj["audio_base64"]) else {
                    throw routeIdentity.frameError("ElevenLabs record missing audio_base64", body: record)
                }
                let bytes: [UInt8]
                do {
                    bytes = try base64ToBytes(b64)
                } catch {
                    throw routeIdentity.frameError("ElevenLabs record contains invalid base64 audio", body: record)
                }
                events.append(contentsOf: AIProtocolUtils.SpeechStream.delta(&audioState, chunk: bytes))
                if let alignment = AIProtocolUtils.JSONCodec.objectValue(obj["alignment"]) {
                    let chars = (AIProtocolUtils.JSONCodec.arrayValue(alignment["characters"]) ?? []).compactMap(AIProtocolUtils.JSONCodec.stringValue)
                    let starts = (AIProtocolUtils.JSONCodec.arrayValue(alignment["character_start_times_seconds"]) ?? []).compactMap(AIProtocolUtils.JSONCodec.doubleValue)
                    let ends = (AIProtocolUtils.JSONCodec.arrayValue(alignment["character_end_times_seconds"]) ?? []).compactMap(AIProtocolUtils.JSONCodec.doubleValue)
                    events.append(contentsOf: AIProtocolUtils.SpeechStream.timestamps(texts: chars, starts: starts, ends: ends))
                }
            }
            let fmtMeta = describeOutputFormat(format)
            let loweredHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
            let usage = AIProtocolUtils.SpeechStream.headerUsage(type: "credits", value: loweredHeaders["character-cost"])
            let reqID = loweredHeaders["request-id"]
            let finishEvents = try AIProtocolUtils.SpeechStream.finish(
                route: routeIdentity,
                state: audioState,
                mediaType: fmtMeta.mediaType,
                info: fmtMeta.info,
                usage: usage,
                providerMetadata: reqID.map { ["elevenlabs": ["requestId": .string($0)]] }
            )
            events.append(contentsOf: finishEvents)
            return events
        }

        // parity: ai/src/protocols/elevenlabs-speech.ts#protocol [status=implemented hash=699b27e6663f]
        public static let `protocol` = MediaProtocolSpec(
            identity: routeIdentity,
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH,
            buildBody: { input throws(AIProtocolUtils.ProtocolError) in
                let req = Request(
                    modelID: AIProtocolUtils.JSONCodec.stringValue(input["model_id"])
                        ?? AIProtocolUtils.JSONCodec.stringValue(input["model"])
                        ?? "eleven_multilingual_v2",
                    text: AIProtocolUtils.JSONCodec.stringValue(input["text"]) ?? "",
                    voice: AIProtocolUtils.JSONCodec.stringValue(input["voice"]),
                    instructions: AIProtocolUtils.JSONCodec.stringValue(input["instructions"]),
                    format: AIProtocolUtils.JSONCodec.stringValue(input["format"]),
                    speed: AIProtocolUtils.JSONCodec.doubleValue(input["speed"]),
                    language: AIProtocolUtils.JSONCodec.stringValue(input["language"])
                        ?? AIProtocolUtils.JSONCodec.stringValue(input["language_code"]),
                    timestamps: AIProtocolUtils.JSONCodec.boolValue(input["timestamps"]),
                    streaming: AIProtocolUtils.JSONCodec.boolValue(input["streaming"]) ?? false,
                    providerOptions: AIProtocolUtils.JSONCodec.objectValue(input["providerOptions"])
                )
                return try fromRequest(req)
            },
            parseResponse: { text throws(AIProtocolUtils.ProtocolError) in
                let events = try decodeTimestampedResponse(text)
                var timestampCount = 0
                var audioByteCount = 0
                for ev in events {
                    switch ev {
                    case .audioDelta(let b): audioByteCount += b.count
                    case .timestamps(let items): timestampCount += items.count
                    case .finish: break
                    }
                }
                return .object([
                    "audioBytes": .int(Int64(audioByteCount)),
                    "timestamps": .int(Int64(timestampCount)),
                ])
            }
        )

        // parity: ai/src/protocols/elevenlabs-speech.ts#model [status=implemented hash=734377e50dce]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/elevenlabs-speech.ts#ElevenLabsSpeech [status=implemented hash=f1e22f4afd54]
        public static let ElevenLabsSpeech = AIProtocols.ElevenLabsSpeech.self
    }

    // MARK: - 9. ElevenLabsTranscription (packages/ai/src/protocols/elevenlabs-transcription.ts — 7 symbols)

    public enum ElevenLabsTranscription {
        // parity: ai/src/protocols/elevenlabs-transcription.ts#DEFAULT_BASE_URL [status=implemented hash=3992eb92ee13]
        public static let DEFAULT_BASE_URL = "https://api.elevenlabs.io"

        // parity: ai/src/protocols/elevenlabs-transcription.ts#PATH [status=implemented hash=fab9f6321ee5]
        public static let PATH = "/v1/speech-to-text"

        // parity: ai/src/protocols/elevenlabs-transcription.ts#ElevenLabsTranscriptionOptions [status=implemented hash=6a4d1748c251]
        public typealias ElevenLabsTranscriptionOptions = [String: JSONValue]

        // parity: ai/src/protocols/elevenlabs-transcription.ts#Request [status=implemented hash=0dffb2c6bc51]
        public typealias Request = TranscriptionRequestPayload

        // parity: ai/src/protocols/elevenlabs-transcription.ts#protocol [status=implemented hash=0973adfe9fae]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "elevenlabs-transcription", name: "ElevenLabs", provider: "elevenlabs"),
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/elevenlabs-transcription.ts#model [status=implemented hash=92d899c272cb]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/elevenlabs-transcription.ts#ElevenLabsTranscription [status=implemented hash=e5dd8f6ca874]
        public static let ElevenLabsTranscription = AIProtocols.ElevenLabsTranscription.self
    }

    // MARK: - 10. GoogleDecisions (packages/ai/src/protocols/google-decisions.ts — 4 symbols)

    public enum GoogleDecisions {
        // parity: ai/src/protocols/google-decisions.ts#DEFAULT_BASE_URL [status=implemented hash=ae7b30027e03]
        public static let DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

        // parity: ai/src/protocols/google-decisions.ts#OptionsInput [status=implemented hash=f75e9b8ed22c]
        public typealias OptionsInput = [String: JSONValue]

        // parity: ai/src/protocols/google-decisions.ts#protocol [status=implemented hash=ba63abf33f5a]
        public static let `protocol` = DecisionProtocolSpec(
            id: "google-decisions",
            name: "Google Decisions",
            provider: "google",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                try SystemOneProtocol.encodeBody(req, fallbackMediaInput: "state")
            }
        )

        // parity: ai/src/protocols/google-decisions.ts#route [status=implemented hash=95918b34d6c4]
        public static let route = DecisionRouteSpec(
            id: "google-decisions",
            provider: "google",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            pathBuilder: { modelID in "/models/\(modelID):generateContent" }
        )
    }

    // MARK: - 11. GoogleEmbedContent (packages/ai/src/protocols/google-embed-content.ts — 9 symbols)

    public enum GoogleEmbedContent {
        // parity: ai/src/protocols/google-embed-content.ts#DEFAULT_BASE_URL [status=implemented hash=ae7b30027e03]
        public static let DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

        // parity: ai/src/protocols/google-embed-content.ts#MAX_BATCH [status=implemented hash=0232bf763a89]
        public static let MAX_BATCH = 100

        // parity: ai/src/protocols/google-embed-content.ts#TaskType [status=implemented hash=a7e96105dcf9]
        public typealias TaskType = String

        // parity: ai/src/protocols/google-embed-content.ts#OptionsInput [status=implemented hash=f0b4bb236a5c]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var taskType: TaskType?
            public var title: String?
            public init(taskType: TaskType? = nil, title: String? = nil) {
                self.taskType = taskType; self.title = title
            }
        }

        // parity: ai/src/protocols/google-embed-content.ts#VertexOptionsInput [status=implemented hash=3c1304b1122c]
        public struct VertexOptionsInput: Equatable, Hashable, Sendable {
            public var taskType: TaskType?
            public var title: String?
            public var autoTruncate: Bool?
            public var documentOcr: Bool?
            public var audioTrackExtraction: Bool?
            public init(
                taskType: TaskType? = nil, title: String? = nil,
                autoTruncate: Bool? = nil, documentOcr: Bool? = nil, audioTrackExtraction: Bool? = nil
            ) {
                self.taskType = taskType; self.title = title
                self.autoTruncate = autoTruncate; self.documentOcr = documentOcr
                self.audioTrackExtraction = audioTrackExtraction
            }
        }

        private static func encodeContent(_ value: EmbeddingInputValue) throws(AIProtocolUtils.ProtocolError) -> JSONValue {
            switch value {
            case .text(let s):
                return .object(["parts": .array([.object(["text": .string(s)])])])
            case .media(let asset):
                let part = try AIProtocolUtils.GeminiGenerateContent.mediaPart(route: "Google embedContent", asset: asset)
                return .object(["parts": .array([.object(part)])])
            }
        }

        private static func buildConfig(_ req: EmbeddingRequestPayload) -> [String: JSONValue] {
            var cfg = req.providerOptions ?? [:]
            if let inputType = req.inputType, cfg["taskType"] == nil {
                if inputType == "query" { cfg["taskType"] = .string("RETRIEVAL_QUERY") }
                else if inputType == "document" { cfg["taskType"] = .string("RETRIEVAL_DOCUMENT") }
            }
            if let dims = req.dimensions { cfg["outputDimensionality"] = .int(Int64(dims)) }
            return cfg
        }

        // parity: ai/src/protocols/google-embed-content.ts#protocol [status=implemented hash=4f83b9656707]
        public static let `protocol` = EmbeddingProtocolSpec(
            id: "google-embed-content",
            name: "Google embedContent",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var items: [JSONValue] = []
                let fields = buildConfig(req)
                for value in req.values {
                    var entry = fields
                    entry["model"] = .string("models/\(req.model.id)")
                    entry["content"] = try encodeContent(value)
                    items.append(.object(entry))
                }
                return AIProtocolUtils.JSONCodec.mergeObjects(["requests": .array(items)], req.httpBody)
            },
            decodeResponse: { text, metaKey throws(AIProtocolUtils.ProtocolError) in
                let parsed = try AIProtocolUtils.ProviderShared.parseJson(route: "google-embed-content", input: text, message: "Invalid Google embedContent response")
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                      let list = AIProtocolUtils.JSONCodec.arrayValue(obj["embeddings"]) else {
                    throw AIProtocolUtils.ProviderShared.eventError("google-embed-content", "Missing embeddings array", body: text)
                }
                let vectors: [[Double]] = list.map { entry in
                    let vals = AIProtocolUtils.JSONCodec.arrayValue(AIProtocolUtils.JSONCodec.objectValue(entry)?["values"]) ?? []
                    return vals.compactMap(AIProtocolUtils.JSONCodec.doubleValue)
                }
                let usageMeta = AIProtocolUtils.JSONCodec.objectValue(obj["usageMetadata"])
                let tokens = AIProtocolUtils.JSONCodec.doubleValue(usageMeta?["promptTokenCount"])
                return EmbeddingResponsePayload(
                    embeddings: vectors,
                    inputTokens: tokens,
                    providerMetadata: [metaKey: usageMeta.map { ["usageMetadata": .object($0)] } ?? [:]]
                )
            }
        )

        // parity: ai/src/protocols/google-embed-content.ts#vertexProtocol [status=implemented hash=ed4dcd4e220b]
        public static let vertexProtocol = EmbeddingProtocolSpec(
            id: "google-vertex-embed-content",
            name: "Google Vertex embedContent",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                guard let first = req.values.first else {
                    throw AIProtocolUtils.ProviderShared.invalidRequest("Google Vertex embedContent requires at least one value")
                }
                let fields = buildConfig(req)
                var base: [String: JSONValue] = ["content": try encodeContent(first)]
                if !fields.isEmpty { base["embedContentConfig"] = .object(fields) }
                return AIProtocolUtils.JSONCodec.mergeObjects(base, req.httpBody)
            },
            decodeResponse: { text, metaKey throws(AIProtocolUtils.ProtocolError) in
                let parsed = try AIProtocolUtils.ProviderShared.parseJson(route: "google-vertex-embed-content", input: text, message: "Invalid Vertex embedContent response")
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                      let embObj = AIProtocolUtils.JSONCodec.objectValue(obj["embedding"]),
                      let vals = AIProtocolUtils.JSONCodec.arrayValue(embObj["values"]) else {
                    throw AIProtocolUtils.ProviderShared.eventError("google-vertex-embed-content", "Missing embedding values", body: text)
                }
                let vector = vals.compactMap(AIProtocolUtils.JSONCodec.doubleValue)
                let usageMeta = AIProtocolUtils.JSONCodec.objectValue(obj["usageMetadata"])
                let tokens = AIProtocolUtils.JSONCodec.doubleValue(usageMeta?["promptTokenCount"])
                var meta: [String: JSONValue] = [:]
                if let usageMeta { meta["usageMetadata"] = .object(usageMeta) }
                if let trunc = obj["truncated"] { meta["truncated"] = trunc }
                return EmbeddingResponsePayload(embeddings: [vector], inputTokens: tokens, providerMetadata: [metaKey: meta])
            }
        )

        // parity: ai/src/protocols/google-embed-content.ts#route [status=implemented hash=71ffa8b422e0]
        public static let route = EmbeddingRouteSpec(
            id: "google-embed-content",
            provider: "google",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            pathBuilder: { modelID in "/models/\(modelID):batchEmbedContents" },
            maxValues: MAX_BATCH
        )

        // parity: ai/src/protocols/google-embed-content.ts#GoogleEmbedContent [status=implemented hash=082a20e0ba87]
        public static let GoogleEmbedContent = AIProtocols.GoogleEmbedContent.self
    }

    // MARK: - 12. GoogleImages (packages/ai/src/protocols/google-images.ts — 6 symbols)

    public enum GoogleImages {
        public static let routeIdentity = AIProtocolUtils.MediaIdentity(id: "google-images", name: "Google Images", provider: "google")

        // parity: ai/src/protocols/google-images.ts#DEFAULT_BASE_URL [status=implemented hash=ae7b30027e03]
        public static let DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

        // parity: ai/src/protocols/google-images.ts#GoogleImageOptions [status=implemented hash=c9d62852f77d]
        public typealias GoogleImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/google-images.ts#Request [status=implemented hash=513264af475e]
        public typealias Request = ImageRequestPayload

        public static func fromRequest(_ request: Request) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue] {
            if let n = request.n, n > 1 {
                throw routeIdentity.unsupported(
                    "media.n",
                    "\(routeIdentity.name) generates one image per request; call it once per image instead of n=\(n)"
                )
            }
            var parts: [JSONValue] = [.object(["text": .string(request.prompt)])]
            for asset in request.images ?? [] {
                let mediaPart = try AIProtocolUtils.GeminiGenerateContent.mediaPart(route: routeIdentity.name, asset: asset)
                parts.append(.object(mediaPart))
            }
            var native = request.providerOptions ?? [:]
            let thinkingLevel = native.removeValue(forKey: "thinkingLevel")
            let includeThoughts = native.removeValue(forKey: "includeThoughts")
            var genConfig: [String: JSONValue] = [
                "responseModalities": .array([.string("IMAGE")]),
            ]
            var imageConfig: [String: JSONValue] = [:]
            if let aspect = request.aspect { imageConfig["aspectRatio"] = .string(aspect) }
            if let resolution = request.resolution {
                let upper = resolution.uppercased()
                imageConfig["imageSize"] = .string(upper == "0.5K" ? "512" : upper)
            }
            if !imageConfig.isEmpty { genConfig["imageConfig"] = .object(imageConfig) }
            var thinkingConfig: [String: JSONValue] = [:]
            if let thinkingLevel { thinkingConfig["thinkingLevel"] = thinkingLevel }
            if let includeThoughts { thinkingConfig["includeThoughts"] = includeThoughts }
            if !thinkingConfig.isEmpty { genConfig["thinkingConfig"] = .object(thinkingConfig) }
            let mergedGenConfig = AIProtocolUtils.JSONCodec.mergeObjects(genConfig, native)
            return [
                "contents": .array([.object(["role": .string("user"), "parts": .array(parts)])]),
                "generationConfig": .object(mergedGenConfig),
            ]
        }

        public static func decodeResponse(_ text: String) throws(AIProtocolUtils.ProtocolError) -> DecodedImageResponse {
            let parsed = try AIProtocolUtils.ProviderShared.parseJson(
                route: routeIdentity.id,
                input: text,
                message: "\(routeIdentity.name) returned an invalid response"
            )
            guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed) else {
                throw routeIdentity.frameError("\(routeIdentity.name) returned an invalid response", body: text)
            }
            let candidates = (AIProtocolUtils.JSONCodec.arrayValue(obj["candidates"]) ?? []).compactMap(AIProtocolUtils.JSONCodec.objectValue)
            var images: [AIProtocolUtils.MediaAsset] = []
            var finishReasons: [String] = []

            for (candIdx, cand) in candidates.enumerated() {
                if let fr = AIProtocolUtils.JSONCodec.stringValue(cand["finishReason"]) {
                    finishReasons.append(fr)
                }
                let contentObj = AIProtocolUtils.JSONCodec.objectValue(cand["content"])
                let parts = (AIProtocolUtils.JSONCodec.arrayValue(contentObj?["parts"]) ?? []).compactMap(AIProtocolUtils.JSONCodec.objectValue)
                for (partIdx, part) in parts.enumerated() {
                    if AIProtocolUtils.JSONCodec.boolValue(part["thought"]) == true { continue }
                    guard let inlineData = AIProtocolUtils.JSONCodec.objectValue(part["inlineData"]),
                          let data = AIProtocolUtils.JSONCodec.stringValue(inlineData["data"]),
                          let mime = AIProtocolUtils.JSONCodec.stringValue(inlineData["mimeType"])
                    else { continue }
                    var meta: [String: JSONValue] = [
                        "candidateIndex": .int(Int64(AIProtocolUtils.JSONCodec.intValue(cand["index"]) ?? candIdx)),
                        "partIndex": .int(Int64(partIdx)),
                    ]
                    if let fr = cand["finishReason"] { meta["finishReason"] = fr }
                    if let sig = part["thoughtSignature"] { meta["thoughtSignature"] = sig }
                    let asset = try AIProtocolUtils.MediaInput.decodedAsset(
                        invalid: { msg in routeIdentity.frameError(msg, body: text) },
                        label: "\(routeIdentity.name) candidate \(candIdx) part \(partIdx)",
                        data: data,
                        mediaType: mime,
                        providerMetadata: ["google": meta]
                    )
                    images.append(asset)
                }
            }

            if images.isEmpty {
                if finishReasons.contains(where: AIProtocolUtils.GeminiGenerateContent.contentFiltered) {
                    throw AIProtocolUtils.ProtocolError(
                        kind: .contentPolicy,
                        message: "\(routeIdentity.name) withheld its images (finish reasons: \(finishReasons.joined(separator: ", ")))",
                        route: routeIdentity.id,
                        provider: routeIdentity.provider,
                        body: text
                    )
                }
                let suffix = finishReasons.isEmpty ? "" : " (finish reasons: \(finishReasons.joined(separator: ", ")))"
                throw routeIdentity.frameError("\(routeIdentity.name) returned no final images\(suffix)", body: text)
            }

            let usage: AIProtocolUtils.MediaUsage?
            if let u = AIProtocolUtils.JSONCodec.objectValue(obj["usageMetadata"]) {
                let promptTokens = AIProtocolUtils.JSONCodec.doubleValue(u["promptTokenCount"])
                let candidatesTokens = AIProtocolUtils.JSONCodec.doubleValue(u["candidatesTokenCount"])
                let thoughtsTokens = AIProtocolUtils.JSONCodec.doubleValue(u["thoughtsTokenCount"])
                let outputTokens = candidatesTokens.map { $0 + (thoughtsTokens ?? 0) }
                let totalTokens = AIProtocolUtils.ProviderShared.totalTokens(
                    promptTokens,
                    outputTokens,
                    AIProtocolUtils.JSONCodec.doubleValue(u["totalTokenCount"])
                )
                var details: [String: JSONValue] = ["google": .object(u)]
                if let thoughtsTokens { details["reasoningTokens"] = .double(thoughtsTokens) }
                if let cached = AIProtocolUtils.JSONCodec.doubleValue(u["cachedContentTokenCount"]) {
                    details["cacheReadInputTokens"] = .double(cached)
                }
                usage = .tokens(input: promptTokens, output: outputTokens, total: totalTokens, details: details)
            } else {
                usage = nil
            }

            var topMeta: [String: JSONValue] = [:]
            if let mv = obj["modelVersion"] { topMeta["modelVersion"] = mv }
            if let rid = obj["responseId"] { topMeta["responseId"] = rid }
            if let pf = obj["promptFeedback"] { topMeta["promptFeedback"] = pf }
            return DecodedImageResponse(
                images: images,
                usage: usage,
                providerMetadata: topMeta.isEmpty ? nil : ["google": topMeta]
            )
        }

        // parity: ai/src/protocols/google-images.ts#protocol [status=implemented hash=32b174ab3a05]
        public static let `protocol` = MediaProtocolSpec(
            identity: routeIdentity,
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            buildBody: { input throws(AIProtocolUtils.ProtocolError) in
                let req = Request(
                    modelID: AIProtocolUtils.JSONCodec.stringValue(input["model"]) ?? "gemini-2.5-flash-image",
                    prompt: AIProtocolUtils.JSONCodec.stringValue(input["prompt"]) ?? "",
                    n: AIProtocolUtils.JSONCodec.intValue(input["n"]),
                    aspect: AIProtocolUtils.JSONCodec.stringValue(input["aspect"]),
                    resolution: AIProtocolUtils.JSONCodec.stringValue(input["resolution"]),
                    providerOptions: AIProtocolUtils.JSONCodec.objectValue(input["providerOptions"])
                )
                return try fromRequest(req)
            },
            parseResponse: { text throws(AIProtocolUtils.ProtocolError) in
                let decoded = try decodeResponse(text)
                return .object([
                    "images": .array(decoded.images.map { img in
                        var obj: [String: JSONValue] = ["mediaType": .string(img.mediaType)]
                        if let inline = img.inline() { obj["b64_json"] = .string(inline.base64) }
                        return .object(obj)
                    }),
                ])
            }
        )

        // parity: ai/src/protocols/google-images.ts#model [status=implemented hash=443b38f1f584]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input, pathOverride: "/models/\(input.id):generateContent")
        }

        // parity: ai/src/protocols/google-images.ts#GoogleImages [status=implemented hash=1cffb2303779]
        public static let GoogleImages = AIProtocols.GoogleImages.self
    }

    // MARK: - 13. GoogleInteractionsVideo (packages/ai/src/protocols/google-interactions-video.ts — 8 symbols)

    public enum GoogleInteractionsVideo {
        // parity: ai/src/protocols/google-interactions-video.ts#DEFAULT_BASE_URL [status=implemented hash=31b1fd2b0c34]
        public static let DEFAULT_BASE_URL = GoogleInteractions.DEFAULT_BASE_URL

        // parity: ai/src/protocols/google-interactions-video.ts#PATH [status=implemented hash=d93a8211098f]
        public static let PATH = "/interactions"

        // parity: ai/src/protocols/google-interactions-video.ts#GoogleVideoOptions [status=implemented hash=c06d9cec5967]
        public typealias GoogleVideoOptions = [String: JSONValue]

        // parity: ai/src/protocols/google-interactions-video.ts#Request [status=implemented hash=1aae4c979925]
        public typealias Request = VideoRequestPayload

        // parity: ai/src/protocols/google-interactions-video.ts#Token [status=implemented hash=3db348ce72a1]
        public typealias Token = String

        // parity: ai/src/protocols/google-interactions-video.ts#protocol [status=implemented hash=87ae2e318d66]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "google-interactions-video", name: "Google Video", provider: "google"),
            mode: .queued,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/google-interactions-video.ts#model [status=implemented hash=bf1a33ad89ca]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/google-interactions-video.ts#GoogleInteractionsVideo [status=implemented hash=b30302f4fd50]
        public static let GoogleInteractionsVideo = AIProtocols.GoogleInteractionsVideo.self
    }

    // MARK: - 14. GoogleSpeech (packages/ai/src/protocols/google-speech.ts — 6 symbols)

    public enum GoogleSpeech {
        // parity: ai/src/protocols/google-speech.ts#DEFAULT_BASE_URL [status=implemented hash=ae7b30027e03]
        public static let DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

        // parity: ai/src/protocols/google-speech.ts#GoogleSpeechOptions [status=implemented hash=27c6de263ecb]
        public typealias GoogleSpeechOptions = [String: JSONValue]

        // parity: ai/src/protocols/google-speech.ts#Request [status=implemented hash=fecd1ffd582e]
        public typealias Request = SpeechRequestPayload

        // parity: ai/src/protocols/google-speech.ts#protocol [status=implemented hash=ecd7211a9c38]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "google-speech", name: "Google Speech", provider: "google"),
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL
        )

        // parity: ai/src/protocols/google-speech.ts#model [status=implemented hash=7be3fba6225b]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input, pathOverride: AIProtocolUtils.GeminiGenerateContent.path(model: input.id, streaming: true))
        }

        // parity: ai/src/protocols/google-speech.ts#GoogleSpeech [status=implemented hash=94cc181ab910]
        public static let GoogleSpeech = AIProtocols.GoogleSpeech.self
    }

    // MARK: - 15. GoogleTranscription (packages/ai/src/protocols/google-transcription.ts — 6 symbols)

    public enum GoogleTranscription {
        // parity: ai/src/protocols/google-transcription.ts#DEFAULT_BASE_URL [status=implemented hash=ae7b30027e03]
        public static let DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

        // parity: ai/src/protocols/google-transcription.ts#GoogleTranscriptionOptions [status=implemented hash=6bafcbc366e0]
        public typealias GoogleTranscriptionOptions = [String: JSONValue]

        // parity: ai/src/protocols/google-transcription.ts#Request [status=implemented hash=f70e255f0961]
        public typealias Request = TranscriptionRequestPayload

        // parity: ai/src/protocols/google-transcription.ts#protocol [status=implemented hash=6da0d4b58198]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "google-transcription", name: "Google Transcription", provider: "google"),
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL
        )

        // parity: ai/src/protocols/google-transcription.ts#model [status=implemented hash=72af5a1a043c]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input, pathOverride: AIProtocolUtils.GeminiGenerateContent.path(model: input.id, streaming: true))
        }

        // parity: ai/src/protocols/google-transcription.ts#GoogleTranscription [status=implemented hash=8bf01245d299]
        public static let GoogleTranscription = AIProtocols.GoogleTranscription.self
    }

    // MARK: - 16. GoogleVertexPredictEmbeddings (packages/ai/src/protocols/google-vertex-predict-embeddings.ts — 4 symbols)

    public enum GoogleVertexPredictEmbeddings {
        // parity: ai/src/protocols/google-vertex-predict-embeddings.ts#MAX_INSTANCES [status=implemented hash=67c6709cc88f]
        public static let MAX_INSTANCES = 250

        // parity: ai/src/protocols/google-vertex-predict-embeddings.ts#OptionsInput [status=implemented hash=b89786fa8ba4]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var taskType: String?
            public var title: String?
            public var autoTruncate: Bool?
            public init(taskType: String? = nil, title: String? = nil, autoTruncate: Bool? = nil) {
                self.taskType = taskType; self.title = title; self.autoTruncate = autoTruncate
            }
        }

        // parity: ai/src/protocols/google-vertex-predict-embeddings.ts#protocol [status=implemented hash=02776290d209]
        public static let `protocol` = EmbeddingProtocolSpec(
            id: "google-vertex-predict-embeddings",
            name: "Google Vertex Predict Embeddings",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var instances: [JSONValue] = []
                for v in req.values {
                    guard case .text(let s) = v else {
                        throw AIProtocolUtils.ProviderShared.unsupportedOperation(
                            operation: "embedding.media",
                            message: "Google Vertex predict embeddings accepts text values",
                            provider: req.model.provider,
                            route: req.model.routeID
                        )
                    }
                    var inst: [String: JSONValue] = ["content": .string(s)]
                    if let tt = req.providerOptions?["taskType"] { inst["task_type"] = tt }
                    if let title = req.providerOptions?["title"] { inst["title"] = title }
                    instances.append(.object(inst))
                }
                var params: [String: JSONValue] = [:]
                if let dims = req.dimensions { params["outputDimensionality"] = .int(Int64(dims)) }
                if let trunc = req.providerOptions?["autoTruncate"] { params["autoTruncate"] = trunc }
                var body: [String: JSONValue] = ["instances": .array(instances)]
                if !params.isEmpty { body["parameters"] = .object(params) }
                return AIProtocolUtils.JSONCodec.mergeObjects(body, req.httpBody)
            },
            decodeResponse: { text, metaKey throws(AIProtocolUtils.ProtocolError) in
                let parsed = try AIProtocolUtils.ProviderShared.parseJson(route: "google-vertex-predict-embeddings", input: text, message: "Invalid Vertex predict embeddings response")
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                      let preds = AIProtocolUtils.JSONCodec.arrayValue(obj["predictions"]) else {
                    throw AIProtocolUtils.ProviderShared.eventError("google-vertex-predict-embeddings", "Missing predictions array", body: text)
                }
                var vectors: [[Double]] = []
                var tokenSum = 0.0
                var hasTokens = false
                for pred in preds {
                    let embObj = AIProtocolUtils.JSONCodec.objectValue(AIProtocolUtils.JSONCodec.objectValue(pred)?["embeddings"])
                    let vals = (AIProtocolUtils.JSONCodec.arrayValue(embObj?["values"]) ?? []).compactMap(AIProtocolUtils.JSONCodec.doubleValue)
                    vectors.append(vals)
                    if let stats = AIProtocolUtils.JSONCodec.objectValue(embObj?["statistics"]),
                       let tc = AIProtocolUtils.JSONCodec.doubleValue(stats["token_count"]) {
                        tokenSum += tc
                        hasTokens = true
                    }
                }
                return EmbeddingResponsePayload(
                    embeddings: vectors,
                    inputTokens: hasTokens ? tokenSum : nil,
                    providerMetadata: [metaKey: [:]]
                )
            }
        )

        // parity: ai/src/protocols/google-vertex-predict-embeddings.ts#GoogleVertexPredictEmbeddings [status=implemented hash=a005dc1427be]
        public static let GoogleVertexPredictEmbeddings = AIProtocols.GoogleVertexPredictEmbeddings.self
    }

    // MARK: - 17. MetaImages (packages/ai/src/protocols/meta-images.ts — 5 symbols)

    public enum MetaImages {
        // parity: ai/src/protocols/meta-images.ts#DEFAULT_BASE_URL [status=implemented hash=80087103d2e6]
        public static let DEFAULT_BASE_URL = "https://api.meta.ai/v1"

        // parity: ai/src/protocols/meta-images.ts#ImageOptions [status=implemented hash=95d0dedfbc0b]
        public typealias ImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/meta-images.ts#Request [status=implemented hash=e92ff3a61f7d]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/meta-images.ts#protocol [status=implemented hash=32b174ab3a05]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "meta-images", name: "Meta Images", provider: "meta"),
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: "/responses"
        )

        // parity: ai/src/protocols/meta-images.ts#model [status=implemented hash=62d4fb63fcfe]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }
    }

    // MARK: - 18. MiniMaxImages (packages/ai/src/protocols/minimax-images.ts — 7 symbols)

    public enum MiniMaxImages {
        // parity: ai/src/protocols/minimax-images.ts#DEFAULT_BASE_URL [status=implemented hash=0af1a202e8a7]
        public static let DEFAULT_BASE_URL = "https://api.minimax.io/v1"

        // parity: ai/src/protocols/minimax-images.ts#PATH [status=implemented hash=8dbe77a7f9ba]
        public static let PATH = "/image_generation"

        // parity: ai/src/protocols/minimax-images.ts#MiniMaxImageOptions [status=implemented hash=b5c12b8bc29e]
        public typealias MiniMaxImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/minimax-images.ts#Request [status=implemented hash=7525daf2128e]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/minimax-images.ts#protocol [status=implemented hash=32b174ab3a05]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "minimax-images", name: "MiniMax Images", provider: "minimax"),
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/minimax-images.ts#model [status=implemented hash=10ce8464b141]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/minimax-images.ts#MiniMaxImages [status=implemented hash=0686fe140bd7]
        public static let MiniMaxImages = AIProtocols.MiniMaxImages.self
    }

    // MARK: - 19. MiniMaxVideo (packages/ai/src/protocols/minimax-video.ts — 15 symbols)

    public enum MiniMaxVideo {
        // parity: ai/src/protocols/minimax-video.ts#DEFAULT_BASE_URL [status=implemented hash=5ca08f8937f2]
        public static let DEFAULT_BASE_URL = "https://api.minimax.io"

        // parity: ai/src/protocols/minimax-video.ts#PATH [status=implemented hash=c92613212e27]
        public static let PATH = "/v2/video_generation"

        // parity: ai/src/protocols/minimax-video.ts#STATUS_PATH [status=implemented hash=13da0e842513]
        public static let STATUS_PATH = "/v2/query/video_generation"

        // parity: ai/src/protocols/minimax-video.ts#HAILUO_PATH [status=implemented hash=7ba7524a651f]
        public static let HAILUO_PATH = "/v1/video_generation"

        // parity: ai/src/protocols/minimax-video.ts#HAILUO_STATUS_PATH [status=implemented hash=d71fb3abfce4]
        public static let HAILUO_STATUS_PATH = "/v1/query/video_generation"

        // parity: ai/src/protocols/minimax-video.ts#FILE_PATH [status=implemented hash=23849ef9707d]
        public static let FILE_PATH = "/v1/files/retrieve"

        // parity: ai/src/protocols/minimax-video.ts#MiniMaxVideoOptions [status=implemented hash=ee417425c046]
        public typealias MiniMaxVideoOptions = [String: JSONValue]

        // parity: ai/src/protocols/minimax-video.ts#Request [status=implemented hash=92ffd4f20077]
        public typealias Request = VideoRequestPayload

        // parity: ai/src/protocols/minimax-video.ts#Token [status=implemented hash=3db348ce72a1]
        public typealias Token = String

        // parity: ai/src/protocols/minimax-video.ts#protocol [status=implemented hash=9ff264dd38c0]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "minimax-video", name: "MiniMax Video", provider: "minimax"),
            mode: .queued,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/minimax-video.ts#hailuoProtocol [status=implemented hash=bf1d7df625ae]
        public static let hailuoProtocol = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "minimax-hailuo-video", name: "MiniMax Hailuo Video", provider: "minimax"),
            mode: .queued,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: HAILUO_PATH
        )

        // parity: ai/src/protocols/minimax-video.ts#h3Model [status=implemented hash=6da6272e061b]
        public static func h3Model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/minimax-video.ts#hailuoModel [status=implemented hash=731f0bfd2390]
        public static func hailuoModel(_ input: MediaModelInput) -> MediaModelHandle {
            hailuoProtocol.makeModel(input)
        }

        internal static func isHailuo(_ id: String) -> Bool {
            let lower = id.lowercased()
            return lower.hasPrefix("minimax-hailuo-")
                || lower.hasPrefix("t2v-01")
                || lower.hasPrefix("i2v-01")
                || lower.hasPrefix("s2v-01")
                || lower.hasPrefix("video-01")
        }

        // parity: ai/src/protocols/minimax-video.ts#model [status=implemented hash=dc08017272f5]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            isHailuo(input.id) ? hailuoModel(input) : h3Model(input)
        }

        // parity: ai/src/protocols/minimax-video.ts#MiniMaxVideo [status=implemented hash=ed7ffed619ee]
        public static let MiniMaxVideo = AIProtocols.MiniMaxVideo.self
    }

    // MARK: - 20. OpenAIDecisions (packages/ai/src/protocols/openai-decisions.ts — 6 symbols)

    public enum OpenAIDecisions {
        // parity: ai/src/protocols/openai-decisions.ts#DEFAULT_BASE_URL [status=implemented hash=97f5685da742]
        public static let DEFAULT_BASE_URL = "https://api.openai.com/v1"

        // parity: ai/src/protocols/openai-decisions.ts#PATH [status=implemented hash=18206621d2e1]
        public static let PATH = "/decisions"

        // parity: ai/src/protocols/openai-decisions.ts#OptionsInput [status=implemented hash=f75e9b8ed22c]
        public typealias OptionsInput = [String: JSONValue]

        // parity: ai/src/protocols/openai-decisions.ts#protocol [status=implemented hash=31eae38a33a4]
        public static let `protocol` = DecisionProtocolSpec(
            id: "openai-decisions",
            name: "OpenAI Decisions",
            provider: "openai",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var body = try SystemOneProtocol.encodeBody(req, fallbackMediaInput: "state")
                body["model"] = .string(req.model.id)
                return body
            }
        )

        // parity: ai/src/protocols/openai-decisions.ts#route [status=implemented hash=f30b7b60d617]
        public static let route = DecisionRouteSpec(
            id: "openai-decisions",
            provider: "openai",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/openai-decisions.ts#OpenAIDecisions [status=implemented hash=1cc21bb2cddd]
        public static let OpenAIDecisions = AIProtocols.OpenAIDecisions.self
    }

    // MARK: - 21. OpenAIEmbeddings (packages/ai/src/protocols/openai-embeddings.ts — 6 symbols)

    public enum OpenAIEmbeddings {
        // parity: ai/src/protocols/openai-embeddings.ts#DEFAULT_BASE_URL [status=implemented hash=97f5685da742]
        public static let DEFAULT_BASE_URL = "https://api.openai.com/v1"

        // parity: ai/src/protocols/openai-embeddings.ts#PATH [status=implemented hash=ce30353f9610]
        public static let PATH = "/embeddings"

        // parity: ai/src/protocols/openai-embeddings.ts#OptionsInput [status=implemented hash=6183e4f0a516]
        public struct OptionsInput: Equatable, Hashable, Sendable {
            public var user: String?
            public var encodingFormat: String?
            public init(user: String? = nil, encodingFormat: String? = nil) {
                self.user = user; self.encodingFormat = encodingFormat
            }
        }

        private static func decodeBase64Float32LE(_ encoded: String) throws(AIProtocolUtils.ProtocolError) -> [Double] {
            let bytes: [UInt8]
            do {
                bytes = try base64ToBytes(encoded)
            } catch {
                throw AIProtocolUtils.ProviderShared.eventError("openai-embeddings", "OpenAI Embeddings returned an invalid base64 embedding")
            }
            guard bytes.count % 4 == 0 else {
                throw AIProtocolUtils.ProviderShared.eventError("openai-embeddings", "OpenAI Embeddings base64 byte length is not a multiple of 4")
            }
            var out: [Double] = []
            out.reserveCapacity(bytes.count / 4)
            var i = 0
            while i + 4 <= bytes.count {
                let bits = UInt32(bytes[i])
                    | (UInt32(bytes[i + 1]) << 8)
                    | (UInt32(bytes[i + 2]) << 16)
                    | (UInt32(bytes[i + 3]) << 24)
                out.append(Double(Float(bitPattern: bits)))
                i += 4
            }
            return out
        }

        // parity: ai/src/protocols/openai-embeddings.ts#protocol [status=implemented hash=94858471b7b4]
        public static let `protocol` = EmbeddingProtocolSpec(
            id: "openai-embeddings",
            name: "OpenAI Embeddings",
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in
                var strings: [JSONValue] = []
                for v in req.values {
                    guard case .text(let s) = v else {
                        throw AIProtocolUtils.ProviderShared.unsupportedOperation(
                            operation: "embedding.media",
                            message: "OpenAI Embeddings embeds text only; pass media values to a host with a multimodal embedding API",
                            provider: req.model.provider,
                            route: req.model.routeID
                        )
                    }
                    strings.append(.string(s))
                }
                var defaults: [String: JSONValue] = ["encoding_format": .string("float")]
                if let po = req.providerOptions {
                    for (k, v) in po { defaults[k] = v }
                }
                var merged = AIProtocolUtils.JSONCodec.mergeObjects(defaults, req.httpBody)
                merged["model"] = .string(req.model.id)
                merged["input"] = .array(strings)
                if let dims = req.dimensions { merged["dimensions"] = .int(Int64(dims)) }
                return merged
            },
            decodeResponse: { text, metaKey throws(AIProtocolUtils.ProtocolError) in
                let parsed = try AIProtocolUtils.ProviderShared.parseJson(route: "openai-embeddings", input: text, message: "Invalid OpenAI Embeddings response")
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                      let data = AIProtocolUtils.JSONCodec.arrayValue(obj["data"]) else {
                    throw AIProtocolUtils.ProviderShared.eventError("openai-embeddings", "Missing data array", body: text)
                }
                var indexed: [(Int, JSONValue)] = []
                for (pos, entry) in data.enumerated() {
                    guard let item = AIProtocolUtils.JSONCodec.objectValue(entry),
                          let emb = item["embedding"] else { continue }
                    let idx = AIProtocolUtils.JSONCodec.intValue(item["index"]) ?? pos
                    indexed.append((idx, emb))
                }
                indexed.sort { $0.0 < $1.0 }
                var vectors: [[Double]] = []
                for (_, emb) in indexed {
                    if case .string(let b64) = emb {
                        vectors.append(try decodeBase64Float32LE(b64))
                    } else if case .array(let nums) = emb {
                        vectors.append(nums.compactMap(AIProtocolUtils.JSONCodec.doubleValue))
                    }
                }
                let usageObj = AIProtocolUtils.JSONCodec.objectValue(obj["usage"])
                let promptTokens = AIProtocolUtils.JSONCodec.doubleValue(usageObj?["prompt_tokens"])
                var meta: [String: JSONValue] = [:]
                if let m = obj["model"] { meta["model"] = m }
                if let usageObj { meta["usage"] = .object(usageObj) }
                return EmbeddingResponsePayload(
                    embeddings: vectors,
                    inputTokens: promptTokens,
                    providerMetadata: [metaKey: meta]
                )
            }
        )

        // parity: ai/src/protocols/openai-embeddings.ts#route [status=implemented hash=1149b90cf75b]
        public static let route = EmbeddingRouteSpec(
            id: "openai-embeddings",
            provider: "openai",
            protocol: `protocol`,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/openai-embeddings.ts#OpenAIEmbeddings [status=implemented hash=a02bc183319e]
        public static let OpenAIEmbeddings = AIProtocols.OpenAIEmbeddings.self
    }

    // MARK: - 22. OpenAIImages (packages/ai/src/protocols/openai-images.ts — 10 symbols)

    public enum OpenAIImages {
        public static let routeIdentity = AIProtocolUtils.MediaIdentity(id: "openai-images", name: "OpenAI Images", provider: "openai")

        // parity: ai/src/protocols/openai-images.ts#DEFAULT_BASE_URL [status=implemented hash=97f5685da742]
        public static let DEFAULT_BASE_URL = "https://api.openai.com/v1"

        // parity: ai/src/protocols/openai-images.ts#PATH [status=implemented hash=bb919f32959f]
        public static let PATH = "/images/generations"

        // parity: ai/src/protocols/openai-images.ts#EDIT_PATH [status=implemented hash=4f5d44e3ad14]
        public static let EDIT_PATH = "/images/edits"

        // parity: ai/src/protocols/openai-images.ts#OpenAIImageOptions [status=implemented hash=3b2ee0b4bb89]
        public typealias OpenAIImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/openai-images.ts#Request [status=implemented hash=3cd9daa23813]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/openai-images.ts#OpenAIImageSizing [status=implemented hash=daaf1ed6450e]
        public typealias OpenAIImageSizing = @Sendable (Request) -> [String: JSONValue]?

        // parity: ai/src/protocols/openai-images.ts#OpenAIImageInput [status=implemented hash=33738af924f8]
        public enum OpenAIImageInput: String, Equatable, Hashable, Sendable, Codable {
            case edits
            case jsonEdits = "json-edits"
            case references
        }

        public static func pixelSize(_ request: Request) -> [String: JSONValue]? {
            let shape = AIProtocolUtils.ImageSizing.Shape(aspect: request.aspect, resolution: request.resolution)
            guard AIProtocolUtils.ImageSizing.isRequested(shape) else { return nil }
            let id = request.modelID.split(separator: "/").last.map(String.init) ?? request.modelID
            let size: AIProtocolUtils.ImageSizing.Size
            if id.hasPrefix("dall-e-2") {
                size = AIProtocolUtils.ImageSizing.nearest(shape, sizes: [256, 512, 1024].map { .init(width: $0, height: $0) })
            } else if id.hasPrefix("dall-e-3") {
                size = AIProtocolUtils.ImageSizing.nearest(shape, sizes: [.init(width: 1024, height: 1024), .init(width: 1792, height: 1024), .init(width: 1024, height: 1792)])
            } else if id.hasPrefix("gpt-image-1") || id.hasPrefix("chatgpt-image") {
                size = AIProtocolUtils.ImageSizing.nearest(shape, sizes: [.init(width: 1024, height: 1024), .init(width: 1536, height: 1024), .init(width: 1024, height: 1536)])
            } else if id.hasPrefix("gpt-image-") {
                size = AIProtocolUtils.ImageSizing.fit(shape, limits: .init(multiple: 16, maxEdge: 3840, minPixels: 655_360, maxPixels: 8_294_400, maxRatio: 3))
            } else {
                size = AIProtocolUtils.ImageSizing.fit(shape, limits: .init(multiple: 16))
            }
            return ["size": .string("\(size.width)x\(size.height)")]
        }

        public static func fromRequest(
            _ request: Request,
            imageInput: OpenAIImageInput = .edits,
            streaming: Bool = false,
            provider: String = "openai"
        ) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue] {
            let images = request.images ?? []
            let opts = request.providerOptions ?? [:]
            let hasMask = opts["mask"] != nil && opts["mask"] != .null
            if imageInput == .references && hasMask {
                throw routeIdentity.unsupported("media.mask", "\(provider) image edits take no mask")
            }
            if hasMask && images.isEmpty {
                throw AIProtocolUtils.ProviderShared.invalidRequest("An OpenAI image mask requires at least one input image")
            }
            let shape = AIProtocolUtils.ImageSizing.Shape(aspect: request.aspect, resolution: request.resolution)
            if opts["size"] != nil && AIProtocolUtils.ImageSizing.isRequested(shape) {
                throw AIProtocolUtils.ProviderShared.invalidRequest("OpenAI providerOptions.size replaces aspect and resolution; set one or the other")
            }
            if streaming, let n = request.n, n > 1 {
                throw routeIdentity.unsupported("media.n", "\(routeIdentity.name) streams one image; use Image.generate for n=\(n)")
            }

            var fields: [String: JSONValue] = [:]
            if let n = request.n { fields["n"] = .int(Int64(n)) }
            if let sized = pixelSize(request) {
                for (k, v) in sized { fields[k] = v }
            }
            if streaming {
                fields["stream"] = .bool(true)
                let partials = AIProtocolUtils.JSONCodec.intValue(opts["partialImages"]) ?? 2
                fields["partial_images"] = .int(Int64(partials))
            }

            var native: [String: JSONValue] = [:]
            for (k, v) in opts {
                switch k {
                case "outputCompression": native["output_compression"] = v
                case "outputFormat": native["output_format"] = v
                case "partialImages", "mask": break
                case "response_format":
                    if v != .null { native[k] = v }
                default:
                    native[k] = v
                }
            }
            let mergedFields = AIProtocolUtils.JSONCodec.mergeObjects(fields, native)

            var body: [String: JSONValue] = [
                "model": .string(request.modelID),
                "prompt": .string(request.prompt),
            ]
            if imageInput == .references {
                if !images.isEmpty {
                    var refs: [JSONValue] = []
                    for img in images {
                        let ref = try AIProtocolUtils.ProviderShared.mediaReference(asset: img, provider: nil, label: routeIdentity.name)
                        refs.append(.object([
                            "type": .string("image_url"),
                            "image_url": .object(["url": .string(ref.value)]),
                        ]))
                    }
                    body["input_references"] = .array(refs)
                }
            } else if !images.isEmpty {
                var refs: [JSONValue] = []
                for img in images {
                    let ref = try AIProtocolUtils.ProviderShared.mediaReference(asset: img, provider: provider, label: routeIdentity.name)
                    if ref.type == .ref {
                        refs.append(.object(["file_id": .string(ref.value)]))
                    } else {
                        refs.append(.object(["image_url": .string(ref.value)]))
                    }
                }
                body["images"] = .array(refs)
            }
            return AIProtocolUtils.JSONCodec.mergeObjects(body, mergedFields)
        }

        private static func parseImageInfo(format: String?, size: String?) -> [String: JSONValue]? {
            var info: [String: JSONValue] = [:]
            if let format { info["format"] = .string(format) }
            if let size {
                let parts = size.split(separator: "x")
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                    info["width"] = .int(Int64(w))
                    info["height"] = .int(Int64(h))
                }
            }
            return info.isEmpty ? nil : info
        }

        public static func decodeResponse(
            _ text: String,
            provider: String = "openai"
        ) throws(AIProtocolUtils.ProtocolError) -> DecodedImageResponse {
            let parsed = try AIProtocolUtils.ProviderShared.parseJson(
                route: routeIdentity.id,
                input: text,
                message: "\(routeIdentity.name) returned an invalid response"
            )
            guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                  let dataArr = AIProtocolUtils.JSONCodec.arrayValue(obj["data"]) else {
                throw routeIdentity.frameError("\(routeIdentity.name) returned an invalid response", body: text)
            }
            let format = AIProtocolUtils.JSONCodec.stringValue(obj["output_format"])
            let size = AIProtocolUtils.JSONCodec.stringValue(obj["size"])
            let mediaType = format.map { "image/\($0)" }
            let imgInfo = parseImageInfo(format: format, size: size)

            var images: [AIProtocolUtils.MediaAsset] = []
            for (idx, elem) in dataArr.enumerated() {
                guard let item = AIProtocolUtils.JSONCodec.objectValue(elem) else {
                    throw routeIdentity.frameError("\(routeIdentity.name) result \(idx) is not an object", body: text)
                }
                let asset = try AIProtocolUtils.MediaInput.imageOutput(
                    invalid: { msg in routeIdentity.frameError(msg, body: text) },
                    label: "\(routeIdentity.name) result \(idx)",
                    b64Json: AIProtocolUtils.JSONCodec.stringValue(item["b64_json"]),
                    url: AIProtocolUtils.JSONCodec.stringValue(item["url"]),
                    mediaType: mediaType
                )
                images.append(AIProtocolUtils.MediaAsset(
                    source: asset.source,
                    mediaType: asset.mediaType,
                    info: imgInfo,
                    providerMetadata: asset.providerMetadata
                ))
            }
            if images.isEmpty {
                throw routeIdentity.frameError("\(routeIdentity.name) returned no images", body: text)
            }

            let usage: AIProtocolUtils.MediaUsage?
            if let u = AIProtocolUtils.JSONCodec.objectValue(obj["usage"]) {
                usage = .tokens(
                    input: AIProtocolUtils.JSONCodec.doubleValue(u["input_tokens"]),
                    output: AIProtocolUtils.JSONCodec.doubleValue(u["output_tokens"]),
                    total: AIProtocolUtils.JSONCodec.doubleValue(u["total_tokens"]),
                    details: [provider: .object(u)]
                )
            } else {
                usage = nil
            }

            var meta: [String: JSONValue] = [:]
            if let format { meta["outputFormat"] = .string(format) }
            if let size { meta["size"] = .string(size) }
            if let q = obj["quality"] { meta["quality"] = q }
            if let bg = obj["background"] { meta["background"] = bg }
            return DecodedImageResponse(
                images: images,
                usage: usage,
                providerMetadata: meta.isEmpty ? nil : [provider: meta]
            )
        }

        // parity: ai/src/protocols/openai-images.ts#protocol [status=implemented hash=da6e8c6b762d]
        public static let `protocol` = MediaProtocolSpec(
            identity: routeIdentity,
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH,
            buildBody: { input throws(AIProtocolUtils.ProtocolError) in
                let req = Request(
                    modelID: AIProtocolUtils.JSONCodec.stringValue(input["model"]) ?? "gpt-image-1",
                    prompt: AIProtocolUtils.JSONCodec.stringValue(input["prompt"]) ?? "",
                    n: AIProtocolUtils.JSONCodec.intValue(input["n"]),
                    aspect: AIProtocolUtils.JSONCodec.stringValue(input["aspect"]),
                    resolution: AIProtocolUtils.JSONCodec.stringValue(input["resolution"]),
                    providerOptions: AIProtocolUtils.JSONCodec.objectValue(input["providerOptions"])
                )
                let streaming = AIProtocolUtils.JSONCodec.boolValue(input["stream"]) ?? false
                return try fromRequest(req, streaming: streaming)
            },
            parseResponse: { text throws(AIProtocolUtils.ProtocolError) in
                let decoded = try decodeResponse(text)
                return .object([
                    "images": .array(decoded.images.map { img in
                        var obj: [String: JSONValue] = ["mediaType": .string(img.mediaType)]
                        if let inline = img.inline() { obj["b64_json"] = .string(inline.base64) }
                        if case .url(let u) = img.source { obj["url"] = .string(u) }
                        return .object(obj)
                    }),
                ])
            }
        )

        // parity: ai/src/protocols/openai-images.ts#model [status=implemented hash=22a5ce3eac63]
        public static func model(_ input: MediaModelInput, imageInput: OpenAIImageInput = .edits) -> MediaModelHandle {
            _ = imageInput
            return `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/openai-images.ts#OpenAIImages [status=implemented hash=98128782094b]
        public static let OpenAIImages = AIProtocols.OpenAIImages.self
    }

    // MARK: - 23. OpenAISpeech (packages/ai/src/protocols/openai-speech.ts — 7 symbols)

    public enum OpenAISpeech {
        public static let routeIdentity = AIProtocolUtils.MediaIdentity(id: "openai-speech", name: "OpenAI Speech", provider: "openai")
        public static let pcmSampleRate = 24_000
        private static let supportedFormats: Set<String> = ["mp3", "opus", "aac", "flac", "wav", "pcm"]

        // parity: ai/src/protocols/openai-speech.ts#DEFAULT_BASE_URL [status=implemented hash=97f5685da742]
        public static let DEFAULT_BASE_URL = "https://api.openai.com/v1"

        // parity: ai/src/protocols/openai-speech.ts#PATH [status=implemented hash=f3777d5f6bc0]
        public static let PATH = "/audio/speech"

        // parity: ai/src/protocols/openai-speech.ts#OpenAISpeechOptions [status=implemented hash=932f3dd2be4f]
        public typealias OpenAISpeechOptions = [String: JSONValue]

        // parity: ai/src/protocols/openai-speech.ts#Request [status=implemented hash=da62c94cf290]
        public typealias Request = SpeechRequestPayload

        public static func supportsSSE(_ modelID: String) -> Bool {
            let lower = modelID.lowercased()
            if lower == "tts-1" || lower.hasPrefix("tts-1-") || lower == "tts-1-hd" || lower.hasPrefix("tts-1-hd-") {
                return false
            }
            return true
        }

        public static func fromRequest(_ request: Request) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue] {
            if request.language != nil {
                throw routeIdentity.unsupported("media.language", "\(routeIdentity.name) does not support language selection")
            }
            if request.timestamps == true {
                throw routeIdentity.unsupported("media.timestamps", "\(routeIdentity.name) does not return timestamps")
            }
            if let format = request.format, !supportedFormats.contains(format) {
                throw routeIdentity.unsupported(
                    "media.format",
                    "\(routeIdentity.name) supports the mp3, opus, aac, flac, wav, and pcm formats, not \"\(format)\""
                )
            }
            var body: [String: JSONValue] = [
                "model": .string(request.modelID),
                "input": .string(request.text),
            ]
            if let voice = request.voice { body["voice"] = .string(voice) }
            if let instructions = request.instructions { body["instructions"] = .string(instructions) }
            if let format = request.format { body["response_format"] = .string(format) }
            if let speed = request.speed { body["speed"] = .double(speed) }
            if request.streaming && supportsSSE(request.modelID) {
                body["stream_format"] = .string("sse")
            }
            return AIProtocolUtils.JSONCodec.mergeObjects(body, request.providerOptions)
        }

        public static func decodeSSEStream(
            _ bytes: [UInt8],
            format: String = "mp3"
        ) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.SpeechEvent] {
            var sse = AIProtocolUtils.SSEParser()
            let frames = sse.feed(bytes) + sse.finish()
            var audio = AIProtocolUtils.SpeechStream.Audio()
            var events: [AIProtocolUtils.SpeechEvent] = []
            var done = false
            var usage: AIProtocolUtils.MediaUsage? = nil

            for frame in frames {
                let trimmed = frame.data.trimmingASCIIWhitespace()
                if trimmed.isEmpty || trimmed == "[DONE]" { continue }
                let parsed = try AIProtocolUtils.ProviderShared.parseJson(
                    route: routeIdentity.id,
                    input: trimmed,
                    message: "Invalid OpenAI Speech SSE JSON"
                )
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                      let evType = AIProtocolUtils.JSONCodec.stringValue(obj["type"]) else { continue }
                if evType == "speech.audio.delta" {
                    guard let b64 = AIProtocolUtils.JSONCodec.stringValue(obj["audio"]) else {
                        throw routeIdentity.frameError("OpenAI Speech delta missing audio field", body: trimmed)
                    }
                    let chunk: [UInt8]
                    do {
                        chunk = try base64ToBytes(b64)
                    } catch {
                        throw routeIdentity.frameError("OpenAI Speech delta contains invalid base64", body: trimmed)
                    }
                    events.append(contentsOf: AIProtocolUtils.SpeechStream.delta(&audio, chunk: chunk))
                } else if evType == "speech.audio.done" {
                    done = true
                    if let u = AIProtocolUtils.JSONCodec.objectValue(obj["usage"]) {
                        usage = .tokens(
                            input: AIProtocolUtils.JSONCodec.doubleValue(u["input_tokens"]),
                            output: AIProtocolUtils.JSONCodec.doubleValue(u["output_tokens"]),
                            total: AIProtocolUtils.JSONCodec.doubleValue(u["total_tokens"]),
                            details: ["openai": .object(u)]
                        )
                    }
                }
            }
            guard done else {
                throw routeIdentity.incomplete()
            }
            let fmtMeta = format == "pcm"
                ? AIProtocolUtils.SpeechStream.pcm(encoding: .pcm_s16le, sampleRate: pcmSampleRate)
                : AIProtocolUtils.SpeechStream.container(format: format)
            let finished = try AIProtocolUtils.SpeechStream.finish(
                route: routeIdentity,
                state: audio,
                mediaType: fmtMeta.mediaType,
                info: fmtMeta.info,
                usage: usage
            )
            events.append(contentsOf: finished)
            return events
        }

        // parity: ai/src/protocols/openai-speech.ts#protocol [status=implemented hash=9c37a4e6e9cf]
        public static let `protocol` = MediaProtocolSpec(
            identity: routeIdentity,
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH,
            buildBody: { input throws(AIProtocolUtils.ProtocolError) in
                let req = Request(
                    modelID: AIProtocolUtils.JSONCodec.stringValue(input["model"]) ?? "gpt-4o-mini-tts",
                    text: AIProtocolUtils.JSONCodec.stringValue(input["input"])
                        ?? AIProtocolUtils.JSONCodec.stringValue(input["text"])
                        ?? "",
                    voice: AIProtocolUtils.JSONCodec.stringValue(input["voice"]),
                    instructions: AIProtocolUtils.JSONCodec.stringValue(input["instructions"]),
                    format: AIProtocolUtils.JSONCodec.stringValue(input["response_format"])
                        ?? AIProtocolUtils.JSONCodec.stringValue(input["format"]),
                    speed: AIProtocolUtils.JSONCodec.doubleValue(input["speed"]),
                    language: AIProtocolUtils.JSONCodec.stringValue(input["language"]),
                    timestamps: AIProtocolUtils.JSONCodec.boolValue(input["timestamps"]),
                    streaming: AIProtocolUtils.JSONCodec.boolValue(input["streaming"]) ?? false,
                    providerOptions: AIProtocolUtils.JSONCodec.objectValue(input["providerOptions"])
                )
                return try fromRequest(req)
            },
            parseResponse: { text throws(AIProtocolUtils.ProtocolError) in
                let events = try decodeSSEStream(Array(text.utf8))
                var byteCount = 0
                for ev in events {
                    if case .audioDelta(let b) = ev { byteCount += b.count }
                }
                return .object(["audioBytes": .int(Int64(byteCount))])
            }
        )

        // parity: ai/src/protocols/openai-speech.ts#model [status=implemented hash=fd6fa57e138d]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/openai-speech.ts#OpenAISpeech [status=implemented hash=dd07439a46b1]
        public static let OpenAISpeech = AIProtocols.OpenAISpeech.self
    }

    // MARK: - 24. OpenAITranscription (packages/ai/src/protocols/openai-transcription.ts — 7 symbols)

    public enum OpenAITranscription {
        public static let routeIdentity = AIProtocolUtils.MediaIdentity(id: "openai-transcription", name: "OpenAI Transcription", provider: "openai")

        // parity: ai/src/protocols/openai-transcription.ts#DEFAULT_BASE_URL [status=implemented hash=97f5685da742]
        public static let DEFAULT_BASE_URL = "https://api.openai.com/v1"

        // parity: ai/src/protocols/openai-transcription.ts#PATH [status=implemented hash=c49cf2ccf6b6]
        public static let PATH = "/audio/transcriptions"

        // parity: ai/src/protocols/openai-transcription.ts#OpenAITranscriptionOptions [status=implemented hash=17e813958b22]
        public typealias OpenAITranscriptionOptions = [String: JSONValue]

        // parity: ai/src/protocols/openai-transcription.ts#Request [status=implemented hash=b35dbdd7ad13]
        public typealias Request = TranscriptionRequestPayload

        private struct ModelCaps {
            let stream: Bool
            let timestamps: [String]
            let diarize: Bool
            let usesLanguagesArray: Bool
        }

        private static func capabilities(for modelID: String) -> ModelCaps {
            if modelID.hasPrefix("whisper") {
                return ModelCaps(stream: false, timestamps: ["segment", "word"], diarize: false, usesLanguagesArray: false)
            }
            if modelID.contains("diarize") {
                return ModelCaps(stream: true, timestamps: ["segment"], diarize: true, usesLanguagesArray: false)
            }
            if modelID.hasPrefix("gpt-transcribe") {
                return ModelCaps(stream: true, timestamps: [], diarize: false, usesLanguagesArray: true)
            }
            return ModelCaps(stream: true, timestamps: [], diarize: false, usesLanguagesArray: false)
        }

        private static let reservedFormFields: Set<String> = [
            "file", "model", "prompt", "language", "response_format", "timestamp_granularities", "stream",
        ]

        public static func fromRequest(_ request: Request) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue] {
            let caps = capabilities(for: request.modelID)
            if request.diarize == true && !caps.diarize {
                throw routeIdentity.unsupported("media.diarize", "\(request.modelID) does not diarize; use gpt-4o-transcribe-diarize")
            }
            if request.prompt != nil && caps.diarize {
                throw routeIdentity.unsupported("media.prompt", "\(request.modelID) does not accept a prompt")
            }
            if let ts = request.timestamps, ts != "none", !caps.timestamps.contains(ts) {
                throw routeIdentity.unsupported("media.timestamps", "\(request.modelID) does not return \(ts) timestamps")
            }
            guard let ext = AIProtocolUtils.mediaTypeExtension(request.audio.mediaType) else {
                throw AIProtocolUtils.ProviderShared.invalidRequest(
                    "\(routeIdentity.name) cannot name a \(request.audio.mediaType) upload; send mp3, mp4, m4a, wav, webm, ogg, or flac audio"
                )
            }
            let responseFormat: String? = caps.diarize
                ? "diarized_json"
                : ((request.timestamps == nil || request.timestamps == "none") ? nil : "verbose_json")
            var fields: [String: JSONValue] = [
                "model": .string(request.modelID),
                "filename": .string("audio.\(ext)"),
            ]
            if let lang = request.language {
                if caps.usesLanguagesArray {
                    fields["languages"] = .array([.string(lang)])
                } else {
                    fields["language"] = .string(lang)
                }
            }
            if let prompt = request.prompt { fields["prompt"] = .string(prompt) }
            if let responseFormat { fields["response_format"] = .string(responseFormat) }
            if responseFormat == "verbose_json", let ts = request.timestamps {
                fields["timestamp_granularities"] = .array([.string(ts)])
            }
            if caps.diarize { fields["chunking_strategy"] = .string("auto") }
            if request.streaming && caps.stream { fields["stream"] = .bool(true) }
            let filteredOverlay = request.providerOptions?.filter { !reservedFormFields.contains($0.key) }
            return AIProtocolUtils.JSONCodec.mergeObjects(fields, filteredOverlay)
        }

        public static func buildMultipart(_ request: Request) throws(AIProtocolUtils.ProtocolError) -> AIRoute.MultipartFormData {
            var fields = try fromRequest(request)
            let filename = AIProtocolUtils.JSONCodec.stringValue(fields.removeValue(forKey: "filename")) ?? "audio.mp3"
            let rawBytes = try AIProtocolUtils.MediaInput.inlineBytes(route: routeIdentity.id, asset: request.audio)
            var form = AIRoute.MultipartFormData()
            form.append("file", data: rawBytes, filename: filename, contentType: request.audio.mediaType)
            let multipartFields = AIProtocolUtils.MediaInput.appendFields(
                fields: fields,
                overlay: nil,
                reserved: reservedFormFields,
                repeatArrays: "key[]"
            )
            for item in multipartFields {
                form.append(item.name, value: item.value)
            }
            return form
        }

        private static func parseUsage(_ value: JSONValue?) -> AIProtocolUtils.MediaUsage? {
            guard let u = AIProtocolUtils.JSONCodec.objectValue(value) else { return nil }
            let kind = AIProtocolUtils.JSONCodec.stringValue(u["type"])
            if kind == "duration", let secs = AIProtocolUtils.JSONCodec.doubleValue(u["seconds"]) {
                return .seconds(secs)
            }
            let input = AIProtocolUtils.JSONCodec.doubleValue(u["input_tokens"])
            let output = AIProtocolUtils.JSONCodec.doubleValue(u["output_tokens"])
            let total = AIProtocolUtils.JSONCodec.doubleValue(u["total_tokens"])
            if input == nil && output == nil && total == nil { return nil }
            return .tokens(input: input, output: output, total: total, details: ["openai": .object(u)])
        }

        private static func parseSegment(_ value: JSONValue) -> AIProtocolUtils.TranscriptionSegment? {
            guard let obj = AIProtocolUtils.JSONCodec.objectValue(value),
                  let text = AIProtocolUtils.JSONCodec.stringValue(obj["text"]),
                  let start = AIProtocolUtils.JSONCodec.doubleValue(obj["start"]),
                  let end = AIProtocolUtils.JSONCodec.doubleValue(obj["end"])
            else { return nil }
            return AIProtocolUtils.TranscriptionSegment(
                text: text.trimmingASCIIWhitespace(),
                start: start,
                end: end,
                speaker: AIProtocolUtils.JSONCodec.stringValue(obj["speaker"])
            )
        }

        public static func decodeResponse(_ text: String) throws(AIProtocolUtils.ProtocolError) -> DecodedTranscriptionResponse {
            let parsed = try AIProtocolUtils.ProviderShared.parseJson(
                route: routeIdentity.id,
                input: text,
                message: "Invalid OpenAI Transcription JSON response"
            )
            guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                  let transcriptText = AIProtocolUtils.JSONCodec.stringValue(obj["text"]) else {
                throw routeIdentity.frameError("OpenAI Transcription response missing text", body: text)
            }
            let segments = (AIProtocolUtils.JSONCodec.arrayValue(obj["segments"]) ?? []).compactMap(parseSegment)
            let words: [TranscriptionWord] = (AIProtocolUtils.JSONCodec.arrayValue(obj["words"]) ?? []).compactMap { raw in
                guard let w = AIProtocolUtils.JSONCodec.objectValue(raw),
                      let wordStr = AIProtocolUtils.JSONCodec.stringValue(w["word"]),
                      let start = AIProtocolUtils.JSONCodec.doubleValue(w["start"]),
                      let end = AIProtocolUtils.JSONCodec.doubleValue(w["end"])
                else { return nil }
                return TranscriptionWord(text: wordStr, startSeconds: start, endSeconds: end)
            }
            let firstLangFromArray: String? = AIProtocolUtils.JSONCodec.arrayValue(obj["languages"])?
                .first
                .flatMap(AIProtocolUtils.JSONCodec.objectValue)
                .flatMap { AIProtocolUtils.JSONCodec.stringValue($0["code"]) }
            let language = (AIProtocolUtils.JSONCodec.stringValue(obj["language"]) ?? firstLangFromArray)?.lowercased()
            return DecodedTranscriptionResponse(
                text: transcriptText,
                language: language,
                durationSeconds: AIProtocolUtils.JSONCodec.doubleValue(obj["duration"]),
                segments: segments,
                words: words,
                usage: parseUsage(obj["usage"])
            )
        }

        public static func decodeSSEStream(_ bytes: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> [AIProtocolUtils.TranscriptionEvent] {
            var sse = AIProtocolUtils.SSEParser()
            let frames = sse.feed(bytes) + sse.finish()
            var events: [AIProtocolUtils.TranscriptionEvent] = []
            var streamedSegments: [AIProtocolUtils.TranscriptionSegment] = []
            var finalDecoded: DecodedTranscriptionResponse? = nil

            for frame in frames {
                let trimmed = frame.data.trimmingASCIIWhitespace()
                if trimmed.isEmpty || trimmed == "[DONE]" { continue }
                let parsed = try AIProtocolUtils.ProviderShared.parseJson(
                    route: routeIdentity.id,
                    input: trimmed,
                    message: "Invalid OpenAI Transcription SSE JSON"
                )
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                      let evType = AIProtocolUtils.JSONCodec.stringValue(obj["type"]) else { continue }
                switch evType {
                case "error":
                    let errObj = AIProtocolUtils.JSONCodec.objectValue(obj["error"])
                    let msg = AIProtocolUtils.JSONCodec.stringValue(obj["message"])
                        ?? AIProtocolUtils.JSONCodec.stringValue(errObj?["message"])
                        ?? "unknown error"
                    throw AIProtocolUtils.ProtocolError(
                        kind: .providerInternal,
                        message: "\(routeIdentity.name) stream failed: \(msg)",
                        route: routeIdentity.id,
                        provider: routeIdentity.provider,
                        body: trimmed
                    )
                case "transcript.text.delta":
                    if let delta = AIProtocolUtils.JSONCodec.stringValue(obj["delta"]), !delta.isEmpty {
                        events.append(.textDelta(delta))
                    }
                case "transcript.text.segment":
                    if let seg = parseSegment(.object(obj)) {
                        streamedSegments.append(seg)
                        events.append(.segment(seg))
                    }
                case "transcript.text.done":
                    finalDecoded = try decodeResponse(trimmed)
                default:
                    break
                }
            }

            guard let finalDecoded else {
                throw routeIdentity.incomplete()
            }
            let effectiveSegments = finalDecoded.segments.isEmpty ? streamedSegments : finalDecoded.segments
            events.append(.finish(
                text: finalDecoded.text,
                language: finalDecoded.language,
                durationSeconds: finalDecoded.durationSeconds,
                segments: effectiveSegments,
                usage: finalDecoded.usage,
                providerMetadata: finalDecoded.providerMetadata
            ))
            return events
        }

        // parity: ai/src/protocols/openai-transcription.ts#protocol [status=implemented hash=03e9142e6c73]
        public static let `protocol` = MediaProtocolSpec(
            identity: routeIdentity,
            mode: .stream,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH,
            buildBody: { input throws(AIProtocolUtils.ProtocolError) in
                let mediaType = AIProtocolUtils.JSONCodec.stringValue(input["mediaType"]) ?? "audio/mpeg"
                let audio: AIProtocolUtils.MediaAsset
                if let b64 = AIProtocolUtils.JSONCodec.stringValue(input["audio_base64"]) {
                    audio = .base64(b64, mediaType: mediaType)
                } else {
                    audio = .bytes([], mediaType: mediaType)
                }
                let req = Request(
                    modelID: AIProtocolUtils.JSONCodec.stringValue(input["model"]) ?? "gpt-4o-transcribe",
                    audio: audio,
                    language: AIProtocolUtils.JSONCodec.stringValue(input["language"]),
                    prompt: AIProtocolUtils.JSONCodec.stringValue(input["prompt"]),
                    diarize: AIProtocolUtils.JSONCodec.boolValue(input["diarize"]),
                    timestamps: AIProtocolUtils.JSONCodec.stringValue(input["timestamps"]),
                    streaming: AIProtocolUtils.JSONCodec.boolValue(input["stream"])
                        ?? AIProtocolUtils.JSONCodec.boolValue(input["streaming"])
                        ?? false,
                    providerOptions: AIProtocolUtils.JSONCodec.objectValue(input["providerOptions"])
                )
                return try fromRequest(req)
            },
            parseResponse: { text throws(AIProtocolUtils.ProtocolError) in
                let decoded = try decodeResponse(text)
                var out: [String: JSONValue] = ["text": .string(decoded.text)]
                if let lang = decoded.language { out["language"] = .string(lang) }
                if let dur = decoded.durationSeconds { out["durationSeconds"] = .double(dur) }
                if !decoded.segments.isEmpty {
                    out["segments"] = .array(decoded.segments.map { seg in
                        var s: [String: JSONValue] = ["text": .string(seg.text), "start": .double(seg.start), "end": .double(seg.end)]
                        if let spk = seg.speaker { s["speaker"] = .string(spk) }
                        return .object(s)
                    })
                }
                return .object(out)
            }
        )

        // parity: ai/src/protocols/openai-transcription.ts#model [status=implemented hash=f4c2cabea6a9]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/openai-transcription.ts#OpenAITranscription [status=implemented hash=c3bd98e95856]
        public static let OpenAITranscription = AIProtocols.OpenAITranscription.self
    }

    // MARK: - 25. OpenRouterVideo (packages/ai/src/protocols/openrouter-video.ts — 8 symbols)

    public enum OpenRouterVideo {
        // parity: ai/src/protocols/openrouter-video.ts#DEFAULT_BASE_URL [status=implemented hash=b9d1cc5c7087]
        public static let DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"

        // parity: ai/src/protocols/openrouter-video.ts#PATH [status=implemented hash=365083670db9]
        public static let PATH = "/videos"

        // parity: ai/src/protocols/openrouter-video.ts#OpenRouterVideoOptions [status=implemented hash=414b0b629eea]
        public typealias OpenRouterVideoOptions = [String: JSONValue]

        // parity: ai/src/protocols/openrouter-video.ts#Request [status=implemented hash=48d02dadda1e]
        public typealias Request = VideoRequestPayload

        // parity: ai/src/protocols/openrouter-video.ts#Token [status=implemented hash=3db348ce72a1]
        public typealias Token = String

        // parity: ai/src/protocols/openrouter-video.ts#protocol [status=implemented hash=8bf0d04ef0ad]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "openrouter-video", name: "OpenRouter Video", provider: "openrouter"),
            mode: .queued,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/openrouter-video.ts#model [status=implemented hash=0ea6ba16e9c5]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/openrouter-video.ts#OpenRouterVideo [status=implemented hash=0b04ebd1e7af]
        public static let OpenRouterVideo = AIProtocols.OpenRouterVideo.self
    }

    // MARK: - 26. SeedanceVideo (packages/ai/src/protocols/seedance-video.ts — 7 symbols)

    public enum SeedanceVideo {
        // parity: ai/src/protocols/seedance-video.ts#VOLCENGINE_BASE_URL [status=implemented hash=e66a3c7eaca8]
        public static let VOLCENGINE_BASE_URL = "https://ark.cn-beijing.volces.com/api/v3"

        // parity: ai/src/protocols/seedance-video.ts#BYTEPLUS_BASE_URL [status=implemented hash=520f2876fed9]
        public static let BYTEPLUS_BASE_URL = "https://ark.ap-southeast.bytepluses.com/api/v3"

        // parity: ai/src/protocols/seedance-video.ts#PATH [status=implemented hash=c9999adb2411]
        public static let PATH = "/contents/generations/tasks"

        // parity: ai/src/protocols/seedance-video.ts#SeedanceVideoOptions [status=implemented hash=b170b0a4d131]
        public typealias SeedanceVideoOptions = [String: JSONValue]

        // parity: ai/src/protocols/seedance-video.ts#Request [status=implemented hash=3118ffc4310e]
        public typealias Request = VideoRequestPayload

        // parity: ai/src/protocols/seedance-video.ts#Token [status=implemented hash=3db348ce72a1]
        public typealias Token = String

        // parity: ai/src/protocols/seedance-video.ts#Provider [status=implemented hash=4887c47d908e]
        public enum Provider: String, Equatable, Hashable, Sendable, Codable {
            case volcengine
            case byteplus

            public var defaultBaseURL: String {
                switch self {
                case .volcengine: return AIProtocols.SeedanceVideo.VOLCENGINE_BASE_URL
                case .byteplus: return AIProtocols.SeedanceVideo.BYTEPLUS_BASE_URL
                }
            }
        }

        public struct ProviderEndpoint: Sendable {
            public let provider: Provider
            public let protocolID: String
            public let baseURL: String
            public let path: String

            public init(provider: Provider) {
                self.provider = provider
                self.protocolID = "seedance-video"
                self.baseURL = provider.defaultBaseURL
                self.path = AIProtocols.SeedanceVideo.PATH
            }

            public func model(_ input: MediaModelInput) -> MediaModelHandle {
                AIProtocols.SeedanceVideo.model(input, provider: provider)
            }
        }

        public struct ProviderRegistry: Sendable {
            public let volcengine: ProviderEndpoint
            public let byteplus: ProviderEndpoint

            public init(volcengine: ProviderEndpoint, byteplus: ProviderEndpoint) {
                self.volcengine = volcengine
                self.byteplus = byteplus
            }
        }

        // parity: ai/src/protocols/seedance-video.ts#SeedanceVideo [status=implemented hash=c50d07fe4328]
        public static let SeedanceVideo = ProviderRegistry(
            volcengine: ProviderEndpoint(provider: .volcengine),
            byteplus: ProviderEndpoint(provider: .byteplus)
        )

        public static func model(_ input: MediaModelInput, provider: Provider = .volcengine) -> MediaModelHandle {
            MediaModelHandle(
                id: input.id,
                provider: input.provider ?? provider.rawValue,
                protocolID: "seedance-video",
                baseURL: input.baseURL ?? provider.defaultBaseURL,
                path: PATH,
                mode: .queued,
                providerOptions: input.providerOptions
            )
        }
    }

    // MARK: - 27. XAIImages (packages/ai/src/protocols/xai-images.ts — 9 symbols)

    public enum XAIImages {
        public static let routeIdentity = AIProtocolUtils.MediaIdentity(id: "xai-images", name: "xAI Images", provider: "xai")

        // parity: ai/src/protocols/xai-images.ts#DEFAULT_BASE_URL [status=implemented hash=cc60095d3c12]
        public static let DEFAULT_BASE_URL = "https://api.x.ai/v1"

        // parity: ai/src/protocols/xai-images.ts#PATH [status=implemented hash=bb919f32959f]
        public static let PATH = "/images/generations"

        // parity: ai/src/protocols/xai-images.ts#EDIT_PATH [status=implemented hash=4f5d44e3ad14]
        public static let EDIT_PATH = "/images/edits"

        // parity: ai/src/protocols/xai-images.ts#XAIImageOptions [status=implemented hash=055a4486ded6]
        public typealias XAIImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/xai-images.ts#Request [status=implemented hash=57a5c6dbf3c6]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/xai-images.ts#resolution [status=implemented hash=5e9d44f3e1cb]
        public static func resolution(_ requested: String?) -> String? {
            guard let requested else { return nil }
            return (AIProtocolUtils.ImageSizing.tier(requested) ?? 1.0) < 1.5 ? "1k" : "2k"
        }

        public static func fromRequest(_ request: Request) throws(AIProtocolUtils.ProtocolError) -> [String: JSONValue] {
            var refs: [JSONValue] = []
            for img in request.images ?? [] {
                let ref = try AIProtocolUtils.ProviderShared.mediaReference(asset: img, provider: routeIdentity.provider, label: routeIdentity.name)
                if ref.type == .ref {
                    refs.append(.object(["file_id": .string(ref.value)]))
                } else {
                    refs.append(.object(["url": .string(ref.value), "type": .string("image_url")]))
                }
            }
            var body: [String: JSONValue] = [
                "model": .string(request.modelID),
                "prompt": .string(request.prompt),
            ]
            if refs.count == 1 {
                body["image"] = refs[0]
            } else if refs.count > 1 {
                body["images"] = .array(refs)
            }
            if let n = request.n { body["n"] = .int(Int64(n)) }
            if let aspect = request.aspect { body["aspect_ratio"] = .string(aspect) }
            if let res = resolution(request.resolution) { body["resolution"] = .string(res) }

            var native = request.providerOptions ?? [:]
            let responseFormat = native.removeValue(forKey: "responseFormat")
            var mergedNative: [String: JSONValue] = [
                "response_format": responseFormat ?? native["response_format"] ?? .string("b64_json"),
            ]
            for (k, v) in native { mergedNative[k] = v }
            return AIProtocolUtils.JSONCodec.mergeObjects(body, mergedNative)
        }

        public static func decodeResponse(_ text: String) throws(AIProtocolUtils.ProtocolError) -> DecodedImageResponse {
            let parsed = try AIProtocolUtils.ProviderShared.parseJson(
                route: routeIdentity.id,
                input: text,
                message: "\(routeIdentity.name) returned an invalid response"
            )
            guard let obj = AIProtocolUtils.JSONCodec.objectValue(parsed),
                  let dataArr = AIProtocolUtils.JSONCodec.arrayValue(obj["data"]) else {
                throw routeIdentity.frameError("\(routeIdentity.name) returned an invalid response", body: text)
            }
            var images: [AIProtocolUtils.MediaAsset] = []
            for (idx, elem) in dataArr.enumerated() {
                guard let item = AIProtocolUtils.JSONCodec.objectValue(elem) else {
                    throw routeIdentity.frameError("\(routeIdentity.name) result \(idx) is not an object", body: text)
                }
                let revised = AIProtocolUtils.JSONCodec.stringValue(item["revised_prompt"])
                let meta: AIProtocolUtils.ProviderMetadata? = revised.map { ["xai": ["revisedPrompt": .string($0)]] }
                let asset = try AIProtocolUtils.MediaInput.imageOutput(
                    invalid: { msg in routeIdentity.frameError(msg, body: text) },
                    label: "\(routeIdentity.name) result \(idx)",
                    b64Json: AIProtocolUtils.JSONCodec.stringValue(item["b64_json"]),
                    url: AIProtocolUtils.JSONCodec.stringValue(item["url"]),
                    mediaType: AIProtocolUtils.JSONCodec.stringValue(item["mime_type"]),
                    providerMetadata: meta
                )
                images.append(asset)
            }
            if images.isEmpty {
                throw routeIdentity.frameError("\(routeIdentity.name) returned no images", body: text)
            }
            let usageMeta: AIProtocolUtils.ProviderMetadata? = AIProtocolUtils.JSONCodec.objectValue(obj["usage"]).map {
                ["xai": ["usage": .object($0)]]
            }
            return DecodedImageResponse(images: images, usage: nil, providerMetadata: usageMeta)
        }

        // parity: ai/src/protocols/xai-images.ts#protocol [status=implemented hash=32b174ab3a05]
        public static let `protocol` = MediaProtocolSpec(
            identity: routeIdentity,
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH,
            buildBody: { input throws(AIProtocolUtils.ProtocolError) in
                let req = Request(
                    modelID: AIProtocolUtils.JSONCodec.stringValue(input["model"]) ?? "grok-2-image",
                    prompt: AIProtocolUtils.JSONCodec.stringValue(input["prompt"]) ?? "",
                    n: AIProtocolUtils.JSONCodec.intValue(input["n"]),
                    aspect: AIProtocolUtils.JSONCodec.stringValue(input["aspect"]),
                    resolution: AIProtocolUtils.JSONCodec.stringValue(input["resolution"]),
                    providerOptions: AIProtocolUtils.JSONCodec.objectValue(input["providerOptions"])
                )
                return try fromRequest(req)
            },
            parseResponse: { text throws(AIProtocolUtils.ProtocolError) in
                let decoded = try decodeResponse(text)
                return .object([
                    "images": .array(decoded.images.map { img in
                        var obj: [String: JSONValue] = ["mediaType": .string(img.mediaType)]
                        if let inline = img.inline() { obj["b64_json"] = .string(inline.base64) }
                        if case .url(let u) = img.source { obj["url"] = .string(u) }
                        if let revised = img.providerMetadata?["xai"]?["revisedPrompt"] {
                            obj["revisedPrompt"] = revised
                        }
                        return .object(obj)
                    }),
                ])
            }
        )

        // parity: ai/src/protocols/xai-images.ts#model [status=implemented hash=509784433d9d]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/xai-images.ts#XAIImages [status=implemented hash=5c790159f0d3]
        public static let XAIImages = AIProtocols.XAIImages.self
    }

    // MARK: - 28. XAIVideo (packages/ai/src/protocols/xai-video.ts — 11 symbols)

    public enum XAIVideo {
        // parity: ai/src/protocols/xai-video.ts#DEFAULT_BASE_URL [status=implemented hash=cc60095d3c12]
        public static let DEFAULT_BASE_URL = "https://api.x.ai/v1"

        // parity: ai/src/protocols/xai-video.ts#PATH [status=implemented hash=7a24ace06b7d]
        public static let PATH = "/videos/generations"

        // parity: ai/src/protocols/xai-video.ts#EDIT_PATH [status=implemented hash=1c7af90e4f01]
        public static let EDIT_PATH = "/videos/edits"

        // parity: ai/src/protocols/xai-video.ts#EXTEND_PATH [status=implemented hash=87756a355faf]
        public static let EXTEND_PATH = "/videos/extensions"

        // parity: ai/src/protocols/xai-video.ts#STATUS_PATH [status=implemented hash=823277b18653]
        public static let STATUS_PATH = "/videos"

        // parity: ai/src/protocols/xai-video.ts#XAIVideoOptions [status=implemented hash=7e6945a45b5a]
        public typealias XAIVideoOptions = [String: JSONValue]

        // parity: ai/src/protocols/xai-video.ts#Request [status=implemented hash=cde0226bdc76]
        public typealias Request = VideoRequestPayload

        // parity: ai/src/protocols/xai-video.ts#Token [status=implemented hash=3db348ce72a1]
        public typealias Token = String

        // parity: ai/src/protocols/xai-video.ts#protocol [status=implemented hash=ebe276feedbf]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "xai-video", name: "xAI Video", provider: "xai"),
            mode: .queued,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/xai-video.ts#model [status=implemented hash=921f76b35e84]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/xai-video.ts#XAIVideo [status=implemented hash=2203767c5687]
        public static let XAIVideo = AIProtocols.XAIVideo.self
    }

    // MARK: - 29. ZAIImages (packages/ai/src/protocols/zai-images.ts — 7 symbols)

    public enum ZAIImages {
        // parity: ai/src/protocols/zai-images.ts#DEFAULT_BASE_URL [status=implemented hash=e01b2ebca740]
        public static let DEFAULT_BASE_URL = "https://api.z.ai/api/paas/v4"

        // parity: ai/src/protocols/zai-images.ts#PATH [status=implemented hash=bb919f32959f]
        public static let PATH = "/images/generations"

        // parity: ai/src/protocols/zai-images.ts#ZAIImageOptions [status=implemented hash=fb0deff4273d]
        public typealias ZAIImageOptions = [String: JSONValue]

        // parity: ai/src/protocols/zai-images.ts#Request [status=implemented hash=b4603ea8320c]
        public typealias Request = ImageRequestPayload

        // parity: ai/src/protocols/zai-images.ts#protocol [status=implemented hash=e72e73089689]
        public static let `protocol` = MediaProtocolSpec(
            identity: AIProtocolUtils.MediaIdentity(id: "zai-images", name: "Z.ai Images", provider: "zai"),
            mode: .inline,
            defaultBaseURL: DEFAULT_BASE_URL,
            path: PATH
        )

        // parity: ai/src/protocols/zai-images.ts#model [status=implemented hash=cd0c9338f567]
        public static func model(_ input: MediaModelInput) -> MediaModelHandle {
            `protocol`.makeModel(input)
        }

        // parity: ai/src/protocols/zai-images.ts#ZAIImages [status=implemented hash=bea08b21c522]
        public static let ZAIImages = AIProtocols.ZAIImages.self
    }
}
